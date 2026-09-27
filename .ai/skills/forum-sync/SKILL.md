---
name: forum-sync
description: Refresh the local mirror of the OpenWrt forum thread "Adding OpenWrt support for QNAP QHora-301W" (topic 96934) and fold anything new into docs/status.md. Use when asked about the device's current community status or before revising the status or design docs.
---

# Forum sync

The thread is the main record of the device's OpenWrt history (946+ posts since 2021-05). `tools/forum-sync.py` mirrors it through Discourse's public JSON API into `cache/forum/`:

- `posts.json`: raw posts (incremental; only new post IDs are fetched).
- `thread.txt`: plain-text rendering, one `===== #N user date` header per post, quotes collapsed to `[quote]`.
- `state.json`: highest post number seen at the last sync.

## Steps

1. Run `python3 tools/forum-sync.py` from the repo root. It prints the posts that are new since the previous run.
2. Read the new posts. For each one that changes what we know (support status, regressions, bootloader or flash-layout facts, recovery methods), update `docs/status.md` or `docs/hardware.md` with a one-line entry citing `#<post number>`.
3. Follow links that matter (GitHub PRs/issues, commits) with `gh` and record their state (open/merged, dates).
4. Add a dated line to `docs/journal.md` saying what was synced and what changed.

`python3 tools/forum-sync.py --show 476,511-513` prints specific posts from the mirror; `--grep <regex>` searches it.

Don't post to the forum. Draft replies in `docs/` and hand them to the user.
