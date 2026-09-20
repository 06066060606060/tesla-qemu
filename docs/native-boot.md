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

### `libEGL warning: egl: failed to create dri2 screen`

The firmware's Mesa only knows the Intel GPU of a real car, so on the virtio GPU
EGL never initialises and QtCar dies without a GL context:

```
libEGL warning: egl: failed to create dri2 screen
QEgl::display(): Cannot initialize EGL display: "Not initialized (0x3001)"
QEglContext::chooseConfig(): Could not find a suitable EGL configuration
```

`build.sh` solved this for the Alpine image by copying Ubuntu's Mesa, DRI
drivers and Xorg into it. The native path needs the same import, in two steps:

```bash
./scripts/import-x11.sh                 # exports cache/ubuntu-xorg-rootfs
./scripts/prepare-rootfs.sh firmware/<version>.squashfs
```

`import-x11.sh` needs Docker or Podman (`RUNTIME=podman`) and runs only once;
`FORCE=1` re-exports. `prepare-rootfs.sh` then installs the DRI drivers, the
Xorg modules and server, the Mesa/GL/GBM/DRM libraries with their full
dependency tree, the libinput drivers and the glvnd vendor file. Set
`X11_ROOTFS` to use an export from elsewhere.

`/usr/bin/Xorg` on Ubuntu is a wrapper script that execs `/usr/lib/xorg/Xorg`,
so the whole `/usr/lib/xorg` tree is copied, not just `modules/`. Without the
real binary the guest only says:

```
/usr/bin/Xorg: exec: line 10: /usr/lib/xorg/Xorg: not found
```

followed by `Can't open display :0` everywhere and a segfault in QtCar. The
install checks the wrapper's target and warns when it is missing.

The whole dependency tree is copied on purpose: glamor `dlopen`s `libgbm.so.1`,
and if a single transitive dependency is missing the call fails silently and
acceleration disappears without a message.

Two binary patches are applied at the same time, as `build.sh` did:

- `libdrm.so.2`: the virtio GPU has no `DRM_IOCTL_WAIT_VBLANK`, and QtCar waits
  for a vblank before presenting a frame, so the screen stays black.
  `drmWaitVBlank` is made to return 0.
- `libQtCarUIFramework.so`: the touch driver is loaded and the display reported
  as on and powered.

Their offsets belong to one specific firmware build, so each patch checks the
bytes it expects and prints a warning instead of failing when they differ. On a
version other than the one they were derived from, expect
`unexpected bytes at 0x...: skipped` and no touch input.

### Graphics: "no screens found", segfault in QtCar

The old Alpine path installed a set of guest-side files that the native path
also needs. `prepare-rootfs.sh` now does it, but the helper binaries have to be
built first, in a container, because they need X11 headers:

```bash
./scripts/build-tools.sh                 # out/x11-input-proxy, touch-proxy, vblank-fix.so
./scripts/prepare-rootfs.sh firmware/<version>.squashfs
```

What gets installed and why:

| Item | Symptom when missing |
| --- | --- |
| `10-modesetting.conf`, `20-input.conf` | `(EE) no screens found`, no input devices |
| `10-monitor.conf` disabled | the stock monitor section fights the virtio screen |
| `/usr/local/bin/x11-input-proxy` | `No such file or directory`, `/dev/input/touch` never appears |
| `/opt/games/var/tesla-chromium-webapp-adapter` | `mkdir: Read-only file system` |
| `/usr/lib/x86_64-linux-gnu/dri` | Mesa cannot find `virtio_gpu_dri` |
| `tesla` user shell | `su` fails in `start-qtcar.sh` |
| `/home/tesla` created at runtime | `Unable to create folder /home/tesla/.Tesla`, then a segfault |

`NATIVE=1 ./scripts/build-tools.sh` builds without a container, but the result is
linked against the host's libc, which may not match the guest.

`runsv ... fatal: unable to lock supervise/lock` for the stock services is
expected: their `supervise` directories are on the read-only squashfs. It does
not prevent QtCar from starting, it only means `sv` cannot talk to them.

`modprobe: can't change directory to '6.6.14-0-lts'` means the guest has no
module tree for the Alpine kernel — the squashfs only ships `4.14.334-PLK`. Pass
the same `MODULES_DIR` used for the initrd to `prepare-rootfs.sh` and it copies
the tree into the image:

```bash
MODULES_DIR=cache/modloop/modules/6.6.14-0-lts \
    ./scripts/prepare-rootfs.sh firmware/<version>.squashfs
```

The modules the UI needs (`virtio_gpu`, `evdev`, `uinput`, `usbhid`) are already
loaded by the initrd, so this is only for convenience.

### `Unable to create folder /home/tesla/.Tesla`, then a segfault

QtCar keeps its settings, cache and database under `/home/tesla/.Tesla`, and dies
without them. `/home` is an LVM volume: empty on a fresh overlay, and still the
read-only squashfs whenever the volume is not mounted. `start-native.sh` now
creates the directory, falls back to a tmpfs when `/home` is not writable, and
gives it to the `tesla` user:

```
storage: /home is not writable, mounting a tmpfs on /home/tesla
storage: /home/tesla ready
```

A tmpfs means the UI starts from scratch on every boot. To keep its state, make
sure the `home` volume is mounted (`mount | grep /home`, `lvs ivg`).

### `Server is already active for display 0`

A leftover Xorg from an earlier attempt. `start-native.sh` reuses the running
server instead of failing; to force a clean start, kill it and remove the lock:

```bash
pkill Xorg; rm -f /tmp/.X0-lock
```

### Launch helpers

`rootfs/root/start.sh` and `start-qtcar.sh` belong to the Alpine path, which
copies them into the guest. The native path patches the stock squashfs instead,
so `prepare-rootfs.sh` installs them under `/root`, plus a generated
`/root/start-native.sh`: the same script with the parts runit already handles
removed — network, virtual filesystems, the Alpine modloop mount and the sshd
launch.

`start-qtcar.sh` runs the UI as the `tesla` user from `rootfs/home/tesla/start.sh`.
That copy cannot go to `/home/tesla`, since `/home` is an LVM volume mounted over
the squashfs, so it is installed as `/usr/local/bin/qtcar-user.sh` and the
wrapper in `/root` points there.

Everything is installed twice, in `/root` and in `/usr/local/bin`: on some
builds `/root` is a link into `/var` or a mount point, so the copy there is
hidden at runtime. If `/root` looks empty, use `/usr/local/bin`.

Over SSH, as root:

```bash
/root/start-native.sh      # input devices, Xorg, 1200x1920, touch proxy
/root/start-qtcar.sh       # the UI, as the tesla user
```

To start the UI entirely by hand, without the helpers:

```bash
export DISPLAY=:0
export LD_LIBRARY_PATH=/usr/tesla/UI/lib:/lib
export MESA_LOADER_DRIVER_OVERRIDE=virtio_gpu_dri
export EGL_PLATFORM=x11
export LIBGL_DRIVERS_PATH=/usr/lib/dri
cd /usr/tesla/UI/bin
./QtCar --touch evdev:/dev/input/touch
```

Run it as `tesla` (`su -s /bin/bash tesla`) unless you are debugging: QtCar
expects that user to own `/opt/games/run/*`. Xorg must already be running, so
run the input/Xorg preparation first.

Note that `/root` is on the read-only squashfs, so anything these scripts try to
rewrite in place fails harmlessly — the Xorg input configuration in particular is
already patched by `prepare-rootfs.sh`, so the `sed -i` inside `start.sh` has
nothing left to do.

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
`/proc/sysrq-trigger` or `reboot_required=1`, into console messages. Backups are
kept as `<file>.orig`.

Only the exit following the message is touched. An earlier version appended a
blanket `exit 0`, which broke the boot in a much more confusing way: these
helpers are sourced by `/etc/runit/1`, so the added exit ended stage 1
immediately. The symptom was `enter stage: /etc/runit/1` followed straight away
by `leave stage: /etc/runit/1` with no output in between, and stage 2 starting
with no service ever configured.
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

### check-lvm-parts fights the pre-created volumes

With the reboot suppressed, the console finally shows what it wants:

```
LVM PV requires shrinking
WARNING: /dev/mmcblk0p4: Pretending size is 12312576 not 16508895 sectors.
/dev/mmcblk0p4: cannot resize to 1502 extents as 1839 are allocated.
Volume group "ivg" has insufficient free space (175 extents): 2048 required.
Failed to find logical volume "ivg/gamesvar"
gaming Logical Volume mismatch; updating Volume Group as needed
no pre-existing scheme found, creating from scratch
```

The firmware owns its volume scheme. It shrinks the PV to a fixed size, uses its
own names (`gamesvar`, not the `gamesusr` guessed here) and creates whatever is
missing — but it cannot shrink a PV whose extents are already allocated, so
pre-created volumes block it.

`make-overlay.sh` therefore ships an **empty** VG, and sizes p4 to the
12312576 sectors the firmware resizes to, which avoids the failing `pvresize`:

```bash
sudo ./scripts/make-overlay.sh            # empty VG (default)
CREATE_LVS=1 sudo ./scripts/make-overlay.sh   # old behaviour
P4_SECTORS=0 sudo ./scripts/make-overlay.sh   # p4 spans the rest of the disk
```

The first boot after this is slow: the guest creates and formats every volume
itself.

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

`prepare-rootfs.sh` installs a `qemu-net` runit service that waits for the
interface, assigns `192.168.90.100/24`, generates host keys in `/run/qemu-ssh`
on first boot, and runs sshd with `/etc/ssh/sshd_config_qemu`. It also unlocks the root
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

The stock sshd owns port 22 and only accepts certificates signed by Tesla's PKI:

```
# REMOTE SSH NOT ALLOWED: customer vehicle
root@localhost: Permission denied (publickey).
```

Seeing that banner means you reached the firmware's sshd, not ours. Ours now
listens on `2022` inside the guest (`GUEST_SSH_PORT`), and the forwards are:

```bash
ssh -p 2222 root@localhost   # our sshd, password or your key
ssh -p 2223 root@localhost   # the stock sshd, Tesla certificates only
```

A reset on port 2222 while port 2223 still shows the Tesla banner means our
service never came up. Three reasons were found and fixed:

- The service directory is under `/var`, an LVM volume mounted over the squashfs
  during boot, so a symlink placed there vanishes at the worst moment. The
  service is now launched from `/etc/runit/1`, which always runs.
- `runsv` needs to create a `supervise` directory inside `/etc/sv/qemu-net`, and
  the rootfs is a read-only squashfs. Stage 1 runs the script directly, and the
  `supervise` path is a symlink into `/run` for `runsvdir` setups.
- `sshd` exits before printing its banner when its privilege-separation user or
  `/var/empty` is missing, which the client sees only as a reset. Both are now
  created.

Its output goes to `/dev/ttyS0`, so `out/serial.log` contains the `qemu-net:`
lines, or `/run/qemu-net/log` inside the guest as a fallback.

`kex_exchange_identification: Connection reset by peer` means sshd accepted the
connection then died. The usual cause was host keys written under `/var`, which
lives on LVM and is not mounted when the service starts — they now go to
`/run/qemu-ssh` on tmpfs. The service also runs `sshd -t` first, so a bad
configuration is reported on the console instead of silently resetting clients.

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
