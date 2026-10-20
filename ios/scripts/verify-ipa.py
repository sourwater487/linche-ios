#!/usr/bin/env python3
"""Reject simulator packages, missing executables, and accidentally bundled secrets."""
import plistlib
import hashlib
import json
import math
from pathlib import PurePosixPath
import struct
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    names = archive.namelist()
    info = plistlib.loads(archive.read('Payload/LinChe.app/Info.plist'))
    assert info['CFBundleIdentifier'] == 'com.linche.privateapp', 'Unexpected bundle identifier'
    assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS'], 'Not an iPhone device build'
    assert info['CFBundlePackageType'] == 'APPL', 'Not an application'
    font = archive.read('Payload/LinChe.app/KingHwaOldSong.ttf')
    assert hashlib.sha256(font).hexdigest() == 'f7fef9fc413e9e2343f0bb432c51cca41c44b8fe37f071dc86b050896ae9f9e2', 'Missing or incorrect global font'
    executable = archive.read('Payload/LinChe.app/' + info['CFBundleExecutable'])
    magic, cpu = struct.unpack_from('<II', executable)
    assert magic == 0xFEEDFACF and cpu == 0x0100000C, 'Expected arm64 Mach-O executable'
    assert any(name.endswith('/Assets.car') for name in names), 'Missing app icons'
    widget_root = 'Payload/LinChe.app/PlugIns/GardenWidget.appex/'
    widget = plistlib.loads(archive.read(widget_root + 'Info.plist'))
    assert widget['CFBundleIdentifier'] == 'com.linche.privateapp.GardenWidget', 'Unexpected widget identifier'
    assert widget['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension', 'Not a WidgetKit extension'
    for bundle in (info, widget):
        assert bundle.get('CFBundleDevelopmentRegion') == 'zh-Hans', 'Bundle default language must be Simplified Chinese'
        assert 'zh-Hans' in bundle.get('CFBundleLocalizations', []), 'Missing Chinese localization declaration'
    assert widget['CFBundleVersion'] == info['CFBundleVersion'], 'Widget build mismatch'
    assert widget['CFBundleShortVersionString'] == info['CFBundleShortVersionString'], 'Widget version mismatch'
    widget_executable = archive.read(widget_root + widget['CFBundleExecutable'])
    assert struct.unpack_from('<II', widget_executable) == (0xFEEDFACF, 0x0100000C), 'Widget must be an arm64 device binary'
    assert 'linche' in info['CFBundleURLTypes'][0]['CFBundleURLSchemes'], 'Missing Garden deep link'
    # Ad-hoc signing must carry the App Group for SideStore to re-provision it.
    for binary in (executable, widget_executable):
        assert b'group.com.linche.privateapp.garden' in binary and b'com.apple.security.application-groups' in binary, 'Missing shared-group entitlement'
    animation = json.loads(archive.read('Payload/LinChe.app/ClawdAnimation.json'))
    assert animation['fps'] == 30, 'Unexpected animation frame rate'
    assert 0 < animation['failureLoopStart'] < len(animation['clips']['failure']), 'Invalid failure loop'
    for clip in ('walk', 'success', 'failure', 'reducedWalk', 'reducedSuccess', 'reducedFailure'):
        frames = animation['clips'][clip]
        assert frames, 'Empty animation clip'
        for frame in frames:
            for block in frame:
                assert len(block) == 7 and all(math.isfinite(v) for v in block), 'Invalid animation block'
                assert block[2] > 0 and block[3] > 0 and 0 <= block[6] <= 1, 'Invalid animation geometry'
                assert int(block[5]) == block[5] and 0 <= block[5] < len(animation['colors']), 'Invalid animation palette'
    for name in names:
        parts = PurePosixPath(name).parts
        assert '..' not in parts and not name.startswith('/'), 'Unsafe archive path'
        assert not any(part.startswith('.env') or part in {'.git', 'node_modules'} for part in parts), 'Unexpected private/runtime files'
        assert not name.endswith(('.p12', '.mobileprovision', '.db', '.sqlite', '.sqlite3')), 'Unexpected signing material or database'
    print(f"Validated device IPA: version {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")
