#!/usr/bin/env python3
"""Reject simulator packages, missing executables, and accidentally bundled secrets."""
import plistlib
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
    executable = archive.read('Payload/LinChe.app/' + info['CFBundleExecutable'])
    magic, cpu = struct.unpack_from('<II', executable)
    assert magic == 0xFEEDFACF and cpu == 0x0100000C, 'Expected arm64 Mach-O executable'
    assert any(name.endswith('/Assets.car') for name in names), 'Missing app icons'
    for name in names:
        parts = PurePosixPath(name).parts
        assert '..' not in parts and not name.startswith('/'), 'Unsafe archive path'
        assert not any(part.startswith('.env') or part in {'.git', 'node_modules'} for part in parts), 'Unexpected private/runtime files'
        assert not name.endswith(('.p12', '.mobileprovision', '.db', '.sqlite', '.sqlite3')), 'Unexpected signing material or database'
    print(f"Validated device IPA: version {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")
