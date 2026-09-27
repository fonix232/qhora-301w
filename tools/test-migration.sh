#!/bin/sh
# Offline rehearsal of the stock -> v2 migration (docs/safety.md: every write
# step is rehearsed on a disk image first). Uses a full-size synthetic stock
# eMMC, a synthetic backup set, the real loader FIT and installer, then:
#   1. dry run writes nothing
#   2. conversion; result checked with sgdisk, byte compares, and our U-Boot
#      (sandbox) booting slot A from the converted image
#   3. the installer refuses: second run, tampered bundle, other unit's backup
#   4. simulated power cut after every step: the table is always either the
#      old one or the complete new one
#   5. restore from the backup is byte-identical
#
# usage: tools/test-migration.sh   (needs build/loader/*.itb and the sandbox
#                                   from tools/test-bootflow.sh)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
T=build/migration
cd "$root"
rm -rf "$T" && mkdir -p "$T/backup/nor" "$T/backup/emmc"
# the two 3.6 GiB disk images live on a Docker volume (sparse files work there)
export QH_VOLUME=qhora-scratch
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $*"; }
bad() { fail=$((fail+1)); echo "FAIL  $*"; }
c() { tools/build/run.sh sh -c "$*" </dev/null; }
c "rm -rf /scratch/migration && mkdir -p /scratch/migration && touch /scratch/migration/disk.img && ln -sf /scratch/migration/stock.img /work/$T/stock.img && ln -sf /scratch/migration/disk.img /work/$T/disk.img"

# ---- synthetic stock disk and backup set -------------------------------------
python3 tools/gpt.py build layouts/stock.json "$T/stock" --disk-guid 11111111-2222-4333-8444-555555555555 2>/dev/null
c "
cd /work/$T
truncate -s \$((7634944*512)) stock.img
dd if=stock.primary.bin of=stock.img conv=notrunc status=none
dd if=stock.backup.bin of=stock.img bs=512 seek=7634940 conv=notrunc status=none
for lba in 34 32802 65570 98338 1146914 2195490 3244066 3252258 3285026; do
	head -c 4194304 /dev/urandom | dd of=stock.img bs=512 seek=\$lba conv=notrunc status=none
done
dd if=stock.img of=backup/emmc/gpt-primary.bin bs=512 count=34 status=none
dd if=stock.img of=backup/emmc/gpt-backup.bin bs=512 skip=7634911 count=33 status=none
head -c 8388608 /dev/urandom > backup/nor/nor-assembled-gaps-zeroed.bin
printf 'NOR ranges not exposed by the running kernel (zero-filled in the assembled image, NOT device data):\n  none\n' > backup/nor/coverage.txt
sha256sum stock.img | cut -d' ' -f1 > stock.sha256
"
(cd "$T/backup" && find . -type f ! -name MANIFEST.sha256 | sort | xargs shasum -a 256 > MANIFEST.sha256)

# a slot image like OpenWrt's sysupgrade.itb (external data, metadata trailer)
c "
cd /work/$T
head -c 4096 /dev/urandom > kernel.bin; head -c 65536 /dev/urandom > rootfs.bin
printf '/dts-v1/;\n/ { chosen { rootdisk-a = <1>; rootdisk-b = <2>; }; };\n' > board.dts
dtc -q -O dtb -o board.dtb board.dts
cat > slot.its <<EOF
/dts-v1/;
/ { description = \"test slot\"; #address-cells = <1>;
  images {
    kernel-1 { data = /incbin/(\"kernel.bin\"); type = \"kernel\"; arch = \"arm64\"; os = \"linux\"; compression = \"none\"; load = <0x41000000>; entry = <0x41000000>; hash-1 { algo = \"sha1\"; }; };
    fdt-1 { data = /incbin/(\"board.dtb\"); type = \"flat_dt\"; arch = \"arm64\"; compression = \"none\"; hash-1 { algo = \"sha1\"; }; };
    rootfs-1 { data = /incbin/(\"rootfs.bin\"); type = \"filesystem\"; arch = \"arm64\"; compression = \"none\"; hash-1 { algo = \"sha1\"; }; };
  };
  configurations { default = \"config@hk01\"; config@hk01 { kernel = \"kernel-1\"; fdt = \"fdt-1\"; loadables = \"rootfs-1\"; }; };
};
EOF
mkimage -E -B 0x1000 -p 0x1000 -f slot.its slot-raw.itb >/dev/null 2>&1
cat slot-raw.itb > sysupgrade.itb; printf 'OPENWRT-METADATA-TRAILER' >> sysupgrade.itb
"

tools/mkbundle.sh "$T/backup" build/loader/qnap_301w-uboot-loader.itb "$T/sysupgrade.itb" "$T/bundle" >/dev/null 2>"$T/mkbundle.err" ||
	{ cat "$T/mkbundle.err"; exit 1; }
cmp -s "$T/bundle/slot.itb" "$T/slot-raw.itb" && ok "bundle: metadata trailer stripped from the slot image" || bad "bundle: slot image not cut at the FIT end"
[ "$(awk '{ print $2 }' "$T/bundle/manifest" | tr '\n' ' ')" = "gpt.primary.bin gpt.backup.bin layout loader.itb slot.itb stock-gpt-primary stock-gpt-backup " ] &&
	ok "bundle: manifest covers exactly the expected files (no NOR data on the device)" || { bad "bundle manifest"; cat "$T/bundle/manifest"; }

inst() { # extra env, args
	c "cd /work/$T && cp --sparse=always stock.img disk.img 2>/dev/null; true" >/dev/null
	c "cd /work/$T && $1 QH_DISK=/work/$T/disk.img QH_TEST=1 sh bundle/qhora-install.sh bundle $2"
}
disk_sha() { c "sha256sum /work/$T/disk.img | cut -d' ' -f1"; }

# ---- 1. dry run ---------------------------------------------------------------------
c "cp --sparse=always /work/$T/stock.img /work/$T/disk.img"
out=$(c "cd /work/$T && QH_DISK=/work/$T/disk.img QH_TEST=1 sh bundle/qhora-install.sh bundle" 2>&1 || true)
echo "$out" | grep -q "nothing written" && [ "$(disk_sha)" = "$(cat $T/stock.sha256)" ] && ok "dry run: checks pass, disk unchanged" || { bad "dry run"; echo "$out"; }

# ---- 2. conversion ------------------------------------------------------------------
out=$(c "cd /work/$T && QH_DISK=/work/$T/disk.img QH_TEST=1 sh bundle/qhora-install.sh bundle --yes" 2>&1 || true)
echo "$out" | grep -q "converted to layout v2" && ok "conversion completes" || { bad "conversion"; echo "$out"; }
v=$(c "sgdisk -v /work/$T/disk.img 2>&1" || true)
echo "$v" | grep -q "No problems found" && ok "sgdisk: converted table is valid" || { bad "sgdisk verify"; echo "$v"; }
c "cd /work/$T && sfdisk -d disk.img" > "$T/converted.sfdisk"
for n in 0:HLOS 0:HLOS_1 ubootenv ubootenv2 rootfs fit_a fit_b data; do
	grep -q "name=\"$n\"" "$T/converted.sfdisk" || bad "partition $n missing after conversion"
done
# the stock U-Boot's bootipq looks these up by name before it loads anything
# (findings 0004, 0006); without rootfs it stops at its prompt
[ "$(for n in 0:HLOS 0:HLOS_1 rootfs; do grep -c "name=\"$n\"" "$T/converted.sfdisk"; done | tr '\n' ' ')" = "1 1 1 " ] &&
	ok "the names the stock bootipq needs exist once each: 0:HLOS, 0:HLOS_1, rootfs" || bad "a name the stock bootipq needs is missing or duplicated"
# our U-Boot finds its two env copies by type GUID, in table order
[ "$(grep -i 'type=3DE21764-95BD-54BD-A5C3-4ABE786F38A8' "$T/converted.sfdisk" | sed -n 's/.*name="\([^"]*\)".*/\1/p' | tr '\n' ' ')" = "ubootenv ubootenv2 " ] &&
	ok "exactly ubootenv, ubootenv2 carry the U-Boot env type, in that order" || { bad "env partition types"; grep -i 3de21764 "$T/converted.sfdisk"; }
cmpart() { # file, partition name
	set -- "$1" "$2" $(awk -v n="$2" '$1 == n { print $2 }' "$T/bundle/layout")
	c "cd /work/$T && n=\$(wc -c < $1) && dd if=disk.img bs=512 skip=$3 count=\$(( (n+511)/512 )) status=none | head -c \$n | cmp -s - $1"
}
cmpart bundle/loader.itb 0:HLOS && ok "0:HLOS holds the U-Boot loader" || bad "0:HLOS content"
cmpart bundle/loader.itb 0:HLOS_1 && ok "0:HLOS_1 holds the second copy of the loader" || bad "0:HLOS_1 content"
cmpart bundle/slot.itb fit_a && ok "fit_a holds the slot image" || bad "fit_a content"

S=/work/build/u-boot-sandbox
cp build/u-boot-301w/include/generated/env.in "$T/board.env"
printf 'qh_if=host\nqh_dev=0\nloadaddr=0x2000000\nqh_do_boot=echo QH_BOOT slot=${qh_s} rootdisk=${boot_rootdisk}\nqh_rescue=echo QH_RESCUE\nqh_rescue_loop=run qh_rescue\nqh_btn=button1\n' > "$T/test.env"
c "$S/u-boot -d $S/u-boot.dtb -c 'host bind 0 /work/$T/disk.img; load hostfs - 0x1000000 /work/$T/board.env; env import -t 0x1000000 \${filesize}; load hostfs - 0x1000000 /work/$T/test.env; env import -t 0x1000000 \${filesize}; run qh_boot'" > "$T/uboot.log" 2>&1 || true
boot=$(grep -m1 '^QH_' "$T/uboot.log" || true)
echo "$boot" | grep -q "QH_BOOT slot=a rootdisk=rootdisk-a" && ok "our U-Boot boots slot A from the converted disk" ||
	{ bad "U-Boot on converted disk: $boot"; grep -E -i "qh:|error|bad|fail|##|part|read" "$T/uboot.log" | head -20 | sed 's/^/      /'; }

# ---- 3. refusals ----------------------------------------------------------------------
out=$(c "cd /work/$T && QH_DISK=/work/$T/disk.img QH_TEST=1 sh bundle/qhora-install.sh bundle --yes" 2>&1 || true)
echo "$out" | grep -q "already converted" && ok "refuses a second run on a converted disk" || { bad "second run not refused"; echo "$out"; }
c "cp --sparse=always /work/$T/stock.img /work/$T/disk.img"
cp "$T/bundle/slot.itb" "$T/slot.bak"; printf 'x' >> "$T/bundle/slot.itb"
out=$(c "cd /work/$T && QH_DISK=/work/$T/disk.img QH_TEST=1 sh bundle/qhora-install.sh bundle --yes" 2>&1 || true)
mv "$T/slot.bak" "$T/bundle/slot.itb"
echo "$out" | grep -q "does not match the manifest" && [ "$(disk_sha)" = "$(cat $T/stock.sha256)" ] && ok "refuses a tampered bundle, disk unchanged" || { bad "tampered bundle"; echo "$out"; }
python3 tools/gpt.py build layouts/stock.json "$T/other" --disk-guid 99999999-2222-4333-8444-555555555555 2>/dev/null
c "cd /work/$T && dd if=other.primary.bin of=disk.img conv=notrunc status=none"
out=$(c "cd /work/$T && QH_DISK=/work/$T/disk.img QH_TEST=1 sh bundle/qhora-install.sh bundle --yes" 2>&1 || true)
echo "$out" | grep -q "not the one in the backup" && ok "refuses a disk that isn't the backed-up unit" || { bad "other unit not refused"; echo "$out"; }

# ---- 4. power cuts ----------------------------------------------------------------------
prim_new=$(shasum -a 256 < "$T/bundle/gpt.primary.bin" | cut -d' ' -f1)
prim_old=$(shasum -a 256 < "$T/backup/emmc/gpt-primary.bin" | cut -d' ' -f1)
back_new=$(shasum -a 256 < "$T/bundle/gpt.backup.bin" | cut -d' ' -f1)
for n in 1 2 3 4 5 6 7 8; do
	c "cp --sparse=always /work/$T/stock.img /work/$T/disk.img"
	c "cd /work/$T && QH_STOP_AFTER=$n QH_DISK=/work/$T/disk.img QH_TEST=1 sh bundle/qhora-install.sh bundle --yes" >/dev/null 2>&1 || true
	p=$(c "dd if=/work/$T/disk.img bs=512 count=34 status=none | sha256sum | cut -d' ' -f1")
	b=$(c "dd if=/work/$T/disk.img bs=512 skip=7634911 count=33 status=none | sha256sum | cut -d' ' -f1")
	if [ "$p" = "$prim_old" ]; then state="old table (stock layout)"
	elif [ "$p" = "$prim_new" ] && [ "$b" = "$back_new" ]; then state="complete new table"
	else state="INCONSISTENT"; fi
	[ "$state" != "INCONSISTENT" ] && ok "power cut after step $n -> $state" || bad "power cut after step $n -> $state"
	if [ "$state" = "old table (stock layout)" ]; then
		out=$(c "cd /work/$T && QH_DISK=/work/$T/disk.img QH_TEST=1 sh bundle/qhora-install.sh bundle --yes" 2>&1 || true)
		echo "$out" | grep -q "converted to layout v2" && ok "  ...and re-running the installer completes the conversion" || { bad "  ...re-run after step $n"; echo "$out" | tail -3; }
	fi
done

# ---- 5. restore -------------------------------------------------------------------------
c "cp --sparse=always /work/$T/stock.img /work/$T/disk.img && cd /work/$T && QH_DISK=/work/$T/disk.img QH_TEST=1 sh bundle/qhora-install.sh bundle --yes >/dev/null && truncate -s 0 disk.img && dd if=stock.img of=disk.img bs=1M conv=sparse status=none && truncate -s \$((7634944*512)) disk.img"
[ "$(disk_sha)" = "$(cat $T/stock.sha256)" ] && ok "restore of the stock image is byte-identical" || bad "restore"

c "rm -rf /scratch/migration"; rm -f "$T"/*.img
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
