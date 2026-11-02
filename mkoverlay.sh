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
# Upstream may use a flat layout (pkg/template) or a ports layout
# (category/pkg/template), so package dirs are found the same way bpm finds
# them. The overlay itself stays flat: bpm checks flat paths first, so a flat
# overlay still shadows the upstream package.
#
set -eu

BROOT=${BROOT:-$(dirname "$0")/basix-packages}
ODIR=${ODIR:-$(dirname "$0")/overlay}
TMP=${TMP:-$(mktemp -d)}
export TMP
trap 'rm -rf "$TMP"' EXIT
# absolute, so the paths keep working regardless of where the script is run
# from
case $BROOT in /*) ;; *) BROOT=$PWD/$BROOT ;; esac
case $ODIR in /*) ;; *) ODIR=$PWD/$ODIR ;; esac

# pkg => mirror url template. ${version} is substituted; extra bash syntax is
# allowed (binutils tag names use underscores). GitHub /archive/ endpoints
# serve the exact release tag tree and keep a .tar.gz basename (bpm decides
# how to extract a dist by its filename); ftpmirror.gnu.org geolocates to a
# fast nearby host.
#
# bpm itself is not overlaid: the rootfs ships the pristine upstream package.
# The CI runs the current upstream bpm instead, materialized separately with
# --ci-bpm (the previous rootfs may ship an older bpm that does not know about
# the ports layout).
PATCHES="\
gcc|https://mirrors.kernel.org/gnu/gcc/gcc-\${version}/gcc-\${version}.tar.xz
binutils|https://mirrors.kernel.org/gnu/binutils/binutils-\${version}.tar.xz
gmp|https://mirrors.kernel.org/gnu/gmp/gmp-\${version}.tar.xz
mpfr|https://mirrors.kernel.org/gnu/mpfr/mpfr-\${version}.tar.xz
libmpc|https://mirrors.kernel.org/gnu/mpc/mpc-\${version}.tar.gz
m4|https://mirrors.kernel.org/gnu/m4/m4-\${version}.tar.xz
make|https://mirrors.kernel.org/gnu/make/make-\${version}.tar.gz
bison|https://mirrors.kernel.org/gnu/bison/bison-\${version}.tar.xz
zlib|https://zlib.net/zlib-\${version}.tar.gz
pigz|https://zlib.net/pigz/pigz-\${version}.tar.gz
musl|https://git.musl-libc.org/cgit/musl/snapshot/musl-\${version}.tar.gz"

# print the directory holding <pkg> in repo <root>, matching bpm's lookup
# order: flat (repo/pkg) or ports layout up to two levels deep
# (repo/category/pkg), shallowest wins
pkg_find() {
    for _d in "$1/$2" "$1"/*/"$2" "$1"/*/*/"$2"; do
        [ -f "$_d/template" ] && { printf '%s\n' "$_d"; return 0; }
    done
    return 1
}

check_sync() {
    dir=$1
    for line in $PATCHES; do
        pkg=${line%%|*}; [ -n "$pkg" ] || continue
        if ! upd=$(pkg_find "$BROOT" "$pkg"); then
            echo "STALE: $pkg not in upstream repository"; return 1
        fi
        up=$upd/template; ov=$dir/$pkg/template
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
        # everything except the mirror-specific fields must match upstream, so
        # flag/dependency/function changes are picked up even without a bump
        _u=$(awk '/^dist_files=/ {next} /^checksum=/ {next} {print}' "$up")
        _o=$(awk '/^dist_files=/ {next} /^checksum=/ {next} {print}' "$ov")
        if [ "$_u" != "$_o" ]; then
            echo "STALE: $pkg template differs from upstream"
            return 1
        fi
        grep -qE '^checksum=' "$ov" || { echo "STALE: $pkg missing checksum"; return 1; }
        _df=$(grep -E '^dist_files=' "$ov" | tail -1 | sed 's/^dist_files="//;s/"$//')
        case $_df in
            *.tar.gz|*.tar.xz|*.tar.bz2|*.tgz|*.txz|*.zip|git+*) ;;
            *)
                echo "STALE: $pkg dist_files has no archive extension (bpm would cp it raw): $_df"
                return 1 ;;
        esac
        for sub in files patches; do
            if [ -d "$upd/$sub" ] && [ ! -d "$dir/$pkg/$sub" ]; then
                echo "STALE: $pkg missing $sub/ (the overlay shadows it)"
                return 1
            fi
            if [ ! -d "$upd/$sub" ] && [ -d "$dir/$pkg/$sub" ]; then
                echo "STALE: $pkg has stale $sub/ not in upstream"
                return 1
            fi
        done
        echo "ok: $pkg"
    done
    return 0
}

gen() {
    for line in $PATCHES; do
        pkg=${line%%|*}; url=${line#*|}
        [ -n "$pkg" ] || continue
        upd=$(pkg_find "$BROOT" "$pkg") ||
            { echo "no upstream package for $pkg"; exit 1; }
        up=$upd/template
        version=$(grep -E '^version=' "$up" | tail -1 | cut -d= -f2)
        eval "url_str=\"$url\""
        echo "== $pkg $version: $url_str"
        f=$TMP/$pkg.tarball
        curl -fL --retry 4 --retry-delay 10 -m 900 -o "$f" "$url_str"
        hash=$(b3sum "$f" | cut -d' ' -f1)
        mkdir -p "$ODIR/$pkg"
        awk -v dist="$url_str" -v sum="$hash" '
            /^dist_files=/ { print "dist_files=\"" dist "\""; next }
            /^checksum=/  { print "checksum=\"" sum "\""; next }
            { print }
        ' "$up" > "$ODIR/$pkg/template"
        # the overlay shadows the package dir wholesale, so templates whose
        # build needs $FILESDIR or $PATCHESDIR get those copied along
        for sub in files patches; do
            if [ -d "$upd/$sub" ]; then
                rm -rf "$ODIR/$pkg/$sub"
                cp -R "$upd/$sub" "$ODIR/$pkg/$sub"
            else
                rm -rf "$ODIR/$pkg/$sub"
            fi
        done
    done
}

# --ci-bpm <dir> - materialize the upstream bpm tree for the CI to run the
# build with. The rootfs itself keeps the pristine upstream bpm package; only
# the build is driven by this one, because the rootfs we start from ships an
# older bpm that does not understand the current repository layout.
ci_bpm() {
    out=$1
    upd=$(pkg_find "$BROOT" bpm) || { echo "no upstream package for bpm"; exit 1; }
    up=$upd/template
    version=$(grep -E '^version=' "$up" | tail -1 | cut -d= -f2)
    url_str="https://github.com/kkrruumm/bpm/archive/refs/tags/$version.tar.gz"
    echo "== ci-bpm $version: $url_str"
    f=$TMP/bpm.tar.gz
    curl -fL --retry 4 --retry-delay 10 -m 900 -o "$f" "$url_str"
    tar -xzf "$f" -C "$TMP"
    mkdir -p "$out"
    cp -R "$TMP/bpm-$version/." "$out/"
    [ -f "$out/bpm" ] && [ -d "$out/lib/style" ] || {
        echo "ci-bpm tree incomplete in $out"; exit 1; }
}

case ${1:-gen} in
    --check) check_sync "$ODIR" ;;
    --ci-bpm) ci_bpm "${2:?usage: mkoverlay.sh --ci-bpm <dir>}" ;;
    *) gen ;;
esac

