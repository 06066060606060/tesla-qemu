#!/usr/bin/env bash
# Build the guest-side helper binaries into out/.
#
# They need X11 headers, which the Tesla rootfs does not provide, so they are
# built in a container exactly as build.sh did for the Alpine path.
# prepare-rootfs.sh then installs whatever it finds in out/.
#
#   ./scripts/build-tools.sh              # everything, in Docker
#   RUNTIME=podman ./scripts/build-tools.sh
#
# On a machine with gcc, libx11-dev and libxtst-dev, NATIVE=1 skips the
# container.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$ROOT/out"
RUNTIME="${RUNTIME:-docker}"
NATIVE="${NATIVE:-0}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$OUT"

# tool source:flags
TOOLS="
x11-input-proxy:x11-input-proxy.c:-lX11 -lXtst
touch-proxy:touch-proxy.c:
vblank-fix.so:vblank-fix.c:-shared -fPIC -lc
"

if [ "$NATIVE" = "1" ]; then
    command -v gcc >/dev/null || err "gcc not found"
    echo "$TOOLS" | while IFS=: read -r out src flags; do
        [ -n "$out" ] || continue
        [ -f "$ROOT/tools/$src" ] || { warn "tools/$src missing, skipped"; continue; }
        log "Build $out"
        # One missing development package must not stop the others.
        # shellcheck disable=SC2086
        gcc -O2 -o "$OUT/$out" "$ROOT/tools/$src" $flags ||
            warn "$out failed to build (missing headers? libx11-dev, libxtst-dev)"
    done
    log "Built:"
    for f in x11-input-proxy touch-proxy vblank-fix.so; do
        [ -f "$OUT/$f" ] && echo "  out/$f"
    done
    exit 0
fi

command -v "$RUNTIME" >/dev/null ||
    err "$RUNTIME not found; install it or use NATIVE=1 with gcc, libx11-dev and libxtst-dev"

log "Build the helper binaries in a container"
"$RUNTIME" run --rm \
    -v "$ROOT/tools:/src:ro" \
    -v "$OUT:/out" \
    ubuntu:22.04 bash -c '
        set -e
        apt-get update -qq
        apt-get install -y -qq gcc libx11-dev libxtst-dev linux-libc-dev >/dev/null
        cd /src
        for spec in "x11-input-proxy:x11-input-proxy.c:-lX11 -lXtst" \
                    "touch-proxy:touch-proxy.c:" \
                    "vblank-fix.so:vblank-fix.c:-shared -fPIC -lc"; do
            out=${spec%%:*}; rest=${spec#*:}; src=${rest%%:*}; flags=${rest#*:}
            if [ ! -f "$src" ]; then
                echo "warning: tools/$src missing, skipped" >&2
                continue
            fi
            echo "  $out"
            gcc -O2 -o "/out/$out" "$src" $flags ||
                echo "warning: $out failed to build" >&2
        done
    '

log "Built:"
for f in x11-input-proxy touch-proxy vblank-fix.so; do
    [ -f "$OUT/$f" ] && echo "  out/$f"
done
echo
echo "Now rebuild the rootfs so they are installed in the guest:"
echo "  ./scripts/prepare-rootfs.sh firmware/<version>.squashfs"
