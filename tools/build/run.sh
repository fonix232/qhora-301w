#!/bin/sh
# Run a command in the build container with the repo mounted at /work.
# usage: tools/build/run.sh <command...>
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
image=qhora-301w-build
if ! docker image inspect "$image" >/dev/null 2>&1; then
	docker build -t "$image" "$root/tools/build"
fi
exec docker run --rm -i -v "$root:/work" -w /work "$image" "$@"
