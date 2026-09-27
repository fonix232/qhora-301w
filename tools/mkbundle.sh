#!/bin/sh
# Build the per-unit bundle for tools/installer/qhora-install.sh from a verified
# backup set (tools/backup-live.sh, taken from the recovery image so the whole
# NOR is covered) and the images to install.
#
#   tools/mkbundle.sh <backup dir> <loader.itb> <slot sysupgrade.itb> <out dir>
#
# The bundle gets a fresh GPT (new partition GUIDs) for layout v2 and a
# manifest that also pins the disk's current GPT to the one in the backup, so
# the installer refuses to run on any other unit or on a disk that has changed
# since the backup. The backup itself stays off the device; it must cover the
# whole NOR before a bundle is made at all.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
bk=$(cd "${1:?usage: $0 <backup dir> <loader.itb> <slot.itb> <out dir>}" && pwd)
loader=$(cd "$(dirname "${2:?}")" && pwd)/$(basename "$2")
slot=$(cd "$(dirname "${3:?}")" && pwd)/$(basename "$3")
out=${4:?}
mkdir -p "$out"; out=$(cd "$out" && pwd)

nor="$bk/nor/nor-assembled-gaps-zeroed.bin"
[ -f "$nor" ] || { echo "no assembled NOR image in $bk" >&2; exit 1; }
grep -q '^  none$' "$bk/nor/coverage.txt" ||
	{ echo "the backup does not cover the whole NOR (take it from the recovery image, P1-B)" >&2; exit 1; }
for f in gpt-primary.bin gpt-backup.bin; do
	[ -f "$bk/emmc/$f" ] || { echo "backup has no emmc/$f" >&2; exit 1; }
done
(cd "$bk" && shasum -a 256 -c MANIFEST.sha256 >/dev/null) ||
	{ echo "backup set does not match its MANIFEST.sha256" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# the slot image without OpenWrt's metadata trailer: cut at the FIT's end
"$root/tools/build/run.sh" python3 - "/work/${slot#$root/}" "/work/${out#$root/}/slot.itb" <<'EOF'
import sys, libfdt
data = open(sys.argv[1], "rb").read()
fit = libfdt.Fdt(data)
end = fit.totalsize()
images = fit.path_offset("/images")
node = fit.first_subnode(images, libfdt.QUIET_NOTFOUND)
while node >= 0:
    size = fit.getprop(node, "data-size", libfdt.QUIET_NOTFOUND)
    if not isinstance(size, int):
        pos = fit.getprop(node, "data-position", libfdt.QUIET_NOTFOUND)
        off = fit.getprop(node, "data-offset", libfdt.QUIET_NOTFOUND)
        start = pos.as_uint32() if not isinstance(pos, int) else (fit.totalsize() + 3) // 4 * 4 + off.as_uint32()
        end = max(end, start + size.as_uint32())
    node = fit.next_subnode(node, libfdt.QUIET_NOTFOUND)
open(sys.argv[2], "wb").write(data[:end])
print(f"slot image: {end} of {len(data)} bytes are the FIT", file=sys.stderr)
EOF

cp "$loader" "$out/loader.itb"
python3 "$root/tools/gpt.py" build "$root/layouts/v2.json" "$work/gpt" 2>/dev/null
cp "$work/gpt.primary.bin" "$work/gpt.backup.bin" "$out/"
python3 -c "
import json
for p in json.load(open('$work/gpt.json'))['partitions']:
    print(p['name'], p['start'], p['end'] - p['start'] + 1)
" > "$out/layout"
cp "$work/gpt.json" "$out/gpt.json"

(cd "$out" && shasum -a 256 gpt.primary.bin gpt.backup.bin layout loader.itb slot.itb > manifest)
echo "$(shasum -a 256 < "$bk/emmc/gpt-primary.bin" | cut -d' ' -f1)  stock-gpt-primary" >> "$out/manifest"
echo "$(shasum -a 256 < "$bk/emmc/gpt-backup.bin" | cut -d' ' -f1)  stock-gpt-backup" >> "$out/manifest"
cp "$root/tools/installer/qhora-install.sh" "$out/"
echo "bundle: $out"
cat "$out/manifest"
