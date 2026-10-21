#!/usr/bin/env python3
"""u55c -- host tool for the Alveo U55C RISC-V image.

Talks to the card through BAR0 (1 MB), mapped from
/sys/bus/pci/devices/<BDF>/resource0. No kernel driver is needed, but the
tool must run as root (sudo).

    sudo ./u55c.py status
    sudo ./u55c.py load fw.bin          # hold CPU, copy firmware, run
    sudo ./u55c.py console              # live log + keyboard input (Ctrl-] quits)
    sudo ./u55c.py log                  # print the log buffer and exit
    sudo ./u55c.py send "help"          # type one line into the firmware console
    sudo ./u55c.py mbox call 1 41       # mailbox request -> prints the result
    sudo ./u55c.py flash program x.mcs  # write the config flash (uses ./u55c-flash)
    sudo ./u55c.py fpga-reload          # reload the FPGA from flash

Run `./u55c.py <command> -h` for details. The register map is documented in
docs/GUIDE.md.
"""
import argparse
import mmap
import os
import select
import struct
import subprocess
import sys
import time

VENDOR_ID = 0x10EE
DEVICE_ID = 0x903F
BAR_SIZE = 0x100000

# ---------------------------------------------------------------- BAR0 map
REG_MAGIC = 0x000        # 0x55C0F00D
REG_VERSION = 0x004      # major << 16 | minor
REG_BUILD_TIME = 0x008   # Unix time of the bitstream build
REG_SCRATCH = 0x00C      # read/write, no effect
REG_CPU_CTRL = 0x010     # bit0: 1 = hold the CPU in reset
REG_CPU_STATUS = 0x014   # bit0 in reset, bit1 trapped, bit2 clock locked, bit3 reload armed
REG_CPU_PC = 0x018       # address of the CPU's most recent instruction fetch
REG_UPTIME_LO = 0x020    # 100 MHz ticks since configuration (read LO first)
REG_UPTIME_HI = 0x024
REG_TICK_HZ = 0x028      # 100000000
REG_RELOAD = 0x030       # write RELOAD_KEY: reload the FPGA from flash after 1 s
REG_RAM_SIZE = 0x040
REG_SHM_SIZE = 0x044

MAGIC = 0x55C0F00D
RELOAD_KEY = 0x52454C44  # "RELD"

SHM = 0x10000            # shared RAM, CPU address 0x1000_0000
SHM_MBOX = SHM + 0x00    # 8 words
SHM_LOG_WR = SHM + 0x20
SHM_LOG_RD = SHM + 0x24
SHM_IN_WR = SHM + 0x28
SHM_IN_RD = SHM + 0x2C
SHM_FW_MAGIC = SHM + 0x30
SHM_FW_BOOTS = SHM + 0x34
SHM_IN_BUF, SHM_IN_SIZE = SHM + 0x1000, 0x1000
SHM_LOG_BUF, SHM_LOG_SIZE = SHM + 0x2000, 0x2000
FW_MAGIC = 0xC0DE0001

QSPI = 0x40000           # AXI Quad SPI registers (used by u55c-flash / xbflash2)
RAM = 0x80000            # CPU program RAM, CPU address 0x0000_0000
RAM_SIZE = 0x40000

HERE = os.path.dirname(os.path.abspath(__file__))


class CardError(Exception):
    pass


# ---------------------------------------------------------------- device access
def find_devices():
    """Return the PCI addresses (BDFs) of all cards running this image."""
    found = []
    base = "/sys/bus/pci/devices"
    for bdf in sorted(os.listdir(base)):
        try:
            with open(f"{base}/{bdf}/vendor") as f:
                ven = int(f.read(), 16)
            with open(f"{base}/{bdf}/device") as f:
                dev = int(f.read(), 16)
        except OSError:
            continue
        if ven == VENDOR_ID and dev == DEVICE_ID:
            found.append(bdf)
    return found


def normalize_bdf(bdf):
    return bdf if bdf.count(":") == 2 else "0000:" + bdf


class Card:
    """BAR0 of one card. All accesses are aligned 32-bit loads/stores."""

    def __init__(self, bdf=None, check=True):
        if bdf is None:
            devs = find_devices()
            if not devs:
                raise CardError(
                    f"no {VENDOR_ID:04x}:{DEVICE_ID:04x} device found (try: lspci -d {VENDOR_ID:04x}:).\n"
                    "Is the image loaded, and was the host rebooted after loading it?")
            if len(devs) > 1:
                raise CardError(f"several cards found ({', '.join(devs)}); pick one with --bdf")
            bdf = devs[0]
        self.bdf = normalize_bdf(bdf)
        path = f"/sys/bus/pci/devices/{self.bdf}"
        try:
            self._enable_memory(path)
            self.fd = os.open(f"{path}/resource0", os.O_RDWR | os.O_SYNC)
        except PermissionError:
            raise CardError("permission denied: run with sudo")
        except FileNotFoundError:
            raise CardError(f"{path} does not exist")
        self.mm = mmap.mmap(self.fd, BAR_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
        self.words = memoryview(self.mm).cast("I")  # element access = one 32-bit MMIO access
        if check:
            magic = self.rd(REG_MAGIC)
            if magic == 0xFFFFFFFF:
                raise CardError("BAR0 reads all ones: the card is not responding "
                                "(PCIe link down, or the FPGA is reloading). Reboot the host.")
            if magic != MAGIC:
                raise CardError(f"BAR0 magic is 0x{magic:08x}, expected 0x{MAGIC:08x}: wrong image?")

    @staticmethod
    def _enable_memory(path):
        # PCI command register bit 1 = memory space decoding
        with open(f"{path}/config", "r+b", buffering=0) as f:
            f.seek(4)
            cmd = struct.unpack("<H", f.read(2))[0]
            if not cmd & 0x2:
                f.seek(4)
                f.write(struct.pack("<H", cmd | 0x2))

    def rd(self, off):
        return self.words[off >> 2]

    def wr(self, off, val):
        self.words[off >> 2] = val & 0xFFFFFFFF

    def uptime_ticks(self):
        lo = self.rd(REG_UPTIME_LO)   # latches the high word
        return (self.rd(REG_UPTIME_HI) << 32) | lo


# ---------------------------------------------------------------- console helpers
class LogReader:
    """Follows the firmware's log ring in SHM."""

    def __init__(self, card, history=False):
        self.card = card
        wr = card.rd(SHM_LOG_WR)
        self.rd = max(0, wr - SHM_LOG_SIZE) if history else wr

    def poll(self):
        """Return new log text (bytes) since the last call."""
        c = self.card
        wr = c.rd(SHM_LOG_WR)
        out = bytearray()
        if wr < self.rd:
            out += b"\n[u55c: firmware restarted]\n"
            self.rd = 0
        if wr - self.rd > SHM_LOG_SIZE:
            lost = wr - self.rd - SHM_LOG_SIZE
            out += b"\n[u55c: %d log bytes were overwritten before they could be read]\n" % lost
            self.rd = wr - SHM_LOG_SIZE
        word_addr, word = None, 0
        while self.rd < wr:
            pos = self.rd % SHM_LOG_SIZE
            a = SHM_LOG_BUF + (pos & ~3)
            if a != word_addr:
                word_addr, word = a, c.rd(a)
            out.append((word >> (8 * (pos & 3))) & 0xFF)
            self.rd += 1
        if out:
            c.wr(SHM_LOG_RD, self.rd)
        return bytes(out).replace(b"\r", b"")


def send_input(card, data, timeout=2.0):
    """Append bytes to the firmware's input ring."""
    wr = card.rd(SHM_IN_WR)
    t0 = time.time()
    for b in data:
        while wr - card.rd(SHM_IN_RD) >= SHM_IN_SIZE:
            if time.time() - t0 > timeout:
                raise CardError("input ring full: is the firmware reading its console?")
            time.sleep(0.001)
        pos = wr % SHM_IN_SIZE
        a = SHM_IN_BUF + (pos & ~3)
        shift = 8 * (pos & 3)
        card.wr(a, (card.rd(a) & ~(0xFF << shift)) | (b << shift))  # firmware never writes here
        wr = (wr + 1) & 0xFFFFFFFF
    card.wr(SHM_IN_WR, wr)        # publish after the data


# ---------------------------------------------------------------- commands
def cmd_status(card, args):
    st = card.rd(REG_CPU_STATUS)
    ver = card.rd(REG_VERSION)
    bt = card.rd(REG_BUILD_TIME)
    hz = card.rd(REG_TICK_HZ) or 100_000_000
    up = card.uptime_ticks() / hz
    fw_ok = card.rd(SHM_FW_MAGIC) == FW_MAGIC
    if st & 0x2:
        cpu = "TRAPPED (illegal instruction or misaligned access)"
    elif st & 0x1:
        cpu = "held in reset"
    else:
        cpu = "running"
    print(f"device        {card.bdf}")
    print(f"image         magic 0x{card.rd(REG_MAGIC):08x}, version {ver >> 16}.{ver & 0xFFFF}, "
          f"built {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(bt))}")
    print(f"uptime        {up:.3f} s since FPGA configuration")
    print(f"clock         {'locked' if st & 0x4 else 'NOT LOCKED (100 MHz CPU clock missing)'}")
    print(f"cpu           {cpu}, last fetch at 0x{card.rd(REG_CPU_PC):08x}")
    print(f"firmware      {'console active' if fw_ok else 'no console yet'}, "
          f"boots {card.rd(SHM_FW_BOOTS)}, log bytes {card.rd(SHM_LOG_WR)}")
    print(f"reload        {'ARMED' if st & 0x8 else 'idle'}")
    return 0


def read_firmware(path):
    with open(path, "rb") as f:
        data = f.read()
    if path.endswith(".elf") or data[:4] == b"\x7fELF":
        raise CardError("give the .bin file (objcopy -O binary), not the .elf")
    if len(data) > RAM_SIZE:
        raise CardError(f"{path} is {len(data)} bytes; the program RAM is {RAM_SIZE} bytes")
    return data + b"\0" * (-len(data) % 4)


def cmd_load(card, args):
    data = read_firmware(args.file)
    words = struct.unpack(f"<{len(data) // 4}I", data)
    card.wr(REG_CPU_CTRL, 1)                     # hold the CPU
    time.sleep(0.001)
    for i, w in enumerate(words):
        card.wr(RAM + 4 * i, w)
    bad = [i for i, w in enumerate(words) if card.rd(RAM + 4 * i) != w]
    if bad:
        raise CardError(f"RAM readback mismatch at {len(bad)} word(s), first at 0x{4 * bad[0]:05x}")
    print(f"loaded {len(data)} bytes from {args.file} (verified)")
    if args.no_run:
        print("CPU is held in reset; start it with: u55c run")
        return 0
    log = LogReader(card)
    card.wr(REG_CPU_CTRL, 0)
    print("CPU running")
    # show the first output so the user sees the firmware start
    t_end = time.time() + args.wait
    while time.time() < t_end:
        sys.stdout.write(log.poll().decode(errors="replace"))
        sys.stdout.flush()
        time.sleep(0.05)
    return 0


def cmd_run(card, args):
    card.wr(REG_CPU_CTRL, 0)
    print("CPU running")
    return 0


def cmd_reset(card, args):
    card.wr(REG_CPU_CTRL, 1)
    if args.hold:
        print("CPU held in reset (start it with: u55c run)")
        return 0
    time.sleep(0.01)
    card.wr(REG_CPU_CTRL, 0)
    print("CPU reset and restarted")
    return 0


def cmd_log(card, args):
    log = LogReader(card, history=True)
    sys.stdout.write(log.poll().decode(errors="replace"))
    sys.stdout.flush()
    if args.follow:
        try:
            while True:
                sys.stdout.write(log.poll().decode(errors="replace"))
                sys.stdout.flush()
                time.sleep(0.02)
        except KeyboardInterrupt:
            pass
    return 0


def cmd_console(card, args):
    import termios
    import tty
    log = LogReader(card, history=args.history)
    interactive = sys.stdin.isatty() and not args.no_input
    old = None
    if interactive:
        old = termios.tcgetattr(sys.stdin)
        tty.setraw(sys.stdin.fileno())
        sys.stdout.write("[u55c console on %s -- Ctrl-] to quit]\r\n" % card.bdf)
    else:
        print(f"[u55c console on {card.bdf} -- Ctrl-C to quit]")
    try:
        while True:
            text = log.poll()
            if text:
                if interactive:
                    text = text.replace(b"\n", b"\r\n")
                sys.stdout.buffer.write(text)
                sys.stdout.flush()
            if interactive and select.select([sys.stdin], [], [], 0.02)[0]:
                data = os.read(sys.stdin.fileno(), 256)
                if b"\x1d" in data:                       # Ctrl-]
                    break
                send_input(card, data)
            elif not interactive:
                time.sleep(0.02)
    except KeyboardInterrupt:
        pass
    finally:
        if old is not None:
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old)
            print()
    return 0


def cmd_send(card, args):
    log = LogReader(card)
    send_input(card, (" ".join(args.text) + "\r").encode())
    t_end = time.time() + args.wait
    while time.time() < t_end:
        sys.stdout.write(log.poll().decode(errors="replace"))
        sys.stdout.flush()
        time.sleep(0.02)
    return 0


def cmd_mbox(card, args):
    if args.action == "read":
        for i in range(8):
            print(f"MBOX{i} = 0x{card.rd(SHM_MBOX + 4 * i):08x}")
    elif args.action == "write":
        if len(args.values) != 2:
            raise CardError("usage: u55c mbox write INDEX VALUE")
        idx, val = (int(v, 0) for v in args.values)
        card.wr(SHM_MBOX + 4 * idx, val)
    else:  # call
        if not args.values:
            raise CardError("usage: u55c mbox call CMD [ARG1 [ARG2 ...]]")
        vals = [int(v, 0) for v in args.values]
        for i, v in enumerate(vals[1:], start=1):
            card.wr(SHM_MBOX + 4 * i, v)
        card.wr(SHM_MBOX, vals[0])               # command last: starts the request
        t0 = time.time()
        while card.rd(SHM_MBOX) != 0:
            if time.time() - t0 > args.timeout:
                raise CardError("no answer: the firmware did not clear MBOX0 "
                                "(is it running and polling the mailbox?)")
            time.sleep(0.001)
        r = card.rd(SHM_MBOX + 4)
        print(f"0x{r:08x} ({r})")
    return 0


def cmd_peek(card, args):
    off = int(args.offset, 0) & ~3
    for i in range(args.count):
        print(f"BAR0+0x{off + 4 * i:05x} = 0x{card.rd(off + 4 * i):08x}")
    return 0


def cmd_poke(card, args):
    card.wr(int(args.offset, 0) & ~3, int(args.value, 0))
    return 0


def cmd_flash(args):
    tool = os.path.join(HERE, "u55c-flash")
    if not os.path.exists(tool):
        raise CardError(f"{tool} not found: build it first with `make -C {HERE}`")
    cmd = [tool] + (["-d", args.bdf] if args.bdf else []) + args.flash_args
    return subprocess.call(cmd)


def cmd_fpga_reload(card, args):
    if not args.yes:
        print("This reloads the FPGA from flash. The card drops off PCIe for a few\n"
              "seconds; the host only sees it again after a warm reboot (sudo reboot).\n"
              "Make sure the flash holds a good image (u55c flash verify <image.mcs>).\n"
              "Re-run with --yes to proceed.")
        return 1
    card.wr(REG_RELOAD, RELOAD_KEY)
    time.sleep(0.05)
    if not card.rd(REG_CPU_STATUS) & 0x8:
        raise CardError("reload did not arm (is the 100 MHz clock locked? see u55c status)")
    # Detach the device from Linux before the link drops, so the kernel does
    # not treat the disappearance as an error.
    bdf = card.bdf
    card.mm.close()
    os.close(card.fd)
    with open(f"/sys/bus/pci/devices/{bdf}/remove", "w") as f:
        f.write("1")
    print(f"reload armed; {bdf} removed from Linux. The FPGA reconfigures in ~1 s.")
    if args.rescan:
        time.sleep(args.rescan_delay)
        with open("/sys/bus/pci/rescan", "w") as f:
            f.write("1")
        time.sleep(1)
        devs = find_devices()
        if devs:
            print(f"rescan found {', '.join(devs)} -- check it with: u55c status")
            return 0
        print("rescan did not find the card; reboot the host: sudo reboot")
        return 1
    print("Now reboot the host to see the new image:  sudo reboot")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="u55c", description=__doc__.split("\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--bdf", help="PCI address, e.g. 0000:01:00.0 (default: auto-detect)")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status", help="image, CPU and firmware state")

    s = sub.add_parser("load", help="hold the CPU, copy a firmware .bin into RAM, start it")
    s.add_argument("file")
    s.add_argument("--no-run", action="store_true", help="leave the CPU held in reset")
    s.add_argument("--wait", type=float, default=1.0, help="seconds of log to show after start")

    sub.add_parser("run", help="release the CPU from reset")
    s = sub.add_parser("reset", help="reset the CPU (restart the firmware in RAM)")
    s.add_argument("--hold", action="store_true", help="keep it in reset")

    s = sub.add_parser("console", help="live firmware console (log + keyboard input)")
    s.add_argument("--history", action="store_true", help="first print the buffered log")
    s.add_argument("--no-input", action="store_true", help="only show output")

    s = sub.add_parser("log", help="print the buffered firmware log (up to 8 KB)")
    s.add_argument("-f", "--follow", action="store_true", help="keep printing new output")

    s = sub.add_parser("send", help="type one line into the firmware console")
    s.add_argument("text", nargs="+")
    s.add_argument("--wait", type=float, default=0.5, help="seconds of reply to show")

    s = sub.add_parser("mbox", help="mailbox registers: read | write IDX VAL | call CMD [ARGS]")
    s.add_argument("action", choices=["read", "write", "call"])
    s.add_argument("values", nargs="*")
    s.add_argument("--timeout", type=float, default=1.0)

    s = sub.add_parser("peek", help="read BAR0 registers")
    s.add_argument("offset")
    s.add_argument("count", nargs="?", type=int, default=1)
    s = sub.add_parser("poke", help="write a BAR0 register")
    s.add_argument("offset")
    s.add_argument("value")

    s = sub.add_parser("flash", help="config flash: id | program IMG | verify IMG | read OUT ADDR LEN")
    s.add_argument("flash_args", nargs=argparse.REMAINDER)

    s = sub.add_parser("fpga-reload", help="reconfigure the FPGA from flash")
    s.add_argument("--yes", action="store_true", help="really do it")
    s.add_argument("--rescan", action="store_true",
                   help="try a PCI rescan instead of rebooting (may not work on every host)")
    s.add_argument("--rescan-delay", type=float, default=5.0)

    args = p.parse_args(argv)
    try:
        if args.cmd == "flash":
            return cmd_flash(args)
        card = Card(args.bdf)
        return globals()["cmd_" + args.cmd.replace("-", "_")](card, args)
    except CardError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
