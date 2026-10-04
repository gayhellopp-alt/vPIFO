set script_dir [file dirname [file normalize [info script]]]
set run_tag stage15_accepted_taskfifo_we
if {$argc > 0} {
    set run_tag [lindex $argv 0]
}
set run_dir [file join $script_dir \
    vivado_heterogeneous_300mhz_${run_tag}]
set report_dir [file join $run_dir reports]
open_checkpoint [file join $run_dir \
    heterogeneous_${run_tag}_ooc_synth.dcp]

proc report_stage15_group {group_name endpoint_pins report_dir run_tag} {
    set output_file [open [file join $report_dir \
        ${run_tag}_${group_name}_machine_summary.txt] w]
    puts $output_file "MATCHED_ENDPOINT_PINS=[llength $endpoint_pins]"

    if {[llength $endpoint_pins] == 0} {
        puts $output_file "NO_PATH=1"
        close $output_file
        return
    }

    report_timing -delay_type max -max_paths 20 -nworst 1 \
        -to $endpoint_pins -path_type full_clock_expanded \
        -file [file join $report_dir \
            ${run_tag}_${group_name}_top20_paths.rpt]

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

set taskfifo_ram_cells [get_cells -quiet -hier -filter \
    {NAME =~ *tf/buf_mem_reg*}]
set taskfifo_we_pins [get_pins -quiet -of_objects $taskfifo_ram_cells \
    -filter {REF_PIN_NAME == WE}]
set taskfifo_data_pins [get_pins -quiet -of_objects $taskfifo_ram_cells \
    -filter {REF_PIN_NAME =~ D* || REF_PIN_NAME == I}]

set candidate_relation_cells [concat \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_pair_older_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_pair_same_event_reg*}]]
set candidate_relation_d_pins [get_pins -quiet \
    -of_objects $candidate_relation_cells -filter {REF_PIN_NAME == D}]

set candidate_partner_cells [concat \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_partner_slot_id_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_partner_valid_reg*}] \
    [get_cells -quiet -hier -filter \
        {NAME =~ *candidate_partner_resolved_reg*}]]
set candidate_partner_d_pins [get_pins -quiet \
    -of_objects $candidate_partner_cells -filter {REF_PIN_NAME == D}]

set retire_mask_cells [get_cells -quiet -hier -filter \
    {NAME =~ *logical_pending/retire_slot_mask_reg*}]
set retire_mask_d_pins [get_pins -quiet -of_objects $retire_mask_cells \
    -filter {REF_PIN_NAME == D}]

set directory_head_cells [get_cells -quiet -hier -filter \
    {NAME =~ *directory/o_shard_head_rank_reg*}]
set directory_head_d_pins [get_pins -quiet -of_objects $directory_head_cells \
    -filter {REF_PIN_NAME == D}]

report_stage15_group taskfifo_we $taskfifo_we_pins $report_dir $run_tag
report_stage15_group taskfifo_data $taskfifo_data_pins $report_dir $run_tag
report_stage15_group candidate_relation $candidate_relation_d_pins \
    $report_dir $run_tag
report_stage15_group candidate_partner $candidate_partner_d_pins \
    $report_dir $run_tag
report_stage15_group retire_mask $retire_mask_d_pins $report_dir $run_tag
report_stage15_group directory_head $directory_head_d_pins \
    $report_dir $run_tag

puts "Stage15 directed timing groups written to $report_dir"
