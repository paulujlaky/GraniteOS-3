#!/bin/sh
# Regenerates the media decoders' test fixtures in src/media/fixtures with ffmpeg, flac, lame, and Python with numpy.
# Tests hold sample counts, CRCs, and times taken from ffmpeg 8.1, LAME 3.100, and flac 1.5; other versions may need them updated.
set -eu

project=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
fixtures=$project/src/media/fixtures
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"

python=${PYTHON:-}
for candidate in py python3 python; do

    [ -z "$python" ] || break
    ! "$candidate" --version >/dev/null 2>&1 || python=$candidate

done

tone() {

    ffmpeg -v error -y -f lavfi -i "aevalsrc=$1" -c:a "$2" "$3"

}

# FLAC: one file per sample width and layout; their STREAMINFO MD5s are what the tests check against.
tone "0.5*sin(2*PI*440*t)+0.1*sin(2*PI*3000*t)+0.004*random(0)|0.4*sin(2*PI*660*t)+0.45*sin(2*PI*440*t)+0.004*random(1):s=44100:d=0.3" pcm_s16le stereo16.wav
tone "0.7*sin(2*PI*1000*t)*sin(2*PI*3*t)+0.0005*random(0):s=96000:d=0.08" pcm_s24le mono24.wav
tone "0.6*sin(2*PI*300*t)+0.02*random(0):s=8000:d=0.5" pcm_u8 mono8.wav
tone "0.3*sin(2*PI*200*t)|0.3*sin(2*PI*300*t)|0.3*sin(2*PI*400*t)|0.3*sin(2*PI*50*t)|0.2*sin(2*PI*500*t)|0.2*sin(2*PI*600*t):s=48000:d=0.06" pcm_s16le surround.wav
tone "0.9*sin(2*PI*440*t)+0.00001*random(0)|-0.9*sin(2*PI*440*t)+0.3*sin(2*PI*5000*t):s=48000:d=0.04" pcm_s32le stereo32.wav
tone "0.5*sin(2*PI*(200+300*t)*t):s=22050:d=2" pcm_s16le sweep.wav

flac -s -f -8 -o "$fixtures/flac-stereo16.flac" stereo16.wav
flac -s -f -8 -o "$fixtures/flac-mono24.flac" mono24.wav
flac -s -f -5 -o "$fixtures/flac-mono8.flac" mono8.wav
flac -s -f -5 -o "$fixtures/flac-surround.flac" surround.wav
flac -s -f -8 -o "$fixtures/flac-stereo32.flac" stereo32.wav
flac -s -f -6 -b 1152 -S 20x -T "TITLE=Sweep Test" -T "ARTIST=Gränite" -o "$fixtures/flac-tagged.flac" sweep.wav

# MPEG audio: tones, a chirp, and a noise burst that forces short blocks, at every rate and layer; Layer I comes from
# tools/layer.py, since neither ffmpeg nor LAME writes it.
waves() {

    "$python" "$project/tools/waves.py" "$@"

}

waves s44.wav 44100 2 0.5
waves s44s.wav 44100 2 0.25
waves s44t.wav 44100 2 0.3
waves s48.wav 48000 2 0.5
waves s48m.wav 48000 1 0.3
waves s44m.wav 44100 1 0.5
waves s32.wav 32000 2 0.5
waves s32m.wav 32000 1 0.5
waves s32mt.wav 32000 1 0.3
waves s22.wav 22050 2 0.5
waves s24.wav 24000 2 0.5
waves s16m.wav 16000 1 0.5
waves s11.wav 11025 2 0.5
waves s12m.wav 12000 1 0.5
waves s8m.wav 8000 1 0.5

lame --quiet -b 128 -m j s44.wav "$fixtures/mp3-44k-joint.mp3"
lame --quiet -b 320 -m s -q 0 s44s.wav "$fixtures/mp3-44k-320.mp3"
lame --quiet -V 2 s48.wav "$fixtures/mp3-48k-vbr.mp3"
lame --quiet -t -b 48 -m m s32m.wav "$fixtures/mp3-32k-mono.mp3"
lame --quiet -b 48 -m j s22.wav "$fixtures/mp3-22k-joint.mp3"
lame --quiet -p -b 64 -m s s24.wav "$fixtures/mp3-24k-stereo.mp3"
lame --quiet -b 24 -m m s16m.wav "$fixtures/mp3-16k-mono.mp3"
lame --quiet --resample 11.025 -b 32 -m j s11.wav "$fixtures/mp3-11k-joint.mp3"
lame --quiet --resample 12 -b 16 -m m s12m.wav "$fixtures/mp3-12k-mono.mp3"
lame --quiet --resample 8 -b 8 -m m s8m.wav "$fixtures/mp3-8k-mono.mp3"
ffmpeg -v error -y -i s44t.wav -c:a mp2 -b:a 224k -f mp2 "$fixtures/mp2-44k-stereo.mp2"
ffmpeg -v error -y -i s48m.wav -c:a mp2 -b:a 64k -f mp2 "$fixtures/mp2-48k-mono.mp2"
ffmpeg -v error -y -i s44m.wav -c:a mp2 -b:a 48k -f mp2 "$fixtures/mp2-44k-mono.mp2"
ffmpeg -v error -y -i s32.wav -c:a mp2 -b:a 64k -f mp2 "$fixtures/mp2-32k-stereo.mp2"
ffmpeg -v error -y -i s22.wav -c:a mp2 -b:a 64k -f mp2 "$fixtures/mp2-22k-stereo.mp2"
"$python" "$project/tools/layer.py" s44t.wav "$fixtures/mp1-44k-joint.mp1" 192 joint
"$python" "$project/tools/layer.py" s32mt.wav "$fixtures/mp1-32k-mono.mp1" 64 mono

# Each MPEG audio file's reference is the start of ffmpeg's own float decoder's output, rounded to 16 bits.
for file in "$fixtures"/mp3-*.mp3 "$fixtures"/mp2-*.mp2 "$fixtures"/mp1-*.mp1; do

    ffmpeg -v error -y -c:a "${file##*.}float" -i "$file" -f s16le whole.pcm
    head -c 8192 whole.pcm > "${file%.*}.pcm"

done

# MPEG-1 video: GOPs with B pictures, custom quantiser matrices at an odd size, SIF in an MPEG-2 program stream, a long
# clip for seeking, and MPEG-2 video the decoder must refuse.
ffmpeg -v error -y -f lavfi -i testsrc2=size=160x120:rate=25 -f lavfi -i sine=frequency=440:sample_rate=32000 -t 1 -c:v mpeg1video -q:v 10 -g 12 -bf 2 -c:a mp2 -b:a 32k -ac 1 -f mpeg "$fixtures/video-gop.mpg"
intra=$("$python" -c "print(','.join(str(8 + (i % 8 + i // 8) * 3) for i in range(64)))")
inter=$("$python" -c "print(','.join(str(12 + (i % 8) * 2 + i // 8) for i in range(64)))")
ffmpeg -v error -y -f lavfi -i mandelbrot=size=100x60:rate=25 -t 0.6 -c:v mpeg1video -q:v 4 -g 6 -bf 1 -intra_matrix "$intra" -inter_matrix "$inter" -f mpeg1video "$fixtures/video-odd.m1v"
ffmpeg -v error -y -f lavfi -i "mandelbrot=size=352x240:rate=30000/1001" -f lavfi -i sine=frequency=330:sample_rate=48000 -t 0.3 -c:v mpeg1video -b:v 1200k -qmin 8 -qmax 31 -lumi_mask 0.3 -dark_mask 0.2 -g 6 -bf 2 -c:a mp2 -b:a 64k -ac 1 -f vob "$fixtures/video-sif.mpg"
ffmpeg -v error -y -f lavfi -i mandelbrot=size=64x48:rate=25 -f lavfi -i sine=frequency=500:sample_rate=32000 -t 6 -c:v mpeg1video -q:v 16 -g 12 -bf 2 -c:a mp2 -b:a 32k -ac 1 -f mpeg "$fixtures/system-long.mpg"
ffmpeg -v error -y -f lavfi -i testsrc2=size=32x32:rate=25 -t 0.12 -c:v mpeg2video -q:v 10 -an -f vob "$fixtures/system-mpeg2.mpg"

# Video references: ffmpeg's decode of chosen display-order pictures, every step-th pel of every step-th row of Y, Cb, Cr.
reference() {

    ffmpeg -v error -y -i "$fixtures/$1" -f rawvideo -pix_fmt yuv420p -fps_mode passthrough frames.yuv
    "$python" -c '
import sys
width, height, step = map(int, sys.argv[2:5])
frames = [int(index) for index in sys.argv[5].split(",")]
data = open("frames.yuv", "rb").read()
cw, ch = (width + 1) // 2, (height + 1) // 2
size = width * height + 2 * cw * ch
out = bytearray()
for index in frames:
    frame = data[index * size:(index + 1) * size]
    for start, w, h in ((0, width, height), (width * height, cw, ch), (width * height + cw * ch, cw, ch)):
        for y in range(0, h, step):
            out += frame[start + y * w:start + (y + 1) * w:step]
open(sys.argv[1], "wb").write(out)
' "$fixtures/$2" "$3" "$4" "$5" "$6"

}

reference video-gop.mpg video-gop.yuv 160 120 2 0,4,11,22
reference video-odd.m1v video-odd.yuv 100 60 1 0,7,14
reference video-sif.mpg video-sif.yuv 352 240 4 1,5,8
