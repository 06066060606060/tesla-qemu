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
#   8. check-lvm-parts: suppress the reboot it triggers after fixing the
#      partition table or running e2fsck, which loops forever under QEMU
#      (SUPPRESS_REBOOT=0 keeps the stock behaviour).
#   7. Add a "qemu-net" runit service that configures eth0 and starts sshd, so
#      the VM is reachable without using the serial console, and unlock the
#      root account.
#
# Environment:
#   SSH_PUBKEY=~/.ssh/id_ed25519.pub  key installed for root (default: the
#                                     agent keys, else any ~/.ssh/*.pub)
#   ROOT_PASSWORD=root                console + SSH password for root
#   GUEST_IP=192.168.90.100           static address for eth0
#   GUEST_SSH_PORT=2022               port for our sshd (22 stays with Tesla's)
#   SKIP_SSH=1                        skip the qemu-net service entirely
#
# Reference: ROOT Tesla OS on QEMU Part 2 - Debugging + fixing
# https://cn0xroot.wordpress.com/2026/09/20/root_tesla_os_on_qemu_part_2_debugging_fixing/
set -euo pipefail

IMG="${1:-}"
OUT="${2:-out/rootfs_edited.squashfs}"
ROOT_DIR="${ROOT_DIR:-out/squashfs-root}"
GUEST_IP="${GUEST_IP:-192.168.90.100}"
# The stock sshd owns port 22 and only accepts certificates signed by Tesla's
# PKI ("REMOTE SSH NOT ALLOWED: customer vehicle"), so ours listens elsewhere.
GUEST_SSH_PORT="${GUEST_SSH_PORT:-2022}"
GUEST_GW="${GUEST_GW:-192.168.90.2}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
SKIP_SSH="${SKIP_SSH:-0}"
SUPPRESS_REBOOT="${SUPPRESS_REBOOT:-1}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# --- 8: boot-loop reboots -----------------------------------------------
# 8. Find whatever prints "REBOOTING" and neutralise the restart. The
#    message is emitted by a helper run from stage 1, not by /etc/runit/1
#    itself, so search the image instead of guessing the path.
if [ "$SUPPRESS_REBOOT" != "0" ]; then
    log "Suppress the boot-loop reboots"
    REBOOT_FILES="$(sudo grep -rIl 'REBOOTING' \
        "$R/etc" "$R/usr/bin" "$R/usr/sbin" "$R/sbin" "$R/usr/share" \
        2>/dev/null || true)"
    # Always include the LVM script and stage 1 themselves.
    for extra in "$LVM_SCRIPT" "$R/etc/runit/1"; do
        [ -f "$extra" ] || continue
        case "$REBOOT_FILES" in
            *"$extra"*) ;;
            *) REBOOT_FILES="$REBOOT_FILES
$extra" ;;
        esac
    done
    if [ -n "$(printf '%s' "$REBOOT_FILES" | tr -d '[:space:]')" ]; then
        printf '%s\n' "$REBOOT_FILES" | while read -r f; do
            [ -n "$f" ] || continue
            sudo cp -n "$f" "$f.orig" 2>/dev/null || true
            echo "  candidate: $(realpath --relative-to="$R" "$f")"
        done
        # shellcheck disable=SC2086
        sudo python3 "$SCRIPT_DIR/lib/suppress-reboot.py" $REBOOT_FILES
    else
        warn "nothing printing REBOOTING found; the boot loop may come from elsewhere"
    fi
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

# --- 7: network + sshd service ------------------------------------------
if [ "$SKIP_SSH" != "1" ]; then
    log "Add qemu-net runit service (eth0 $GUEST_IP + sshd)"

    SSHD_BIN=""
    for cand in /usr/sbin/sshd /usr/bin/sshd /sbin/sshd; do
        if [ -x "$R$cand" ]; then SSHD_BIN="$cand"; break; fi
    done
    [ -n "$SSHD_BIN" ] || warn "no sshd binary in the image; the service will only bring up the network"

    if [ -n "$SSHD_BIN" ]; then
        SSHD_CMD="exec $SSHD_BIN -D -e -f /etc/ssh/sshd_config_qemu"
        # Fail loudly: a silent sshd death reaches the client only as
        # "kex_exchange_identification: Connection reset by peer".
        SSHD_TEST="$SSHD_BIN -t -f /etc/ssh/sshd_config_qemu || echo \"qemu-net: sshd config test FAILED\""
    else
        SSHD_CMD="exec sleep infinity"
        SSHD_TEST=":"
    fi

    sudo mkdir -p "$R/etc/sv/qemu-net"
    sudo tee "$R/etc/sv/qemu-net/run" >/dev/null <<EOF
#!/bin/sh
# Generated by scripts/prepare-rootfs.sh - network + sshd for the QEMU guest.
exec 2>&1
set -x

ip link set lo up

# The NIC appears slightly after runit starts, and depending on the kernel it
# may be eth0 or a predictable name such as enp0s2: take the first interface
# that is not loopback.
IFACE=""
for _i in \$(seq 1 30); do
    for _c in /sys/class/net/*; do
        # An unmatched glob stays literal, so check the entry exists.
        [ -e "\$_c" ] || continue
        _n=\$(basename "\$_c")
        [ "\$_n" = "lo" ] && continue
        IFACE="\$_n"
        break
    done
    [ -n "\$IFACE" ] && break
    sleep 1
done

if [ -z "\$IFACE" ]; then
    echo "qemu-net: no network interface found. The kernel has no driver for"
    echo "qemu-net: the emulated NIC. Interfaces: \$(ls /sys/class/net)"
    echo "qemu-net: loaded modules: \$(cut -d' ' -f1 /proc/modules | tr '\\n' ' ')"
    exec sleep infinity
fi

echo "qemu-net: using interface \$IFACE"
ip addr add $GUEST_IP/24 dev "\$IFACE" 2>/dev/null
ip link set "\$IFACE" up
ip route add default via $GUEST_GW 2>/dev/null

mkdir -p /run/qemu-net/supervise /run/qemu-ssh /run/sshd
chmod 0755 /run/sshd
for _t in rsa ecdsa ed25519; do
    _k=/run/qemu-ssh/ssh_host_\${_t}_key
    [ -f "\$_k" ] || ssh-keygen -q -t "\$_t" -N "" -f "\$_k"
done

$SSHD_TEST

$SSHD_CMD
EOF
    sudo chmod +x "$R/etc/sv/qemu-net/run"

    sudo mkdir -p "$R/etc/ssh"
    sudo tee "$R/etc/ssh/sshd_config_qemu" >/dev/null <<'SSHDCONF'
# Generated by scripts/prepare-rootfs.sh - development VM only.
Port __SSH_PORT__
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
PubkeyAuthentication yes
UsePAM no
UseDNS no
StrictModes no
AuthorizedKeysFile /root/.ssh/authorized_keys
HostKey /run/qemu-ssh/ssh_host_rsa_key
HostKey /run/qemu-ssh/ssh_host_ecdsa_key
HostKey /run/qemu-ssh/ssh_host_ed25519_key
PidFile /run/sshd/sshd.pid
Subsystem sftp internal-sftp
SSHDCONF
    sudo sed -i "s/__SSH_PORT__/$GUEST_SSH_PORT/" "$R/etc/ssh/sshd_config_qemu"

    # Enable the service. A symlink in the service directory is not enough on
    # its own: on this image the directory lives under /var, which is an LVM
    # volume mounted over the squashfs during boot, so the link disappears
    # exactly when it would be needed. Launch it from stage 1 as well, which
    # always runs and is never masked.
    for cand in /etc/service /var/service /etc/runit/runsvdir/current /service; do
        if [ -d "$R$cand" ]; then
            log "  symlink into $cand"
            sudo ln -sfn /etc/sv/qemu-net "$R$cand/qemu-net"
            # runsv needs a writable supervise directory; the rootfs is not.
            sudo ln -sfn /run/qemu-net/supervise "$R/etc/sv/qemu-net/supervise"
        fi
    done

    if [ -f "$R/etc/runit/1" ]; then
        if sudo grep -q 'qemu-net' "$R/etc/runit/1"; then
            log "  already launched from /etc/runit/1"
        else
            log "  launch from /etc/runit/1"
            sudo tee -a "$R/etc/runit/1" >/dev/null <<'RUNIT1'

# qemu: network + sshd. Run the script directly instead of through runsv: the
# rootfs is a read-only squashfs, so runsv cannot create its "supervise"
# directory in /etc/sv/qemu-net. The service directory is also under /var, which
# is mounted over during boot, so a symlink there would vanish.
mkdir -p /run/qemu-net
# Send the output to the serial console when possible, so start-native.sh's
# out/serial.log shows why sshd or the network failed.
if [ -w /dev/ttyS0 ]; then
    qemu_net_out=/dev/ttyS0
else
    qemu_net_out=/run/qemu-net/log
fi
(/etc/sv/qemu-net/run > "$qemu_net_out" 2>&1 &) &
RUNIT1
        fi
    else
        warn "no /etc/runit/1; start the service by hand: runsv /etc/sv/qemu-net &"
    fi

    # sshd refuses to start without its privilege-separation user and directory,
    # and dies before the banner - which the client only sees as a reset
    # connection.
    if [ -n "$SSHD_BIN" ]; then
        if ! sudo grep -q '^sshd:' "$R/etc/passwd" 2>/dev/null; then
            log "  add the sshd privilege-separation user"
            echo 'sshd:x:74:74:sshd:/run/sshd:/sbin/nologin' |
                sudo tee -a "$R/etc/passwd" >/dev/null
            sudo grep -q '^sshd:' "$R/etc/group" 2>/dev/null ||
                echo 'sshd:x:74:' | sudo tee -a "$R/etc/group" >/dev/null
        fi
        sudo mkdir -p "$R/var/empty"
        sudo chmod 0755 "$R/var/empty"
    fi

    # Public key for root.
    PUBKEY_DATA=""
    if [ -n "${SSH_PUBKEY:-}" ] && [ -f "$SSH_PUBKEY" ]; then
        PUBKEY_DATA="$(cat "$SSH_PUBKEY")"
    elif ssh-add -L >/dev/null 2>&1; then
        PUBKEY_DATA="$(ssh-add -L)"
    else
        PUBKEY_DATA="$(cat ~/.ssh/*.pub 2>/dev/null || true)"
    fi

    if [ -n "$PUBKEY_DATA" ]; then
        log "  install authorized_keys for root"
        sudo mkdir -p "$R/root/.ssh"
        printf '%s\n' "$PUBKEY_DATA" | sudo tee "$R/root/.ssh/authorized_keys" >/dev/null
        sudo chmod 700 "$R/root/.ssh"
        sudo chmod 600 "$R/root/.ssh/authorized_keys"
    else
        warn "no SSH public key found (set SSH_PUBKEY=...); password login only"
    fi

    # The stock root account is locked, which blocks console and password logins.
    if command -v openssl >/dev/null && [ -f "$R/etc/shadow" ]; then
        log "  set root password"
        HASH="$(openssl passwd -6 "$ROOT_PASSWORD")"
        sudo cp -n "$R/etc/shadow" "$R/etc/shadow.orig"
        sudo python3 - "$R/etc/shadow" "$HASH" <<'PYSHADOW'
import sys
path, hash_ = sys.argv[1], sys.argv[2]
out = []
for line in open(path).read().splitlines():
    parts = line.split(":")
    if parts and parts[0] == "root":
        parts[1] = hash_
        line = ":".join(parts)
    out.append(line)
open(path, "w").write("\n".join(out) + "\n")
PYSHADOW
    else
        warn "openssl not available; root password unchanged (likely locked)"
    fi
fi

# --- 9: launch helpers in /root ------------------------------------------
# The Alpine path copied these from rootfs/root/ into the guest; the native path
# patches the stock squashfs, so install them here. Most of start.sh is
# unnecessary under runit (network, sshd, virtual filesystems), so only the parts
# QtCar needs when started by hand are kept.
if [ -d "$SCRIPT_DIR/../rootfs/root" ]; then
    log "Install the launch helpers in /root"
    sudo mkdir -p "$R/root"
    for f in "$SCRIPT_DIR/../rootfs/root/"*.sh; do
        [ -f "$f" ] || continue
        sudo install -m 0755 "$f" "$R/root/$(basename "$f")"
        # /root may be a link into /var, or a mount point, in which case the
        # copy above is hidden at runtime. /usr/local/bin always survives.
        sudo mkdir -p "$R/usr/local/bin"
        sudo install -m 0755 "$f" "$R/usr/local/bin/$(basename "$f")"
        echo "  /root/$(basename "$f") and /usr/local/bin/$(basename "$f")"
    done

    # Native-boot variant: runit already handled the boot, so drop the Alpine
    # module loop, the network setup and the sshd launch.
    sudo python3 - "$R/root/start.sh" "$R/root/start-native.sh" <<'PYHELPER'
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

# Sections that only make sense with init=/bin/bash on the Alpine kernel.
drops = [
    (r'# Network\n(?:ip [^\n]*\n)+', ''),
    (r'# With init=/bin/bash[\s\S]*?mount -t devpts[^\n]*\n', ''),
    (r'# Mount modloop[\s\S]*?ln -sf /\.modloop[^\n]*\n', ''),
    (r'(?m)^/usr/sbin/sshd[^\n]*$\n?', ''),
    (r'(?m)^modprobe (?:ehci_pci|ehci_hcd)[^\n]*$\n', ''),
]
for pattern, replacement in drops:
    text = re.sub(pattern, replacement, text)

header = (
    "#!/bin/bash\n"
    "# Generated by scripts/prepare-rootfs.sh from rootfs/root/start.sh.\n"
    "# Native boot: runit already set up the network, the virtual filesystems\n"
    "# and sshd, so only the QtCar/Xorg/input preparation is left. Run it as\n"
    "# root over SSH, then start the UI with /root/start-qtcar.sh.\n"
)
text = re.sub(r'^#!/bin/bash\n', header, text, count=1)
open(dst, 'w').write(text)
print("  /root/start-native.sh (QtCar/Xorg/input only)")
PYHELPER
    sudo chmod 0755 "$R/root/start-native.sh"
    sudo install -m 0755 "$R/root/start-native.sh" "$R/usr/local/bin/start-native.sh"

    # start-qtcar.sh runs the UI as the tesla user from /home/tesla/start.sh,
    # but /home is an LVM volume mounted over the squashfs, so a copy there
    # would be hidden. Install it somewhere the tesla user can always read it,
    # and point the wrapper at that path.
    if [ -f "$SCRIPT_DIR/../rootfs/home/tesla/start.sh" ]; then
        sudo mkdir -p "$R/usr/local/bin"
        sudo install -m 0755 "$SCRIPT_DIR/../rootfs/home/tesla/start.sh" \
            "$R/usr/local/bin/qtcar-user.sh"
        sudo tee "$R/root/start-qtcar.sh" >/dev/null <<'QTCAR'
#!/bin/bash
# Generated by scripts/prepare-rootfs.sh - start the UI as the tesla user.
# The script lives in /usr/local/bin because /home is an LVM volume mounted
# over the squashfs, which would hide a copy placed in /home/tesla.
exec su -s /bin/bash tesla -c "/usr/local/bin/qtcar-user.sh $*"
QTCAR
        sudo chmod 0755 "$R/root/start-qtcar.sh"
        sudo install -m 0755 "$R/root/start-qtcar.sh" "$R/usr/local/bin/start-qtcar.sh"
        echo "  /usr/local/bin/qtcar-user.sh (run by /root/start-qtcar.sh)"
    else
        warn "rootfs/home/tesla/start.sh missing; /root/start-qtcar.sh will not work"
    fi
else
    warn "rootfs/root not found; no launch helper installed"
fi

# --- 10: X11 and graphics assets -----------------------------------------
# The Alpine path (build.sh) installed these into the disk image; the native
# path has to put them in the squashfs. Without the modesetting configuration
# Xorg stops with "no screens found", and without a writable /opt/games/var or
# the DRI path the UI cannot start.
XORG_D="$R/etc/X11/xorg.conf.d"
if [ -d "$SCRIPT_DIR/../rootfs/etc/X11/xorg.conf.d" ]; then
    log "Install the Xorg configuration"
    sudo mkdir -p "$XORG_D"
    # The stock monitor section conflicts with the virtio screen.
    if [ -f "$XORG_D/10-monitor.conf" ]; then
        sudo mv "$XORG_D/10-monitor.conf" "$XORG_D/10-monitor.conf.orig"
        echo "  10-monitor.conf disabled"
    fi
    for f in "$SCRIPT_DIR/../rootfs/etc/X11/xorg.conf.d/"*.conf; do
        [ -f "$f" ] || continue
        sudo install -m 0644 "$f" "$XORG_D/$(basename "$f")"
        echo "  $(basename "$f")"
    done
else
    warn "rootfs/etc/X11 not found: Xorg will likely stop with 'no screens found'"
fi

log "Create the directories the UI writes to"
# The rootfs is read-only at runtime, so anything the UI expects to create must
# exist now, and anything it must write into has to live on a volume or tmpfs.
for d in /opt/games/var/tesla-chromium-webapp-adapter /opt/games/run \
         /usr/lib/x86_64-linux-gnu /usr/local/bin /usr/local/lib; do
    sudo mkdir -p "$R$d"
done
if [ -d "$R/usr/lib/dri" ] && [ ! -e "$R/usr/lib/x86_64-linux-gnu/dri" ]; then
    sudo ln -sfn /usr/lib/dri "$R/usr/lib/x86_64-linux-gnu/dri"
    echo "  /usr/lib/x86_64-linux-gnu/dri -> /usr/lib/dri"
fi

# Binaries built by scripts/build-tools.sh (they need X11 headers, so they are
# built in a container rather than here).
for b in x11-input-proxy touch-proxy; do
    if [ -f "$SCRIPT_DIR/../out/$b" ]; then
        sudo install -m 0755 "$SCRIPT_DIR/../out/$b" "$R/usr/local/bin/$b"
        echo "  /usr/local/bin/$b"
    else
        warn "out/$b missing: run scripts/build-tools.sh (touch input will not work)"
    fi
done
if [ -f "$SCRIPT_DIR/../out/vblank-fix.so" ]; then
    sudo install -m 0755 "$SCRIPT_DIR/../out/vblank-fix.so" "$R/usr/local/lib/vblank-fix.so"
    echo "  /usr/local/lib/vblank-fix.so"
fi

# The tesla user needs a real shell for start-qtcar.sh's su.
if sudo grep -qE '^tesla:.*:/bin/false$' "$R/etc/passwd" 2>/dev/null; then
    log "Give the tesla user a shell"
    sudo sed -i -E 's@^tesla:(.*):/bin/false$@tesla:\1:/bin/bash@' "$R/etc/passwd"
fi

# Alpine kernel modules: the squashfs only ships 4.14.334-PLK, so modprobe in
# the guest fails with "can't change directory to '6.6.14-0-lts'". Copying the
# tree used to build the initrd makes modprobe work inside the guest too.
if [ -n "${MODULES_DIR:-}" ] && [ -d "$MODULES_DIR" ]; then
    KVER_G="$(basename "$MODULES_DIR")"
    log "Install the $KVER_G modules in the guest"
    sudo mkdir -p "$R/lib/modules"
    sudo cp -a "$MODULES_DIR" "$R/lib/modules/$KVER_G"
    sudo depmod -b "$R" "$KVER_G" 2>/dev/null ||
        warn "depmod failed; modprobe may still need explicit paths"
fi

# --- repack --------------------------------------------------------------
log "Repack -> $OUT"
sudo rm -f "$OUT"
sudo mksquashfs "$R" "$OUT" -comp zstd -noappend -no-progress | tail -5
sudo chown "$(id -u):$(id -g)" "$OUT"

log "DONE: $OUT"
log "Next: sudo ./scripts/make-overlay.sh && ./qemu/start-native.sh"
if [ "$SKIP_SSH" != "1" ]; then
    log "SSH once booted: ssh -p 2222 root@localhost   (password: $ROOT_PASSWORD)"
    log "  (guest port $GUEST_SSH_PORT: the stock sshd keeps 22 and rejects non-Tesla keys)"
fi
