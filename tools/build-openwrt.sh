#!/bin/sh
# Full OpenWrt build of qualcommax/ipq807x with both 301w profiles
# (qnap_301w and qnap_301w-ubootmod) from src/openwrt (tools/prepare-src.sh
# openwrt) and the upstream feeds. The ubootmod variant needs a kernel option
# of its own (CONFIG_UIMAGE_FIT_BLK), so the ImageBuilder can't make it.
#
# Runs directly on a Linux host with OpenWrt's build prerequisites, not in the
# build container: OpenWrt refuses to build as root and needs a case-sensitive
# filesystem, which the macOS bind mount isn't. CI runs it on the runner.
#
# QH_CCACHE_DIR=<dir> keeps ccache there (CI caches it between runs).
# Images and sha256sums end up in src/openwrt/bin/targets/qualcommax/ipq807x/.
#
# usage: tools/build-openwrt.sh [config|download|build|all]   (default: all)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root/src/openwrt" 2>/dev/null || { echo "no src/openwrt: run tools/prepare-src.sh openwrt" >&2; exit 1; }
jobs=$(nproc)

configure() {
	./scripts/feeds update -a
	./scripts/feeds install -a >/dev/null
	cp "$root/tools/openwrt/diffconfig" .config
	[ -n "${QH_CCACHE_DIR:-}" ] && echo "CONFIG_CCACHE_DIR=\"$QH_CCACHE_DIR\"" >> .config
	make defconfig >/dev/null
	# defconfig silently drops symbols it doesn't know (a renamed device)
	grep -v '^#' "$root/tools/openwrt/diffconfig" | while read -r line; do
		grep -qx "$line" .config || { echo "defconfig dropped: $line" >&2; exit 1; }
	done
	./scripts/diffconfig.sh > "$root/build/openwrt-diffconfig"
}

download() {
	make -j"$jobs" download || make -j1 download V=s
}

build() {
	# on failure, rerun serially and verbosely so the log shows the error
	make -j"$jobs" || make -j1 V=s
	ls -l bin/targets/qualcommax/ipq807x/ | grep 301w
}

mkdir -p "$root/build"
case ${1:-all} in
config)   configure ;;
download) configure; download ;;
build)    build ;;
all)      configure; download; build ;;
*)        echo "usage: $0 [config|download|build|all]" >&2; exit 2 ;;
esac
