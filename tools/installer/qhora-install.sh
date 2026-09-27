#!/bin/sh
# Convert a QNAP QHora-301W eMMC from the stock layout to layout v2
# (docs/design.md). Runs on the device, booted from RAM (the recovery image),
# from a directory holding the bundle made by tools/mkbundle.sh:
#
#   manifest          sha256 of every file below, and of the disk's current
#                     GPT areas as captured in the backup (see mkbundle.sh)
#   gpt.primary.bin   new GPT, LBA 0..33
#   gpt.backup.bin    new backup GPT, the disk's last 33 sectors
#   layout            "name start_lba sectors" for every v2 partition
#   loader.itb        our U-Boot as a FIT for the stock U-Boot (-> 0:HLOS and
#                     0:HLOS_1: the stock U-Boot falls back to entry 1 by
#                     itself when entry 0 fails to load, finding 0004)
#   slot.itb          OpenWrt slot image, metadata stripped (-> fit_a; the
#                     rest of fit_a becomes that slot's overlay, /dev/fitrw)
#
#   qhora-install.sh <bundle dir> [--yes]
#
# Nothing is written unless every check passes. Payloads go first and are read
# back; then the new backup GPT, then the new primary GPT. A power cut at any
# point leaves either the old table (stock layout) or the complete new one.
# After a power cut the old 0:HLOS/0:HLOS_1 may be partly overwritten, so the
# stock U-Boot marks both entries bad and stops at its prompt; boot the
# recovery image from there and re-run. The script never writes the stock
# U-Boot environment (NOR): at the end it reports boot_0/boot_1/current_entry
# and prints the fw_setenv to run if a failed boot left them changed.
# For the offline rehearsal, QH_DISK points at an image file instead of the
# eMMC and QH_TEST=1 skips the checks that only make sense on the device;
# QH_STOP_AFTER=<step> simulates a power cut after that step.
set -eu

bundle=${1:?usage: qhora-install.sh <bundle dir> [--yes]}
disk=${QH_DISK:-/dev/mmcblk0}
sectors_expected=7634944

say() { echo "qhora-install: $*"; }
die() { echo "qhora-install: ERROR: $*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
dd_q() { dd "$@" 2>/dev/null; }
step=0
checkpoint() {
	step=$((step + 1))
	say "step $step done: $1"
	if [ "${QH_STOP_AFTER:-}" = "$step" ]; then
		say "simulated power cut after step $step"
		exit 3
	fi
}

cd "$bundle" || die "no bundle directory $bundle"

# ---- checks: nothing below writes -------------------------------------------
[ -f manifest ] || die "bundle has no manifest"
while read -r want name; do
	case "$name" in
	stock-gpt-primary|stock-gpt-backup) continue ;;
	esac
	[ -f "$name" ] || die "bundle file $name missing"
	[ "$(sha "$name")" = "$want" ] || die "bundle file $name does not match the manifest"
done < manifest
say "bundle verified"

if [ -z "${QH_TEST:-}" ]; then
	[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = "qnap,301w" ] ||
		die "this is not a QNAP 301w running the recovery image"
	grep -qE '^[^ ]+ / (tmpfs|ramfs|rootfs) ' /proc/mounts || die "not running from RAM"
	grep -q '^/dev/mmcblk0' /proc/mounts && die "something on the eMMC is mounted"
fi

if [ -b "$disk" ]; then
	sectors=$(cat "/sys/class/block/${disk##*/}/size")
else
	sectors=$(($(wc -c < "$disk") / 512))
fi
[ "$sectors" -eq "$sectors_expected" ] || die "disk has $sectors sectors, expected $sectors_expected"

cur_primary=$(dd_q if="$disk" bs=512 count=34 | sha256sum | cut -d' ' -f1)
cur_backup=$(dd_q if="$disk" bs=512 skip=$((sectors - 33)) count=33 | sha256sum | cut -d' ' -f1)
[ "$cur_primary" = "$(awk '$2 == "stock-gpt-primary" { print $1 }' manifest)" ] ||
	die "the disk's GPT is not the one in the backup: already converted, or backup of another unit"
# The backup GPT is either the stock one, or already this bundle's new one:
# the state a power cut leaves after the new backup GPT was written but not
# yet the primary. Every write below is idempotent, so just redo them all.
if [ "$cur_backup" = "$(awk '$2 == "stock-gpt-backup" { print $1 }' manifest)" ]; then
	say "disk is the stock layout from the backup"
elif [ "$cur_backup" = "$(sha gpt.backup.bin)" ]; then
	say "disk is the stock layout from the backup, with this bundle's backup GPT (interrupted run): resuming"
else
	die "the disk's backup GPT is neither the stock one nor this bundle's"
fi

part() { awk -v n="$1" '$1 == n { print $2, $3 }' layout; }
# rootfs: the stock U-Boot's bootipq needs a GPT partition of that name, or it
# stops at its prompt before loading 0:HLOS (docs/findings/0006)
for name in 0:HLOS 0:HLOS_1 ubootenv ubootenv2 rootfs fit_a fit_b data; do
	[ -n "$(part "$name")" ] || die "layout has no $name"
done
fits() { # file, partition name
	set -- "$1" $(part "$2")
	[ $(( ($(wc -c < "$1") + 511) / 512 )) -le "$3" ] || die "$1 does not fit its partition"
}
fits loader.itb 0:HLOS
fits loader.itb 0:HLOS_1
fits slot.itb fit_a

if [ "${2:-}" != "--yes" ]; then
	say "all checks passed; nothing written. Re-run with --yes to convert."
	exit 0
fi

# ---- writes -------------------------------------------------------------------
write_part() { # file, partition name
	set -- "$1" "$2" $(part "$2")
	dd_q if="$1" of="$disk" bs=512 seek="$3" conv=notrunc,fsync
	n=$(wc -c < "$1")
	[ "$(dd_q if="$disk" bs=512 skip="$3" count=$(( (n + 511) / 512 )) | head -c "$n" | sha256sum | cut -d' ' -f1)" = "$(sha "$1")" ] ||
		die "read-back of $2 does not match $1"
}
zero_part_head() { # partition name, sectors
	set -- "$1" "$2" $(part "$1")
	dd_q if=/dev/zero of="$disk" bs=512 seek="$3" count="$2" conv=notrunc,fsync
}
zero_after() { # file, partition name, sectors: clear what follows the file
	set -- "$1" "$2" "$3" $(part "$2")
	dd_q if=/dev/zero of="$disk" bs=512 seek=$(( $4 + ($(wc -c < "$1") + 511) / 512 )) count="$3" conv=notrunc,fsync
}

write_part loader.itb 0:HLOS;		checkpoint "U-Boot loader -> 0:HLOS"
write_part loader.itb 0:HLOS_1;		checkpoint "U-Boot loader -> 0:HLOS_1 (second copy)"
write_part slot.itb fit_a
zero_after slot.itb fit_a 2048;		checkpoint "OpenWrt -> fit_a, its overlay area cleared"
zero_part_head fit_b 2048;		checkpoint "fit_b cleared"
zero_part_head ubootenv 2048
zero_part_head ubootenv2 2048;		checkpoint "ubootenv, ubootenv2 cleared (U-Boot uses its defaults)"
zero_part_head data 2048;		checkpoint "data cleared"

dd_q if=gpt.backup.bin of="$disk" bs=512 seek=$((sectors - 33)) conv=notrunc,fsync
checkpoint "new backup GPT"
dd_q if=gpt.primary.bin of="$disk" bs=512 conv=notrunc,fsync
checkpoint "new primary GPT"

[ "$(dd_q if="$disk" bs=512 count=34 | sha256sum | cut -d' ' -f1)" = "$(sha gpt.primary.bin)" ] || die "primary GPT read-back mismatch"
[ "$(dd_q if="$disk" bs=512 skip=$((sectors - 33)) count=33 | sha256sum | cut -d' ' -f1)" = "$(sha gpt.backup.bin)" ] || die "backup GPT read-back mismatch"
sync
say "converted to layout v2; everything read back correctly."

# The stock U-Boot skips autoboot when boot_0 and boot_1 are both "bad" and
# loads 0:HLOS_1 when current_entry is 1 (finding 0004). Report, don't fix:
# the stock environment is only changed by hand, after its backup.
if [ -z "${QH_TEST:-}" ] && command -v fw_printenv >/dev/null; then
	b0=$(fw_printenv -n boot_0 2>/dev/null || echo unset)
	b1=$(fw_printenv -n boot_1 2>/dev/null || echo unset)
	ce=$(fw_printenv -n current_entry 2>/dev/null || echo unset)
	say "stock U-Boot env: boot_0=$b0 boot_1=$b1 current_entry=$ce"
	if [ "$b0" != good ] || [ "$b1" != good ] || [ "$ce" != 0 ]; then
		say "WARNING: a failed boot changed these. To boot 0:HLOS automatically again, run:"
		say "  fw_setenv boot_0 good; fw_setenv boot_1 good; fw_setenv current_entry 0"
	fi
fi
say "Reboot when ready."
