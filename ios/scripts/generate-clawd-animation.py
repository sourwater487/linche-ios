#!/usr/bin/env python3
"""Author compact pixel frames shared by UIKit and an offline canvas preview.
No downloaded artwork, image engine, browser dependency or network is required.
Pose reference: https://github.com/JohnHeibel/ClaudeAnimationBase (MIT).
These rectangle frames are authored here; no reference artwork is bundled.
"""
import argparse
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FPS = 30
COLORS = ['#85817b', '#d67557', '#1f1a17', '#c7b5ba', '#cec6ae', '#b5bfaf', '#dd5b58', '#aaa7a0', '#edac86']


def ease(t):
    t = max(0, min(1, t))
    return t * t * (3 - 2 * t)


def rect(frame, x, y, w, h, color, alpha=1, angle=0):
    if alpha > .005:
        frame.append([round(v, 2) for v in [x, y, w, h, angle, color, alpha]])


def sprite(frame, x=0, y=-20, sx=1, sy=1, angle=0, pose='walk', hand_lift=None):
    # Original Clawd: 5 pt pixels, 9 x 6 body, 11 x 8 overall silhouette.
    # Expressions change inside that body; they must not widen/flatten it.
    blocks = [(1, 0, 9, 6, 1)]
    for foot in [1, 3, 7, 9]:
        blocks.append((foot, 6, 1, 2, 1))
    if pose == 'happy':
        for eye in [2, 7]:
            blocks += [(eye, 2.5, .5, .5, 2), (eye + .5, 2, .5, .5, 2), (eye + 1, 2.5, .5, .5, 2)]
    elif pose == 'hurt':
        for eye in [2, 7]:
            blocks += [(eye, 2, .5, .5, 2), (eye + 1, 2, .5, .5, 2), (eye + .5, 2.5, .5, .5, 2), (eye, 3, .5, .5, 2), (eye + 1, 3, .5, .5, 2)]
    else:
        blocks += [(2, 2, 1, 1, 2), (8, 2, 1, 1, 2)]
    rad = math.radians(angle)
    for bx, by, bw, bh, color in blocks:
        dx, dy = (bx + bw / 2 - 5.5) * 5 * sx, (by + bh / 2 - 4) * 5 * sy
        rect(frame, x + dx * math.cos(rad) - dy * math.sin(rad), y + dx * math.sin(rad) + dy * math.cos(rad), bw * 5 * sx, bh * 5 * sy, color, angle=angle)
    # Rotate the original 1 x 2 side blocks about their attachment points.
    # Raising a hand never changes its dimensions or grows an arm.
    lift = (1 if pose in ('happy', 'scared') else 0) if hand_lift is None else hand_lift
    for side, pivot in [(-1, 1), (1, 10)]:
        turn = -side * 110 * lift
        hand_rad = math.radians(turn)
        hx = pivot + side * .5 * math.cos(hand_rad) - math.sin(hand_rad)
        hy = 2 + side * .5 * math.sin(hand_rad) + math.cos(hand_rad)
        dx, dy = (hx - 5.5) * 5 * sx, (hy - 4) * 5 * sy
        rect(frame, x + dx * math.cos(rad) - dy * math.sin(rad), y + dx * math.sin(rad) + dy * math.cos(rad), 5 * sx, 10 * sy, 1, angle=angle + turn)


def stairs(frame, phase=0, camera=0, future=1):
    # Restore the separate original ┐ ledges, not a connected staircase.
    # Snap both segments to the same pixel edge, with no shared filled area.
    for index in range(-3, 5):
        pos = index - phase
        x, y = round(pos * 66 - 29 - camera), round(-pos * 24)
        alpha = .27 * min(1, max(0, (pos + 3) / 2)) * min(1, max(0, (4 - pos) / 2))
        if index > 0:
            alpha *= future
        rect(frame, x + 29, y + 1.5, 58, 3, 0, alpha)
        rect(frame, x + 56.5, y + 9, 3, 12, 0, alpha)


def flower(frame, x, y, color, alpha):
    for dx, dy in [(0, -2), (-2, 0), (2, 0), (0, 2)]:
        rect(frame, x + dx, y + dy, 2, 2, color, alpha)
    rect(frame, x, y, 2, 2, 4, alpha)


def cross(frame, x, y, alpha):
    for dx, dy in [(-3, -3), (3, -3), (0, 0), (-3, 3), (3, 3)]:
        rect(frame, x + dx, y + dy, 3, 3, 6, alpha)


def walk(t):
    frame = []
    phase = t / .6
    # Keep the camera still while feet touch a step; move to the next step
    # during flight. Each 18-frame hop has crouch, takeoff, air and impact.
    flight = max(0, min(1, (phase - 1 / 6) / (2 / 3)))
    stairs(frame, ease(flight))
    poses = [(0, 1), (1 / 9, .80), (2 / 9, 1.12),
             (4 / 9, 1), (7 / 9, 1.04), (8 / 9, .72), (1, 1)]
    squash = 1
    for (start, a), (end, b) in zip(poses, poses[1:]):
        if start <= phase <= end:
            squash = a + (b - a) * ease((phase - start) / (end - start))
            break
    hop = math.sin(flight * math.pi) * 25
    # Scale around the feet, so the landing compresses against the stair.
    sprite(frame, y=-20 * squash - hop, sx=1 / math.sqrt(squash), sy=squash)
    return frame


def success(t, reduced=False):
    frame = []
    stairs(frame)
    if reduced:
        sprite(frame, pose='happy')
        for x, y in [(-48, -40), (46, -43), (-30, -75), (28, -77)]:
            flower(frame, x, y, 3, 1)
        return frame
    if t < .12:
        squash = 1 - .18 * ease(t / .12)
        hop = 0
    elif t < .78:
        u = (t - .12) / .66
        hop, squash = math.sin(u * math.pi) * 38, 1 + .06 * math.sin(u * math.pi)
    else:
        hop, squash = 0, 1 - .18 * math.sin(min(1, (t - .78) / .25) * math.pi)
    sprite(frame, y=-20 * squash - hop, sx=2 - squash, sy=squash, pose='happy' if t >= .12 else 'walk', hand_lift=ease((t - .10) / .24))
    burst = ease((t - .16) / .48)
    for i, (dx, dy) in enumerate([(-54, -40), (52, -38), (-32, -84), (30, -90), (-66, -70), (64, -72)]):
        alpha = min(1, max(0, (t - .16 - i * .025) / .15)) * (1 - .4 * ease((t - 1) / .3))
        flower(frame, dx * (.55 + .45 * burst), dy - hop * .3 + max(0, t - .7) * 7, [3, 5, 4][i % 3], alpha)
    return frame


def failure(t, reduced=False):
    frame = []
    if reduced:
        t = 2.6
    camera = 29 * ease(t / .65)
    stairs(frame, camera=camera, future=1 - ease(t / .30))
    ground_alpha = ease((t - .40) / .40)
    rect(frame, 12, 97.5, 128, 3, 0, .28 * ground_alpha)
    if t < .65:
        walk_to_edge = ease(t / .65)
        sprite(frame, x=28 * walk_to_edge - camera, y=-20 - math.sin(walk_to_edge * math.pi * 2) * 3)
    elif t < .95:
        u = (t - .65) / .30
        sprite(frame, x=-1 + 9 * u, y=-20, angle=12 * math.sin(u * math.pi), pose='scared')
    elif t < 1.48:
        u = (t - .95) / .53
        sprite(frame, x=8 + 10 * u, y=-20 + 96 * u * u, angle=180 * ease(u), pose='scared' if u < .6 else 'hurt')
    else:
        impact = max(0, 1 - (t - 1.48) / .30)
        sy = 1 - .18 * math.sin(impact * math.pi)
        sprite(frame, x=18, y=96 - 20 * sy, sx=2 - sy, sy=sy, angle=180, pose='hurt')
        for sign in [-1, 1]:
            rect(frame, 18 + sign * (30 + (1 - impact) * 16), 89 - (1 - impact) * 8, 5, 3, 4, impact)
        # Smoke and little error crosses drift above the fallen character.
        for i in range(3):
            age = (max(0, t - 1.5) + i * .48) % 1.7
            opacity = min(1, max(0, (t - 1.48) * 3)) * .75 * math.sin(math.pi * age / 1.7)
            x = 4 + math.sin(age * 3 + i) * 8
            y = 61 - age * 28
            rect(frame, x, y, 7 + age * 4, 5, 7, opacity)
            rect(frame, x + 3, y - 5, 5 + age * 2, 5, 7, opacity)
            cross(frame, 34 + i * 13, 57 - age * 22, opacity)
    return frame


def build():
    clips = {name: [fn(i / FPS) for i in range(round(duration * FPS) + 1)]
             for name, fn, duration in [('walk', walk, .6), ('success', success, 1.3), ('failure', failure, 4.7)]}
    # Do not repeat the walking endpoint: it is the next cycle's first frame.
    clips['walk'].pop()
    # Fall once, then loop the settled pose's complete 1.7-second smoke cycle.
    clips['failure'].pop()
    still = []
    stairs(still)
    sprite(still)
    clips['reducedWalk'] = [still]
    clips['reducedSuccess'] = [success(0, True)]
    clips['reducedFailure'] = [failure(0, True)]
    return {'fps': FPS, 'failureLoopStart': 3 * FPS, 'colors': COLORS, 'clips': clips}


def preview(data, path):
    html = '''<!doctype html><html lang="zh"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Clawd 加载动画预览</title><style>body{margin:0;background:#eee9e3;color:#463d36;font:14px system-ui;text-align:center}canvas{width:min(100vw,393px);height:auto;background:#faf8f4;border-radius:24px;margin:16px auto;display:block}button{font:inherit;padding:9px 13px;margin:4px;border:1px solid #bcb5ac;background:transparent;border-radius:10px;color:inherit}p{margin:8px}body.dark{background:#252422;color:#e9e4dd}body.dark canvas{background:#171716}</style><p>同一份像素帧：加载 → 成功 / 失败</p><div><button onclick="play('walk')">重新加载</button><button onclick="play('success')">连接成功</button><button onclick="play('failure')">连接失败</button><button onclick="document.body.classList.toggle('dark')">日 / 夜</button><button onclick="reduced=!reduced">减少动态</button></div><canvas id="stage" width="393" height="660"></canvas><p id="status">加载中</p><p>动作素材预览；不是 iOS 模拟器截图。</p><script>const data=DATA;const c=document.querySelector('canvas'),ctx=c.getContext('2d');let mode='walk',start=performance.now(),reduced=false;function play(m){mode=m;start=performance.now()}function render(now){const t=(now-start)/1000;let key=reduced?'reduced'+mode[0].toUpperCase()+mode.slice(1):mode;const frames=data.clips[key];const n=Math.floor(t*data.fps),loop=data.failureLoopStart;const i=reduced?0:mode==='walk'?n%frames.length:mode==='failure'&&n>=loop?loop+(n-loop)%(frames.length-loop):Math.min(frames.length-1,n);ctx.clearRect(0,0,c.width,c.height);ctx.save();ctx.translate(c.width/2,c.height/2-25);for(const [x,y,w,h,a,color,alpha]of frames[i]){ctx.save();ctx.translate(x,y);ctx.rotate(a*Math.PI/180);ctx.globalAlpha=alpha;ctx.fillStyle=color===0&&document.body.classList.contains('dark')?'#c7c2bb':data.colors[color];ctx.fillRect(-w/2,-h/2,w,h);ctx.restore()}ctx.restore();document.querySelector('#status').textContent=mode==='walk'?'加载中':mode==='success'?'连接成功 · 欢迎回来':'连接失败 · 重新连接';requestAnimationFrame(render)}requestAnimationFrame(render);</script>'''
    path.write_text(html.replace('DATA', json.dumps(data, separators=(',', ':'))))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--preview', type=Path)
    args = parser.parse_args()
    data = build()
    target = ROOT / 'LinChe/ClawdAnimation.json'
    target.write_text(json.dumps(data, separators=(',', ':')) + '\n')
    if args.preview:
        preview(data, args.preview)
    print(f'{target.name}: {target.stat().st_size:,} bytes; {sum(len(v) for v in data["clips"].values())} frames')
