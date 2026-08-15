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
# allowed (binutils tag names use underscores). GitHub /archive/ endpoints
# serve the exact release tag tree and keep a .tar.gz basename (bpm decides
# how to extract a dist by its filename); ftpmirror.gnu.org geolocates to a
# fast nearby host.
#
# bpm itself is not overlaid: the rootfs ships the pristine upstream package.
# The CI runs on a patched build of it instead, generated separately with
# --ci-bpm (patches/bpm-common.sh.patch applied on top of the upstream tag).
PATCHES="\
gcc|https://github.com/gcc-mirror/gcc/archive/refs/tags/releases/gcc-\${version}.tar.gz
binutils|https://github.com/gnutools/binutils-gdb/archive/refs/tags/binutils-\${version//./_}.tar.gz
gmp|https://ftpmirror.gnu.org/gnu/gmp/gmp-\${version}.tar.xz
mpfr|https://ftpmirror.gnu.org/gnu/mpfr/mpfr-\${version}.tar.xz
libmpc|https://ftpmirror.gnu.org/gnu/mpc/mpc-\${version}.tar.gz
m4|https://ftpmirror.gnu.org/gnu/m4/m4-\${version}.tar.xz
make|https://ftpmirror.gnu.org/gnu/make/make-\${version}.tar.gz
bison|https://ftpmirror.gnu.org/gnu/bison/bison-\${version}.tar.xz
zlib|https://github.com/madler/zlib/releases/download/v\${version}/zlib-\${version}.tar.gz
pigz|https://github.com/madler/pigz/archive/refs/tags/v\${version}.tar.gz
musl|https://github.com/ifduyue/musl/archive/refs/tags/v\${version}.tar.gz"

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
        if [ -d "$BROOT/$pkg/files" ] && [ ! -d "$dir/$pkg/files" ]; then
            echo "STALE: $pkg missing files/ (FILESDIR would be empty)"
            return 1
        fi
        echo "ok: $pkg"
    done
    [ -f "$(dirname "$0")/patches/bpm-common.sh.patch" ] || {
        echo "STALE: patches/bpm-common.sh.patch missing"; return 1; }
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
        # the overlay shadows the package dir wholesale, so templates whose
        # build needs $FILESDIR get the upstream files/ copied along
        if [ -d "$BROOT/$pkg/files" ]; then
            rm -rf "$ODIR/$pkg/files"
            cp -R "$BROOT/$pkg/files" "$ODIR/$pkg/files"
        fi
    done
}

# --ci-bpm <dir> - materialize a patched bpm tree for the CI to run the build
# with. The rootfs itself keeps the pristine upstream bpm package; only the
# build is driven by this one. The patch (patches/bpm-common.sh.patch, the
# cached-source self-heal) is applied on top of the upstream tag tarball, so
# it fails loud if upstream drifts.
ci_bpm() {
    out=$1
    up=$BROOT/bpm/template
    version=$(grep -E '^version=' "$up" | tail -1 | cut -d= -f2)
    url_str="https://github.com/kkrruumm/bpm/archive/refs/tags/$version.tar.gz"
    echo "== ci-bpm $version: $url_str"
    f=$TMP/bpm.tar.gz
    curl -fL --retry 3 --retry-delay 2 -m 900 -o "$f" "$url_str"
    tar -xzf "$f" -C "$TMP"
    mkdir -p "$out"
    # absolute, the patch redirect must not be re-resolved after the cd
    _patch=$(cd "$(dirname "$0")" && pwd)/patches/bpm-common.sh.patch
    ( cd "$TMP/bpm-$version" && patch -s -p1 < "$_patch" )
    cp -R "$TMP/bpm-$version/." "$out/"
    [ -f "$out/bpm" ] && [ -d "$out/lib/style" ] || {
        echo "ci-bpm tree incomplete in $out"; exit 1; }
}

case ${1:-gen} in
    --check) check_sync "$ODIR" ;;
    --ci-bpm) ci_bpm "${2:?usage: mkoverlay.sh --ci-bpm <dir>}" ;;
    *) gen ;;
esac