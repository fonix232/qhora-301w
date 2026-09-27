# qhora-301w

A modern boot stack for the QNAP QHora-301W: a new U-Boot, a re-partitioned eMMC that uses the whole 4 GB, and an OpenWrt recovery/production split, in the spirit of the Linksys E8450 / Belkin RT3200 UBI conversion. The first requirement is that every step is safe and reversible on a real device.

## Principles

- The SPI-NOR boot chain (Qualcomm SBL/TZ/RPM, the stock U-Boot, ART calibration) is never written. The new U-Boot is chainloaded from eMMC by the unmodified stock U-Boot, which stays as the always-present serial/TFTP safety net.
- Everything is tried from RAM first (`tftpboot` + `bootm`), then against a disk image of a real backup, and only then on the device, with the owner's go-ahead for each write.
- Backups are complete, verified and kept off the device.

## Where to look

- `docs/status.md`: how well OpenWrt supports the device today.
- `docs/hardware.md`: boot chain, flash maps, environment, serial.
- `docs/safety.md`: what can brick the device and how each layer is recovered.
- `docs/design.md`: target architecture and phased plan; `docs/open-questions.md` for the unknowns.
- `docs/fit.md`: what a FIT image is and how the stock U-Boot, our U-Boot and Linux (fitblk) use them.
- `.ai/AGENTS.md`: rules and conventions for AI tools working in this repo (also linked as `AGENTS.md`, `.claude/CLAUDE.md`, `.codex/AGENTS.md`, `.github/copilot-instructions.md`).

## Tooling

- `tools/forum-sync.py`: mirrors the OpenWrt forum thread (topic 96934) into `cache/forum/` and prints new posts.
- `tools/build/`: build container (Debian, native arm64 + armhf toolchains); `tools/build/run.sh <cmd>` runs a command in it with the repo at `/work`.
- `patches/u-boot/`: our mainline U-Boot series (IPQ8074 clock + pinctrl, QHora-301W board); `docs/uboot-port.md` has build steps and status.
- `tools/mkloader.sh`: wraps the built U-Boot in the `config@hk01` FIT the stock U-Boot boots.
- `tools/mkrecovery.sh`: recovery/backup image (official OpenWrt initramfs with a corrected device tree).
- `tools/backup-live.sh`: read-only full backup over SSH, with verification and manifest.
- `docs/procedures.md`: the device steps that are ready (backups, RAM-only chainload and APPSBL tests) and the drafted migration.
- `patches/openwrt/`: the OpenWrt series (appsbl offset fix, DTS split, `qnap_301w-ubootmod` A/B variant).
- `tools/mkappsbl.sh`, `tools/mkmbn.py`, `tools/appsbl/`: package our U-Boot as an APPSBL (AArch32 trampoline + MBN v3).
- `tools/installer/`, `tools/mkbundle.sh`: the migration installer and its per-unit bundle.
- `tools/serial-run.py`, `tools/serialcon.py`, `tools/backup-serial.py`: shell and read-only backups over the serial console (NOR in chunks, whole eMMC over a direct Ethernet link with `--emmc-nc`), for a unit without network.
- `tools/uboot-nor-read.py`: reads a NOR range through the stock U-Boot (reboot, stop autoboot, `sf read`, `md.b`, `reset`) to fill what OpenWrt doesn't expose; `--backup` checks it against the Linux dumps and completes a backup set.
- `tools/gpt.py`, `layouts/`: byte-exact GPT tables for the stock and v2 layouts.
- `tools/analyze-boot.py`: boot-chain and NOR-dump analyser.
- `tools/esp32s3-uart-bridge/`: PlatformIO firmware that turns a Waveshare ESP32-S3-Zero into a USB serial adapter that finds the RX pin and baud rate by itself.

## Offline checks

Run these after changing anything they cover; none needs the device.

| Check | Covers |
|---|---|
| `tools/test-bootflow.sh` | U-Boot A/B + fallback chain in the sandbox (9 scenarios), plus the 301w build's GPT/env config (5 checks) |
| `tools/test-migration.sh` | installer on a full-size synthetic disk: conversion, both loader copies, env partition types, refusals, power cut after every step, restore (29 checks) |
| `tools/test-ab-upgrade.sh` | OpenWrt A/B sysupgrade logic (5 scenarios) |
| `tools/check-openwrt-dts.sh` | both OpenWrt 301w device trees compile, no new dtc warnings |
| `python3 tools/mkmbn.py verify cache/vendor/nbg7815/*.mbn` | MBN hash-table generator against QCA's own images |
| `tools/esp32s3-uart-bridge/README.md` (host test command) | serial bridge baud/pin detection against synthesised 8N1 (44 checks) |
- Agents in `.ai/agents/`: `safety-reviewer`, `uboot-engineer`, `kernel-engineer`, `openwrt-integrator`.
- Skills in `.ai/skills/`: `device-safety`, `forum-sync`.
