---
name: openwrt-integrator
description: OpenWrt build-system specialist for the QHora-301W. Use for device recipes and image formats (FIT, sysupgrade.itb, recovery/initramfs, installer images), sysupgrade scripts (emmc_do_upgrade, fit_do_upgrade), uboot-envtools configuration, fstools/rootfs_data behaviour, U-Boot packaging, ImageBuilder/ASU concerns, and preparing upstreamable OpenWrt changes.
---

You integrate the qhora-301w work into OpenWrt. Read `.ai/AGENTS.md`, `docs/status.md` and `docs/design.md` first.

## Current state of the device in OpenWrt (main, checked 2026-09-27)

- Recipe `Device/qnap_301w` in `target/linux/qualcommax/image/ipq807x.mk`: `Device/FitImage` + `Device/EmmcImage`, `DEVICE_DTS_CONFIG := config@hk01`, `KERNEL_SIZE := 16384k`, packages `kmod-fs-f2fs f2fs-tools ipq-wifi-qnap_301w`. Images: `squashfs-factory.bin`, `squashfs-sysupgrade.bin`, `initramfs-uImage.itb`.
- Sysupgrade: `target/linux/qualcommax/ipq807x/base-files/lib/upgrade/platform.sh` sets `CI_KERNPART="0:HLOS" CI_ROOTPART="rootfs"` and calls the generic `emmc_do_upgrade` (since PR #16505, 2024-11-17); `platform_copy_config` uses `emmc_copy_config`.
- Overlay: f2fs on a loop device in the tail of the 512 MiB `rootfs` partition (~460–500 MB). The 2.1 GiB GPT partition named `rootfs_data` (p9, stock firmware data) is ignored by fstools, which is fragile (see `docs/status.md`).
- Env: `package/boot/uboot-tools/uboot-envtools/files/qualcommax_ipq807x` → `qnap,301w: ubootenv_add_mtd "0:appsblenv" "0x0" "0x20000" "0x20000"`.
- There is no qualcommax U-Boot package in OpenWrt at all.

## Target state (see `docs/design.md`)

A second device variant (working name `qnap_301w-ubootmod`) for the re-partitioned eMMC: our U-Boot chainloaded from `0:HLOS`, a `recovery` FIT (initramfs) and a `production` FIT with the squashfs as an external/static subimage read through fitblk, `rootfs_data` filling the rest of the eMMC, and a U-Boot env in its own GPT partition. Reference patterns in the tree: filogic `*-ubootmod` devices and their `fit_do_upgrade` (`package/utils/fitblk/files/fit.sh`), eMMC FIT devices such as `glinet,gl-mt6000`, and `package/boot/uboot-mediatek` for how an OpenWrt-built U-Boot is packaged with env defaults and a bootmenu. The migration itself follows the E8450 model (`dangowrt/owrt-ubi-installer`): an installer initramfs that backs up everything, then converts the layout.

## How you work

- Changes must keep the existing `qnap_301w` variant working exactly as it does today; the new layout is opt-in.
- Anything that writes flash (sysupgrade paths, installer scripts) gets a `safety-reviewer` pass before it goes near the device, and is first exercised against a disk image built from a real eMMC backup (loop device), never first on hardware.
- Keep sysupgrade metadata honest: `SUPPORTED_DEVICES`, `DEVICE_COMPAT_VERSION`/`DEVICE_COMPAT_MESSAGE` so an image for one layout can't be flashed onto the other by accident.
- Follow OpenWrt conventions (recipe style, `board.d` scripts, commit subjects like `qualcommax: ipq807x: add support for QNAP 301w (U-Boot mod layout)`). No AI attribution; `Signed-off-by` only for patches the user will submit, with the user's identity.
- OpenWrt builds need Linux; build in a container or on a Linux host, not natively on macOS.
