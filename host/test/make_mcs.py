"""Write a binary as an Intel-hex .mcs (16-byte records), like Vivado write_cfgmem."""
import sys

src, dst, base = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
data = open(src, "rb").read()


def rec(typ, addr, payload):
    body = bytes([len(payload), (addr >> 8) & 0xFF, addr & 0xFF, typ]) + payload
    return ":" + body.hex().upper() + "%02X" % ((-sum(body)) & 0xFF) + "\n"


with open(dst, "w") as f:
    hi = None
    for off in range(0, len(data), 16):
        a = base + off
        if a >> 16 != hi:
            hi = a >> 16
            f.write(rec(4, 0, bytes([hi >> 8, hi & 0xFF])))
        f.write(rec(0, a & 0xFFFF, data[off:off + 16]))
    f.write(rec(1, 0, b""))
