#!/bin/bash
# Offline repair of the overlay disk: run e2fsck and strip the ext4 quota
# feature from every logical volume of the "ivg" volume group.
#
# Symptom this fixes (visible on the serial console):
#   EXT4-fs (dm-N): The kernel was not built with CONFIG_QUOTA ...
#   -> the volume is mounted read-only and QtCar/runit services fail.
#
# The guest rootfs is patched by scripts/prepare-rootfs.sh so it stops
# re-enabling quota, but an overlay written by an earlier boot still carries
# the feature flag. Clean it here with the VM stopped.
#
# Usage: sudo ./scripts/fix-lvm-quota.sh [out/overlay.qcow2]
#
# Reference: ROOT Tesla OS on QEMU Part 2 - Debugging + fixing
# https://cn0xroot.wordpress.com/2026/09/20/root_tesla_os_on_qemu_part_2_debugging_fixing/
set -euo pipefail

IMG="${1:-out/overlay.qcow2}"
NBD="${NBD:-/dev/nbd0}"
VG="${VG:-ivg}"
FILTER='devices { filter = [ "a|'"$NBD"'p4|", "r|.*|" ] }'

log() { echo -e "\033[32m$1\033[0m"; }
err() { echo -e "\033[31m$1\033[0m" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || err "This script needs root (qemu-nbd + LVM)."
[ -f "$IMG" ] || err "$IMG not found"
for t in qemu-nbd vgscan vgchange lvs e2fsck tune2fs; do
    command -v "$t" >/dev/null || err "$t is required"
done

cleanup() {
    vgchange -an "$VG" --config "$FILTER" >/dev/null 2>&1 || true
    qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
}
trap cleanup EXIT

modprobe nbd max_part=16 2>/dev/null || true
log "Connect $IMG to $NBD"
qemu-nbd --connect="$NBD" "$IMG"
sleep 1

# The LVM filter keeps the host's own volume groups out of the way.
vgscan --config "$FILTER" >/dev/null
vgchange -ay "$VG" --config "$FILTER" >/dev/null

mapfile -t LVS < <(lvs --noheadings -o lv_name "$VG" --config "$FILTER" | awk '{print $1}')
[ "${#LVS[@]}" -gt 0 ] || err "no logical volumes found in vg $VG"

for lv in "${LVS[@]}"; do
    dev="/dev/mapper/${VG}-${lv}"
    [ -e "$dev" ] || dev="/dev/$VG/$lv"
    log "=== $lv ($dev)"
    e2fsck -fy "$dev" || true
    tune2fs -O ^quota,^project "$dev" >/dev/null || true
    e2fsck -fy "$dev" || true
    tune2fs -l "$dev" | grep -E '^Filesystem features' || true
done

cleanup
trap - EXIT
log "DONE - overlay volumes are clean and quota-free"
