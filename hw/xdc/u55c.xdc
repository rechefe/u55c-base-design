# Alveo U55C (xcu55c-fsvh2892-2L-e) constraints for the RISC-V image.
# Pin locations follow the open-source taxi project's AU55C XDC (MIT licensed,
# github.com/fpganinja/taxi, src/cndm/board/Alveo/fpga/syn/AU55/).

# ---------------------------------------------------------------- configuration
# The card boots from a Micron MT25QU01G (1 Gbit) quad-SPI flash.
set_property CFGBVS GND                                [current_design]
set_property CONFIG_VOLTAGE 1.8                        [current_design]
set_property CONFIG_MODE SPIx4                         [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4           [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR YES       [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES        [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 85.0          [current_design]
set_property BITSTREAM.CONFIG.EXTMASTERCCLK_EN DISABLE [current_design]
set_property BITSTREAM.CONFIG.CONFIGFALLBACK ENABLE    [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP         [current_design]
set_property BITSTREAM.CONFIG.OVERTEMPSHUTDOWN ENABLE  [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE           [current_design]

# ---------------------------------------------------------------- PCIe
# x16 lanes; the XDMA IP places the GT channels itself. Only the refclk and
# PERST# need locations. Lane 0 is GTY quad 227, lane 15 quad 224.
set_property PACKAGE_PIN AR15 [get_ports pcie_refclk_p]
set_property PACKAGE_PIN AR14 [get_ports pcie_refclk_n]
create_clock -period 10.000 -name pcie_refclk [get_ports pcie_refclk_p]

set_property -dict {PACKAGE_PIN BF41 IOSTANDARD LVCMOS18 PULLUP true} [get_ports pcie_perst_n]
set_false_path -from [get_ports pcie_perst_n]

# ---------------------------------------------------------------- 161 MHz reference
# SI5394 OUT0 -> QSFP0 MGT refclk (MGTREFCLK0_130). Running from power-up.
set_property PACKAGE_PIN AD42 [get_ports clk161_p]
set_property PACKAGE_PIN AD43 [get_ports clk161_n]
create_clock -period 6.206 -name clk161 [get_ports clk161_p]

# ---------------------------------------------------------------- UARTs (FT4232H channels C and D)
set_property -dict {PACKAGE_PIN BJ41 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {uart_txd[0]}]
set_property -dict {PACKAGE_PIN BK41 IOSTANDARD LVCMOS18}                   [get_ports {uart_rxd[0]}]
set_property -dict {PACKAGE_PIN BN47 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {uart_txd[1]}]
set_property -dict {PACKAGE_PIN BP47 IOSTANDARD LVCMOS18}                   [get_ports {uart_rxd[1]}]
set_false_path -to   [get_ports {uart_txd[*]}]
set_false_path -from [get_ports {uart_rxd[*]}]

# ---------------------------------------------------------------- LEDs (QSFP activity/status)
set_property -dict {PACKAGE_PIN BL13 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN BK11 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN BJ11 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN BK14 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN BK15 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN BL12 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {led[5]}]
set_false_path -to [get_ports {led[*]}]

# ---------------------------------------------------------------- HBM CATTRIP
# Monitored by the satellite controller: if left floating/high the card powers off.
set_property -dict {PACKAGE_PIN BE45 IOSTANDARD LVCMOS18 PULLDOWN true} [get_ports hbm_cattrip]
set_false_path -to [get_ports hbm_cattrip]

# ---------------------------------------------------------------- clock domain crossings
# The PCIe user clock and the 161 MHz-derived clocks are unrelated; all
# crossings go through sync_bits / cdc_snapshot / dual-port RAMs. The
# set_clock_groups constraint lives in hw/scripts/build.tcl because the PCIe
# user clock only exists after the XDMA IP is linked in.
