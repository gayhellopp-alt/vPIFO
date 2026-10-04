# Vivado XSim RTL functional simulation for the current non-conserving path.
# Usage:
#   vivado -mode batch -nojournal \
#     -source sim_three_tier_non_conserving_vivado.tcl \
#     -tclargs node_y <run_id>
#   vivado -mode batch -nojournal \
#     -source sim_three_tier_non_conserving_vivado.tcl \
#     -tclargs node_y_multistream_sustained <run_id> 750 100
#   vivado -mode batch -nojournal \
#     -source sim_three_tier_non_conserving_vivado.tcl \
#     -tclargs node_y_ab <run_id> 750

set test_name "node_y"
if {$argc > 0} {
    set test_name [lindex $argv 0]
}
if {$test_name ni {node_y node_y_multistream node_y_ab
                   node_y_multistream_sustained}} {
    error "invalid non-conserving test name: $test_name"
}

set run_id "current"
if {$argc > 1} {
    set run_id [lindex $argv 1]
}

set sustained_service_cycles 750
if {$argc > 2} {
    set sustained_service_cycles [lindex $argv 2]
}
set sustained_intervals 100
if {$argc > 3} {
    set sustained_intervals [lindex $argv 3]
}

set rtl_dir [file dirname [file normalize [info script]]]
set config_pkg [file join $rtl_dir generated vpifo_config_pkg.sv]
set sim_project_dir [file join $rtl_dir vivado_non_conserving_xsim_work \
    ${test_name}_${run_id}]

create_project -force vpifo_non_conserving_sim $sim_project_dir \
    -part xcu200-fsgd2104-2-e
set_property target_language Verilog [current_project]

add_files -norecurse [list \
    $config_pkg \
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

if {$test_name eq "node_y"} {
    set testbench [file join $rtl_dir ThreeTierNodeYTokenBucket_tb.sv]
    set top_name ThreeTierNodeYTokenBucket_tb
} elseif {$test_name eq "node_y_ab"} {
    set testbench [file join $rtl_dir ThreeTierNodeYShapingAB_tb.sv]
    set top_name ThreeTierNodeYShapingAB_tb
} else {
    set testbench [file join $rtl_dir ThreeTierNodeYMultiStream_tb.sv]
    set top_name ThreeTierNodeYMultiStream_tb
}

add_files -fileset sim_1 -norecurse [list $testbench]
set_property top $top_name [get_filesets sim_1]
if {$test_name eq "node_y_multistream_sustained"} {
    set_property generic [list \
        SUSTAINED_MODE=1 \
        TARGET_SERVICE_TIME=$sustained_service_cycles \
        SUSTAINED_MEASUREMENT_SERVICE_INTERVALS=$sustained_intervals] \
        [get_filesets sim_1]
} elseif {$test_name eq "node_y_ab"} {
    set_property generic [list \
        TARGET_SERVICE_TIME=$sustained_service_cycles] \
        [get_filesets sim_1]
}
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
set_property xsim.simulate.runtime all [get_filesets sim_1]

puts "NON_CONSERVING_XSIM_TEST=$test_name"
puts "NON_CONSERVING_XSIM_TOP=$top_name"
puts "NON_CONSERVING_XSIM_PROJECT=$sim_project_dir"
if {$test_name eq "node_y_multistream_sustained"} {
    puts "NON_CONSERVING_XSIM_SERVICE_CYCLES=$sustained_service_cycles"
    puts "NON_CONSERVING_XSIM_MEASUREMENT_INTERVALS=$sustained_intervals"
} elseif {$test_name eq "node_y_ab"} {
    puts "NON_CONSERVING_XSIM_SERVICE_CYCLES=$sustained_service_cycles"
}
launch_simulation
close_sim
close_project
