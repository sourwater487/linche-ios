#!/usr/bin/env python3
"""Validate local XcodeGen paths before spending a macOS build on the spec."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = json.loads((root / 'project.json').read_text())
targets = spec['targets']
for name, target in targets.items():
    for source in target.get('sources', []):
        path = source if isinstance(source, str) else source['path']
        assert (root / path).exists(), f'{name}: missing source {path}'
    for key, value in target.get('settings', {}).get('base', {}).items():
        if key.startswith('CODE_SIGN_ENTITLEMENTS'):
            assert (root / value).is_file(), f'{name}: missing entitlements {value}'
    for dependency in target.get('dependencies', []):
        if 'target' in dependency:
            assert dependency['target'] in targets, f'{name}: missing dependency target'
for scheme in spec.get('schemes', {}).values():
    assert set(scheme.get('build', {}).get('targets', {})) <= targets.keys(), 'Missing scheme build target'
    for target in scheme.get('test', {}).get('targets', []):
        assert (target if isinstance(target, str) else target['name']) in targets, 'Missing scheme test target'
print('XcodeGen paths and targets validated:', ', '.join(targets))
