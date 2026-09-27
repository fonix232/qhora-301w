#!/usr/bin/env python3
"""Mirror an OpenWrt forum (Discourse) thread into cache/forum/.

Default topic is 96934, "Adding OpenWrt support for QNAP QHora-301W".
Only post IDs not already in posts.json are fetched; new posts are printed.

  tools/forum-sync.py                 sync and print new posts
  tools/forum-sync.py --show 476,511-513
  tools/forum-sync.py --grep 'u-?boot|appsbl'
"""
import argparse
import html
import json
import re
import sys
import time
import urllib.request
from pathlib import Path

BASE = "https://forum.openwrt.org"
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "cache" / "forum"


def get(url):
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "qhora-301w-forum-sync"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except Exception as e:  # rate limits and transient errors
            wait = 5 * (attempt + 1)
            print(f"retry in {wait}s: {e}", file=sys.stderr)
            time.sleep(wait)
    raise SystemExit(f"giving up on {url}")


def to_text(cooked):
    c = re.sub(r"<aside class=\"quote.*?</aside>", "[quote]", cooked, flags=re.S)
    c = re.sub(r"<pre><code[^>]*>", "\n```\n", c).replace("</code></pre>", "\n```\n")
    c = re.sub(r"<br\s*/?>", "\n", c)
    c = re.sub(r"</p>", "\n", c)
    c = re.sub(r"<a [^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", r"\2 <\1>", c, flags=re.S)
    c = re.sub(r"<[^>]+>", "", c)
    return html.unescape(c).strip()


def render(p):
    return f"===== #{p['post_number']} {p['username']} {p['created_at'][:10]}\n{to_text(p['cooked'])}\n"


def load_posts(path):
    return {p["id"]: p for p in json.loads(path.read_text())} if path.exists() else {}


def parse_ranges(spec):
    nums = set()
    for part in spec.split(","):
        a, _, b = part.partition("-")
        nums.update(range(int(a), int(b or a) + 1))
    return nums


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--topic", type=int, default=96934)
    ap.add_argument("--show", help="print posts by number, e.g. 476,511-513")
    ap.add_argument("--grep", help="print posts matching a regex (case-insensitive)")
    args = ap.parse_args()

    out = OUT if args.topic == 96934 else OUT / str(args.topic)
    out.mkdir(parents=True, exist_ok=True)
    posts_path, state_path = out / "posts.json", out / "state.json"
    posts = load_posts(posts_path)

    if args.show or args.grep:
        ordered = sorted(posts.values(), key=lambda p: p["post_number"])
        if args.show:
            wanted = parse_ranges(args.show)
            ordered = [p for p in ordered if p["post_number"] in wanted]
        if args.grep:
            rx = re.compile(args.grep, re.I)
            ordered = [p for p in ordered if rx.search(to_text(p["cooked"]))]
        print("\n".join(render(p) for p in ordered))
        return

    topic = get(f"{BASE}/t/{args.topic}.json")
    missing = [i for i in topic["post_stream"]["stream"] if i not in posts]
    for i in range(0, len(missing), 20):
        q = "&".join(f"post_ids[]={pid}" for pid in missing[i:i + 20])
        for p in get(f"{BASE}/t/{args.topic}/posts.json?{q}")["post_stream"]["posts"]:
            posts[p["id"]] = p
        time.sleep(1)

    ordered = sorted(posts.values(), key=lambda p: p["post_number"])
    posts_path.write_text(json.dumps(ordered))
    (out / "thread.txt").write_text("\n".join(render(p) for p in ordered))

    state = json.loads(state_path.read_text()) if state_path.exists() else {"last_post": 0}
    new = [p for p in ordered if p["post_number"] > state["last_post"]]
    last = max((p["post_number"] for p in ordered), default=0)
    state_path.write_text(json.dumps({"last_post": last, "synced_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}))

    print(f"{topic['title']}: {len(ordered)} posts, last #{last} ({topic['last_posted_at'][:10]}); {len(new)} new")
    if state["last_post"]:
        for p in new:
            print(render(p))


if __name__ == "__main__":
    main()
