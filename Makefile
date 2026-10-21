# U55C RISC-V image -- top-level build.
#
#   make fw         firmware (fw/build/demo.bin + .hex)
#   make sim        RTL simulation of the CPU + host window with real firmware
#   make bitstream  Vivado build -> build/hw/u55c_riscv.{bit,mcs,bin}  (1-2 hours)
#   make host       host tools (host/u55c-flash, C)
#   make release    build/release/u55c-riscv.tar.gz: everything the lab machine needs
VIVADO   ?= /tools/xilinx/2024.2/Vivado/2024.2/bin/vivado
XSIM_BIN ?= $(dir $(VIVADO))
export XILINXD_LICENSE_FILE ?= 2600@132.70.224.181:2100@enicsw01
export LM_LICENSE_FILE      ?= 2600@132.70.224.181:2100@enicsw01

HW_OUT   := build/hw
FW_HEX   := fw/build/demo.hex
RTL      := $(wildcard hw/rtl/*.v) hw/third_party/picorv32.v

all: fw host

fw:
	$(MAKE) -C fw

$(FW_HEX): $(wildcard fw/lib/*) $(wildcard fw/apps/demo/*)
	$(MAKE) -C fw

host:
	$(MAKE) -C host

bitstream: $(HW_OUT)/u55c_riscv.bit
$(HW_OUT)/u55c_riscv.bit: $(FW_HEX) $(RTL) hw/xdc/u55c.xdc hw/scripts/build.tcl hw/scripts/ip.tcl
	@mkdir -p $(HW_OUT)
	cd $(HW_OUT) && $(VIVADO) -mode batch -nojournal -log vivado.log \
	    -source $(CURDIR)/hw/scripts/build.tcl -tclargs $(CURDIR)/$(FW_HEX) $(CURDIR)/$(HW_OUT)

# Simulation uses Vivado's xsim (the Xilinx-specific top level is left out).
SIM_SRC := $(filter-out hw/rtl/u55c_top.v,$(wildcard hw/rtl/*.v)) hw/third_party/picorv32.v hw/sim/tb.v
sim: $(FW_HEX)
	@mkdir -p build/sim
	cd build/sim && $(XSIM_BIN)xvlog -d SIM $(addprefix $(CURDIR)/,$(SIM_SRC)) > xvlog.log \
	    || (cat xvlog.log; false)
	cd build/sim && $(XSIM_BIN)xelab -debug off -s tb_snap tb > xelab.log || (cat xelab.log; false)
	cd build/sim && $(XSIM_BIN)xsim tb_snap -R -testplusarg fw=$(CURDIR)/$(FW_HEX) | tee xsim.log
	@grep -q "TB PASS" build/sim/xsim.log

host-test:
	$(MAKE) -C host test

REL := build/release/u55c-riscv
release: fw
	rm -rf $(REL) && mkdir -p $(REL)/bitstream $(REL)/fw
	cp $(HW_OUT)/u55c_riscv.bit $(HW_OUT)/u55c_riscv.mcs $(HW_OUT)/build_info.txt $(REL)/bitstream/
	cp fw/build/demo.bin fw/build/demo.elf $(REL)/fw/
	rsync -a --exclude build fw/ $(REL)/fw/src/
	rsync -a --exclude '*.o' --exclude u55c-flash --exclude __pycache__ host/ $(REL)/host/
	cp -r docs README.md $(REL)/
	cp hw/scripts/jtag_program.tcl hw/scripts/jtag_flash.tcl $(REL)/bitstream/
	tar -C build/release -czf build/release/u55c-riscv.tar.gz u55c-riscv
	@echo "release: build/release/u55c-riscv.tar.gz"

clean:
	rm -rf build
	$(MAKE) -C fw clean
	$(MAKE) -C host clean

.PHONY: all fw host bitstream sim host-test release clean
