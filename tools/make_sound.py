#!/usr/bin/env python3
"""Synthesises the video's soundtrack, cued to the film's own timeline.

Nothing sampled: hum, traffic, the cut's thunk, sparks, wind, a riser while
the light rests on a jinn, a stinger for each catch, Abu Ali's generator
coughing into a rumble, and a short phrase in maqam Hijaz plucked on a
Karplus-Strong string for the ending.

    ~/venvs/pw/bin/python tools/make_sound.py --out /tmp/kahraba.wav
"""
import argparse
import wave

import numpy as np

SR = 44100
rng = np.random.default_rng(7)

# the video's timeline (seconds), see make_video.py
T_MAIN = 3.2 + 1.8 + 4 * 4.4          # the piece starts here
T_DEAD = T_MAIN + 40.5
T_CREDITS = T_DEAD + 6.0
TOTAL = T_CREDITS + 4.6
CUT = 7.0                              # film time of the cut
CATCHES = [10.9, 14.4, 18.8, 22.3, 25.8, 29.3]
DIES = 73.67 - 72.5                    # dead clip: the battery dies
MOTEUR_DEAD = 76.27 - 72.5


def t_axis(n):
    return np.arange(n) / SR


def noise(n):
    return rng.standard_normal(n)


def lowpass(x, cutoff):
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i in range(len(x)):
        acc = (1 - a) * x[i] + a * acc
        y[i] = acc
    return y


def lp_fast(x, cutoff):
    # one-pole lowpass via cumulative trick on blocks (good enough for beds)
    k = max(1, int(SR / cutoff / 2))
    kernel = np.ones(k) / k
    return np.convolve(x, kernel, mode='same')


def env(n, a, d):
    t = t_axis(n)
    e = np.minimum(1, t / max(a, 1e-4)) * np.exp(-np.maximum(0, t - a) / max(d, 1e-4))
    return e


class Mix:
    def __init__(self, seconds):
        self.buf = np.zeros((int(seconds * SR) + SR, 2))

    def add(self, at, mono, gain=1.0, pan=0.0):
        i = int(at * SR)
        n = min(len(mono), len(self.buf) - i)
        if n <= 0:
            return
        l = np.sqrt(0.5 * (1 - pan))
        r = np.sqrt(0.5 * (1 + pan))
        self.buf[i:i + n, 0] += mono[:n] * gain * l
        self.buf[i:i + n, 1] += mono[:n] * gain * r


def drone(seconds, root=55.0, dark=1.0):
    n = int(seconds * SR)
    t = t_axis(n)
    x = (np.sin(2 * np.pi * root * t) + 0.6 * np.sin(2 * np.pi * root * 1.498 * t + 0.3)
         + 0.35 * np.sin(2 * np.pi * root * 2.003 * t) + 0.25 * np.sin(2 * np.pi * root * 1.189 * t) * dark)
    trem = 0.75 + 0.25 * np.sin(2 * np.pi * 0.13 * t)
    fade = np.minimum(1, t / 1.5) * np.minimum(1, (seconds - t) / 1.0)
    return x * trem * fade * 0.25


def hum(seconds):
    n = int(seconds * SR)
    t = t_axis(n)
    return (np.sin(2 * np.pi * 50 * t) * 0.5 + np.sin(2 * np.pi * 100 * t) * 0.3 + np.sin(2 * np.pi * 150 * t) * 0.12) * 0.12


def traffic(seconds):
    n = int(seconds * SR)
    t = t_axis(n)
    x = lp_fast(noise(n), 300) * (0.6 + 0.4 * np.sin(2 * np.pi * 0.07 * t))
    return x * 0.35


def horn(dur=0.32, f=420):
    n = int(dur * SR)
    t = t_axis(n)
    x = np.sign(np.sin(2 * np.pi * f * t)) * 0.3 + np.sin(2 * np.pi * f * 1.26 * t) * 0.4
    return lp_fast(x, 2500) * env(n, 0.01, 0.25) * 0.25


def thunk():
    n = int(1.2 * SR)
    t = t_axis(n)
    f = 70 * np.exp(-t * 3) + 30
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 4)
    return x * 0.9 + lp_fast(noise(n), 800) * np.exp(-t * 20) * 0.5


def crackle(dur=0.5, density=120):
    n = int(dur * SR)
    x = np.zeros(n)
    for _ in range(int(density * dur)):
        i = rng.integers(0, max(1, n - 400))
        L = rng.integers(40, 400)
        x[i:i + L] += noise(L) * np.exp(-np.arange(L) / (L / 4)) * rng.uniform(0.3, 1)
    return x * 0.35


def buzz(dur):
    n = int(dur * SR)
    t = t_axis(n)
    gate = (rng.random(int(dur * 11) + 1) > 0.45).repeat(SR // 11 + 1)[:n]
    return (np.sign(np.sin(2 * np.pi * 100 * t)) * 0.15) * gate * 0.5


def wind(seconds):
    n = int(seconds * SR)
    t = t_axis(n)
    x = lp_fast(noise(n), 500) - lp_fast(noise(n), 120) * 0.5
    sweep = 0.5 + 0.5 * np.sin(2 * np.pi * 0.09 * t) * np.sin(2 * np.pi * 0.031 * t + 1)
    fade = np.minimum(1, t / 2.0) * np.minimum(1, (seconds - t) / 1.0)
    return x * sweep * fade * 0.5


def riser(dur=0.9):
    n = int(dur * SR)
    t = t_axis(n)
    f = 220 * (2 ** (t / dur * 1.5))
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) + 0.5 * np.sin(2 * np.pi * np.cumsum(f * 1.06) / SR)
    return x * (t / dur) ** 2 * 0.12


def stinger(base=110):
    n = int(1.8 * SR)
    t = t_axis(n)
    chord = [1, 1.06, 1.5, 2.12, 2.83]
    x = sum(np.sin(2 * np.pi * base * c * t + i) for i, c in enumerate(chord))
    hiss = lp_fast(noise(n), 4000) * np.exp(-t * 6) * 0.6
    return (x * env(n, 0.005, 0.7) * 0.18 + hiss * 0.4)


def meow():
    n = int(0.55 * SR)
    t = t_axis(n)
    f = 520 + 260 * np.sin(np.pi * t / 0.55) - 120 * t
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) + 0.4 * np.sin(4 * np.pi * np.cumsum(f) / SR)
    vib = 1 + 0.05 * np.sin(2 * np.pi * 7 * t)
    return x * vib * np.sin(np.pi * t / 0.55) ** 0.6 * 0.18


def generator(seconds, cough=0.6):
    n = int(seconds * SR)
    t = t_axis(n)
    f0 = 27.0
    saw = 2 * ((t * f0) % 1) - 1
    pulse = (np.sin(2 * np.pi * f0 * t) > 0.6).astype(float)
    eng = lp_fast(saw * 0.6 + pulse * 0.8 + noise(n) * 0.15, 400)
    am = 0.85 + 0.15 * np.sin(2 * np.pi * 3.1 * t)
    start = np.clip((t - cough) / 0.8, 0, 1)
    coughs = np.zeros(n)
    for k, c in enumerate([0.05, 0.2, 0.38, 0.52]):
        i = int(c * SR)
        L = int(0.09 * SR)
        coughs[i:i + L] += lp_fast(noise(L), 600) * np.exp(-np.arange(L) / (L / 3)) * 1.4
    fade = np.minimum(1, (seconds - t) / 1.2)
    return (eng * am * start * 0.9 + coughs) * fade * 0.55


def ks_pluck(freq, dur=1.6, bright=0.5):
    n = int(dur * SR)
    p = int(SR / freq)
    buf = rng.uniform(-1, 1, p) * bright + rng.uniform(-1, 1, p) * (1 - bright) * 0.3
    out = np.empty(n)
    for i in range(n):
        j = i % p
        out[i] = buf[j]
        buf[j] = 0.996 * 0.5 * (buf[j] + buf[(j + 1) % p])
    return out * 0.5


def hijaz(mix, at, gain=0.8):
    # D Eb F# G A, G F# Eb D: the sound of every old Arabic ghost film
    d = 146.83
    steps = [1, 16 / 15, 5 / 4, 4 / 3, 3 / 2, 4 / 3, 5 / 4, 16 / 15, 1]
    times = [0, 0.28, 0.56, 0.84, 1.12, 1.6, 1.82, 2.04, 2.3]
    for s, tt in zip(steps, times):
        mix.add(at + tt, ks_pluck(d * s, 1.8), gain, pan=-0.2 + 0.4 * (s - 1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    m = Mix(TOTAL)

    # title + how it is made: a low drone, keys while the code is typed
    m.add(0, drone(T_MAIN + 0.5, 55, 0.6), 0.8)
    for s in range(4):
        st = 3.2 + 1.8 + s * 4.4
        tt = st + 0.1
        while tt < st + 3.0:
            L = int(0.025 * SR)
            click = lp_fast(noise(L), 3000) * np.exp(-np.arange(L) / 200)
            m.add(tt, click, 0.25, pan=rng.uniform(-0.3, 0.3))
            tt += rng.uniform(0.06, 0.16)

    # the piece: 8 PM, the city with power
    M = T_MAIN
    m.add(M, hum(CUT), 1.0)
    m.add(M, traffic(CUT + 0.2), 0.9)
    m.add(M + 2.1, horn(0.3, 410), 1.0, pan=-0.6)
    m.add(M + 2.5, horn(0.18, 410), 1.0, pan=-0.6)
    m.add(M + 4.3, horn(0.5, 350), 0.6, pan=0.7)
    m.add(M + 5.6, buzz(1.4), 0.6)
    # the cut
    m.add(M + CUT, thunk(), 0.6)
    m.add(M + CUT, crackle(0.6, 160), 0.8, pan=-0.5)
    # the dark
    m.add(M + CUT, wind(22.5 + 1.0), 0.9)
    m.add(M + CUT, drone(23.5, 41.2, 1.0), 0.9)
    for k, c in enumerate(CATCHES):
        m.add(M + c - 0.9, riser(0.9), 1.0)
        if k == 5:
            m.add(M + c, meow(), 1.0, pan=-0.4)
        else:
            m.add(M + c, stinger(98 + k * 7), 1.7, pan=rng.uniform(-0.3, 0.3))
    for s in [9.8, 16.9, 24.6]:
        m.add(M + s, crackle(0.35, 100), 0.6, pan=-0.6)
    # the moteur and the ending
    m.add(M + CATCHES[-1], generator(40.5 - CATCHES[-1]), 1.0, pan=-0.35)
    m.add(M + CATCHES[-1] + 0.6, crackle(0.4, 140), 0.6, pan=-0.5)
    hijaz(m, M + 33.2, 1.5)

    # the other ending
    D = T_DEAD
    m.add(D, wind(6.2), 0.8)
    m.add(D, drone(6.2, 36.7, 1.0), 1.0)
    n = int(1.4 * SR)
    t = t_axis(n)
    down = np.sin(2 * np.pi * np.cumsum(600 * np.exp(-t * 2.2) + 40) / SR) * np.exp(-t * 1.2) * 0.2
    m.add(D + DIES, down, 1.0)
    m.add(D + DIES + 0.2, stinger(73), 1.2)
    m.add(D + MOTEUR_DEAD, generator(6.0 - MOTEUR_DEAD + 0.3, 0.5), 1.0, pan=-0.35)

    # credits
    m.add(T_CREDITS, drone(4.6, 73.4, 0.3), 0.6)
    hijaz(m, T_CREDITS + 0.4, 1.2)

    buf = m.buf[: int(TOTAL * SR)]
    buf = buf / max(1e-6, np.percentile(np.abs(buf), 99.9))
    buf = np.tanh(buf * 0.9) * 0.89
    pcm = (buf * 32767).astype('<i2')
    with wave.open(a.out, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print('wrote', a.out, f'{TOTAL:.1f}s')


if __name__ == '__main__':
    main()
