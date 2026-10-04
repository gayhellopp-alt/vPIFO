# Vivado 2019.2 OOC synthesis for the four hard-coded three-tier samples.
#
# Usage:
#   vivado -mode batch -source synth_three_tier_matrix.tcl \
#       -tclargs <hetero|original> <BMW_ORDER> <BMW_LEVEL> <run_tag> ?MTW?

set exp_dir [file dirname [file normalize [info script]]]
set hardware_dir [file dirname $exp_dir]

if {($argc != 4) && ($argc != 5)} {
    error "expected: <hetero|original> <BMW_ORDER> <BMW_LEVEL> <run_tag> ?MTW?"
}
set variant [lindex $argv 0]
set bmw_order [lindex $argv 1]
set bmw_level [lindex $argv 2]
set run_tag [lindex $argv 3]
set mtw [expr {$argc == 5 ? [lindex $argv 4] : 16}]

if {($variant ne "hetero") && ($variant ne "original")} {
    error "variant must be hetero or original"
}
if {![string is integer -strict $bmw_order] ||
    ![string is integer -strict $bmw_level] ||
    ![string is integer -strict $mtw] || ($mtw < 1)} {
    error "BMW_ORDER, BMW_LEVEL, and MTW must be positive decimal integers"
}
if {![regexp {^[A-Za-z0-9_]+$} $run_tag]} {
    error "run_tag may contain only letters, digits, and underscores"
}
if {$variant eq "hetero" &&
    (($bmw_order != 2) || ($bmw_level != 6))} {
    error "the heterogeneous sample is fixed at M=2, LEVEL=6"
}
if {$variant eq "original" &&
    (($bmw_order ni {2 4 8}) || ($bmw_level < 2))} {
    error "unsupported original BMW configuration"
}

set ptw 16
set ctw 10
set fifo_size 8
set logical_tree_num 14
set physical_tree_num [expr {$variant eq "hetero" ? 33 : 14}]
set part_name xcu200-fsgd2104-2-e
set clock_period_ns 3.333

proc integer_power {base exponent} {
    set result 1
    for {set index 0} {$index < $exponent} {incr index} {
        set result [expr {$result * $base}]
    }
    return $result
}

proc ceil_log2_at_least_one {value} {
    set width 0
    set power 1
    while {$power < $value} {
        set power [expr {$power * 2}]
        incr width
    }
    return [expr {$width < 1 ? 1 : $width}]
}

set per_tree_capacity 0
for {set level_index 1} {$level_index <= $bmw_level} {incr level_index} {
    set per_tree_capacity [expr {$per_tree_capacity +
        [integer_power $bmw_order $level_index]}]
}
if {$bmw_order == 2} {
    set tree_size_bits $bmw_level
} elseif {$bmw_order == 4} {
    set tree_size_bits [expr {2 * $bmw_level - 1}]
} else {
    set tree_size_bits [expr {3 * $bmw_level - 2}]
}
set tree_stride_words [expr {[integer_power 2 $tree_size_bits] - 1}]
set tree_groups [expr {($physical_tree_num + $bmw_level - 1) /
                       $bmw_level}]
set sram_required_depth [expr {$tree_groups * $tree_stride_words}]
set sram_adw [ceil_log2_at_least_one $sram_required_depth]
set sram_binary_depth [integer_power 2 $sram_adw]
set sram_word_bits [expr {$bmw_order * ($ctw + $mtw + $ptw)}]
set actual_bmw_bits [expr {$physical_tree_num *
                           $per_tree_capacity *
                           ($ctw + $mtw + $ptw)}]
set allocated_bmw_bits [expr {$bmw_level *
                              $sram_binary_depth *
                              $sram_word_bits}]

set build_dir [file join $exp_dir runs $run_tag]
set report_dir [file join $build_dir reports]
file mkdir $build_dir
file mkdir $report_dir

set_part $part_name
set_param general.maxThreads 8

if {$variant eq "hetero"} {
    set rtl_dir [file join $hardware_dir BMW_PIFO_SRAM_vPIFO]
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
        [file join $exp_dir ThreeTierHeterogeneousVPIFO.sv]]
    set top_name ThreeTierHeterogeneousVPIFO
    set generics [list \
        "PTW=$ptw" "MTW=$mtw" "CTW=$ctw" \
        "FIFO_SIZE=$fifo_size"]
} else {
    set rtl_dir [file join $hardware_dir \
        "BMW_PIFO_SRAM_vPIFO_${bmw_order}"]
    read_verilog -sv [list \
        [file join $rtl_dir INFER_SDPRAM.v] \
        [file join $rtl_dir TaskFIFO.sv] \
        [file join $rtl_dir TaskDistribute.sv] \
        [file join $rtl_dir PIFO_SRAM.sv] \
        [file join $rtl_dir PIFO_SRAM_TOP.sv] \
        [file join $exp_dir ThreeTierOriginalVPIFO.sv]]
    set top_name ThreeTierOriginalVPIFO
    set generics [list \
        "PTW=$ptw" "MTW=$mtw" "CTW=$ctw" \
        "LEVEL=$bmw_level" "TREE_NUM=$logical_tree_num" \
        "FIFO_SIZE=$fifo_size"]
}

read_xdc [file join $exp_dir three_tier_300mhz.xdc]

set synth_arguments [list \
    -mode out_of_context \
    -top $top_name \
    -part $part_name \
    -directive PerformanceOptimized \
    -fanout_limit 400 \
    -fsm_extraction one_hot \
    -keep_equivalent_registers \
    -resource_sharing off \
    -no_lc \
    -shreg_min_size 5]
if {[llength $generics] != 0} {
    lappend synth_arguments -generic $generics
}
eval synth_design $synth_arguments

report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir "${run_tag}_timing_summary.rpt"]
report_utilization \
    -file [file join $report_dir "${run_tag}_utilization.rpt"]
report_utilization -hierarchical \
    -file [file join $report_dir "${run_tag}_utilization_hierarchical.rpt"]
if {[llength [info commands report_ram_utilization]] != 0} {
    report_ram_utilization \
        -file [file join $report_dir "${run_tag}_memory_utilization.rpt"]
}
report_timing -delay_type max -max_paths 20 -nworst 1 \
    -path_type full_clock_expanded \
    -file [file join $report_dir "${run_tag}_top20_paths.rpt"]
report_high_fanout_nets -timing -load_types -max_nets 100 \
    -fanout_greater_than 50 \
    -file [file join $report_dir "${run_tag}_high_fanout_nets.rpt"]
write_checkpoint -force \
    [file join $build_dir "${run_tag}_ooc_synth.dcp"]

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
puts $summary_file "VARIANT=$variant"
puts $summary_file "TOP=$top_name"
puts $summary_file "PART=$part_name"
puts $summary_file "CLOCK_PERIOD_NS=$clock_period_ns"
puts $summary_file "PTW=$ptw"
puts $summary_file "MTW=$mtw"
puts $summary_file "CTW=$ctw"
puts $summary_file "SCHEDULER_LEVELS=3"
puts $summary_file "LOGICAL_TREE_NUM=$logical_tree_num"
puts $summary_file "PHYSICAL_TREE_NUM=$physical_tree_num"
puts $summary_file "BMW_ORDER=$bmw_order"
puts $summary_file "BMW_LEVEL=$bmw_level"
puts $summary_file "PER_PHYSICAL_CAPACITY=$per_tree_capacity"
puts $summary_file "TOTAL_STRUCTURAL_CAPACITY=[expr {$physical_tree_num * $per_tree_capacity}]"
puts $summary_file "SRAM_BANKS=$bmw_level"
puts $summary_file "TREE_STRIDE_WORDS=$tree_stride_words"
puts $summary_file "SRAM_REQUIRED_DEPTH_PER_BANK=$sram_required_depth"
puts $summary_file "SRAM_ADW=$sram_adw"
puts $summary_file "SRAM_BINARY_DEPTH_PER_BANK=$sram_binary_depth"
puts $summary_file "SRAM_WORD_BITS=$sram_word_bits"
puts $summary_file "ACTUAL_BMW_BITS=$actual_bmw_bits"
puts $summary_file "ALLOCATED_BMW_BITS=$allocated_bmw_bits"
puts $summary_file \
    "BMW_STORAGE_EFFICIENCY=[expr {double($actual_bmw_bits) /
                                   $allocated_bmw_bits}]"
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

puts "PASS: three-tier synthesis reports written to $report_dir"
