#!/usr/bin/env bash
# Export an Ubuntu rootfs containing Mesa, the DRI drivers and Xorg into
# cache/ubuntu-xorg-rootfs/.
#
# The firmware's Mesa only knows Intel hardware, so EGL fails on the virtio GPU
# with "libEGL warning: egl: failed to create dri2 screen" and QtCar cannot get
# a GL context. build.sh solved this for the Alpine path by copying Ubuntu's
# drivers into the image; prepare-rootfs.sh does the same for the native path,
# using what this script exports.
#
#   ./scripts/import-x11.sh
#   RUNTIME=podman ./scripts/import-x11.sh
#   FORCE=1 ./scripts/import-x11.sh     # re-export even if the cache exists
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="${DEST:-$ROOT/cache/ubuntu-xorg-rootfs}"
RUNTIME="${RUNTIME:-docker}"
FORCE="${FORCE:-0}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [ -d "$DEST/usr/lib/x86_64-linux-gnu/dri" ] && [ "$FORCE" != "1" ]; then
    log "Already exported: $DEST"
    echo "Use FORCE=1 to rebuild it."
    exit 0
fi

command -v "$RUNTIME" >/dev/null || err "$RUNTIME not found (needed to export the Ubuntu rootfs)"
[ -f "$ROOT/docker/Dockerfile.ubuntu" ] || err "docker/Dockerfile.ubuntu not found"

log "Export the Ubuntu X11 rootfs into $DEST"
mkdir -p "$DEST"
"$RUNTIME" build -o "$DEST" -f "$ROOT/docker/Dockerfile.ubuntu" "$ROOT/docker"

[ -d "$DEST/usr/lib/x86_64-linux-gnu/dri" ] ||
    err "export finished but $DEST/usr/lib/x86_64-linux-gnu/dri is missing"

log "Done. Drivers found:"
ls "$DEST/usr/lib/x86_64-linux-gnu/dri" | sed 's/^/  /' | head
echo
echo "Now rebuild the rootfs so they are installed in the guest:"
echo "  ./scripts/prepare-rootfs.sh firmware/<version>.squashfs"
