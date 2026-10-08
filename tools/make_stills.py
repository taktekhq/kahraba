#!/usr/bin/env python3
"""Picks the stills from the rendered frame sequences (1600x1000, the same
headless `rive --screenshot` frames the video is cut from) and writes JPEGs.

    python3 tools/make_stills.py --main /tmp/kframes/main --dead /tmp/kframes/dead --out media
"""
import argparse
import os

from PIL import Image

# (file, sequence, frame index at 30 fps; main starts at film 0 s, dead at 72.5 s)
STILLS = [
    ('hero.jpg', 'main', 324),              # 10.8 s: fallback; tools/make_hero.sh writes the real cover
    ('still-lit.jpg', 'main', 90),          # 3 s: 8 PM, state power on
    ('still-qarina.jpg', 'main', 555),      # 18.5 s: the Qarina lifts her own phone
    ('still-battery-dead.jpg', 'dead', 63),  # 74.6 s: every window opens its eyes
    ('still-ending.jpg', 'main', 1110),     # 37 s: the moteur, six jinn on the parapet
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--main', required=True)
    ap.add_argument('--dead', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    dirs = {'main': a.main, 'dead': a.dead}
    for name, seq, i in STILLS:
        im = Image.open(os.path.join(dirs[seq], f'f{i:05d}.png')).convert('RGB')
        path = os.path.join(a.out, name)
        im.save(path, quality=90, optimize=True, progressive=True)
        print('wrote', path, im.size)


if __name__ == '__main__':
    main()
