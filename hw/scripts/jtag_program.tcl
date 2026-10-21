# Load a bitstream into the U55C over JTAG (volatile: lost at power-off).
#
#   vivado_lab -mode batch -source jtag_program.tcl -tclargs u55c_riscv.bit
#
# The card drops off PCIe while it is reprogrammed. Afterwards run
# `sudo reboot` (warm) so the host enumerates the new PCIe device.
set bit [file normalize [lindex $argv 0]]
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xcu55c*] 0]
if {$dev eq ""} { error "no xcu55c found on the JTAG chain: [get_hw_devices]" }
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev
puts "JTAG: programmed $dev with $bit"
puts "JTAG: DONE pin = [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"
close_hw_target
disconnect_hw_server
