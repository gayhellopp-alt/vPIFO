set script_dir [file dirname [file normalize [info script]]]
set run_tag stage8_parallel_kth_free_allocator
if {$argc > 0} {
    set run_tag [lindex $argv 0]
}
set run_dir [file join $script_dir \
    vivado_heterogeneous_300mhz_${run_tag}]
set report_dir [file join $run_dir reports]
open_checkpoint [file join $run_dir \
    heterogeneous_${run_tag}_ooc_synth.dcp]

set allocation_cells {}
foreach pattern {
    *logical_pending/allocation_plan_slot_reg*
    *logical_pending/allocation_plan_slot_mask_reg*
    *logical_pending/slot_reserved_reg*
} {
    set allocation_cells [concat $allocation_cells \
        [get_cells -quiet -hier -filter "NAME =~ $pattern"]]
}
set allocation_cells [lsort -unique $allocation_cells]
set allocation_d_pins [get_pins -quiet -of_objects $allocation_cells \
    -filter {REF_PIN_NAME == D}]

report_timing -delay_type max -max_paths 20 -nworst 1 \
    -to $allocation_d_pins -path_type full_clock_expanded \
    -file [file join $report_dir \
        ${run_tag}_allocator_top20_paths.rpt]

set output_file [open [file join $report_dir \
    ${run_tag}_allocator_machine_summary.txt] w]
puts $output_file "MATCHED_CELLS=[llength $allocation_cells]"
puts $output_file "MATCHED_D_PINS=[llength $allocation_d_pins]"
set worst_path [get_timing_paths -quiet -delay_type max \
    -to $allocation_d_pins -max_paths 1 -nworst 1]
if {[llength $worst_path] == 0} {
    puts $output_file "NO_PATH=1"
} else {
    set worst_path [lindex $worst_path 0]
    foreach property {
        SLACK STARTPOINT_PIN ENDPOINT_PIN DATAPATH_DELAY LOGIC_LEVELS
    } {
        puts $output_file \
            "$property=[get_property $property $worst_path]"
    }
}
close $output_file
puts "Stage8 directed allocator reports written to $report_dir"
