#!/usr/bin/env python3
"""Make sure every Swift file in the repository belongs to the correct Xcode target.

Requires Apple's plutil (included with Xcode) or another plutil supporting JSON.
Usage: python3 tools/check_xcode_sources.py
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'oupos.xcodeproj' / 'project.pbxproj'


def main() -> int:
    project = json.loads(subprocess.check_output([
        'plutil', '-convert', 'json', '-o', '-', str(PROJECT)
    ], text=True))
    objects = project['objects']
    resolved: dict[str, Path] = {}
    errors: list[str] = []

    def visit(ref: str, folder: Path) -> None:
        node = objects[ref]
        kind = node['isa']
        if kind == 'PBXGroup':
            path = node.get('path')
            base = folder / path if path else folder
            for child in node.get('children', []):
                visit(child, base)
        elif kind == 'PBXFileReference' and node.get('lastKnownFileType') == 'sourcecode.swift':
            resolved[ref] = folder / node['path']

    visit(objects[project['rootObject']]['mainGroup'], ROOT)

    for target_name, source_dir in [('oupos', 'oupos'), ('ouposTests', 'ouposTests')]:
        target = next(item for item in objects.values()
                      if item['isa'] == 'PBXNativeTarget' and item['name'] == target_name)
        source_phases = [objects[phase] for phase in target['buildPhases']
                         if objects[phase]['isa'] == 'PBXSourcesBuildPhase']
        included: list[Path] = []
        for phase in source_phases:
            for build_id in phase.get('files', []):
                file_id = objects[build_id].get('fileRef')
                if file_id in resolved:
                    included.append(resolved[file_id])
        intended = set((ROOT / source_dir).rglob('*.swift'))
        present = set(included)
        for missing in sorted(intended - present):
            errors.append(f'{target_name}: not in Compile Sources: {missing.relative_to(ROOT)}')
        for stale in sorted(present - intended):
            errors.append(f'{target_name}: unexpected source: {stale}')
        if len(set(included)) != len(included):
            errors.append(f'{target_name}: duplicate Compile Sources entries')
        for path in included:
            if not path.is_file():
                errors.append(f'{target_name}: referenced file missing: {path}')
        print(f'{target_name}: {len(intended)} Swift files / {len(included)} Compile Sources entries')

    if errors:
        for error in errors:
            print('ERROR:', error, file=sys.stderr)
        return 1
    print('OK: all Swift files are in their targets and all references resolve.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
