#!/bin/sh
# Fetch QCA's IPQ807x boot images from the Zyxel NBG7815 GPL drop into
# cache/vendor/nbg7815/ (gitignored, never committed or redistributed), for
# `python3 tools/mkmbn.py verify cache/vendor/nbg7815/*.mbn`, which checks our
# MBN hash-table generator against them. Pinned to one commit and checked
# against known sha256 sums; files already present and correct are kept.
#
# usage: tools/fetch-vendor-mbn.sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
commit=e816d72c67037186f2d5c10639f609649cbcce10
base=https://raw.githubusercontent.com/kirdesde/nbg7815_gpl/$commit/target/linux/ipq/ipq807x_64/prebuilt_images
dir=$root/cache/vendor/nbg7815
mkdir -p "$dir"

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

while read -r sum name; do
	f=$dir/$name
	if [ -f "$f" ] && [ "$(sha256 "$f")" = "$sum" ]; then
		echo "ok      $name"
		continue
	fi
	curl -fsSL --retry 3 -o "$f.part" "$base/$name"
	[ "$(sha256 "$f.part")" = "$sum" ] || { rm -f "$f.part"; echo "sha256 mismatch: $name" >&2; exit 1; }
	mv "$f.part" "$f"
	echo "fetched $name"
done <<EOF
47d82923e9eeac952de230eb51ffcfe429acaa77d7a870328c66077759ab621e devcfg.mbn
2c4dfdb28fa214f6c0b79831263fa908249bb99bbb38f952d0c840c2ddec4e8f openwrt-ipq807x-u-boot.mbn
255733d3ee1a1f25cdf9c3a7a83e24c9fa876588a2cc832c4e40d5930a264cd5 rpm.mbn
02e6aea7e8787dab39649adde4699a4b7cb6fdfe506c0a12a5be023850ae55a6 sbl1_nor.mbn
e4bbde63195d77ff3a89d99f54d5c890d1d4d3b854409be222b9dd132e7e5bc4 tz.mbn
EOF
