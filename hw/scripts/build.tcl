# Non-project Vivado build: IP -> synth -> place -> route -> bitstream -> MCS.
#
#   vivado -mode batch -source hw/scripts/build.tcl -tclargs <fw_hex> <out_dir>
#
# Outputs in <out_dir>: u55c_riscv.bit, u55c_riscv.mcs, u55c_riscv.bin, reports/.
set root   [file normalize [file join [file dirname [info script]] .. ..]]
set fw_hex [file normalize [lindex $argv 0]]
set out    [file normalize [lindex $argv 1]]
set part   xcu55c-fsvh2892-2L-e
set name   u55c_riscv

file mkdir $out/ip $out/reports
set ip_dir $out/ip
set_param general.maxThreads 16

create_project -in_memory -part $part
set_property target_language Verilog [current_project]

# ---------------------------------------------------------------- IP
source $root/hw/scripts/ip.tcl
generate_target all [get_ips]
synth_ip [get_ips]

# ---------------------------------------------------------------- build-time parameters
set build_time [clock seconds]
set fh [open $out/build_params.vh w]
puts $fh "`define U55C_BUILD_TIME 32'd$build_time"
puts $fh "`define U55C_FW_INIT \"$fw_hex\""
close $fh
puts "BUILD_TIME = $build_time ([clock format $build_time -gmt 1])"

# ---------------------------------------------------------------- sources
read_verilog [glob $root/hw/rtl/*.v]
read_verilog $root/hw/third_party/picorv32.v
read_xdc $root/hw/xdc/u55c.xdc

synth_design -top u55c_top -part $part -include_dirs $out
# The PCIe user clock exists only now that the XDMA netlist is linked in.
set_clock_groups -asynchronous \
    -group [get_clocks -of_objects [get_pins u_xdma/axi_aclk]] \
    -group [get_clocks -include_generated_clocks clk161]
write_checkpoint -force $out/post_synth.dcp
report_utilization -file $out/reports/utilization_synth.rpt

# ---------------------------------------------------------------- implementation
opt_design
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] < 0} {
    phys_opt_design -directive AggressiveExplore
}
write_checkpoint -force $out/post_route.dcp

report_timing_summary -max_paths 20 -file $out/reports/timing_summary.rpt
report_utilization -file $out/reports/utilization.rpt
report_clock_interaction -file $out/reports/clock_interaction.rpt
report_cdc -file $out/reports/cdc.rpt
report_drc -file $out/reports/drc.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "TIMING: WNS = $wns ns, WHS = $whs ns"
if {$wns < 0 || $whs < 0} {
    puts "ERROR: timing not met -- see $out/reports/timing_summary.rpt"
    if {![info exists ::env(ALLOW_TIMING_FAIL)]} { exit 1 }
}

# ---------------------------------------------------------------- outputs
write_bitstream -force $out/$name.bit
# Flash image for the 1 Gbit (128 MB) MT25QU01G, quad SPI, bitstream at address 0.
write_cfgmem -force -format mcs -size 128 -interface SPIx4 \
    -loadbit "up 0x00000000 $out/$name.bit" -file $out/$name.mcs
write_cfgmem -force -format bin -size 128 -interface SPIx4 \
    -loadbit "up 0x00000000 $out/$name.bit" -file $out/$name.bin

set fh [open $out/build_info.txt w]
puts $fh "build_time=$build_time"
puts $fh "build_time_utc=[clock format $build_time -gmt 1]"
puts $fh "firmware=$fw_hex"
puts $fh "wns=$wns"
puts $fh "whs=$whs"
close $fh
puts "BUILD DONE: $out/$name.bit"
