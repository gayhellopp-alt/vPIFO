`timescale 1ns / 10ps

// Select the due prefix of all logical shaping heads in global
// (release_time, sequence, logical_id) order.  An older unavailable head is a
// barrier; it is never skipped in favor of a later rank.  One outstanding Pop
// per logical PIFO is represented by i_reserved, and such a head may be skipped
// because its rank is already protected by the completion reorder state.
module ShapingDueArbiter #(
    parameter LOGICAL_TREE_NUM = 2,
    parameter PHYSICAL_TREE_NUM = 3,
    parameter TIME_WIDTH = 16,
    parameter SEQUENCE_WIDTH = 8,
    parameter ISSUE_PORTS = 2,
    localparam RANK_WIDTH = TIME_WIDTH + SEQUENCE_WIDTH,
    localparam LOGICAL_ID_WIDTH = (LOGICAL_TREE_NUM <= 1) ? 1 :
                                  $clog2(LOGICAL_TREE_NUM),
    localparam PHYSICAL_ID_WIDTH = (PHYSICAL_TREE_NUM <= 1) ? 1 :
                                   $clog2(PHYSICAL_TREE_NUM),
    localparam ISSUE_COUNT_WIDTH = (ISSUE_PORTS <= 1) ? 1 :
                                   $clog2(ISSUE_PORTS + 1)
)(
    input  wire [TIME_WIDTH-1:0]        i_time,
    input  wire [LOGICAL_TREE_NUM-1:0]  i_head_valid,
    input  wire [RANK_WIDTH-1:0]        i_head_rank [0:LOGICAL_TREE_NUM-1],
    input  wire [PHYSICAL_ID_WIDTH-1:0] i_head_physical_tree_id [0:LOGICAL_TREE_NUM-1],
    input  wire [LOGICAL_TREE_NUM-1:0]  i_logical_busy,
    input  wire [LOGICAL_TREE_NUM-1:0]  i_logical_pending,
    input  wire [LOGICAL_TREE_NUM-1:0]  i_reserved,
    input  wire [LOGICAL_TREE_NUM-1:0]  i_blocked,
    input  wire                         i_global_barrier,
    input  wire [ISSUE_COUNT_WIDTH-1:0] i_issue_limit,
    output reg  [ISSUE_PORTS-1:0]       o_issue_valid,
    output reg  [LOGICAL_ID_WIDTH-1:0]  o_issue_logical_tree_id [0:ISSUE_PORTS-1],
    output reg  [PHYSICAL_ID_WIDTH-1:0] o_issue_physical_tree_id [0:ISSUE_PORTS-1],
    output reg  [RANK_WIDTH-1:0]        o_issue_rank [0:ISSUE_PORTS-1],
    output reg  [ISSUE_COUNT_WIDTH-1:0] o_issue_count
);

    reg [LOGICAL_TREE_NUM-1:0] selected_logical;
    reg best_found;
    reg best_eligible;
    reg [RANK_WIDTH-1:0] best_rank;
    integer best_logical;
    integer issue_slot;
    integer logical_scan;

    always @* begin
        o_issue_valid = {ISSUE_PORTS{1'b0}};
        o_issue_count = {ISSUE_COUNT_WIDTH{1'b0}};
        selected_logical = {LOGICAL_TREE_NUM{1'b0}};
        for (issue_slot = 0; issue_slot < ISSUE_PORTS;
             issue_slot = issue_slot + 1) begin
            o_issue_logical_tree_id[issue_slot] =
                {LOGICAL_ID_WIDTH{1'b0}};
            o_issue_physical_tree_id[issue_slot] =
                {PHYSICAL_ID_WIDTH{1'b0}};
            o_issue_rank[issue_slot] = {RANK_WIDTH{1'b1}};
            best_found = 1'b0;
            best_eligible = 1'b0;
            best_rank = {RANK_WIDTH{1'b1}};
            best_logical = 0;
            for (logical_scan = 0; logical_scan < LOGICAL_TREE_NUM;
                 logical_scan = logical_scan + 1) begin
                if (!selected_logical[logical_scan] &&
                    i_head_valid[logical_scan] &&
                    !i_reserved[logical_scan] &&
                    (!best_found ||
                     (i_head_rank[logical_scan] < best_rank) ||
                     ((i_head_rank[logical_scan] == best_rank) &&
                      (logical_scan < best_logical)))) begin
                    best_found = 1'b1;
                    best_rank = i_head_rank[logical_scan];
                    best_logical = logical_scan;
                end
            end
            if (best_found) begin
                best_eligible = !i_global_barrier &&
                    !i_logical_busy[best_logical] &&
                    !i_logical_pending[best_logical] &&
                    !i_blocked[best_logical] &&
                    (best_rank[RANK_WIDTH-1 -: TIME_WIDTH] <= i_time);
            end
            if (best_eligible &&
                (issue_slot < int'(i_issue_limit))) begin
                o_issue_valid[issue_slot] = 1'b1;
                o_issue_logical_tree_id[issue_slot] =
                    best_logical[LOGICAL_ID_WIDTH-1:0];
                o_issue_physical_tree_id[issue_slot] =
                    i_head_physical_tree_id[best_logical];
                o_issue_rank[issue_slot] = best_rank;
                selected_logical[best_logical] = 1'b1;
                o_issue_count = o_issue_count + 1'b1;
            end
        end
    end

    initial begin
        if ((LOGICAL_TREE_NUM < 1) || (PHYSICAL_TREE_NUM < 1) ||
            (TIME_WIDTH < 1) || (SEQUENCE_WIDTH < 1) ||
            (ISSUE_PORTS < 1))
            $fatal(1, "ShapingDueArbiter parameters must be positive");
    end

endmodule
