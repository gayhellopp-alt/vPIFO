`timescale 1ns / 10ps

// Reduce physical BMW shard heads into one earliest event per logical shaping
// PIFO.  REGISTER_OUTPUT breaks the Stage-28 shard-head to request-allocation
// path; the extra cycle can only delay a release and is therefore safe.
module ShapingLogicalHeadSummary #(
    parameter LOGICAL_TREE_NUM = 2,
    parameter PHYSICAL_TREE_NUM = 3,
    parameter MAX_SHARDS_PER_LOGICAL = 2,
    parameter RANK_WIDTH = 32,
    parameter REGISTER_OUTPUT = 1,
    parameter integer USE_EXPLICIT_SHARD_MAP = 0,
    parameter integer SHARD_COUNTS [0:LOGICAL_TREE_NUM-1] = '{default:1},
    parameter integer SHARD_OFFSETS [0:LOGICAL_TREE_NUM-1] = '{default:0},
    parameter integer EXPLICIT_SHARD_MAP [0:PHYSICAL_TREE_NUM-1] =
        '{default:0},
    localparam LOGICAL_ID_WIDTH = (LOGICAL_TREE_NUM <= 1) ? 1 :
                                  $clog2(LOGICAL_TREE_NUM),
    localparam PHYSICAL_ID_WIDTH = (PHYSICAL_TREE_NUM <= 1) ? 1 :
                                   $clog2(PHYSICAL_TREE_NUM)
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,
    input  wire [RANK_WIDTH-1:0]        i_shard_head_rank [0:PHYSICAL_TREE_NUM-1],
    input  wire                         i_shard_head_valid [0:PHYSICAL_TREE_NUM-1],
    input  wire                         i_shard_update_pending [0:PHYSICAL_TREE_NUM-1],
    output wire [LOGICAL_TREE_NUM-1:0]  o_head_valid,
    output wire [RANK_WIDTH-1:0]        o_head_rank [0:LOGICAL_TREE_NUM-1],
    output wire [PHYSICAL_ID_WIDTH-1:0] o_head_physical_tree_id [0:LOGICAL_TREE_NUM-1]
);

    reg [LOGICAL_TREE_NUM-1:0] head_valid_comb;
    reg [LOGICAL_TREE_NUM-1:0] logical_update_pending_comb;
    reg [RANK_WIDTH-1:0] head_rank_comb [0:LOGICAL_TREE_NUM-1];
    reg [PHYSICAL_ID_WIDTH-1:0]
        head_physical_comb [0:LOGICAL_TREE_NUM-1];
    reg [LOGICAL_TREE_NUM-1:0] head_valid_reg;
    reg [RANK_WIDTH-1:0] head_rank_reg [0:LOGICAL_TREE_NUM-1];
    reg [PHYSICAL_ID_WIDTH-1:0]
        head_physical_reg [0:LOGICAL_TREE_NUM-1];

    function integer configured_flat_offset;
        input integer logical_id;
        integer offset_logical;
        begin
            configured_flat_offset = 0;
            for (offset_logical = 0; offset_logical < LOGICAL_TREE_NUM;
                 offset_logical = offset_logical + 1)
                if (offset_logical < logical_id)
                    configured_flat_offset = configured_flat_offset +
                        SHARD_COUNTS[offset_logical];
        end
    endfunction

    function integer configured_physical_id;
        input integer logical_id;
        input integer slot;
        integer flat_index;
        begin
            flat_index = configured_flat_offset(logical_id) + slot;
            if (USE_EXPLICIT_SHARD_MAP != 0)
                configured_physical_id = EXPLICIT_SHARD_MAP[flat_index];
            else
                configured_physical_id = flat_index;
        end
    endfunction

    integer logical_scan;
    integer shard_slot;
    integer physical_scan;
    always @* begin
        head_valid_comb = {LOGICAL_TREE_NUM{1'b0}};
        logical_update_pending_comb = {LOGICAL_TREE_NUM{1'b0}};
        for (logical_scan = 0; logical_scan < LOGICAL_TREE_NUM;
             logical_scan = logical_scan + 1) begin
            head_rank_comb[logical_scan] = {RANK_WIDTH{1'b1}};
            head_physical_comb[logical_scan] =
                {PHYSICAL_ID_WIDTH{1'b0}};
            // A logical minimum is not knowable while any of its shards is
            // completing an update.  Selecting a stable sibling shard in
            // that interval can reserve a later rank while the Directory
            // subsequently Pops an earlier rank from the updating shard.
            for (shard_slot = 0;
                 shard_slot < MAX_SHARDS_PER_LOGICAL;
                 shard_slot = shard_slot + 1) begin
                if (shard_slot < SHARD_COUNTS[logical_scan]) begin
                    physical_scan = configured_physical_id(
                        logical_scan, shard_slot);
                    if (i_shard_update_pending[physical_scan])
                        logical_update_pending_comb[logical_scan] = 1'b1;
                end
            end
            for (shard_slot = 0;
                 shard_slot < MAX_SHARDS_PER_LOGICAL;
                 shard_slot = shard_slot + 1) begin
                if (shard_slot < SHARD_COUNTS[logical_scan]) begin
                    physical_scan = configured_physical_id(
                        logical_scan, shard_slot);
                    if (!logical_update_pending_comb[logical_scan] &&
                        i_shard_head_valid[physical_scan] &&
                        (!head_valid_comb[logical_scan] ||
                         (i_shard_head_rank[physical_scan] <
                          head_rank_comb[logical_scan]) ||
                         ((i_shard_head_rank[physical_scan] ==
                           head_rank_comb[logical_scan]) &&
                          (physical_scan <
                           head_physical_comb[logical_scan])))) begin
                        head_valid_comb[logical_scan] = 1'b1;
                        head_rank_comb[logical_scan] =
                            i_shard_head_rank[physical_scan];
                        head_physical_comb[logical_scan] =
                            physical_scan[PHYSICAL_ID_WIDTH-1:0];
                    end
                end
            end
        end
    end

    integer reset_logical;
    generate
        if (REGISTER_OUTPUT != 0) begin : GEN_REGISTERED_HEAD
            always @(posedge i_clk or negedge i_arst_n) begin
                if (!i_arst_n) begin
                    head_valid_reg <= {LOGICAL_TREE_NUM{1'b0}};
                    for (reset_logical = 0;
                         reset_logical < LOGICAL_TREE_NUM;
                         reset_logical = reset_logical + 1) begin
                        head_rank_reg[reset_logical] <= {RANK_WIDTH{1'b1}};
                        head_physical_reg[reset_logical] <=
                            {PHYSICAL_ID_WIDTH{1'b0}};
                    end
                end else begin
                    head_valid_reg <= head_valid_comb;
                    for (reset_logical = 0;
                         reset_logical < LOGICAL_TREE_NUM;
                         reset_logical = reset_logical + 1) begin
                        head_rank_reg[reset_logical] <=
                            head_rank_comb[reset_logical];
                        head_physical_reg[reset_logical] <=
                            head_physical_comb[reset_logical];
                    end
                end
            end
            // Mask a registered old minimum immediately when a live shard
            // update starts.  On update completion the register captures an
            // invalid cycle first, then the new all-shard minimum, so the
            // release side can never observe a partial summary.
            assign o_head_valid = head_valid_reg &
                ~logical_update_pending_comb;
            for (genvar out_logical = 0;
                 out_logical < LOGICAL_TREE_NUM;
                 out_logical = out_logical + 1) begin : GEN_HEAD_OUTPUT
                assign o_head_rank[out_logical] =
                    head_rank_reg[out_logical];
                assign o_head_physical_tree_id[out_logical] =
                    head_physical_reg[out_logical];
            end
        end else begin : GEN_COMBINATIONAL_HEAD
            assign o_head_valid = head_valid_comb;
            for (genvar out_logical = 0;
                 out_logical < LOGICAL_TREE_NUM;
                 out_logical = out_logical + 1) begin : GEN_HEAD_OUTPUT
                assign o_head_rank[out_logical] =
                    head_rank_comb[out_logical];
                assign o_head_physical_tree_id[out_logical] =
                    head_physical_comb[out_logical];
            end
        end
    endgenerate

    integer check_logical;
    integer check_total;
    integer check_physical;
    integer check_slot;
    reg [PHYSICAL_TREE_NUM-1:0] check_seen;
    initial begin
        if ((LOGICAL_TREE_NUM < 1) || (PHYSICAL_TREE_NUM < 1) ||
            (MAX_SHARDS_PER_LOGICAL < 1) || (RANK_WIDTH < 1))
            $fatal(1, "ShapingLogicalHeadSummary parameters are invalid");
        check_total = 0;
        check_seen = {PHYSICAL_TREE_NUM{1'b0}};
        for (check_logical = 0; check_logical < LOGICAL_TREE_NUM;
             check_logical = check_logical + 1) begin
            if ((SHARD_COUNTS[check_logical] < 1) ||
                (SHARD_COUNTS[check_logical] >
                 MAX_SHARDS_PER_LOGICAL) ||
                (SHARD_OFFSETS[check_logical] != check_total))
                $fatal(1, "Invalid shaping shard count/offset map");
            for (check_slot = 0;
                 check_slot < SHARD_COUNTS[check_logical];
                 check_slot = check_slot + 1) begin
                check_physical = configured_physical_id(
                    check_logical, check_slot);
                if ((check_physical < 0) ||
                    (check_physical >= PHYSICAL_TREE_NUM) ||
                    check_seen[check_physical])
                    $fatal(1, "Invalid or duplicate shaping physical shard");
                check_seen[check_physical] = 1'b1;
            end
            check_total = check_total + SHARD_COUNTS[check_logical];
        end
        if (check_total != PHYSICAL_TREE_NUM)
            $fatal(1, "Shaping shard-count sum must equal physical count");
    end

endmodule
