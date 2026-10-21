# U55C RISC-V image: guide

1. [Hardware](#1-hardware)
2. [Register reference](#2-register-reference)
3. [Operation flows](#3-operation-flows)
4. [Building](#4-building)
5. [Firmware](#5-firmware)
6. [Host tools](#6-host-tools)
7. [Reprogramming the card](#7-reprogramming-the-card)
8. [Troubleshooting](#8-troubleshooting)

> **Lab machine rule:** never run `poweroff` or `shutdown` on the lab machine. Nothing can switch it back on remotely. Every procedure here uses a warm reboot (`sudo reboot`).

---

## 1. Hardware

### 1.1 Block diagram

```
 PCIe x16 ──► XDMA (Gen3 x16) ──BAR0, AXI4-Lite, 250 MHz──► host_if ─┬─► control/status registers
                │                                                    ├─► SHM 16 KB  (port A) ◄──┐
                └─ DMA master: unused, terminated (axi_null)          ├─► RAM 256 KB (port A) ◄──┤ port B
                                                                     └─► AXI Quad SPI ─► STARTUPE3 ─► MT25QU01G flash
                                                                                                │
 SI5394 161.13 MHz ─► MMCM ─┬─ 100 MHz ─► cpu_subsys: PicoRV32 + UART + timer + LEDs ─────────┘
                            │                         └─► ICAPE3 (reload from flash)
                            └─ 49.3 MHz ─► SPI clock (SCK ≈ 24.7 MHz)
```

`host_if` serves the PCIe side; `cpu_subsys` serves the CPU side. They share two dual-port RAMs: the program RAM and the shared memory (SHM). Each RAM has one port per clock domain, so neither side waits for the other.

### 1.2 Components

| Block | File | Description |
|---|---|---|
| `u55c_top` | `hw/rtl/u55c_top.v` | Pins, clocks, XDMA, AXI Quad SPI, `HBM_CATTRIP` tie-off |
| `u55c_core` | `hw/rtl/u55c_core.v` | RAMs, CPU subsystem, host window, reload, clock crossings (simulated by `hw/sim/tb.v`) |
| `host_if` | `hw/rtl/host_if.v` | BAR0 AXI4-Lite slave: address decode, control registers, RAM/SHM port A, forwarding to the flash controller |
| `cpu_subsys` | `hw/rtl/cpu_subsys.v` | PicoRV32, its memory bus, UART, timer, LEDs |
| `iprog` | `hw/rtl/iprog.v` | Writes the IPROG command sequence to ICAPE3 |
| `cdc_snapshot`, `sync_bits` | `hw/rtl/cdc.v` | Clock-domain crossing |
| `tdp_ram` | `hw/rtl/tdp_ram.v` | Dual-clock, byte-writable block RAM |
| `axi_null` | `hw/rtl/axi_null.v` | Answers the unused XDMA DMA port |

### 1.3 CPU

| Property | Value |
|---|---|
| Core | PicoRV32 (`hw/third_party/picorv32.v`, YosysHQ) |
| ISA | RV32IMC; no interrupts, no CSRs except the cycle counters |
| Clock | 100 MHz |
| Reset vector | `0x0000_0000` |
| Memory latency | 1 wait state for RAM, SHM and IO |
| Traps | Illegal instruction or misaligned access stops the CPU; `CPU_STATUS.TRAP` goes high |

### 1.4 PCIe identity

| Field | Value |
|---|---|
| Vendor:Device | `10ee:903f` |
| Class | `1200` (processing accelerator) |
| BAR0 | 1 MB, 32-bit, non-prefetchable: the register window in this guide |
| BAR1 | XDMA DMA engine registers; unused |
| Link | Gen3 (8 GT/s) x16 |

Find the card with `lspci -d 10ee:903f`.

### 1.5 Clocks and resets

| Clock | Source | Frequency | Used by |
|---|---|---|---|
| `axi_aclk` | XDMA (PCIe) | 250 MHz | `host_if`, RAM/SHM port A, AXI Quad SPI registers |
| `clk100` | SI5394 161.13 MHz → MMCM | 100 MHz | CPU, UART, timer, ICAPE3 |
| `clk50` | same MMCM | 49.3 MHz | AXI Quad SPI serial clock (`ext_spi_clk`) |

| Reset | Asserted when | Resets |
|---|---|---|
| PCIe reset (`axi_aresetn`) | Host reboot, link down | `host_if` registers, including `CPU_CTRL` (so a host reboot releases a held CPU) |
| `rst100` | MMCM not locked | Whole CPU subsystem, timer |
| CPU reset | `CPU_CTRL.HOLD = 1`, or `rst100` | PicoRV32 only |

The CPU clock is independent of PCIe. The firmware keeps running, and its log keeps filling, through a warm reboot of the host.

### 1.6 What survives what

| Event | FPGA image | Program RAM | SHM (log, mailboxes) | CPU |
|---|---|---|---|---|
| `u55c reset` | kept | kept | kept | restarts at `0x0` |
| Warm reboot (`sudo reboot`) | kept | kept | kept | keeps running |
| JTAG load or `fpga-reload` | replaced | reinitialized with the built-in demo firmware | cleared | starts the demo |
| Power off | lost; reloaded from flash at power-on | reinitialized | cleared | starts the demo |

### 1.7 Board connections

| Signal | Pin | Notes |
|---|---|---|
| PCIe refclk | `AR15`/`AR14` | 100 MHz from the slot |
| PCIe `PERST#` | `BF41` | |
| 161 MHz reference | `AD42`/`AD43` | SI5394 OUT0, runs from power-up |
| `uart_txd[0]` / `uart_rxd[0]` | `BJ41` / `BK41` | FT4232H channel C |
| `uart_txd[1]` / `uart_rxd[1]` | `BN47` / `BP47` | FT4232H channel D |
| `led[5:0]` | `BL13 BK11 BJ11 BK14 BK15 BL12` | QSFP activity/status LEDs |
| `HBM_CATTRIP` | `BE45` | Driven low. The satellite controller powers the card off if it goes high. |

Pin locations come from the open-source [taxi](https://github.com/fpganinja/taxi) AU55C constraints (MIT).

---

## 2. Register reference

All host accesses are aligned 32-bit reads and writes on BAR0. Unmapped addresses read `0` and ignore writes.

### 2.1 BAR0 map (host view)

| BAR0 offset | Size | Region | CPU address |
|---|---|---|---|
| `0x00000` | 4 KB | Control/status registers | — |
| `0x10000` | 16 KB | SHM: mailboxes and console rings | `0x1000_0000` |
| `0x40000` | 128 B | AXI Quad SPI (flash controller) | — |
| `0x80000` | 256 KB | Program RAM | `0x0000_0000` |

### 2.2 Control/status registers (BAR0 + `0x000`)

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| `0x000` | `MAGIC` | RO | `0x55C0F00D` | Identifies this image |
| `0x004` | `VERSION` | RO | `0x00010000` | `[31:16]` major, `[15:0]` minor |
| `0x008` | `BUILD_TIME` | RO | build | Unix time of the Vivado build |
| `0x00C` | `SCRATCH` | RW | `0` | No effect; for testing access |
| `0x010` | `CPU_CTRL` | RW | `0` | bit 0 `HOLD`: 1 holds the CPU in reset |
| `0x014` | `CPU_STATUS` | RO | — | bit 0 `IN_RESET`, bit 1 `TRAP`, bit 2 `CLK_LOCKED`, bit 3 `RELOAD_ARMED` |
| `0x018` | `CPU_PC` | RO | — | Address of the CPU's most recent instruction fetch |
| `0x020` | `UPTIME_LO` | RO | — | 100 MHz ticks since configuration, bits `[31:0]`. Reading it latches `UPTIME_HI`. |
| `0x024` | `UPTIME_HI` | RO | — | Bits `[63:32]`, as latched by the last `UPTIME_LO` read |
| `0x028` | `TICK_HZ` | RO | `100000000` | Uptime tick rate |
| `0x030` | `RELOAD` | RW | `0` | Write `0x52454C44` ("RELD") to reload the FPGA from flash 1 s later. Other values are ignored. Read: bit 0 = armed. |
| `0x040` | `RAM_SIZE` | RO | `0x40000` | Program RAM size in bytes |
| `0x044` | `SHM_SIZE` | RO | `0x4000` | SHM size in bytes |

`CPU_STATUS`, `CPU_PC` and the uptime cross from the 100 MHz domain and lag by a few clock cycles. If the 100 MHz clock stops, they keep their last values and `CLK_LOCKED` reads 0.

### 2.3 Shared memory (SHM)

Host: BAR0 + `0x10000` + offset. CPU: `0x1000_0000` + offset. Both sides can read and write everything; the table says who writes each field.

| Offset | Name | Written by | Description |
|---|---|---|---|
| `0x00`–`0x1C` | `MBOX0`–`MBOX7` | both | Mailbox words (see [3.3](#33-mailbox-request)) |
| `0x20` | `LOG_WR` | firmware | Total bytes written to the log ring |
| `0x24` | `LOG_RD` | host | Total bytes the host has read (informational) |
| `0x28` | `IN_WR` | host | Total bytes written to the input ring |
| `0x2C` | `IN_RD` | firmware | Total bytes the firmware has consumed |
| `0x30` | `FW_MAGIC` | firmware | `0xC0DE0001` once the firmware console is initialized |
| `0x34` | `FW_BOOTS` | firmware | Incremented at each firmware start |
| `0x1000` | `IN_BUF` | host | Input ring, 4 KB |
| `0x2000` | `LOG_BUF` | firmware | Log ring, 8 KB |

The ring counters only increase; the byte for counter value `n` is at `BUF[n % size]`.

### 2.4 Flash controller (BAR0 + `0x40000`)

An AMD AXI Quad SPI v3.2 core (PG153) in quad mode with Micron command support, a 256-byte FIFO, AXI4-Lite, and no XIP. It drives the MT25QU01G (1 Gbit) configuration flash through STARTUPE3. AMD's `xbflash2` tool expects this layout by default (`--bar 0 --bar-offset 0x40000`).

| Offset | Register |
|---|---|
| `0x40` | `SRR`: write `0x0A` to reset the core |
| `0x60` | `SPICR`: control |
| `0x64` | `SPISR`: status |
| `0x68` | `SPI_DTR`: transmit FIFO |
| `0x6C` | `SPI_DRR`: receive FIFO |
| `0x70` | `SPISSR`: chip select (`0xFFFFFFFE` selects the flash) |
| `0x74` / `0x78` | TX / RX FIFO occupancy |

### 2.5 CPU memory map

| Address | Size | Region |
|---|---|---|
| `0x0000_0000` | 256 KB | Program RAM: code, data, stack (stack top `0x0004_0000`) |
| `0x1000_0000` | 16 KB | SHM ([2.3](#23-shared-memory-shm)) |
| `0x2000_0000` | 256 B | IO registers (below) |

| IO offset | Name | Access | Description |
|---|---|---|---|
| `0x00` | `UART_DATA` | W | Queue one byte (`[7:0]`) for transmission on both UARTs |
| `0x00` | `UART_DATA` | R | bit 31 = byte valid, `[7:0]` = received byte; the read removes it from the RX FIFO |
| `0x04` | `UART_STAT` | R | bit 0 TX FIFO full, bit 1 RX byte available, bit 2 TX idle |
| `0x08` | `TIME_LO` | R | 100 MHz counter since configuration, bits `[31:0]` |
| `0x0C` | `TIME_HI` | R | Bits `[63:32]` (read HI, LO, HI to get a consistent value) |
| `0x10` | `LED` | RW | `[5:0]` drive the six QSFP LEDs |
| `0x14` | `CLK_HZ` | R | `100000000` |

The UART is 115200 baud, 8N1, with a 256-byte TX FIFO and a 64-byte RX FIFO. Both FPGA UARTs carry the same TX stream; bytes received on either one go into the same RX FIFO.

---

## 3. Operation flows

### 3.1 Console output (firmware → host)

1. Firmware writes the byte to `LOG_BUF[LOG_WR % 8192]`.
2. Firmware increments `LOG_WR`. Writing the counter after the byte means the host never reads a byte before it is complete.
3. Firmware also queues the byte on the UART.
4. The host polls `LOG_WR` every 20 ms and reads the bytes between its own read counter and `LOG_WR`.

The log ring holds the last 8 KB. If the host falls more than 8 KB behind, the oldest bytes are lost; `u55c console` reports how many. When the firmware restarts it sets `LOG_WR` to 0; the host sees the counter go backwards and starts reading from 0 again.

Each `printf` waits while the UART TX FIFO is full, so sustained output is limited to the UART rate, about 11.5 KB/s.

### 3.2 Console input (host → firmware)

1. The host writes the byte to `IN_BUF[IN_WR % 4096]`.
2. The host increments `IN_WR`.
3. The firmware's `console_getc()` reads a byte when `IN_RD != IN_WR`, then increments `IN_RD`. If the ring is empty, it reads the UART RX FIFO instead.

At start-up the firmware sets `IN_RD = IN_WR`, discarding input that arrived before it ran.

### 3.3 Mailbox request

The demo firmware polls the mailbox in its main loop. A request:

1. The host writes the arguments to `MBOX1`–`MBOX7`.
2. The host writes the command number to `MBOX0`. This starts the request.
3. The firmware runs the command, writes the result to `MBOX1`, then writes 0 to `MBOX0`.
4. The host polls `MBOX0` until it reads 0, then reads `MBOX1`.

Demo firmware commands:

| `MBOX0` | Name | Result in `MBOX1` |
|---|---|---|
| 1 | ping | `MBOX1 + 1` |
| 2 | add | `MBOX1 + MBOX2` |
| 3 | peek | 32-bit word at CPU address `MBOX1` |
| 4 | time | Milliseconds since configuration |
| other | — | `0xFFFFFFFF` |

### 3.4 Loading firmware

1. The host writes `CPU_CTRL = 1`. The CPU stops.
2. The host writes the firmware image to BAR0 + `0x80000` (CPU address 0) and reads it back to verify it.
3. The host writes `CPU_CTRL = 0`. The CPU starts at address 0.

The bitstream also contains the demo firmware as the RAM's initial contents, so the CPU runs it immediately after every configuration.

### 3.5 FPGA reload from flash

1. The host writes `0x52454C44` to `RELOAD`. `CPU_STATUS.RELOAD_ARMED` goes high.
2. `u55c fpga-reload` removes the device from Linux (`/sys/bus/pci/devices/<BDF>/remove`), so the kernel does not treat the link loss as an error.
3. After 1 s, `iprog` sends the IPROG sequence to ICAPE3 (`WBSTAR = 0`, `CMD = IPROG`).
4. The FPGA reconfigures from flash address 0. The PCIe link drops and comes back with the new image.
5. The host finds the new device after a warm reboot.

---

## 4. Building

Run these on the build server, from the repository root.

### 4.1 Prerequisites

| Tool | Location | Used for |
|---|---|---|
| Vivado 2024.2 | `/tools/xilinx/2024.2` (set `VIVADO=` to override) | Bitstream, simulation (xsim) |
| Xilinx licence | `2600@132.70.224.181:2100@enicsw01` (set in the Makefile) | `xcu55c` needs an Enterprise licence |
| RISC-V GCC | xPack 14.2.0-3, downloaded to `tools/` by `make -C fw toolchain` | Firmware |
| Python 3, gcc | system | Firmware hex conversion, host tools |

### 4.2 Targets

| Command | Output | Time |
|---|---|---|
| `make fw` | `fw/build/demo.{elf,bin,hex}` | seconds |
| `make sim` | `build/sim/xsim.log`, ends with `TB PASS` | ~30 s |
| `make -C host test` | Unit tests of `u55c.py` and `u55c-flash` (simulated flash) | seconds |
| `make bitstream` | `build/hw/u55c_riscv.{bit,mcs,bin}`, `build/hw/reports/` | 1–2 hours |
| `make release` | `build/release/u55c-riscv.tar.gz` | seconds |

`make bitstream` embeds `fw/build/demo.hex` as the RAM's initial contents. It stops with an error if timing is not met; set `ALLOW_TIMING_FAIL=1` to write the bitstream anyway. Check `build/hw/reports/timing_summary.rpt` and `build/hw/build_info.txt`.

### 4.3 Release contents

| Path in the tarball | Contents |
|---|---|
| `bitstream/u55c_riscv.bit` | For JTAG loading |
| `bitstream/u55c_riscv.mcs` | For flash programming |
| `bitstream/jtag_program.tcl`, `jtag_flash.tcl` | Vivado Lab scripts |
| `fw/demo.bin`, `fw/demo.elf` | Demo firmware |
| `fw/src/` | Firmware sources and Makefile |
| `host/` | `u55c`, `u55c.py`, `u55c_flash.c`, Makefile, tests |
| `docs/`, `README.md` | Documentation |

---

## 5. Firmware

### 5.1 Layout

| File | Contents |
|---|---|
| `fw/lib/start.S` | Reset entry: sets `gp` and `sp`, clears `.bss`, calls `main` |
| `fw/lib/link.ld` | Places everything in the 256 KB RAM; reserves 16 KB for the stack |
| `fw/lib/u55c.h` | Register map and API |
| `fw/lib/u55c.c` | Console, time, small libc |
| `fw/lib/printf.c` | `printf`, `snprintf` |
| `fw/apps/<name>/*.c` | One directory per application; `demo` is the default |

The firmware uses no C library. `fw/lib` provides `memset`, `memcpy`, `strlen`, `strcmp`, `strncmp`, `strtoul`.

### 5.2 Build

```sh
make -C fw                  # builds apps/demo -> fw/build/demo.bin
make -C fw APP=myapp        # builds apps/myapp/*.c -> fw/build/myapp.bin
make -C fw build/demo.lst   # disassembly listing
```

The first build downloads the compiler (about 200 MB) into `tools/`. On the lab machine, run `make -C fw/src toolchain` once.

### 5.3 API (`u55c.h`)

| Function | Description |
|---|---|
| `void console_init(void)` | Resets the log counter, discards old input, increments `FW_BOOTS`, sets `FW_MAGIC`. Call first. |
| `int printf(const char *fmt, ...)` | Formatted output to the log ring and both UARTs. Supports `%d %i %u %x %X %p %s %c %%`, `-`/`0` flags, width, `l`/`ll`. |
| `int puts(const char *s)`, `int putchar(int c)` | Same destinations as `printf` |
| `void console_write(const char *s, size_t n)` | Writes `n` bytes |
| `int console_getc(void)` | Next input byte from the PCIe input ring or the UART; `-1` if none. Does not block. |
| `int console_readline(char *buf, size_t size)` | Line editor with echo and backspace. Returns 1 when a full line is in `buf`, else 0. Does not block. |
| `uint64_t time_ticks(void)` | 100 MHz ticks since configuration |
| `uint32_t time_ms(void)` | Milliseconds since configuration |
| `void delay_us(uint32_t us)` | Busy-wait |
| `SHM_MBOX(n)`, `IO_LED`, … | Register macros (see `u55c.h`) |

`\n` is sent as `\r\n`.

### 5.4 Minimal application

`fw/apps/hello/main.c`:

```c
#include "u55c.h"

int main(void)
{
    console_init();
    printf("hello from RISC-V, uptime %u ms\n", (unsigned)time_ms());
    for (;;) {
        delay_us(1000000);
        printf("tick\n");
    }
}
```

```sh
make -C fw APP=hello
sudo host/u55c load fw/build/hello.bin
```

### 5.5 Debugging

- `sudo host/u55c status` shows `CPU_PC`, the address of the most recent instruction fetch. Find it in `fw/build/<app>.lst`.
- A trap (illegal instruction, misaligned access, jump to garbage) stops the CPU and sets `TRAP`. `CPU_PC` points near the faulting instruction. Restart with `u55c reset` or load new firmware.
- `int32_t`/`uint32_t` are `long` on this compiler: cast to `unsigned` for `%u`, or use `%lu`.

---

## 6. Host tools

### 6.1 Setup on the lab machine

```sh
tar xzf u55c-riscv.tar.gz && cd u55c-riscv
sudo apt install python3 gcc make      # if missing
make -C host                           # builds host/u55c-flash
lspci -d 10ee:903f                     # the card, once the image is loaded
```

All commands need root, because they map the card's BAR0 through `/sys`.

### 6.2 Commands

Global option: `--bdf 0000:XX:00.0` picks a card when several are present; by default the tool finds the `10ee:903f` device.

| Command | Description |
|---|---|
| `u55c status` | Image version and build time, uptime, clock lock, CPU state and `CPU_PC`, firmware boots, reload state |
| `u55c load FILE.bin [--no-run] [--wait S]` | Hold the CPU, copy and verify the image, start it, show `S` seconds (default 1) of output |
| `u55c run` | Release the CPU (`CPU_CTRL = 0`) |
| `u55c reset [--hold]` | Restart the firmware in RAM; `--hold` leaves the CPU stopped |
| `u55c console [--history] [--no-input]` | Live console: prints the log and sends your keystrokes. `Ctrl-]` quits. `--history` first prints the buffered log. |
| `u55c log [-f]` | Print the buffered log (up to 8 KB); `-f` keeps following |
| `u55c send TEXT…` | Type one line (adds Enter) and show 0.5 s of reply |
| `u55c mbox read` | Print `MBOX0`–`MBOX7` |
| `u55c mbox write IDX VAL` | Write one mailbox word |
| `u55c mbox call CMD [ARGS…]` | Mailbox request ([3.3](#33-mailbox-request)); prints `MBOX1` |
| `u55c peek OFF [COUNT]`, `u55c poke OFF VAL` | Raw BAR0 access |
| `u55c flash id` | Read the flash JEDEC ID (expect `20 bb 21 …`) |
| `u55c flash program IMG.mcs` | Erase, program and verify the flash |
| `u55c flash verify IMG.mcs` | Compare the flash with an image |
| `u55c flash read OUT.bin ADDR LEN` | Dump flash contents |
| `u55c fpga-reload --yes [--rescan]` | Reload the FPGA from flash ([3.5](#35-fpga-reload-from-flash)) |

Example session:

```text
$ sudo ./host/u55c status
device        0000:01:00.0
image         magic 0x55c0f00d, version 1.0, built 2026-10-21 20:30:00 UTC
uptime        42.118 s since FPGA configuration
clock         locked
cpu           running, last fetch at 0x00000604
firmware      console active, boots 1, log bytes 191
reload        idle

$ sudo ./host/u55c mbox call 2 5 7
0x0000000c (12)

$ sudo ./host/u55c send help
help
commands:
  help              this text
  ...
```

### 6.3 Serial console

The firmware prints the same text on the card's USB serial port. The FT4232H behind the micro-USB port provides four channels: channel A is JTAG, channels C and D are the FPGA UARTs. On the lab machine they are expected at `/dev/ttyUSB2` and `/dev/ttyUSB3`; try both.

```sh
sudo screen /dev/ttyUSB2 115200       # Ctrl-A then K quits
```

Typing in the serial terminal also reaches the firmware console.

### 6.4 How the host tool reaches the card

Linux exposes each PCIe BAR of a device as a file: `/sys/bus/pci/devices/<BDF>/resource0` is BAR0. `u55c.py` opens that file and maps it with `mmap`. A 32-bit load or store at an offset in the mapping becomes a PCIe read or write to that BAR0 offset. XDMA turns it into an AXI4-Lite transaction, and `host_if` answers it.

- **No kernel driver needed:** the card shows no driver in `lspci -k`.
- **Root required:** mapping `resource0` needs root. Secure Boot / kernel lockdown would block it; it is off on the lab machine.
- **Memory decoding:** the tools set bit 1 of the PCI command register (memory decoding) if the BIOS left it off.
- **Access width:** every access is a single aligned 32-bit load or store.

`u55c-flash` uses the same mechanism from C.

### 6.5 Python API (`host/u55c.py`)

Import `u55c.py` to script the card:

```python
import sys; sys.path.insert(0, "host")
import u55c

card = u55c.Card()                     # finds 10ee:903f, maps BAR0, checks MAGIC
print(hex(card.rd(u55c.REG_CPU_STATUS)))
card.wr(u55c.SHM_MBOX + 4, 41)         # MBOX1 = 41
card.wr(u55c.SHM_MBOX, 1)              # MBOX0 = ping
while card.rd(u55c.SHM_MBOX):
    pass
print(card.rd(u55c.SHM_MBOX + 4))      # 42

log = u55c.LogReader(card)             # follows the log ring
u55c.send_input(card, b"uptime\r")
```

| Item | Description |
|---|---|
| `Card(bdf=None, check=True)` | Open a card. Raises `CardError` if it is missing, not responding (`0xFFFFFFFF`), or has the wrong `MAGIC`. |
| `Card.rd(off)` / `Card.wr(off, val)` | 32-bit BAR0 read / write |
| `Card.uptime_ticks()` | 64-bit uptime |
| `LogReader(card, history=False)` | `poll()` returns new log bytes since the last call (`\r` removed) |
| `send_input(card, data)` | Append bytes to the input ring |
| `find_devices()` | BDFs of all cards with this image |
| `REG_*`, `SHM_*`, `RAM`, `QSPI` | Offsets from [section 2](#2-register-reference) |

### 6.6 C access

```c
int fd = open("/sys/bus/pci/devices/0000:01:00.0/resource0", O_RDWR | O_SYNC);
volatile uint32_t *bar = mmap(NULL, 0x100000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
uint32_t magic = bar[0x000 / 4];          /* 0x55C0F00D */
bar[0x010 / 4] = 1;                        /* CPU_CTRL.HOLD = 1 */
```

`host/u55c_flash.c` is a complete example.

---

## 7. Reprogramming the card

The flash on the card holds a different design today. That design has no PCIe flash access, so the first load uses JTAG.

### 7.1 First bring-up over JTAG (flash untouched)

1. Copy `u55c-riscv.tar.gz` to the lab machine and unpack it.
2. Build the flash tool: `make -C host`.
3. Load the bitstream into the FPGA:
   ```sh
   vivado_lab -mode batch -source bitstream/jtag_program.tcl -tclargs bitstream/u55c_riscv.bit
   ```
   The card drops off PCIe during this step; your BIOS settings keep the host from crashing.
4. Warm-reboot the host: `sudo reboot`. The FPGA keeps the image; the BIOS enumerates the new device.
5. Check the device: `lspci -d 10ee:903f -vv | grep -E 'LnkSta|Region 0'`. Expect `Speed 8GT/s, Width x16`.
6. Check the image: `sudo host/u55c status`. Expect `clock locked` and `cpu running`.
7. Read the boot messages: `sudo host/u55c log`. Expect the `=== U55C PicoRV32 demo firmware ===` banner.
8. Open the console: `sudo host/u55c console`. Type `help`, Enter. `Ctrl-]` quits.
9. Read the flash ID: `sudo host/u55c flash id`. Expect `20 bb 21 …`.

The image is in the FPGA only. A power loss brings back the old design from flash.

### 7.2 Writing the flash over PCIe

1. Write and verify the image:
   ```sh
   sudo host/u55c flash program bitstream/u55c_riscv.mcs
   ```
   The tool erases 64 KB sectors over the image range, programs 128-byte chunks (skipping all-`0xFF` chunks), then reads everything back. It ends with `DONE … flash programmed and verified.` Expect several minutes.
2. If it is interrupted, run the same command again. The running FPGA image is unaffected until a reload or power cycle.

Alternative: AMD's `xbflash2` (separate download from the U55C page on amd.com; no XRT needed):

```sh
sudo xbflash2 program --spi --image bitstream/u55c_riscv.mcs --device 0000:01:00.0 --bar 0 --bar-offset 0x40000
```

Never run `xbflash2 … --revert-to-golden` or `xbflash.qspi --factory-reset` on this card. They write to fixed flash addresses from AMD's shell layout and corrupt this image.

### 7.3 Running the image from flash

1. Confirm the flash contents: `sudo host/u55c flash verify bitstream/u55c_riscv.mcs`.
2. Reload the FPGA: `sudo host/u55c fpga-reload --yes`.
3. Warm-reboot: `sudo reboot`.
4. Check: `sudo host/u55c status`. `uptime` restarts near 0 at the reload, and `built` shows the flashed image's build time.

From now on, the card boots this image at every power-up.

`fpga-reload --rescan` tries a PCI rescan instead of step 3. It works when the BIOS left room for the device's BAR; if it prints `rescan did not find the card`, reboot.

### 7.4 Updating firmware only

No FPGA change is needed:

```sh
make -C fw/src APP=myapp           # or build on the build server and copy the .bin
sudo host/u55c load fw/src/build/myapp.bin
```

To make a firmware the power-up default, rebuild the bitstream with it (`make bitstream` uses `fw/build/demo.hex`) and write the flash again.

### 7.5 Recovery

| Situation | Fix |
|---|---|
| New image in flash does not appear after `fpga-reload` + reboot | Load a known-good `.bit` over JTAG ([7.1](#71-first-bring-up-over-jtag-flash-untouched) steps 3–4), then write a good `.mcs` ([7.2](#72-writing-the-flash-over-pcie)) |
| No image with PCIe flash access is available | Write the flash over JTAG: `vivado_lab -mode batch -source bitstream/jtag_flash.tcl -tclargs bitstream/u55c_riscv.mcs` (10–20 minutes), then load the `.bit` over JTAG and reboot |

---

## 8. Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| `no 10ee:903f device found` | Image not loaded, or host not rebooted after loading | Load over JTAG, then `sudo reboot` |
| `permission denied: run with sudo` | Mapping BAR0 needs root | Use `sudo` |
| `BAR0 reads all ones` | Link down, or an FPGA reload is in progress | `sudo reboot` |
| `clock NOT LOCKED` | 161 MHz reference missing | CPU, UART and reload do not run; PCIe and flash access still work. Report the `status` output. |
| `cpu TRAPPED` | Firmware fault | Look up `CPU_PC` in the `.lst`; `u55c reset` or load fixed firmware |
| `no console yet` | Firmware did not call `console_init()`, or the CPU is held | `u55c status`; `u55c run` |
| `log bytes were overwritten` | Firmware printed more than 8 KB between polls | Keep `u55c console` running, or print less |
| `mbox call`: `no answer` | Firmware does not poll the mailbox | Call a mailbox handler like `mailbox_poll()` in `apps/demo/main.c` |
| `flash JEDEC ID 00 …` / `no flash response` | Flash controller not reaching the flash | Report the output; write the flash over JTAG ([7.5](#75-recovery)) |
| No text on `/dev/ttyUSB2` | Other channel, or `hw_server` holds the FTDI chip | Try `/dev/ttyUSB3`; stop `hw_server` |
| Card vanishes from `lspci` after a reboot and the old design is back | Power was lost; the flash still holds the old design | Load over JTAG, then write the flash ([7.2](#72-writing-the-flash-over-pcie)) |
