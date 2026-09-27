#!/usr/bin/env python3
"""Read-only backup of a QHora-301W running OpenWrt, over the serial console.

The serial counterpart of tools/backup-live.sh for a unit with no network:
the same info/ files and the same nor/ layout (every MTD partition, an 8 MiB
image assembled by offset, and a coverage report for what the kernel doesn't
expose). Every chunk is read twice on the device and only accepted when the
hash of one read matches the data of the other (tools/serialcon.py).

On the device this only runs cat, dd if=, sha256sum, gzip, hexdump,
fw_printenv, uci show and similar reads. Nothing is written, nothing restarted.

usage: tools/backup-serial.py [--port P] [--unit NAME] [--emmc-part NAME ...]
       tools/backup-serial.py --into backups/<unit>/<stamp>-serial --emmc-part NAME ...
       tools/backup-serial.py --into backups/<unit>/<stamp>-serial --emmc-nc en8:lan4

--emmc-part also fetches whole eMMC partitions by GPT name (slow: ~5 KB/s
for data that doesn't compress). --into adds them to an existing backup
instead of starting a new one (no info, NOR or GPT pass).

--emmc-nc MAC_IF:ROUTER_IF streams the whole eMMC over a direct Ethernet
link instead: the Mac listens on MAC_IF's IPv6 link-local address and the
router, told over serial, runs `dd if=/dev/mmcblk0 | nc <addr>%ROUTER_IF`.
Nothing is configured on the router. Use a router port without a DHCP
server on it (the WAN port), so the Mac's routing isn't affected. The
stream is hashed per partition on arrival and compared with hashes computed
on the device; only mounted or loop-backed partitions may differ.
"""
import argparse
import datetime
import hashlib
import os
import re
import socket
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from serialcon import ROOT, Console  # noqa: E402

INFO = [
    ("proc-mtd.txt", "cat /proc/mtd"),
    ("cmdline.txt", "cat /proc/cmdline"),
    ("partitions.txt", "cat /proc/partitions"),
    ("fw_printenv.txt", "fw_printenv"),
    ("openwrt_release.txt", "cat /etc/openwrt_release"),
    ("board.json", "cat /etc/board.json"),
    ("uname.txt", "uname -a"),
    ("dmesg.txt", "dmesg"),
    ("uci-show.txt", "uci show"),
    ("mounts.txt", "cat /proc/mounts"),
    ("packages.txt", "if command -v apk >/dev/null; then apk list --installed; else opkg list-installed; fi"),
    ("mtd-sysfs.txt", "for d in /sys/class/mtd/mtd[0-9] /sys/class/mtd/mtd[0-9][0-9]; do [ -f $d/name ] && echo ${d##*/} $(cat $d/name) $(cat $d/offset) $(cat $d/size); done"),
    ("loop-backing.txt", "for l in /sys/block/loop*/loop/backing_file; do [ -f $l ] && echo $l $(cat $l); done"),
    ("emmc-parts.txt", "for p in /sys/class/block/mmcblk0p*; do echo ${p##*/} $(sed -n 's/^PARTNAME=//p' $p/uevent) $(cat $p/start) $(cat $p/size); done"),
    ("ext_csd.txt", "cat /sys/kernel/debug/mmc0/mmc0:0001/ext_csd 2>/dev/null || echo unavailable"),
    ("iomem.txt", "cat /proc/iomem"),
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port")
    ap.add_argument("--unit", default="301w")
    ap.add_argument("--emmc-part", action="append", default=[])
    ap.add_argument("--into")
    ap.add_argument("--emmc-nc")
    args = ap.parse_args()

    con = Console(args.port)
    board = con.check("cat /tmp/sysinfo/board_name").strip()
    if board != "qnap,301w":
        sys.exit("board is %r, expected 'qnap,301w'; refusing" % board)

    manifest = []
    if args.into:
        out = os.path.abspath(args.into)
        if not os.path.isfile(os.path.join(out, "info/emmc-parts.txt")):
            sys.exit("%s is not a backup from this tool" % out)
        live = con.check("for p in /sys/class/block/mmcblk0p*; do echo ${p##*/} $(sed -n 's/^PARTNAME=//p' $p/uevent) $(cat $p/start) $(cat $p/size); done")
        if live.split() != open(os.path.join(out, "info/emmc-parts.txt")).read().split():
            sys.exit("the device's partition table differs from the one in %s; refusing" % out)
    else:
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        out = os.path.join(ROOT, "backups", args.unit, stamp + "-serial")
        for d in ("info", "nor", "emmc"):
            os.makedirs(os.path.join(out, d))
    print("backup -> %s" % out, file=sys.stderr)

    def save(rel, data):
        with open(os.path.join(out, rel), "wb") as f:
            f.write(data)
        manifest.append((sha(data), rel))

    if not args.into:
        for name, cmd in INFO:
            rc, text = con.run(cmd, timeout=60)
            save("info/" + name, text.encode())
        save("info/running.dtb", con.fetch("/sys/firmware/fdt"))
        print("info: done", file=sys.stderr)

        # NOR: every MTD partition by name, resolved from sysfs, size asserted.
        mtds = []
        for line in open(os.path.join(out, "info/mtd-sysfs.txt")):
            dev, name, off, size = line.split()
            mtds.append((dev, name, int(off), int(size)))
        for dev, name, off, size in mtds:
            t = time.time()
            data = con.fetch("/dev/%sro" % dev, 0, size,
                             progress=lambda d, n: print("  %s %d/%d KiB" % (name, d >> 10, n >> 10), file=sys.stderr))
            whole = con.check("sha256sum < /dev/%sro" % dev, timeout=120).split()[0]
            if sha(data) != whole:
                sys.exit("NOR %s: assembled data doesn't match the device's whole-partition hash" % dev)
            save("nor/%s-%s.bin" % (dev, name.replace(":", "_").replace("/", "_")), data)
            print("nor: %s %s offset=%#x size=%#x ok (%.0fs)" % (dev, name, off, size, time.time() - t), file=sys.stderr)

        img, cov = bytearray(8 << 20), bytearray(8 << 20)
        for dev, name, off, size in mtds:
            data = open(os.path.join(out, "nor/%s-%s.bin" % (dev, name.replace(":", "_").replace("/", "_"))), "rb").read()
            for i in range(size):
                if cov[off + i] and img[off + i] != data[i]:
                    sys.exit("overlapping partitions disagree at %#x" % (off + i))
            img[off:off + size] = data
            cov[off:off + size] = b"\1" * size
        gaps, start = [], None
        for i, c in enumerate(cov + b"\1"):
            if not c and start is None:
                start = i
            elif c and start is not None:
                gaps.append((start, i))
                start = None
        save("nor/nor-assembled-gaps-zeroed.bin", bytes(img))
        report = "NOR ranges not exposed by the running kernel (zero-filled in the assembled image, NOT device data):\n"
        report += "".join("  %#08x-%#08x (%d bytes)\n" % (a, b - 1, b - a) for a, b in gaps) or "  none\n"
        save("nor/coverage.txt", report.encode())
        print(report, end="", file=sys.stderr)

        # eMMC GPT copies, same ranges as backup-live.sh (tools/mkbundle.sh uses them).
        sectors = int(con.check("cat /sys/class/block/mmcblk0/size").strip())
        save("emmc/gpt-primary.bin", con.fetch_cmd("dd if=/dev/mmcblk0 bs=512 count=34 2>/dev/null", 3))
        save("emmc/gpt-backup.bin", con.fetch_cmd("dd if=/dev/mmcblk0 bs=512 skip=%d count=33 2>/dev/null" % (sectors - 33), 3))
        print("emmc: GPT copies ok", file=sys.stderr)

    # Optional eMMC partitions by GPT name.
    parts = {}
    for line in open(os.path.join(out, "info/emmc-parts.txt")):
        dev, pname, start, size = line.split()
        parts[pname] = (dev, int(start), int(size))
    for pname in args.emmc_part:
        if pname not in parts:
            sys.exit("no eMMC partition named %r" % pname)
        dev, start, size = parts[pname]
        data = con.fetch("/dev/%s" % dev, 0, size * 512,
                         progress=lambda d, n: print("  %s %d/%d MiB" % (pname, d >> 20, n >> 20), file=sys.stderr))
        whole = con.check("sha256sum < /dev/%s" % dev, timeout=1800).split()[0]
        live = con.run("grep -q '^/dev/%s ' /proc/mounts || grep -qs '/dev/%s$' /sys/block/loop*/loop/backing_file" % (dev, dev))[0] == 0
        if sha(data) != whole and not live:
            sys.exit("eMMC %s: data doesn't match the device's whole-partition hash" % dev)
        save("emmc/%s-%s.bin" % (dev, pname.replace(":", "_")), data)
        print("emmc: %s %s ok%s" % (dev, pname, " (live: changed while reading)" if sha(data) != whole else ""), file=sys.stderr)

    if args.emmc_nc:
        emmc_over_nc(con, out, args.emmc_nc)
        for rel in ("emmc/mmcblk0.img.zst", "emmc/mmcblk0.img.sha256", "emmc/device-partitions.sha256"):
            h = hashlib.sha256()
            with open(os.path.join(out, rel), "rb") as f:
                for block in iter(lambda: f.read(1 << 20), b""):
                    h.update(block)
            manifest.append((h.hexdigest(), rel))

    with open(os.path.join(out, "MANIFEST.sha256"), "a" if args.into else "w") as f:
        f.writelines("%s  %s\n" % m for m in manifest)
    print("done: %s" % out, file=sys.stderr)


def emmc_over_nc(con, out, spec, port=9000):
    mac_if, router_if = spec.split(":")
    ifc = subprocess.run(["ifconfig", mac_if], capture_output=True, text=True).stdout
    m = re.search(r"inet6 (fe80::[0-9a-f:]+)%" + re.escape(mac_if), ifc)
    if not m:
        sys.exit("%s has no IPv6 link-local address" % mac_if)
    addr = m.group(1)
    if con.check("cat /sys/class/net/%s/carrier" % router_if).strip() != "1":
        sys.exit("router interface %s has no link" % router_if)
    total = int(con.check("cat /sys/class/block/mmcblk0/size").strip()) * 512
    parts = []
    for line in open(os.path.join(out, "info/emmc-parts.txt")):
        dev, name, start, size = line.split()
        parts.append((int(start) * 512, (int(start) + int(size)) * 512, dev, name))

    srv = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((addr, port, 0, socket.if_nametoindex(mac_if)))  # only on the direct link
    srv.listen(1)
    srv.settimeout(60)
    dst = os.path.join(out, "emmc/mmcblk0.img.zst")
    result = {}

    def receive():
        try:
            conn, peer = srv.accept()
        except socket.timeout:
            return
        conn.settimeout(120)
        zst = subprocess.Popen(["zstd", "-q", "-T0", "-10", "-f", "-o", dst], stdin=subprocess.PIPE)
        whole = hashlib.sha256()
        hashers = {dev: hashlib.sha256() for _, _, dev, _ in parts}
        pos, t0, shown = 0, time.time(), 0
        while True:
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            zst.stdin.write(chunk)
            whole.update(chunk)
            end = pos + len(chunk)
            for a, b, dev, _ in parts:
                lo, hi = max(a, pos), min(b, end)
                if lo < hi:
                    hashers[dev].update(chunk[lo - pos:hi - pos])
            pos = end
            if pos - shown >= 256 << 20:
                shown = pos
                print("  emmc %d/%d MiB (%.0f MiB/s)" % (pos >> 20, total >> 20, (pos >> 20) / max(time.time() - t0, 1)), file=sys.stderr)
        zst.stdin.close()
        zst.wait()
        result.update(size=pos, whole=whole.hexdigest(), peer=peer[0],
                      parts={d: h.hexdigest() for d, h in hashers.items()})

    th = threading.Thread(target=receive)
    th.start()
    print("emmc: streaming to [%s]:%d via the router's %s" % (addr, port, router_if), file=sys.stderr)
    rc, text = con.run("dd if=/dev/mmcblk0 bs=1M 2>/dev/null | nc %s%%%s %d" % (addr, router_if, port), timeout=3600)
    th.join()
    srv.close()
    if result.get("size") != total:
        sys.exit("eMMC stream: got %s bytes, expected %d (nc exit %d: %s)" % (result.get("size"), total, rc, text.strip()))
    with open(os.path.join(out, "emmc/mmcblk0.img.sha256"), "w") as f:
        f.write("%s  mmcblk0.img\n" % result["whole"])
    print("emmc: %d MiB received from %s; hashing partitions on the device" % (total >> 20, result["peer"]), file=sys.stderr)

    # Partitions the running system writes to may legitimately differ.
    live = set(re.findall(r"/dev/(mmcblk0p\d+)", con.check(
        "cat /proc/mounts; for l in /sys/block/loop*/loop/backing_file; do [ -f $l ] && cat $l; done")))
    report, bad = [], []
    for a, b, dev, name in parts:
        dev_hash = con.check("sha256sum /dev/%s" % dev, timeout=1800).split()[0]
        if dev_hash == result["parts"][dev]:
            state = "ok"
        elif dev in live:
            state = "changed-live"
        else:
            state = "MISMATCH"
            bad.append(dev)
        report.append("%s %s %s %s" % (dev, name, dev_hash, state))
        print("  %s %-12s %s" % (dev, name, state), file=sys.stderr)
    with open(os.path.join(out, "emmc/device-partitions.sha256"), "w") as f:
        f.write("\n".join(report) + "\n")
    if bad:
        sys.exit("eMMC partitions differ from the device: %s" % " ".join(bad))


if __name__ == "__main__":
    main()
