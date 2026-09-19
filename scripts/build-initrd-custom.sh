#!/bin/bash
# Build the initramfs used by the native-boot path (qemu/start-native.sh).
#
# Contents: static busybox (for rescue/debug) + static custom_init as /init.
# custom_init mounts the edited squashfs from /dev/vda and switch_roots into
# the stock Tesla userland, bypassing dm-verity and the dm-linear rootfs.
#
# Usage: ./scripts/build-initrd-custom.sh [out/initrd_custom.cpio.gz]
set -euo pipefail

OUT="${1:-out/initrd_custom.cpio.gz}"
STAGING="${STAGING:-out/initramfs_custom}"
BUSYBOX_URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
ROOT_DEVICE="${ROOT_DEVICE:-/dev/vda}"

log() { echo -e "\033[32m$1\033[0m"; }
err() { echo -e "\033[31m$1\033[0m" >&2; exit 1; }

command -v gcc >/dev/null || err "gcc is required"
command -v cpio >/dev/null || err "cpio is required"

mkdir -p out cache
rm -rf "$STAGING"
mkdir -p "$STAGING"/{bin,sbin,dev,proc,sys,mnt,etc,lib}

log "Fetch busybox"
if [ ! -f cache/busybox ]; then
    wget -q -O cache/busybox "$BUSYBOX_URL"
    chmod +x cache/busybox
fi
cp cache/busybox "$STAGING/bin/busybox"
chmod +x "$STAGING/bin/busybox"

log "Create busybox applet symlinks"
( cd "$STAGING/bin" && for applet in $(./busybox --list); do ln -sf busybox "$applet"; done )

log "Compile custom_init (static)"
gcc -O2 -static -DROOT_DEVICE="\"$ROOT_DEVICE\"" \
    -o "$STAGING/init" tools/custom_init.c
strip "$STAGING/init" 2>/dev/null || true

# A shell fallback is handy when custom_init dies: boot with
# rdinit=/bin/sh on the kernel command line.
ln -sf /bin/busybox "$STAGING/sbin/sh" 2>/dev/null || true

log "Pack cpio archive"
( cd "$STAGING" && find . -print0 | cpio --null -o -H newc --quiet ) | gzip -9 > "$OUT"

log "DONE: $OUT ($(stat -c%s "$OUT") bytes)"
