#!/usr/bin/env python3
"""Build and inspect GPT partition tables for the 301w eMMC, byte-exact.

The installer never partitions on the device: it verifies the current table
and writes the primary and backup GPT blobs generated here with dd. That keeps
the device-side script trivial to review, and lets us rebuild the stock table
from a spec and compare it with a real backup byte for byte.

  gpt.py build <layout.json> <out-prefix> [--disk-sectors N] [--disk-guid G]
      writes <out-prefix>.primary.bin (LBA 0..entries end) and
      <out-prefix>.backup.bin (backup entries + header, the disk's last sectors)
      plus <out-prefix>.json (the exact values used, including generated GUIDs)
  gpt.py dump <image-or-primary.bin>
"""
import argparse
import json
import struct
import sys
import uuid
import zlib

SECTOR = 512
ENTRY_SIZE = 128


def guid_bytes(s):
    return uuid.UUID(s).bytes_le


def guid_str(b):
    return str(uuid.UUID(bytes_le=bytes(b)))


def protective_mbr(disk_sectors):
    mbr = bytearray(SECTOR)
    size = min(disk_sectors - 1, 0xFFFFFFFF)
    mbr[446:462] = struct.pack("<B3sB3sII", 0x00, b"\x00\x02\x00", 0xEE, b"\xff\xff\xff", 1, size)
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr)


def entries_blob(parts, num_entries):
    blob = bytearray(num_entries * ENTRY_SIZE)
    for i, p in enumerate(parts):
        name = p["name"].encode("utf-16-le")
        assert len(name) <= 72, p["name"]
        struct.pack_into("<16s16sQQQ72s", blob, i * ENTRY_SIZE,
                         guid_bytes(p["type"]), guid_bytes(p["guid"]),
                         p["start"], p["end"], p.get("attrs", 0), name)
    return bytes(blob)


def header(my_lba, alt_lba, first_usable, last_usable, disk_guid, entries_lba,
           num_entries, entries_crc):
    fields = [b"EFI PART", 0x00010000, 92, 0, 0, my_lba, alt_lba, first_usable,
              last_usable, guid_bytes(disk_guid), entries_lba, num_entries,
              ENTRY_SIZE, entries_crc]
    fmt = "<8sIIIIQQQQ16sQIII"
    raw = struct.pack(fmt, *fields)
    fields[3] = zlib.crc32(raw) & 0xFFFFFFFF
    return struct.pack(fmt, *fields).ljust(SECTOR, b"\0")


def build(layout, disk_sectors, disk_guid):
    num = layout.get("num_entries", 128)
    entry_sectors = (num * ENTRY_SIZE + SECTOR - 1) // SECTOR
    first_usable = layout.get("first_usable", 2 + entry_sectors)
    last_lba = disk_sectors - 1
    last_usable = layout.get("last_usable_from_end")
    last_usable = last_lba - (last_usable if last_usable is not None else 1 + entry_sectors)
    parts = []
    for p in layout["partitions"]:
        p = dict(p)
        p.setdefault("guid", str(uuid.uuid4()))
        if p.get("end") == "last":
            align = layout.get("align", 1)
            p["end"] = (last_usable + 1) // align * align - 1
        assert first_usable <= p["start"] <= p["end"] <= last_usable, p
        parts.append(p)
    for a, b in zip(parts, parts[1:]):
        assert a["end"] < b["start"], (a["name"], b["name"])
    entries = entries_blob(parts, num)
    ecrc = zlib.crc32(entries) & 0xFFFFFFFF
    entries_padded = entries.ljust(entry_sectors * SECTOR, b"\0")
    primary = (protective_mbr(disk_sectors)
               + header(1, last_lba, first_usable, last_usable, disk_guid, 2, num, ecrc)
               + entries_padded)
    backup_entries_lba = last_lba - entry_sectors
    backup = entries_padded + header(last_lba, 1, first_usable, last_usable, disk_guid,
                                     backup_entries_lba, num, ecrc)
    used = dict(layout, partitions=parts, disk_sectors=disk_sectors, disk_guid=disk_guid,
                first_usable=first_usable, last_usable=last_usable,
                backup_lba=backup_entries_lba)
    return primary, backup, used


def dump(data):
    hdr = data[SECTOR:2 * SECTOR]
    (sig, rev, hsize, hcrc, _, my, alt, first, last, dguid, elba, num, esize,
     ecrc) = struct.unpack_from("<8sIIIIQQQQ16sQIII", hdr)
    assert sig == b"EFI PART", "no GPT header at LBA 1"
    check = bytearray(hdr[:hsize])
    check[16:20] = b"\0\0\0\0"
    ok = zlib.crc32(check) & 0xFFFFFFFF == hcrc
    entries = data[elba * SECTOR:elba * SECTOR + num * esize]
    eok = zlib.crc32(entries) & 0xFFFFFFFF == ecrc
    print(f"disk guid {guid_str(dguid)}  entries {num}x{esize} at LBA {elba}  "
          f"usable {first}..{last}  backup header LBA {alt}  "
          f"header crc {'ok' if ok else 'BAD'}  entries crc {'ok' if eok else 'BAD'}")
    for i in range(num):
        e = entries[i * esize:(i + 1) * esize]
        t, g, s, en, attrs, name = struct.unpack("<16s16sQQQ72s", e)
        if t == bytes(16):
            continue
        n = name.decode("utf-16-le").rstrip("\0")
        print(f"{i + 1:3} {s:>9} {en:>9} {(en - s + 1) * SECTOR / 1048576:9.2f} MiB  "
              f"{n:<14} type {guid_str(t)}  guid {guid_str(g)}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("layout")
    b.add_argument("out")
    b.add_argument("--disk-sectors", type=int, default=7634944)
    b.add_argument("--disk-guid", default=None)
    d = sub.add_parser("dump")
    d.add_argument("image")
    a = ap.parse_args()
    if a.cmd == "build":
        layout = json.load(open(a.layout))
        guid = a.disk_guid or layout.get("disk_guid") or str(uuid.uuid4())
        primary, backup, used = build(layout, a.disk_sectors, guid)
        open(a.out + ".primary.bin", "wb").write(primary)
        open(a.out + ".backup.bin", "wb").write(backup)
        json.dump(used, open(a.out + ".json", "w"), indent=1)
        print(f"primary {len(primary)} bytes at LBA 0, backup {len(backup)} bytes at LBA "
              f"{used['backup_lba']}", file=sys.stderr)
    else:
        with open(a.image, "rb") as f:
            dump(f.read(64 * SECTOR))


if __name__ == "__main__":
    main()
