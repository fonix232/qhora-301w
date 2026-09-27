#!/bin/sh
# Build our U-Boot for the QHora-301W from src/u-boot (tools/prepare-src.sh
# u-boot) in the build container: native on an arm64 host, cross-compiled
# with aarch64-linux-gnu- anywhere else (e.g. x86-64 CI runners).
#
# SOURCE_DATE_EPOCH defaults to the tree's HEAD commit time, so a clean tree
# made by prepare-src.sh gives the same u-boot.bin wherever it is built.
#
# usage: tools/build-uboot.sh [output dir]     (default build/u-boot-301w)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-build/u-boot-301w}
[ -f "$root/src/u-boot/Makefile" ] || { echo "no src/u-boot: run tools/prepare-src.sh u-boot" >&2; exit 1; }
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$root/src/u-boot" log -1 --format=%ct)}
export SOURCE_DATE_EPOCH
mkdir -p "$root/$out"
"$root/tools/build/run.sh" sh -eu -c "
[ \"\$(uname -m)\" = aarch64 ] || export CROSS_COMPILE=aarch64-linux-gnu-
make -C src/u-boot O=/work/$out qnap_301w_defconfig
make -C src/u-boot O=/work/$out -j\"\$(nproc)\"
" </dev/null
ls -l "$root/$out/u-boot.bin"
