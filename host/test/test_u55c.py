"""Unit tests for host/u55c.py using an in-memory fake BAR0 (no card needed).

    python3 host/test/test_u55c.py
"""
import io
import os
import sys
import threading
import time
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import u55c  # noqa: E402


class FakeCard(u55c.Card):
    def __init__(self):
        self.bdf = "0000:99:00.0"
        self.buf = bytearray(u55c.BAR_SIZE)
        self.words = memoryview(self.buf).cast("I")
        self.wr(u55c.REG_MAGIC, u55c.MAGIC)


def fw_log(card, text):
    """Append text to the log ring the way the firmware does."""
    wr = card.rd(u55c.SHM_LOG_WR)
    for b in text:
        pos = wr % u55c.SHM_LOG_SIZE
        card.buf[u55c.SHM_LOG_BUF + pos] = b
        wr += 1
    card.wr(u55c.SHM_LOG_WR, wr)


def fw_read_input(card):
    out = bytearray()
    rd = card.rd(u55c.SHM_IN_RD)
    while rd != card.rd(u55c.SHM_IN_WR):
        out.append(card.buf[u55c.SHM_IN_BUF + rd % u55c.SHM_IN_SIZE])
        rd += 1
    card.wr(u55c.SHM_IN_RD, rd)
    return bytes(out)


class LogTests(unittest.TestCase):
    def test_basic_and_cr_stripping(self):
        c = FakeCard()
        log = u55c.LogReader(c)
        fw_log(c, b"hello\r\nworld\r\n")
        self.assertEqual(log.poll(), b"hello\nworld\n")
        self.assertEqual(log.poll(), b"")
        self.assertEqual(c.rd(u55c.SHM_LOG_RD), 14)

    def test_wraparound(self):
        c = FakeCard()
        fw_log(c, b"x" * (u55c.SHM_LOG_SIZE - 3))
        log = u55c.LogReader(c)
        fw_log(c, b"abcdefg")
        self.assertEqual(log.poll(), b"abcdefg")

    def test_history(self):
        c = FakeCard()
        fw_log(c, b"boot banner\n")
        self.assertEqual(u55c.LogReader(c, history=True).poll(), b"boot banner\n")
        self.assertEqual(u55c.LogReader(c).poll(), b"")

    def test_overflow_reported(self):
        c = FakeCard()
        log = u55c.LogReader(c)
        fw_log(c, b"y" * (u55c.SHM_LOG_SIZE + 100))
        out = log.poll()
        self.assertIn(b"100 log bytes were overwritten", out)
        self.assertTrue(out.endswith(b"y" * u55c.SHM_LOG_SIZE))

    def test_restart_detected(self):
        c = FakeCard()
        log = u55c.LogReader(c)
        fw_log(c, b"first run\n")
        log.poll()
        c.wr(u55c.SHM_LOG_WR, 0)                 # firmware console_init()
        fw_log(c, b"second\n")
        out = log.poll()
        self.assertIn(b"firmware restarted", out)
        self.assertTrue(out.endswith(b"second\n"))


class InputTests(unittest.TestCase):
    def test_send_and_wrap(self):
        c = FakeCard()
        start = u55c.SHM_IN_SIZE - 2
        c.wr(u55c.SHM_IN_WR, start)
        c.wr(u55c.SHM_IN_RD, start)
        u55c.send_input(c, b"help\r")
        self.assertEqual(fw_read_input(c), b"help\r")

    def test_ring_full_times_out(self):
        c = FakeCard()
        with self.assertRaises(u55c.CardError):
            u55c.send_input(c, b"z" * (u55c.SHM_IN_SIZE + 1), timeout=0.05)


class MailboxTests(unittest.TestCase):
    def test_call(self):
        c = FakeCard()
        stop = False

        def firmware():
            while not stop:
                if c.rd(u55c.SHM_MBOX) == 2:
                    c.wr(u55c.SHM_MBOX + 4, c.rd(u55c.SHM_MBOX + 4) + c.rd(u55c.SHM_MBOX + 8))
                    c.wr(u55c.SHM_MBOX, 0)
                time.sleep(0.001)

        t = threading.Thread(target=firmware)
        t.start()
        args = u55c.argparse.Namespace(action="call", values=["2", "5", "0x10"], timeout=1.0)
        out = io.StringIO()
        with redirect_stdout(out):
            u55c.cmd_mbox(c, args)
        stop = True
        t.join()
        self.assertIn("(21)", out.getvalue())

    def test_call_timeout(self):
        c = FakeCard()
        args = u55c.argparse.Namespace(action="call", values=["1", "1"], timeout=0.05)
        with self.assertRaises(u55c.CardError):
            u55c.cmd_mbox(c, args)


class LoadTests(unittest.TestCase):
    def test_load_copies_and_releases(self):
        c = FakeCard()
        path = os.path.join(os.environ.get("TMPDIR", "/tmp"), "u55c_test_fw.bin")
        with open(path, "wb") as f:
            f.write(bytes(range(10)))
        args = u55c.argparse.Namespace(file=path, no_run=False, wait=0)
        with redirect_stdout(io.StringIO()):
            u55c.cmd_load(c, args)
        os.unlink(path)
        self.assertEqual(c.buf[u55c.RAM:u55c.RAM + 12], bytes(range(10)) + b"\0\0")
        self.assertEqual(c.rd(u55c.REG_CPU_CTRL), 0)

    def test_status_runs(self):
        c = FakeCard()
        c.wr(u55c.REG_CPU_STATUS, 0x4)
        with redirect_stdout(io.StringIO()) as out:
            u55c.cmd_status(c, None)
        self.assertIn("running", out.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=1)
