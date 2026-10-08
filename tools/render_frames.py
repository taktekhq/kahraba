#!/usr/bin/env python3
"""Renders an image sequence of the scene with the Rive CLI, headless.

The CLI captures one frame per run (`--screenshot` after `--advance`), and the
scene is deterministic (fixed 60 fps steps, hashed randomness), so frame i is
a fresh run advanced to t = start + i / fps. Runs go in parallel, each worker
in its own copy of the project so builds don't collide. Existing frames are
skipped, so an interrupted render resumes.

    python3 tools/render_frames.py --out /tmp/frames/main --start 0 --end 40 \
        --data autoplay=1 --data quality=1.25 --viewport 1600x1000 --jobs 8

Then: ffmpeg -framerate 30 -i /tmp/frames/main/f%05d.png ...
"""
import argparse
import os
import shutil
import subprocess
import sys
import threading
import queue

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = ['scene.rml', 'main.luau', 'light.wgsl', 'rive.yaml',
       'Lalezar-Regular.ttf', 'IBMPlexSansArabic-Regular.ttf', 'IBMPlexSansArabic-SemiBold.ttf']


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    ap.add_argument('--start', type=float, default=0)
    ap.add_argument('--end', type=float, required=True)
    ap.add_argument('--fps', type=int, default=30)
    ap.add_argument('--data', action='append', default=[])
    ap.add_argument('--viewport', default='1600x1000')
    ap.add_argument('--jobs', type=int, default=8)
    ap.add_argument('--work', default='/tmp/kahraba-render')
    a = ap.parse_args()

    os.makedirs(a.out, exist_ok=True)
    rive = shutil.which('rive') or os.path.expanduser('~/.rive/bin/rive')
    n = int(round((a.end - a.start) * a.fps))
    todo = queue.Queue()
    for i in range(n):
        path = os.path.join(a.out, f'f{i:05d}.png')
        if not os.path.exists(path):
            todo.put((i, path))
    total = todo.qsize()
    print(f'{total} of {n} frames to render', flush=True)
    done = [0]
    lock = threading.Lock()

    def worker(k):
        wd = os.path.join(a.work, f'w{k}')
        os.makedirs(wd, exist_ok=True)
        for f in SRC:
            shutil.copy(os.path.join(ROOT, f), wd)
        while True:
            try:
                i, path = todo.get_nowait()
            except queue.Empty:
                return
            t = a.start + i / a.fps
            adv = max(1, int(round(t * 60)))
            tmp = path + '.tmp.png'
            cmd = [rive, '.', f'--screenshot={tmp}', f'--viewport={a.viewport}', '--fit=contain', '--quiet']
            cmd += [f'--data={d}' for d in a.data]
            cmd += [f'--advance={adv}']
            # surfaceless EGL: picks the iGPU even when another DRM device is wedged
            env = dict(os.environ, EGL_PLATFORM=os.environ.get('EGL_PLATFORM', 'surfaceless'))
            r = subprocess.run(cmd, cwd=wd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            if r.returncode == 0 and os.path.exists(tmp):
                os.replace(tmp, path)
            else:
                print(f'frame {i} failed: {r.stderr.decode()[-300:]}', file=sys.stderr, flush=True)
            with lock:
                done[0] += 1
                if done[0] % 25 == 0:
                    print(f'{done[0]}/{total}', flush=True)

    threads = [threading.Thread(target=worker, args=(k,)) for k in range(a.jobs)]
    for th in threads:
        th.start()
    for th in threads:
        th.join()
    print('done', flush=True)


if __name__ == '__main__':
    main()
