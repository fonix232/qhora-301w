"""Shell access to the router over its serial console (OpenWrt, no login).

Used by tools/serial-run.py and tools/backup-serial.py. Talks to the ESP32-S3
bridge (tools/esp32s3-uart-bridge/, Espressif VID only) unless a port is
given. Everything sent and received, except bulk hex payloads, is appended to
logs/serial-YYYYMMDD.log.

This is a transport, not a safety layer: callers decide what is safe to run
(.ai/skills/device-safety). Read-only commands only unless a step has the
user's go-ahead.
"""
import datetime
import gzip
import hashlib
import os
import random
import re
import sys
import time

import serial
from serial.tools import list_ports

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BAUD = 115200
HEX_LINE = re.compile(r"^[0-9a-f ]+$")


class ConsoleError(Exception):
    pass


class Console:
    def __init__(self, port=None):
        if not port:
            ports = [p.device for p in list_ports.comports() if p.vid == 0x303A]
            if len(ports) != 1:
                raise ConsoleError("expected exactly one Espressif bridge, found %d; pass a port" % len(ports))
            port = ports[0]
        os.makedirs(os.path.join(ROOT, "logs"), exist_ok=True)
        self.log = open(os.path.join(ROOT, "logs", "serial-%s.log" % datetime.date.today().strftime("%Y%m%d")), "ab")
        self.s = serial.Serial(port, BAUD, timeout=0.1)  # DTR/RTS asserted: the bridge doesn't reset
        # Ctrl-C discards a half-received line left by an earlier session (a
        # lost character can leave the shell at a continuation prompt), then
        # Enter activates the console ("Please press Enter"). Drain the echo.
        self.s.write(b"\x03")
        self._drain(0.3)
        self.s.write(b"\r")
        self._drain(1.0)

    def _drain(self, secs):
        end = time.time() + secs
        while time.time() < end:
            self.log.write(self.s.read(4096))

    def run(self, cmd, timeout=30, quiet=False):
        """Run cmd; return (exit status, output). quiet keeps the output out of the log."""
        tag = "%08x" % random.getrandbits(32)
        # The echoed command line shows `__B_""tag`; only real output shows `__B_tag`.
        line = 'echo "__B_""%s"; %s; echo "__E_""%s $?"\r' % (tag, cmd, tag)
        self.log.write(("\n=== %s $ %s\n" % (datetime.datetime.now().isoformat(timespec="seconds"), cmd)).encode())
        self.s.write(line.encode())
        begin, end = ("__B_%s" % tag).encode(), ("__E_%s " % tag).encode()
        buf, deadline = b"", time.time() + timeout
        while time.time() < deadline:
            chunk = self.s.read(65536)
            if chunk:
                buf += chunk
                if not quiet:
                    self.log.write(chunk)
                # Keep extending the deadline while data flows.
                deadline = max(deadline, time.time() + 10)
            i = buf.find(end)
            if i >= 0 and buf.find(b"\n", i) >= 0:
                break
        else:
            raise ConsoleError("timeout running %r" % cmd)
        text = buf.decode(errors="replace").replace("\r", "")
        body = text.split(begin.decode() + "\n", 1)
        if len(body) != 2:
            raise ConsoleError("no start marker for %r" % cmd)
        out, _, rest = body[1].partition(end.decode())
        return int(rest.split()[0]), out

    def check(self, cmd, timeout=30):
        rc, out = self.run(cmd, timeout)
        if rc:
            raise ConsoleError("%r exited %d: %s" % (cmd, rc, out.strip()))
        return out

    def fetch(self, src, offset=0, length=None, chunk=1 << 20, retries=3, progress=None):
        """Read `length` bytes of device file `src` from `offset`, in chunks.

        Each chunk is read twice on the device: once hashed there, once sent
        gzip'd as hex. The chunk is accepted only if the hashes match, so a
        kernel message landing in the stream, a dropped byte or an unstable
        read all cause a retry, never silent corruption. offset, length and
        chunk must be multiples of 64 KiB unless length is None (whole file,
        read with cat).
        """
        if length is None:
            return self.fetch_cmd("cat %s" % src, retries)
        bs = 65536
        assert offset % bs == 0 and chunk % bs == 0
        out = bytearray()
        pos = offset
        while pos < offset + length:
            n = min(chunk, offset + length - pos)
            count = (n + bs - 1) // bs
            data = self.fetch_cmd("dd if=%s bs=%d skip=%d count=%d 2>/dev/null" % (src, bs, pos // bs, count), retries)
            if len(data) != n:
                raise ConsoleError("%s @%#x: got %d bytes, expected %d" % (src, pos, len(data), n))
            out += data
            pos += n
            if progress:
                progress(pos - offset, length)
        return bytes(out)

    def fetch_cmd(self, reader, retries=3):
        """Run a device-side command that writes binary to stdout; return its output, verified."""
        for attempt in range(retries):
            want = self.check("%s | sha256sum" % reader, timeout=120).split()[0]
            # 2 hex chars per byte at ~11.5 KB/s; run() extends the deadline while data flows.
            rc, out = self.run("%s | gzip -c | hexdump -v -e '64/1 \"%%02x\" \"\\n\"'" % reader, timeout=60, quiet=True)
            if rc == 0:
                hexdata = "".join(l.replace(" ", "") for l in out.split("\n") if HEX_LINE.match(l))
                try:
                    data = gzip.decompress(bytes.fromhex(hexdata))
                except (ValueError, OSError, EOFError):
                    data = None
                if data is not None and hashlib.sha256(data).hexdigest() == want:
                    return data
            print("  retry %d: %s" % (attempt + 1, reader), file=sys.stderr)
        raise ConsoleError("could not read %s intact after %d attempts" % (reader, retries))
