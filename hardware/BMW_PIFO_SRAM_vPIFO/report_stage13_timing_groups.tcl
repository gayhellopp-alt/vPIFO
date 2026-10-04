set script_dir [file dirname [file normalize [info script]]]
set run_tag stage13_parallel_pop_result_fifo
if {$argc > 0} {
    set run_tag [lindex $argv 0]
}
set run_dir [file join $script_dir \
    vivado_heterogeneous_300mhz_${run_tag}]
set report_dir [file join $run_dir reports]
open_checkpoint [file join $run_dir \
    heterogeneous_${run_tag}_ooc_synth.dcp]

proc report_stage13_group {group_name endpoint_pins report_dir run_tag} {
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

set pop_result_cells [concat \
    [get_cells -quiet -hier -filter \
        {NAME =~ *pop_result_fifo/o_count_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *pop_result_fifo/o_tail_ptr_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *pop_result_fifo/o_enqueued_count_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *pop_result_fifo/storage_data_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *pop_result_fifo/storage_logical_id_reg*}]]
set pop_result_d_pins [get_pins -quiet -of_objects $pop_result_cells \
    -filter {REF_PIN_NAME == D}]

set candidate_partner_cells [concat \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_partner_slot_id_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_partner_valid_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_partner_resolved_reg*}]]
set candidate_partner_d_pins [get_pins -quiet \
    -of_objects $candidate_partner_cells -filter {REF_PIN_NAME == D}]

report_stage13_group pop_result_state $pop_result_d_pins \
    $report_dir $run_tag
report_stage13_group candidate_partner $candidate_partner_d_pins \
    $report_dir $run_tag

puts "Stage13 directed timing groups written to $report_dir"
