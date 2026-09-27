#!/bin/sh
# Build the 301w recovery/backup image: the official OpenWrt initramfs FIT for
# qnap_301w, repacked with its device tree patched so that
#   - 0:appsbl starts at 0x270000 (docs/findings/0001-appsbl-dts-offset.md)
#   - a read-only "nor-full" MTD partition covers the whole 8 MiB NOR,
#     so tools/backup-live.sh can read every byte of it.
# Nothing else changes: same kernel and initramfs, configuration config@hk01,
# so the stock U-Boot boots it from RAM (tftpboot + bootm) and so will ours.
#
# usage: tools/mkrecovery.sh [openwrt-version]      (default 25.12.5)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
ver=${1:-25.12.5}
name=openwrt-$ver-qualcommax-ipq807x-qnap_301w-initramfs-uImage.itb
base=https://downloads.openwrt.org/releases/$ver/targets/qualcommax/ipq807x
src=cache/openwrt/$name
work=build/recovery/$ver
out=build/recovery/qnap_301w-recovery-$ver.itb

mkdir -p "$root/cache/openwrt" "$root/$work"
if [ ! -f "$root/$src" ]; then
	curl -sfSL -o "$root/$src" "$base/$name"
fi
curl -sfSL "$base/sha256sums" | grep " \*\{0,1\}$name\$" | awk '{print $1}' > "$root/$work/expected.sha256"
[ "$(shasum -a 256 "$root/$src" | cut -d' ' -f1)" = "$(cat "$root/$work/expected.sha256")" ] ||
	{ echo "checksum mismatch for $src" >&2; exit 1; }

"$root/tools/build/run.sh" sh -eu -c "
cd /work/$work
dumpimage -T flat_dt -p 0 -o kernel.gz /work/$src >/dev/null
dumpimage -T flat_dt -p 1 -o board.dtb /work/$src >/dev/null
python3 - <<'PY'
import libfdt

fdt = libfdt.Fdt(bytearray(open('board.dtb', 'rb').read()))
fdt.resize(fdt.totalsize() + 4096)

def find_label(label):
    node, depth = 0, 0
    while True:
        r = fdt.next_node(node, depth, libfdt.QUIET_NOTFOUND)
        if isinstance(r, int) or r[1] < 0:
            return None
        node, depth = r
        prop = fdt.getprop(node, 'label', libfdt.QUIET_NOTFOUND)
        if not isinstance(prop, int) and prop.as_str() == label:
            return node

appsbl = find_label('0:appsbl')
assert appsbl is not None, 'no 0:appsbl partition in the DTB'
start, size = fdt.getprop(appsbl, 'reg').as_uint32_list()
assert size == 0x100000, hex(size)
if start != 0x270000:
    assert start == 0x250000, hex(start)
    fdt.setprop(appsbl, 'reg', (0x270000).to_bytes(4, 'big') + size.to_bytes(4, 'big'))
    print('fixed 0:appsbl: 0x250000 -> 0x270000')

parts = fdt.parent_offset(appsbl, libfdt.QUIET_NOTFOUND)
full = fdt.add_subnode(parts, 'nor-full@0')
fdt.setprop_str(full, 'label', 'nor-full')
fdt.setprop(full, 'reg', (0).to_bytes(4, 'big') + (0x800000).to_bytes(4, 'big'))
fdt.setprop(full, 'read-only', b'')
print('added read-only nor-full 0x0-0x7fffff under', fdt.get_path(parts))

fdt.pack()
open('board-recovery.dtb', 'wb').write(fdt.as_bytearray())
PY
cat > recovery.its <<EOF
/dts-v1/;
/ {
	description = \"QNAP QHora-301W recovery/backup (OpenWrt $ver initramfs, patched DT)\";
	#address-cells = <1>;
	images {
		kernel-1 {
			description = \"OpenWrt $ver Linux with initramfs\";
			data = /incbin/(\"kernel.gz\");
			type = \"kernel\";
			arch = \"arm64\";
			os = \"linux\";
			compression = \"gzip\";
			load = <0x41000000>;
			entry = <0x41000000>;
			hash-1 { algo = \"crc32\"; };
			hash-2 { algo = \"sha1\"; };
		};
		fdt-1 {
			description = \"QNAP 301w, 0:appsbl fixed, nor-full added\";
			data = /incbin/(\"board-recovery.dtb\");
			type = \"flat_dt\";
			arch = \"arm64\";
			compression = \"none\";
			hash-1 { algo = \"crc32\"; };
			hash-2 { algo = \"sha1\"; };
		};
	};
	configurations {
		default = \"config@hk01\";
		config@hk01 {
			description = \"OpenWrt qnap_301w recovery\";
			kernel = \"kernel-1\";
			fdt = \"fdt-1\";
		};
	};
};
EOF
mkimage -f recovery.its /work/$out >/dev/null 2>&1
dumpimage -l /work/$out | grep -e Description -e Configuration -e 'Data Size'
"
ls -l "$root/$out"
shasum -a 256 "$root/$out"
