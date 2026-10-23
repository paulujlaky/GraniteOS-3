# A bare MPEG-1 Layer I encoder (no psychoacoustics), only to make valid test streams for decoders.
import sys, wave
import numpy as np

source, target, bitrate, mode = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
with wave.open(source) as wav:
    channels, rate = wav.getnchannels(), wav.getframerate()
    pcm = np.frombuffer(wav.readframes(wav.getnframes()), '<i2').reshape(-1, channels) / 32768.0

rates = {44100: 0, 48000: 1, 32000: 2}
bitrates = [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]
joint = mode == 'joint'
bound = 8 if joint else 32
taps = np.arange(512)
prototype = np.sinc((taps - 255.5) / 64) * np.hanning(512) / 32
matrix = np.cos((2 * np.arange(32)[:, None] + 1) * (taps[None, :] - 16) * np.pi / 64) * prototype[None, :]

blocks = (len(pcm) + 383) // 384 * 12 + 12
padded = np.concatenate([np.zeros((512, channels)), pcm, np.zeros((blocks * 32 - len(pcm), channels))])
subbands = np.zeros((channels, blocks, 32))
for block in range(blocks):
    window = padded[block * 32 + 31 + 512 - taps]
    subbands[:, block, :] = (matrix @ window).T
subbands *= 0.5 / max(np.abs(subbands).max(), 1e-9)
scales = 2.0 ** (1 - np.arange(63) / 3)

class Writer:
    def __init__(self): self.bits = []
    def put(self, value, count): self.bits += [(value >> (count - 1 - i)) & 1 for i in range(count)]

out = bytearray()
exact = 12 * bitrate * 1000 / rate
for frame in range(blocks // 12):
    slots = int((frame + 1) * exact) - int(frame * exact)
    padding = slots - int(exact)
    budget = slots * 32 - 32
    s = subbands[:, frame * 12:(frame + 1) * 12, :]
    if joint: s = np.concatenate([s[:, :, :bound], np.repeat(s[:, :, bound:].mean(axis=0, keepdims=True), 2, axis=0)], axis=2)
    units = [(sb, ch) for sb in range(32) for ch in range(channels if sb < bound else 1)]
    budget -= 4 * len(units)
    alloc = {unit: 0 for unit in units}
    peak = {unit: np.abs(s[unit[1], :, unit[0]]).max() for unit in units}
    while True:
        best, score = None, -1e9
        for unit in units:
            a = alloc[unit]
            if a == 14: continue
            cost = 12 if a else 12 * 2 + 6 * (1 if unit[0] < bound else channels)
            value = 20 * np.log10(peak[unit] + 1e-9) - 6.02 * (a + 1)
            if cost <= budget and value > score: best, score = unit, value
        if best is None or score < -90: break
        budget -= 12 if alloc[best] else 12 * 2 + 6 * (1 if best[0] < bound else channels)
        alloc[best] += 1
    w = Writer()
    w.put(0xfff, 12); w.put(1, 1); w.put(3, 2); w.put(1, 1)
    w.put(bitrates.index(bitrate), 4); w.put(rates[rate], 2); w.put(padding, 1); w.put(0, 1)
    w.put(3 if channels == 1 else (1 if joint else 0), 2); w.put(1 if joint else 0, 2); w.put(0, 4)
    for unit in units: w.put(alloc[unit], 4)
    factor = {}
    for sb in range(32):
        for ch in range(channels):
            unit = (sb, ch if sb < bound else 0)
            if not alloc[unit]: continue
            index = int(np.searchsorted(-scales, -max(peak[unit], 1e-9), side='right')) - 1
            factor[(sb, ch)] = max(index, 0)
            w.put(factor[(sb, ch)], 6)
    for sample in range(12):
        for unit in units:
            a = alloc[unit]
            if not a: continue
            levels = (1 << (a + 1)) - 1
            scale = scales[factor[(unit[0], unit[1])]]
            value = int(round((s[unit[1], sample, unit[0]] / scale * levels + levels - 1) / 2))
            w.put(min(max(value, 0), levels - 1), a + 1)
    w.bits += [0] * (slots * 32 - len(w.bits))
    out += bytes(int(''.join(map(str, w.bits[i:i + 8])), 2) for i in range(0, len(w.bits), 8))
open(target, 'wb').write(out)
