#!/usr/bin/env python3
"""Guard against programmatic iPad keyboard restoration in all OUPOS forms.

Run on a development machine: python3 tools/check_keyboard_focus.py
This is a source-level regression check, not a substitute for iPad UI testing.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1] / 'oupos'
files = sorted(root.rglob('*.swift'))
errors = []
for file in files:
    source = file.read_text(encoding='utf-8')
    # No ViewModifier, TextEditor or other form field should bind to a focus
    # state: doing so can re-focus after a keyboard-dismissal / view redraw.
    for marker in ('@FocusState ', '.focused(', 'keyboardDidHideNotification'):
        # Ignore explanatory comments and detect only source statements.
        for line_number, line in enumerate(source.splitlines(), start=1):
            if marker in line and not line.lstrip().startswith('//'):
                errors.append(f'{file.relative_to(root)}:{line_number}: {marker}')

if errors:
    print('Focus regression detected:\n' + '\n'.join(errors), file=sys.stderr)
    sys.exit(1)

assert 'window.endEditing(true)' in (root / 'Shared' / 'CommonViews.swift').read_text()
print(f'OK: {len(files)} Swift app files checked; inputs accept tap-to-focus only.')
