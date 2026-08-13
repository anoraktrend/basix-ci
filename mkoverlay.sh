#!/bin/sh
# mkoverlay.sh - generate a bpm "overlay" repo shadowing basix-packages
#
# The first repo listed in BPM_REPOS wins template lookup, so an overlay can
# repoint a package's dist_files at a mirror without touching upstream. This
# script creates overlay/<pkg>/template for every package in PATCHES, copying
# the upstream template byte-for-byte except for dist_files= and checksum=,
# which are re-pointed at the mirror and re-hashed (blake3) from the actual
# bytes downloaded. Run after updating basix-packages, or --check to verify
# the committed overlay is still in sync.
#
set -eu

BROOT=${BROOT:-$(dirname "$0")/basix-packages}
ODIR=${ODIR:-$(dirname "$0")/overlay}
TMP=${TMP:-$(mktemp -d)}
export TMP
trap 'rm -rf "$TMP"' EXIT
# absolute, since the bpm patch is applied from inside a subshell that cd's
case $BROOT in /*) ;; *) BROOT=$PWD/$BROOT ;; esac
case $ODIR in /*) ;; *) ODIR=$PWD/$ODIR ;; esac

# pkg => mirror url template. ${version} is substituted; extra bash syntax is
# allowed (binutils tag names use underscores). GitHub codeload serves the
# exact release tag tree; ftpmirror.gnu.org geolocates to a fast nearby host.
#
# bpm is special: it builds from its own upstream tag, but must carry our
# lib/common.sh fix (refetch cached sources that fail checksum) into the
# rootfs, so the overlay splices a do_patch that copies files/lib/common.sh
# over the upstream one.
PATCHES="\
gcc|https://codeload.github.com/gcc-mirror/gcc/tar.gz/refs/tags/releases/gcc-\${version}
binutils|https://codeload.github.com/gnutools/binutils-gdb/tar.gz/refs/tags/binutils-\${version//./_}
gmp|https://ftpmirror.gnu.org/gnu/gmp/gmp-\${version}.tar.xz
mpfr|https://ftpmirror.gnu.org/gnu/mpfr/mpfr-\${version}.tar.xz
libmpc|https://ftpmirror.gnu.org/gnu/mpc/mpc-\${version}.tar.gz
m4|https://ftpmirror.gnu.org/gnu/m4/m4-\${version}.tar.xz
make|https://ftpmirror.gnu.org/gnu/make/make-\${version}.tar.gz
bison|https://ftpmirror.gnu.org/gnu/bison/bison-\${version}.tar.xz
zlib|https://github.com/madler/zlib/releases/download/v\${version}/zlib-\${version}.tar.gz
pigz|https://codeload.github.com/madler/pigz/tar.gz/refs/tags/v\${version}
bpm|https://github.com/kkrruumm/bpm/archive/refs/tags/\${version}.tar.gz"

check_sync() {
    dir=$1
    for line in $PATCHES; do
        pkg=${line%%|*}; [ -n "$pkg" ] || continue
        up=$BROOT/$pkg/template; ov=$dir/$pkg/template
        if [ ! -f "$ov" ]; then
            echo "STALE: $pkg not in overlay"; return 1
        fi
        for field in version revision; do
            u=$(grep -E "^$field=" "$up" | tail -1); o=$(grep -E "^$field=" "$ov" | tail -1)
            if [ "$u" != "$o" ]; then
                echo "STALE: $pkg $field: overlay ($o) != upstream ($u)"
                return 1
            fi
        done
        grep -qE '^checksum=' "$ov" || { echo "STALE: $pkg missing checksum"; return 1; }
        if [ "$pkg" = bpm ]; then
            [ -f "$dir/$pkg/files/common.sh.patch" ] || {
                echo "STALE: bpm missing files/common.sh.patch"; return 1; }
            grep -q '^do_patch()' "$ov" || {
                echo "STALE: bpm missing do_patch"; return 1; }
        fi
        echo "ok: $pkg"
    done
    return 0
}

gen() {
    for line in $PATCHES; do
        pkg=${line%%|*}; url=${line#*|}
        [ -n "$pkg" ] || continue
        up=$BROOT/$pkg/template
        [ -f "$up" ] || { echo "no upstream template for $pkg"; exit 1; }
        version=$(grep -E '^version=' "$up" | tail -1 | cut -d= -f2)
        eval "url_str=\"$url\""
        echo "== $pkg $version: $url_str"
        f=$TMP/$pkg.tarball
        curl -fL --retry 3 --retry-delay 2 -m 900 -o "$f" "$url_str"
        hash=$(b3sum "$f" | cut -d' ' -f1)
        mkdir -p "$ODIR/$pkg"
        awk -v dist="$url_str" -v sum="$hash" '
            /^dist_files=/ { print "dist_files=\"" dist "\""; next }
            /^checksum=/  { print "checksum=\"" sum "\""; next }
            { print }
        ' "$up" > "$ODIR/$pkg/template"
        case $pkg in
            bpm)
                # the patch itself is committed in the overlay as
                # files/common.sh.patch; regenerate the patched file from the
                # upstream tarball already downloaded for checksumming, so
                # nothing depends on a vendored checkout. If the upstream
                # tree drifts so the patch no longer applies, this fails loud.
                mkdir -p "$ODIR/$pkg/files/lib"
                _src=$pkg-$version
                tar -xzf "$f" -C "$TMP" "$_src/lib/common.sh"
                ( cd "$TMP/$_src" && patch -s -p1 \
                    < "$ODIR/$pkg/files/common.sh.patch" )
                cp "$TMP/$_src/lib/common.sh" \
                   "$ODIR/$pkg/files/lib/common.sh"
                cat >> "$ODIR/$pkg/template" <<'EOF'
do_patch() { cp "$FILESDIR/lib/common.sh" lib/common.sh; }
EOF
                ;;
        esac
    done
}

case ${1:-gen} in
    --check) check_sync "$ODIR" ;;
    *) gen ;;
esac