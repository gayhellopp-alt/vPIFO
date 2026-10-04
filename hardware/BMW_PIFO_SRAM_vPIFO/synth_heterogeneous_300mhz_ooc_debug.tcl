# Vivado 2019.2 non-project OOC synthesis-only timing debug flow.
#
# This deliberately stops after synthesis.  It uses the same top, parameters,
# clock constraint, part, and synthesis directives as
# impl_heterogeneous_300mhz_ooc.tcl so its reports can be compared with the
# synthesis reports from the full implementation flow.
#
# Usage from this directory:
#   vivado -mode batch -source synth_heterogeneous_300mhz_ooc_debug.tcl
#   vivado -mode batch -source synth_heterogeneous_300mhz_ooc_debug.tcl \
#       -tclargs stage2_candidate

set rtl_dir [file dirname [file normalize [info script]]]
source [file join $rtl_dir generated vpifo_config.tcl]
set run_tag "stage1_synth"
set lrb_depth 12
if {$argc > 0} {
    set run_tag [lindex $argv 0]
}
if {$argc > 1} {
    set lrb_depth [lindex $argv 1]
}
if {![regexp {^[A-Za-z0-9_]+$} $run_tag]} {
    error "run tag may contain only letters, digits, and underscores"
}
if {![string is integer -strict $lrb_depth] || ($lrb_depth < 1)} {
    error "LRB depth must be a positive integer"
}

set build_dir [file join $rtl_dir \
    "vivado_heterogeneous_300mhz_${run_tag}"]
set report_dir [file join $build_dir reports]
file mkdir $build_dir
file mkdir $report_dir

set_part xcu200-fsgd2104-2-e
set_param general.maxThreads 8

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
read_xdc [file join $rtl_dir heterogeneous_300mhz.xdc]

synth_design -mode out_of_context \
    -top HeterogeneousPIFO \
    -part xcu200-fsgd2104-2-e \
    -generic LOGICAL_PENDING_DEPTH=$lrb_depth \
    -directive PerformanceOptimized \
    -fanout_limit 400 \
    -fsm_extraction one_hot \
    -keep_equivalent_registers \
    -resource_sharing off \
    -no_lc \
    -shreg_min_size 5

report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir "${run_tag}_timing_summary.rpt"]
report_utilization \
    -file [file join $report_dir "${run_tag}_utilization.rpt"]
report_utilization -hierarchical \
    -file [file join $report_dir \
        "${run_tag}_utilization_hierarchical.rpt"]
if {[llength [info commands report_ram_utilization]] != 0} {
    report_ram_utilization \
        -file [file join $report_dir \
            "${run_tag}_memory_utilization.rpt"]
}
report_timing -delay_type max -max_paths 20 -nworst 1 \
    -path_type full_clock_expanded \
    -file [file join $report_dir "${run_tag}_top20_paths.rpt"]
report_high_fanout_nets -timing -load_types -max_nets 100 \
    -fanout_greater_than 50 \
    -file [file join $report_dir "${run_tag}_high_fanout_nets.rpt"]
write_checkpoint -force \
    [file join $build_dir "heterogeneous_${run_tag}_ooc_synth.dcp"]

set primitive_file [open \
    [file join $report_dir "${run_tag}_primitive_summary.txt"] w]
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
    puts $primitive_file \
        "$primitive_type=$primitive_count($primitive_type)"
}
close $primitive_file

set summary_file [open \
    [file join $report_dir "${run_tag}_machine_summary.txt"] w]
puts $summary_file "TOP=HeterogeneousPIFO"
puts $summary_file "PART=xcu200-fsgd2104-2-e"
puts $summary_file "CLOCK_PORT=i_clk"
puts $summary_file "CLOCK_PERIOD_NS=3.333"
puts $summary_file "CONFIG_NAME=$vpifo_config_name"
puts $summary_file "CONFIG_FINGERPRINT=$vpifo_config_fingerprint"
puts $summary_file "LEVEL=$vpifo_level"
puts $summary_file "SHARD_CAPACITY=$vpifo_shard_capacity"
puts $summary_file "PHYSICAL_TREE_NUM=$vpifo_physical_tree_num"
puts $summary_file "LOGICAL_TREE_NUM=$vpifo_logical_tree_num"
puts $summary_file "LRB_DEPTH=$lrb_depth"
puts $summary_file "SHARD_COUNTS=$vpifo_shard_counts"
puts $summary_file "SHARD_OFFSETS=$vpifo_shard_offsets"

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

puts "OOC synthesis-only reports written to $report_dir"
