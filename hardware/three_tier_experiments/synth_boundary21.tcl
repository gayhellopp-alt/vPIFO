# Vivado 2019.2 OOC synthesis for the balanced 21-logical-tree boundary
# experiment.  Both variants implement one root, four middle schedulers, and
# sixteen leaves with PTW=16, MTW=32, and CTW=10.
#
# Usage:
#   vivado -mode batch -source synth_boundary21.tcl \
#       -tclargs <hetero|original> <run_tag> ?clock_period_ns? \
#           ?hetero_pending_depth?

set exp_dir [file dirname [file normalize [info script]]]
set hardware_dir [file dirname $exp_dir]

if {($argc < 2) || ($argc > 4)} {
    error "expected: <hetero|original> <run_tag> ?clock_period_ns? ?hetero_pending_depth?"
}
set variant [lindex $argv 0]
set run_tag [lindex $argv 1]
set clock_period_ns [expr {$argc == 3 ? [lindex $argv 2] : 8.0645}]
if {$argc == 4} {
    set clock_period_ns [lindex $argv 2]
}
set hetero_pending_depth [expr {$argc == 4 ? [lindex $argv 3] : 16}]

if {($variant ne "hetero") && ($variant ne "original")} {
    error "variant must be hetero or original"
}
if {![regexp {^[A-Za-z0-9_]+$} $run_tag]} {
    error "run_tag may contain only letters, digits, and underscores"
}
if {![string is double -strict $clock_period_ns] ||
    ($clock_period_ns <= 0.0)} {
    error "clock_period_ns must be positive"
}
if {![string is integer -strict $hetero_pending_depth] ||
    ($hetero_pending_depth < 5)} {
    error "hetero_pending_depth must be an integer of at least 5"
}

set ptw 16
set mtw 32
set ctw 10
set fifo_size 8
set middle_count 4
set leaf_count 16
set logical_tree_num 21
set bmw_order 2
set bmw_level [expr {$variant eq "hetero" ? 6 : 10}]
set physical_tree_num [expr {$variant eq "hetero" ? 48 : 21}]
set per_tree_capacity [expr {(1 << ($bmw_level + 1)) - 2}]
set resource_limit_lut 174243
set target_frequency_mhz [expr {1000.0 / $clock_period_ns}]
set part_name xcu200-fsgd2104-2-e

proc ceil_log2_at_least_one {value} {
    set width 0
    set power 1
    while {$power < $value} {
        set power [expr {$power * 2}]
        incr width
    }
    return [expr {$width < 1 ? 1 : $width}]
}

proc extract_utilization_metric {report_text row_name} {
    set escaped_name [regsub -all {([][(){}.+*?^$\\|])} $row_name {\\\1}]
    set pattern "^\\|\\s*$escaped_name\\*?\\s*\\|\\s*([0-9,]+)"
    if {[regexp -line -- $pattern $report_text unused value]} {
        return [string map {, ""} $value]
    }
    return "UNKNOWN"
}

# The corrected rotating-placement address sizing is intentionally shared by
# both variants so the comparison does not give either design an SRAM-depth
# advantage.
set tree_stride_words [expr {(1 << $bmw_level) - 1}]
set tree_groups [expr {($physical_tree_num + $bmw_level - 1) /
                       $bmw_level}]
set sram_required_depth [expr {$tree_groups * $tree_stride_words}]
set sram_adw [ceil_log2_at_least_one $sram_required_depth]
set sram_binary_depth [expr {1 << $sram_adw}]
set sram_word_bits [expr {$bmw_order * ($ctw + $mtw + $ptw)}]
set actual_bmw_bits [expr {$physical_tree_num * $per_tree_capacity *
                           ($ctw + $mtw + $ptw)}]
set allocated_bmw_bits [expr {$bmw_level * $sram_binary_depth *
                              $sram_word_bits}]

set build_dir [file join $exp_dir runs $run_tag]
set report_dir [file join $build_dir reports]
file mkdir $build_dir
file mkdir $report_dir

set constraint_file [file join $build_dir "${run_tag}.xdc"]
set constraint_handle [open $constraint_file w]
puts $constraint_handle \
    "create_clock -name vpifo_clk -period $clock_period_ns \[get_ports i_clk\]"
close $constraint_handle

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
        [file join $exp_dir ThreeTierHeterogeneousVPIFO.sv] \
        [file join $exp_dir ThreeTierHeterogeneousVPIFO21.sv]]
    set top_name ThreeTierHeterogeneousVPIFO21
    set generics [list \
        "PTW=$ptw" "MTW=$mtw" "CTW=$ctw" \
        "FIFO_SIZE=$fifo_size" \
        "LOGICAL_PENDING_DEPTH=$hetero_pending_depth"]
    set shard_counts "16,4,4,4,4,1x16"
} else {
    set rtl_dir [file join $hardware_dir BMW_PIFO_SRAM_vPIFO_2]
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
        "MIDDLE_COUNT=$middle_count" "LEAF_COUNT=$leaf_count" \
        "FIFO_SIZE=$fifo_size"]
    set shard_counts "not_applicable"
}

read_xdc $constraint_file

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
lappend synth_arguments -generic $generics
eval synth_design $synth_arguments

set timing_summary_file [file join $report_dir \
    "${run_tag}_timing_summary.rpt"]
set utilization_file [file join $report_dir \
    "${run_tag}_utilization.rpt"]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file $timing_summary_file
report_utilization -file $utilization_file
report_utilization -hierarchical \
    -file [file join $report_dir \
        "${run_tag}_utilization_hierarchical.rpt"]
if {[llength [info commands report_ram_utilization]] != 0} {
    report_ram_utilization \
        -file [file join $report_dir \
            "${run_tag}_memory_utilization.rpt"]
}
report_timing -delay_type max -max_paths 100 -nworst 1 \
    -path_type full_clock_expanded \
    -file [file join $report_dir "${run_tag}_top100_paths.rpt"]
report_high_fanout_nets -timing -load_types -max_nets 100 \
    -fanout_greater_than 50 \
    -file [file join $report_dir "${run_tag}_high_fanout_nets.rpt"]

set synth_dcp [file join $build_dir "${run_tag}_ooc_synth.dcp"]
write_checkpoint -force $synth_dcp

set utilization_text [report_utilization -return_string]
set clb_luts [extract_utilization_metric $utilization_text "CLB LUTs"]
set logic_luts [extract_utilization_metric $utilization_text "LUT as Logic"]
set lutram_luts [extract_utilization_metric $utilization_text "LUT as Memory"]
set registers [extract_utilization_metric $utilization_text "CLB Registers"]

set summary_file [open [file join $report_dir \
    "${run_tag}_machine_summary.txt"] w]
puts $summary_file "STAGE=POST_SYNTH"
puts $summary_file "VARIANT=$variant"
puts $summary_file "TOP=$top_name"
puts $summary_file "PART=$part_name"
puts $summary_file "CLOCK_PERIOD_NS=$clock_period_ns"
puts $summary_file "TARGET_FREQUENCY_MHZ=$target_frequency_mhz"
puts $summary_file "RESOURCE_LIMIT_CLB_LUT=$resource_limit_lut"
puts $summary_file "PTW=$ptw"
puts $summary_file "MTW=$mtw"
puts $summary_file "CTW=$ctw"
puts $summary_file "LOGICAL_PENDING_DEPTH=$hetero_pending_depth"
puts $summary_file "SCHEDULER_LEVELS=3"
puts $summary_file "MIDDLE_COUNT=$middle_count"
puts $summary_file "LEAF_COUNT=$leaf_count"
puts $summary_file "LOGICAL_TREE_NUM=$logical_tree_num"
puts $summary_file "PHYSICAL_TREE_NUM=$physical_tree_num"
puts $summary_file "SHARD_COUNTS=$shard_counts"
puts $summary_file "BMW_ORDER=$bmw_order"
puts $summary_file "BMW_LEVEL=$bmw_level"
puts $summary_file "PER_PHYSICAL_CAPACITY=$per_tree_capacity"
puts $summary_file \
    "TOTAL_STRUCTURAL_CAPACITY=[expr {$physical_tree_num * $per_tree_capacity}]"
puts $summary_file "EXPERIMENT_REQUIRED_CAPACITY=6048"
puts $summary_file "SRAM_BANKS=$bmw_level"
puts $summary_file "TREE_STRIDE_WORDS=$tree_stride_words"
puts $summary_file "SRAM_REQUIRED_DEPTH_PER_BANK=$sram_required_depth"
puts $summary_file "SRAM_ADW=$sram_adw"
puts $summary_file "SRAM_BINARY_DEPTH_PER_BANK=$sram_binary_depth"
puts $summary_file "SRAM_WORD_BITS=$sram_word_bits"
puts $summary_file "ACTUAL_BMW_BITS=$actual_bmw_bits"
puts $summary_file "ALLOCATED_BMW_BITS=$allocated_bmw_bits"
puts $summary_file \
    "BMW_STORAGE_EFFICIENCY=[expr {double($actual_bmw_bits) / $allocated_bmw_bits}]"
puts $summary_file "CLB_LUT=$clb_luts"
puts $summary_file "LUT_AS_LOGIC=$logic_luts"
puts $summary_file "LUT_AS_MEMORY=$lutram_luts"
puts $summary_file "CLB_REGISTERS=$registers"
if {$clb_luts ne "UNKNOWN"} {
    puts $summary_file \
        "RESOURCE_GATE_PASS=[expr {$clb_luts <= $resource_limit_lut}]"
}
puts $summary_file "SYNTH_DIRECTIVE=PerformanceOptimized"
puts $summary_file "SYNTH_DCP=$synth_dcp"

set worst_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $worst_path] == 0} {
    puts $summary_file "NO_SETUP_PATH=1"
} else {
    set worst_path [lindex $worst_path 0]
    set wns [get_property SLACK $worst_path]
    set datapath_delay [get_property DATAPATH_DELAY $worst_path]
    puts $summary_file "WNS=$wns"
    puts $summary_file \
        "STARTPOINT=[get_property STARTPOINT_PIN $worst_path]"
    puts $summary_file \
        "ENDPOINT=[get_property ENDPOINT_PIN $worst_path]"
    puts $summary_file "DATAPATH_DELAY=$datapath_delay"
    puts $summary_file \
        "LOGIC_LEVELS=[get_property LOGIC_LEVELS $worst_path]"
    puts $summary_file "SYNTH_TIMING_GATE_PASS=[expr {$wns >= 0.0}]"
}

set tns 0.0
set violating_paths [get_timing_paths -delay_type max \
    -slack_lesser_than 0.0 -max_paths 200000 -nworst 1]
foreach timing_path $violating_paths {
    set tns [expr {$tns + [get_property SLACK $timing_path]}]
}
puts $summary_file "TNS=$tns"
puts $summary_file "VIOLATING_ENDPOINTS=[llength $violating_paths]"
close $summary_file

puts "PASS: boundary21 synthesis reports written to $report_dir"
