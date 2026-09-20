#!/usr/bin/env python3
"""Apply the binary patches the UI needs on a virtio GPU.

Usage: patch-binaries.py <rootfs>

Two patches, taken from build.sh where they were applied to the Alpine disk
image:

- libdrm.so.2: the virtio GPU does not implement DRM_IOCTL_WAIT_VBLANK, so every
  call returns ENOTSUP. QtCar gates frame presentation on a successful vblank
  wait, so the screen stays black. drmWaitVBlank is made to return 0 at once.

- libQtCarUIFramework.so: make the touch driver load and report the display as on
  and powered, so the UI accepts input from the QEMU tablet.

Offsets are specific to the build these were derived from, so every patch checks
the bytes it expects and is skipped - with a warning, not an error - when they do
not match. Already-patched files are left alone, so this can run again.
"""

import sys
from pathlib import Path

# (relative path, [(offset, expected, patch, description)], required)
TARGETS = [
    (
        "usr/lib/libdrm.so.2",
        [
            (
                0x97E4,
                bytes.fromhex("415649"),
                bytes.fromhex("31c0c3"),
                "drmWaitVBlank -> xor eax,eax; ret",
            ),
        ],
        False,
    ),
    (
        "usr/tesla/UI/lib/libQtCarUIFramework.so",
        [
            (
                0x80D1A9,
                bytes.fromhex("0f85b20a0000"),
                bytes.fromhex("909090909090"),
                "NOP touch-skip jump in DisplayDevice ctor",
            ),
            (
                0x80D1DF,
                bytes.fromhex("488b0512d06b00807d2900488b18"),
                bytes.fromhex("4c89e7e839b9c4ff4893807d2900"),
                "call TouchDevice::getInstance before loadTouchDriver",
            ),
            (
                0xA61AE0,
                bytes.fromhex("534889fbe8c79d9eff"),
                bytes.fromhex("b801000000c3"),
                "ManagedQtCarTouchDriver::isDisplayOn() -> return true",
            ),
            (
                0xA61D10,
                bytes.fromhex("534889fbe827a0a0ff"),
                bytes.fromhex("b801000000c3"),
                "ManagedQtCarTouchDriver::isPowered() -> return true",
            ),
        ],
        False,
    ),
]


def patch_file(path: Path, patches) -> None:
    with open(path, "r+b") as f:
        for offset, expected, patch, desc in patches:
            f.seek(offset)
            orig = f.read(max(len(expected), len(patch)))

            if orig[: len(patch)] == patch:
                print(f"  {path.name} {offset:#x}: already patched ({desc})")
                continue

            if orig[: len(expected)] != expected:
                print(
                    f"warning: {path}: unexpected bytes at {offset:#x}: "
                    f"{orig[:len(expected)].hex()} != {expected.hex()}; "
                    f"skipped ({desc})",
                    file=sys.stderr,
                )
                continue

            f.seek(offset)
            f.write(patch)
            print(f"  {path.name} {offset:#x}: {desc}")


def main() -> int:
    root = Path(sys.argv[1])
    for rel, patches, required in TARGETS:
        path = root / rel
        if not path.is_file():
            message = f"{rel} not found"
            if required:
                print(f"error: {message}", file=sys.stderr)
                return 1
            print(f"  {message}, skipped")
            continue
        patch_file(path, patches)
    return 0


if __name__ == "__main__":
    sys.exit(main())
