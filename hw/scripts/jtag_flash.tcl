# Fallback: write the configuration flash over JTAG (slow, ~10-20 minutes).
# Use this only when flashing over PCIe is not possible.
#
#   vivado_lab -mode batch -source jtag_flash.tcl -tclargs u55c_riscv.mcs
#
# Vivado first loads a helper bitstream into the FPGA, so the card drops off
# PCIe. Afterwards load the new image with jtag_program.tcl and run
# `sudo reboot`; from the next power-up the card boots the flashed image.
set mcs [file normalize [lindex $argv 0]]
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xcu55c*] 0]
if {$dev eq ""} { error "no xcu55c found on the JTAG chain: [get_hw_devices]" }
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts {mt25qu01g-spi-x1_x2_x4}] 0]
set mem [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.ADDRESS_RANGE  {use_file}  $mem
set_property PROGRAM.FILES          [list $mcs] $mem
set_property PROGRAM.PRM_FILE       {}          $mem
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $mem
set_property PROGRAM.BLANK_CHECK    0 $mem
set_property PROGRAM.ERASE          1 $mem
set_property PROGRAM.CFG_PROGRAM    1 $mem
set_property PROGRAM.VERIFY         1 $mem
set_property PROGRAM.CHECKSUM       0 $mem

create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev
program_hw_cfgmem -hw_cfgmem $mem
puts "JTAG: flash programmed and verified with $mcs"
close_hw_target
disconnect_hw_server
