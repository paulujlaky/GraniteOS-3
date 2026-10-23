# Writes a short test signal as 16-bit WAV: tones, a chirp, and a noise burst that forces short blocks.
import sys, wave
import numpy as np

path, rate, channels, seconds = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
t = np.arange(int(rate * seconds)) / rate
top = rate * 0.4
chirp = np.sin(2 * np.pi * (100 * t + (top - 100) * t * t / (2 * seconds)))
burst = np.zeros_like(t)
start, stop = int(rate * seconds * 0.55), int(rate * seconds * 0.55 + rate * 0.015)
burst[start:stop] = np.random.default_rng(7).uniform(-1, 1, stop - start)
left = 0.3 * np.sin(2 * np.pi * 440 * t) + 0.2 * chirp + 0.5 * burst
right = 0.3 * np.sin(2 * np.pi * 660 * t + 1) + 0.15 * chirp + 0.4 * burst
data = np.stack([left, right], axis=1)[:, :channels]
pcm = np.clip(np.round(data * 32767), -32768, 32767).astype('<i2')
with wave.open(path, 'wb') as out:
    out.setnchannels(channels)
    out.setsampwidth(2)
    out.setframerate(rate)
    out.writeframes(pcm.tobytes())
