set script_dir [file dirname [file normalize [info script]]]
set run_tag stage14_parallel_partner_oldest
if {$argc > 0} {
    set run_tag [lindex $argv 0]
}
set run_dir [file join $script_dir \
    vivado_heterogeneous_300mhz_${run_tag}]
set report_dir [file join $run_dir reports]
open_checkpoint [file join $run_dir \
    heterogeneous_${run_tag}_ooc_synth.dcp]

proc report_stage14_partner_group {
        group_name source_pins endpoint_pins report_dir run_tag} {
    report_timing -delay_type max -max_paths 20 -nworst 1 \
        -from $source_pins -to $endpoint_pins \
        -path_type full_clock_expanded \
        -file [file join $report_dir \
            ${run_tag}_${group_name}_top20_paths.rpt]

    set output_file [open [file join $report_dir \
        ${run_tag}_${group_name}_machine_summary.txt] w]
    puts $output_file "MATCHED_SOURCE_PINS=[llength $source_pins]"
    puts $output_file "MATCHED_ENDPOINT_PINS=[llength $endpoint_pins]"
    set worst_path [get_timing_paths -quiet -delay_type max \
        -from $source_pins -to $endpoint_pins -max_paths 1 -nworst 1]
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

set partner_endpoint_cells [concat \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_partner_slot_id_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_partner_valid_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_partner_resolved_reg*}]]
set partner_endpoint_pins [get_pins -quiet \
    -of_objects $partner_endpoint_cells -filter {REF_PIN_NAME == D}]

set pending_partner_source_cells [concat \
    [get_cells -quiet -hier -filter \
        {NAME =~ *logical_pending/slot_valid_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *logical_pending/slot_push_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *logical_pending/slot_logical_id_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *logical_pending/slot_merge_slots_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *logical_pending/slot_older_reg*}]]
set pending_partner_source_pins [get_pins -quiet \
    -of_objects $pending_partner_source_cells -filter {DIRECTION == OUT}]

set primary_descriptor_cells [concat \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_partner_resolving_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_push_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_slot_id_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_merge_slots_reg*}]]
set primary_descriptor_source_pins [get_pins -quiet \
    -of_objects $primary_descriptor_cells -filter {DIRECTION == OUT}]

report_stage14_partner_group pending_state_to_partner \
    $pending_partner_source_pins $partner_endpoint_pins \
    $report_dir $run_tag
report_stage14_partner_group registered_primary_to_partner \
    $primary_descriptor_source_pins $partner_endpoint_pins \
    $report_dir $run_tag

puts "Stage14 partner path reports written to $report_dir"
