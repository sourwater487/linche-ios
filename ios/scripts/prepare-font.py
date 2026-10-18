#!/usr/bin/env python3
"""Fetch the unchanged font used by the site's CSS for private device builds."""
import hashlib
from pathlib import Path
import urllib.request

URL = 'https://github.com/DzmingLi/nur-packages/releases/download/KingHwaOldSong-3.0/KingHwaOldSong-3.0.ttf'
SHA256 = 'f7fef9fc413e9e2343f0bb432c51cca41c44b8fe37f071dc86b050896ae9f9e2'
target = Path(__file__).resolve().parents[1] / 'LinChe' / 'KingHwaOldSong.ttf'
if not target.exists() or hashlib.sha256(target.read_bytes()).hexdigest() != SHA256:
    with urllib.request.urlopen(URL, timeout=60) as response:
        data = response.read(40 * 1024 * 1024 + 1)
    assert hashlib.sha256(data).hexdigest() == SHA256, 'Unexpected font download'
    target.write_bytes(data)
print(f'KingHwaOldSong verified: {target.stat().st_size:,} bytes')
