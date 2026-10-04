# Vivado batch synthesis/implementation for the heterogeneous PIFO timing cut.
# Usage from this directory:
#   vivado -mode batch -source impl_heterogeneous_300mhz.tcl

set rtl_dir [file dirname [file normalize [info script]]]
set build_dir [file join $rtl_dir vivado_heterogeneous_300mhz]
set report_dir [file join $build_dir reports]
file mkdir $report_dir

create_project -force vpifo_heterogeneous_300mhz $build_dir \
    -part xcu200-fsgd2104-2-e
set_property target_language Verilog [current_project]

add_files -norecurse [list \
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
add_files -fileset constrs_1 -norecurse [list \
    [file join $rtl_dir heterogeneous_300mhz.xdc]]

set_property top HeterogeneousPIFO [get_filesets sources_1]
update_compile_order -fileset sources_1

set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_Explore [get_runs impl_1]

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "synth_1 did not complete"
}

open_run synth_1
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir synth_timing_summary.rpt]
report_utilization \
    -file [file join $report_dir synth_utilization.rpt]
report_utilization -hierarchical \
    -file [file join $report_dir synth_utilization_hierarchical.rpt]
report_timing -delay_type max -max_paths 10 -nworst 1 \
    -path_type full_clock_expanded \
    -file [file join $report_dir synth_top10_paths.rpt]
report_high_fanout_nets -timing -load_types -max_nets 100 \
    -fanout_greater_than 50 \
    -file [file join $report_dir synth_high_fanout_nets.rpt]
write_checkpoint -force \
    [file join $build_dir heterogeneous_synth.dcp]
close_design

launch_runs impl_1 -to_step route_design -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "impl_1 did not complete"
}
open_run impl_1

report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir post_route_timing_summary.rpt]
report_utilization \
    -file [file join $report_dir post_route_utilization.rpt]
report_utilization -hierarchical \
    -file [file join $report_dir post_route_utilization_hierarchical.rpt]
report_timing -delay_type max -max_paths 10 -nworst 1 \
    -path_type full_clock_expanded \
    -file [file join $report_dir post_route_top10_paths.rpt]
report_timing -delay_type max -max_paths 1 -nworst 1 \
    -path_type full_clock_expanded \
    -file [file join $report_dir critical_path_detail.rpt]
report_high_fanout_nets -timing -clock_regions -slr \
    -max_nets 100 -fanout_greater_than 50 \
    -file [file join $report_dir post_route_high_fanout_nets.rpt]
report_methodology \
    -file [file join $report_dir report_methodology.rpt]
report_route_status \
    -file [file join $report_dir report_route_status.rpt]
report_clock_utilization \
    -file [file join $report_dir post_route_clock_utilization.rpt]

set summary_file [open [file join $report_dir machine_summary.txt] w]
set worst_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $worst_path] == 0} {
    puts $summary_file "No setup timing path found"
} else {
    puts $summary_file "WNS=[get_property SLACK $worst_path]"
    puts $summary_file "STARTPOINT=[get_property STARTPOINT_PIN $worst_path]"
    puts $summary_file "ENDPOINT=[get_property ENDPOINT_PIN $worst_path]"
    puts $summary_file "DATAPATH_DELAY=[get_property DATAPATH_DELAY $worst_path]"
    puts $summary_file "LOGIC_LEVELS=[get_property LOGIC_LEVELS $worst_path]"
}

set tns 0.0
set violating_paths [get_timing_paths -delay_type max -slack_lesser_than 0.0 \
    -max_paths 100000 -nworst 1]
foreach timing_path $violating_paths {
    set tns [expr {$tns + [get_property SLACK $timing_path]}]
}
puts $summary_file "TNS=$tns"
puts $summary_file "VIOLATING_ENDPOINTS=[llength $violating_paths]"
close $summary_file

write_checkpoint -force [file join $build_dir heterogeneous_routed.dcp]
puts "Implementation reports written to $report_dir"
