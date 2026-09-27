# qhora-301w — agent instructions

This repo is the working area for giving the **QNAP QHora-301W** (Qualcomm IPQ8072A, 8 MiB SPI-NOR + 4 GB eMMC) a modern boot stack: a new U-Boot, a re-partitioned eMMC that uses the whole flash, and two OpenWrt firmware slots (A/B), each with its own settings, in the spirit of what the Linksys E8450 / Belkin RT3200 got with its UBI layout. The overriding requirement is that the whole process is **100% safe and reversible** on a real device.

This file is the single source of truth for every AI tool. It is symlinked as `AGENTS.md`, `.claude/CLAUDE.md`, `.codex/AGENTS.md` and `.github/copilot-instructions.md`. Edit only `.ai/AGENTS.md`.

## Hard safety rules (never break these)

These exist because a wrong write on this device can need a 1.8 V SPI programmer or JTAG to recover. Read `docs/safety.md` for the reasoning; the `device-safety` skill has the preflight checklist.

1. **The SPI-NOR boot chain is read-only.** Never write, erase or unlock `0:sbl1`, `0:mibib`, `0:qsee`, `0:devcfg`, `0:apdp`, `0:rpm`, `0:cdt`, `0:appsbl` or `0:art` (NOR offsets `0x000000`–`0x3AFFFF`). No `mtd write/erase`, `flashcp`, `dd of=/dev/mtd*`, `sf erase/write/update` in U-Boot, `kmod-mtd-rw`/`i_want_a_brick`, or DTS changes that drop `read-only` from these partitions. There are exactly two planned exceptions, both in `docs/design.md`: the **NOR phase** (a stock APPSBL copy written to the empty `0x4B0000`–`0x5AFFFF`, then a rewrite of the first 4 KiB of `0:mibib` with the new table, "NOR layout v2") and the **APPSBL phase** (replacing `0:appsbl` with our U-Boot). Each may only start after every gate listed there is met and the user has explicitly approved that specific write. `0:APPSBLENV` and `0:ETHPHYFW` keep their exact names and ranges in any new table. Until the APPSBL phase the new U-Boot runs chainloaded from the stock one.
2. **Never run irreversible eMMC commands.** No `mmc hwpartition ... complete`, no RPMB key programming, no `mmc wp`/`mmc writeprotect` (power-on or permanent), no `mmc bootpart-resize`, no EXT_CSD writes of any kind (`mmc-utils` `enh_area`, `write_reliability`, `bootpart enable`, `bootbus`). Don't touch `mmcblk0boot0/1` or `mmcblk0rpmb`.
3. **The stock U-Boot environment (`0:appsblenv`) is never erased or rewritten wholesale.** At most individual `fw_setenv`/`setenv` calls on named variables, after a verified backup, with the user's go-ahead. The QNAP inventory variables (`BMAC QSN PN MN NMAC SSID MD HV PLN MF CC MCC VN FWMode`) are never modified.
4. **Nothing is written to the live device without the user's explicit go-ahead for that specific step.** The unit may be someone's production router: no reboots, power cycles, `sysupgrade`, `fw_setenv` or partition changes without a yes first. Reading is fine.
5. **Backups first, verified, kept off-device.** Every write step names the backup it depends on and that backup's sha256. Backups contain device-unique data (MACs, serial number, Wi-Fi calibration): they live under `backups/` (gitignored) and are never committed or uploaded anywhere.
6. **Address MTD partitions by name, never by `mtdN` number.** A typo (`mtd1` for `mtd10`) erased someone's MIBIB (forum post #805). Resolve names from `/proc/mtd` in scripts and assert the size before acting.
7. **Don't trust OpenWrt's `0:appsbl` MTD partition.** Its `reg` starts at `0x250000` instead of `0x270000` (see `docs/findings/0001-appsbl-dts-offset.md`), so it contains the env plus 896 KiB of U-Boot, and NOR `0x350000`–`0x36FFFF` is not exposed at all. Full NOR backups need our own read-only initramfs or U-Boot `sf read`.
8. **On-device writes only through scripts in this repo** that check the current state first, refuse on any unexpected layout, and have been reviewed by the `safety-reviewer` agent. No ad-hoc write one-liners on the device.

## Working conventions

- Every hardware or behavioural claim in `docs/` cites its source (forum post number, commit hash, file path, or our own captured log). Mark anything unverified as **unverified**.
- Markdown prose is one line per paragraph or list item; no hard wrapping. Code blocks keep their own line breaks.
- Commits: conventional commits (`type(scope): subject`), plain messages, **no AI attribution or `Co-Authored-By` trailers**. Stage explicit paths only.
- Research write-ups (`docs/**`, findings, reports) stay **untracked until the user explicitly says to commit them**. Tooling, scripts and scaffolding can be committed.
- Nothing outward-facing (forum posts, upstream PRs/issues, pushes) without the user's say-so. Draft them in `docs/` instead.
- Raw downloads and upstream source trees go in `cache/` (gitignored). `tools/forum-sync.py` keeps the OpenWrt forum thread mirrored there.

## Repo layout

```
.ai/AGENTS.md        this file (canonical)
.ai/skills/          skills (symlinked into .claude/, .codex/, .github/)
.ai/agents/          agent definitions (symlinked into .claude/agents, .github/agents)
docs/status.md       current OpenWrt support level (forum + source)
docs/hardware.md     device facts: boot chain, NOR map, eMMC GPT, env, serial
docs/safety.md       safety model: what can brick, how each layer recovers
docs/design.md       target architecture and phased plan
docs/fit.md          FIT images: format, U-Boot/fitblk use, the FITs in this project
docs/uboot-port.md   mainline U-Boot port: build, patches, subsystem status
docs/procedures.md   step-by-step device procedures that are ready
docs/open-questions.md  unknowns that block or shape the design
docs/findings/       discrete findings (bugs, verified behaviours)
docs/journal.md      dated research log
docs/sources.md      references
tools/               scripts: forum mirror, build container, loader/recovery images, backup
patches/u-boot/      our mainline U-Boot patch series (base commit in BASE)
src/                 gitignored working trees of patched upstreams (src/u-boot)
build/               gitignored build outputs
cache/               gitignored: forum mirror, upstream clones, vendor GPL drops
backups/             gitignored: device dumps (never commit)
```

## Agents and skills

- `safety-reviewer`: reviews any procedure, script or command sequence that touches the device before it runs. Mandatory for rule 8.
- `uboot-engineer`: mainline U-Boot (mach-snapdragon, DM drivers, FIT, bootmenu, env) and the QCA U-Boot 2016 fork; chainloading on IPQ807x.
- `kernel-engineer`: Linux/OpenWrt `qualcommax` kernel work: DTS, drivers, patch hygiene, fitblk.
- `openwrt-integrator`: OpenWrt build system, image recipes, sysupgrade, uboot-envtools, installer and recovery images.
- Skill `device-safety`: preflight checklist and command risk classes for anything on the device.
- Skill `forum-sync`: refresh the forum mirror and fold new posts into `docs/status.md`.

Codex has no agent directory; when a task matches one of the agents above, read its file in `.ai/agents/` and follow it as a role prompt.

## Offline checks

After changing U-Boot, the installer, the layout, the OpenWrt patches or the image tooling, re-run the matching check before committing; the table in `README.md` lists them (`tools/test-bootflow.sh`, `tools/test-migration.sh`, `tools/test-ab-upgrade.sh`, `tools/check-openwrt-dts.sh`). Build everything through `tools/build/run.sh` (Docker/OrbStack); large disk images go on the `qhora-scratch` volume (`QH_VOLUME`), never on the macOS bind mount.

## Useful facts at a glance

- Board compatible `qnap,301w`; OpenWrt device `qnap_301w` in `qualcommax/ipq807x`; DTS `target/linux/qualcommax/dts/ipq8072-301w.dts`.
- Stock bootloader: QCA U-Boot 2016.01 (built Aug 18 2020), AArch32, `bootcmd=bootipq`, `bootdelay=2`, serial 115200 8N1 3.3 V. It loads a FIT (`config@hk01`) from GPT partition `0:HLOS` (entry 0) and starts the kernel at EL1 through the TrustZone monitor. If that load fails it marks `boot_0=bad`, switches to `0:HLOS_1`, saves its env and resets by itself; with `boot_0` and `boot_1` both bad it skips autoboot (`docs/findings/0004`). It honours no keypress at `bootdelay=0`, so `bootdelay` must never be lowered.
- The stock U-Boot power-on write-protects any GPT partition with attribute bit 60 at every boot; `tools/gpt.py` refuses that bit.
- Secure boot fuse is **not** blown (`is_sec_boot_enabled` → "secure boot fuse is not enabled", forum #24).
- NOR part is a Winbond W25Q64DW: a **1.8 V** chip. A 3.3 V programmer will damage it.
