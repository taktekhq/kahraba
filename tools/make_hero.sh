#!/bin/bash
# The cover: a real pointer (not the demo path) parked on the ghoul 0.8 s after
# the cut, rendered at 2288x1430 and cropped to the top-left 1600x1000, so the
# title, the ghoul rearing on the roof, the Ifrit, the Si'lewa and the Qarina's
# eyes share one frame.
set -euo pipefail
cd "$(dirname "$0")/.."
W=$(mktemp -d)
cp scene.rml main.luau light.wgsl rive.yaml ./*.ttf "$W"/
( cd "$W" && EGL_PLATFORM=surfaceless "$HOME/.rive/bin/rive" . --screenshot="$W/big.png" \
    --viewport=2288x1430 --fit=contain --quiet --data=quality=1.79 \
    --advance=480 --pointer=move@450,134 --advance=50 >/dev/null )
${PY:-python3} -c "
from PIL import Image
Image.open('$W/big.png').convert('RGB').crop((0, 0, 1600, 1000)).save('media/hero.jpg', quality=90, optimize=True, progressive=True)
print('wrote media/hero.jpg (1600, 1000)')"
rm -rf "$W"
