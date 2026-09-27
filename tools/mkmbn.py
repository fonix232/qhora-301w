#!/usr/bin/env python3
"""Qualcomm MBN v3 images for the IPQ807x APPSBL slot.

  mkmbn.py verify <file>...
      recompute the hash table of an existing image (ELF32 or ELF64) and
      compare it and the MBN v3 header with what is stored
  mkmbn.py appsbl <raw image> <out.mbn> [--load 0x4a900000]
      wrap a raw, position-independent image (tools/appsbl/trampoline.S +
      payload) as an ELF32 APPSBL with an unsigned MBN v3 hash segment

The format was reversed from QCA's own APPSBL and is documented in
docs/findings/0003-ipq807x-boot-chain.md. `verify` reproduces the stored
hashes of QCA's images exactly, which is how the generator is tested.
"""
import argparse
import hashlib
import struct
import sys

MBN_HDR = struct.Struct("<10I")
HASH_FLAGS = 0x02200000        # Qualcomm segment type HASH
PHDR_FLAGS = 0x07000000        # Qualcomm segment type PHDR
APPSBL_ID = 0x15


def parse(data):
    assert data[:4] == b"\x7fELF", "not an ELF"
    is64 = data[4] == 2
    if is64:
        phoff, = struct.unpack_from("<Q", data, 32)
        phentsize, phnum = struct.unpack_from("<HH", data, 54)
        fmt = "<IIQQQQQQ"
        keys = ("type", "flags", "offset", "vaddr", "paddr", "filesz", "memsz", "align")
    else:
        phoff, = struct.unpack_from("<I", data, 28)
        phentsize, phnum = struct.unpack_from("<HH", data, 42)
        fmt = "<IIIIIIII"
        keys = ("type", "offset", "vaddr", "paddr", "filesz", "memsz", "flags", "align")
    segs = [dict(zip(keys, struct.unpack_from(fmt, data, phoff + i * phentsize)))
            for i in range(phnum)]
    return phoff + phnum * phentsize, segs


def hash_table(data, headers_end, segs):
    table = b""
    for s in segs:
        role = (s["flags"] >> 24) & 7
        if role == 7:                       # PHDR: ELF header + program headers
            table += hashlib.sha256(data[:headers_end]).digest()
        elif role == 2 or s["filesz"] == 0:  # the hash segment itself, empty segments
            table += bytes(32)
        else:
            table += hashlib.sha256(data[s["offset"]:s["offset"] + s["filesz"]]).digest()
    return table


def verify(path):
    data = open(path, "rb").read()
    headers_end, segs = parse(data)
    hs = [s for s in segs if (s["flags"] >> 24) & 7 == 2]
    assert len(hs) == 1, "expected exactly one hash segment"
    h = hs[0]
    hdr = MBN_HDR.unpack_from(data, h["offset"])
    stored = data[h["offset"] + 40:h["offset"] + 40 + hdr[5]]
    ok = stored == hash_table(data, headers_end, segs)
    dest = h["vaddr"] + h["offset"] + 40
    hdr_ok = hdr[1] == 3 and hdr[3] == dest and hdr[4] == hdr[5] == 32 * len(segs)
    print(f"{path}: image_id {hdr[0]:#x}, v{hdr[1]}, {len(segs)} segments, "
          f"hashes {'match' if ok else 'DO NOT MATCH'}, header {'consistent' if hdr_ok else 'differs from the formula'}, "
          f"{'signed' if hdr[7] else 'unsigned'}")
    return ok


def build_appsbl(raw, load):
    load_off = 0x2000
    hash_off = 0x1000
    phnum = 3
    headers_end = 52 + 32 * phnum
    hash_vaddr = (load + len(raw) + 0xFFFF) & ~0xFFFF
    code_size = 32 * phnum
    hash_filesz = 40 + code_size
    phdrs = [
        # type, offset, vaddr, paddr, filesz, memsz, flags, align
        (0, 0, 0, 0, headers_end, 0, PHDR_FLAGS, 0),
        (0, hash_off, hash_vaddr, hash_vaddr, hash_filesz, 0x1000, HASH_FLAGS, 0x1000),
        (1, load_off, load, load, len(raw), len(raw), 0x7, 0x10000),
    ]
    ehdr = b"\x7fELF\x01\x01\x01" + bytes(9) + struct.pack(
        "<HHIIIIIHHHHHH", 3, 40, 1, load, 52, 0, 0x5000202, 52, 32, phnum, 40, 0, 0)
    out = bytearray(load_off + len(raw))
    out[:52] = ehdr
    for i, p in enumerate(phdrs):
        struct.pack_into("<8I", out, 52 + 32 * i, *p)
    out[load_off:] = raw
    segs = [dict(type=p[0], offset=p[1], vaddr=p[2], filesz=p[4], flags=p[6]) for p in phdrs]
    table = hash_table(bytes(out), headers_end, segs)
    dest = hash_vaddr + hash_off + 40
    out[hash_off:hash_off + 40] = MBN_HDR.pack(APPSBL_ID, 3, 0, dest, code_size, code_size,
                                               dest + code_size, 0, dest + code_size, 0)
    out[hash_off + 40:hash_off + hash_filesz] = table
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("verify")
    v.add_argument("files", nargs="+")
    a = sub.add_parser("appsbl")
    a.add_argument("raw")
    a.add_argument("out")
    a.add_argument("--load", type=lambda x: int(x, 0), default=0x4A900000)
    args = ap.parse_args()
    if args.cmd == "verify":
        sys.exit(0 if all([verify(f) for f in args.files]) else 1)
    raw = open(args.raw, "rb").read()
    mbn = build_appsbl(raw, args.load)
    assert len(mbn) <= 0x100000, f"{len(mbn)} bytes does not fit the 1 MiB 0:appsbl partition"
    open(args.out, "wb").write(mbn)
    verify(args.out)


if __name__ == "__main__":
    main()
