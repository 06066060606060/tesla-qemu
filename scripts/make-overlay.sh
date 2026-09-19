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
# Reference: ROOT Tesla OS on QEMU Part 2 - Debugging + fixing
# https://cn0xroot.wordpress.com/2026/09/20/root_tesla_os_on_qemu_part_2_debugging_fixing/
set -euo pipefail

OUT="${1:-out/overlay.qcow2}"
# QEMU's sd-card device only accepts capacities that are a power of two,
# so keep this at 8G / 16G / 32G / 64G.
SIZE="${SIZE:-32G}"
NBD="${NBD:-/dev/nbd0}"
VG="${VG:-ivg}"
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
case "$SIZE" in
    4G|8G|16G|32G|64G|128G) ;;
    *) err "SIZE must be a power of two (4G, 8G, 16G, 32G, 64G, 128G) because QEMU's sd-card device requires it" ;;
esac

mkdir -p "$(dirname "$OUT")"

cleanup() {
    vgchange -an "$VG" --config "$FILTER" >/dev/null 2>&1 || true
    qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Create $OUT ($SIZE, sparse qcow2)"
qemu-img create -f qcow2 "$OUT" "$SIZE" >/dev/null

modprobe nbd max_part=16 2>/dev/null || true
log "Connect $NBD"
qemu-nbd --connect="$NBD" "$OUT"
sleep 1

log "Write GPT layout"
sgdisk --zap-all "$NBD" >/dev/null
sgdisk \
    -n 1:0:+128M   -c 1:boot            -t 1:8300 \
    -n 2:0:+1900M  -c 2:rootfs-a-legacy -t 2:8300 \
    -n 3:0:+1900M  -c 3:rootfs-b-legacy -t 3:8300 \
    -n 4:0:0       -c 4:lvm             -t 4:8E00 \
    "$NBD" >/dev/null
partprobe "$NBD" 2>/dev/null || true
sleep 1

log "Format boot partition (ext2)"
mkfs.ext2 -q -L boot "${NBD}p1"

log "Create PV/VG $VG on ${NBD}p4"
pvcreate -ff -y "${NBD}p4" --config "$FILTER" >/dev/null
vgcreate "$VG" "${NBD}p4" --config "$FILTER" >/dev/null

# name:size - adjust freely, the VG has room left for more.
VOLUMES=(
    "var:4G"
    "home:4G"
    "log:2G"
    "gamesusr:8G"
)

for entry in "${VOLUMES[@]}"; do
    name="${entry%%:*}"
    size="${entry##*:}"
    log "Create LV $name ($size) + ext4 without quota"
    lvcreate -y -n "$name" -L "$size" "$VG" --config "$FILTER" >/dev/null
    mkfs.ext4 -q -O ^quota,^project -L "$name" "/dev/$VG/$name"
    tune2fs -O ^quota,^project "/dev/$VG/$name" >/dev/null
done

log "Result"
lvs "$VG" --config "$FILTER" || true

cleanup
trap - EXIT

chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "$OUT" 2>/dev/null || true
log "DONE: $OUT"
