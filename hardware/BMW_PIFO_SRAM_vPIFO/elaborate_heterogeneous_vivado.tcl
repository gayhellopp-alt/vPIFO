# Vivado RTL elaboration for the fixed heterogeneous PIFO baseline.
# The part matches this repository's existing simulation/implementation Tcl.
# Usage from this directory:
#   vivado -mode batch -source elaborate_heterogeneous_vivado.tcl

set rtl_dir [file dirname [file normalize [info script]]]
set target_part xcu200-fsgd2104-2-e
if {$argc > 0} {
    set target_part [lindex $argv 0]
}

read_verilog -sv [list \
    [file join $rtl_dir generated vpifo_config_pkg.sv] \
    [file join $rtl_dir INFER_SDPRAM.v] \
    [file join $rtl_dir TaskFIFO.sv] \
    [file join $rtl_dir TaskDistribute.sv] \
    [file join $rtl_dir PIFO_SRAM.sv] \
    [file join $rtl_dir PIFO_SRAM_TOP.sv] \
    [file join $rtl_dir ShardDirectory.sv] \
    [file join $rtl_dir PopResultFIFO.sv] \
    [file join $rtl_dir LogicalRequestBuffer.sv] \
    [file join $rtl_dir HeterogeneousPIFO.sv]]

synth_design -rtl -top HeterogeneousPIFO -part $target_part
puts "PASS: HeterogeneousPIFO RTL elaboration completed for $target_part"
