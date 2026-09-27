#!/bin/sh
# What .github/workflows/ci.yml runs, in the same order, on any host with
# Docker: the patched trees, U-Boot, the loader FIT and the APPSBL, then
# every offline check. Carries on after a failed check and lists them all at
# the end; exits non-zero if anything failed. Keep it in step with ci.yml.
# tools/build/remote-verify.sh runs it on mimir before anything is pushed.
#
# usage: tools/ci-checks.sh
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
failed=
step() { # name, command...
	name=$1; shift
	echo "=== $name"
	if "$@"; then echo "--- ok: $name"; return 0; fi
	echo "--- FAILED: $name"; failed="$failed
  $name"
	return 1
}

step "upstream sources + patch series" tools/prepare-src.sh --update all || { echo "no sources, stopping" >&2; exit 1; }
SOURCE_DATE_EPOCH=$(git -C src/u-boot log -1 --format=%ct); export SOURCE_DATE_EPOCH
built=0
step "U-Boot" tools/build-uboot.sh && step "loader FIT" tools/mkloader.sh && step "APPSBL" tools/mkappsbl.sh && built=1
if [ $built = 1 ]; then
	step "boot flow (sandbox)" tools/test-bootflow.sh
	step "migration rehearsal" tools/test-migration.sh
fi
step "A/B sysupgrade logic" tools/test-ab-upgrade.sh
step "OpenWrt device trees" tools/check-openwrt-dts.sh
step "NOR partition table (MIBIB)" tools/test-mibib.sh
step "MBN generator against QCA's images" sh -c 'tools/fetch-vendor-mbn.sh && python3 tools/mkmbn.py verify cache/vendor/nbg7815/*.mbn'
step "serial bridge detection (host test)" tools/build/run.sh sh -c \
	'c++ -std=c++17 -O2 -I tools/esp32s3-uart-bridge/src tools/esp32s3-uart-bridge/test/detect_test.cpp -o build/detect_test && build/detect_test'

if [ -n "$failed" ]; then
	echo "FAILED:$failed"
	exit 1
fi
[ $built = 1 ] && (cd build && shasum -a 256 u-boot-301w/u-boot.bin loader/qnap_301w-uboot-loader.itb appsbl/qnap_301w-appsbl.mbn)
echo "all checks passed"
