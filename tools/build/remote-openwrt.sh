#!/bin/sh
# Build OpenWrt on a remote Docker host (default mimir) instead of the Mac:
# tools/build-openwrt.sh in a resource-capped container. The OpenWrt tree,
# dl/ and ccache stay in a named volume there, and the tree is moved to the
# current series with tools/prepare-src.sh --update, so later builds only
# redo what changed. The repo's tracked files are sent as they are in the
# working tree (committed or not); the images come back to build/openwrt/.
#
# usage: tools/build/remote-openwrt.sh [build|logs|fetch|shell|clean]  (default: build)
#   build   send the tree, start the build, follow it, fetch the images
#   logs    follow a running build (after Ctrl-C or a dropped connection), then fetch
#   fetch   copy the last build's images to build/openwrt/
#   shell   a shell in the build image, with the volume at /build
#   clean   delete the volume (the whole OpenWrt tree, dl/ and ccache)
#
#   QH_REMOTE=ssh://mimir   Docker host
#   QH_REMOTE_CPUS=12       CPU quota and make -j (low CPU weight, so the
#                           host's services win under contention)
#   QH_REMOTE_MEM=10g       memory cap, no swap. mimir has ~18 GiB available
#                           with its services running; freya only ~3 GiB, so
#                           it isn't a suitable host while Lemonade's model is
#                           loaded. Past the cap the build fails, the host is safe.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
export DOCKER_HOST=${QH_REMOTE:-ssh://mimir}
cpus=${QH_REMOTE_CPUS:-12}
mem=${QH_REMOTE_MEM:-10g}
vol=qhora-owrt
name=qhora-owrt-build
image=qhora-owrt-build:$(cksum < "$root/tools/build/openwrt/Dockerfile" | cut -d' ' -f1)
out=$root/build/openwrt
limits="--cpus $cpus --cpu-shares 256 --memory $mem --memory-swap $mem --pids-limit 8192"

ensure_image() {
	docker image inspect "$image" >/dev/null 2>&1 ||
		docker build -q -t "$image" - < "$root/tools/build/openwrt/Dockerfile" >/dev/null
}
running() { [ -n "$(docker ps -q -f "name=^$name\$")" ]; }

fetch() {
	ensure_image
	rm -rf "$out" && mkdir -p "$out"
	docker run --rm -v "$vol:/build:ro" "$image" sh -c '
		cd /build/src/openwrt/bin/targets/qualcommax/ipq807x || exit 1
		cp /build/repo/build/openwrt-diffconfig . 2>/dev/null
		tar cf - $(ls | grep -E "301w|\.buildinfo\$|^profiles\.json\$|^openwrt-diffconfig\$")' |
		tar xf - -C "$out"
	(cd "$out" && shasum -a 256 -- *301w* > sha256sums)
	echo "images in ${out#$root/}:" && cat "$out/sha256sums"
}

follow() {
	docker logs -f "$name" 2>&1 || true
	rc=$(docker wait "$name")
	docker rm "$name" >/dev/null
	[ "$rc" = 0 ] || { echo "remote build failed (exit $rc)" >&2; exit "$rc"; }
}

case ${1:-build} in
build)
	ensure_image
	! running || { echo "a build is already running on $DOCKER_HOST; follow it with: $0 logs" >&2; exit 1; }
	docker rm "$name" >/dev/null 2>&1 || true
	# the working tree's tracked files, uncommitted edits included (stash
	# create makes a commit object without touching the stash or the tree)
	snap=$(git -C "$root" stash create)
	git -C "$root" archive --format=tar "${snap:-HEAD}" |
		docker run --rm -i -v "$vol:/build" "$image" sh -eu -c '
			rm -rf /build/repo && mkdir -p /build/repo /build/src /build/ccache
			tar xf - -C /build/repo && ln -s /build/src /build/repo/src
			[ -f /build/ccache/ccache.conf ] || echo "max_size = 10G" > /build/ccache/ccache.conf'
	docker run -d --name "$name" $limits -e QH_JOBS="$cpus" -e QH_CCACHE_DIR=/build/ccache \
		-v "$vol:/build" -w /build/repo "$image" \
		sh -eu -c 'tools/prepare-src.sh --update openwrt && tools/build-openwrt.sh all' >/dev/null
	echo "building on $DOCKER_HOST ($cpus CPUs, $mem); Ctrl-C stops following, not the build ($0 logs resumes)"
	follow
	fetch ;;
logs)  follow; fetch ;;
fetch) fetch ;;
shell) ensure_image; docker run --rm -it $limits -v "$vol:/build" -w /build "$image" bash ;;
clean) ! running || { echo "a build is running" >&2; exit 1; }; docker volume rm "$vol" ;;
*)     echo "usage: $0 [build|logs|fetch|shell|clean]" >&2; exit 2 ;;
esac
