# Native boot path (stock kernel + squashfs + LVM overlay)

This is an alternative to the Alpine-kernel path documented in the README.
Instead of copying the firmware into a 6 GB ext4 disk and starting QtCar by
hand, it boots the **stock Tesla kernel** with a small custom `init` that
mounts the **edited squashfs read-only** and hands over to `/sbin/init`
(runit), so the real service tree comes up.

Everything below follows the debugging write-up
[ROOT Tesla OS on QEMU Part 2 – Debugging + fixing](https://cn0xroot.wordpress.com/2026/09/20/root_tesla_os_on_qemu_part_2_debugging_fixing/),
adapted to this repository.

## Boot chain

```
QEMU -kernel bzImage -initrd initrd_custom.cpio.gz
  └── /init  (tools/custom_init.c, PID 1)
        ├── mount /dev/vda (squashfs, ro) on /mnt
        ├── MS_MOVE + chroot            ← no dm-verity, no dm-linear
        └── execve /sbin/init  (runit-init)
              └── /etc/runit/1 → runsvdir → /etc/sv/*
```

On a real MCU2 the rootfs is not the raw partition: init builds a `dm-linear`
device from `p2` (or `p3`) plus a 1 GiB region "borrowed" from the end of the
LVM partition `p4`, then validates it with an RSA-signed `dm-verity`
superblock (`/etc/verity-prod.pub`). Mounting the squashfs directly skips both
the signature check and the device assembly, which is what makes an edited
rootfs bootable.

Note on the borrow offset if you ever rebuild that device yourself: the stock
code computes the sector count as `(BLKGETSIZE64(p4) >> 12) << 3`, i.e. it
rounds the partition down to whole 4 KiB pages. Using `size // 512` instead
shifts the borrowed region (by 3072 bytes on the published dump) and the
squashfs directory table lands mid-block.

## What you need

| Artifact | Where it comes from |
|---|---|
| `out/bzImage` | `scripts/extract_iasImage.py boot/bank_a.iasImage out/` |
| `out/initrd_custom.cpio.gz` | `./scripts/build-initrd-custom.sh` |
| `out/rootfs_edited.squashfs` | `./scripts/prepare-rootfs.sh firmware/<version>.squashfs` |
| `out/overlay.qcow2` | `sudo ./scripts/make-overlay.sh` |

If you only have the squashfs and no `iasImage`, use any x86_64 kernel that
has `squashfs`, `virtio_blk`, `virtio_gpu`, `sdhci`, `ext4`, `dm-mod` and
`igb` built in, and set `KERNEL=...` when starting. Modules only present in
the rootfs as `/lib/modules/4.14.334-PLK` will not load against a different
kernel version, so prefer a kernel with those drivers built in (`=y`) or
rebuild and `modules_install` into the unpacked rootfs before repacking.

## Quick start

```bash
./scripts/build-initrd-custom.sh
./scripts/prepare-rootfs.sh firmware/2026.8.3.squashfs
sudo ./scripts/make-overlay.sh
./qemu/start-native.sh
```

### Sizing the overlay

`make-overlay.sh` defaults to an 8 GiB sparse qcow2, which is enough for the
runit services and QtCar state. The size **must be a power of two** — QEMU's
`sd-card` device rejects anything else with `Invalid SD card size`.

```bash
SIZE=4G  sudo ./scripts/make-overlay.sh          # smallest usable image
SIZE=16G LEGACY_PARTS=1 sudo ./scripts/make-overlay.sh
```

The `rootfs-a/b-legacy` partitions are created as 1 MiB stubs by default: the
rootfs is served read-only from virtio-blk, so p2/p3 are never read and their
full 1.9 GiB each would be wasted. `LEGACY_PARTS=1` restores them.

Logical volumes are allocated as a share of the volume group (`var` 30%,
`home` 25%, `log` 10%, `gamesusr` 25%, 10% left free), so the same script works
from 4G upwards. Override with `PCT_VAR`, `PCT_HOME`, `PCT_LOG`,
`PCT_GAMESUSR`. Since the image is sparse, a larger `SIZE` costs no disk until
the guest actually writes.

Launch overrides: `RAM`, `SMP`, `RESOLUTION`, `DISPLAY_BACKEND`, `KERNEL`,
`INITRD`, `SQUASHFS`, `OVERLAY`, `NET` (`user` or `tap`), `GL` (`off`/`on`),
`KVM`.

SSH: `ssh -p 2222 root@localhost` with `NET=user`, or
`ssh root@192.168.90.100` with `NET=tap` after `./create-tap.sh`.

## Fixes applied, and why

### LVM volumes reformatted on every boot

`check-lvm-parts` calls `luks_format_and_open()`, which starts with
`wipefs -a` on the volume data path. Without the original TPM the LUKS
container is never actually created, `luks_formatted` keeps returning false,
and each boot wipes the previous signatures — `var`, `home` and `log` are
reformatted every time and the LVM stage takes 700+ seconds.

`scripts/prepare-rootfs.sh` sets `crypt_partitions=""` so the volumes stay
plain. Bring-up drops to roughly 100 s and `e2fsck` passes on all volumes.

### `EXT4-fs: The kernel was not built with CONFIG_QUOTA`

The stock `ext4_tune()` re-adds `usrquota,grpquota,prjquota` to `home` and
`gamesusr` on every boot, and `/etc/fstab` mounts `/opt/games/usr` with the
same options. A kernel without `CONFIG_QUOTA`/`CONFIG_QFMT_V2` then mounts
those filesystems read-only. The prepare script neutralises the `tune2fs -Q`
call and strips the quota mount options; `scripts/make-overlay.sh` formats
with `-O ^quota,^project`. For an overlay that already carries the flag, run
`sudo ./scripts/fix-lvm-quota.sh out/overlay.qcow2` with the VM stopped.

### `rcu_preempt self-detected stall on CPU`

The firmware sets `rcu_cpu_stall_timeout` to 3 seconds, which virtio-gpu work
easily exceeds inside a VM. Both the rootfs patch and the kernel command line
in `start-native.sh` raise it to 60 s.

### No input devices in Xorg

Turning `AutoAddDevices` off silences udev discovery entirely
(`AutoAddDevices is off - not adding device`). The real cause was config
sections referencing `void_drv.so` / `libinput_drv.so`, which are not shipped
— the missing modules leave input privates uninitialised and Xorg aborts with
`dixGetPrivateAddr: Assertion 'key->initialized' failed`. The fix is to keep
`AutoAddDevices true`, keep the stock `10-evdev.conf`, and remove the sections
for drivers that do not exist.

### AppArmor denies the second DRM node

With `bochs-drm` present, virtio-gpu becomes `card1`/`renderD129` and the
stock profiles only allow `card0`/`renderD128`:

```
apparmor="DENIED" operation="open" profile="/usr/bin/Xorg" name="/dev/dri/card1"
```

The prepare script duplicates the `card0`/`renderD128` rules for the second
node and disables the Xorg profile.

### 3D acceleration

`virtio-vga-gl` + `-display sdl,gl=on` was not usable: `eglMakeCurrent failed:
EGL_BAD_ACCESS` and segfaults inside the host NVIDIA GLX library, and
`LIBGL_ALWAYS_SOFTWARE=1` / `__GLX_VENDOR_LIBRARY_NAME=mesa` did not stabilise
it. Plain `virtio-vga` with 2D scanout renders the UI (Factory Net badge, map
grid, task bar, icons, animations) without guest 3D. `GL=on` is available in
`start-native.sh` if you want to retry virgl on your host.

There is also an ABI gap worth knowing about: the firmware ships Mesa 19.0.6,
so its `libGL`/DRI modules cannot load a modern host driver
(`MESA-LOADER: failed to open virtio_gpu`, `core dri driver extension not
found`). The existing `build.sh` already solves this for the Alpine path by
importing Ubuntu 22.04 Xorg/Mesa binaries; reuse the same approach here if you
want glamor.

### Inspecting the overlay offline

```bash
sudo qemu-nbd --connect=/dev/nbd0 out/overlay.qcow2
sudo vgscan   --config 'devices { filter = ["a|/dev/nbd0p4|", "r|.*|"] }'
sudo vgchange -ay ivg --config 'devices { filter = ["a|/dev/nbd0p4|", "r|.*|"] }'
sudo mount -o ro,noload /dev/mapper/ivg-var /mnt/tesla_var   # dirty journal
...
sudo vgchange -an ivg --config 'devices { filter = ["a|/dev/nbd0p4|", "r|.*|"] }'
sudo qemu-nbd --disconnect /dev/nbd0
```

The LVM filter matters: without it the host may pick up the guest VG or vice
versa.

## Known limits

- No TPM, so `vcrypt` LUKS volumes (`id-loadablekey`, OID 2.23.133.10.1.3) can
  never be unlocked; the overlay uses plain ext4 instead.
- `failed to open heci client` / `failed to query soc lock bit` in the log are
  expected — the Intel CSME/HECI devices do not exist in QEMU.
- Display hardware (DS90UB949/948 FPD-Link, NVT51922 bridge, CYTTSP6 touch
  controller) is absent; the touch path still relies on the QEMU tablet plus
  the proxies in `tools/`.
