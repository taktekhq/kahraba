#!/bin/bash
# The cover: a real pointer (not the demo path) parked on the Ghoul after the
# cut until it is caught; the frame is taken 0.4 s after the catch, in the
# close-up, as it stretches up with its claws over its head (no lock-on ring).
set -euo pipefail
cd "$(dirname "$0")/.."
W=$(mktemp -d)
cp scene.rml main.luau light.wgsl rive.yaml ./*.ttf "$W"/
( cd "$W" && EGL_PLATFORM=surfaceless "$HOME/.rive/bin/rive" . --screenshot="$W/hero.png" \
    --viewport=1600x1000 --fit=contain --quiet --data=quality=1.5 \
    --advance=480 --pointer=move@450,134 --advance=76 >/dev/null )
${PY:-python3} -c "
from PIL import Image
Image.open('$W/hero.png').convert('RGB').save('media/hero.jpg', quality=90, optimize=True, progressive=True)
print('wrote media/hero.jpg (1600, 1000)')"
rm -rf "$W"
