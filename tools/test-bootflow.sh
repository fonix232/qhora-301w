#!/bin/sh
# Exercise the 301w boot flow (src/u-boot/board/qnap/301w/301w.env) in U-Boot's
# sandbox, against layout-v2 disk images with real FIT slot images.
#
# Every scenario imports the board's default environment, points the scripts
# at a host-backed disk instead of the eMMC, replaces the final bootm and the
# USB/TFTP rescue with markers, and checks which path was taken.
#
# usage: tools/test-bootflow.sh        (needs build/u-boot-301w built first)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$root/build/u-boot-301w/include/generated/env.in" ] ||
	{ echo "build the 301w U-Boot first (its env.txt is the input)" >&2; exit 1; }

exec "$root/tools/build/run.sh" sh -eu -c '
S=/work/build/u-boot-sandbox
T=/work/build/bootflow
if [ ! -x $S/u-boot ] || grep -q "^CONFIG_FIT_SIGNATURE=y" $S/.config; then
	make -C src/u-boot O=$S sandbox_defconfig >/dev/null
	# Mirror the 301w build: no FIT signature support, which is also what
	# lets U-Boot accept the "config@hk01" node name the stock U-Boot needs.
	src/u-boot/scripts/config --file $S/.config -d FIT_SIGNATURE -d SPL_FIT_SIGNATURE
	make -C src/u-boot O=$S olddefconfig </dev/null >/dev/null
	make -C src/u-boot O=$S -j"$(nproc)" NO_SDL=1 </dev/null >/work/build/sandbox-build.log 2>&1 ||
		{ echo "sandbox build failed, see build/sandbox-build.log" >&2; tail -20 /work/build/sandbox-build.log >&2; exit 1; }
fi
rm -rf $T && mkdir -p $T && cd $T

# --- a slot FIT like OpenWrt builds it: external, 4 KiB aligned, static ---
head -c 4096 /dev/urandom > kernel.bin
head -c 65536 /dev/urandom > rootfs.bin
cat > board.dts <<EOF
/dts-v1/;
/ { model = "fake 301w"; chosen { rootdisk-a = <1>; rootdisk-b = <2>; }; };
EOF
dtc -q -O dtb -o board.dtb board.dts
cat > slot.its <<EOF
/dts-v1/;
/ {
	description = "test slot";
	#address-cells = <1>;
	images {
		kernel-1 { data = /incbin/("kernel.bin"); type = "kernel"; arch = "arm64"; os = "linux";
			compression = "none"; load = <0x41000000>; entry = <0x41000000>;
			hash-1 { algo = "sha1"; }; };
		fdt-1 { data = /incbin/("board.dtb"); type = "flat_dt"; arch = "arm64"; compression = "none";
			hash-1 { algo = "sha1"; }; };
		rootfs-1 { data = /incbin/("rootfs.bin"); type = "filesystem"; arch = "arm64"; compression = "none";
			hash-1 { algo = "sha1"; }; };
	};
	configurations {
		default = "config@hk01";
		config@hk01 { kernel = "kernel-1"; fdt = "fdt-1"; loadables = "rootfs-1"; };
	};
};
EOF
mkimage -E -B 0x1000 -p 0x1000 -f slot.its slot.itb >/dev/null

# --- layout v2 disk ---
python3 /work/tools/gpt.py build /work/layouts/v2.json gpt >/dev/null 2>&1
sectors=7634944
start() { python3 -c "import json;print([p[\"start\"] for p in json.load(open(\"gpt.json\"))[\"partitions\"] if p[\"name\"]==\"$1\"][0])"; }
A=$(start fit_a); B=$(start fit_b)
mkdisk() { # name, what goes in fit_a, what goes in fit_b  (slot|zero|badhash)
	img=$1.img; rm -f $img; truncate -s $((sectors*512)) $img
	dd if=gpt.primary.bin of=$img conv=notrunc status=none
	dd if=gpt.backup.bin of=$img bs=512 seek=$(python3 -c "import json;print(json.load(open(\"gpt.json\"))[\"backup_lba\"])") conv=notrunc status=none
	for pair in "$A:$2" "$B:$3"; do
		lba=${pair%%:*}; kind=${pair#*:}
		case $kind in
		slot) dd if=slot.itb of=$img bs=512 seek=$lba conv=notrunc status=none ;;
		badhash) dd if=slot.itb of=$img bs=512 seek=$lba conv=notrunc status=none
			printf "\\377" | dd of=$img bs=1 seek=$((lba*512 + $(stat -c %s slot.itb) - 100)) conv=notrunc status=none ;;
		zero) ;;
		esac
	done
}
mkdisk good slot slot
mkdisk a_missing zero slot
mkdisk a_badhash badhash slot
mkdisk none zero zero

cp /work/build/u-boot-301w/include/generated/env.in board.env
cat > test.env <<EOF
qh_if=host
qh_dev=0
loadaddr=0x2000000
qh_do_boot=echo QH_BOOT slot=\${qh_s} rootdisk=\${boot_rootdisk} active=\${boot_slot} fallback=\${boot_fallback}
qh_rescue=echo QH_RESCUE
qh_rescue_loop=run qh_rescue
qh_btn=button1
EOF

pass=0; fail=0
run_case() { # name, disk, u-boot commands, expected regex
	out=$($S/u-boot -d $S/u-boot.dtb -c "host bind 0 $T/$2.img; load hostfs - 0x1000000 $T/board.env; env import -t 0x1000000 \${filesize}; load hostfs - 0x1000000 $T/test.env; env import -t 0x1000000 \${filesize}; $3" 2>&1 || true)
	# qh_do_boot/qh_rescue only print markers here, so a script carries on
	# after its "boot"; the first marker is the path actually taken.
	first=$(echo "$out" | grep -m1 "^QH_" || true)
	if echo "$first" | grep -E -q "$4"; then
		pass=$((pass+1)); echo "PASS  $1"
	else
		fail=$((fail+1)); echo "FAIL  $1  (wanted /$4/, first marker: $first)"; echo "$out" | grep -E "QH_|qh:|Bad|bad|rror|##" | sed "s/^/      /" | tail -12
	fi
}

run_case "both slots good, active a"          good      "run qh_boot"                                   "QH_BOOT slot=a rootdisk=rootdisk-a active=a"
run_case "both slots good, active b"          good      "setenv boot_slot b; run qh_boot"               "QH_BOOT slot=b rootdisk=rootdisk-b active=b"
run_case "level 3: slot a missing -> b"       a_missing "run qh_boot"                                   "QH_BOOT slot=b rootdisk=rootdisk-b active=b fallback=1"
run_case "level 3: slot a bad hash -> b"      a_badhash "run qh_boot"                                   "QH_BOOT slot=b rootdisk=rootdisk-b active=b fallback=1"
run_case "level 2: no bootable slot -> rescue" none     "run qh_boot"                                   "QH_RESCUE"
run_case "level 4: a keeps failing -> b"      good      "run altbootcmd"                                "QH_BOOT slot=b rootdisk=rootdisk-b active=b fallback=1"
run_case "level 4 twice -> rescue"            good      "setenv boot_fallback 1; run altbootcmd"         "QH_RESCUE"
run_case "control: button not held -> boot"   good      "gpio clear a3; run qh_boot"                    "^QH_BOOT slot=a"
run_case "reset button held -> rescue first"  good      "gpio set a3; run qh_boot"                      "^QH_RESCUE"

# The sandbox has its own config, so check the real 301w build for what the
# flow needs from it: GPT (partitions by name), env partitions by type GUID,
# and no raw-offset env fallback (finding 0002).
C=/work/build/u-boot-301w/.config
for opt in EFI_PARTITION PARTITION_TYPE_GUID ENV_MMC_USE_DT ENV_REDUNDANT; do
	if grep -q "^CONFIG_$opt=y" $C; then pass=$((pass+1)); echo "PASS  301w config has $opt"
	else fail=$((fail+1)); echo "FAIL  301w config lacks $opt"; fi
done
D=/work/build/u-boot-301w/arch/arm/dts/ipq8072-qnap-301w.dtb
if ! fdtget -t s $D / model >/dev/null 2>&1; then
	fail=$((fail+1)); echo "FAIL  cannot read $D with fdtget (control)"
elif fdtget -t s $D /config u-boot,mmc-env-partition >/dev/null 2>&1 || fdtget $D /config u-boot,mmc-env-offset >/dev/null 2>&1; then
	fail=$((fail+1)); echo "FAIL  301w DT names an env partition or raw offset (would put both copies in one place / allow raw writes)"
else
	pass=$((pass+1)); echo "PASS  301w DT has no env partition name or raw offset"
fi

echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
'
