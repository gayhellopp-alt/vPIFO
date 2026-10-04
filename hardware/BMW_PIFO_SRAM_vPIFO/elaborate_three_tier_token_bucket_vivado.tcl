# Usage:
#   vivado -mode batch -source elaborate_three_tier_token_bucket_vivado.tcl

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
    [file join $rtl_dir HeterogeneousPIFO.sv] \
    [file join $rtl_dir ShapingEventTable.sv] \
    [file join $rtl_dir ShapingReleaseFIFO.sv] \
    [file join $rtl_dir ShapingLogicalHeadSummary.sv] \
    [file join $rtl_dir ShapingDueArbiter.sv] \
    [file join $rtl_dir MultiLogicalShapingPIFO.sv] \
    [file join $rtl_dir ShapingReleaseToParent.sv] \
    [file join $rtl_dir ShapingTransactionEngine.sv] \
    [file join $rtl_dir RecursiveScheduleTreeHeterogeneousPIFO.sv] \
    [file join $rtl_dir ThreeTierTokenBucketVPIFO.sv]]

synth_design -rtl -top ThreeTierTokenBucketVPIFO -part $target_part
puts "PASS: ThreeTierTokenBucketVPIFO RTL elaboration completed for $target_part"

set multi_driven_nets [get_nets -hierarchical -filter {TYPE == MultiDriver}]
puts "multi_driven_nets: [llength $multi_driven_nets]"
if {[llength $multi_driven_nets] != 0} {
    puts [join $multi_driven_nets "\n"]
    error "ThreeTierTokenBucketVPIFO contains multi-driven nets"
}
