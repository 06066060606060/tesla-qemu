# image_path <rootfs> <absolute guest path>
#
# Echo the host path to use when writing <absolute guest path> inside an
# unpacked rootfs, following symlinked directory components as the guest would.
#
# This matters because an absolute symlink inside the unpacked tree points at the
# HOST filesystem: if /usr/lib is a link to /lib, then writing to
# "$R/usr/lib/xorg/Xorg" creates /lib/xorg/Xorg on the build machine and nothing
# in the image, while every command reports success.
image_path() {
    local R="$1"
    local target="$2"
    local cur=""
    local part link

    local IFS=/
    # shellcheck disable=SC2206
    local parts=($target)
    unset IFS

    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        [ "$part" = "." ] && continue
        if [ -L "$R$cur/$part" ]; then
            link="$(readlink "$R$cur/$part")"
            case "$link" in
                /*) cur="$link" ;;
                *)  cur="$cur/$link" ;;
            esac
        else
            cur="$cur/$part"
        fi
    done

    printf '%s%s\n' "$R" "$cur"
}

# image_mkdir <rootfs> <absolute guest path>...
image_mkdir() {
    local R="$1"
    shift
    local d
    for d in "$@"; do
        sudo mkdir -p "$(image_path "$R" "$d")"
    done
}
