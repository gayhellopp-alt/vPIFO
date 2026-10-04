set script_dir [file dirname [file normalize [info script]]]
set run_tag stage5_registered_allocation_commit
set run_dir [file join $script_dir \
    vivado_heterogeneous_300mhz_${run_tag}]
set report_dir [file join $run_dir reports]
open_checkpoint [file join $run_dir \
    heterogeneous_${run_tag}_ooc_synth.dcp]

set output_file [open [file join $report_dir \
    ${run_tag}_selected_signal_fanout.txt] w]

proc report_group {channel group patterns} {
    set cells {}
    foreach pattern $patterns {
        set cells [concat $cells \
            [get_cells -quiet -hier -filter "NAME =~ $pattern"]]
    }
    set cells [lsort -unique $cells]
    set maximum_loads -1
    set maximum_cell ""
    set maximum_net ""
    foreach cell $cells {
        foreach output_pin [get_pins -quiet -of_objects $cell \
                -filter {DIRECTION == OUT}] {
            foreach net [get_nets -quiet -of_objects $output_pin] {
                set flat_pin_count [get_property FLAT_PIN_COUNT $net]
                set loads [expr {$flat_pin_count > 0 ? \
                    $flat_pin_count - 1 : 0}]
                if {$loads > $maximum_loads} {
                    set maximum_loads $loads
                    set maximum_cell $cell
                    set maximum_net $net
                }
            }
        }
    }
    puts $channel "GROUP=$group"
    puts $channel "MATCHED_CELLS=[llength $cells]"
    puts $channel "MAX_LOADS=$maximum_loads"
    puts $channel "MAX_CELL=$maximum_cell"
    puts $channel "MAX_NET=$maximum_net"
    puts $channel ""
}

report_group $output_file slot_reserved {
    *logical_pending/slot_reserved_reg*
}
report_group $output_file allocation_plan_valid {
    *logical_pending/allocation_plan_valid_reg*
}
report_group $output_file allocation_plan_slot {
    *logical_pending/allocation_plan_slot_reg*
}
report_group $output_file allocation_plan_slot_mask {
    *logical_pending/allocation_plan_slot_mask_reg*
}
report_group $output_file candidate_dispatch_ready {
    *candidate_dispatch_ready_reg*
}
report_group $output_file candidate_slot_id {
    *candidate_slot_id_reg*
}
report_group $output_file retire_slot_mask {
    *logical_pending/retire_slot_mask_reg*
}
report_group $output_file directory_update_pending {
    *directory/o_update_pending_reg*
}

close $output_file
puts "Stage5 selected-signal fanout report written to $report_dir"
