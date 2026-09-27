#!/usr/bin/env python3
"""Read a NOR range through the stock U-Boot, over the serial console.

Fills what OpenWrt doesn't expose (finding 0001: NOR 0x350000-0x36FFFF, the
tail of the real 0:APPSBL). From a running OpenWrt console it:

  1. runs `reboot` and presses a key during the stock U-Boot's countdown
  2. at the prompt: sf probe; sf read 0x44000000 <off> <len>; crc32; md.b
  3. parses the hex dump, checks it against U-Boot's crc32
  4. runs `reset`, which boots OpenWrt again (the env is never touched)

Read-only on the device apart from the reboot: no setenv/saveenv, no sf
write/erase. With --backup it verifies the read against the Linux MTD dumps
where they overlap, stores it, writes a gap-free assembled NOR image and
marks the backup's NOR coverage complete.

usage: tools/uboot-nor-read.py [--offset 0x340000] [--length 0x40000] [--backup DIR]
"""
import argparse
import datetime
import hashlib
import os
import re
import sys
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from serialcon import Console  # noqa: E402

LOADADDR = 0x44000000  # the stock bootipq's own load address: free RAM at the prompt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port")
    ap.add_argument("--offset", type=lambda s: int(s, 0), default=0x340000)
    ap.add_argument("--length", type=lambda s: int(s, 0), default=0x40000)
    ap.add_argument("--backup")
    ap.add_argument("--at-prompt", action="store_true", help="the device already sits at the stock U-Boot prompt")
    args = ap.parse_args()
    assert args.offset % 0x1000 == 0 and args.length % 16 == 0 and args.offset + args.length <= 8 << 20

    con = Console(args.port)
    s, log = con.s, con.log

    def read_until(pattern, timeout, quiet=False):
        buf, end = b"", time.time() + timeout
        while time.time() < end:
            chunk = s.read(4096)
            if chunk:
                buf += chunk
                if not quiet:
                    log.write(chunk)
                m = re.search(pattern, buf)
                if m:
                    return buf, m
        raise SystemExit("timeout waiting for %r; last output: %r" % (pattern, buf[-300:]))

    if not args.at_prompt:
        board = con.check("cat /tmp/sysinfo/board_name").strip()
        if board != "qnap,301w":
            sys.exit("board is %r, expected 'qnap,301w'; refusing" % board)
        print("rebooting into the stock U-Boot prompt", file=sys.stderr)
        log.write(("\n=== %s reboot for U-Boot NOR read\n" % datetime.datetime.now().isoformat(timespec="seconds")).encode())
        s.write(b"reboot\r")
        read_until(rb"Hit any key to stop autoboot", 180)
        s.write(b" ")  # one key stops autoboot (bootdelay=2)
        time.sleep(3)

    # U-Boot lines end "\r\n\r"; the prompt is whatever the last line is.
    prompt_re = rb"\n\r?([^\r\n]*[#>] ?)$"
    try:
        s.write(b"\r")
        buf, m = read_until(prompt_re, 20)
        prompt = m.group(1)
        print("prompt: %r" % prompt, file=sys.stderr)
        # A second prompt from the Enter may still be on its way: let it
        # arrive, so the first command doesn't match a stale prompt.
        end = time.time() + 1.5
        while time.time() < end:
            log.write(s.read(4096))

        def cmd(line, timeout=30, quiet=False):
            s.write(line.encode() + b"\r")
            out, _ = read_until(rb"\n\r?" + re.escape(prompt) + rb"$", timeout, quiet)
            text = out.decode(errors="replace").replace("\r", "")
            return text.split("\n", 1)[1] if "\n" in text else ""  # drop the echo

        print(cmd("sf probe").strip(), file=sys.stderr)
        print(cmd("sf read 0x%x 0x%x 0x%x" % (LOADADDR, args.offset, args.length)).strip(), file=sys.stderr)
        crc_out = cmd("crc32 0x%x 0x%x" % (LOADADDR, args.length))
        m = re.search(r"==> ([0-9a-f]{8})", crc_out)
        if not m:
            raise SystemExit("no crc32 result: %r" % crc_out)
        want = int(m.group(1), 16)
        t = time.time()
        dump = cmd("md.b 0x%x 0x%x" % (LOADADDR, args.length), timeout=args.length // 700 + 60, quiet=True)
        print("md.b: %.0fs" % (time.time() - t), file=sys.stderr)
    finally:
        # Always leave the prompt the way the device normally boots.
        s.write(b"reset\r")

    data = bytearray()
    expect = LOADADDR
    for line in dump.split("\n"):
        m = re.match(r"([0-9a-f]{8}): ((?:[0-9a-f]{2} ){1,16})", line)
        if not m:
            continue
        if int(m.group(1), 16) != expect:
            raise SystemExit("md.b line out of sequence at %s" % m.group(1))
        chunk = bytes.fromhex(m.group(2))
        data += chunk
        expect += len(chunk)
    data = bytes(data)
    if len(data) != args.length or zlib.crc32(data) != want:
        raise SystemExit("dump: %d bytes, crc32 %08x, U-Boot says %08x" % (len(data), zlib.crc32(data), want))
    print("read %#x-%#x: crc32 %08x matches U-Boot" % (args.offset, args.offset + args.length - 1, want), file=sys.stderr)

    print("waiting for OpenWrt to come back", file=sys.stderr)
    read_until(rb"Please press Enter to activate this console", 240)
    print("OpenWrt is back", file=sys.stderr)

    if args.backup:
        store(args.backup, args.offset, data, want)


def store(bk, off, data, crc):
    nor_dir = os.path.join(bk, "nor")
    img = bytearray(open(os.path.join(nor_dir, "nor-assembled-gaps-zeroed.bin"), "rb").read())
    cover = open(os.path.join(nor_dir, "coverage.txt")).read()
    gaps = [(int(a, 16), int(b, 16)) for a, b in re.findall(r"(0x[0-9a-f]+)-(0x[0-9a-f]+)", cover)]
    end = off + len(data)
    # Everything outside the gaps was read by Linux: it must match byte for byte.
    for i in range(off, end):
        if not any(a <= i <= b for a, b in gaps) and img[i] != data[i - off]:
            raise SystemExit("U-Boot read differs from the Linux dump at %#x" % i)
    for a, b in gaps:
        if not (off <= a and b < end):
            raise SystemExit("gap %#x-%#x is not inside the read range" % (a, b))
    img[off:end] = data
    name = "uboot-sf-read-%#08x-%#08x.bin" % (off, end - 1)
    stamp = datetime.date.today().isoformat()
    files = {
        name: data,
        "nor-assembled-complete.bin": bytes(img),
        "coverage.txt": (
            "NOR ranges not covered by this backup:\n  none\n"
            + "".join("%#08x-%#08x (not exposed by the running kernel) was read through the stock U-Boot on %s "
                      "(sf read, crc32 %08x; the overlap with the Linux reads matches byte for byte): %s\n"
                      % (a, b, stamp, crc, name) for a, b in gaps)
            + "nor-assembled-gaps-zeroed.bin still has those ranges zero-filled; nor-assembled-complete.bin is the whole NOR.\n"
        ).encode(),
    }
    for fname, blob in files.items():
        with open(os.path.join(nor_dir, fname), "wb") as f:
            f.write(blob)
    man_path = os.path.join(bk, "MANIFEST.sha256")
    lines = [l for l in open(man_path) if not any(l.rstrip().endswith("  nor/" + f) for f in files)]
    lines += ["%s  nor/%s\n" % (hashlib.sha256(b).hexdigest(), f) for f, b in files.items()]
    open(man_path, "w").writelines(lines)
    print("backup updated: nor/%s, nor/nor-assembled-complete.bin, nor/coverage.txt" % name, file=sys.stderr)


if __name__ == "__main__":
    main()
