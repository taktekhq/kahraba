#!/usr/bin/env python3
"""Picks the stills from the rendered frame sequences (1600x1000, the same
headless `rive --screenshot` frames the video is cut from) and writes JPEGs.
The cover (hero.jpg) is its own render: tools/make_hero.sh.

    python3 tools/make_stills.py --frames /tmp/kframes --out media
"""
import argparse
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

import film

# (file, sequence, film time)
STILLS = [
    ('still-lit.jpg', 'main', 4.0),               # 8 PM, state power on, for now
    ('still-qarina.jpg', 'main', 19.15),          # the close-up: the Qarina lifts her own phone, 3 / 6
    ('still-battery-dead.jpg', 'dead', 41.3),     # every window opens its eyes
    ('still-ending.jpg', 'main', 36.0),           # the moteur, six jinn on the parapet, end card
]
START = {'main': film.PIECE_START, 'dead': film.DEAD_START}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def poster(street, path):
    # the video's poster: the street out of focus, the title, nothing else
    im = street.filter(ImageFilter.GaussianBlur(7))
    im = Image.blend(Image.new('RGB', im.size, (10, 12, 18)), im, 0.42)
    d = ImageDraw.Draw(im)
    f = lambda n, z: ImageFont.truetype(os.path.join(ROOT, n), z)
    d.text((800, 400), 'كهربا', font=f('Lalezar-Regular.ttf', 220), fill=(255, 200, 97), anchor='mm')
    d.text((800, 570), 'KAHRABA', font=f('Lalezar-Regular.ttf', 72), fill=(242, 232, 213), anchor='mm')
    d.text((800, 640), 'a Beirut power-cut ghost story', font=f('IBMPlexSansArabic-Regular.ttf', 34),
           fill=(200, 192, 178), anchor='mm')
    im.save(path, quality=88, optimize=True, progressive=True)
    print('wrote', path, im.size)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--frames', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    for name, seq, t in STILLS:
        i = int(round((t - START[seq]) * film.FPS))
        im = Image.open(os.path.join(a.frames, seq, f'f{i:05d}.png')).convert('RGB')
        path = os.path.join(a.out, name)
        im.save(path, quality=90, optimize=True, progressive=True)
        print('wrote', path, im.size)
        if name == 'still-lit.jpg':
            poster(im, os.path.join(a.out, 'poster.jpg'))


if __name__ == '__main__':
    main()
