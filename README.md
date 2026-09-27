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
- `.ai/AGENTS.md`: rules and conventions for AI tools working in this repo (also linked as `AGENTS.md`, `.claude/CLAUDE.md`, `.codex/AGENTS.md`, `.github/copilot-instructions.md`).

## Tooling

- `tools/forum-sync.py`: mirrors the OpenWrt forum thread (topic 96934) into `cache/forum/` and prints new posts.
- Agents in `.ai/agents/`: `safety-reviewer`, `uboot-engineer`, `kernel-engineer`, `openwrt-integrator`.
- Skills in `.ai/skills/`: `device-safety`, `forum-sync`.
