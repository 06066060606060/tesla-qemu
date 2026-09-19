#!/usr/bin/env python3
"""Extract the Linux bzImage payload from a Tesla IAS image (bank_a.iasImage).

The boot partition of an MCU2 unit contains `bank_a.iasImage`, an Intel
Automotive Service (IAS) container that wraps the kernel together with its
signature headers. The bzImage payload starts at a fixed offset inside the
container (0x832fa0 on the dumps seen so far); this script can also locate it
automatically by scanning for the x86 boot-protocol magic.

Usage:
    scripts/extract_iasImage.py bank_a.iasImage out/            # auto-detect
    scripts/extract_iasImage.py bank_a.iasImage out/ 0x832fa0   # explicit

Reference: ROOT Tesla OS on QEMU Part 2 - Debugging + fixing
https://cn0xroot.wordpress.com/2026/09/20/root_tesla_os_on_qemu_part_2_debugging_fixing/
"""

import os
import sys

# Linux x86 boot protocol: "HdrS" lives at offset 0x202 of the bzImage.
HDRS = b"HdrS"
HDRS_OFFSET = 0x202


def find_bzimage(blob: bytes) -> int:
    """Return the offset of the first plausible bzImage inside blob."""
    pos = 0
    while True:
        hit = blob.find(HDRS, pos)
        if hit < 0:
            return -1
        start = hit - HDRS_OFFSET
        if start >= 0 and blob[start + 0x1FE:start + 0x200] == b"\x55\xaa":
            return start
        pos = hit + 1


def main(argv: list) -> int:
    if len(argv) not in (3, 4):
        print(__doc__)
        return 2

    src, outdir = argv[1], argv[2]
    offset = int(argv[3], 0) if len(argv) == 4 else None

    with open(src, "rb") as f:
        blob = f.read()

    if offset is None:
        offset = find_bzimage(blob)
        if offset < 0:
            print("error: no bzImage signature found in %s" % src, file=sys.stderr)
            return 1
        print("bzImage found at offset 0x%x (auto-detected)" % offset)
    else:
        if blob[offset + HDRS_OFFSET:offset + HDRS_OFFSET + 4] != HDRS:
            print(
                "warning: no 'HdrS' magic at 0x%x + 0x202 - extracting anyway"
                % offset,
                file=sys.stderr,
            )

    os.makedirs(outdir, exist_ok=True)
    dst = os.path.join(outdir, "bzImage")
    with open(dst, "wb") as f:
        f.write(blob[offset:])

    print("wrote %s (%d bytes)" % (dst, os.path.getsize(dst)))
    print("check with: file %s" % dst)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
