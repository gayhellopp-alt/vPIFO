# Reproduce the original vPIFO RTL that accompanied the first FPGA_data.xlsx
# commit. Historical sources are exported into the run directory so the dirty
# working tree is neither modified nor used as the synthesis input.
#
# Usage:
#   vivado -mode batch -source run_historical_original_vpifo_impl.tcl \
#       -tclargs <TREE_NUM> <run_tag>

set point_dir [file dirname [file normalize [info script]]]
set exp_dir [file dirname $point_dir]
set repo_dir [file dirname [file dirname $exp_dir]]

if {$argc != 2} {
    error "expected arguments: <TREE_NUM> <run_tag>"
}
set tree_num [lindex $argv 0]
set run_tag [lindex $argv 1]
if {![string is integer -strict $tree_num] || ($tree_num < 2)} {
    error "TREE_NUM must be an integer of at least two for the historical RTL"
}
if {![regexp {^[A-Za-z0-9_]+$} $run_tag]} {
    error "run tag may contain only letters, digits, and underscores"
}

set source_commit 43e3476ae2bd9a543a20dcb10ade5575a18a8f00
set rtl_rel_dir hardware/BMW_PIFO_SRAM_vPIFO
set source_names [list \
    INFER_SDPRAM.v \
    TaskFIFO.sv \
    TaskDistribute.sv \
    PIFO_SRAM.sv \
    PIFO_SRAM_TOP.sv]

set part_name xcu200-fsgd2104-2-e
set clock_period_ns 2.6
set target_frequency_mhz [expr {1000.0 / $clock_period_ns}]
set ptw 16
set mtw 0
set ctw 10
set fifo_size 8
set bmw_order 2
set bmw_level 6

set build_dir [file join $exp_dir runs $run_tag]
set source_dir [file join $build_dir historical_rtl]
set report_dir [file join $build_dir reports]
file mkdir $source_dir
file mkdir $report_dir

foreach source_name $source_names {
    set source_spec \
        "${source_commit}:${rtl_rel_dir}/${source_name}"
    set source_text [exec git -C $repo_dir show $source_spec]
    set source_handle [open [file join $source_dir $source_name] w]
    puts -nonewline $source_handle $source_text
    close $source_handle
}

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
foreach source_name $source_names {
    read_verilog -sv [file join $source_dir $source_name]
}
read_xdc $constraint_file

set generics [list \
    "PTW=$ptw" "MTW=$mtw" "CTW=$ctw" \
    "LEVEL=$bmw_level" "TREE_NUM=$tree_num" \
    "FIFO_SIZE=$fifo_size"]
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
puts $route_summary "SOURCE_COMMIT=$source_commit"
puts $route_summary "PART=$part_name"
puts $route_summary "CLOCK_PERIOD_NS=$clock_period_ns"
puts $route_summary "TARGET_FREQUENCY_MHZ=$target_frequency_mhz"
puts $route_summary "PTW=$ptw"
puts $route_summary "MTW=$mtw"
puts $route_summary "CTW=$ctw"
puts $route_summary "FIFO_SIZE=$fifo_size"
puts $route_summary "BMW_ORDER=$bmw_order"
puts $route_summary "BMW_LEVEL=$bmw_level"
puts $route_summary "TREE_NUM=$tree_num"
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
