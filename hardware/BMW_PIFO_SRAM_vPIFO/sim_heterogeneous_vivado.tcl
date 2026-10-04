# Usage:
#   vivado -mode batch -source sim_heterogeneous_vivado.tcl
#   vivado -mode batch -source sim_heterogeneous_vivado.tcl -tclargs directory
#   vivado -mode batch -source sim_heterogeneous_vivado.tcl -tclargs duplicate_update
#   vivado -mode batch -source sim_heterogeneous_vivado.tcl -tclargs fifo
#   vivado -mode batch -source sim_heterogeneous_vivado.tcl -tclargs pending
#   vivado -mode batch -source sim_heterogeneous_vivado.tcl -tclargs performance
#   vivado -mode batch -source sim_heterogeneous_vivado.tcl -tclargs multi_pop
#   vivado -mode batch -source sim_heterogeneous_vivado.tcl -tclargs warm_reset
#   vivado -mode batch -source sim_heterogeneous_vivado.tcl -tclargs hierarchical
#   vivado -mode batch -source sim_heterogeneous_vivado.tcl -tclargs hierarchical_alt

set test_name "heterogeneous"
if {$argc > 0} {
    set test_name [lindex $argv 0]
}
if {$test_name ni {heterogeneous performance multi_pop warm_reset directory duplicate_update fifo pending hierarchical hierarchical_alt}} {
    error "invalid heterogeneous test name"
}

set rtl_dir [file dirname [file normalize [info script]]]
set config_pkg [file join $rtl_dir generated vpifo_config_pkg.sv]
set sim_project_dir [file join $rtl_dir vivado_validation_xsim_work $test_name]
create_project -force vpifo_heterogeneous_sim $sim_project_dir \
    -part xcu200-fsgd2104-2-e
set_property target_language Verilog [current_project]

if {$test_name eq "directory"} {
    add_files -norecurse [list \
        $config_pkg \
        [file join $rtl_dir ShardDirectory.sv]]
    add_files -fileset sim_1 -norecurse [list \
        [file join $rtl_dir ShardDirectory_tb.sv]]
    set_property top ShardDirectory_tb [get_filesets sim_1]
} elseif {$test_name eq "duplicate_update"} {
    add_files -norecurse [list \
        $config_pkg \
        [file join $rtl_dir ShardDirectory.sv]]
    add_files -fileset sim_1 -norecurse [list \
        [file join $rtl_dir ShardDirectory_duplicate_update_tb.sv]]
    set_property top ShardDirectory_duplicate_update_tb [get_filesets sim_1]
} elseif {$test_name eq "fifo"} {
    add_files -norecurse [list \
        [file join $rtl_dir PopResultFIFO.sv]]
    add_files -fileset sim_1 -norecurse [list \
        [file join $rtl_dir PopResultFIFO_tb.sv]]
    set_property top PopResultFIFO_tb [get_filesets sim_1]
} elseif {$test_name eq "pending"} {
    add_files -norecurse [list \
        [file join $rtl_dir LogicalRequestBuffer.sv]]
    add_files -fileset sim_1 -norecurse [list \
        [file join $rtl_dir LogicalRequestBuffer_tb.sv]]
    set_property top LogicalRequestBuffer_tb [get_filesets sim_1]
} elseif {$test_name in {heterogeneous performance multi_pop warm_reset}} {
    add_files -norecurse [list \
        $config_pkg \
        [file join $rtl_dir INFER_SDPRAM.v] \
        [file join $rtl_dir TaskFIFO.sv] \
        [file join $rtl_dir TaskDistribute.sv] \
        [file join $rtl_dir PIFO_SRAM.sv] \
        [file join $rtl_dir PIFO_SRAM_TOP.sv] \
        [file join $rtl_dir ShardDirectory.sv] \
        [file join $rtl_dir PopResultFIFO.sv] \
        [file join $rtl_dir LogicalRequestBuffer.sv] \
        [file join $rtl_dir HeterogeneousPIFO.sv]]
    if {$test_name eq "performance"} {
        add_files -fileset sim_1 -norecurse [list \
            [file join $rtl_dir HeterogeneousPIFO_perf_tb.sv]]
        set_property top HeterogeneousPIFO_perf_tb [get_filesets sim_1]
    } elseif {$test_name eq "multi_pop"} {
        add_files -fileset sim_1 -norecurse [list \
            [file join $rtl_dir HeterogeneousPIFO_multi_pop_tb.sv]]
        set_property top HeterogeneousPIFO_multi_pop_tb [get_filesets sim_1]
    } elseif {$test_name eq "warm_reset"} {
        add_files -fileset sim_1 -norecurse [list \
            [file join $rtl_dir HeterogeneousPIFO_warm_reset_tb.sv]]
        set_property top HeterogeneousPIFO_warm_reset_tb [get_filesets sim_1]
    } else {
        add_files -fileset sim_1 -norecurse [list \
            [file join $rtl_dir HeterogeneousPIFO_tb.sv]]
        set_property top HeterogeneousPIFO_tb [get_filesets sim_1]
    }
} else {
    add_files -norecurse [list \
        $config_pkg \
        [file join $rtl_dir INFER_SDPRAM.v] \
        [file join $rtl_dir TaskFIFO.sv] \
        [file join $rtl_dir TaskDistribute.sv] \
        [file join $rtl_dir PIFO_SRAM.sv] \
        [file join $rtl_dir PIFO_SRAM_TOP.sv] \
        [file join $rtl_dir ShardDirectory.sv] \
        [file join $rtl_dir PopResultFIFO.sv] \
        [file join $rtl_dir LogicalRequestBuffer.sv] \
        [file join $rtl_dir HeterogeneousPIFO.sv] \
        [file join $rtl_dir HierarchicalHeterogeneousPIFO.sv]]
    if {$test_name eq "hierarchical"} {
        add_files -fileset sim_1 -norecurse [list \
            [file join $rtl_dir HierarchicalHeterogeneousPIFO_tb.sv]]
        set_property top HierarchicalHeterogeneousPIFO_tb [get_filesets sim_1]
    } else {
        add_files -fileset sim_1 -norecurse [list \
            [file join $rtl_dir HierarchicalHeterogeneousPIFO_alt_tb.sv]]
        set_property top HierarchicalHeterogeneousPIFO_alt_tb [get_filesets sim_1]
    }
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
set_property xsim.simulate.runtime all [get_filesets sim_1]
launch_simulation
close_sim
