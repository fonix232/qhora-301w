#!/usr/bin/env python3
"""Run shell commands on the router's serial console and print their output.

usage: tools/serial-run.py [--port P] [--timeout S] 'cmd1' ['cmd2' ...]

See tools/serialcon.py. Read-only commands only unless a step has the user's
go-ahead (.ai/skills/device-safety).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from serialcon import Console, ConsoleError  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port")
    ap.add_argument("--timeout", type=float, default=30, help="seconds per command")
    ap.add_argument("commands", nargs="+")
    args = ap.parse_args()
    con = Console(args.port)
    for cmd in args.commands:
        try:
            rc, out = con.run(cmd, args.timeout)
        except ConsoleError as e:
            print("### %s\n### %s" % (cmd, e))
            return 1
        print("### %s  (exit %d)\n%s" % (cmd, rc, out.rstrip()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
