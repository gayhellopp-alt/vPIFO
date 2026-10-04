# Vivado 2019.2 full heterogeneous OOC synthesis for one capacity point.
#
# Usage:
#   vivado -mode batch -source synth_heterogeneous_capacity.tcl \
#       -tclargs <generated_dir> <run_tag> ?directory_fixed_logical_ports?

set rtl_dir [file dirname [file normalize [info script]]]

if {($argc != 2) && ($argc != 3)} {
    error "expected arguments: <generated_dir> <run_tag> ?directory_fixed_logical_ports?"
}
set generated_dir [file normalize [lindex $argv 0]]
set run_tag [lindex $argv 1]
set directory_fixed_logical_ports [expr {$argc == 3 ? [lindex $argv 2] : 1}]
if {![file isdirectory $generated_dir]} {
    error "generated configuration directory does not exist: $generated_dir"
}
if {![regexp {^[A-Za-z0-9_]+$} $run_tag]} {
    error "run tag may contain only letters, digits, and underscores"
}
if {![string is integer -strict $directory_fixed_logical_ports] ||
    (($directory_fixed_logical_ports != 0) &&
     ($directory_fixed_logical_ports != 1))} {
    error "directory_fixed_logical_ports must be 0 or 1"
}
set config_pkg [file join $generated_dir vpifo_config_pkg.sv]
set config_tcl [file join $generated_dir vpifo_config.tcl]
if {![file isfile $config_pkg] || ![file isfile $config_tcl]} {
    error "generated directory lacks vpifo_config_pkg.sv or vpifo_config.tcl"
}
source $config_tcl

set request_ports 4
set logical_pending_depth 12
set pop_result_fifo_depth 10
set fifo_size 8
set ptw 16
set mtw 16
set ctw 10
set part_name xcu200-fsgd2104-2-e
set clock_period_ns 3.333

if {$vpifo_shard_order != 2 ||
    $vpifo_level < 4 || $vpifo_level > 6 ||
    $vpifo_logical_tree_num != 4} {
    error "capacity matrix requires M=2, LEVEL=4..6, LOGICAL_TREE_NUM=4"
}
if {$logical_pending_depth < $request_ports ||
    $pop_result_fifo_depth < $vpifo_logical_tree_num} {
    error "fixed experiment FIFO/control dimensions are inconsistent"
}
set shard_sum 0
foreach shard_count $vpifo_shard_counts {
    set shard_sum [expr {$shard_sum + $shard_count}]
}
if {$shard_sum != $vpifo_physical_tree_num} {
    error "generated shard counts do not sum to PHYSICAL_TREE_NUM"
}

set point_dir [file dirname $generated_dir]
set build_dir [file join $point_dir vivado_synth]
set report_dir [file join $build_dir reports]
file mkdir $build_dir
file mkdir $report_dir

set_part $part_name
set_param general.maxThreads 8

read_verilog -sv [list \
    $config_pkg \
    [file join $rtl_dir INFER_SDPRAM.v] \
    [file join $rtl_dir TaskFIFO.sv] \
    [file join $rtl_dir TaskDistribute.sv] \
    [file join $rtl_dir PIFO_SRAM.sv] \
    [file join $rtl_dir PIFO_SRAM_TOP.sv] \
    [file join $rtl_dir ShardDirectory.sv] \
    [file join $rtl_dir PopResultFIFO.sv] \
    [file join $rtl_dir LogicalRequestBuffer.sv] \
    [file join $rtl_dir HeterogeneousPIFO.sv]]
read_xdc [file join $rtl_dir heterogeneous_300mhz.xdc]

set generics [list \
    "PTW=$ptw" \
    "MTW=$mtw" \
    "CTW=$ctw" \
    "FIFO_SIZE=$fifo_size" \
    "REQUEST_PORTS=$request_ports" \
    "LOGICAL_PENDING_DEPTH=$logical_pending_depth" \
    "POP_RESULT_FIFO_DEPTH=$pop_result_fifo_depth" \
    "DIRECTORY_FIXED_LOGICAL_PORTS=$directory_fixed_logical_ports"]

synth_design -mode out_of_context \
    -top HeterogeneousPIFO \
    -part $part_name \
    -generic $generics \
    -directive PerformanceOptimized \
    -fanout_limit 400 \
    -fsm_extraction one_hot \
    -keep_equivalent_registers \
    -resource_sharing off \
    -no_lc \
    -shreg_min_size 5

report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir "${run_tag}_synth_timing_summary.rpt"]
report_utilization \
    -file [file join $report_dir "${run_tag}_synth_utilization.rpt"]
report_utilization -hierarchical \
    -file [file join $report_dir \
        "${run_tag}_synth_utilization_hierarchical.rpt"]
if {[llength [info commands report_ram_utilization]] != 0} {
    report_ram_utilization \
        -file [file join $report_dir \
            "${run_tag}_synth_memory_utilization.rpt"]
}
report_timing -delay_type max -max_paths 20 -nworst 1 \
    -path_type full_clock_expanded \
    -file [file join $report_dir "${run_tag}_synth_top20_paths.rpt"]
report_high_fanout_nets -timing -load_types -max_nets 100 \
    -fanout_greater_than 50 \
    -file [file join $report_dir "${run_tag}_synth_high_fanout_nets.rpt"]

set dcp_file [file join $build_dir \
    "heterogeneous_${run_tag}_ooc_synth.dcp"]
write_checkpoint -force $dcp_file

set primitive_file [open \
    [file join $report_dir "${run_tag}_synth_primitive_summary.txt"] w]
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
    [file join $report_dir "${run_tag}_synth_machine_summary.txt"] w]
puts $summary_file "STAGE=OOC_SYNTHESIS"
puts $summary_file "TOP=HeterogeneousPIFO"
puts $summary_file "PART=$part_name"
puts $summary_file "CLOCK_PERIOD_NS=$clock_period_ns"
puts $summary_file "CONFIG_NAME=$vpifo_config_name"
puts $summary_file "CONFIG_FINGERPRINT=$vpifo_config_fingerprint"
puts $summary_file "BMW_ORDER=$vpifo_shard_order"
puts $summary_file "LEVEL=$vpifo_level"
puts $summary_file "SHARD_CAPACITY=$vpifo_shard_capacity"
puts $summary_file "LOGICAL_TREE_NUM=$vpifo_logical_tree_num"
puts $summary_file "PHYSICAL_TREE_NUM=$vpifo_physical_tree_num"
puts $summary_file "SHARD_COUNTS=$vpifo_shard_counts"
puts $summary_file "SHARD_OFFSETS=$vpifo_shard_offsets"
puts $summary_file "REQUEST_PORTS=$request_ports"
puts $summary_file "LOGICAL_PENDING_DEPTH=$logical_pending_depth"
puts $summary_file "POP_RESULT_FIFO_DEPTH=$pop_result_fifo_depth"
puts $summary_file "FIFO_SIZE=$fifo_size"
puts $summary_file \
    "DIRECTORY_FIXED_LOGICAL_PORTS=$directory_fixed_logical_ports"
puts $summary_file "DCP=$dcp_file"
puts $summary_file "SYNTH_DIRECTIVE=PerformanceOptimized"

set worst_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $worst_path] == 0} {
    puts $summary_file "NO_SETUP_PATH=1"
} else {
    set worst_path [lindex $worst_path 0]
    puts $summary_file "WNS=[get_property SLACK $worst_path]"
    puts $summary_file \
        "STARTPOINT=[get_property STARTPOINT_PIN $worst_path]"
    puts $summary_file \
        "ENDPOINT=[get_property ENDPOINT_PIN $worst_path]"
    puts $summary_file \
        "DATAPATH_DELAY=[get_property DATAPATH_DELAY $worst_path]"
    puts $summary_file \
        "LOGIC_LEVELS=[get_property LOGIC_LEVELS $worst_path]"
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

puts "Full heterogeneous OOC synthesis reports written to $report_dir"
