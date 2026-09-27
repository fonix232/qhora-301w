#!/bin/sh
# Run a command in the build container with the repo mounted at /work.
# usage: tools/build/run.sh <command...>
#
# The image tag carries a checksum of the Dockerfile, so editing it builds a
# new image instead of reusing a stale one. QH_IMAGE=<tag> uses a prebuilt
# image instead (CI builds it with layer caching). SOURCE_DATE_EPOCH is passed
# through for reproducible builds.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
image=${QH_IMAGE:-qhora-301w-build:$(cksum < "$root/tools/build/Dockerfile" | cut -d' ' -f1)}
if ! docker image inspect "$image" >/dev/null 2>&1; then
	docker build -t "$image" "$root/tools/build"
fi
# On a Linux host, run as the calling user so files written into the checkout
# stay theirs (Docker Desktop and OrbStack already map ownership on macOS).
user=
[ "$(uname -s)" = Linux ] && user="--user $(id -u):$(id -g) -e HOME=/tmp"
# QH_VOLUME=<name> also mounts a named Docker volume at /scratch (a Linux
# filesystem: sparse files work there, unlike on the macOS bind mount). A new
# volume is made world-writable so a non-root container user can use it.
if [ -n "${QH_VOLUME:-}" ] && ! docker volume inspect "$QH_VOLUME" >/dev/null 2>&1; then
	docker volume create "$QH_VOLUME" >/dev/null
	docker run --rm -v "$QH_VOLUME:/scratch" "$image" chmod 1777 /scratch
fi
exec docker run --rm -i $user ${SOURCE_DATE_EPOCH:+-e SOURCE_DATE_EPOCH} \
	-v "$root:/work" ${QH_VOLUME:+-v "$QH_VOLUME:/scratch"} -w /work "$image" "$@"
