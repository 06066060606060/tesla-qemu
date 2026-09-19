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

With the stock Tesla kernel (squashfs and virtio are built in):

```bash
./scripts/build-initrd-custom.sh
./scripts/prepare-rootfs.sh firmware/2026.8.3.squashfs
sudo ./scripts/make-overlay.sh
./qemu/start-native.sh
```

With a distribution kernel such as Alpine's `vmlinuz-lts`, squashfs and virtio
are **modules**, so they must be embedded in the initramfs — otherwise
`custom_init` stops on `mount /dev/vda: No such device`:

```bash
MODLOOP=./cache/alpine-iso/boot/modloop-lts ./scripts/build-initrd-custom.sh
KERNEL=./cache/alpine-iso/boot/vmlinuz-lts ./qemu/start-native.sh
```

`MODULES_DIR=/lib/modules/<version>` works too for a modules tree you already
have on disk. The script resolves `squashfs`, virtio, sdhci/mmc, ext4, dm-mod
and the input drivers with their dependencies, copies only those, and generates
an `/init` wrapper that `insmod`s them in order before handing over to
`custom_init`. Override the list with `KMODS="..."`.

## Then what?

Nothing to launch by hand: unlike the Alpine path, `custom_init` execs
`/sbin/init`, so runit brings up `/etc/runit/1` then `runsvdir` and the whole
`/etc/sv/*` tree, QtCar included. Watch it happen in `out/serial.log`, then:

```bash
ssh -p 2222 root@localhost     # NET=user
sv status /etc/sv/*            # what runit actually started
```

If QtCar is not up, the launcher scripts from the Alpine path are still
available inside the image (`/root/start-qtcar.sh`).

### Boot loop

`out/serial.log` shows the real cause:

```
runit/1: REBOOTING - check-lvm-parts: Partition table modification or e2fsck fixes
- runit: warning: child failed: /etc/runit/1
- runit: enter stage: /etc/runit/3
```

This is not a kernel panic: the stock `check-lvm-parts` restarts the machine on
purpose once it has repaired the partition table or a filesystem, expecting the
repair to hold. Under QEMU the same condition returns on the next boot, so the
machine restarts forever.

The `runit/1:` prefix is only the stage-1 log prefix, so the message does not
come from `/etc/runit/1` — `grep REBOOTING` finds nothing there. It is printed
by a helper that stage 1 runs, which then exits non-zero; runit treats a failed
stage-1 child as fatal and enters stage 3 (shutdown).

`prepare-rootfs.sh` therefore searches the whole image for whatever prints
`REBOOTING` and hands it to `scripts/lib/suppress-reboot.py`, which rewrites the
non-zero exit that follows the message, plus any `reboot`, `shutdown -r`,
`/proc/sysrq-trigger` or `reboot_required=1`, into console messages, and appends
`exit 0` so stage 1 reports success. Backups are kept as `<file>.orig`.
The boot then continues and the console says what it wanted to repair.

```bash
./scripts/prepare-rootfs.sh firmware/<version>.squashfs
```

`SUPPRESS_REBOOT=0` keeps the stock behaviour.

The kernel command line used to carry `panic=1`, so any failure rebooted after
one second and the cause scrolled past. `panic=0` and `-no-reboot` are now the
default: the VM stops on the error and QEMU exits, leaving the whole story in
`out/serial.log`. Read the last screen before the stop:

```bash
tail -100 out/serial.log
```

`PANIC=1 ./qemu/start-native.sh` restores the hardware behaviour.

A loop that starts right after the overlay was switched to virtio-blk usually
means the guest now enumerates two virtio disks and `custom_init` mounted the
wrong one. `/dev/vda` is the first `-drive` on the command line, which is the
squashfs; if the order is inverted, the mount of `/mnt` fails and PID 1 exits,
which the kernel treats as a panic. The diagnostics dump lists `/sys/block`, so
the serial log shows which device holds what.

### `check-lvm-parts: e2fsck: Bad magic number in super-block`

The logical volume exists but carries no filesystem the guest can read, so
`check-lvm-parts` reformats it with `mke2fs`. Boot usually continues after
that, but the volume is recreated on every boot if the cause persists.

Check the image from the host:

```bash
sudo ./scripts/verify-overlay.sh out/overlay.qcow2
```

Two causes have been addressed in `make-overlay.sh`:

- Data left in the page cache never reached the qcow2 file, because the VG was
  deactivated without a `sync` or a device flush first. The image looked fine on
  the host and empty to the guest.
- `metadata_csum_seed` and `orphan_file`, enabled by default since e2fsprogs
  1.47, are unknown to the stock `4.14.334-PLK` kernel. They are now disabled
  along with `quota` and `project`. The list is probed at runtime, because an
  older `mkfs.ext4` rejects the whole `-O` set with "Invalid filesystem option
  set" as soon as one name is unknown to it.

Rebuild the overlay: `sudo ./scripts/make-overlay.sh`. The script now verifies
every volume before finishing, so this fails on the host instead of mid-boot.

The overlay is exposed as an SD/eMMC card by default:

```bash
OVERLAY_IF=sd     ./qemu/start-native.sh   # /dev/mmcblk0, like the MCU2 (default)
OVERLAY_IF=virtio ./qemu/start-native.sh   # /dev/vdb, bypasses SD emulation
```

`virtio` is useful to rule out QEMU's SD emulation, but it is not a working
setup: the firmware refers to the device by name, so the boot partition mount
fails with `mount: /mnt/mmcblk0p1: unknown filesystem type` and check-lvm-parts
gives up. Only the LVM volumes are found, because LVM scans every block device.

That `unknown filesystem type 'ext2'` also needs the `ext2` module in the
initrd: `ext4` does not register the `ext2` name unless the kernel was built
with `CONFIG_EXT4_USE_FOR_EXT23`, which the Alpine kernel is not. It is now in
the default `KMODS` list.

### Stuck on `custom_init: waiting for /dev/vda`

The kernel has no virtio-blk driver, so the rootfs disk never shows up. That
happens when the initrd was built without modules while using a modular kernel:

```bash
MODLOOP=./cache/alpine-iso/boot/modloop-lts ./scripts/build-initrd-custom.sh
```

The build now warns explicitly if `squashfs` or `virtio_blk` did not make it
into the image, and `/init` reports every `insmod` failure plus the final list
of loaded modules. After a 30 s timeout `custom_init` dumps `/sys/block`,
`/dev`, `/proc/partitions`, `/proc/modules` and `/proc/filesystems`, then drops
to a busybox rescue shell so the VM can be inspected instead of hanging.

### `eth0: ERROR while getting interface flags: No such device`

The guest has no network interface at all, for one of two reasons.

The kernel has no driver for the emulated NIC. The initrd now ships `e1000`,
`e1000e`, `igb`, `virtio_net` (plus `failover`/`net_failover`), so rebuild it:

```bash
MODLOOP=./cache/alpine-iso/boot/modloop-lts ./scripts/build-initrd-custom.sh
```

Or the interface exists under a predictable name such as `enp0s2` instead of
`eth0`. The kernel command line now sets `net.ifnames=0 biosdevname=0`, and the
`qemu-net` service picks the first non-loopback interface in `/sys/class/net`
rather than assuming `eth0`. If it finds none it says so on the console and
lists the loaded modules.

Check inside the guest with `ls /sys/class/net` and `ip link`.

### SSH does not connect

`prepare-rootfs.sh` installs a `qemu-net` runit service that waits for `eth0`,
assigns `192.168.90.100/24`, generates host keys in `/var/etc/ssh` on first
boot, and runs sshd with `/etc/ssh/sshd_config_qemu`. It also unlocks the root
account (`ROOT_PASSWORD`, default `root`) and installs your public key
(`SSH_PUBKEY`, or the agent keys, or `~/.ssh/*.pub`), because the stock image
has a locked root password and no `authorized_keys` — password and key logins
both fail otherwise, usually with nothing more than a closed connection.

A rootfs built before this service existed has to be repacked:

```bash
./scripts/prepare-rootfs.sh firmware/2026.8.3.squashfs
```

Then check, on the QEMU serial console or in `out/serial.log`:

```bash
ip addr show eth0            # must show 192.168.90.100
sv status /etc/sv/qemu-net   # must be "run"
cat /etc/sv/qemu-net/supervise/stat 2>/dev/null
ps | grep sshd
```

If the service is missing, `prepare-rootfs.sh` found no directory watched by
`runsvdir` and said so; start it by hand with `runsv /etc/sv/qemu-net &`.

If `eth0` does not exist at all, the guest has no driver for the emulated NIC —
see the network device model section above and try `NIC=e1000`.

With `NET=user`, connect through the forwarded port, not the guest address:

```bash
ssh -p 2222 root@localhost
```

Note that with a non-Tesla kernel, the rootfs only carries
`/lib/modules/4.14.334-PLK`, so the `modprobe` calls added to `/etc/runit/1`
fail harmlessly — the drivers already loaded from the initramfs keep working.

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
`INITRD`, `SQUASHFS`, `OVERLAY`, `NET` (`user` or `tap`), `NIC`, `GL`
(`off`/`on`), `KVM`, `QEMU_BIN`.

### Network device model

The real MCU2 has an Intel `igb` NIC and the firmware ships `igb.ko`, so the
launcher prefers `-device igb`. That model only exists in QEMU 8.2 and later —
older builds fail with `'igb' is not a valid device model name`. The script
probes `qemu-system-x86_64 -device help` and falls back to `e1000e`, `e1000`,
then `virtio-net-pci`, printing which one it picked.

With a generic kernel (`vmlinuz-lts`) any model works. With the stock Tesla
kernel, a fallback model needs its driver: `e1000e` and `virtio-net` are *not*
necessarily built in that config, so either upgrade QEMU, or build/copy the
matching module into `/lib/modules/4.14.334-PLK` before repacking the squashfs.
Force a specific model with `NIC=e1000`.

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
