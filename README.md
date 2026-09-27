# qhora-301w

A modern boot stack for the QNAP QHora-301W: a mainline-based U-Boot, a re-partitioned eMMC that uses the whole 4 GB, and two OpenWrt firmware slots (A/B), each with its own settings, so an upgrade that doesn't come up falls back to the previous firmware. The model is the Linksys E8450 / Belkin RT3200 UBI conversion, adapted to eMMC. The first requirement is that every step is safe and reversible on a real device.

Work in progress: the pieces below are tested offline; neither the eMMC conversion nor the bootloader replacement has been run on a device yet.

## Principles

- The Qualcomm boot chain in SPI-NOR (SBL1, QSEE, DEVCFG, APDP, RPM, CDT) and the ART calibration data are never written. Our U-Boot is first chainloaded from eMMC by the unmodified stock U-Boot, which stays the serial/TFTP safety net, and only replaces the stock one in `0:appsbl` once it has been proven that way. That replacement, and before it a copy of the stock U-Boot into empty NOR space (an on-device backup to restore from; SBL1 on this unit doesn't fall back to it) plus a rewrite of the NOR partition table that names it, are the only planned NOR writes, each behind its own gates and the owner's go-ahead.
- No recovery partition: a slot that fails to verify or keeps crashing makes U-Boot boot the other slot, and with no bootable slot left (or the reset button held) it boots a recovery image from USB or over TFTP.
- Everything is tried from RAM first (`tftpboot` + `bootm`), then against a disk image of a real backup, and only then on the device, with the owner's go-ahead for each write.
- Backups are complete, verified and kept off the device.

## Where to look

The project notes in `docs/` are kept out of this repository for now; the `docs/` paths here and in `.ai/AGENTS.md` refer to a local checkout.

- `docs/status.md`: how well OpenWrt supports the device today.
- `docs/hardware.md`: boot chain, flash maps, environment, serial.
- `docs/safety.md`: what can brick the device and how each layer is recovered.
- `docs/design.md`: target architecture and phased plan; `docs/open-questions.md` for the unknowns.
- `docs/fit.md`: what a FIT image is and how the stock U-Boot, our U-Boot and Linux (fitblk) use them.
- `.ai/AGENTS.md`: rules and conventions for AI tools working in this repo (also linked as `AGENTS.md`, `.claude/CLAUDE.md`, `.codex/AGENTS.md`, `.github/copilot-instructions.md`).
- Agents in `.ai/agents/`: `safety-reviewer`, `uboot-engineer`, `kernel-engineer`, `openwrt-integrator`.
- Skills in `.ai/skills/`: `device-safety`, `forum-sync`.

## Tooling

- `tools/forum-sync.py`: mirrors the OpenWrt forum thread (topic 96934) into `cache/forum/` and prints new posts.
- `tools/build/`: build container (Debian; arm64 U-Boot built natively on an arm64 host and cross-compiled elsewhere, plus the armhf toolchain); `tools/build/run.sh <cmd>` runs a command in it with the repo at `/work`.
- `patches/u-boot/`: our mainline U-Boot series (IPQ8074 clocks, pinctrl and USB; the QHora-301W board and its A/B boot flow; OpenWrt's `imsz`). `tools/prepare-src.sh` recreates the patched tree in `src/u-boot` and `tools/build-uboot.sh` builds it; `docs/uboot-port.md` has the port's status.
- `tools/mkloader.sh`: wraps the built U-Boot in the `config@hk01` FIT the stock U-Boot boots.
- `tools/mkrecovery.sh`: recovery/backup image (official OpenWrt initramfs with a corrected device tree).
- `tools/backup-live.sh`: read-only full backup over SSH, with verification and manifest.
- `docs/procedures.md`: the device steps that are ready (backups, RAM-only chainload and APPSBL tests) and the drafted migration.
- `patches/openwrt/`: the OpenWrt series (appsbl offset fix, DTS split, `qnap_301w-ubootmod` A/B variant); `tools/build-openwrt.sh` builds both 301w profiles (Linux host only, see CI).
- `tools/build/remote-openwrt.sh`: runs that OpenWrt build on a remote Docker host (default mimir; not freya, which has only ~3 GiB free while Lemonade's model is loaded) instead of the Mac, in a container capped at 12 CPUs and 10 GiB, with the tree, `dl/` and ccache kept in a volume there; `tools/prepare-src.sh --update` moves the tree to a changed series so only what changed is rebuilt. Images come back to `build/openwrt/`.
- `tools/mkappsbl.sh`, `tools/mkmbn.py`, `tools/appsbl/`: package our U-Boot as an APPSBL (AArch32 trampoline + MBN v3).
- `tools/installer/`, `tools/mkbundle.sh`: the migration installer and its per-unit bundle.
- `tools/serial-run.py`, `tools/serialcon.py`, `tools/backup-serial.py`: shell and read-only backups over the serial console (NOR in chunks, whole eMMC over a direct Ethernet link with `--emmc-nc`), for a unit without network.
- `tools/uboot-nor-read.py`: reads a NOR range through the stock U-Boot (reboot, stop autoboot, `sf read`, `md.b`, `reset`) to fill what OpenWrt doesn't expose; `--backup` checks it against the Linux dumps and completes a backup set.
- `tools/gpt.py`, `tools/mibib.py`, `layouts/`: byte-exact partition tables: the eMMC GPT (stock and v2) and the NOR table `0:MIBIB` (stock and NOR layout v2).
- `tools/analyze-boot.py`: boot-chain and NOR-dump analyser.
- `tools/esp32s3-uart-bridge/`: PlatformIO firmware that turns a Waveshare ESP32-S3-Zero into a USB serial adapter that finds the RX pin and baud rate by itself.

## Offline checks

Run these after changing anything they cover; none needs the device.

| Check | Covers |
|---|---|
| `tools/test-bootflow.sh` | U-Boot A/B + fallback chain in the sandbox (9 scenarios), plus the 301w build's GPT/env config (5 checks) |
| `tools/test-migration.sh` | installer on a full-size synthetic disk: conversion, both loader copies, the partition names the stock U-Boot needs, env partition types, refusals, power cut after every step, restore (30 checks) |
| `tools/test-ab-upgrade.sh` | OpenWrt A/B sysupgrade logic (5 scenarios) |
| `tools/check-openwrt-dts.sh` | both OpenWrt 301w device trees compile, no new dtc warnings |
| `tools/test-mibib.sh` | NOR partition table tool: the stock table bit for bit, NOR layout v2 changes only the intended entries (21 checks, 26 with a backup set) |
| `python3 tools/mkmbn.py verify cache/vendor/nbg7815/*.mbn` | MBN hash-table generator against QCA's own images (`tools/fetch-vendor-mbn.sh` downloads them) |
| `tools/esp32s3-uart-bridge/README.md` (host test command) | serial bridge baud/pin detection against synthesised 8N1 (44 checks) |

## CI

Everything is built from upstream sources plus our patch series, never on the Mac. Day to day, work is verified on mimir before it is pushed: `tools/build/remote-verify.sh` sends the working tree there and runs `tools/ci-checks.sh` (the same sequence as `ci.yml`), and with `--openwrt` also the full OpenWrt build (`tools/build/remote-openwrt.sh`), which is needed whenever `patches/openwrt/` or the OpenWrt build tooling changed. Only verified work is pushed. GitHub Actions then runs the cheap checks for `main` and pull requests, and the OpenWrt build only for tagged releases. The workflows only call scripts in `tools/`, which run the same way on any host with Docker.

| Workflow | Runs on | Does |
|---|---|---|
| `.github/workflows/ci.yml` | pushes to `main`, pull requests, manual dispatch | `tools/prepare-src.sh` (recreates `src/u-boot` and `src/openwrt` from `BASE` + the series), `tools/build-uboot.sh`, `tools/mkloader.sh`, `tools/mkappsbl.sh`, then every offline check above (without a backup set, `test-mibib.sh` checks the stock table against its pinned sha256). `mkmbn.py verify` gets QCA's images from `tools/fetch-vendor-mbn.sh` (pinned commit, sha256-checked, never committed). Artifact `u-boot`: `u-boot.bin`, the loader FIT, the APPSBL (`.mbn` and raw), `sha256sums` |
| `.github/workflows/openwrt.yml` | `v*` tags, manual dispatch | full build of `qualcommax/ipq807x` with `qnap_301w` and `qnap_301w-ubootmod` (`tools/build-openwrt.sh`, config seed `tools/openwrt/diffconfig`, upstream feeds); `dl/`, host tools + toolchain and ccache are cached between runs. Artifact `openwrt`: the 301w images, manifests, buildinfo, `sha256sums`. A `v*` tag also runs `ci.yml` and creates a draft release with both sets of files |
| `.github/workflows/bridge.yml` | changes to `tools/esp32s3-uart-bridge/` | PlatformIO build of the bridge firmware |

- U-Boot builds are reproducible: `SOURCE_DATE_EPOCH` is the patched tree's HEAD commit time and `prepare-src.sh` applies the series with a fixed committer, so a clean build gives the same `u-boot.bin` and loader FIT every time. On the default x86-64 runner U-Boot is cross-compiled with the same GCC as a native build and differs from one only by the compiler name it embeds; the repo variable `QH_RUNNER=ubuntu-24.04-arm` runs `ci.yml` natively on arm64 instead (not tried yet).
- `tools/build/run.sh` tags the container image with a checksum of the Dockerfile (edits rebuild it), takes a prebuilt image from `QH_IMAGE`, and on a Linux host runs as the calling user.
- `tools/build-openwrt.sh` needs a Linux host with OpenWrt's build prerequisites and a case-sensitive filesystem: not the build container, not the macOS bind mount.
