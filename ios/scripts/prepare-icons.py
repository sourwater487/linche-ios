#!/usr/bin/env python3
"""Reuse the existing PWA icon; sips is provided by macOS/Xcode runners."""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
assets = root / 'ios/LinChe/Assets.xcassets'
icons = assets / 'AppIcon.appiconset'
icons.mkdir(parents=True, exist_ok=True)
info = {'version': 1, 'author': 'xcode'}
(assets / 'Contents.json').write_text(json.dumps({'info': info}))
images = []
for idiom, sizes in [('iphone', [20, 29, 40, 60]), ('ipad', [20, 29, 40, 76, 83.5]), ('ios-marketing', [1024])]:
    for size in sizes:
        scales = [1] if idiom == 'ios-marketing' else [2] if size == 83.5 else [2, 3] if idiom == 'iphone' else [1, 2]
        for scale in scales:
            pixels = int(size * scale)
            filename = f'{idiom}-{size}@{scale}x.png'
            subprocess.run(['sips', '-z', str(pixels), str(pixels), str(root / 'public/pwa-512x512.png'), '--out', str(icons / filename)], check=True, stdout=subprocess.DEVNULL)
            images.append({'idiom': idiom, 'size': f'{size}x{size}', 'scale': f'{scale}x', 'filename': filename})
(icons / 'Contents.json').write_text(json.dumps({'images': images, 'info': info}, indent=2))

# Match the native loader from the first system launch frame, including dark mode.
launch_colors = assets / "LaunchBackground.colorset"
launch_colors.mkdir(parents=True, exist_ok=True)
(launch_colors / "Contents.json").write_text('{\n  "info": {\n    "version": 1,\n    "author": "xcode"\n  },\n  "colors": [\n    {\n      "idiom": "universal",\n      "color": {\n        "color-space": "srgb",\n        "components": {\n          "red": "0.965",\n          "green": "0.957",\n          "blue": "0.937",\n          "alpha": "1.000"\n        }\n      }\n    },\n    {\n      "idiom": "universal",\n      "appearances": [\n        {\n          "appearance": "luminosity",\n          "value": "dark"\n        }\n      ],\n      "color": {\n        "color-space": "srgb",\n        "components": {\n          "red": "0.067",\n          "green": "0.067",\n          "blue": "0.063",\n          "alpha": "1.000"\n        }\n      }\n    }\n  ]\n}')
