#!/bin/sh
# Fallback level 1 (docs/design.md): make the stock U-Boot TFTP-boot the
# recovery image when bootipq can't boot 0:HLOS, so an eMMC mishap is
# recoverable without the serial console.
#
#   qhora-stock-fallback.sh [--yes]          add the fallback
#   qhora-stock-fallback.sh --remove [--yes] restore the saved bootcmd
#
# Only these stock env variables are touched: bootcmd, qh_fallback,
# qh_bootcmd_orig. The QNAP inventory variables are never written. Keep a
# backup of 0:appsblenv (tools/backup-live.sh) before using --yes.
set -eu

bootfile=openwrt-qualcommax-ipq807x-qnap_301w-ubootmod-initramfs-recovery.itb
fallback="echo qh: stock boot failed, TFTP rescue; setenv ipaddr 192.168.1.1; setenv serverip 192.168.1.254; tftpboot 0x44000000 $bootfile && bootm 0x44000000#config@hk01"

die() { echo "qhora-stock-fallback: ERROR: $*" >&2; exit 1; }
remove=; yes=
for a in "$@"; do
	case "$a" in
	--remove) remove=1 ;;
	--yes) yes=1 ;;
	*) die "unknown argument $a" ;;
	esac
done

[ -z "${QH_TEST:-}" ] && { [ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = "qnap,301w" ] || die "not a QNAP 301w on the stock layout"; }
grep -q '0:appsblenv' /etc/fw_env.config 2>/dev/null || [ -n "${QH_TEST:-}" ] ||
	die "fw_env.config doesn't point at the stock env (0:appsblenv)"

cur=$(fw_printenv -n bootcmd 2>/dev/null) || die "cannot read bootcmd"
orig=$(fw_printenv -n qh_bootcmd_orig 2>/dev/null || true)

if [ -n "$remove" ]; then
	[ -n "$orig" ] || die "no saved bootcmd (qh_bootcmd_orig); nothing to remove"
	echo "bootcmd now:      $cur"
	echo "bootcmd restored: $orig"
	[ -n "$yes" ] || { echo "dry run; add --yes to write"; exit 0; }
	printf 'bootcmd %s\nqh_fallback\nqh_bootcmd_orig\n' "$orig" | fw_setenv -s -
	echo "done"
	exit 0
fi

case "$cur" in
*"run qh_fallback"*) echo "fallback already set: $cur"; exit 0 ;;
*bootipq) ;;
*) die "bootcmd is '$cur'; expected it to end with bootipq, not touching it" ;;
esac

new="$cur; run qh_fallback"
echo "bootcmd now:  $cur"
echo "bootcmd new:  $new"
echo "qh_fallback:  $fallback"
[ -n "$yes" ] || { echo "dry run; add --yes to write"; exit 0; }
printf 'qh_bootcmd_orig %s\nqh_fallback %s\nbootcmd %s\n' "$cur" "$fallback" "$new" | fw_setenv -s -
[ "$(fw_printenv -n bootcmd)" = "$new" ] || die "read-back of bootcmd differs"
echo "done"
