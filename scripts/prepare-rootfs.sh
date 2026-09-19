#!/bin/bash
# Unpack a stock Tesla squashfs, apply the fixes needed to boot the full
# runit userland under QEMU, and repack it as an edited squashfs image.
#
#   ./scripts/prepare-rootfs.sh firmware/2026.8.3.squashfs \
#        [out/rootfs_edited.squashfs]
#
# Fixes applied (all optional, each one is skipped with a warning if the
# matching file is absent in this firmware version):
#
#   1. check-lvm-parts: crypt_partitions="" — the stock script cannot create
#      LUKS containers without the real TPM, so luks_formatted() never turns
#      true and `wipefs -a` reformats var/home/log on *every* boot. Clearing
#      the list keeps the volumes plain and cuts LVM bring-up from 700+ s to
#      roughly 100 s.
#   2. ext4_tune(): stop re-adding usrquota/grpquota/prjquota — a kernel built
#      without CONFIG_QUOTA/CONFIG_QFMT_V2 mounts those filesystems read-only.
#   3. fstab: drop the quota mount options for /opt/games/usr and friends.
#   4. rcu_cpu_stall_timeout: 3 s -> 60 s, otherwise virtio-gpu triggers
#      "rcu_preempt self-detected stall on CPU" during boot.
#   5. Xorg: restore the stock evdev autodetection (AutoAddDevices true) and
#      remove the void/libinput driver sections whose modules do not exist
#      (they abort the server with a dixGetPrivateAddr assertion).
#   6. AppArmor: allow the second DRM node (card1 / renderD129) used by
#      virtio-gpu-pci, and drop the unmodifiable Xorg profile.
#
# Reference: ROOT Tesla OS on QEMU Part 2 - Debugging + fixing
# https://cn0xroot.wordpress.com/2026/09/20/root_tesla_os_on_qemu_part_2_debugging_fixing/
set -euo pipefail

IMG="${1:-}"
OUT="${2:-out/rootfs_edited.squashfs}"
ROOT_DIR="${ROOT_DIR:-out/squashfs-root}"

log()  { echo -e "\033[32m$1\033[0m"; }
warn() { echo -e "\033[33mWARN: $1\033[0m" >&2; }
err()  { echo -e "\033[31m$1\033[0m" >&2; exit 1; }

[ -n "$IMG" ] || err "Usage: $0 <firmware.squashfs> [out.squashfs]"
[ -f "$IMG" ] || err "Input file '$IMG' does not exist"
command -v unsquashfs >/dev/null || err "squashfs-tools is required"
command -v mksquashfs >/dev/null || err "squashfs-tools is required"

mkdir -p out

log "Unpack $IMG -> $ROOT_DIR"
sudo rm -rf "$ROOT_DIR"
sudo unsquashfs -d "$ROOT_DIR" -f "$IMG" | tail -5

R="$ROOT_DIR"

# --- 1 + 2: LVM bring-up script ------------------------------------------
LVM_SCRIPT="$(sudo grep -rl 'luks_format_and_open\|check-lvm-parts' \
    "$R/etc" "$R/usr/bin" "$R/usr/sbin" "$R/sbin" 2>/dev/null | head -1 || true)"

if [ -n "$LVM_SCRIPT" ]; then
    log "Patch LVM script: $(realpath --relative-to="$R" "$LVM_SCRIPT")"
    sudo cp -n "$LVM_SCRIPT" "$LVM_SCRIPT.orig"

    # 1. No LUKS volumes -> no wipefs -a on every boot.
    sudo sed -i -E 's@^([[:space:]]*)crypt_partitions=.*@\1crypt_partitions=""  # qemu: no TPM, keep volumes plain@' \
        "$LVM_SCRIPT"

    # 2. Never re-enable ext4 quota features.
    sudo python3 - "$LVM_SCRIPT" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
new, n = re.subn(r'(\n\s*)(tune2fs\s+-Q\s+[^\n]*)', r'\1: # qemu: quota disabled (\2)', s)
if n:
    open(p, 'w').write(new)
    print(f"  disabled {n} tune2fs -Q call(s)")
else:
    print("  no tune2fs -Q call found (nothing to do)")
PY
else
    warn "check-lvm-parts / luks_format_and_open script not found"
fi

# --- 3: fstab quota options ---------------------------------------------
if [ -f "$R/etc/fstab" ]; then
    log "Strip quota mount options from /etc/fstab"
    sudo cp -n "$R/etc/fstab" "$R/etc/fstab.orig"
    sudo sed -i -E 's@,?(usr|grp|prj)quota@@g' "$R/etc/fstab"
else
    warn "/etc/fstab not found"
fi

# --- 4: RCU stall timeout ----------------------------------------------
RCU_FILES="$(sudo grep -rl 'rcu_cpu_stall_timeout' "$R/etc" 2>/dev/null || true)"
if [ -n "$RCU_FILES" ]; then
    for f in $RCU_FILES; do
        log "Raise rcu_cpu_stall_timeout to 60 in $(realpath --relative-to="$R" "$f")"
        sudo cp -n "$f" "$f.orig"
        sudo sed -i -E 's@echo[[:space:]]+[0-9]+([[:space:]]*>[[:space:]]*/sys/module/rcupdate/parameters/rcu_cpu_stall_timeout)@echo 60\1@' "$f"
    done
else
    warn "rcu_cpu_stall_timeout not set by the rootfs (kernel default applies)"
fi

# --- 4b: load the QEMU device drivers early -----------------------------
if [ -f "$R/etc/runit/1" ]; then
    if ! sudo grep -q 'qemu: load virtual hardware modules' "$R/etc/runit/1"; then
        log "Add modprobe lines for QEMU devices to /etc/runit/1"
        sudo cp -n "$R/etc/runit/1" "$R/etc/runit/1.orig"
        sudo tee -a "$R/etc/runit/1" >/dev/null <<'EOF'

# qemu: load virtual hardware modules (built as modules in our kernel config)
for m in xhci-pci usbhid igb virtio_gpu virtio_blk virtio_net evdev uinput; do
    modprobe "$m" 2>/dev/null
done
EOF
    fi
else
    warn "/etc/runit/1 not found"
fi

# --- 5: Xorg input configuration ----------------------------------------
XCONF_DIR="$R/etc/X11/xorg.conf.d"
if [ -d "$XCONF_DIR" ]; then
    log "Restore stock evdev autodetection in xorg.conf.d"
    for f in "$XCONF_DIR"/*.conf; do
        [ -f "$f" ] || continue
        sudo sed -i -E 's@(Option[[:space:]]+"AutoAddDevices"[[:space:]]+)"false"@\1"true"@; s@(Option[[:space:]]+"AutoEnableDevices"[[:space:]]+)"false"@\1"true"@' "$f"
    done
    # Drop sections pointing at drivers that are not shipped in the image.
    for drv in void libinput; do
        if [ ! -f "$R/usr/lib/xorg/modules/input/${drv}_drv.so" ]; then
            hits="$(sudo grep -rl "\"$drv\"" "$XCONF_DIR" 2>/dev/null || true)"
            for f in $hits; do
                log "Disable missing Xorg driver '$drv' in $(basename "$f")"
                sudo mv "$f" "$f.disabled"
            done
        fi
    done
    [ -f "$R/usr/share/X11/xorg.conf.d/10-evdev.conf" ] || \
        warn "10-evdev.conf missing; input autodetection may still fail"
else
    warn "$XCONF_DIR not found"
fi

# --- 6: AppArmor DRM nodes ----------------------------------------------
AA_DIR="$R/etc/apparmor.d"
if [ -d "$AA_DIR" ]; then
    log "Grant AppArmor access to card1 / renderD129"
    sudo python3 - "$AA_DIR" <<'PY'
import os, re, sys
d = sys.argv[1]
changed = []
for root, _, files in os.walk(d):
    for name in files:
        p = os.path.join(root, name)
        try:
            s = open(p).read()
        except (OSError, UnicodeDecodeError):
            continue
        out = s
        for src, dst in (("card0", "card1"), ("renderD128", "renderD129")):
            for line in set(re.findall(r'^.*/dev/dri/%s.*$' % src, out, re.M)):
                if line.replace(src, dst) not in out:
                    out = out.replace(line, line + "\n" + line.replace(src, dst), 1)
        if out != s:
            open(p, "w").write(out)
            changed.append(os.path.relpath(p, d))
print("  updated: " + (", ".join(changed) if changed else "nothing"))
PY
    for prof in "$AA_DIR"/*Xorg* "$AA_DIR"/*xorg*; do
        [ -f "$prof" ] || continue
        log "Remove Xorg AppArmor profile $(basename "$prof")"
        sudo mv "$prof" "$prof.disabled"
    done
else
    warn "$AA_DIR not found (AppArmor profiles unchanged)"
fi

# --- repack --------------------------------------------------------------
log "Repack -> $OUT"
sudo rm -f "$OUT"
sudo mksquashfs "$R" "$OUT" -comp zstd -noappend -no-progress | tail -5
sudo chown "$(id -u):$(id -g)" "$OUT"

log "DONE: $OUT"
log "Next: ./scripts/make-overlay.sh && ./qemu/start-native.sh"
