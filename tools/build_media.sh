#!/bin/bash
# Rebuilds every media file from the project in one go:
#   frames (headless rive --screenshot, resumable) -> soundtrack -> video -> stills
#   tools/build_media.sh                  # FRAMES=/tmp/kframes JOBS=7 by default
#   FRESH=1 tools/build_media.sh          # re-render every frame (after any scene change)
#   FRAMES_ONLY=1 tools/build_media.sh    # stop after the frames
set -euo pipefail
cd "$(dirname "$0")/.."
FRAMES=${FRAMES:-/tmp/kframes}
JOBS=${JOBS:-7}
PY_SND=${PY_SND:-$HOME/venvs/pw/bin/python}   # needs numpy
PY=${PY:-python3}                             # needs Pillow + pygments
export PATH="$HOME/.rive/bin:$PATH"
export EGL_PLATFORM=${EGL_PLATFORM:-surfaceless}
if [ "${FRESH:-0}" = 1 ] && [ -d "$FRAMES" ]; then
  mv "$FRAMES" "$FRAMES.old.$(date +%s)"   # kept, not deleted: remove by hand when happy
fi
rive . --verify
R="$PY tools/render_frames.py --jobs $JOBS --data quality=1.25"
# the piece on the demo path: lit street, the cut, six catches, the moteur ending
$R --out "$FRAMES/main" --start 2.5 --end 36.9 --data autoplay=1
# the other ending: nobody finds anything, the battery dies (film 40.3 s)
$R --out "$FRAMES/dead" --start 39.6 --end 44.6
# the breakdown: the script's two buffers at film 17.2 s
$R --out "$FRAMES/albedo" --start 17.2 --end 17.23 --data autoplay=1 --data view=1
$R --out "$FRAMES/emit" --start 17.2 --end 17.23 --data autoplay=1 --data view=2
[ "${FRAMES_ONLY:-0}" = 1 ] && exit 0
$PY_SND tools/make_sound.py --out "$FRAMES/kahraba.wav"
$PY tools/make_video.py --frames "$FRAMES" --audio "$FRAMES/kahraba.wav" --out media/kahraba.mp4
$PY tools/make_stills.py --frames "$FRAMES" --out media
tools/make_hero.sh   # the cover is its own zoomed render
ls -la media
