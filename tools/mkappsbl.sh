#!/bin/sh
# Build the APPSBL image for the APPSBL phase: tools/appsbl/trampoline.S
# followed by our arm64 U-Boot, wrapped as an ELF32 with an MBN v3 hash
# segment (tools/mkmbn.py). Also writes the raw image, which the stock
# U-Boot can run from RAM with `go` to test the trampoline without touching
# the NOR (docs/procedures.md, P3).
#
# usage: tools/mkappsbl.sh [u-boot build dir]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
build=${1:-build/u-boot-301w}
out=build/appsbl
[ -f "$root/$build/u-boot.bin" ] || { echo "build U-Boot first" >&2; exit 1; }
mkdir -p "$root/$out"
"$root/tools/build/run.sh" sh -eu -c "
cd /work/$out
arm-linux-gnueabihf-gcc -c -o trampoline.o -DPAYLOAD='\"/work/$build/u-boot.bin\"' /work/tools/appsbl/trampoline.S
arm-linux-gnueabihf-ld -Ttext=0 -o trampoline.elf trampoline.o
arm-linux-gnueabihf-objcopy -O binary trampoline.elf qnap_301w-appsbl-raw.bin
arm-linux-gnueabihf-objdump -d --stop-address=0x100 trampoline.elf > trampoline.lst
"
python3 "$root/tools/mkmbn.py" appsbl "$root/$out/qnap_301w-appsbl-raw.bin" "$root/$out/qnap_301w-appsbl.mbn"
python3 "$root/tools/analyze-boot.py" elf "$root/$out/qnap_301w-appsbl.mbn"
shasum -a 256 "$root/$out/qnap_301w-appsbl-raw.bin" "$root/$out/qnap_301w-appsbl.mbn"
