#!/bin/sh
# Full, read-only backup of a QNAP QHora-301W running OpenWrt, taken over SSH.
#
#   tools/backup-live.sh root@<router-ip> [unit-name]
#
# Everything the device runs is a fixed read: cat, dd if=, sha256sum,
# fw_printenv, uci show, the package list, and `sysupgrade -b` into /tmp
# (tmpfs). Nothing is written to flash, nothing is rebooted.
#
# Output: backups/<unit>/<UTC timestamp>/ with MANIFEST.sha256. See
# docs/safety.md ("Backups") for what a complete set needs; the NOR range
# 0x350000-0x36FFFF is not exposed by OpenWrt's partition table
# (docs/findings/0001-appsbl-dts-offset.md) and is reported as a gap.
set -eu

target=${1:?usage: $0 root@<router-ip> [unit-name]}
unit=${2:-301w}
root=$(cd "$(dirname "$0")/.." && pwd)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="$root/backups/$unit/$stamp"
ssh_opts="-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15"

r() { ssh $ssh_opts "$target" "$@"; }
say() { printf '%s\n' "$*" >&2; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

mkdir -p "$out/info" "$out/nor" "$out/emmc" "$out/openwrt"
say "backup -> $out"

# --- identity check: refuse anything that isn't a 301w -----------------------
board=$(r cat /tmp/sysinfo/board_name)
[ "$board" = "qnap,301w" ] || { say "board is '$board', expected 'qnap,301w'; refusing"; exit 1; }

# --- system information (small, text) ----------------------------------------
for spec in \
	"proc-mtd.txt:cat /proc/mtd" \
	"cmdline.txt:cat /proc/cmdline" \
	"partitions.txt:cat /proc/partitions" \
	"fw_printenv.txt:fw_printenv" \
	"openwrt_release.txt:cat /etc/openwrt_release" \
	"board.json:cat /etc/board.json" \
	"uname.txt:uname -a" \
	"dmesg.txt:dmesg" \
	"uci-show.txt:uci show" \
	"mounts.txt:cat /proc/mounts" \
	"packages.txt:if command -v apk >/dev/null; then apk list --installed; else opkg list-installed; fi" \
	"mtd-sysfs.txt:for d in /sys/class/mtd/mtd[0-9] /sys/class/mtd/mtd[0-9][0-9]; do [ -f \$d/name ] && echo \${d##*/} \$(cat \$d/name) \$(cat \$d/offset) \$(cat \$d/size); done" \
	"loop-backing.txt:for l in /sys/block/loop*/loop/backing_file; do [ -f \$l ] && echo \$l \$(cat \$l); done" \
	"emmc-parts.txt:for p in /sys/class/block/mmcblk0p*; do echo \${p##*/} \$(sed -n 's/^PARTNAME=//p' \$p/uevent) \$(cat \$p/start) \$(cat \$p/size); done" \
	"ext_csd.txt:cat /sys/kernel/debug/mmc0/mmc0:0001/ext_csd 2>/dev/null || echo unavailable"
do
	name=${spec%%:*}; cmd=${spec#*:}
	r "$cmd" > "$out/info/$name" 2>&1 || say "  (info/$name: command failed, kept output)"
done
r cat /sys/firmware/fdt > "$out/info/running.dtb"
say "info: done"

# --- NOR: every MTD partition, read twice, must match ------------------------
while read -r dev name offset size extra; do
	[ -n "$size" ] && [ -z "$extra" ] || { say "unexpected line in mtd-sysfs.txt: $dev $name $offset $size $extra"; exit 1; }
	f="$out/nor/$dev-$(echo "$name" | tr ':/' '__').bin"
	r "cat /dev/${dev}ro" > "$f"
	r "cat /dev/${dev}ro" > "$f.2"
	a=$(sha "$f"); b=$(sha "$f.2")
	[ "$a" = "$b" ] || { say "NOR $dev: two reads differ ($a vs $b); stopping"; exit 1; }
	[ "$(wc -c < "$f" | tr -d ' ')" -eq "$((size))" ] || { say "NOR $dev: short read"; exit 1; }
	rm "$f.2"
	say "nor: $dev $name offset=$offset size=$size ok"
done < "$out/info/mtd-sysfs.txt"

# Assemble an 8 MiB image by offset and record what isn't covered.
python3 - "$out" <<'EOF'
import os, sys
out = sys.argv[1]
img = bytearray(8 << 20)
cov = bytearray(8 << 20)
for line in open(f"{out}/info/mtd-sysfs.txt"):
    dev, name, off, size = line.split()
    off, size = int(off), int(size)
    data = open(f"{out}/nor/{dev}-{name.replace(':', '_').replace('/', '_')}.bin", "rb").read()
    for i in range(size):
        if cov[off + i] and img[off + i] != data[i]:
            sys.exit(f"overlapping partitions disagree at {off + i:#x}")
    img[off:off + size] = data
    cov[off:off + size] = b"\1" * size
gaps, start = [], None
for i, c in enumerate(cov + b"\1"):
    if not c and start is None:
        start = i
    elif c and start is not None:
        gaps.append((start, i)); start = None
open(f"{out}/nor/nor-assembled-gaps-zeroed.bin", "wb").write(img)
with open(f"{out}/nor/coverage.txt", "w") as f:
    f.write("NOR ranges not exposed by the running kernel (zero-filled in the assembled image, NOT device data):\n")
    for a, b in gaps:
        f.write(f"  {a:#08x}-{b - 1:#08x} ({b - a} bytes)\n")
    if not gaps:
        f.write("  none\n")
print(open(f"{out}/nor/coverage.txt").read(), end="", file=sys.stderr)
EOF

# --- eMMC: whole user area, boot partitions, GPT copies ----------------------
sectors=$(r cat /sys/class/block/mmcblk0/size)
say "emmc: $sectors sectors, streaming the whole device"
r "dd if=/dev/mmcblk0 bs=1M 2>/dev/null" | zstd -q -T0 -10 -o "$out/emmc/mmcblk0.img.zst"
say "emmc: hashing each partition on the device"
r 'for p in /sys/class/block/mmcblk0p*; do n=${p##*/}; echo $n $(cat $p/start) $(cat $p/size) $(sha256sum /dev/$n | cut -d" " -f1); done' > "$out/emmc/device-partitions.sha256"

# Compare every partition hashed on the device with the same range of the
# stored image. The running system keeps writing to whatever is mounted or
# backs a loop device (normally p4, the OpenWrt overlay); only those may
# differ. Everything else must match byte for byte.
python3 - "$out" "$sectors" <<'PY'
import hashlib, subprocess, sys
out, sectors = sys.argv[1], int(sys.argv[2])
parts = []
for line in open(f"{out}/emmc/device-partitions.sha256"):
    name, start, size, digest = line.split()
    parts.append((int(start) * 512, (int(start) + int(size)) * 512, name, digest))
live = set()
for line in open(f"{out}/info/mounts.txt"):
    dev = line.split()[0]
    if dev.startswith("/dev/mmcblk0p"):
        live.add(dev[5:])
for line in open(f"{out}/info/loop-backing.txt"):
    if "/dev/mmcblk0p" in line:
        live.add(line.split()[-1][5:])
whole = hashlib.sha256()
hashers = {name: hashlib.sha256() for _, _, name, _ in parts}
pos = 0
zs = subprocess.Popen(["zstd", "-dc", f"{out}/emmc/mmcblk0.img.zst"], stdout=subprocess.PIPE)
while chunk := zs.stdout.read(1 << 20):
    whole.update(chunk)
    end = pos + len(chunk)
    for a, b, name, _ in parts:
        lo, hi = max(a, pos), min(b, end)
        if lo < hi:
            hashers[name].update(chunk[lo - pos:hi - pos])
    pos = end
zs.wait()
if pos != sectors * 512:
    sys.exit(f"stored image is {pos} bytes, device has {sectors * 512}")
bad = []
with open(f"{out}/emmc/verify.txt", "w") as f:
    for _, _, name, digest in parts:
        ok = hashers[name].hexdigest() == digest
        state = "ok" if ok else ("changed (live, expected)" if name in live else "MISMATCH")
        f.write(f"{name} {state}\n")
        if not ok and name not in live:
            bad.append(name)
    f.write(f"stored image sha256 {whole.hexdigest()}\n")
print(open(f"{out}/emmc/verify.txt").read(), end="", file=sys.stderr)
if bad:
    sys.exit(f"partitions that must not change differ: {bad}")
PY
say "emmc: verified"

r "dd if=/dev/mmcblk0 bs=512 count=34 2>/dev/null" > "$out/emmc/gpt-primary.bin"
r "dd if=/dev/mmcblk0 bs=512 skip=$((sectors - 33)) count=33 2>/dev/null" > "$out/emmc/gpt-backup.bin"
for b in mmcblk0boot0 mmcblk0boot1; do
	r "[ -e /dev/$b ] && cat /dev/$b" > "$out/emmc/$b.bin" || say "  ($b not present)"
done
say "emmc: gpt and boot partitions done"

# --- OpenWrt configuration ------------------------------------------------------
r "sysupgrade -b /tmp/qhora-backup.tgz >/dev/null 2>&1 && cat /tmp/qhora-backup.tgz; rm -f /tmp/qhora-backup.tgz" > "$out/openwrt/sysupgrade-backup.tgz"
say "openwrt: config archive done"

# --- manifest ----------------------------------------------------------------------
(cd "$out" && find . -type f ! -name MANIFEST.sha256 | sort | xargs shasum -a 256 > MANIFEST.sha256)
say "manifest: $out/MANIFEST.sha256"
say "Next: copy $out to a second place off this Mac (e.g. freya) and confirm the set."
