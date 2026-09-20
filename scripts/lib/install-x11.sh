# Install Ubuntu's Mesa/Xorg stack into an unpacked rootfs.
#
# Sourced by prepare-rootfs.sh. Expects:
#   $1  the unpacked rootfs directory
#   $2  the exported Ubuntu rootfs (see scripts/import-x11.sh)
#
# This mirrors what build.sh did for the Alpine disk image. The firmware's own
# Mesa has no virtio_gpu driver, so without this EGL fails with
# "failed to create dri2 screen" and QtCar never gets a GL context.

install_x11_stack() {
    local R="$1"
    local SRCROOT="$2"
    local SRC="$SRCROOT/usr/lib/x86_64-linux-gnu"

    # shellcheck source=image-path.sh
    . "$(dirname "${BASH_SOURCE[0]}")/image-path.sh"

    # Resolve the destinations through the image's own symlinks. Writing to
    # "$R/usr/lib/..." when /usr/lib is an absolute symlink would silently land
    # on the build machine instead of in the image.
    local LIBD BIND XORGD SHAD
    LIBD="$(image_path "$R" /usr/lib)"
    BIND="$(image_path "$R" /usr/bin)"
    XORGD="$(image_path "$R" /usr/lib/xorg)"
    SHAD="$(image_path "$R" /usr/share)"
    echo "  destination for /usr/lib: ${LIBD#"$R"}"

    # The whole /usr/lib/xorg tree, not just modules/: on Ubuntu /usr/bin/Xorg is
    # a wrapper script that execs /usr/lib/xorg/Xorg, and without the real binary
    # it fails with "exec: /usr/lib/xorg/Xorg: not found".
    if [ -d "$SRCROOT/usr/lib/xorg" ]; then
        sudo mkdir -p "$XORGD"
        sudo cp -R "$SRCROOT/usr/lib/xorg/." "$XORGD/"
        sudo chmod a+x "$XORGD"/modules/drivers/*.so 2>/dev/null || true
        if [ -f "$XORGD/Xorg" ]; then
            sudo chmod 0755 "$XORGD/Xorg"
            echo "  Xorg server and modules"
        else
            echo "  Xorg modules (no /usr/lib/xorg/Xorg in the export)"
        fi
    fi
    if [ -d "$SRC/dri" ]; then
        sudo cp -R "$SRC/dri" "$LIBD/"
        sudo chmod a+x "$LIBD"/dri/*.so 2>/dev/null || true
        echo "  DRI drivers ($(ls "$SRC/dri" | wc -l) files)"
    fi

    # Xorg itself: the firmware's server has no modesetting driver for virtio.
    for b in Xorg X; do
        [ -f "$SRCROOT/usr/bin/$b" ] || continue
        sudo install -m 0755 "$SRCROOT/usr/bin/$b" "$BIND/$b"
        echo "  /usr/bin/$b"
    done

    # Mesa, GL, GBM, DRM and their transitive dependencies. Glamor dlopens
    # libgbm.so.1: if any dependency is missing the dlopen fails silently and
    # acceleration disappears without a word, so the whole tree is copied.
    local libs=(
        libLLVM-15.so.1 libglapi.so.0 libvirglrenderer.so.1
        libEGL.so.1 libEGL_mesa.so.0 libGLdispatch.so.0 libGLESv2.so.2
        libGL.so.1 libGLX.so.0 libGLX_mesa.so.0 libepoxy.so.0
        libgbm.so.1 libdrm.so.2 libdrm_radeon.so.1 libdrm_amdgpu.so.1
        libdrm_nouveau.so.2
        libexpat.so.1 libffi.so.8 libwayland-server.so.0 libwayland-client.so.0
        libudev.so.1 libsystemd.so.0 libpciaccess.so.0 libpixman-1.so.0
        libxcvt.so.0 libXfont2.so.2 libxshmfence.so.1 libdbus-1.so.3
        libgcrypt.so.20
        libelf.so.1 libzstd.so.1 libsensors.so.5 libedit.so.2 libtinfo.so.6
        libbsd.so.0 libmd.so.0 libaudit.so.1 libunwind.so.8 libselinux.so.1
        liblzma.so.5
        # Xorg's input drivers.
        libinput.so.10 libevdev.so.2 libmtdev.so.1 libwacom.so.9
    )
    local missing=0 copied=0
    for lib in "${libs[@]}"; do
        if [ -f "$SRC/$lib" ]; then
            # -L resolves the symlink so a real file lands in the image.
            sudo cp -L "$SRC/$lib" "$LIBD/$lib"
            copied=$((copied + 1))
        else
            missing=$((missing + 1))
            echo "  missing in the Ubuntu rootfs: $lib" >&2
        fi
    done
    echo "  $copied libraries ($missing missing)"

    if [ -d "$SRCROOT/usr/share/libwacom" ]; then
        sudo mkdir -p "$SHAD/libwacom"
        sudo cp -R "$SRCROOT"/usr/share/libwacom/* "$SHAD/libwacom/"
    fi

    # glvnd needs to be told which vendor library to load.
    sudo mkdir -p "$SHAD/glvnd/egl_vendor.d"
    sudo tee "$SHAD/glvnd/egl_vendor.d/50_mesa.json" >/dev/null <<'JSON'
{
    "file_format_version" : "1.0.0",
    "ICD": {
        "library_path": "libEGL_mesa.so.0"
    }
}
JSON
    echo "  glvnd vendor file"

    # /usr/bin/Xorg on Ubuntu is a wrapper: check the target it execs exists,
    # otherwise the guest only says "exec: /usr/lib/xorg/Xorg: not found".
    if [ -f "$BIND/Xorg" ] && head -c 2 "$BIND/Xorg" | grep -q '#!'; then
        local target
        target="$(sudo grep -oE '/usr/lib/xorg/Xorg[^ ]*' "$BIND/Xorg" | head -1)"
        if [ -n "$target" ] && [ ! -f "$(image_path "$R" "$target")" ]; then
            echo "  warning: /usr/bin/Xorg execs $target, which is missing" >&2
        fi
    fi
}
