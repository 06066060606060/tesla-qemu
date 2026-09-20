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

    # Mesa DRI drivers and the Xorg modules that go with them.
    if [ -d "$SRCROOT/usr/lib/xorg/modules" ]; then
        sudo mkdir -p "$R/usr/lib/xorg"
        sudo cp -R "$SRCROOT/usr/lib/xorg/modules" "$R/usr/lib/xorg/"
        sudo chmod a+x "$R"/usr/lib/xorg/modules/drivers/*.so 2>/dev/null || true
        echo "  Xorg modules"
    fi
    if [ -d "$SRC/dri" ]; then
        sudo cp -R "$SRC/dri" "$R/usr/lib/"
        sudo chmod a+x "$R"/usr/lib/dri/*.so 2>/dev/null || true
        echo "  DRI drivers ($(ls "$SRC/dri" | wc -l) files)"
    fi

    # Xorg itself: the firmware's server has no modesetting driver for virtio.
    for b in Xorg X; do
        [ -f "$SRCROOT/usr/bin/$b" ] || continue
        sudo install -m 0755 "$SRCROOT/usr/bin/$b" "$R/usr/bin/$b"
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
            sudo cp -L "$SRC/$lib" "$R/usr/lib/$lib"
            copied=$((copied + 1))
        else
            missing=$((missing + 1))
            echo "  missing in the Ubuntu rootfs: $lib" >&2
        fi
    done
    echo "  $copied libraries ($missing missing)"

    if [ -d "$SRCROOT/usr/share/libwacom" ]; then
        sudo mkdir -p "$R/usr/share/libwacom"
        sudo cp -R "$SRCROOT"/usr/share/libwacom/* "$R/usr/share/libwacom/"
    fi

    # glvnd needs to be told which vendor library to load.
    sudo mkdir -p "$R/usr/share/glvnd/egl_vendor.d"
    sudo tee "$R/usr/share/glvnd/egl_vendor.d/50_mesa.json" >/dev/null <<'JSON'
{
    "file_format_version" : "1.0.0",
    "ICD": {
        "library_path": "libEGL_mesa.so.0"
    }
}
JSON
    echo "  glvnd vendor file"
}
