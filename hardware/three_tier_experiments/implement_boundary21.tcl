# Vivado 2019.2 full OOC implementation for one synthesized balanced
# boundary21 checkpoint.
#
# Usage:
#   vivado -mode batch -source implement_boundary21.tcl \
#       -tclargs <synth.dcp> <hetero|original> <run_tag> \
#           ?<place_directive> <phys_opt_directive> <route_directive>? \
#           ?<hetero_pending_depth>?

set exp_dir [file dirname [file normalize [info script]]]

if {($argc != 3) && ($argc != 4) && ($argc != 6) && ($argc != 7)} {
    error "expected: <synth.dcp> <hetero|original> <run_tag> ?<place_directive> <phys_opt_directive> <route_directive>? ?<hetero_pending_depth>?"
}
set synth_dcp [file normalize [lindex $argv 0]]
set variant [lindex $argv 1]
set run_tag [lindex $argv 2]
set place_directive "Explore"
set phys_opt_directive "Explore"
set route_directive "Explore"
set hetero_pending_depth 16
if {($argc == 6) || ($argc == 7)} {
    set place_directive [lindex $argv 3]
    set phys_opt_directive [lindex $argv 4]
    set route_directive [lindex $argv 5]
}
if {$argc == 4} {
    set hetero_pending_depth [lindex $argv 3]
} elseif {$argc == 7} {
    set hetero_pending_depth [lindex $argv 6]
}
if {![string is integer -strict $hetero_pending_depth] ||
    ($hetero_pending_depth < 5)} {
    error "hetero_pending_depth must be an integer of at least 5"
}
if {![file isfile $synth_dcp]} {
    error "synthesis checkpoint does not exist: $synth_dcp"
}
if {($variant ne "hetero") && ($variant ne "original")} {
    error "variant must be hetero or original"
}
if {![regexp {^[A-Za-z0-9_]+$} $run_tag]} {
    error "run_tag may contain only letters, digits, and underscores"
}

set resource_limit_lut 174243
set timing_gate_frequency_mhz 124.0
set build_dir [file join $exp_dir runs $run_tag]
set report_dir [file join $build_dir reports]
file mkdir $build_dir
file mkdir $report_dir

proc extract_utilization_metric {report_text row_name} {
    set escaped_name [regsub -all {([][(){}.+*?^$\\|])} $row_name {\\\1}]
    set pattern "^\\|\\s*$escaped_name\\*?\\s*\\|\\s*([0-9,]+)"
    if {[regexp -line -- $pattern $report_text unused value]} {
        return [string map {, ""} $value]
    }
    return "UNKNOWN"
}

set_param general.maxThreads 8
open_checkpoint $synth_dcp
set implementation_period_ns [get_property PERIOD [get_clocks vpifo_clk]]

opt_design -directive Explore
write_checkpoint -force [file join $build_dir "${run_tag}_opt.dcp"]

place_design -directive $place_directive
write_checkpoint -force [file join $build_dir "${run_tag}_placed.dcp"]

phys_opt_design -directive $phys_opt_directive
write_checkpoint -force [file join $build_dir "${run_tag}_phys_opt.dcp"]

route_design -directive $route_directive
set routed_dcp [file join $build_dir "${run_tag}_routed.dcp"]
write_checkpoint -force $routed_dcp

report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir \
        "${run_tag}_post_route_timing_summary.rpt"]
report_timing -delay_type max -max_paths 200 -nworst 1 \
    -path_type full_clock_expanded \
    -file [file join $report_dir "${run_tag}_post_route_top200_paths.rpt"]
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

set utilization_text [report_utilization -return_string]
set clb_luts [extract_utilization_metric $utilization_text "CLB LUTs"]
set logic_luts [extract_utilization_metric $utilization_text "LUT as Logic"]
set lutram_luts [extract_utilization_metric $utilization_text "LUT as Memory"]
set registers [extract_utilization_metric $utilization_text "CLB Registers"]

set summary_file [open [file join $report_dir \
    "${run_tag}_post_route_machine_summary.txt"] w]
puts $summary_file "STAGE=POST_ROUTE"
puts $summary_file "VARIANT=$variant"
puts $summary_file "TOP=[get_property TOP [current_design]]"
puts $summary_file "PART=[get_property PART [current_design]]"
puts $summary_file "CLOCK_PERIOD_NS=$implementation_period_ns"
puts $summary_file "TARGET_FREQUENCY_MHZ=$timing_gate_frequency_mhz"
puts $summary_file "RESOURCE_LIMIT_CLB_LUT=$resource_limit_lut"
puts $summary_file "PTW=16"
puts $summary_file "MTW=32"
puts $summary_file "CTW=10"
puts $summary_file "LOGICAL_PENDING_DEPTH=$hetero_pending_depth"
puts $summary_file "SCHEDULER_LEVELS=3"
puts $summary_file "MIDDLE_COUNT=4"
puts $summary_file "LEAF_COUNT=16"
puts $summary_file "LOGICAL_TREE_NUM=21"
puts $summary_file \
    "PHYSICAL_TREE_NUM=[expr {$variant eq "hetero" ? 48 : 21}]"
puts $summary_file \
    "BMW_LEVEL=[expr {$variant eq "hetero" ? 6 : 10}]"
puts $summary_file \
    "SHARD_COUNTS=[expr {$variant eq "hetero" ? "16,4,4,4,4,1x16" : "not_applicable"}]"
puts $summary_file "INPUT_DCP=$synth_dcp"
puts $summary_file "ROUTED_DCP=$routed_dcp"
puts $summary_file "OPT_DIRECTIVE=Explore"
puts $summary_file "PLACE_DIRECTIVE=$place_directive"
puts $summary_file "PHYS_OPT_DIRECTIVE=$phys_opt_directive"
puts $summary_file "ROUTE_DIRECTIVE=$route_directive"
puts $summary_file "CLB_LUT=$clb_luts"
puts $summary_file "LUT_AS_LOGIC=$logic_luts"
puts $summary_file "LUT_AS_MEMORY=$lutram_luts"
puts $summary_file "CLB_REGISTERS=$registers"
if {$clb_luts ne "UNKNOWN"} {
    puts $summary_file \
        "RESOURCE_GATE_PASS=[expr {$clb_luts <= $resource_limit_lut}]"
}

set worst_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $worst_path] == 0} {
    puts $summary_file "NO_SETUP_PATH=1"
} else {
    set worst_path [lindex $worst_path 0]
    set start_pin [get_property STARTPOINT_PIN $worst_path]
    set end_pin [get_property ENDPOINT_PIN $worst_path]
    set wns [get_property SLACK $worst_path]
    puts $summary_file "WNS=$wns"
    puts $summary_file "STARTPOINT=$start_pin"
    puts $summary_file "ENDPOINT=$end_pin"
    puts $summary_file \
        "DATAPATH_DELAY=[get_property DATAPATH_DELAY $worst_path]"
    puts $summary_file \
        "LOGIC_LEVELS=[get_property LOGIC_LEVELS $worst_path]"
    set achieved_period_ns [expr {$implementation_period_ns - $wns}]
    set estimated_fmax_mhz [expr {1000.0 / $achieved_period_ns}]
    puts $summary_file "ACHIEVED_PERIOD_NS=$achieved_period_ns"
    puts $summary_file "ESTIMATED_FMAX_MHZ=$estimated_fmax_mhz"
    puts $summary_file \
        "TIMING_GATE_PASS=[expr {$estimated_fmax_mhz >= $timing_gate_frequency_mhz}]"
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
    -slack_lesser_than 0.0 -max_paths 200000 -nworst 1]
foreach timing_path $violating_paths {
    set tns [expr {$tns + [get_property SLACK $timing_path]}]
}
puts $summary_file "TNS=$tns"
puts $summary_file "VIOLATING_ENDPOINTS=[llength $violating_paths]"
puts $summary_file "VIOLATING_PATH_LIMIT=200000"
close $summary_file

puts "PASS: boundary21 implementation reports written to $report_dir"
