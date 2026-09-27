#!/bin/sh
# Test tools/mibib.py and the NOR layouts (docs/design.md, "NOR layout v2"):
#   - layouts/nor-stock.json rebuilds the real 0:MIBIB sector bit for bit
#     (its sha256 is pinned below, so this runs without the dump, e.g. in CI)
#   - v2 keeps every stock entry up to 0:ETHPHYFW byte-identical (0:APPSBLENV
#     and 0:ETHPHYFW explicitly), adds only 0:ETHPHYFW2 and 0:APPSBL_1, shrinks
#     reserved, changes nothing outside the two tables and the CRC, and fits in
#     the first 4 KiB
#   - bad layouts and damaged dumps are refused
# With a backup set (QH_BACKUP=<dir with nor/>, default: the newest under
# backups/) it also decodes the dump itself, rebuilds the whole 64 KiB block
# from it, and checks the NOR ranges v2 names against the full NOR image.
#
# usage: tools/test-mibib.sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
backup=${QH_BACKUP:-$(ls -d "$root"/backups/*/*/nor/.. 2>/dev/null | sort | tail -1)}
exec python3 - "$root" "$backup" <<'EOF'
import copy, hashlib, json, os, subprocess, sys
root, backup = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "tools"))
import mibib

# sha256 of the first 4 KiB of mjolnir's 0:MIBIB (nor/mtd1-0_mibib.bin, backup
# 20260927T133902Z-serial). The table has no unit-specific data.
STOCK_SECTOR_SHA256 = "1d1de90c8ba49c2d66ba8420ceefc8bd6fbdcbb74a678a5216498f33fac5a02a"

passed = failed = 0
def result(ok, what):
    global passed, failed
    if ok: passed += 1; print(f"PASS  {what}")
    else: failed += 1; print(f"FAIL  {what}")

def refused(fn, *args):
    try: fn(*args)
    except SystemExit as e: return str(e)
    return None

def strip(layout):
    return {k: v for k, v in layout.items() if k != "description"}

stock = json.load(open(os.path.join(root, "layouts/nor-stock.json")))
v2 = json.load(open(os.path.join(root, "layouts/nor-v2.json")))
s_bin, v_bin = mibib.build(stock), mibib.build(v2)

# ---- the stock table ------------------------------------------------------
result(hashlib.sha256(s_bin).hexdigest() == STOCK_SECTOR_SHA256,
       "nor-stock.json rebuilds the real MIBIB sector (pinned sha256)")
result(mibib.decode(s_bin) == strip(stock), "stock: decode(build(layout)) == layout")

# ---- v2 -------------------------------------------------------------------
result(mibib.decode(v_bin) == strip(v2), "v2: decode(build(layout)) == layout")
result(len(v_bin) == 0x1000 and set(v_bin[mibib.CRC_AT + 16:]) == {0xFF},
       "v2: the whole table is in the first 4 KiB (0xff after the CRC block)")
diff = [i for i in range(0x1000) if s_bin[i] != v_bin[i]]
sys_rng = range(mibib.SYS_AT, mibib.SYS_AT + mibib.TABLE_SIZE)
usr_rng = range(mibib.USR_AT, mibib.USR_AT + mibib.TABLE_SIZE)
crc_rng = range(mibib.CRC_AT + 12, mibib.CRC_AT + 16)
result(diff and all(i in sys_rng or i in usr_rng or i in crc_rng for i in diff),
       f"v2: only the two tables and the CRC change ({len(diff)} bytes; header page identical)")

def entry_bytes(blob, base, i):
    at = base + 16 + i * mibib.ENTRY_SIZE
    return blob[at:at + mibib.ENTRY_SIZE]
s_names = [p["name"] for p in stock["partitions"]]
v_names = [p["name"] for p in v2["partitions"]]
keep = s_names[:s_names.index("reserved")]
same = all(v_names[i] == n and stock["partitions"][i] == v2["partitions"][i]
           and entry_bytes(s_bin, mibib.SYS_AT, i) == entry_bytes(v_bin, mibib.SYS_AT, i)
           and entry_bytes(s_bin, mibib.USR_AT, i) == entry_bytes(v_bin, mibib.USR_AT, i)
           for i, n in enumerate(keep))
result(same, f"v2: the {len(keep)} stock entries before reserved are byte-identical and in place")
for name in ("0:APPSBLENV", "0:ETHPHYFW"):
    i, j = s_names.index(name), v_names.index(name)
    result(i == j and stock["partitions"][i] == v2["partitions"][j]
           and entry_bytes(s_bin, mibib.SYS_AT, i) == entry_bytes(v_bin, mibib.SYS_AT, j)
           and entry_bytes(s_bin, mibib.USR_AT, i) == entry_bytes(v_bin, mibib.USR_AT, j),
           f"v2: {name} unchanged (name, range, attr, both table entries)")
new = [(p["name"], p["offset"], p["size"]) for p in v2["partitions"][len(keep):]]
result(new == [("0:ETHPHYFW2", "0x430000", "0x080000"), ("0:APPSBL_1", "0x4b0000", "0x100000"),
               ("reserved", "0x5b0000", "0x250000")],
       "v2: adds only 0:ETHPHYFW2 0x430000+0x80000 and 0:APPSBL_1 0x4b0000+0x100000; reserved 0x5b0000+0x250000")

# ---- refusals ---------------------------------------------------------------
def with_parts(fn):
    bad = copy.deepcopy(v2); fn(bad["partitions"]); return bad
cases = [
    ("overlap", lambda p: p[1].update(offset="0x040000"), "expected 0x050000"),
    ("gap", lambda p: p.pop(3), "expected 0x1e0000"),
    ("wrong order", lambda p: p.insert(0, p.pop(1)), "expected 0x000000"),
    ("misaligned size", lambda p: p[-1].update(size="0x24f000"), "multiples of"),
    ("name over 16 bytes", lambda p: p[-1].update(name="reserved-and-more!"), "name must be"),
    ("duplicate name", lambda p: p[-1].update(name="0:APPSBL"), "duplicate"),
    ("more than 16 entries", lambda p: [p.append(dict(p[-1], name=f"x{k}")) for k in range(3)], "17 partitions"),
    ("pad not below size", lambda p: p[-1].update(pad="0x250000"), "pad must"),
    ("table short of the chip end", lambda p: p[-1].update(size="0x240000"), "the chip at"),
]
for what, fn, msg in cases:
    err = refused(mibib.build, with_parts(fn))
    result(err is not None and msg in err, f"build refuses: {what}" + ("" if err is None or msg in err else f" (but with: {err})"))
def decode_refuses(what, blob, msg):
    err = refused(mibib.decode, bytes(blob))
    result(err is not None and msg in err, f"decode refuses: {what}" + ("" if err is None or msg in err else f" (but with: {err})"))
bad_crc = bytearray(v_bin); bad_crc[0x120] ^= 1
decode_refuses("a flipped bit (CRC)", bad_crc, "CRC mismatch")
bad_magic = bytearray(v_bin); bad_magic[0x500] ^= 1
decode_refuses("bad user table magic", bad_magic, "no user table magic")
# a user entry that doesn't follow the system table, with a valid CRC
odd = bytearray(v_bin); odd[mibib.USR_AT + 16 + 20] ^= 1
odd[mibib.CRC_AT + 12:mibib.CRC_AT + 16] = mibib.crc32_msb(bytes(odd[:mibib.CRC_AT])).to_bytes(4, "little")
decode_refuses("user table not derived from the system table", odd, "bit for bit")

# ---- against the unit's dump ------------------------------------------------
dump = os.path.join(backup, "nor", "mtd1-0_mibib.bin") if backup else ""
if dump and os.path.isfile(dump):
    raw = open(dump, "rb").read()
    got = mibib.decode(raw)
    result(got == strip(stock), f"dump decodes to layouts/nor-stock.json ({dump})")
    whole = mibib.build(got) + b"\xff" * (len(raw) - 0x1000)
    result(whole == raw, f"build(decode(dump)) == dump, all {len(raw)} bytes")
    nor = os.path.join(backup, "nor", "nor-assembled-complete.bin")
    if os.path.isfile(nor):
        n = open(nor, "rb").read()
        result(set(n[0x4B0000:0x5B0000]) == {0xFF}, "NOR 0x4b0000-0x5affff (0:APPSBL_1) is empty in the full NOR image")
        result(n[0x430000:0x4B0000] != b"\xff" * 0x80000, "NOR 0x430000-0x4affff (0:ETHPHYFW2) holds data already")
        result(n[0x50000:0x60000] == raw[:0x10000], "full NOR image's 0:MIBIB matches the mtd dump")
    else:
        print(f"SKIP  full-NOR checks (no {nor})")
else:
    print("SKIP  dump checks (no backup set; QH_BACKUP=<dir with nor/>)")

print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
EOF
