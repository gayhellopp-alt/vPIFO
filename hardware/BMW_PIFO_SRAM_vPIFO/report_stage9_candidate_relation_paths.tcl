set script_dir [file dirname [file normalize [info script]]]
set run_tag stage9_registered_candidate_relations
if {$argc > 0} {
    set run_tag [lindex $argv 0]
}
set run_dir [file join $script_dir \
    vivado_heterogeneous_300mhz_${run_tag}]
set report_dir [file join $run_dir reports]
open_checkpoint [file join $run_dir \
    heterogeneous_${run_tag}_ooc_synth.dcp]

proc report_path_group {group_name endpoint_pins report_dir run_tag} {
    report_timing -delay_type max -max_paths 20 -nworst 1 \
        -to $endpoint_pins -path_type full_clock_expanded \
        -file [file join $report_dir \
            ${run_tag}_${group_name}_top20_paths.rpt]

    set output_file [open [file join $report_dir \
        ${run_tag}_${group_name}_machine_summary.txt] w]
    puts $output_file "MATCHED_ENDPOINT_PINS=[llength $endpoint_pins]"
    set worst_path [get_timing_paths -quiet -delay_type max \
        -to $endpoint_pins -max_paths 1 -nworst 1]
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
}

set relation_cells [concat \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_pair_older_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_pair_same_event_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *logical_pending/o_head_pair_older_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *logical_pending/o_head_pair_same_event_reg*}]]
set relation_d_pins [get_pins -quiet -of_objects $relation_cells \
    -filter {REF_PIN_NAME == D}]

set retire_cells [get_cells -quiet -hier -filter \
    {NAME =~ *logical_pending/retire_slot_mask_reg*}]
set retire_d_pins [get_pins -quiet -of_objects $retire_cells \
    -filter {REF_PIN_NAME == D}]

set task_fifo_we_pins [get_pins -quiet -hier -filter \
    {NAME =~ *tf/buf_mem*/*/WE}]

report_path_group candidate_relations $relation_d_pins \
    $report_dir $run_tag
report_path_group retire_mask $retire_d_pins $report_dir $run_tag
report_path_group task_fifo_we $task_fifo_we_pins $report_dir $run_tag

puts "Stage9 directed path reports written to $report_dir"
