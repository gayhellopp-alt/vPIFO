# Vivado 2019.2 post-route physical-optimization comparison flow.
#
# Usage from this directory:
#   vivado -mode batch -source postroute_physopt_heterogeneous_dcp_300mhz.tcl \
#       -tclargs <routed.dcp> <run_tag>

set rtl_dir [file dirname [file normalize [info script]]]

if {$argc != 2} {
    error "expected arguments: <routed.dcp> <run_tag>"
}
set input_dcp [file normalize [lindex $argv 0]]
set run_tag [lindex $argv 1]
if {![file isfile $input_dcp]} {
    error "routed checkpoint does not exist: $input_dcp"
}
if {![regexp {^[A-Za-z0-9_]+$} $run_tag]} {
    error "run tag may contain only letters, digits, and underscores"
}

set build_dir [file join $rtl_dir \
    "vivado_heterogeneous_300mhz_${run_tag}_impl"]
set report_dir [file join $build_dir reports]
file mkdir $build_dir
file mkdir $report_dir

set_param general.maxThreads 8
open_checkpoint $input_dcp

phys_opt_design -directive AggressiveExplore
write_checkpoint -force \
    [file join $build_dir "heterogeneous_${run_tag}_postroute_phys_opt.dcp"]
route_design -directive Explore
write_checkpoint -force \
    [file join $build_dir "heterogeneous_${run_tag}_routed.dcp"]

report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir "${run_tag}_post_route_timing_summary.rpt"]
report_timing -delay_type max -max_paths 20 -nworst 1 \
    -path_type full_clock_expanded \
    -file [file join $report_dir "${run_tag}_post_route_top20_paths.rpt"]
report_utilization \
    -file [file join $report_dir "${run_tag}_post_route_utilization.rpt"]
report_route_status \
    -file [file join $report_dir "${run_tag}_route_status.rpt"]

set summary_file [open \
    [file join $report_dir "${run_tag}_post_route_machine_summary.txt"] w]
puts $summary_file "TOP=HeterogeneousPIFO"
puts $summary_file "PART=[get_property PART [current_design]]"
puts $summary_file "CLOCK_PORT=i_clk"
puts $summary_file "CLOCK_PERIOD_NS=3.333"
puts $summary_file "INPUT_DCP=$input_dcp"
puts $summary_file "POST_ROUTE_PHYS_OPT_DIRECTIVE=AggressiveExplore"
puts $summary_file "ROUTE_DIRECTIVE=Explore"

set worst_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $worst_path] == 0} {
    puts $summary_file "NO_SETUP_PATH=1"
} else {
    set worst_path [lindex $worst_path 0]
    set start_pin [get_property STARTPOINT_PIN $worst_path]
    set end_pin [get_property ENDPOINT_PIN $worst_path]
    puts $summary_file "WNS=[get_property SLACK $worst_path]"
    puts $summary_file "STARTPOINT=$start_pin"
    puts $summary_file "ENDPOINT=$end_pin"
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

puts "Post-route physical-optimization reports written to $report_dir"
