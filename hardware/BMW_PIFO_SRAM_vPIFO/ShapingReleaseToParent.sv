`timescale 1ns / 10ps

// Scheduling admission policy at the shaping -> parent boundary.
//
// Direct packet scheduling work always wins over a shaping release.  An
// external scheduling Pop also blocks shaping admission for that cycle.  The
// parent is nevertheless free to accept a direct Push and a Pop together;
// HierarchicalHeterogeneousPIFO treats those as scheduling operations and
// reserves the required shared pending slots atomically.
module ShapingReleaseToParent #(
    parameter LOGICAL_ID_WIDTH = 2,
    parameter PRIORITY_WIDTH = 16,
    parameter DATA_WIDTH = 32
)(
    input  wire                         i_direct_valid,
    output wire                         o_direct_ready,
    input  wire [LOGICAL_ID_WIDTH-1:0]  i_direct_leaf_tree_id,
    input  wire [PRIORITY_WIDTH-1:0]    i_direct_priority,
    input  wire [DATA_WIDTH-1:0]        i_direct_data,

    // "Present", rather than "fire", is intentional.  Scheduling requests
    // retain priority while backpressured, so release order is independent of
    // transient parent capacity.
    input  wire                         i_scheduling_pop_present,

    input  wire                         i_shaping_valid,
    output wire                         o_shaping_ready,
    input  wire [LOGICAL_ID_WIDTH-1:0]  i_shaping_leaf_tree_id,
    input  wire [PRIORITY_WIDTH-1:0]    i_shaping_priority,
    input  wire [DATA_WIDTH-1:0]        i_shaping_data,

    output wire                         o_parent_valid,
    input  wire                         i_parent_ready,
    output wire [LOGICAL_ID_WIDTH-1:0]  o_parent_leaf_tree_id,
    output wire [PRIORITY_WIDTH-1:0]    o_parent_priority,
    output wire [DATA_WIDTH-1:0]        o_parent_data,

    output wire                         o_direct_fire,
    output wire                         o_shaping_fire,
    output wire                         o_shaping_deferred,
    output wire                         o_deferred_by_direct_push,
    output wire                         o_deferred_by_scheduling_pop,
    output wire                         o_deferred_by_parent_backpressure
);

    wire shaping_selected =
        i_shaping_valid && !i_direct_valid &&
        !i_scheduling_pop_present;

    assign o_parent_valid = i_direct_valid || shaping_selected;
    assign o_parent_leaf_tree_id = i_direct_valid ?
        i_direct_leaf_tree_id : i_shaping_leaf_tree_id;
    assign o_parent_priority = i_direct_valid ?
        i_direct_priority : i_shaping_priority;
    assign o_parent_data = i_direct_valid ?
        i_direct_data : i_shaping_data;

    assign o_direct_ready = i_parent_ready;
    assign o_shaping_ready =
        !i_direct_valid && !i_scheduling_pop_present && i_parent_ready;

    assign o_direct_fire = i_direct_valid && o_direct_ready;
    assign o_shaping_fire = i_shaping_valid && o_shaping_ready;
    assign o_shaping_deferred = i_shaping_valid && !o_shaping_ready;
    assign o_deferred_by_direct_push =
        i_shaping_valid && i_direct_valid;
    assign o_deferred_by_scheduling_pop =
        i_shaping_valid && !i_direct_valid &&
        i_scheduling_pop_present;
    assign o_deferred_by_parent_backpressure =
        i_shaping_valid && !i_direct_valid &&
        !i_scheduling_pop_present && !i_parent_ready;

    initial begin
        if ((LOGICAL_ID_WIDTH < 1) || (PRIORITY_WIDTH < 1) ||
            (DATA_WIDTH < 1))
            $fatal(1, "ShapingReleaseToParent widths must be positive");
    end

endmodule
