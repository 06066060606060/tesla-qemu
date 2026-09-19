# Tesla on QEMU
For sw 2026.8.3 mcu2 model S (portrait screen)


Run Tesla's QtCar infotainment UI from a firmware squashfs image inside QEMU.

Two boot paths are available:

- **Alpine path** (`./build.sh` + `./qemu/start.sh`) — copies the firmware into
  an ext4 disk, boots an Alpine kernel with `init=/bin/bash`, and starts Xorg
  and QtCar manually. Documented below.
- **Native path** (`./scripts/*` + `./qemu/start-native.sh`) — boots the stock
  Tesla kernel with a custom `init` that mounts the edited squashfs read-only
  and hands over to runit, with a writable LVM overlay for `var`/`home`/`log`.
  See [docs/native-boot.md](./docs/native-boot.md).

## Requirements

- Linux with KVM available
- QEMU
- Docker
- `qemu-img`, `mkfs.ext4`, `mkfs.exfat`, `wget`, `ssh-keygen`, `ssh-add`
- A Tesla firmware squashfs image, for example `firmware/2026.2.3.model3.squashfs`

The build script also uses `sudo` to mount disk images and copy files into the generated root filesystem.

## Network Setup

Create the tap interface used by QEMU:

```bash
./create-tap.sh
```

The defaults are:

- Host tap device: `tap0`
- Host IP: `192.168.90.5/24`
- VM IP: `192.168.90.100`

You can override the host-side settings:

```bash
TAP=tap1 HOST_CIDR=192.168.91.5/24 ./create-tap.sh
```

## Build The Disk Image

```bash
./build.sh firmware/2026.8.3.squashfs
```

This creates `out/disk.img`, copies the Tesla root filesystem into it, adds Xorg/Mesa support, installs the input proxy helpers, applies the current QtCar/DRM patches, and caches Alpine boot files under `cache/alpine-iso`.

The QtCar binary patches are firmware-specific. If a checked byte signature does not match, the build stops instead of silently patching an unknown binary.

## Start The VM

```bash
./qemu/start.sh
```

Useful launch overrides:

```bash
RAM=4g SMP=4 RESOLUTION=1920x1200 TAP=tap0 ./qemu/start.sh
```

Supported environment variables:

- `RAM`, default `2g`
- `SMP`, default `2`
- `DISK_IMG`, default `./out/disk.img`
- `KERNEL`, default `./cache/alpine-iso/boot/vmlinuz-lts`
- `INITRD`, default `./cache/alpine-iso/boot/initramfs-lts`
- `TAP`, default `tap0`
- `RESOLUTION`, default `1920x1200`
- `DISPLAY_BACKEND`, default `gtk,gl=on`

## Start Services In The VM

The VM boots with `init=/bin/bash`. From the QEMU serial console, start networking, device setup, Xorg, the input proxy, and sshd:

```bash
/root/start.sh
```

From another terminal, connect over SSH:

```bash
ssh root@192.168.90.100
```

Then start QtCar as the `tesla` user:

```bash
/root/start-qtcar.sh
```

If everything works, the QtCar UI should appear:

![QtCar UI](./docs/qtcar.jpg)

## Native Boot (stock kernel, runit, squashfs read-only)

If you already have a firmware squashfs, this path needs no 6 GB disk copy:

```bash
./scripts/build-initrd-custom.sh                        # initrd + custom_init
./scripts/prepare-rootfs.sh firmware/2026.8.3.squashfs  # patch + repack rootfs
sudo ./scripts/make-overlay.sh                          # writable LVM overlay
./qemu/start-native.sh
```

It bypasses dm-verity and the dm-linear rootfs assembly, and applies the
fixes needed for the full service tree to come up in a VM: no more `wipefs -a`
reformatting the LVM volumes on every boot, no ext4 quota features on a kernel
without `CONFIG_QUOTA`, a 60 s RCU stall timeout, stock evdev input
autodetection in Xorg, and AppArmor access to the second DRM node.

With a distribution kernel (Alpine's `vmlinuz-lts`), squashfs and virtio are
modules, so they have to be embedded in the initramfs:

```bash
MODLOOP=./cache/alpine-iso/boot/modloop-lts ./scripts/build-initrd-custom.sh
KERNEL=./cache/alpine-iso/boot/vmlinuz-lts ./qemu/start-native.sh
```

Unlike the Alpine path, nothing has to be started by hand afterwards: runit
boots the service tree, QtCar included.

Helper scripts:

- `scripts/extract_iasImage.py` — pull the bzImage out of `bank_a.iasImage`
- `scripts/verify-overlay.sh`, `scripts/fix-lvm-quota.sh` — offline `e2fsck` + quota cleanup of an overlay

Full rationale, log excerpts and limitations: [docs/native-boot.md](./docs/native-boot.md).

## Notes

- Touch input is handled through `x11-input-proxy`, which maps the QEMU USB tablet into X11 clicks and a uinput multitouch device exposed as `/dev/input/touch`.
- QtCar is still missing many surrounding Tesla services, so car graphics, maps, emergency-call UI, and other service-backed features may be absent or incomplete.
- The current image setup uses permissive device permissions inside the VM for convenience. Treat the VM image as a local development artifact.
- Guest 3D acceleration (virgl) is unreliable; the native path defaults to
  `virtio-vga` 2D scanout, with `GL=on` available to retry.

## References

- [ROOT Tesla OS on QEMU Part 2 – Debugging + fixing](https://cn0xroot.wordpress.com/2026/09/20/root_tesla_os_on_qemu_part_2_debugging_fixing/) — the debugging notes the native-boot path is based on.
