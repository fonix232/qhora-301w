#!/bin/sh
# Compile the OpenWrt series' 301w device trees without an OpenWrt build:
# Linux DT sources from mainline U-Boot's dts/upstream import, OpenWrt's
# qualcommax DT patches applied on top (paths rewritten), plus OpenWrt's own
# dtsi files and binding headers. Fails if either board doesn't compile or
# if the ubootmod variant has dtc warnings the stock one doesn't.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
W=build/dtcheck
cd "$root"
rm -rf "$W" && mkdir -p "$W"
cp -R src/u-boot/dts/upstream/src/arm64/qcom "$W/qcom"
cp -R src/u-boot/dts/upstream/include "$W/include"
(cd "$W" && git init -q . && git add -A && git -c user.name=x -c user.email=x@x commit -q -m base)
for p in src/openwrt/target/linux/qualcommax/patches-6.18/*.patch; do
	grep -q 'arch/arm64/boot/dts/qcom\|include/dt-bindings' "$p" || continue
	sed -e 's#\([ab]\)/arch/arm64/boot/dts/qcom/#\1/qcom/#g' "$p" > "$W/p.patch"
	(cd "$W" && { git apply --include='qcom/*' --include='include/dt-bindings/*' p.patch 2>/dev/null ||
		git apply -R --check --include='qcom/*' --include='include/dt-bindings/*' p.patch 2>/dev/null; }) ||
		{ echo "cannot apply $p" >&2; exit 1; }
done
cp src/openwrt/target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/*.dtsi "$W/qcom/"
cp -R src/openwrt/target/linux/qualcommax/files/include/. "$W/include/"
cp src/openwrt/target/linux/qualcommax/dts/ipq8072-301w*.dts* "$W/qcom/"
tools/build/run.sh sh -c "
cd /work/$W
for b in ipq8072-301w ipq8072-301w-ubootmod; do
	cpp -nostdinc -I include -I qcom -undef -D__DTS__ -x assembler-with-cpp qcom/\$b.dts -o \$b.pp.dts
	dtc -I dts -O dtb -o \$b.dtb \$b.pp.dts 2>&1 | sort > \$b.warn
	echo \"\$b: \$(stat -c %s \$b.dtb) bytes, \$(wc -l < \$b.warn) dtc warnings\"
done
new=\$(comm -13 ipq8072-301w.warn ipq8072-301w-ubootmod.warn)
[ -z \"\$new\" ] || { echo \"new warnings in ubootmod:\"; echo \"\$new\"; exit 1; }
dtc -q -I dtb -O dts ipq8072-301w-ubootmod.dtb | grep -q 'rootdisk-a = ' || { echo 'no rootdisk-a'; exit 1; }
echo ok
" </dev/null
