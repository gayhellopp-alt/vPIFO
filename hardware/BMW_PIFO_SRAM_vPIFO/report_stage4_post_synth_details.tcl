set script_dir [file dirname [file normalize [info script]]]
set run_dir [file join $script_dir \
    vivado_heterogeneous_300mhz_stage4_partner_pipeline]
set report_dir [file join $run_dir reports]
set checkpoint [file join $run_dir \
    heterogeneous_stage4_partner_pipeline_ooc_synth.dcp]

open_checkpoint $checkpoint

proc matching_cells {pattern} {
    return [get_cells -quiet -hier -filter "NAME =~ $pattern"]
}

proc data_pins_for_cells {cells} {
    if {[llength $cells] == 0} {
        return {}
    }
    return [get_pins -quiet -of_objects $cells \
        -filter {REF_PIN_NAME == D}]
}

proc output_pins_for_cells {cells} {
    if {[llength $cells] == 0} {
        return {}
    }
    return [get_pins -quiet -of_objects $cells \
        -filter {DIRECTION == OUT}]
}

set category_file [open [file join $report_dir \
    stage4_partner_pipeline_category_summary.txt] w]

proc report_category {channel name cell_patterns} {
    set cells {}
    foreach pattern $cell_patterns {
        set cells [concat $cells [matching_cells $pattern]]
    }
    set cells [lsort -unique $cells]
    set data_pins [data_pins_for_cells $cells]
    puts $channel "CATEGORY=$name"
    puts $channel "MATCHED_CELLS=[llength $cells]"
    puts $channel "MATCHED_D_PINS=[llength $data_pins]"
    if {[llength $data_pins] == 0} {
        puts $channel "NO_PATH=1"
        puts $channel ""
        return
    }
    set paths [get_timing_paths -quiet -delay_type max \
        -to $data_pins -max_paths 1 -nworst 1]
    if {[llength $paths] == 0} {
        puts $channel "NO_PATH=1"
        puts $channel ""
        return
    }
    set timing_path [lindex $paths 0]
    foreach property {
        SLACK STARTPOINT_PIN ENDPOINT_PIN DATAPATH_DELAY LOGIC_LEVELS
    } {
        puts $channel "$property=[get_property $property $timing_path]"
    }
    foreach property {
        DATAPATH_LOGIC_DELAY DATAPATH_NET_DELAY
    } {
        if {[lsearch -exact [list_property $timing_path] $property] >= 0} {
            puts $channel "$property=[get_property $property $timing_path]"
        }
    }
    puts $channel ""
}

proc report_category_from_to {
    channel name source_cell_patterns destination_cell_patterns
} {
    set source_cells {}
    foreach pattern $source_cell_patterns {
        set source_cells [concat $source_cells [matching_cells $pattern]]
    }
    set source_cells [lsort -unique $source_cells]
    set source_pins [output_pins_for_cells $source_cells]
    set destination_cells {}
    foreach pattern $destination_cell_patterns {
        set destination_cells [concat $destination_cells \
            [matching_cells $pattern]]
    }
    set destination_cells [lsort -unique $destination_cells]
    set destination_pins [data_pins_for_cells $destination_cells]
    puts $channel "CATEGORY=$name"
    puts $channel "MATCHED_SOURCE_CELLS=[llength $source_cells]"
    puts $channel "MATCHED_SOURCE_PINS=[llength $source_pins]"
    puts $channel \
        "MATCHED_DESTINATION_CELLS=[llength $destination_cells]"
    puts $channel \
        "MATCHED_DESTINATION_D_PINS=[llength $destination_pins]"
    if {
        [llength $source_pins] == 0 ||
        [llength $destination_pins] == 0
    } {
        puts $channel "NO_PATH=1"
        puts $channel ""
        return
    }
    set paths [get_timing_paths -quiet -delay_type max \
        -from $source_pins -to $destination_pins \
        -max_paths 1 -nworst 1]
    if {[llength $paths] == 0} {
        puts $channel "NO_PATH=1"
        puts $channel ""
        return
    }
    set timing_path [lindex $paths 0]
    foreach property {
        SLACK STARTPOINT_PIN ENDPOINT_PIN DATAPATH_DELAY LOGIC_LEVELS
    } {
        puts $channel "$property=[get_property $property $timing_path]"
    }
    foreach property {
        DATAPATH_LOGIC_DELAY DATAPATH_NET_DELAY
    } {
        if {[lsearch -exact [list_property $timing_path] $property] >= 0} {
            puts $channel "$property=[get_property $property $timing_path]"
        }
    }
    puts $channel ""
}

report_category $category_file pending_to_primary {
    *candidate_slot_id_reg*
    *candidate_merge_slots_reg*
    *candidate_push_reg*
    *candidate_push_data_reg*
    *candidate_source_port_reg*
}
report_category $category_file registered_primary_to_partner {
    *candidate_partner_slot_id_reg*
    *candidate_partner_valid_reg*
}
report_category $category_file partner_to_ready {
    *candidate_dispatch_ready_reg*
    *candidate_partner_resolving_reg*
}
report_category $category_file dispatch_to_retire {
    *retire_slot_mask_reg*
}
report_category $category_file pending_state_update {
    *slot_older_reg*
    *slot_merge_slots_reg*
    *slot_valid_reg*
}
report_category_from_to $category_file \
    registered_primary_data_to_partner {
        *candidate_slot_id_reg*
        *candidate_merge_slots_reg*
        *candidate_push_reg*
    } {
        *candidate_partner_slot_id_reg*
        *candidate_partner_valid_reg*
    }
report_category_from_to $category_file \
    resolving_state_to_ready {
        *candidate_partner_resolving_reg*
    } {
        *candidate_dispatch_ready_reg*
    }
close $category_file

set storage_file [open [file join $report_dir \
    stage4_partner_pipeline_storage_mapping.txt] w]

proc report_storage {channel name cell_patterns} {
    set cells {}
    foreach pattern $cell_patterns {
        set cells [concat $cells [matching_cells $pattern]]
    }
    set cells [lsort -unique $cells]
    set sequential_cells {}
    foreach cell $cells {
        if {[get_property IS_SEQUENTIAL $cell]} {
            lappend sequential_cells $cell
        }
    }
    puts $channel "STATE=$name"
    puts $channel "MATCHED_CELLS=[llength $cells]"
    puts $channel "SEQUENTIAL_CELLS=[llength $sequential_cells]"
    array unset counts
    foreach cell $sequential_cells {
        set ref_name [get_property REF_NAME $cell]
        if {$ref_name eq ""} {
            set ref_name UNKNOWN
        }
        if {![info exists counts($ref_name)]} {
            set counts($ref_name) 0
        }
        incr counts($ref_name)
    }
    foreach ref_name [lsort [array names counts]] {
        puts $channel "$ref_name=$counts($ref_name)"
    }
    puts $channel ""
}

report_storage $storage_file slot_valid {
    *logical_pending/slot_valid_reg*
}
report_storage $storage_file slot_logical_id {
    *logical_pending/slot_logical_id_reg*
}
report_storage $storage_file slot_older {
    *logical_pending/slot_older_reg*
}
report_storage $storage_file slot_merge_slots {
    *logical_pending/slot_merge_slots_reg*
}
report_storage $storage_file slot_request_fields {
    *logical_pending/slot_push_reg*
    *logical_pending/slot_push_data_reg*
    *logical_pending/slot_source_port_reg*
    *logical_pending/slot_order_reg*
}
report_storage $storage_file candidate_description {
    *candidate_primary_valid_reg*
    *candidate_partner_resolving_reg*
    *candidate_dispatch_ready_reg*
    *candidate_push_reg*
    *candidate_push_data_reg*
    *candidate_source_port_reg*
    *candidate_slot_id_reg*
    *candidate_merge_slots_reg*
    *candidate_partner_valid_reg*
    *candidate_partner_slot_id_reg*
}
report_storage $storage_file candidate_primary_state {
    *candidate_primary_valid_reg*
    *candidate_partner_resolving_reg*
    *candidate_dispatch_ready_reg*
}
report_storage $storage_file candidate_primary_request {
    *candidate_push_reg*
    *candidate_push_data_reg*
    *candidate_source_port_reg*
    *candidate_slot_id_reg*
    *candidate_merge_slots_reg*
}
report_storage $storage_file candidate_partner_result {
    *candidate_partner_valid_reg*
    *candidate_partner_slot_id_reg*
}
report_storage $storage_file retire_description {
    *logical_pending/retire_slot_mask_reg*
    *logical_pending/retire_check_valid_reg*
    *logical_pending/retire_check_primary_slot_id_reg*
    *logical_pending/retire_check_partner_valid_reg*
    *logical_pending/retire_check_partner_slot_id_reg*
}

set directory_cells [matching_cells directory/*]
set directory_seq {}
foreach cell $directory_cells {
    if {[get_property IS_SEQUENTIAL $cell]} {
        lappend directory_seq $cell
    }
}
puts $storage_file "STATE=shard_directory_sequential"
puts $storage_file "MATCHED_CELLS=[llength $directory_seq]"
array unset directory_counts
foreach cell $directory_seq {
    set ref_name [get_property REF_NAME $cell]
    if {![info exists directory_counts($ref_name)]} {
        set directory_counts($ref_name) 0
    }
    incr directory_counts($ref_name)
}
foreach ref_name [lsort [array names directory_counts]] {
    puts $storage_file "$ref_name=$directory_counts($ref_name)"
}
puts $storage_file ""

foreach primitive {RAMB18E2 RAMB36E2 RAM256X1D RAM32M16} {
    set primitive_cells [get_cells -quiet -hier \
        -filter "REF_NAME == $primitive"]
    puts $storage_file \
        "DESIGN_PRIMITIVE_${primitive}=[llength $primitive_cells]"
}
close $storage_file

puts "Stage4 post-synthesis detail reports written to $report_dir"
