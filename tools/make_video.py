#!/usr/bin/env python3
"""Cuts the submission film from rendered frames (timeline in tools/film.py).

  1. the piece, opening on the lit street (the cut lands at 4.5 s), with the
     pointer drawn where the demo path puts it and hidden in the close-ups
  2. the other ending: the battery dies
  3. GPU Canvas taken apart: the script's albedo and emission buffers beside
     the lit result (real renders, `--data=view=1|2`)
  4. a real terminal session (tools/session/session.txt), replayed
  5. credits on a clean ground

    python3 tools/make_video.py --frames /tmp/kframes --audio /tmp/kframes/kahraba.wav \
        --out media/kahraba.mp4
"""
import argparse
import math
import os
import subprocess

from PIL import Image, ImageDraw, ImageFont

import film

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
W, H, FPS = 1600, 1000, film.FPS
BG = (10, 12, 18)
PANEL = (17, 20, 28)
GOLD = (255, 200, 97)
CREAM = (242, 232, 213)
MUTED = (185, 179, 166)
DIM = (110, 106, 98)
GREEN = (160, 220, 150)
VIOLET = (190, 160, 255)

MONO = '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf'
F = lambda name, size: ImageFont.truetype(os.path.join(ROOT, name), size)
LALEZAR = 'Lalezar-Regular.ttf'
PLEX = 'IBMPlexSansArabic-Regular.ttf'
PLEX_SB = 'IBMPlexSansArabic-SemiBold.ttf'


def ease(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def fade_black(im, a):
    if a >= 1:
        return im
    return Image.blend(Image.new('RGB', (W, H), (0, 0, 0)), im, max(0.0, a))


# ---- the pointer: the same path and smoothing as main.luau's autopilot
FILM = [(0, 640, 430), (7.2, 640, 430), (8.4, 560, 300), (9.4, 520, 230),
        (10.4, 430, 140), (12.0, 425, 126),
        (13.0, 540, 260), (13.8, 610, 352), (15.4, 616, 360),
        (16.4, 820, 470), (17.4, 760, 520), (18.2, 646, 500), (19.8, 640, 504),
        (20.8, 440, 520), (21.6, 220, 430), (23.2, 204, 452),
        (24.2, 420, 640), (25.0, 600, 740), (25.4, 640, 752), (27.0, 640, 752),
        (27.8, 470, 770), (28.4, 330, 762), (30.2, 306, 760),
        (31.4, 500, 420), (60, 520, 400)]


def autopilot(t):
    a, b = FILM[-1], FILM[-1]
    for i in range(len(FILM) - 1):
        if FILM[i][0] <= t < FILM[i + 1][0]:
            a, b = FILM[i], FILM[i + 1]
            break
    span = max(0.001, b[0] - a[0])
    f = ease((t - a[0]) / span)
    hx = math.sin(t * 2.3) * 4 + math.sin(t * 5.1) * 1.5
    hy = math.cos(t * 1.7) * 3 + math.sin(t * 4.3) * 1.5
    return a[1] + (b[1] - a[1]) * f + hx, a[2] + (b[2] - a[2]) * f + hy


def torch_track(seconds):
    dt = 1 / 60
    k = 1 - math.exp(-dt * 12)
    tx, ty = 640.0, 430.0
    t = 0.0
    track = []
    for _ in range(int(seconds * 60) + 2):
        t += dt
        gx, gy = autopilot(t)
        tx += (gx - tx) * k
        ty += (gy - ty) * k
        track.append((tx, ty))
    return track


def to_px(x, y):
    sx = 640 + (x - 640) * 0.88
    sy = y * 0.88 + 22
    return sx * W / 1280, sy * H / 800


def pointer_alpha(t):
    """Shown from the cut until the hunt ends, hidden while a close-up holds
    (the camera moves there, the drawn pointer would not)."""
    a = ease((t - (film.CUT + 0.2)) / 0.3) * (1 - ease((t - 30.0) / 0.4))
    for c in film.CATCHES:
        a *= 1 - ease((t - (c - 0.15)) / 0.15) * (1 - ease((t - (c + film.CLOSE + 0.35)) / 0.25))
    return a


def draw_pointer(im, x, y, a):
    if a <= 0.01:
        return im
    layer = Image.new('RGBA', im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    pts = [(0, 0), (0, 26), (7, 20), (12, 31), (17, 29), (12, 18), (21, 18)]
    poly = [(x + px, y + py) for px, py in pts]
    d.polygon([(px + 2, py + 2) for px, py in poly], fill=(0, 0, 0, int(110 * a)))
    d.polygon(poly, fill=(255, 255, 255, int(255 * a)), outline=(20, 20, 24, int(255 * a)))
    base = im.convert('RGBA')
    base.alpha_composite(layer)
    return base.convert('RGB')


def chip(im, text, a, y=56, cx=712):
    if a <= 0.01:
        return im
    layer = Image.new('RGBA', im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    f = F(PLEX_SB, 19)
    w = f.getlength(text) + 44
    d.rounded_rectangle((cx - w / 2, y - 22, cx + w / 2, y + 22), 22, fill=(10, 12, 18, int(225 * a)),
                        outline=(255, 200, 97, int(120 * a)), width=1)
    d.text((cx, y), text, font=f, fill=(255, 200, 97, int(255 * a)), anchor='mm')
    base = im.convert('RGBA')
    base.alpha_composite(layer)
    return base.convert('RGB')


def heading(d, title, sub, step=None):
    d.text((64, 46), title, font=F(PLEX_SB, 34), fill=CREAM)
    d.text((64, 92), sub, font=F(PLEX, 22), fill=MUTED)
    if step:
        d.text((W - 64, 52), step, font=F(PLEX_SB, 18), fill=GOLD, anchor='ra')


# ---- 3. GPU Canvas taken apart
def breakdown_frame(t, alb, emi, lit):
    im = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(im)
    heading(d, 'GPU Canvas, taken apart',
            'main.luau draws the street twice a frame; one WGSL pass lights it')
    pw, ph = 480, 300
    xs = [56, 560, 1064]
    y0 = 300
    items = [(alb, 'albedo', 'what things are made of (sky left empty)'),
             (emi, 'emission', 'what glows: windows, eyes, moon, candle'),
             (lit, 'light.wgsl', 'moonlight, window spill, the torch, fog')]
    for k, (src, name, note) in enumerate(items):
        a = ease((t - 0.1 - k * 0.45) / 0.35)
        if a <= 0:
            continue
        # the street only: the RML HUD is not part of the script's buffers
        th = src.crop((300, 150, 1300, 775)).resize((pw, ph), Image.LANCZOS)
        yy = int(y0 + (1 - a) * 30)
        tile = Image.blend(Image.new('RGB', (pw, ph), BG), th, a)
        im.paste(tile, (xs[k], yy))
        d.rounded_rectangle((xs[k] - 1, yy - 1, xs[k] + pw, yy + ph), 8,
                            outline=GOLD if k == 2 else (60, 62, 72), width=2)
        col = tuple(int(BG[i] + (c - BG[i]) * a) for i, c in enumerate(GOLD))
        mut = tuple(int(BG[i] + (c - BG[i]) * a) for i, c in enumerate(MUTED))
        d.text((xs[k], yy + ph + 22), f'{k + 1} · {name}', font=F(PLEX_SB, 24), fill=col)
        d.text((xs[k], yy + ph + 58), note, font=F(PLEX, 19), fill=mut)
        if k > 0:
            d.text((xs[k] - 12, y0 + ph // 2), '+' if k == 1 else '→', font=F(PLEX_SB, 34),
                   fill=col, anchor='rm')
    return fade_black(im, ease(t / 0.25) * (1 - ease((t - film.BREAK_DUR + 0.25) / 0.25)))


# ---- 4. the terminal, replayed from a real capture
def line_colour(s):
    if s.startswith('+') and not s.startswith('+++'):
        return GREEN
    if s.startswith('@@'):
        return VIOLET
    if s.startswith('diff') or s.startswith('index') or s.startswith('---') or s.startswith('+++'):
        return DIM
    return MUTED


def terminal_frame(t, sched, shot, mono):
    im = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(im)
    heading(d, 'The loop, for real', 'a captured session in this repo: the diff, rive --verify, a screenshot run')
    px, py, pw, ph = 48, 150, 1504, 800
    d.rounded_rectangle((px, py, px + pw, py + ph), 18, fill=PANEL)
    for k, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        d.ellipse((px + 22 + k * 22, py + 20, px + 34 + k * 22, py + 32), fill=c)
    d.text((px + pw // 2, py + 26), 'kahraba: bash', font=F(PLEX, 16), fill=DIM, anchor='mm')
    lines = []
    caret = None
    for (et, kind, text) in sched:
        if et > t:
            break
        if kind == 'cmd':
            n = int((t - et) * film.TYPE_CPS)
            lines.append(('cmd', text[:max(2, n)]))
            if n < len(text):
                caret = len(lines) - 1
        else:
            lines.append(('out', text))
    lh = 29
    maxl = (ph - 70) // lh
    shown = lines[-maxl:]
    x0, y = px + 28, py + 56
    for i, (kind, text) in enumerate(shown):
        if kind == 'cmd':
            d.text((x0, y), '$', font=mono, fill=GOLD)
            d.text((x0 + mono.getlength('$ '), y), text[2:], font=mono, fill=CREAM)
        else:
            if text.startswith('[') and 'rive' in text:
                stamp, _, rest = text.partition(' ')
                d.text((x0, y), stamp, font=mono, fill=DIM)
                d.text((x0 + mono.getlength(stamp + ' '), y), rest, font=mono,
                       fill=GREEN if ('0 errors' in rest or 'wrote' in rest) else MUTED)
            else:
                d.text((x0, y), text, font=mono, fill=line_colour(text))
        if caret is not None and i == len(shown) - 1 - (len(lines) - 1 - caret) and kind == 'cmd':
            cx = x0 + mono.getlength(text)
            d.rectangle((cx + 2, y + 3, cx + 12, y + 24), fill=GOLD)
        y += lh
    # the screenshot it wrote
    wrote = [et for (et, kind, text) in sched if kind == 'out' and 'wrote build/' in text]
    if wrote and t > wrote[0]:
        a = ease((t - wrote[0]) / 0.35)
        tw, tht = 432, 270
        th = shot.resize((tw, tht), Image.LANCZOS)
        tx, ty = px + pw - tw - 36, py + 86
        im.paste(Image.blend(Image.new('RGB', th.size, PANEL), th, a), (tx, ty))
        d.rectangle((tx - 1, ty - 1, tx + tw, ty + tht), outline=GOLD, width=2)
        d.text((tx, ty - 30), 'build/albedo.png', font=mono, fill=GOLD)
    return fade_black(im, ease(t / 0.25) * (1 - ease((t - film.TERM_DUR + 0.25) / 0.25)))


def credits_frame(t):
    im = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(im)
    rows = [
        ('كهربا', F(LALEZAR, 130), GOLD, 300),
        ('KAHRABA · a Beirut power-cut ghost story', F(PLEX_SB, 30), CREAM, 430),
        ('Rive CLI · RML · Luau scripting · WGSL GPU canvas · data binding · state machines', F(PLEX, 24), MUTED, 500),
        ('github.com/taktekhq/kahraba    ·    taktek.io/kahraba', F(PLEX, 24), MUTED, 600),
        ('@rive_app  #rivehalloweenchallenge', F(PLEX, 24), GOLD, 650),
        ('Taktek · Beirut', F(PLEX, 20), DIM, 900),
    ]
    for txt, font, col, y in rows:
        d.text((W // 2, y), txt, font=font, fill=col, anchor='mm')
    return fade_black(im, ease(t / 0.35) * (1 - ease((t - film.CRED_DUR + 0.4) / 0.4)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--frames', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--audio')
    a = ap.parse_args()

    def seq(name):
        dn = os.path.join(a.frames, name)
        return dn, len([f for f in os.listdir(dn) if f.endswith('.png') and '.tmp' not in f])

    def frame(dn, i):
        return Image.open(os.path.join(dn, f'f{i:05d}.png')).convert('RGB')

    main_dir, n_main = seq('main')
    dead_dir, n_dead = seq('dead')
    alb = frame(seq('albedo')[0], 0)
    emi = frame(seq('emit')[0], 0)
    lit = frame(main_dir, int(round((film.BREAK_FILM - film.PIECE_START) * FPS)))
    shot = Image.open(os.path.join(ROOT, 'tools', 'session', 'albedo.png')).convert('RGB')
    mono = ImageFont.truetype(MONO, 19)
    sched = film.term_schedule()

    ff = subprocess.Popen(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24',
                           '-s', f'{W}x{H}', '-r', str(FPS), '-i', '-']
                          + (['-i', a.audio, '-c:a', 'aac', '-b:a', '160k', '-shortest'] if a.audio else [])
                          + ['-c:v', 'libx264', '-preset', 'slow', '-crf', '23', '-maxrate', '4800k',
                             '-bufsize', '9600k', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', a.out],
                          stdin=subprocess.PIPE)

    def emit(im):
        ff.stdin.write(im.tobytes())

    # 1. the piece
    track = torch_track(film.PIECE_END + 1)
    for i in range(n_main):
        t = film.PIECE_START + i / FPS
        im = frame(main_dir, i)
        ti = min(len(track) - 1, max(0, int(round(t * 60)) - 1))
        px, py = to_px(*track[ti])
        im = draw_pointer(im, px + 10, py + 10, pointer_alpha(t))
        im = chip(im, 'interactive  ·  your pointer is the phone light',
                  ease((t - 7.6) / 0.3) * (1 - ease((t - 10.2) / 0.3)))
        im = fade_black(im, ease((t - film.PIECE_START) / 0.3))
        emit(im)

    # 2. the other ending
    for i in range(n_dead):
        t = i / FPS
        im = frame(dead_dir, i)
        im = chip(im, '…or keep the light on until the battery dies', ease(t / 0.3) * (1 - ease((t - 2.4) / 0.3)))
        im = fade_black(im, ease(t / 0.2) * (1 - ease((t - (n_dead / FPS - 0.25)) / 0.25)))
        emit(im)

    # 3, 4, 5
    for i in range(int(film.BREAK_DUR * FPS)):
        emit(breakdown_frame(i / FPS, alb, emi, lit))
    for i in range(int(film.TERM_DUR * FPS)):
        emit(terminal_frame(i / FPS, sched, shot, mono))
    for i in range(int(film.CRED_DUR * FPS)):
        emit(credits_frame(i / FPS))

    ff.stdin.close()
    ff.wait()
    print('wrote', a.out)


if __name__ == '__main__':
    main()
