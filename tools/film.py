"""The submission film's timeline, shared by make_video.py and make_sound.py.

Film time = the scene's own clock (seconds since the file starts playing).
Video time = seconds into kahraba.mp4.

  piece      film 2.5 .. 36.9   opens on the lit street, the cut lands at 4.5 s,
                                six catches with close-ups, the moteur ending,
                                the end card held 2 s
  dead       film 39.6 .. 44.6  the other ending: the battery dies
  breakdown  3 s                the script's two buffers beside the lit result
  terminal   7 s                a real session: the diff, verify, a screenshot run
  credits    3 s
"""
import os

FPS = 30

PIECE_START, PIECE_END = 2.5, 36.9
DEAD_START, DEAD_END = 39.6, 44.6
BREAK_DUR = 3.0
TERM_DUR = 7.0
CRED_DUR = 3.0
BREAK_FILM = 17.2          # the moment the breakdown takes apart

# story beats, film time (from `rive . --data-dump` on the demo path)
CUT = 7.0
CATCHES = [10.9, 14.383, 18.783, 22.3, 25.8, 29.283]
REACT = 0.85               # main.luau: anticipation, stretch, shake, then the flee
CLOSE = 1.6                # main.luau: the close-up's hold
MOTEUR = 29.283 + CLOSE    # the ending starts when the last close-up lets go
END_CARD = MOTEUR + 190 / 60
DIES = 40.33               # 100 % at the cut, 3 % a second
MOTEUR_DEAD = DIES + 2.6

# video time of each part
V_PIECE = 0.0
V_DEAD = V_PIECE + (PIECE_END - PIECE_START)
V_BREAK = V_DEAD + (DEAD_END - DEAD_START)
V_TERM = V_BREAK + BREAK_DUR
V_CRED = V_TERM + TERM_DUR
TOTAL = V_CRED + CRED_DUR


def piece_v(film_t):
    return film_t - PIECE_START + V_PIECE


def dead_v(film_t):
    return film_t - DEAD_START + V_DEAD


# ---- the terminal session: a real capture (tools/session/session.txt), replayed
SESSION = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'session', 'session.txt')
TYPE_CPS = 55              # characters a second while a command is typed
LINE_GAP = 0.035           # output lines arrive this far apart
PAUSE = 0.25               # after a command's output, before the next prompt


def term_schedule():
    """[(t, kind, text)] relative to the terminal part. kind: 'cmd' (typed from
    t at TYPE_CPS) or 'out' (appears at t)."""
    ev = []
    t = 0.3
    for line in open(SESSION, encoding='utf-8').read().splitlines():
        if line.startswith('$ '):
            t += PAUSE
            ev.append((t, 'cmd', line))
            t += len(line) / TYPE_CPS + 0.15
        else:
            ev.append((t, 'out', line))
            t += LINE_GAP
    return ev
