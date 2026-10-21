# U55C RISC-V image

An FPGA image for the AMD Alveo U55C that contains:

- a PicoRV32 RISC-V CPU (RV32IMC, 100 MHz, 256 KB RAM),
- a console and mailbox the host reaches over PCIe, plus the same console on the card's USB serial port,
- flash programming over PCIe and a command that reloads the FPGA from flash.

The host needs no kernel driver: the tools map the card's PCIe registers (BAR0) through `/sys`.

```
          host (Linux)                                   Alveo U55C
 ┌──────────────────────────┐  PCIe Gen3 x16  ┌────────────────────────────────────────┐
 │ u55c status / load /     │◄───────────────►│ XDMA ─ BAR0 window ─┬─ control regs    │
 │      console / mbox /    │                 │                      ├─ SHM 16 KB ◄──┐ │
 │      flash / fpga-reload │                 │                      ├─ RAM 256 KB ◄─┤ │
 └──────────────────────────┘                 │                      └─ QSPI ─ flash │ │
   /dev/ttyUSB2|3 ◄── micro-USB (FT4232H) ◄───│── UART ◄── PicoRV32 ─────────────────┘ │
                                              └────────────────────────────────────────┘
```

## Repository layout

| Path | Contents |
|---|---|
| `hw/rtl/` | Verilog: top level, CPU subsystem, host window, CDC, UART, ICAP reload |
| `hw/xdc/u55c.xdc` | Pins, clocks and flash boot settings |
| `hw/scripts/` | Vivado build (`build.tcl`, `ip.tcl`) and JTAG scripts for Vivado Lab |
| `hw/sim/tb.v` | Simulation testbench that runs the real firmware |
| `fw/` | Firmware library (`lib/`), demo application (`apps/demo/`), Makefile |
| `host/` | `u55c` command-line tool (Python), `u55c-flash` (C), tests |
| `docs/GUIDE.md` | Hardware and register reference, firmware, host tools, reprogramming |

## Quick start

On the build server:

```sh
make fw          # firmware -> fw/build/demo.bin
make sim         # simulation; ends with "TB PASS"
make bitstream   # Vivado, 1-2 hours -> build/hw/u55c_riscv.{bit,mcs}
make release     # build/release/u55c-riscv.tar.gz
```

On the lab machine, after unpacking the release:

```sh
make -C host                                   # builds u55c-flash
vivado_lab -mode batch -source bitstream/jtag_program.tcl -tclargs bitstream/u55c_riscv.bit
sudo reboot                                    # warm reboot: the FPGA keeps the image
sudo host/u55c status
sudo host/u55c console                         # Ctrl-] quits
```

Do not run `poweroff` on the lab machine: nothing can switch it back on remotely.

[docs/GUIDE.md](docs/GUIDE.md) has the full bring-up sequence, including writing the flash over PCIe.
