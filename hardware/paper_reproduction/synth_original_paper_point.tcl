# Vivado OOC synthesis for vPIFO FPGA points published in SIGCOMM 2024.
#
# The synthesis top is the original PIFO_SRAM_TOP itself.  No hierarchical
# scheduling wrapper is included because Figures 9--11 and 19--24 vary only
# BMW order, BMW level, and the number of virtual PIFO instances.
#
# Usage:
#   vivado -mode batch -source synth_original_paper_point.tcl -tclargs \
#       <BMW_ORDER> <BMW_LEVEL> <INSTANCES> <CLOCK_PERIOD_NS> <RUN_TAG> \
#       ?paper_consistent|github_verbatim? ?Default|PerformanceOptimized? \
#       ?skip|detailed?

set exp_dir [file dirname [file normalize [info script]]]

if {($argc < 5) || ($argc > 8)} {
    error "expected: <BMW_ORDER> <BMW_LEVEL> <INSTANCES> <CLOCK_PERIOD_NS> <RUN_TAG> ?SOURCE_MODE? ?SYNTH_DIRECTIVE? ?RAM_REPORT_MODE?"
}

set bmw_order [lindex $argv 0]
set bmw_level [lindex $argv 1]
set instance_count [lindex $argv 2]
set clock_period_ns [lindex $argv 3]
set run_tag [lindex $argv 4]
set source_mode [expr {$argc >= 6 ? [lindex $argv 5] : "paper_consistent"}]
set synth_directive [expr {$argc >= 7 ? [lindex $argv 6] : "Default"}]
set ram_report_mode [expr {$argc >= 8 ? [lindex $argv 7] : "skip"}]

if {![string is integer -strict $bmw_order] ||
    ($bmw_order ni {2 4 8})} {
    error "BMW_ORDER must be 2, 4, or 8"
}
if {![string is integer -strict $bmw_level] || ($bmw_level < 2)} {
    error "BMW_LEVEL must be an integer of at least 2"
}
if {![string is integer -strict $instance_count] ||
    ($instance_count < 2)} {
    error "INSTANCES must be an integer of at least 2"
}
if {![string is double -strict $clock_period_ns] ||
    ($clock_period_ns <= 0.0)} {
    error "CLOCK_PERIOD_NS must be positive"
}
if {![regexp {^[A-Za-z0-9_]+$} $run_tag]} {
    error "RUN_TAG may contain only letters, digits, and underscores"
}
if {$source_mode ni {paper_consistent github_verbatim}} {
    error "SOURCE_MODE must be paper_consistent or github_verbatim"
}
if {$synth_directive ni {Default PerformanceOptimized}} {
    error "SYNTH_DIRECTIVE must be Default or PerformanceOptimized"
}
if {$ram_report_mode ni {skip detailed}} {
    error "RAM_REPORT_MODE must be skip or detailed"
}

set ptw 16
set mtw 32
set ctw 10
set fifo_size 8
set part_name xcu200-fsgd2104-2-e

proc integer_power {base exponent} {
    set result 1
    for {set index 0} {$index < $exponent} {incr index} {
        set result [expr {$result * $base}]
    }
    return $result
}

proc ceil_log2 {value} {
    set width 0
    set power 1
    while {$power < $value} {
        set power [expr {$power * 2}]
        incr width
    }
    return $width
}

proc extract_utilization_metric {report_text row_name} {
    set escaped_name [regsub -all {([][(){}.+*?^$\\|])} $row_name {\\\1}]
    set pattern "^\\|\\s*$escaped_name\\*?\\s*\\|\\s*([0-9,]+)"
    if {[regexp -line -- $pattern $report_text unused value]} {
        return [string map {, ""} $value]
    }
    return "UNKNOWN"
}

set capacity 0
for {set level_index 1} {$level_index <= $bmw_level} {incr level_index} {
    set capacity [expr {$capacity +
        [integer_power $bmw_order $level_index]}]
}

if {$bmw_order == 2} {
    set tree_size_bits $bmw_level
} elseif {$bmw_order == 4} {
    set tree_size_bits [expr {2 * $bmw_level - 1}]
} else {
    set tree_size_bits [expr {3 * $bmw_level - 2}]
}

set tree_groups [expr {($instance_count + $bmw_level - 1) /
                       $bmw_level}]
set tree_stride_words [expr {[integer_power 2 $tree_size_bits] - 1}]
set paper_required_depth [expr {$tree_groups * $tree_stride_words}]
set paper_sram_adw [ceil_log2 $paper_required_depth]
set paper_binary_depth [integer_power 2 $paper_sram_adw]

# In the public 03b4947 source, integer precedence makes 1/LEVEL equal zero.
# These values describe what the verbatim expression actually elaborates to.
set github_sram_adw [expr {[ceil_log2 [expr {$instance_count +
                                              $bmw_level}]] +
                            $tree_size_bits}]
set github_binary_depth [integer_power 2 $github_sram_adw]

if {$source_mode eq "paper_consistent"} {
    set rtl_dir [file join $exp_dir source_paper_consistent \
        "BMW_PIFO_SRAM_vPIFO_${bmw_order}"]
    set source_base "03b4947_plus_sram_address_parentheses_fix"
    set elaborated_sram_adw $paper_sram_adw
    set elaborated_binary_depth $paper_binary_depth
} else {
    set rtl_dir [file join $exp_dir source_03b4947 hardware \
        "BMW_PIFO_SRAM_vPIFO_${bmw_order}"]
    set source_base "03b4947_verbatim"
    set elaborated_sram_adw $github_sram_adw
    set elaborated_binary_depth $github_binary_depth
}

foreach source_file {INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv \
                     PIFO_SRAM.sv PIFO_SRAM_TOP.sv} {
    if {![file exists [file join $rtl_dir $source_file]]} {
        error "missing source file: [file join $rtl_dir $source_file]"
    }
}

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

read_verilog -sv [list \
    [file join $rtl_dir INFER_SDPRAM.v] \
    [file join $rtl_dir TaskFIFO.sv] \
    [file join $rtl_dir TaskDistribute.sv] \
    [file join $rtl_dir PIFO_SRAM.sv] \
    [file join $rtl_dir PIFO_SRAM_TOP.sv]]
read_xdc $constraint_file

set generics [list \
    "PTW=$ptw" "MTW=$mtw" "CTW=$ctw" \
    "LEVEL=$bmw_level" "TREE_NUM=$instance_count" \
    "FIFO_SIZE=$fifo_size"]

synth_design -mode out_of_context -top PIFO_SRAM_TOP -part $part_name \
    -directive $synth_directive -generic $generics

set timing_summary_file [file join $report_dir \
    "${run_tag}_timing_summary.rpt"]
set utilization_file [file join $report_dir \
    "${run_tag}_utilization.rpt"]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file $timing_summary_file
report_utilization -file $utilization_file
report_utilization -hierarchical -file [file join $report_dir \
    "${run_tag}_utilization_hierarchical.rpt"]
report_timing -delay_type max -max_paths 100 -nworst 1 \
    -path_type full_clock_expanded -file [file join $report_dir \
    "${run_tag}_top100_paths.rpt"]
if {($ram_report_mode eq "detailed") &&
    ([llength [info commands report_ram_utilization]] != 0)} {
    report_ram_utilization -file [file join $report_dir \
        "${run_tag}_memory_utilization.rpt"]
}

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
puts $summary_file "VIVADO_VERSION=[version -short]"
puts $summary_file "SOURCE_MODE=$source_mode"
puts $summary_file "SOURCE_BASE=$source_base"
puts $summary_file "PUBLIC_GITHUB_COMMIT=03b4947"
puts $summary_file "TOP=PIFO_SRAM_TOP"
puts $summary_file "PART=$part_name"
puts $summary_file "SYNTH_DIRECTIVE=$synth_directive"
puts $summary_file "RAM_REPORT_MODE=$ram_report_mode"
puts $summary_file "CLOCK_PERIOD_NS=$clock_period_ns"
puts $summary_file "TARGET_FREQUENCY_MHZ=[expr {1000.0 / $clock_period_ns}]"
puts $summary_file "PTW=$ptw"
puts $summary_file "MTW=$mtw"
puts $summary_file "CTW=$ctw"
puts $summary_file "FIFO_SIZE=$fifo_size"
puts $summary_file "BMW_ORDER=$bmw_order"
puts $summary_file "BMW_LEVEL=$bmw_level"
puts $summary_file "INSTANCE_COUNT=$instance_count"
puts $summary_file "CAPACITY_PER_INSTANCE=$capacity"
puts $summary_file "TOTAL_CAPACITY=[expr {$capacity * $instance_count}]"
puts $summary_file "SRAM_BANKS=$bmw_level"
puts $summary_file "TREE_GROUPS=$tree_groups"
puts $summary_file "TREE_STRIDE_WORDS=$tree_stride_words"
puts $summary_file "PAPER_REQUIRED_DEPTH_PER_BANK=$paper_required_depth"
puts $summary_file "PAPER_SRAM_ADW=$paper_sram_adw"
puts $summary_file "PAPER_BINARY_DEPTH_PER_BANK=$paper_binary_depth"
puts $summary_file "GITHUB_VERBATIM_SRAM_ADW=$github_sram_adw"
puts $summary_file "GITHUB_VERBATIM_BINARY_DEPTH_PER_BANK=$github_binary_depth"
puts $summary_file "ELABORATED_SRAM_ADW=$elaborated_sram_adw"
puts $summary_file "ELABORATED_BINARY_DEPTH_PER_BANK=$elaborated_binary_depth"
puts $summary_file "CLB_LUT=$clb_luts"
puts $summary_file "LUT_AS_LOGIC=$logic_luts"
puts $summary_file "LUT_AS_MEMORY=$lutram_luts"
puts $summary_file "CLB_REGISTERS=$registers"

set worst_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $worst_path] == 0} {
    puts $summary_file "NO_SETUP_PATH=1"
} else {
    set worst_path [lindex $worst_path 0]
    set wns [get_property SLACK $worst_path]
    set achieved_period [expr {$clock_period_ns - $wns}]
    puts $summary_file "WNS=$wns"
    puts $summary_file "STARTPOINT=[get_property STARTPOINT_PIN $worst_path]"
    puts $summary_file "ENDPOINT=[get_property ENDPOINT_PIN $worst_path]"
    puts $summary_file "DATAPATH_DELAY=[get_property DATAPATH_DELAY $worst_path]"
    puts $summary_file "LOGIC_LEVELS=[get_property LOGIC_LEVELS $worst_path]"
    puts $summary_file "ACHIEVED_PERIOD_NS=$achieved_period"
    puts $summary_file "ESTIMATED_FMAX_MHZ=[expr {1000.0 / $achieved_period}]"
}
puts $summary_file "SYNTH_DCP=$synth_dcp"
close $summary_file

puts "PASS: original-paper synthesis reports written to $report_dir"
