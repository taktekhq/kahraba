#!/usr/bin/env python3
"""Cuts the submission video from rendered frames.

  1. title card
  2. how it is made: the RML, the Luau and the WGSL typed out beside what each
     one draws, then the CLI loop in a terminal
  3. the interactive piece, frame-rendered headless by tools/render_frames.py,
     with the pointer drawn where the scripted torch path puts it
  4. the other ending (the battery dies)
  5. credits

    python3 tools/make_video.py --main /tmp/frames/main --dead /tmp/frames/dead \
        --out media/kahraba.mp4
"""
import argparse
import math
import os
import subprocess

from PIL import Image, ImageDraw, ImageFilter, ImageFont
from pygments.lexers import get_lexer_by_name
from pygments.token import Token

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
W, H, FPS = 1600, 1000, 30
BG = (10, 12, 18)
PANEL = (17, 20, 28)
GOLD = (255, 200, 97)
CREAM = (242, 232, 213)
MUTED = (185, 179, 166)
DIM = (110, 106, 98)

MONO = '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf'
F = lambda name, size: ImageFont.truetype(os.path.join(ROOT, name), size)
LALEZAR = 'Lalezar-Regular.ttf'
PLEX = 'IBMPlexSansArabic-Regular.ttf'
PLEX_SB = 'IBMPlexSansArabic-SemiBold.ttf'

SYNTAX = [
    (Token.Comment, (120, 128, 112)),
    (Token.Keyword, (255, 140, 110)),
    (Token.Name.Tag, (255, 140, 110)),
    (Token.Name.Attribute, (255, 200, 97)),
    (Token.Literal.String, (160, 220, 150)),
    (Token.Literal.Number, (190, 160, 255)),
    (Token.Name.Builtin, (120, 200, 255)),
    (Token.Name.Function, (120, 200, 255)),
    (Token.Operator, (220, 200, 180)),
]


def colour(tt):
    for base, c in SYNTAX:
        if tt in base:
            return c
    return CREAM


# ---- the code shown, verbatim excerpts from the project (lightly trimmed)
RML = '''<!-- the Cards layer: one state per jinn found, -->
<!-- driven by the view model number `found` -->
<StateMachineLayer name="Cards" id="0:503">
  <AnimationState animationId="0:620" reset="true" id="0:540">
    <StateTransition stateToId="0:541">
      <TransitionViewModelCondition opValue="equal">
        <TransitionPropertyViewModelComparator>
          <BindablePropertyNumber>
            <DataBindContext sourcePathIds="0:900-0:909"
                             propertyKey="636"/>
          </BindablePropertyNumber>
        </TransitionPropertyViewModelComparator>
        <TransitionValueNumberComparator value="1"/>
      </TransitionViewModelCondition>
    </StateTransition>
  </AnimationState>
<!-- the card slides in and settles like a sticker -->
<LinearAnimation fps="60" duration="200" name="Card 1">
  <KeyedObject objectId="0:300"><KeyedProperty propertyKey="13">
    <KeyFrameDouble value="4" frame="0" interpolationType="elastic">
      <ElasticInterpolator amplitude="0.6" period="0.35"/>
    </KeyFrameDouble>
    <KeyFrameDouble value="34" frame="34"/>'''

LUAU = '''-- each jinn answers the light in its own way
if c.kind == 'ghoul' then
    -- crouched on the parapet; lit, it rears up
    -- and throws its claws over its head
    local rise = -10 * h
    local body = part(nil, 0)
    poly(body, { -9, 16, -14, 0 + rise, -16, -10 + rise,
                 -6, -17 + rise, 6, -17 + rise, 16, -10 + rise })
    ell(body, 0, -28 + rise, 11, 13)
    local arms = part(nil, 4.5)
    local lhx = lerp(-23, -42, h) + sw
    local lhy = lerp(31, -50, h) + rise
    limb(arms, -15, -8 + rise, lex, ley, lhx, lhy)
elseif c.kind == 'qarina' then
    -- your twin steps the other way, and lit,
    -- she lifts her own phone at you
    local ox = (640 - self.torch.x) * 0.03
    ...
-- the torch has to rest on one to catch it
if d < c.r + reach * 0.35 then
    c.dwell += dt
    if c.dwell > DWELL then catch(self, c) end
end'''

WGSL = '''// the phone torch: a hot centre, a soft ring
let d = length(px - u.torch);
let r = max(u.reach, 1.0);
let core = smoothstep(r, r * 0.15, d);
let ring = smoothstep(r * 1.05, r * 0.9, d)
         * smoothstep(r * 0.7, r * 0.92, d) * 0.25;
let torch = (core * core * 0.85 + core * 0.4 + ring)
          * u.torchOn;

// moonlight in the cut, sodium glow while
// the city still has power
var ambient = mix(cityLit, moonDark, u.dark);
let spill = near * (0.28 + 0.2 * u.dark)
          + far * (0.18 + 0.5 * u.dark);
var col = alb.rgb * (ambient + spill + torch * torchCol);
col = col + skyCol * sky;          // sky where nothing is drawn
col = col + em * (0.9 + 0.1 * u.lights);

// fog rolling down the street, lit by the torch
let fogN = fbm(fp + vec2(fbm(fp * 0.7 + t * 0.03) * 1.6, 0.0));'''

TERM = '''$ python3 tools/gen_scene.py && rive kahraba --verify
scene.rml written
rive  verified (0 errors, 0 warnings)

$ rive kahraba --screenshot=shots/hunt.png \\
      --data=autoplay=1 --advance=1110
rive  showing Kahraba [1/1]
rive  wrote shots/hunt.png

$ rive kahraba --data-dump=- --data-dump-every=6 \\
      --data-dump-filter=found,phase --data=autoplay=1
{"time": 7.0,  "values": [{"path": "phase", "value": 1}]}
{"time": 10.9, "values": [{"path": "found", "value": 1}]}
{"time": 14.4, "values": [{"path": "found", "value": 2}]}
...
{"time": 29.3, "values": [{"path": "phase", "value": 3}]}'''


def ease(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def tokens(code, lang):
    lexer = get_lexer_by_name(lang)
    out = []
    for tt, val in lexer.get_tokens(code):
        out.append((val, colour(tt)))
    return out


def code_frame(code_toks, nchars, title, subtitle, preview, label, step, font):
    im = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(im)
    # heading
    d.text((64, 46), title, font=F(PLEX_SB, 34), fill=CREAM)
    d.text((64, 92), subtitle, font=F(PLEX, 22), fill=MUTED)
    d.text((W - 64, 52), step, font=F(PLEX_SB, 18), fill=GOLD, anchor='ra')
    # code panel
    px, py, pw, ph = 48, 150, 960, 800
    d.rounded_rectangle((px, py, px + pw, py + ph), 18, fill=PANEL)
    for k, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        d.ellipse((px + 22 + k * 22, py + 20, px + 34 + k * 22, py + 32), fill=c)
    x0, y0 = px + 28, py + 58
    lh = 30
    x, y = x0, y0
    left = nchars
    line = 1
    d.text((x0 - 4, y), '', font=font)
    for val, col in code_toks:
        for ch in val:
            if left <= 0:
                break
            if ch == '\n':
                x = x0
                y += lh
                line += 1
            else:
                d.text((x, y), ch, font=font, fill=col)
                x += font.getlength(ch)
            left -= 1
        if left <= 0:
            break
    # caret
    if (step and int(nchars / 6) % 2 == 0) or nchars < sum(len(v) for v, _ in code_toks):
        d.rectangle((x + 1, y + 3, x + 11, y + 24), fill=GOLD)
    # preview
    if preview is not None:
        pv = preview.copy()
        pv.thumbnail((540, 680))
        qx = 1040 + (520 - pv.width) // 2
        qy = 150
        im.paste(pv, (qx, qy))
        d.rounded_rectangle((qx - 1, qy - 1, qx + pv.width, qy + pv.height), 10, outline=(60, 62, 72), width=2)
        ty = qy + pv.height + 22
        for ln in label.split('\n'):
            d.text((1040, ty), ln, font=F(PLEX, 20), fill=MUTED)
            ty += 30
    return im


def card(lines, bg=None, alpha=1.0):
    im = Image.new('RGB', (W, H), BG) if bg is None else bg.copy()
    d = ImageDraw.Draw(im)
    for (txt, font, col, y) in lines:
        d.text((W // 2, y), txt, font=font, fill=col, anchor='mm')
    if alpha < 1:
        im = Image.blend(Image.new('RGB', (W, H), (0, 0, 0)), im, alpha)
    return im


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


def draw_pointer(im, x, y, a):
    if a <= 0.01:
        return im
    layer = Image.new('RGBA', im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    pts = [(0, 0), (0, 26), (7, 20), (12, 31), (17, 29), (12, 18), (21, 18)]
    s = 1.0
    poly = [(x + px * s, y + py * s) for px, py in pts]
    d.polygon([(px + 2, py + 2) for px, py in poly], fill=(0, 0, 0, int(110 * a)))
    d.polygon(poly, fill=(255, 255, 255, int(255 * a)), outline=(20, 20, 24, int(255 * a)))
    base = im.convert('RGBA')
    base.alpha_composite(layer)
    return base.convert('RGB')


def chip(im, text, a, y=56):
    if a <= 0.01:
        return im
    layer = Image.new('RGBA', im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    f = F(PLEX_SB, 19)
    w = f.getlength(text) + 44
    cx = 712
    d.rounded_rectangle((cx - w / 2, y - 22, cx + w / 2, y + 22), 22, fill=(10, 12, 18, int(225 * a)),
                        outline=(255, 200, 97, int(120 * a)), width=1)
    d.text((cx, y), text, font=f, fill=(255, 200, 97, int(255 * a)), anchor='mm')
    base = im.convert('RGBA')
    base.alpha_composite(layer)
    return base.convert('RGB')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--main', required=True)
    ap.add_argument('--dead', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--audio')
    a = ap.parse_args()

    def frame(dirn, i):
        return Image.open(os.path.join(dirn, f'f{i:05d}.png')).convert('RGB')

    n_main = len([f for f in os.listdir(a.main) if f.endswith('.png') and '.tmp' not in f])
    n_dead = len([f for f in os.listdir(a.dead) if f.endswith('.png') and '.tmp' not in f])

    ff = subprocess.Popen(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24',
                           '-s', f'{W}x{H}', '-r', str(FPS), '-i', '-']
                          + (['-i', a.audio, '-c:a', 'aac', '-b:a', '160k', '-shortest'] if a.audio else [])
                          + ['-c:v', 'libx264', '-preset', 'slow', '-crf', '23', '-maxrate', '4800k', '-bufsize', '9600k', '-pix_fmt', 'yuv420p',
                           '-movflags', '+faststart', a.out], stdin=subprocess.PIPE)

    def emit(im):
        ff.stdin.write(im.tobytes())

    # 1. title over the lit street
    street = frame(a.main, 90).filter(ImageFilter.GaussianBlur(6))
    street = Image.blend(Image.new('RGB', (W, H), BG), street, 0.42)
    for i in range(int(3.2 * FPS)):
        t = i / FPS
        al = ease(t / 0.6) * (1 - ease((t - 2.8) / 0.4))
        emit(card([
            ('كهربا', F(LALEZAR, 210), GOLD, 360),
            ('KAHRABA', F(LALEZAR, 70), CREAM, 520),
            ('a Beirut power-cut ghost story', F(PLEX, 32), MUTED, 590),
            ('Rive Halloween Challenge  ·  made with the Rive CLI', F(PLEX, 22), DIM, 880),
        ], bg=street, alpha=al))

    # 2. how it is made
    mono = ImageFont.truetype(MONO, 19)
    for i in range(int(1.8 * FPS)):
        t = i / FPS
        al = ease(t / 0.4) * (1 - ease((t - 1.4) / 0.4))
        emit(card([
            ('How it is made', F(PLEX_SB, 44), CREAM, 440),
            ('Written as RML, Luau and WGSL, built and rendered with the Rive CLI.', F(PLEX, 26), MUTED, 510),
        ], alpha=al))
    previews = {
        'rml': frame(a.main, 336).crop((0, 100, 1000, 720)),
        'luau': frame(a.main, 318).crop((330, 40, 830, 440)),
        'wgsl': frame(a.main, 555).crop((520, 380, 1080, 860)),
        'term': frame(a.main, 330),
    }
    segs = [
        (RML, 'xml', 'scene.rml', 'State machine + data binding: the story, the cards, the switch', 'rml',
         'Cards layer: the script counts a catch,\nthe view model says found = 1,\nthe card slides in with an elastic key.', '1 / 4'),
        (LUAU, 'lua', 'main.luau', 'Scripting: a Layout script draws the street and runs the story', 'luau',
         'The ghoul, lit: it rears up, ears back,\narms over its head, mouth open.', '2 / 4'),
        (WGSL, 'wgsl', 'light.wgsl', 'GPU Canvas: one WGSL pass lights the whole street', 'wgsl',
         'Albedo + emission from the script,\nlit by your phone torch, moon and fog.', '3 / 4'),
        (TERM, 'bash', 'terminal', 'The loop: verify, screenshot, dump the data, repeat', 'term',
         'Every still and every video frame is\nrive --screenshot, rendered headless.', '4 / 4'),
    ]
    for code, lang, title, sub, pkey, label, step in segs:
        toks = tokens(code, lang)
        total = sum(len(v) for v, _ in toks)
        dur = 4.4
        for i in range(int(dur * FPS)):
            t = i / FPS
            n = int(total * ease(t / 3.0)) if t < 3.0 else total + int(t * 30)
            emit(code_frame(toks, n, title, sub, previews[pkey], label, step, mono))

    # 3. the piece
    track = torch_track(45)
    for i in range(n_main):
        t = i / FPS
        im = frame(a.main, i)
        ti = min(len(track) - 1, max(0, int(round(t * 60)) - 1))
        tx, ty = track[ti]
        px, py = to_px(tx, ty)
        pa = ease((t - 7.0) / 0.4) * (1 - ease((t - 29.6) / 0.6))
        im = draw_pointer(im, px + 10, py + 10, pa)
        im = chip(im, 'interactive  ·  your pointer is the phone light', ease((t - 7.4) / 0.4) * (1 - ease((t - 11.6) / 0.4)))
        im = chip(im, 'the state power cuts by itself, it always does', ease((t - 5.0) / 0.3) * (1 - ease((t - 6.9) / 0.3)))
        if t < 0.5:
            im = Image.blend(Image.new('RGB', (W, H), (0, 0, 0)), im, ease(t / 0.5))
        emit(im)

    # 4. the other ending
    for i in range(n_dead):
        t = i / FPS
        im = frame(a.dead, i)
        im = chip(im, '…or keep the light on too long', ease(t / 0.3) * (1 - ease((t - 2.6) / 0.3)))
        if t < 0.3:
            im = Image.blend(Image.new('RGB', (W, H), (0, 0, 0)), im, ease(t / 0.3))
        emit(im)

    # 5. credits
    end = frame(a.main, n_main - 1).filter(ImageFilter.GaussianBlur(8))
    end = Image.blend(Image.new('RGB', (W, H), BG), end, 0.35)
    for i in range(int(4.6 * FPS)):
        t = i / FPS
        al = ease(t / 0.5) * (1 - ease((t - 4.1) / 0.5))
        emit(card([
            ('كهربا', F(LALEZAR, 120), GOLD, 300),
            ('Rive CLI  ·  RML  ·  Luau scripting  ·  WGSL GPU canvas', F(PLEX_SB, 30), CREAM, 450),
            ('data binding  ·  state machine  ·  Arabic + English type', F(PLEX_SB, 30), CREAM, 500),
            ('github.com/taktekhq/kahraba', F(PLEX, 26), MUTED, 610),
            ('@rive_app  #rivehalloweenchallenge', F(PLEX, 26), GOLD, 660),
            ('Taktek · Beirut', F(PLEX, 20), DIM, 900),
        ], bg=end, alpha=al))

    ff.stdin.close()
    ff.wait()
    print('wrote', a.out)


if __name__ == '__main__':
    main()
