# Vivado 2019.2 non-project OOC synthesis/implementation for HeterogeneousPIFO.
# Usage from this directory:
#   vivado -mode batch -source impl_heterogeneous_300mhz_ooc.tcl

set rtl_dir [file dirname [file normalize [info script]]]
source [file join $rtl_dir generated vpifo_config.tcl]
set build_dir [file join $rtl_dir vivado_heterogeneous_300mhz_ooc]
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
    -directive PerformanceOptimized \
    -fanout_limit 400 \
    -fsm_extraction one_hot \
    -keep_equivalent_registers \
    -resource_sharing off \
    -no_lc \
    -shreg_min_size 5

report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir ooc_synth_timing_summary.rpt]
report_utilization \
    -file [file join $report_dir ooc_synth_utilization.rpt]
report_utilization -hierarchical \
    -file [file join $report_dir ooc_synth_utilization_hierarchical.rpt]
report_timing -delay_type max -max_paths 10 -nworst 1 \
    -path_type full_clock_expanded \
    -file [file join $report_dir ooc_synth_top10_paths.rpt]
report_high_fanout_nets -timing -load_types -max_nets 100 \
    -fanout_greater_than 50 \
    -file [file join $report_dir ooc_synth_high_fanout_nets.rpt]
write_checkpoint -force \
    [file join $build_dir heterogeneous_ooc_synth.dcp]

opt_design -directive Explore
write_checkpoint -force \
    [file join $build_dir heterogeneous_ooc_opt.dcp]

place_design -directive Explore
write_checkpoint -force \
    [file join $build_dir heterogeneous_ooc_placed.dcp]

phys_opt_design -directive Explore
write_checkpoint -force \
    [file join $build_dir heterogeneous_ooc_phys_opt.dcp]

route_design -directive Explore
write_checkpoint -force \
    [file join $build_dir heterogeneous_ooc_routed.dcp]

report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir ooc_post_route_timing_summary.rpt]
report_utilization \
    -file [file join $report_dir ooc_post_route_utilization.rpt]
report_utilization -hierarchical \
    -file [file join $report_dir ooc_post_route_utilization_hierarchical.rpt]
report_timing -delay_type max -max_paths 10 -nworst 1 \
    -path_type full_clock_expanded \
    -file [file join $report_dir ooc_post_route_top10_paths.rpt]
report_timing -delay_type max -max_paths 1 -nworst 1 \
    -path_type full_clock_expanded \
    -file [file join $report_dir ooc_critical_path_detail.rpt]
report_high_fanout_nets -timing -slr \
    -max_nets 100 -fanout_greater_than 50 \
    -file [file join $report_dir ooc_post_route_high_fanout_nets.rpt]
report_methodology \
    -file [file join $report_dir ooc_report_methodology.rpt]
report_route_status \
    -file [file join $report_dir ooc_report_route_status.rpt]
report_clock_utilization \
    -file [file join $report_dir ooc_post_route_clock_utilization.rpt]

set summary_file [open \
    [file join $report_dir ooc_machine_summary.txt] w]
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
puts $summary_file "SHARD_COUNTS=$vpifo_shard_counts"
puts $summary_file "SHARD_OFFSETS=$vpifo_shard_offsets"

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

    if {[catch {
        set start_cell [get_cells -quiet -of_objects $start_pin]
        set end_cell [get_cells -quiet -of_objects $end_pin]
        set start_slr [get_slrs -quiet -of_objects $start_cell]
        set end_slr [get_slrs -quiet -of_objects $end_cell]
        puts $summary_file "START_SLR=$start_slr"
        puts $summary_file "END_SLR=$end_slr"
        puts $summary_file \
            "CROSSES_SLR=[expr {$start_slr ne $end_slr}]"
    } slr_error]} {
        puts $summary_file "SLR_QUERY_ERROR=$slr_error"
    }
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

puts "OOC implementation reports written to $report_dir"
