# Vivado 2019.2 standard full heterogeneous OOC implementation for one point.
#
# Usage:
#   vivado -mode batch -source implement_heterogeneous_capacity.tcl \
#       -tclargs <generated_dir> <synth_dcp> <run_tag>

set rtl_dir [file dirname [file normalize [info script]]]
if {$argc != 3} {
    error "expected arguments: <generated_dir> <synth_dcp> <run_tag>"
}
set generated_dir [file normalize [lindex $argv 0]]
set synth_dcp [file normalize [lindex $argv 1]]
set run_tag [lindex $argv 2]
if {![file isdirectory $generated_dir]} {
    error "generated configuration directory does not exist: $generated_dir"
}
if {![file isfile $synth_dcp]} {
    error "synthesis checkpoint does not exist: $synth_dcp"
}
if {![regexp {^[A-Za-z0-9_]+$} $run_tag]} {
    error "run tag may contain only letters, digits, and underscores"
}
source [file join $generated_dir vpifo_config.tcl]

set point_dir [file dirname $generated_dir]
set build_dir [file join $point_dir vivado_impl]
set report_dir [file join $build_dir reports]
file mkdir $build_dir
file mkdir $report_dir

set_param general.maxThreads 8
open_checkpoint $synth_dcp

opt_design -directive Explore
write_checkpoint -force \
    [file join $build_dir "heterogeneous_${run_tag}_opt.dcp"]

place_design -directive Explore
write_checkpoint -force \
    [file join $build_dir "heterogeneous_${run_tag}_placed.dcp"]

phys_opt_design -directive Explore
write_checkpoint -force \
    [file join $build_dir "heterogeneous_${run_tag}_phys_opt.dcp"]

route_design -directive Explore
set routed_dcp [file join $build_dir \
    "heterogeneous_${run_tag}_routed.dcp"]
write_checkpoint -force $routed_dcp

report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir \
        "${run_tag}_post_route_timing_summary.rpt"]
report_timing -delay_type max -max_paths 20 -nworst 1 \
    -path_type full_clock_expanded \
    -file [file join $report_dir "${run_tag}_post_route_top20_paths.rpt"]
report_utilization \
    -file [file join $report_dir "${run_tag}_post_route_utilization.rpt"]
report_utilization -hierarchical \
    -file [file join $report_dir \
        "${run_tag}_post_route_utilization_hierarchical.rpt"]
report_route_status \
    -file [file join $report_dir "${run_tag}_route_status.rpt"]
report_high_fanout_nets -timing -slr -max_nets 100 \
    -fanout_greater_than 50 \
    -file [file join $report_dir \
        "${run_tag}_post_route_high_fanout_nets.rpt"]

set primitive_file [open \
    [file join $report_dir "${run_tag}_post_route_primitive_summary.txt"] w]
array set primitive_count {}
foreach primitive_cell [get_cells -hierarchical \
        -filter {IS_PRIMITIVE == 1}] {
    set primitive_type [get_property REF_NAME $primitive_cell]
    if {![info exists primitive_count($primitive_type)]} {
        set primitive_count($primitive_type) 0
    }
    incr primitive_count($primitive_type)
}
foreach primitive_type [lsort [array names primitive_count]] {
    puts $primitive_file "$primitive_type=$primitive_count($primitive_type)"
}
close $primitive_file

set summary_file [open \
    [file join $report_dir "${run_tag}_post_route_machine_summary.txt"] w]
puts $summary_file "STAGE=POST_ROUTE"
puts $summary_file "TOP=HeterogeneousPIFO"
puts $summary_file "PART=[get_property PART [current_design]]"
puts $summary_file "CLOCK_PERIOD_NS=3.333"
puts $summary_file "CONFIG_NAME=$vpifo_config_name"
puts $summary_file "CONFIG_FINGERPRINT=$vpifo_config_fingerprint"
puts $summary_file "BMW_ORDER=$vpifo_shard_order"
puts $summary_file "LEVEL=$vpifo_level"
puts $summary_file "SHARD_CAPACITY=$vpifo_shard_capacity"
puts $summary_file "LOGICAL_TREE_NUM=$vpifo_logical_tree_num"
puts $summary_file "PHYSICAL_TREE_NUM=$vpifo_physical_tree_num"
puts $summary_file "SHARD_COUNTS=$vpifo_shard_counts"
puts $summary_file "SHARD_OFFSETS=$vpifo_shard_offsets"
puts $summary_file "REQUEST_PORTS=4"
puts $summary_file "LOGICAL_PENDING_DEPTH=12"
puts $summary_file "POP_RESULT_FIFO_DEPTH=10"
puts $summary_file "INPUT_DCP=$synth_dcp"
puts $summary_file "ROUTED_DCP=$routed_dcp"
puts $summary_file "OPT_DIRECTIVE=Explore"
puts $summary_file "PLACE_DIRECTIVE=Explore"
puts $summary_file "PHYS_OPT_DIRECTIVE=Explore"
puts $summary_file "ROUTE_DIRECTIVE=Explore"

set worst_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $worst_path] == 0} {
    puts $summary_file "NO_SETUP_PATH=1"
} else {
    set worst_path [lindex $worst_path 0]
    set start_pin [get_property STARTPOINT_PIN $worst_path]
    set end_pin [get_property ENDPOINT_PIN $worst_path]
    puts $summary_file "WNS=[get_property SLACK $worst_path]"
    puts $summary_file "STARTPOINT=$start_pin"
    puts $summary_file "ENDPOINT=$end_pin"
    puts $summary_file \
        "DATAPATH_DELAY=[get_property DATAPATH_DELAY $worst_path]"
    puts $summary_file \
        "LOGIC_LEVELS=[get_property LOGIC_LEVELS $worst_path]"
    set start_cell [get_cells -quiet -of_objects $start_pin]
    set end_cell [get_cells -quiet -of_objects $end_pin]
    set start_slr [get_slrs -quiet -of_objects $start_cell]
    set end_slr [get_slrs -quiet -of_objects $end_cell]
    puts $summary_file "START_SLR=$start_slr"
    puts $summary_file "END_SLR=$end_slr"
    puts $summary_file "CROSSES_SLR=[expr {$start_slr ne $end_slr}]"
}
set tns 0.0
set violating_paths [get_timing_paths -delay_type max \
    -slack_lesser_than 0.0 -max_paths 100000 -nworst 1]
foreach timing_path $violating_paths {
    set tns [expr {$tns + [get_property SLACK $timing_path]}]
}
puts $summary_file "TNS=$tns"
puts $summary_file "VIOLATING_ENDPOINTS=[llength $violating_paths]"
close $summary_file

puts "Full heterogeneous post-route reports written to $report_dir"
