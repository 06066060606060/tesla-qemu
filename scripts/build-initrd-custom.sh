#!/bin/bash
# Build the initramfs used by the native-boot path (qemu/start-native.sh).
#
# Contents: static busybox (rescue shell) + static custom_init, which mounts
# the edited squashfs from /dev/vda and switch_roots into the stock Tesla
# userland, bypassing dm-verity and the dm-linear rootfs.
#
# Usage:
#   ./scripts/build-initrd-custom.sh                    # no kernel modules
#   MODLOOP=./cache/alpine-iso/boot/modloop-lts \
#       ./scripts/build-initrd-custom.sh                # Alpine kernel
#   MODULES_DIR=/lib/modules/6.6.14-0-lts \
#       ./scripts/build-initrd-custom.sh                # any modules tree
#
# Why modules matter: the Tesla kernel has squashfs/virtio built in, but a
# distribution kernel such as Alpine's vmlinuz-lts ships them as modules. With
# no modules in the initramfs, custom_init cannot mount /dev/vda and stops with
# "mount /dev/vda: No such device". Pass MODLOOP or MODULES_DIR and the needed
# modules are resolved with their dependencies and inserted before the mount.
set -euo pipefail

OUT="${1:-out/initrd_custom.cpio.gz}"
STAGING="${STAGING:-out/initramfs_custom}"
BUSYBOX_URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
ROOT_DEVICE="${ROOT_DEVICE:-/dev/vda}"
MODLOOP="${MODLOOP:-}"
MODULES_DIR="${MODULES_DIR:-}"
# Everything custom_init needs before the rootfs exists, plus the storage and
# display drivers the guest uses right after switch_root.
KMODS="${KMODS:-squashfs virtio_pci virtio_blk virtio_net virtio_gpu sdhci_pci sdhci_acpi mmc_block ext4 dm_mod loop usbhid hid_generic xhci_pci evdev uinput}"

log()  { echo -e "\033[32m$1\033[0m"; }
warn() { echo -e "\033[33mWARN: $1\033[0m" >&2; }
err()  { echo -e "\033[31m$1\033[0m" >&2; exit 1; }

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
( cd "$STAGING/bin" && for applet in $(./busybox --list); do
    [ "$applet" = "busybox" ] && continue
    ln -sf busybox "$applet"
done )

log "Compile custom_init (static)"
gcc -O2 -static -DROOT_DEVICE="\"$ROOT_DEVICE\"" \
    -o "$STAGING/sbin/custom_init" tools/custom_init.c
strip "$STAGING/sbin/custom_init" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Optional kernel modules
# ---------------------------------------------------------------------------
if [ -n "$MODLOOP" ] && [ -z "$MODULES_DIR" ]; then
    [ -f "$MODLOOP" ] || err "MODLOOP '$MODLOOP' not found"
    command -v unsquashfs >/dev/null || err "squashfs-tools is required to read $MODLOOP"
    EXTRACT="cache/modloop-$(basename "$MODLOOP")"
    if [ ! -d "$EXTRACT" ]; then
        log "Extract $MODLOOP"
        unsquashfs -q -d "$EXTRACT" "$MODLOOP" >/dev/null
    fi
    # Alpine layout: <root>/modules/<kver>/...
    MODULES_DIR="$(find "$EXTRACT/modules" -maxdepth 1 -mindepth 1 -type d | head -1)"
    [ -n "$MODULES_DIR" ] || err "no modules directory inside $MODLOOP"
fi

MODULE_LOAD_LIST=""
if [ -n "$MODULES_DIR" ]; then
    [ -d "$MODULES_DIR" ] || err "MODULES_DIR '$MODULES_DIR' not found"
    KVER="$(basename "$MODULES_DIR")"
    log "Collect kernel modules for $KVER"

    # modprobe resolves dependencies against a fake root that mirrors
    # /lib/modules/<kver>.
    FAKEROOT="cache/modprobe-root-$KVER"
    rm -rf "$FAKEROOT"
    mkdir -p "$FAKEROOT/lib/modules"
    ln -sfn "$(realpath "$MODULES_DIR")" "$FAKEROOT/lib/modules/$KVER"

    # modprobe needs modules.dep; regenerate it if the tree lacks one.
    if [ ! -f "$MODULES_DIR/modules.dep" ] && [ ! -f "$MODULES_DIR/modules.dep.bin" ]; then
        if command -v depmod >/dev/null; then
            log "  generate modules.dep"
            depmod -b "$FAKEROOT" "$KVER" 2>/dev/null || warn "depmod failed"
        else
            warn "no modules.dep and no depmod: falling back to a plain file search"
        fi
    fi

    mkdir -p "$STAGING/lib/modules/$KVER"
    ORDERED=""
    for mod in $KMODS; do
        deps="$(modprobe -d "$FAKEROOT" -S "$KVER" --show-depends "$mod" 2>/dev/null |
                awk '$1 == "insmod" { print $2 }' || true)"
        if [ -z "$deps" ]; then
            # Last resort: take the module itself without its dependencies.
            alt="${mod//_/[-_]}"
            deps="$(find "$MODULES_DIR" -name "$alt.ko" -o -name "$alt.ko.gz" \
                    -o -name "$alt.ko.xz" -o -name "$alt.ko.zst" 2>/dev/null | head -1)"
        fi
        if [ -z "$deps" ]; then
            warn "module '$mod' not found for $KVER (skipped)"
            continue
        fi
        # --show-depends prints dependencies before the module itself.
        for ko in $deps; do
            case " $ORDERED " in
                *" $ko "*) continue ;;
            esac
            ORDERED="$ORDERED $ko"
        done
    done

    COUNT=0
    for ko in $ORDERED; do
        # modprobe reports paths through the fake root, the find fallback
        # reports them under MODULES_DIR: normalise both to a path relative
        # to the modules directory.
        case "$ko" in
            */lib/modules/"$KVER"/*) rel="${ko##*/lib/modules/"$KVER"/}" ;;
            *"/$KVER/"*)             rel="${ko##*"/$KVER/"}" ;;
            *)                       rel="$(basename "$ko")" ;;
        esac
        dest="$STAGING/lib/modules/$KVER/$rel"
        mkdir -p "$(dirname "$dest")"
        cp "$ko" "$dest"
        MODULE_LOAD_LIST="$MODULE_LOAD_LIST /lib/modules/$KVER/$rel"
        COUNT=$((COUNT + 1))
    done
    log "  embedded $COUNT module(s)"
    for essential in squashfs virtio_blk; do
        case "$MODULE_LOAD_LIST" in
            *"${essential}.ko"*|*"${essential//_/-}.ko"*) ;;
            *) warn "'$essential' is NOT in the initrd: the guest will hang waiting for $ROOT_DEVICE" ;;
        esac
    done
else
    warn "no kernel modules embedded - only works with a kernel that has squashfs and virtio built in (e.g. the stock Tesla bzImage)"
    warn "for Alpine: MODLOOP=./cache/alpine-iso/boot/modloop-lts $0"
fi

# ---------------------------------------------------------------------------
# /init
# ---------------------------------------------------------------------------
if [ -n "$MODULE_LOAD_LIST" ]; then
    log "Generate /init wrapper that inserts modules first"
    cat > "$STAGING/init" <<'HEADER'
#!/bin/busybox sh
# Generated by scripts/build-initrd-custom.sh
export PATH=/bin:/sbin
busybox mount -t devtmpfs none /dev 2>/dev/null
busybox mount -t proc none /proc 2>/dev/null
busybox mount -t sysfs none /sys 2>/dev/null
echo "init: loading kernel modules"
HEADER
    for ko in $MODULE_LOAD_LIST; do
        # A failed module is not fatal, but it must be visible: a missing
        # virtio_blk is exactly why /dev/vda would never appear.
        printf 'busybox insmod %s 2>/dev/null || echo "init: insmod %s FAILED"\n' \
            "$ko" "${ko##*/}" >> "$STAGING/init"
    done
    cat >> "$STAGING/init" <<'FOOTER'
echo "init: modules now loaded:"
busybox cut -d' ' -f1 /proc/modules | busybox tr '\n' ' '
echo
exec /sbin/custom_init
FOOTER
    chmod +x "$STAGING/init"
else
    ln -sf /sbin/custom_init "$STAGING/init"
fi

# Rescue path: boot with rdinit=/bin/sh to get a shell instead of custom_init.
ln -sf /bin/busybox "$STAGING/sbin/sh" 2>/dev/null || true

log "Pack cpio archive"
( cd "$STAGING" && find . -print0 | cpio --null -o -H newc --quiet ) | gzip -9 > "$OUT"

log "DONE: $OUT ($(stat -c%s "$OUT") bytes)"
