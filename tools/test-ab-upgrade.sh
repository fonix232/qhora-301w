#!/bin/sh
# Test the A/B sysupgrade logic (qnap_301w_ab_upgrade in the OpenWrt series)
# with the real platform.sh and mocked device helpers: which slot is written,
# that settings go into rootfs_data before the switch, that boot_slot only
# changes after a successful write, and that failures leave it alone.
#
# usage: tools/test-ab-upgrade.sh     (runs in the build container, dash)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
exec "$root/tools/build/run.sh" sh -c '
PLATFORM=/work/src/openwrt/target/linux/qualcommax/ipq807x/base-files/lib/upgrade/platform.sh
T=$(mktemp -d)
pass=0; fail=0

scenario() { # name, initial boot_slot, write_ok(1/0), keep_settings(1/0), expected checks...
	name=$1; slot=$2; write_ok=$3; keep=$4; shift 4
	rm -rf $T/*; : > $T/log
	[ -n "$slot" ] && echo "boot_slot=$slot" > $T/env || : > $T/env
	(
		. $PLATFORM
		board_name() { echo qnap,301w-ubootmod; }
		fw_printenv() { [ "$1" = -n ] && sed -n "s/^$2=//p" $T/env; }
		fw_setenv() { # only -s - is used
			while read -r k v; do
				[ -n "$k" ] || continue
				grep -v "^$k=" $T/env > $T/env.new || true; echo "$k=$v" >> $T/env.new; mv $T/env.new $T/env
			done
			echo "setenv $(tr "\n" " " < $T/env)" >> $T/log
		}
		find_mmc_part() { echo "/dev/fake-$1"; }
		emmc_do_upgrade() {
			echo "write $EMMC_KERN_DEV" >> $T/log
			[ "$WRITE_OK" = 1 ] && export EMMC_KERNEL_BLOCKS=1234 || export EMMC_KERNEL_BLOCKS=
		}
		emmc_copy_config() { echo "copy config after the FIT in $EMMC_KERN_DEV, EMMC_DATA_DEV=${EMMC_DATA_DEV:-unset}" >> $T/log; }
		dd() { echo "dd $*" >> $T/log; }
		sync() { :; }
		[ "$KEEP" = 1 ] && export UPGRADE_BACKUP=/tmp/sysupgrade.tgz || unset UPGRADE_BACKUP
		export EMMC_DATA_DEV=/dev/stale-from-elsewhere
		platform_do_upgrade /tmp/image.itb > $T/out 2>&1
		echo "rc=$?" >> $T/log
	) || true
	ok=1
	for check in "$@"; do
		case $check in
		!*) grep -q -- "${check#!}" $T/log && ok=0 ;;
		*)  grep -q -- "$check" $T/log || ok=0 ;;
		esac
	done
	# the switch must be the last thing written
	if grep -q "^setenv" $T/log && [ "$(grep -v ^rc= $T/log | tail -1 | cut -c1-6)" != "setenv" ]; then ok=0; fi
	if [ $ok = 1 ]; then pass=$((pass+1)); echo "PASS  $name"; else fail=$((fail+1)); echo "FAIL  $name"; sed "s/^/      /" $T/log $T/out; fi
}

export WRITE_OK KEEP
WRITE_OK=1 KEEP=1 scenario "a running, keep settings -> write b"  a 1 1 "write /dev/fake-fit_b" "copy config after the FIT in /dev/fake-fit_b, EMMC_DATA_DEV=unset" "boot_slot=b" "upgrade_available=1" "bootcount=0" "rc=0"
WRITE_OK=1 KEEP=0 scenario "b running, no settings -> write a"    b 1 0 "write /dev/fake-fit_a" "boot_slot=a" "!copy config" "!stale-from-elsewhere" "rc=0"
WRITE_OK=0 KEEP=1 scenario "write fails -> no switch"             a 0 1 "write /dev/fake-fit_b" "!setenv" "!copy config" "!rc=0"
WRITE_OK=1 KEEP=1 scenario "boot_slot unset -> refuse"            "" 1 1 "!write" "!setenv" "!rc=0"
WRITE_OK=1 KEEP=1 scenario "boot_slot garbage -> refuse"          x 1 1 "!write" "!setenv" "!rc=0"
echo "$pass passed, $fail failed"
[ $fail = 0 ]
'
