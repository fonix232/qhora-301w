#!/bin/sh
# Recreate the patched upstream trees in src/ from their base commit and our
# patch series (both trees are gitignored, only the series is versioned):
#   src/u-boot   https://github.com/u-boot/u-boot  at patches/u-boot/BASE  + patches/u-boot/*.patch
#   src/openwrt  https://github.com/openwrt/openwrt at patches/openwrt/BASE + patches/openwrt/*.patch
#
# Idempotent: a tree that already is exactly BASE + the series is left alone.
# A tree with other commits, a different series or uncommitted changes is
# refused and never modified (it may hold work that isn't exported yet).
#
# The patches are applied with a fixed committer and the author date as the
# commit date, and every file gets the mtime of the resulting HEAD, so the
# same series always gives the same commit IDs (U-Boot's version string) and
# a cached OpenWrt toolchain from an earlier build of it stays valid.
#
# usage: tools/prepare-src.sh [u-boot|openwrt|all]    (default: all)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)

die() { echo "prepare-src: $*" >&2; exit 1; }

# the patch-ids of a series, in order (independent of commit IDs and line offsets)
series_ids() { for p in "$1"/*.patch; do git patch-id --stable < "$p" | cut -d' ' -f1; done; }
tree_ids() { git -C "$1" format-patch --stdout "$2..HEAD" | git patch-id --stable | cut -d' ' -f1; }

prepare() { # name, upstream URL, branch
	name=$1 url=$2 branch=$3
	dir=$root/src/$name
	series=$root/patches/$name
	[ -f "$series/BASE" ] || die "no $series/BASE"
	base=$(cat "$series/BASE")
	n=$(ls "$series"/*.patch | wc -l | tr -d ' ')

	if [ -e "$dir" ]; then
		git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "$dir exists but is not a git tree"
		[ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ] ||
			die "$dir has uncommitted changes; leaving it alone"
		if [ "$(git -C "$dir" rev-parse -q --verify "HEAD~$n" 2>/dev/null)" = "$base" ] &&
			[ "$(tree_ids "$dir" "$base")" = "$(series_ids "$series")" ]; then
			echo "src/$name: up to date ($(git -C "$dir" log -1 --format='%h %s'))"
			return
		fi
		die "src/$name is not $base + the $n patches in patches/$name (local work or an older series); move it aside to recreate it"
	fi

	echo "src/$name: fetching $url at $base"
	rm -rf "$dir.tmp" && mkdir -p "$dir.tmp"
	trap 'rm -rf "$dir.tmp"' EXIT
	git -C "$dir.tmp" init -q
	git -C "$dir.tmp" remote add origin "$url"
	git -C "$dir.tmp" fetch -q --depth=1 origin "$base"
	git -C "$dir.tmp" -c advice.detachedHead=false checkout -q -b "$branch" FETCH_HEAD
	GIT_COMMITTER_NAME="qhora-301w prepare-src" GIT_COMMITTER_EMAIL="prepare-src@invalid" \
		git -C "$dir.tmp" am -q --committer-date-is-author-date "$series"/*.patch ||
		die "the series in patches/$name does not apply to $base"
	epoch=$(git -C "$dir.tmp" log -1 --format=%ct)
	(cd "$dir.tmp" && git ls-files -z) | python3 -c '
import os, sys
os.chdir(sys.argv[1])
t = int(sys.argv[2])
for p in sys.stdin.buffer.read().split(b"\0"):
    if p:
        os.utime(p, (t, t), follow_symlinks=False)
' "$dir.tmp" "$epoch"
	mv "$dir.tmp" "$dir"
	trap - EXIT
	echo "src/$name: $(git -C "$dir" log -1 --format='%h %s')"
}

case ${1:-all} in
u-boot)  prepare u-boot https://github.com/u-boot/u-boot qhora/ipq8074 ;;
openwrt) prepare openwrt https://github.com/openwrt/openwrt qhora/301w-ubootmod ;;
all)     prepare u-boot https://github.com/u-boot/u-boot qhora/ipq8074
         prepare openwrt https://github.com/openwrt/openwrt qhora/301w-ubootmod ;;
*)       echo "usage: $0 [u-boot|openwrt|all]" >&2; exit 2 ;;
esac
