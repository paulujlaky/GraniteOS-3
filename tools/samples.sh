#!/bin/sh
# Rebuilds the sample media new accounts start with, in src/services/samples, from their freely licensed originals on
# Wikimedia Commons; src/services/samples/Credits.txt names each. Needs curl, ffmpeg, and flac.
set -eu

project=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
samples=$project/src/services/samples
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"

commons=https://upload.wikimedia.org/wikipedia/commons

fetch() {

    curl -fsSL -A "GraniteOS samples (tools/samples.sh)" -o "$1" "$commons/$2"

}

fetch mountain.flac "8/84/Grieg_-_Peer_Gynt_Suite_No._1%2C_Op._46_-_IV._In_the_Hall_of_the_Mountain_King_%28Musopen_Symphony%29.flac"
fetch kiev.ogg "b/be/Modest_Mussorgsky_-_pictures_at_an_exhibition_-_x._la_grande_porte_de_kiev_-_allegro_alla_breve._maestoso._con_grandezza.ogg"
fetch capitan.webm "6/62/El_Capitan_Yosemite.webm"

# The whole Grieg as MP3, its trailing silence cut.
ffmpeg -v error -y -i mountain.flac -t 153 -af "afade=t=out:st=151.5:d=1.5" -ar 44100 -c:a libmp3lame -b:a 112k -id3v2_version 3 \
    -metadata title="In the Hall of the Mountain King" -metadata artist="Edvard Grieg, Musopen Symphony" "$samples/mountain.mp3"

# The last 26 seconds of the Mussorgsky as mono FLAC, which keeps the boot image small.
ffmpeg -v error -y -sseof -26 -i kiev.ogg -af "afade=t=in:d=1" -ar 44100 -ac 1 -sample_fmt s16 kiev.wav
flac -s -f -8 -T "TITLE=The Great Gate of Kiev" -T "ARTIST=Modest Mussorgsky" -o "$samples/kiev.flac" kiev.wav

# Five scenes of El Capitan, faded into each other, as an MPEG-1 system stream with MP2 sound.
graph=""
index=0

for scene in "2 6 5.6" "20 5 4.6" "58 6 5.6" "125 6 5.6" "182 7 6.6"; do

    set -- $scene
    graph="$graph[0:v]trim=start=$1:duration=$2,setpts=PTS-STARTPTS,fade=t=in:d=0.4,fade=t=out:st=$3:d=0.4[v$index];"
    graph="$graph[0:a]atrim=start=$1:duration=$2,asetpts=PTS-STARTPTS,afade=t=in:d=0.4,afade=t=out:st=$3:d=0.4[a$index];"
    index=$((index + 1))

done

graph="$graph[v0][a0][v1][a1][v2][a2][v3][a3][v4][a4]concat=n=5:v=1:a=1[v][a];[v]scale=480:270:flags=lanczos[sized];"
graph="$graph[a]volume=12dB,aresample=44100[heard]"

ffmpeg -v error -y -i capitan.webm -filter_complex "$graph" -map "[sized]" -map "[heard]" -c:v mpeg1video -b:v 450k -maxrate 1200k \
    -bufsize 1835k -g 15 -bf 2 -c:a mp2 -b:a 96k -ac 1 -f mpeg "$samples/capitan.mpg"
