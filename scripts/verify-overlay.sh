#!/bin/bash
# Check an existing overlay image the way the guest reads it: activate the VG
# and confirm each logical volume carries a valid ext4 superblock with no
# feature the stock kernel would reject.
#
# Usage: sudo ./scripts/verify-overlay.sh [out/overlay.qcow2]
#
# A FAIL here is exactly what makes check-lvm-parts print
# "Bad magic number in super-block" and reformat the volume at boot.
set -euo pipefail

OUT="${1:-out/overlay.qcow2}"
NBD="${NBD:-/dev/nbd0}"
VG="${VG:-ivg}"
# use_lvmetad was removed in LVM 2.03; only pass it to versions that know it,
# otherwise every command prints "Configuration setting unknown".
LVMETAD=""
if lvm version 2>/dev/null | grep -qE 'LVM version: *2\.0[12]'; then
    LVMETAD=" use_lvmetad = 0"
fi
FILTER='devices { filter = [ "a|'"$NBD"'p4|", "r|.*|" ] global_filter = [ "a|'"$NBD"'p4|", "r|.*|" ]'"$LVMETAD"' }'

log()  { echo -e "\033[32m$1\033[0m"; }
err()  { echo -e "\033[31m$1\033[0m" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || err "This script needs root (qemu-nbd + LVM)."
[ -f "$OUT" ] || err "Image '$OUT' does not exist"
for t in qemu-nbd dumpe2fs vgchange lvs; do
    command -v "$t" >/dev/null || err "missing tool: $t"
done

cleanup() {
    vgchange -an "$VG" --config "$FILTER" >/dev/null 2>&1 || true
    qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
}
trap cleanup EXIT

modprobe nbd max_part=16 2>/dev/null || true
qemu-nbd --connect="$NBD" "$OUT"
sleep 1

log "Partitions"
sgdisk -p "$NBD" 2>/dev/null | tail -n +6 || true

log "Activate VG $VG"
vgchange -ay "$VG" --config "$FILTER" >/dev/null || err "VG '$VG' not found: was the image built by make-overlay.sh?"
udevadm settle 2>/dev/null || true
lvs "$VG" --config "$FILTER" || true

log "Check the filesystems"
FAILED=0
for dev in /dev/mapper/${VG}-*; do
    [ -e "$dev" ] || continue
    if INFO="$(dumpe2fs -h "$dev" 2>/dev/null)"; then
        FEATURES="$(echo "$INFO" | sed -n 's/^Filesystem features: *//p')"
        BAD=""
        for f in quota project metadata_csum_seed orphan_file; do
            case " $FEATURES " in *" $f "*) BAD="$BAD $f" ;; esac
        done
        if [ -n "$BAD" ]; then
            echo -e "  \033[33mWARN\033[0m $dev: unwanted feature(s):$BAD"
            FAILED=1
        else
            echo -e "  \033[32mOK\033[0m   $dev"
        fi
    else
        echo -e "  \033[31mFAIL\033[0m $dev: invalid ext4 superblock"
        FAILED=1
    fi
done

if [ "$FAILED" = 0 ]; then
    log "DONE: every volume is valid"
else
    err "Some volumes are unusable. Rebuild: sudo ./scripts/make-overlay.sh
Or repair quota in place: sudo ./scripts/fix-lvm-quota.sh $OUT"
fi
