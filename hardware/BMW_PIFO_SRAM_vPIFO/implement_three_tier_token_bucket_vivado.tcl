# Constrained out-of-context implementation of the current aggregate-Y
# non-work-conserving top.  The default target is the U200 at 125 MHz.
#
# Usage:
#   vivado -mode batch -nojournal \
#     -source implement_three_tier_token_bucket_vivado.tcl \
#     -tclargs 8.000 current ?interface_delay_ns? \
#         ?schedule_pending_depth? ?schedule_pop_track_depth? \
#         ?sequence_width?
#
# The optional interface delay is an explicit OOC budget assumption, not a
# board constraint.  For example, 1.000 constrains every synchronous data
# input/output to one nanosecond relative to vpifo_clk.

set rtl_dir [file dirname [file normalize [info script]]]
set target_part xcu200-fsgd2104-2-e
set clock_period_ns 8.000
if {$argc > 0} {
    set clock_period_ns [lindex $argv 0]
}
set run_id "current"
if {$argc > 1} {
    set run_id [lindex $argv 1]
}
set interface_delay_ns ""
if {$argc > 2} {
    set interface_delay_ns [lindex $argv 2]
}
if {($interface_delay_ns eq "none") ||
    ($interface_delay_ns eq "unconstrained")} {
    set interface_delay_ns ""
}
set schedule_pending_depth 32
if {$argc > 3} {
    set schedule_pending_depth [lindex $argv 3]
}
set schedule_pop_track_depth 32
if {$argc > 4} {
    set schedule_pop_track_depth [lindex $argv 4]
}
set sequence_width 16
if {$argc > 5} {
    set sequence_width [lindex $argv 5]
}
if {![string is integer -strict $schedule_pending_depth] ||
    ($schedule_pending_depth < 4)} {
    error "schedule_pending_depth must be an integer >= 4"
}
if {![string is integer -strict $schedule_pop_track_depth] ||
    ($schedule_pop_track_depth < 2)} {
    error "schedule_pop_track_depth must be an integer >= 2"
}
if {![string is integer -strict $sequence_width] ||
    ($sequence_width < 1)} {
    error "sequence_width must be an integer >= 1"
}

set build_dir [file join $rtl_dir vivado_three_tier_token_bucket_impl $run_id]
set report_dir [file join $build_dir reports]
file mkdir $build_dir
file mkdir $report_dir

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

puts "THREE_TIER_IMPL_RUN_ID=$run_id"
puts "THREE_TIER_IMPL_PART=$target_part"
puts "THREE_TIER_IMPL_CLOCK_PERIOD_NS=$clock_period_ns"
puts "THREE_TIER_IMPL_SCHEDULE_PENDING_DEPTH=$schedule_pending_depth"
puts "THREE_TIER_IMPL_SCHEDULE_POP_TRACK_DEPTH=$schedule_pop_track_depth"
puts "THREE_TIER_IMPL_SEQUENCE_WIDTH=$sequence_width"
if {$interface_delay_ns ne ""} {
    puts "THREE_TIER_IMPL_INTERFACE_DELAY_NS=$interface_delay_ns"
} else {
    puts "THREE_TIER_IMPL_INTERFACE_DELAY_NS=unconstrained"
}

set design_generics [list \
    "SPLIT_SHAPING=1" \
    "SHAPED_TARGET_NODE=2" \
    "SEQUENCE_WIDTH=$sequence_width" \
    "SAFE_SEQUENCE_WRAP=1" \
    "SCHEDULE_PENDING_DEPTH=$schedule_pending_depth" \
    "SCHEDULE_POP_TRACK_DEPTH=$schedule_pop_track_depth"]

synth_design -mode out_of_context \
    -top ThreeTierTokenBucketVPIFO \
    -part $target_part \
    -flatten_hierarchy rebuilt \
    -generic $design_generics

create_clock -name vpifo_clk -period $clock_period_ns [get_ports i_clk]
set_false_path -from [get_ports i_arst_n]
if {$interface_delay_ns ne ""} {
    set synchronous_inputs [get_ports -filter {
        DIRECTION == IN && NAME != i_clk && NAME != i_arst_n}]
    set synchronous_outputs [get_ports -filter {DIRECTION == OUT}]
    set_input_delay -clock vpifo_clk -max $interface_delay_ns \
        $synchronous_inputs
    set_input_delay -clock vpifo_clk -min 0.000 $synchronous_inputs
    set_output_delay -clock vpifo_clk -max $interface_delay_ns \
        $synchronous_outputs
    set_output_delay -clock vpifo_clk -min 0.000 $synchronous_outputs
}

write_checkpoint -force [file join $build_dir post_synth.dcp]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir post_synth_timing_summary.rpt]
report_utilization \
    -file [file join $report_dir post_synth_utilization.rpt]

opt_design
write_checkpoint -force [file join $build_dir post_opt.dcp]
place_design -directive Explore
write_checkpoint -force [file join $build_dir post_place.dcp]
phys_opt_design -directive AggressiveExplore
write_checkpoint -force [file join $build_dir post_place_physopt.dcp]
route_design -directive Explore
write_checkpoint -force [file join $build_dir post_route.dcp]

report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir post_route_timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -nworst 1 \
    -input_pins -file [file join $report_dir post_route_setup_top20.rpt]
report_timing -delay_type min -max_paths 20 -nworst 1 \
    -input_pins -file [file join $report_dir post_route_hold_top20.rpt]
report_utilization \
    -file [file join $report_dir post_route_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 \
    -file [file join $report_dir post_route_utilization_hierarchical.rpt]
report_clock_utilization \
    -file [file join $report_dir post_route_clock_utilization.rpt]
report_high_fanout_nets -timing -load_types -max_nets 50 \
    -file [file join $report_dir post_route_high_fanout_nets.rpt]
report_drc -file [file join $report_dir post_route_drc.rpt]
report_route_status \
    -file [file join $report_dir post_route_status.rpt]
check_timing -verbose \
    -file [file join $report_dir post_route_check_timing.rpt]

write_verilog -force -mode timesim -sdf_anno true \
    [file join $build_dir ThreeTierTokenBucketVPIFO_post_route_timesim.v]
write_sdf -force \
    [file join $build_dir ThreeTierTokenBucketVPIFO_post_route.sdf]

set setup_paths [get_timing_paths -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -delay_type min -max_paths 1]
set setup_wns "NA"
set hold_wns "NA"
if {[llength $setup_paths] != 0} {
    set setup_wns [get_property SLACK [lindex $setup_paths 0]]
}
if {[llength $hold_paths] != 0} {
    set hold_wns [get_property SLACK [lindex $hold_paths 0]]
}
set timing_met true
if {($setup_wns eq "NA") || ($hold_wns eq "NA") ||
    ($setup_wns < 0.0) || ($hold_wns < 0.0)} {
    set timing_met false
}

set interface_delay_label "unconstrained"
if {$interface_delay_ns ne ""} {
    set interface_delay_label $interface_delay_ns
}

set summary_file [file join $report_dir post_route_machine_summary.txt]
set summary [open $summary_file w]
puts $summary "run_id=$run_id"
puts $summary "part=$target_part"
puts $summary "clock_period_ns=$clock_period_ns"
puts $summary "interface_delay_ns=$interface_delay_label"
puts $summary "schedule_pending_depth=$schedule_pending_depth"
puts $summary "schedule_pop_track_depth=$schedule_pop_track_depth"
puts $summary "sequence_width=$sequence_width"
puts $summary "safe_sequence_wrap=1"
puts $summary "setup_wns_ns=$setup_wns"
puts $summary "hold_wns_ns=$hold_wns"
puts $summary "route_design_completed=true"
puts $summary "timing_met=$timing_met"
close $summary

puts "THREE_TIER_IMPL_SETUP_WNS_NS=$setup_wns"
puts "THREE_TIER_IMPL_HOLD_WNS_NS=$hold_wns"
puts "THREE_TIER_IMPL_TIMING_MET=$timing_met"
puts "THREE_TIER_IMPL_REPORT_DIR=$report_dir"
if {!$timing_met} {
    error "ThreeTierTokenBucketVPIFO post-route timing constraints are not met"
}
puts "PASS: ThreeTierTokenBucketVPIFO implementation and timing completed"
