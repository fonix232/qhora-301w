---
name: device-safety
description: Preflight checklist and command risk classes for anything that touches the QNAP QHora-301W (serial console, U-Boot prompt, OpenWrt shell, flash reads/writes). Use before running or proposing any command on the device, and when writing scripts that will run on it.
---

# Device safety for the QHora-301W

The device has two flash chips with very different failure costs. Know which one a command touches before running it.

- **SPI-NOR (8 MiB, W25Q64DW, 1.8 V)** holds the Qualcomm boot chain, the stock U-Boot, its environment, the ART calibration/MAC data and the Aquantia firmware. A bad write to the boot chain is a brick that needs a 1.8 V SPI programmer (chip clip on a powered-down board) or JTAG.
- **eMMC (4 GB, Micron MTFC4GACAJCN-1M, 3.64 GiB usable)** holds the GPT and all firmware images. As long as the NOR is intact, the stock U-Boot always comes up on serial and can TFTP-boot a RAM image to repair the eMMC.

## Risk classes

| Class | Examples | Rule |
|---|---|---|
| R0 read-only | `cat /proc/mtd`, `dd if=/dev/mtdX`, `dd if=/dev/mmcblk0`, `gdisk -l`, `fw_printenv`, U-Boot `printenv`, `mmc part`, `sf read`, `md` | Always fine. Capture output into `backups/` or `logs/`. |
| R1 RAM-only | U-Boot `tftpboot` + `bootm` of an initramfs; booting our loader from RAM | Fine once serial is confirmed working. Nothing persists. |
| R2 eMMC user area | writing `/dev/mmcblk0p*`, rewriting the GPT, `sysupgrade` | Needs: serial console attached and interruptible, verified full eMMC backup, a tested restore path, user's explicit go-ahead. |
| R3 stock env | `fw_setenv`, U-Boot `setenv`+`saveenv` | Needs a backup of `0:appsblenv` (raw) and of `fw_printenv` output, a named variable list, user's go-ahead. Never erase the partition. Never touch QNAP inventory variables. |
| R4 NOR data, non-boot | `0:ethphyfw1`, `0:ethphyfw2` (Aquantia firmware) | Allowed with backup + go-ahead; resolve by name, assert size `0x80000`. |
| R5 NOR phase / APPSBL | stock APPSBL copy to `0x4B0000`–`0x5AFFFF` and the new table in the first 4 KiB of `0:mibib` (NOR phase); replacing `0:appsbl` (`0x270000`, `0x100000`) with our U-Boot (APPSBL phase) | Only in those phases of `docs/design.md`, after all their gates are met (for the MIBIB: SBL1's parser understood, byte-exact table tool, stock U-Boot compatibility, EDL or a proven 1.8 V programmer; for APPSBL: chainloaded U-Boot verified on the device, handoff format understood, programmer proven, `0:APPSBL_1` in place) and with the user's explicit approval for that specific write. Nothing outside the named range is touched; `0:APPSBLENV` and `0:ETHPHYFW` keep their names and ranges. |
| FORBIDDEN | any write/erase of `0:sbl1 0:qsee 0:devcfg 0:apdp 0:rpm 0:cdt 0:art`, and of `0:mibib` or `0:appsbl` outside R5; `sf erase/write/update` below `0x3B0000`; `kmod-mtd-rw`; eMMC `hwpartition complete`, RPMB keys, write-protect, `bootpart-resize`, any EXT_CSD write; writes to `mmcblk0boot0/1` or `mmcblk0rpmb` | Do not run. Do not propose. If a plan seems to need it, stop and escalate to the user. |

## Preflight checklist (R2 and above)

1. State the step's risk class and exactly which bytes it changes (device, offset, length).
2. Confirm the serial console is attached, logging to a file, and that `Hit any key to stop autoboot` was interrupted successfully in this session or a recent one.
3. Name the backup files this step relies on and print their sha256; confirm they are on the Mac, not only on the device.
4. Confirm the restore path for this exact step and whether it has been rehearsed (on a disk image or on the device).
5. Check the device's current state matches what the script expects (GPT names, LBAs, partition sizes, `fw_printenv` values). Any mismatch: stop.
6. Get the user's explicit yes for this step. A yes for one step does not carry over to the next.
7. After the write: read back and compare hashes before rebooting.

## Safe patterns

Resolve an MTD partition by name and check its size before reading or writing:

```sh
mtd_by_name() {  # usage: mtd_by_name 0:ethphyfw1 0x80000
	local line dev size
	line=$(grep "\"$1\"" /proc/mtd) || { echo "no partition $1" >&2; return 1; }
	dev=/dev/${line%%:*}
	size=0x$(echo "$line" | awk '{print $2}')
	[ $((size)) -eq $(($2)) ] || { echo "$1 size $size != $2" >&2; return 1; }
	echo "$dev"
}
```

Resolve an eMMC partition by GPT name, never by number:

```sh
part_by_name() { for p in /sys/class/block/mmcblk0p*; do [ "$(cat $p/uevent | sed -n 's/^PARTNAME=//p')" = "$1" ] && echo /dev/${p##*/}; done; }
```

## Known traps

- OpenWrt's `0:appsbl` MTD partition starts at the wrong offset (`0x250000`); a dump of it is not a U-Boot image. See `docs/findings/0001-appsbl-dts-offset.md`.
- `mtd erase 0:ethphyfw1` fails ("Could not open mtd device: 0") because the colon confuses `mtd`'s name parsing (forum #829); use the resolved `/dev/mtdN` from `mtd_by_name`.
- The stock firmware stores data in eMMC p9 `rootfs_data` and reads env from p8 `reserved`; back both up before any GPT change even if OpenWrt doesn't use them.
- The stock U-Boot always passes `root=PARTUUID=2a213133-47f8-80a1-5d66-1d565a2ec756` (p4 `rootfs`) regardless of which entry it boots (forum #56).

## Sysupgrade traps (from others' experience)

These come from devplayer0's `flash-openwrt` skill (github.com/devplayer0/nixfiles, `.claude/skills/flash-openwrt/SKILL.md`), restated here. They are general OpenWrt behaviour, **unverified on the 301w**.

- Start `sysupgrade` over SSH detached (`setsid sysupgrade ... </dev/null >/tmp/su.log 2>&1 &`). It kills SSH sessions mid-run, and an attached run can die with the session after the old firmware is already gone. Busybox has no `nohup`.
- Don't use `sysupgrade -c` from an initramfs: it needs `/overlay/upper/etc` and is reported to abort after erasing the firmware when that is missing.
- Detect the reboot by polling SSH with sleeps, not by pinging (pings succeed before the box actually goes down, so "wait for down" loops finish instantly).
- Verify after flashing: revision, management address, package list against the image manifest.
