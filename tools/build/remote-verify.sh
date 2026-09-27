#!/bin/sh
# Verify the working tree on mimir before anything is pushed: send the
# tracked files (uncommitted edits included) to a directory there and run
# tools/ci-checks.sh on that host, in containers capped like the OpenWrt
# builder. With --openwrt, also the full OpenWrt build
# (tools/build/remote-openwrt.sh); do that whenever patches/openwrt/ or the
# OpenWrt build tooling changed. src/ and cache/ stay between runs; build/
# starts empty each time, like CI. GitHub then only runs ci.yml on main and
# pull requests, and the OpenWrt build for tagged releases.
#
# usage: tools/build/remote-verify.sh [--openwrt]
#   QH_REMOTE_SSH=mimir                        ssh host
#   QH_REMOTE_DIR=/mnt/data/repos/qhora-301w   directory there (on the ZFS
#                                              pool: mimir's / lives in RAM)
#   QH_REMOTE_RUN_OPTS                         limits for the check containers
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
host=${QH_REMOTE_SSH:-mimir}
dir=${QH_REMOTE_DIR:-/mnt/data/repos/qhora-301w}
limits=${QH_REMOTE_RUN_OPTS:---cpus 12 --cpu-shares 256 --memory 8g}
openwrt=0
case ${1:-} in --openwrt) openwrt=1 ;; "") ;; *) echo "usage: $0 [--openwrt]" >&2; exit 2 ;; esac

# one heavy job at a time: the OpenWrt builder's 10 GiB cap plus these would
# not leave mimir enough memory for its services
if [ -n "$(ssh "$host" "docker ps -q -f name=^qhora-owrt-build\$")" ]; then
	echo "an OpenWrt build is running on $host; wait for it (tools/build/remote-openwrt.sh logs) and retry" >&2
	exit 1
fi
what=$(git -C "$root" describe --always --dirty)
snap=$(git -C "$root" stash create)
# replace everything but the persistent src/ and cache/ with this tree
git -C "$root" archive --format=tar "${snap:-HEAD}" |
	ssh "$host" "set -eu; mkdir -p '$dir'; cd '$dir'
		find . -mindepth 1 -maxdepth 1 ! -name src ! -name cache -exec rm -rf {} +
		tar xf -"
echo "verifying $what on $host:$dir"
ssh "$host" "cd '$dir' && QH_RUN_OPTS='$limits' QH_VOLUME=qhora-scratch-verify tools/ci-checks.sh"
[ $openwrt = 0 ] || "$root/tools/build/remote-openwrt.sh" build
echo "verified $what on $host"
