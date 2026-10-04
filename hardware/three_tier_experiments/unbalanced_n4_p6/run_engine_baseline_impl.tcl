# Vivado 2019.2 OOC post-route baseline for the original physical vPIFO engine.
#
# This keeps the engine parameters and implementation directives aligned with
# run_impl.tcl so its results can be compared with the 3/1/1/1 wrapper run.

set point_dir [file dirname [file normalize [info script]]]
set exp_dir [file dirname $point_dir]
set hardware_dir [file dirname $exp_dir]
set rtl_dir [file join $hardware_dir BMW_PIFO_SRAM_vPIFO]

set run_tag "vpifo_engine_m2_l6_p6_124mhz_explore"
if {$argc == 1} {
    set run_tag [lindex $argv 0]
} elseif {$argc != 0} {
    error "expected zero arguments or one run tag"
}
if {![regexp {^[A-Za-z0-9_]+$} $run_tag]} {
    error "run tag may contain only letters, digits, and underscores"
}

set part_name xcu200-fsgd2104-2-e
set clock_period_ns 8.0645
set target_frequency_mhz [expr {1000.0 / $clock_period_ns}]
set ptw 16
set mtw 32
set ctw 10
set fifo_size 8
set bmw_order 2
set bmw_level 6
set physical_tree_num 6
set per_tree_capacity 126

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

proc write_timing_fields {summary_handle period_ns stage_prefix} {
    set worst_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
    if {[llength $worst_path] == 0} {
        puts $summary_handle "${stage_prefix}_NO_SETUP_PATH=1"
        return
    }
    set worst_path [lindex $worst_path 0]
    set wns [get_property SLACK $worst_path]
    set achieved_period [expr {$period_ns - $wns}]
    puts $summary_handle "${stage_prefix}_WNS=$wns"
    puts $summary_handle \
        "${stage_prefix}_STARTPOINT=[get_property STARTPOINT_PIN $worst_path]"
    puts $summary_handle \
        "${stage_prefix}_ENDPOINT=[get_property ENDPOINT_PIN $worst_path]"
    puts $summary_handle \
        "${stage_prefix}_DATAPATH_DELAY=[get_property DATAPATH_DELAY $worst_path]"
    puts $summary_handle \
        "${stage_prefix}_LOGIC_LEVELS=[get_property LOGIC_LEVELS $worst_path]"
    puts $summary_handle "${stage_prefix}_ACHIEVED_PERIOD_NS=$achieved_period"
    puts $summary_handle \
        "${stage_prefix}_ESTIMATED_FMAX_MHZ=[expr {1000.0 / $achieved_period}]"
}

set constraint_file [file join $build_dir "${run_tag}.xdc"]
set constraint_handle [open $constraint_file w]
puts $constraint_handle \
    "create_clock -name vpifo_clk -period $clock_period_ns \[get_ports i_clk\]"
close $constraint_handle

set_part $part_name
set_param general.maxThreads 8
read_verilog -sv [list \
    [file join $rtl_dir INFER_SDPRAM.v] \
    [file join $rtl_dir TaskFIFO.sv] \
    [file join $rtl_dir TaskDistribute.sv] \
    [file join $rtl_dir PIFO_SRAM.sv] \
    [file join $rtl_dir PIFO_SRAM_TOP.sv]]
read_xdc $constraint_file

set generics [list \
    "PTW=$ptw" "MTW=$mtw" "CTW=$ctw" \
    "LEVEL=$bmw_level" "TREE_NUM=$physical_tree_num" \
    "FIFO_SIZE=$fifo_size" \
    "TASKFIFO_WRITE_ENABLE_IS_ACCEPTED=1"]
set synth_arguments [list \
    -mode out_of_context \
    -top PIFO_SRAM_TOP \
    -part $part_name \
    -directive PerformanceOptimized \
    -fanout_limit 400 \
    -fsm_extraction one_hot \
    -keep_equivalent_registers \
    -resource_sharing off \
    -no_lc \
    -shreg_min_size 5 \
    -generic $generics]
eval synth_design $synth_arguments

set synth_dcp [file join $build_dir "${run_tag}_ooc_synth.dcp"]
write_checkpoint -force $synth_dcp

opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore

set routed_dcp [file join $build_dir "${run_tag}_routed.dcp"]
write_checkpoint -force $routed_dcp
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir "${run_tag}_post_route_timing_summary.rpt"]
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

set route_utilization [report_utilization -return_string]
set route_summary [open [file join $report_dir \
    "${run_tag}_post_route_machine_summary.txt"] w]
puts $route_summary "STAGE=POST_ROUTE"
puts $route_summary "TOP=PIFO_SRAM_TOP"
puts $route_summary "PART=$part_name"
puts $route_summary "CLOCK_PERIOD_NS=$clock_period_ns"
puts $route_summary "TARGET_FREQUENCY_MHZ=$target_frequency_mhz"
puts $route_summary "PTW=$ptw"
puts $route_summary "MTW=$mtw"
puts $route_summary "CTW=$ctw"
puts $route_summary "FIFO_SIZE=$fifo_size"
puts $route_summary "TASKFIFO_WRITE_ENABLE_IS_ACCEPTED=1"
puts $route_summary "BMW_ORDER=$bmw_order"
puts $route_summary "BMW_LEVEL=$bmw_level"
puts $route_summary "PHYSICAL_TREE_NUM=$physical_tree_num"
puts $route_summary "PER_PHYSICAL_CAPACITY=$per_tree_capacity"
puts $route_summary \
    "TOTAL_STRUCTURAL_CAPACITY=[expr {$physical_tree_num * $per_tree_capacity}]"
puts $route_summary \
    "CLB_LUT=[extract_utilization_metric $route_utilization {CLB LUTs}]"
puts $route_summary \
    "LUT_AS_LOGIC=[extract_utilization_metric $route_utilization {LUT as Logic}]"
puts $route_summary \
    "LUT_AS_MEMORY=[extract_utilization_metric $route_utilization {LUT as Memory}]"
puts $route_summary \
    "CLB_REGISTERS=[extract_utilization_metric $route_utilization {CLB Registers}]"
puts $route_summary "OPT_DIRECTIVE=Explore"
puts $route_summary "PLACE_DIRECTIVE=Explore"
puts $route_summary "PHYS_OPT_DIRECTIVE=Explore"
puts $route_summary "ROUTE_DIRECTIVE=Explore"
puts $route_summary "INPUT_DCP=$synth_dcp"
puts $route_summary "ROUTED_DCP=$routed_dcp"
write_timing_fields $route_summary $clock_period_ns "ROUTE"

set violating_paths [get_timing_paths -delay_type max \
    -slack_lesser_than 0.0 -max_paths 200000 -nworst 1]
set tns 0.0
foreach timing_path $violating_paths {
    set tns [expr {$tns + [get_property SLACK $timing_path]}]
}
puts $route_summary "TNS=$tns"
puts $route_summary "VIOLATING_ENDPOINTS=[llength $violating_paths]"
close $route_summary

puts "RESULT_DIR=$build_dir"
