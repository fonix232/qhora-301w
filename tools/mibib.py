#!/usr/bin/env python3
"""Decode and build the 301w's SPI-NOR partition table (0:MIBIB), byte-exact.

The NOR phase (docs/design.md, "NOR layout v2") rewrites the first 4 KiB of
0:MIBIB with a new table. This tool only reads and writes files: it turns a
MIBIB dump into a JSON layout and a layout into the sector to write, so the
new table can be checked byte for byte against the stock one before anything
touches the device. It never talks to a device.

  mibib.py decode <mibib.bin>              JSON layout on stdout (refuses anything
                                           it can't rebuild bit for bit)
  mibib.py build <layout.json> <out.bin> [--block]
                                           the 4 KiB sector (--block: the whole
                                           64 KiB erase block, 0xff after 4 KiB)
  mibib.py show <mibib.bin|layout.json>    human-readable table

Sector layout (256-byte pages; reconstructed from our dump and QCA's
u-boot-2016 tools/pack.py and smem.c, see docs/findings):
  page 0   0x000  header         0xFE569FAC 0xCD7F127A version age
  page 1   0x100  system table   0x55EE73AA 0xE35EBDDB version numparts, then
                                 32 slots of {name[16], offset, length (both in
                                 64 KiB blocks), attr (u32: attr1 | attr2<<8 |
                                 attr3<<16 | which_flash<<24)}; unused slots 0.
                                 SBL1 copies this into SMEM for the U-Boot.
  page 5   0x500  user table     0xAA7D1B9A 0x1F7D48BC version numparts, then
                                 32 slots of {name[16], image KiB, padding KiB
                                 (u16), which_flash (u16), attr1..3, 0xff};
                                 image + padding = the partition's size
  page 9   0x900  CRC            0x9D41BEA1 0xF1DED2EA version, then CRC-32
                                 (poly 0x04C11DB7, MSB first, init 0, no final
                                 xor) over 0x000-0x8ff
  everything else 0xff
"""
import argparse
import json
import struct
import sys

PAGE = 0x100
SECTOR = 0x1000
SLOTS = 32
# The stock U-Boot reads the SMEM copy of the system table sized for 32
# entries and, if that fails, for 16 (smem_ptable_init() in QCA's smem.c).
# Staying within 16 works with either.
MAX_PARTS = 16
NAME_LEN = 16

HEADER_MAGIC = (0xFE569FAC, 0xCD7F127A)
SYS_MAGIC = (0x55EE73AA, 0xE35EBDDB)
USR_MAGIC = (0xAA7D1B9A, 0x1F7D48BC)
CRC_MAGIC = (0x9D41BEA1, 0xF1DED2EA)
HEADER_AT, SYS_AT, USR_AT, CRC_AT = 0 * PAGE, 1 * PAGE, 5 * PAGE, 9 * PAGE
SYS_ENTRY = "<16sIII"
USR_ENTRY = "<16sIHHBBBB"
ENTRY_SIZE = struct.calcsize(SYS_ENTRY)
assert ENTRY_SIZE == struct.calcsize(USR_ENTRY) == 28
TABLE_SIZE = 16 + SLOTS * ENTRY_SIZE
assert SYS_AT + TABLE_SIZE <= USR_AT and USR_AT + TABLE_SIZE <= CRC_AT


def _crc_table():
    t = []
    for i in range(256):
        c = i << 24
        for _ in range(8):
            c = ((c << 1) ^ 0x04C11DB7) if c & 0x80000000 else (c << 1)
        t.append(c & 0xFFFFFFFF)
    return t


_CRC = _crc_table()


def crc32_msb(data):
    c = 0
    for b in data:
        c = ((c << 8) & 0xFFFFFFFF) ^ _CRC[((c >> 24) ^ b) & 0xFF]
    return c


def num(v):
    return int(v, 0) if isinstance(v, str) else int(v)


def hexs(v, width=6):
    return f"0x{v:0{width}x}"


def fail(msg):
    raise SystemExit(f"mibib: {msg}")


def check(layout):
    """Validate a layout; return (block, chip, [normalised partitions])."""
    block = num(layout["block_size"])
    chip = num(layout["chip_size"])
    parts = []
    for p in layout["partitions"]:
        q = {"name": p["name"], "offset": num(p["offset"]), "size": num(p["size"]),
             "attr": num(p.get("attr", 0xFFFF)), "pad": num(p.get("pad", 0))}
        n = q["name"].encode("ascii")
        if not 0 < len(n) <= NAME_LEN:
            fail(f"{q['name']}: name must be 1-{NAME_LEN} ASCII bytes")
        if q["offset"] % block or q["size"] % block or q["size"] == 0:
            fail(f"{q['name']}: offset and size must be non-zero multiples of {hexs(block)}")
        if q["pad"] % 1024 or q["pad"] >= q["size"] or q["pad"] // 1024 > 0xFFFF:
            fail(f"{q['name']}: pad must be whole KiB, below the size, at most 0xffff KiB")
        if not 0 <= q["attr"] <= 0xFFFFFFFF:
            fail(f"{q['name']}: attr is a u32")
        parts.append(q)
    if not 0 < len(parts) <= MAX_PARTS:
        fail(f"{len(parts)} partitions; the stock U-Boot is only safe with 1-{MAX_PARTS}")
    names = [p["name"] for p in parts]
    if len(set(names)) != len(names):
        fail("duplicate partition names")
    # The table must describe the whole chip, in order, with no gaps or overlaps.
    at = 0
    for p in parts:
        if p["offset"] != at:
            fail(f"{p['name']} starts at {hexs(p['offset'])}, expected {hexs(at)} (gap, overlap or wrong order)")
        at += p["size"]
    if at != chip:
        fail(f"partitions end at {hexs(at)}, the chip at {hexs(chip)}")
    return block, chip, parts


def build(layout):
    """Return the 4 KiB MIBIB sector for a layout."""
    block, _, parts = check(layout)
    hdr = layout.get("header", {})
    out = bytearray(b"\xff" * SECTOR)
    struct.pack_into("<IIII", out, HEADER_AT, *HEADER_MAGIC,
                     num(hdr.get("version", 4)), num(hdr.get("age", 0)))
    for at, magic, version, entry in (
            (SYS_AT, SYS_MAGIC, layout.get("table_version", 4), sys_entry),
            (USR_AT, USR_MAGIC, layout.get("user_table_version", 4), usr_entry)):
        table = bytearray(TABLE_SIZE)
        struct.pack_into("<IIII", table, 0, *magic, num(version), len(parts))
        for i, p in enumerate(parts):
            table[16 + i * ENTRY_SIZE:16 + (i + 1) * ENTRY_SIZE] = entry(p, block)
        out[at:at + TABLE_SIZE] = table
    struct.pack_into("<IIII", out, CRC_AT, *CRC_MAGIC, num(layout.get("crc_version", 1)),
                     crc32_msb(out[:CRC_AT]))
    return bytes(out)


def sys_entry(p, block):
    return struct.pack(SYS_ENTRY, p["name"].encode("ascii"), p["offset"] // block,
                       p["size"] // block, p["attr"])


def usr_entry(p, block):
    a = p["attr"]
    return struct.pack(USR_ENTRY, p["name"].encode("ascii"), (p["size"] - p["pad"]) // 1024,
                       p["pad"] // 1024, a >> 24, a & 0xFF, (a >> 8) & 0xFF, (a >> 16) & 0xFF, 0xFF)


def decode(data, block=0x10000):
    """Parse a MIBIB dump into a layout; refuse anything build() can't reproduce."""
    if len(data) < SECTOR:
        fail(f"need at least {SECTOR} bytes, got {len(data)}")
    m1, m2, hver, age = struct.unpack_from("<IIII", data, HEADER_AT)
    if (m1, m2) != HEADER_MAGIC:
        fail("no MIBIB header magic at 0x000")
    tables = {}
    for name, at, magic in (("system", SYS_AT, SYS_MAGIC), ("user", USR_AT, USR_MAGIC)):
        t1, t2, ver, n = struct.unpack_from("<IIII", data, at)
        if (t1, t2) != magic:
            fail(f"no {name} table magic at {hexs(at, 3)}")
        if not 0 < n <= SLOTS:
            fail(f"{name} table: {n} entries")
        tables[name] = (ver, n)
    c1, c2, cver, crc = struct.unpack_from("<IIII", data, CRC_AT)
    if (c1, c2) != CRC_MAGIC:
        fail(f"no CRC block magic at {hexs(CRC_AT, 3)}")
    if crc != crc32_msb(data[:CRC_AT]):
        fail(f"CRC mismatch: stored {crc:#010x}, computed {crc32_msb(data[:CRC_AT]):#010x}")
    parts = []
    for i in range(tables["system"][1]):
        name, off, length, attr = struct.unpack_from(SYS_ENTRY, data, SYS_AT + 16 + i * ENTRY_SIZE)
        if length == 0xFFFFFFFF:
            fail(f"entry {i}: 'rest of the chip' length is not supported")
        uname, img_kb, pad_kb, *_ = struct.unpack_from(USR_ENTRY, data, USR_AT + 16 + i * ENTRY_SIZE)
        p = {"name": name.rstrip(b"\0").decode("ascii"), "offset": hexs(off * block),
             "size": hexs(length * block), "attr": hexs(attr, 8)}
        if pad_kb:
            p["pad"] = hexs(pad_kb * 1024)
        parts.append(p)
    layout = {
        "block_size": hexs(block, 5),
        "chip_size": hexs(sum(num(p["size"]) for p in parts)),
        "header": {"version": hver, "age": age},
        "table_version": tables["system"][0],
        "user_table_version": tables["user"][0],
        "crc_version": cver,
        "partitions": parts,
    }
    rebuilt = build(layout)
    if rebuilt != bytes(data[:SECTOR]):
        diff = [hexs(i, 3) for i in range(SECTOR) if rebuilt[i] != data[i]]
        fail(f"can't reproduce this MIBIB bit for bit ({len(diff)} bytes differ, first at {diff[0]})")
    return layout


def show(layout):
    block, _, parts = check(layout)
    print(f"{'name':<16} {'offset':>8} {'size':>8} {'end':>8} {'attr':>10} {'pad':>8}")
    for p in parts:
        print(f"{p['name']:<16} {hexs(p['offset']):>8} {hexs(p['size']):>8} "
              f"{hexs(p['offset'] + p['size']):>8} {hexs(p['attr'], 8):>10} "
              f"{hexs(p['pad']) if p['pad'] else '':>8}")


def dump_json(layout, fp=sys.stdout):
    parts = layout["partitions"]
    rest = {k: v for k, v in layout.items() if k != "partitions"}
    text = json.dumps(rest, indent=1)[:-2]
    fp.write(text + ',\n "partitions": [\n')
    fp.write(",\n".join("  " + json.dumps(p) for p in parts))
    fp.write("\n ]\n}\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("decode")
    d.add_argument("mibib")
    b = sub.add_parser("build")
    b.add_argument("layout")
    b.add_argument("out")
    b.add_argument("--block", action="store_true", help="write the whole 64 KiB erase block")
    s = sub.add_parser("show")
    s.add_argument("file")
    a = ap.parse_args()
    if a.cmd == "decode":
        dump_json(decode(open(a.mibib, "rb").read()))
    elif a.cmd == "build":
        layout = json.load(open(a.layout))
        data = build(layout)
        if a.block:
            data += b"\xff" * (num(layout["block_size"]) - len(data))
        open(a.out, "wb").write(data)
        print(f"{a.out}: {len(data)} bytes, CRC {struct.unpack_from('<I', data, CRC_AT + 12)[0]:#010x}",
              file=sys.stderr)
    else:
        raw = open(a.file, "rb").read()
        show(json.loads(raw) if raw.lstrip()[:1] == b"{" else decode(raw))


if __name__ == "__main__":
    main()
