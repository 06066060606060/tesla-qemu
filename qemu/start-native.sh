#!/bin/bash
# Native-boot launcher: stock Tesla kernel + custom initramfs + edited squashfs.
#
# Differences with qemu/start.sh (the Alpine-kernel path):
#   - boots the Tesla bzImage extracted from bank_a.iasImage, not vmlinuz-lts
#   - the rootfs stays a read-only squashfs on virtio-blk; no 6 GB ext4 copy
#   - a separate SD/eMMC overlay (/dev/mmcblk0) carries the LVM volumes
#     var / home / log / gamesusr, so runit boots the real service tree
#   - virtio-vga in plain 2D scanout: virtio-vga-gl + virgl proved unstable
#     with the host GL stack, while 2D scanout renders the UI reliably
#
# Usage:
#   ./scripts/build-initrd-custom.sh
#   ./scripts/prepare-rootfs.sh firmware/2026.8.3.squashfs
#   sudo ./scripts/make-overlay.sh
#   ./qemu/start-native.sh
#
# Reference: ROOT Tesla OS on QEMU Part 2 - Debugging + fixing
# https://cn0xroot.wordpress.com/2026/09/20/root_tesla_os_on_qemu_part_2_debugging_fixing/
set -euo pipefail

RAM="${RAM:-8192}"
SMP="${SMP:-4}"
KERNEL="${KERNEL:-./out/bzImage}"
INITRD="${INITRD:-./out/initrd_custom.cpio.gz}"
SQUASHFS="${SQUASHFS:-./out/rootfs_edited.squashfs}"
OVERLAY="${OVERLAY:-./out/overlay.qcow2}"
RESOLUTION="${RESOLUTION:-1200x1920}"
WIDTH="${RESOLUTION%x*}"
HEIGHT="${RESOLUTION#*x}"
DISPLAY_BACKEND="${DISPLAY_BACKEND:-sdl}"
SERIAL_LOG="${SERIAL_LOG:-./out/serial.log}"
NET="${NET:-user}"          # user | tap
TAP="${TAP:-tap0}"
KVM="${KVM:-1}"
GL="${GL:-off}"             # off = 2D scanout (recommended), on = virtio-vga-gl

err() { echo -e "\033[31m$1\033[0m" >&2; exit 1; }

[ -f "$KERNEL" ]   || err "kernel '$KERNEL' not found (see docs/native-boot.md)"
[ -f "$INITRD" ]   || err "initrd '$INITRD' not found - run ./scripts/build-initrd-custom.sh"
[ -f "$SQUASHFS" ] || err "rootfs '$SQUASHFS' not found - run ./scripts/prepare-rootfs.sh <firmware.squashfs>"
[ -f "$OVERLAY" ]  || err "overlay '$OVERLAY' not found - run sudo ./scripts/make-overlay.sh"

# QEMU's sd-card device rejects any capacity that is not a power of two.
if command -v qemu-img >/dev/null; then
    OVERLAY_BYTES="$(qemu-img info --output=json "$OVERLAY" 2>/dev/null |
        sed -n 's/.*"virtual-size": *\([0-9]*\).*/\1/p' | head -1)"
    if [ -n "$OVERLAY_BYTES" ] && [ $((OVERLAY_BYTES & (OVERLAY_BYTES - 1))) -ne 0 ]; then
        NEXT=1
        while [ "$NEXT" -lt "$OVERLAY_BYTES" ]; do NEXT=$((NEXT * 2)); done
        err "overlay '$OVERLAY' is $OVERLAY_BYTES bytes; QEMU's sd-card needs a power-of-two size.
Fix it with:  qemu-img resize $OVERLAY $((NEXT / 1024 / 1024 / 1024))G"
    fi
fi

mkdir -p "$(dirname "$SERIAL_LOG")"

ARGS=(
    -M q35
    -m "$RAM"
    -smp "$SMP"
    -kernel "$KERNEL"
    -initrd "$INITRD"
)

if [ "$KVM" = "1" ]; then
    ARGS+=( -cpu host -enable-kvm )
else
    ARGS+=( -cpu qemu64 )
fi

# rng_core.default_quality=1000 keeps the boot from blocking on entropy;
# the dwc3 blacklist avoids a long USB role-switch probe that does not exist
# in QEMU.
ARGS+=(
    -append "console=tty0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel panic=1 security=apparmor apparmor=1 intel_xhci_usb_role_switch.default_role=1 modprobe.blacklist=dwc3 rng_core.default_quality=1000 rcupdate.rcu_cpu_stall_timeout=60 video=${RESOLUTION}"
)

# Read-only rootfs (squashfs) on virtio-blk -> /dev/vda, mounted by custom_init.
ARGS+=( -drive "if=virtio,file=$SQUASHFS,format=raw,readonly=on" )

# Writable overlay as an SD/eMMC device -> /dev/mmcblk0 (LVM: var/home/log).
ARGS+=(
    -device sdhci-pci
    -device sd-card,drive=mmc0
    -drive "if=none,id=mmc0,format=qcow2,file=$OVERLAY"
)

# Display. 2D scanout by default: virgl segfaulted in the host GL driver and
# triggered RCU stalls in the guest.
if [ "$GL" = "on" ]; then
    ARGS+=(
        -device "virtio-vga-gl,edid=on,xres=$WIDTH,yres=$HEIGHT"
        -display "${DISPLAY_BACKEND},gl=on"
    )
else
    ARGS+=(
        -device "virtio-vga,edid=on,xres=$WIDTH,yres=$HEIGHT"
        -display "$DISPLAY_BACKEND"
    )
fi

# Input: xHCI + USB keyboard/tablet (absolute coordinates for the touch proxy).
ARGS+=(
    -device qemu-xhci
    -device usb-kbd
    -device usb-tablet
)

# Networking. "user" needs no root; "tap" matches ./create-tap.sh.
case "$NET" in
    user)
        ARGS+=(
            -netdev "user,id=net0,net=192.168.90.0/24,host=192.168.90.2,hostfwd=tcp::2222-192.168.90.100:22"
            -device igb,netdev=net0
        )
        echo "network: user mode, ssh -p 2222 root@localhost"
        ;;
    tap)
        ARGS+=(
            -netdev "tap,id=net0,ifname=$TAP,script=no,downscript=no"
            -device igb,netdev=net0
        )
        echo "network: $TAP, ssh root@192.168.90.100"
        ;;
    *)
        err "NET must be 'user' or 'tap'"
        ;;
esac

ARGS+=( -serial "file:$SERIAL_LOG" -serial stdio )

echo "serial log: $SERIAL_LOG"
exec qemu-system-x86_64 "${ARGS[@]}"
