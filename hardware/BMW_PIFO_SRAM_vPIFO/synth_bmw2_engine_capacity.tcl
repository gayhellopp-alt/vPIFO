# Vivado 2019.2 Engine-only OOC synthesis flow for the M=2 capacity matrix.
#
# Usage from this directory:
#   vivado -mode batch -source synth_bmw2_engine_capacity.tcl \
#       -tclargs <LEVEL> <TREE_NUM> <run_tag>

set rtl_dir [file dirname [file normalize [info script]]]

if {$argc != 3} {
    error "expected arguments: <LEVEL> <TREE_NUM> <run_tag>"
}
set level [lindex $argv 0]
set tree_num [lindex $argv 1]
set run_tag [lindex $argv 2]

if {![string is integer -strict $level] ||
    ![string is integer -strict $tree_num]} {
    error "LEVEL and TREE_NUM must be decimal integers"
}
if {($level < 2) || ($level > 62) || ($tree_num < 1)} {
    error "supported range is 2 <= LEVEL <= 62 and TREE_NUM >= 1"
}
if {![regexp {^[A-Za-z0-9_]+$} $run_tag]} {
    error "run tag may contain only letters, digits, and underscores"
}

set ptw 16
set mtw 16
set ctw 10
set fifo_size 8
set clock_period_ns 3.333
set part_name xcu200-fsgd2104-2-e
set tree_words [expr {(1 << $level) - 1}]
set tree_capacity [expr {2 * $tree_words}]
set tree_groups [expr {($tree_num + $level - 1) / $level}]
set sram_required_depth [expr {$tree_groups * $tree_words}]

proc ceil_log2_at_least_one {value} {
    set width 0
    set power 1
    while {$power < $value} {
        set power [expr {$power * 2}]
        incr width
    }
    if {$width < 1} {
        return 1
    }
    return $width
}

set sram_adw [ceil_log2_at_least_one $sram_required_depth]
set sram_binary_depth [expr {1 << $sram_adw}]
set sram_word_bits [expr {2 * ($ctw + $mtw + $ptw)}]
set actual_bmw_bits [expr {$tree_num * $tree_words * $sram_word_bits}]
set allocated_bmw_bits \
    [expr {$level * $sram_binary_depth * $sram_word_bits}]

set build_dir [file join $rtl_dir \
    "vivado_bmw2_engine_capacity_${run_tag}"]
set report_dir [file join $build_dir reports]
file mkdir $build_dir
file mkdir $report_dir

set_part $part_name
set_param general.maxThreads 8

read_verilog -sv [list \
    [file join $rtl_dir INFER_SDPRAM.v] \
    [file join $rtl_dir TaskFIFO.sv] \
    [file join $rtl_dir TaskDistribute.sv] \
    [file join $rtl_dir PIFO_SRAM.sv] \
    [file join $rtl_dir PIFO_SRAM_TOP.sv]]
read_xdc [file join $rtl_dir heterogeneous_300mhz.xdc]

set generics [list \
    "PTW=$ptw" \
    "MTW=$mtw" \
    "CTW=$ctw" \
    "LEVEL=$level" \
    "TREE_NUM=$tree_num" \
    "FIFO_SIZE=$fifo_size"]

synth_design -mode out_of_context \
    -top PIFO_SRAM_TOP \
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
    [file join $build_dir "bmw2_engine_${run_tag}_ooc_synth.dcp"]

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
puts $summary_file "TOP=PIFO_SRAM_TOP"
puts $summary_file "PART=$part_name"
puts $summary_file "CLOCK_PORT=i_clk"
puts $summary_file "CLOCK_PERIOD_NS=$clock_period_ns"
puts $summary_file "BMW_ORDER=2"
puts $summary_file "LEVEL=$level"
puts $summary_file "TREE_NUM=$tree_num"
puts $summary_file "PTW=$ptw"
puts $summary_file "MTW=$mtw"
puts $summary_file "CTW=$ctw"
puts $summary_file "FIFO_SIZE=$fifo_size"
puts $summary_file "TREE_WORDS=$tree_words"
puts $summary_file "TREE_CAPACITY=$tree_capacity"
puts $summary_file "TOTAL_CAPACITY=[expr {$tree_num * $tree_capacity}]"
puts $summary_file "SRAM_BANKS=$level"
puts $summary_file "SRAM_REQUIRED_DEPTH_PER_BANK=$sram_required_depth"
puts $summary_file "SRAM_ADW=$sram_adw"
puts $summary_file "SRAM_BINARY_DEPTH_PER_BANK=$sram_binary_depth"
puts $summary_file "SRAM_WORD_BITS=$sram_word_bits"
puts $summary_file "ACTUAL_BMW_BITS=$actual_bmw_bits"
puts $summary_file "ALLOCATED_BMW_BITS=$allocated_bmw_bits"
puts $summary_file \
    "BMW_STORAGE_EFFICIENCY=[expr {double($actual_bmw_bits) / $allocated_bmw_bits}]"
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

puts "BMW2 Engine-only OOC synthesis reports written to $report_dir"
