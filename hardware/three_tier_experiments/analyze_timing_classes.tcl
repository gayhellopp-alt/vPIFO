# Classify all failing setup endpoints in an existing synthesized DCP.
# Usage: vivado -mode batch -source analyze_timing_classes.tcl \
#        -tclargs <dcp> <output_report>

if {$argc != 2} {
    error "expected <dcp> <output_report>"
}

set dcp_path [file normalize [lindex $argv 0]]
set report_path [file normalize [lindex $argv 1]]
open_checkpoint $dcp_path

proc module_class {pin_name} {
    if {[string match "core/logical_pending/*" $pin_name]} {
        return "LRB"
    }
    if {[string match "core/directory/*" $pin_name]} {
        return "Directory"
    }
    if {[string match "core/engine/*" $pin_name]} {
        return "Engine"
    }
    if {[string match "core/pop_result_fifo/*" $pin_name]} {
        return "PopFIFO"
    }
    if {[string match "core/*" $pin_name]} {
        return "Core"
    }
    return "Top"
}

array set path_count {}
array set worst_slack {}
array set logic_level_sum {}
array set logic_level_max {}

set failing_paths [get_timing_paths -delay_type max \
    -slack_lesser_than 0.0 -max_paths 100000 -nworst 1]

foreach timing_path $failing_paths {
    set start_pin [get_property STARTPOINT_PIN $timing_path]
    set end_pin [get_property ENDPOINT_PIN $timing_path]
    set start_class [module_class $start_pin]
    set end_class [module_class $end_pin]
    set key "${start_class}->${end_class}"
    set slack [get_property SLACK $timing_path]
    set levels [get_property LOGIC_LEVELS $timing_path]

    if {![info exists path_count($key)]} {
        set path_count($key) 0
        set worst_slack($key) $slack
        set logic_level_sum($key) 0
        set logic_level_max($key) 0
    }
    incr path_count($key)
    set logic_level_sum($key) [expr {$logic_level_sum($key) + $levels}]
    if {$slack < $worst_slack($key)} {
        set worst_slack($key) $slack
    }
    if {$levels > $logic_level_max($key)} {
        set logic_level_max($key) $levels
    }
}

set output_file [open $report_path w]
puts $output_file "TOTAL_FAILING_ENDPOINTS=[llength $failing_paths]"
foreach key [lsort [array names path_count]] {
    puts $output_file \
        "$key count=$path_count($key) worst=$worst_slack($key) max_levels=$logic_level_max($key) avg_levels=[expr {double($logic_level_sum($key)) / $path_count($key)}]"
}
close $output_file
puts "PASS: wrote timing class report to $report_path"
