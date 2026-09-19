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
OVERLAY_IF="${OVERLAY_IF:-virtio}"   # virtio | sd
# A panic must stop the VM, not restart it: an immediate reboot scrolls the
# cause off the console and looks like a boot loop. PANIC=1 restores the
# hardware behaviour (reboot after 1 s).
PANIC="${PANIC:-0}"
RESOLUTION="${RESOLUTION:-1200x1920}"
WIDTH="${RESOLUTION%x*}"
HEIGHT="${RESOLUTION#*x}"
DISPLAY_BACKEND="${DISPLAY_BACKEND:-sdl}"
SERIAL_LOG="${SERIAL_LOG:-./out/serial.log}"
NET="${NET:-user}"          # user | tap
TAP="${TAP:-tap0}"
KVM="${KVM:-1}"
GL="${GL:-off}"             # off = 2D scanout (recommended), on = virtio-vga-gl
NIC="${NIC:-auto}"          # auto | igb | e1000e | e1000 | virtio-net-pci

err() { echo -e "\033[31m$1\033[0m" >&2; exit 1; }

[ -f "$KERNEL" ]   || err "kernel '$KERNEL' not found (see docs/native-boot.md)"
[ -f "$INITRD" ]   || err "initrd '$INITRD' not found - run ./scripts/build-initrd-custom.sh"
[ -f "$SQUASHFS" ] || err "rootfs '$SQUASHFS' not found - run ./scripts/prepare-rootfs.sh <firmware.squashfs>"
[ -f "$OVERLAY" ]  || err "overlay '$OVERLAY' not found - run sudo ./scripts/make-overlay.sh"

# QEMU's sd-card device rejects any capacity that is not a power of two.
if [ "$OVERLAY_IF" = "sd" ]; then
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
fi

# The real MCU2 uses an Intel igb NIC and the firmware ships igb.ko, so that is
# the first choice - but QEMU only gained the 'igb' model in 8.2, hence the
# fallback chain. With a non-Tesla kernel (e.g. vmlinuz-lts) any model works.
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
if [ "$NIC" = "auto" ]; then
    AVAILABLE="$("$QEMU_BIN" -device help 2>/dev/null || true)"
    NIC=""
    for candidate in igb e1000e e1000 virtio-net-pci; do
        if printf '%s' "$AVAILABLE" | grep -q "\"$candidate\""; then
            NIC="$candidate"
            break
        fi
    done
    [ -n "$NIC" ] || NIC="virtio-net-pci"
    if [ "$NIC" != "igb" ]; then
        echo "note: this QEMU has no 'igb' device model (added in QEMU 8.2), using '$NIC'"
        echo "      a stock Tesla kernel may not have a driver for it; set NIC=... to override"
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
    -append "console=tty0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel panic=${PANIC} security=apparmor apparmor=1 intel_xhci_usb_role_switch.default_role=1 modprobe.blacklist=dwc3 rng_core.default_quality=1000 rcupdate.rcu_cpu_stall_timeout=60 net.ifnames=0 biosdevname=0 video=${RESOLUTION}"
)

if [ "$PANIC" = "0" ]; then
    # Without this QEMU restarts on triple fault / reboot() and the boot
    # appears to loop forever.
    ARGS+=( -no-reboot )
fi

# Read-only rootfs (squashfs) on virtio-blk -> /dev/vda, mounted by custom_init.
ARGS+=( -drive "if=virtio,file=$SQUASHFS,format=raw,readonly=on" )

# Writable overlay carrying the LVM volumes (var/home/log/gamesusr).
# OVERLAY_IF=sd reproduces the real hardware (/dev/mmcblk0), but QEMU's SD
# emulation is fragile: power-of-two capacity only, and writes are unreliable
# on some versions, which shows up as check-lvm-parts reformatting ivg-var at
# every boot. LVM finds its PV by scanning, so virtio-blk (/dev/vdb) works just
# as well and is the default.
case "$OVERLAY_IF" in
    virtio)
        ARGS+=( -drive "if=virtio,file=$OVERLAY,format=qcow2" )
        echo "overlay: virtio-blk (/dev/vdb)"
        ;;
    sd)
        ARGS+=(
            -device sdhci-pci
            -device sd-card,drive=mmc0
            -drive "if=none,id=mmc0,format=qcow2,file=$OVERLAY"
        )
        echo "overlay: SD/eMMC (/dev/mmcblk0)"
        ;;
    *)
        err "OVERLAY_IF must be 'virtio' or 'sd' (got '$OVERLAY_IF')"
        ;;
esac

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
            -netdev "user,id=net0,net=192.168.90.0/24,host=192.168.90.2,dhcpstart=192.168.90.100,hostfwd=tcp::2222-192.168.90.100:22"
            -device "$NIC,netdev=net0"
        )
        echo "network: user mode ($NIC), ssh -p 2222 root@localhost"
        ;;
    tap)
        ARGS+=(
            -netdev "tap,id=net0,ifname=$TAP,script=no,downscript=no"
            -device "$NIC,netdev=net0"
        )
        echo "network: $TAP ($NIC), ssh root@192.168.90.100"
        ;;
    *)
        err "NET must be 'user' or 'tap'"
        ;;
esac

ARGS+=( -serial "file:$SERIAL_LOG" -serial stdio )

echo "serial log: $SERIAL_LOG"
exec qemu-system-x86_64 "${ARGS[@]}"
