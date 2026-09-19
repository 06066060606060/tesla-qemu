#!/bin/bash
# Create the writable overlay disk for the native-boot path.
#
# The stock Tesla userland expects an eMMC-like device with this layout:
#
#   p1 boot            ext2
#   p2 rootfs-a-legacy (unused here: we boot the squashfs from virtio)
#   p3 rootfs-b-legacy (unused here)
#   p4 lvm             LVM PV holding vg "ivg" with var / home / log / gamesusr
#
# On a real car p4 is a LUKS/LVM stack unlocked by the TPM. There is no TPM in
# QEMU, so scripts/prepare-rootfs.sh clears crypt_partitions and we create the
# volumes here as plain ext4 - explicitly WITHOUT the quota feature, because a
# kernel without CONFIG_QUOTA mounts quota-enabled ext4 read-only.
#
# Attach the result as an SD/eMMC device so it shows up as /dev/mmcblk0
# (see qemu/start-native.sh).
#
# Usage: sudo ./scripts/make-overlay.sh [out/overlay.qcow2]
#
#   SIZE=4G  sudo ./scripts/make-overlay.sh     # smallest usable image
#   SIZE=16G LEGACY_PARTS=1 sudo ./scripts/make-overlay.sh
#
# SIZE must be a power of two: QEMU's sd-card device refuses anything else.
#
# Reference: ROOT Tesla OS on QEMU Part 2 - Debugging + fixing
# https://cn0xroot.wordpress.com/2026/09/20/root_tesla_os_on_qemu_part_2_debugging_fixing/
set -euo pipefail

OUT="${1:-out/overlay.qcow2}"
# QEMU's sd-card device only accepts capacities that are a power of two,
# so keep this at 4G / 8G / 16G / 32G / 64G.
SIZE="${SIZE:-8G}"
NBD="${NBD:-/dev/nbd0}"
VG="${VG:-ivg}"
# The rootfs-a/b-legacy partitions are dead weight here: the rootfs is served
# read-only from virtio-blk, not from p2/p3. Set LEGACY_PARTS=1 to recreate
# them at full size (costs 3.8 GiB) for a layout closer to the real eMMC.
LEGACY_PARTS="${LEGACY_PARTS:-0}"

# The firmware owns its volume scheme: check-lvm-parts shrinks the PV to a fixed
# size, expects volume names of its own (gamesvar, not gamesusr) and creates
# what is missing. Pre-created volumes only get in its way - it cannot shrink a
# PV whose extents are allocated:
#   /dev/mmcblk0p4: cannot resize to 1502 extents as 1839 are allocated.
#   Volume group "ivg" has insufficient free space (175 extents): 2048 required.
# So ship an empty VG by default and let the guest populate it.
CREATE_LVS="${CREATE_LVS:-0}"

# Size check-lvm-parts resizes the PV to, taken from its own log line:
#   WARNING: /dev/mmcblk0p4: Pretending size is 12312576 not 16508895 sectors.
# Matching it from the start avoids the failing pvresize. 0 = rest of the disk.
P4_SECTORS="${P4_SECTORS:-12312576}"
# Volume sizes as a percentage of the volume group, so the same script works
# from a 4G image up to 64G. Override individually if needed.
PCT_VAR="${PCT_VAR:-30}"
PCT_HOME="${PCT_HOME:-25}"
PCT_LOG="${PCT_LOG:-10}"
PCT_GAMESUSR="${PCT_GAMESUSR:-25}"
FILTER='devices { filter = [ "a|'"$NBD"'p4|", "r|.*|" ] }'

log() { echo -e "\033[32m$1\033[0m"; }
err() { echo -e "\033[31m$1\033[0m" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || err "This script needs root (qemu-nbd + LVM)."
for t in qemu-img qemu-nbd sgdisk pvcreate vgcreate lvcreate mkfs.ext4; do
    command -v "$t" >/dev/null || err "$t is required"
done
[ -e "$OUT" ] && err "$OUT already exists - remove it first"

# Validate the power-of-two requirement early instead of failing at boot with
# "Invalid SD card size".
TOTAL_PCT=$((PCT_VAR + PCT_HOME + PCT_LOG + PCT_GAMESUSR))
[ "$TOTAL_PCT" -le 100 ] || err "volume percentages add up to ${TOTAL_PCT}% (max 100)"

case "$SIZE" in
    4G|8G|16G|32G|64G|128G) ;;
    *) err "SIZE must be a power of two (4G, 8G, 16G, 32G, 64G, 128G) because QEMU's sd-card device requires it" ;;
esac

# Features to disable:
#   quota/project             cause of the check-lvm-parts failure at boot
#   metadata_csum_seed        unknown to the stock 4.14-PLK kernel
#   orphan_file               enabled by default from e2fsprogs 1.47, ditto
# An older mkfs.ext4 rejects the whole -O list when one name is unknown
# ("Invalid filesystem option set"), so only keep the names it recognises.
probe_ext4_features() {
    local probe result="" f
    probe="$(mktemp)"
    truncate -s 16M "$probe"
    for f in "$@"; do
        if mkfs.ext4 -q -n -O "^$f" "$probe" >/dev/null 2>&1; then
            result="${result:+$result,}^$f"
        fi
    done
    rm -f "$probe"
    printf '%s' "$result"
}

EXT4_DISABLE="$(probe_ext4_features quota project metadata_csum_seed orphan_file)"
[ -n "$EXT4_DISABLE" ] || err "mkfs.ext4 rejects even -O ^quota; check your e2fsprogs"
log "ext4 features disabled: $EXT4_DISABLE"

mkdir -p "$(dirname "$OUT")"

cleanup() {
    # Flush before tearing down: data still in the page cache would never reach
    # the qcow2 file and the guest would see an invalid superblock.
    sync
    udevadm settle 2>/dev/null || true
    vgchange -an "$VG" --config "$FILTER" >/dev/null 2>&1 || true
    blockdev --flushbufs "$NBD" 2>/dev/null || true
    qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Create $OUT ($SIZE, sparse qcow2)"
qemu-img create -f qcow2 "$OUT" "$SIZE" >/dev/null

modprobe nbd max_part=16 2>/dev/null || true
log "Connect $NBD"
qemu-nbd --connect="$NBD" "$OUT"
sleep 1

log "Write GPT layout (full-size legacy rootfs partitions: $([ "$LEGACY_PARTS" = 1 ] && echo yes || echo no))"
sgdisk --zap-all "$NBD" >/dev/null
SGDISK_ARGS=( -n 1:0:+128M -c 1:boot -t 1:8300 )
if [ "$LEGACY_PARTS" = "1" ]; then
    SGDISK_ARGS+=(
        -n 2:0:+1900M -c 2:rootfs-a-legacy -t 2:8300
        -n 3:0:+1900M -c 3:rootfs-b-legacy -t 3:8300
    )
else
    # Keep the numbering intact - p4 must remain the LVM PV - but reduce the
    # unused legacy slots to stubs.
    SGDISK_ARGS+=(
        -n 2:0:+1M -c 2:rootfs-a-legacy -t 2:8300
        -n 3:0:+1M -c 3:rootfs-b-legacy -t 3:8300
    )
fi
if [ "$P4_SECTORS" = "0" ]; then
    SGDISK_ARGS+=( -n 4:0:0 -c 4:lvm -t 4:8E00 )
else
    SGDISK_ARGS+=( -n "4:0:+${P4_SECTORS}" -c 4:lvm -t 4:8E00 )
fi
sgdisk "${SGDISK_ARGS[@]}" "$NBD" >/dev/null
partprobe "$NBD" 2>/dev/null || true
sleep 1

log "Format boot partition (ext2)"
mkfs.ext2 -q -L boot "${NBD}p1"

log "Create PV/VG $VG on ${NBD}p4"
pvcreate -ff -y "${NBD}p4" --config "$FILTER" >/dev/null
vgcreate "$VG" "${NBD}p4" --config "$FILTER" >/dev/null

# name:percent-of-VG - only used when CREATE_LVS=1.
VOLUMES=(
    "var:$PCT_VAR"
    "home:$PCT_HOME"
    "log:$PCT_LOG"
    "gamesusr:$PCT_GAMESUSR"
)

if [ "$CREATE_LVS" = "1" ]; then
    for entry in "${VOLUMES[@]}"; do
        name="${entry%%:*}"
        pct="${entry##*:}"
        log "Create LV $name (${pct}%VG) + ext4 without quota"
        lvcreate -y -n "$name" -l "${pct}%VG" "$VG" --config "$FILTER" >/dev/null
        mkfs.ext4 -q -O "$EXT4_DISABLE" -L "$name" "/dev/$VG/$name"
        tune2fs -O ^quota,^project "/dev/$VG/$name" >/dev/null
    done
else
    log "Leave the VG empty: check-lvm-parts creates its own volumes"
    VOLUMES=()
fi

log "Result"
vgs "$VG" --config "$FILTER" || true
lvs "$VG" --config "$FILTER" || true

cleanup
trap - EXIT

# --- verification --------------------------------------------------------
# Re-read the image the way the guest will, so a silent write failure is
# caught here rather than by check-lvm-parts mid-boot.
log "Verify the result"
qemu-nbd --connect="$NBD" "$OUT"
sleep 1
vgchange -ay "$VG" --config "$FILTER" >/dev/null 2>&1 || true
udevadm settle 2>/dev/null || true
VERIFY_FAILED=0
if [ "${#VOLUMES[@]}" -eq 0 ]; then
    FREE="$(vgs --noheadings -o vg_free_count "$VG" --config "$FILTER" 2>/dev/null | tr -d ' ')"
    echo "  VG $VG created, $FREE free extent(s) for the guest"
fi
for entry in "${VOLUMES[@]+"${VOLUMES[@]}"}"; do
    name="${entry%%:*}"
    if dumpe2fs -h "/dev/mapper/${VG}-${name}" >/dev/null 2>&1; then
        echo "  OK   /dev/mapper/${VG}-${name}"
    else
        echo "  FAIL /dev/mapper/${VG}-${name} (invalid superblock)"
        VERIFY_FAILED=1
    fi
done
vgchange -an "$VG" --config "$FILTER" >/dev/null 2>&1 || true
qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
[ "$VERIFY_FAILED" = 0 ] || err "verification failed: the guest would reformat these volumes at boot"

chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "$OUT" 2>/dev/null || true
log "DONE: $OUT"
