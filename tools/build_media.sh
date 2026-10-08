#!/bin/bash
# Rebuilds every media file from the project in one go:
#   frames (headless rive --screenshot, resumable) -> soundtrack -> video -> stills
#   tools/build_media.sh            # FRAMES=/tmp/kframes JOBS=7 by default
#   FRESH=1 tools/build_media.sh    # throw away cached frames first (after any scene change)
set -euo pipefail
cd "$(dirname "$0")/.."
FRAMES=${FRAMES:-/tmp/kframes}
JOBS=${JOBS:-7}
PY_SND=${PY_SND:-$HOME/venvs/pw/bin/python}   # needs numpy
PY=${PY:-python3}                             # needs Pillow + pygments
export PATH="$HOME/.rive/bin:$PATH"
[ "${FRESH:-0}" = 1 ] && rm -rf "$FRAMES"
rive . --verify
$PY tools/render_frames.py --out "$FRAMES/main" --start 0 --end 40.5 --data autoplay=1 --data quality=1.25 --jobs "$JOBS"
$PY tools/render_frames.py --out "$FRAMES/dead" --start 72.5 --end 78.5 --data quality=1.25 --jobs "$JOBS"
$PY_SND tools/make_sound.py --out "$FRAMES/kahraba.wav"
$PY tools/make_video.py --main "$FRAMES/main" --dead "$FRAMES/dead" --audio "$FRAMES/kahraba.wav" --out media/kahraba.mp4
$PY tools/make_stills.py --main "$FRAMES/main" --dead "$FRAMES/dead" --out media
tools/make_hero.sh   # the cover replaces the sequence frame
ls -la media
