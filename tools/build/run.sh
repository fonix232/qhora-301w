#!/bin/sh
# Run a command in the build container with the repo mounted at /work.
# usage: tools/build/run.sh <command...>
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
image=qhora-301w-build
if ! docker image inspect "$image" >/dev/null 2>&1; then
	docker build -t "$image" "$root/tools/build"
fi
# QH_VOLUME=<name> also mounts a named Docker volume at /scratch (a Linux
# filesystem: sparse files work there, unlike on the macOS bind mount).
exec docker run --rm -i -v "$root:/work" ${QH_VOLUME:+-v "$QH_VOLUME:/scratch"} -w /work "$image" "$@"
