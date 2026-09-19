#!/usr/bin/env python3
"""Neutralise the reboot that Tesla's boot scripts trigger after "repairing"
the partition table or a filesystem.

On the real car that restart is harmless: the repair holds and the next boot is
clean. Under QEMU the same condition comes back every time, so the machine
loops. This rewrites the restart into a console message and makes the script
report success, because runit jumps to stage 3 (shutdown) when a stage-1 child
fails.

Usage: suppress-reboot.py <script> [<script> ...]
"""
import re
import sys

MARK = "qemu: reboot suppressed"
EXIT_MARK = "qemu: never fail runit stage 1"

# Order matters: the combined "echo ...; exit 1" form must be handled before
# the bare exit.
PATTERNS = [
    # echo "REBOOTING ..." followed by a non-zero exit on the same line
    (re.compile(r'(?m)^(\s*)([^\n]*REBOOTING[^\n]*?);\s*exit\s+[1-9][0-9]*\s*$'),
     r'\1\2; echo "' + MARK + r' (stage-1 exit)"'),
    # a non-zero exit on the line following a REBOOTING message
    (re.compile(r'(?m)^(\s*[^\n]*REBOOTING[^\n]*\n)(\s*)exit\s+[1-9][0-9]*\s*$'),
     r'\1\2echo "' + MARK + r' (stage-1 exit)"'),
    # direct restart calls
    (re.compile(r'(?m)^(\s*)((?:/s?bin/)?reboot\b[^\n]*)$'),
     r'\1echo "' + MARK + r' (\2)"'),
    (re.compile(r'(?m)^(\s*)((?:/s?bin/)?shutdown\s+-r[^\n]*)$'),
     r'\1echo "' + MARK + r' (\2)"'),
    (re.compile(r'(?m)^(\s*)([^\n]*>\s*/proc/sysrq-trigger[^\n]*)$'),
     r'\1echo "' + MARK + r' (sysrq)"'),
    # the flag some scripts set for a later reboot stage
    (re.compile(r'(?m)^(\s*)(reboot_required=|needs_reboot=|REBOOT=)\s*(1|true|yes)\s*$'),
     r'\g<1>\g<2>0  # ' + MARK),
]


def patch(path):
    try:
        with open(path, encoding="utf-8", errors="surrogateescape") as f:
            original = f.read()
    except (OSError, UnicodeError) as exc:
        print(f"  skip {path}: {exc}")
        return False

    if MARK in original:
        print(f"  already patched: {path}")
        return False

    text = original
    total = 0
    for pattern, replacement in PATTERNS:
        text, n = pattern.subn(replacement, text)
        total += n

    if EXIT_MARK not in text:
        text = text.rstrip("\n") + "\nexit 0  # " + EXIT_MARK + "\n"

    if text == original:
        print(f"  nothing to change: {path}")
        return False

    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(text)
    print(f"  patched {path} ({total} restart call(s) neutralised)")
    return True


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    changed = sum(patch(p) for p in sys.argv[1:])
    print(f"  {changed} file(s) modified")
