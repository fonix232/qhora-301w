#!/usr/bin/env python3
"""Inspect Qualcomm IPQ807x boot-chain images and NOR dumps (read-only analysis).

  analyze-boot.py elf <file>...        ELF class/entry/segments, Qualcomm hash
                                       segment and signing info, per image
  analyze-boot.py nor <8MiB-image>     decode the MIBIB partition table and
                                       analyse every ELF partition in it
  analyze-boot.py strings <file> [re]  printable strings matching a regex
                                       (default: download/recovery hints)
  analyze-boot.py env <file> [size]    decode a U-Boot environment block

Background: docs/open-questions.md Q7 (what SBL1 offers when APPSBL is bad)
and Q8 (how SBL1 loads and enters APPSBL).
"""
import re
import struct
import sys
import zlib

PT = {0: "NULL", 1: "LOAD", 2: "DYNAMIC", 4: "NOTE", 6: "PHDR", 0x6474e551: "GNU_STACK"}
# Qualcomm encodes the segment role in p_flags bits 24-26 (MI_PBT_*)
QC_SEG = {0: "L4", 1: "AMSS", 2: "HASH", 3: "BOOT", 4: "L4BSP", 5: "SWAPPED", 6: "SWAP_POOL", 7: "PHDR"}

RECOVERY_RE = (r"(?i)(dload|download|sahara|firehose|edl|emergency|usb.{0,20}(boot|d\+|mode)|"
               r"crash ?dump|ramdump|memory dump|recovery|fallback|failsafe|boot ?config|appsbl|bootconfig|age)")


def elf_info(data, name=""):
    if data[:4] != b"\x7fELF":
        return None
    cls = data[4]
    is64 = cls == 2
    if is64:
        (e_type, e_machine, _, e_entry, e_phoff, _, e_flags, _, e_phentsize,
         e_phnum) = struct.unpack_from("<HHIQQQIHHH", data, 16)
    else:
        (e_type, e_machine, _, e_entry, e_phoff, _, e_flags, _, e_phentsize,
         e_phnum) = struct.unpack_from("<HHIIIIIHHH", data, 16)
    out = {"name": name, "class": 64 if is64 else 32, "type": e_type, "machine": e_machine,
           "entry": e_entry, "flags": e_flags, "segments": []}
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if is64:
            p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = \
                struct.unpack_from("<IIQQQQQQ", data, off)
        else:
            p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align = \
                struct.unpack_from("<IIIIIIII", data, off)
        out["segments"].append(dict(type=p_type, flags=p_flags, offset=p_offset, vaddr=p_vaddr,
                                    paddr=p_paddr, filesz=p_filesz, memsz=p_memsz, align=p_align))
    return out


def hash_segment_header(data, seg):
    """MBN header at the start of the hash segment (v3/v5: 40 bytes, v6: 48)."""
    h = data[seg["offset"]:seg["offset"] + 48]
    if len(h) < 40:
        return None
    fields = struct.unpack_from("<10I", h)
    names = ["image_id", "version", "image_src", "image_dest_ptr", "image_size", "code_size",
             "sig_ptr", "sig_size", "cert_chain_ptr", "cert_chain_size"]
    d = dict(zip(names, fields))
    if d["version"] >= 6:
        d["metadata_size_qti"], d["metadata_size"] = struct.unpack_from("<2I", h, 40)
    return d


def print_elf(info, data):
    mach = {40: "ARM", 183: "AArch64"}.get(info["machine"], info["machine"])
    etype = {2: "EXEC", 3: "DYN"}.get(info["type"], info["type"])
    print(f"{info['name']}: ELF{info['class']} {mach} {etype} entry {info['entry']:#x} "
          f"e_flags {info['flags']:#x}, {len(info['segments'])} segments, file {len(data)} bytes")
    for i, s in enumerate(info["segments"]):
        role = QC_SEG.get((s["flags"] >> 24) & 7, "?")
        print(f"  [{i}] {PT.get(s['type'], hex(s['type'])):9} off {s['offset']:#08x} "
              f"vaddr {s['vaddr']:#010x} paddr {s['paddr']:#010x} filesz {s['filesz']:#08x} "
              f"memsz {s['memsz']:#08x} flags {s['flags']:#010x} ({role})")
        if role == "HASH" and s["filesz"]:
            h = hash_segment_header(data, s)
            if h:
                signed = "signed" if h["sig_size"] else "not signed"
                print(f"      hash segment header: version {h['version']}, code {h['code_size']:#x}, "
                      f"signature {h['sig_size']} B, cert chain {h['cert_chain_size']} B -> {signed}")


def cmd_elf(paths):
    for p in paths:
        data = open(p, "rb").read()
        info = elf_info(data, p)
        if not info:
            print(f"{p}: not an ELF (first bytes {data[:8].hex()})")
            continue
        print_elf(info, data)


def printable_strings(data, minlen=6):
    for m in re.finditer(rb"[\x20-\x7e]{%d,}" % minlen, data):
        yield m.start(), m.group().decode("ascii")


def cmd_strings(path, pattern=None):
    data = open(path, "rb").read()
    rx = re.compile(pattern or RECOVERY_RE)
    seen = set()
    for off, s in printable_strings(data):
        if rx.search(s) and s not in seen:
            seen.add(s)
            print(f"{off:#08x}  {s}")


def mibib_table(nor):
    base, size = 0x50000, 0x10000
    region = nor[base:base + size]
    i = region.find(struct.pack("<II", 0x55EE73AA, 0xE35EBDDB))
    if i < 0:
        return None, None
    version, count = struct.unpack_from("<II", region, i + 8)
    parts = []
    for n in range(min(count, 32)):
        name, start, psize, attr = struct.unpack_from("<16sIII", region, i + 16 + n * 28)
        parts.append((name.rstrip(b"\0").decode(errors="replace"), start, psize, attr))
    return (version, count, base + i), parts


def cmd_nor(path, block=0x10000):
    nor = open(path, "rb").read()
    print(f"{path}: {len(nor)} bytes")
    hdr, parts = mibib_table(nor)
    if not hdr:
        print("no MIBIB partition table found at 0x50000")
        return
    version, count, where = hdr
    print(f"MIBIB table at {where:#x}: version {version}, {count} partitions (units of {block:#x})")
    for name, start, psize, attr in parts:
        size = (len(nor) // block - start) if psize == 0xFFFFFFFF else psize
        print(f"  {name:<14} {start * block:#08x} +{size * block:#08x}  attr {attr:#010x}")
    for name, start, psize, attr in parts:
        chunk = nor[start * block:(start + (psize if psize != 0xFFFFFFFF else 0)) * block]
        info = elf_info(chunk, name)
        if info:
            print_elf(info, chunk)


def cmd_env(path, size=0x20000):
    data = open(path, "rb").read()[:size]
    crc, body = struct.unpack_from("<I", data)[0], data[4:]
    ok = zlib.crc32(body) & 0xFFFFFFFF == crc
    redundant = False
    if not ok:  # redundant layout: crc, flags byte, data
        ok = zlib.crc32(data[5:]) & 0xFFFFFFFF == crc
        body, redundant = data[5:], ok
    print(f"{path}: crc {'ok' if ok else 'BAD'}{' (redundant layout)' if redundant else ''}")
    for kv in body.split(b"\0"):
        if not kv:
            break
        print("  " + kv.decode(errors="replace"))


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "elf":
        cmd_elf(args)
    elif cmd == "strings":
        cmd_strings(args[0], args[1] if len(args) > 1 else None)
    elif cmd == "nor":
        cmd_nor(args[0])
    elif cmd == "env":
        cmd_env(args[0], int(args[1], 0) if len(args) > 1 else 0x20000)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
