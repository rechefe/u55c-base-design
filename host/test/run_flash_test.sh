#!/bin/bash
# Exercises u55c-flash against the simulated controller + flash (flash_sim.c).
set -euo pipefail
cd "$(dirname "$0")"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export SIM_FLASH_FILE=$T/flash.img
TOOL=../flash_test

echo "== id"
$TOOL id | grep -q "20 bb 21" && echo ok

echo "== program + verify a 3 MB .mcs at address 0"
head -c 3000000 /dev/urandom > $T/img.bin
python3 -I make_mcs.py $T/img.bin $T/img.mcs 0
$TOOL program $T/img.mcs
$TOOL verify $T/img.mcs

echo "== read back and compare"
$TOOL read $T/back.bin 0 3000000
cmp $T/img.bin $T/back.bin && echo ok

echo "== .bin crossing the 16 MB bank boundary, unaligned address"
head -c 200000 /dev/urandom > $T/b.bin
$TOOL program $T/b.bin -a 0xFF0123
$TOOL read $T/b_back.bin 0xFF0123 200000
cmp $T/b.bin $T/b_back.bin && echo ok

echo "== first image untouched"
$TOOL verify $T/img.mcs

echo "== 4 KB erase fallback when 0xD8 is rejected"
head -c 100000 /dev/urandom > $T/c.bin
SIM_REJECT_D8=1 $TOOL program $T/c.bin -a 0x2000000
$TOOL verify $T/c.bin -a 0x2000000

echo "== verify detects a mismatch"
head -c 1000 /dev/urandom > $T/d.bin
if $TOOL verify $T/d.bin -a 0x3000000 2>/dev/null; then echo "FAIL: mismatch not detected"; exit 1; fi
echo ok

echo "ALL FLASH TESTS PASSED"
