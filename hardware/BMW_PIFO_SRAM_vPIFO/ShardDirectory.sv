`timescale 1ns / 10ps

// Compile-time heterogeneous shard directory.
//
// SHARD_COUNTS gives the number of physical shards owned by each logical
// PIFO.  SHARD_OFFSETS is generated as the prefix sum of SHARD_COUNTS.
// In the default continuous mode, flattened entry N maps to physical tree N.
// When USE_EXPLICIT_SHARD_MAP is non-zero, EXPLICIT_SHARD_MAP[N] supplies the
// physical tree ID instead.  The mapping is static for the life of the design.
//
// Multiple request ports are selected combinationally for the caller's
// TaskFIFO write.  Every selection that actually fires is captured in a
// per-port commit register.  That one-cycle context reserves its logical PIFO
// and physical shard, and the registered descriptor (rather than the live
// request or a new directory scan) updates directory state on the next edge.
module ShardDirectory #(
    parameter LOGICAL_TREE_NUM = VpifoConfigPkg::LOGICAL_TREE_NUM,
    parameter PHYSICAL_TREE_NUM = VpifoConfigPkg::PHYSICAL_TREE_NUM,
    parameter SHARD_CAPACITY = VpifoConfigPkg::SHARD_CAPACITY,
    parameter RANK_WIDTH = 16,
    parameter MAX_SHARDS_PER_LOGICAL =
        VpifoConfigPkg::MAX_SHARDS_PER_LOGICAL,
    parameter REQUEST_PORTS = 1,
    parameter UPDATE_PORTS = 1,
    // In the integrated heterogeneous core, request port P permanently
    // represents logical PIFO P.  Keep the generic runtime-ID mode as the
    // default for standalone users and tests, but allow that fixed mapping to
    // remove the logical-ID grant state and cross-port reservation decode.
    parameter integer FIXED_LOGICAL_PORTS = 0,
    // A root update emitted by RPU lane L can only belong to a physical tree
    // whose ID modulo UPDATE_PORTS is L.  The integrated BMW Engine guarantees
    // that rotating-placement invariant.  Enabling this specialization lets
    // every shard state bit consume one fixed update port instead of a fully
    // dynamic UPDATE_PORTS-to-PHYSICAL_TREE_NUM write network.  Standalone and
    // legacy users retain the generic update interface by default.
    parameter integer FIXED_RPU_UPDATE_PORTS = 0,
    // A logical total is the exact sum of its static shard counters.  Native
    // wrappers that do not need a separately updated total register may derive
    // the visible value and remove redundant count state/update control.
    // Generic users keep the registered implementation by default.
    parameter integer DERIVE_LOGICAL_COUNT = 0,
    // In the integrated fixed-port pipeline, directory state changes only on
    // a root completion and the completing logical PIFO remains busy through
    // that edge.  Project the returned Head into a per-logical registered
    // minimum so the next request sees completed state without a live
    // all-shard comparison on the dispatch path.  Generic and legacy users
    // retain the original combinational Head selector by default.
    parameter integer COMPLETION_PROJECTED_HEAD_CACHE = 0,
    parameter integer USE_EXPLICIT_SHARD_MAP =
        VpifoConfigPkg::USE_EXPLICIT_SHARD_MAP,
    parameter integer SHARD_COUNTS [0:LOGICAL_TREE_NUM-1] =
        VpifoConfigPkg::SHARD_COUNTS,
    parameter integer SHARD_OFFSETS [0:LOGICAL_TREE_NUM-1] =
        VpifoConfigPkg::SHARD_OFFSETS,
    parameter integer EXPLICIT_SHARD_MAP [0:PHYSICAL_TREE_NUM-1] =
        VpifoConfigPkg::EXPLICIT_SHARD_MAP,

    localparam LOGICAL_ID_WIDTH = (LOGICAL_TREE_NUM <= 1) ? 1 :
                                  $clog2(LOGICAL_TREE_NUM),
    localparam PHYSICAL_ID_WIDTH = (PHYSICAL_TREE_NUM <= 1) ? 1 :
                                   $clog2(PHYSICAL_TREE_NUM),
    localparam SHARD_COUNT_WIDTH = (SHARD_CAPACITY <= 1) ? 1 :
                                   $clog2(SHARD_CAPACITY + 1),
    localparam TOTAL_COUNT_WIDTH =
        (PHYSICAL_TREE_NUM * SHARD_CAPACITY <= 1) ? 1 :
        $clog2(PHYSICAL_TREE_NUM * SHARD_CAPACITY + 1),
    localparam SHARD_LIST_COUNT_WIDTH =
        (MAX_SHARDS_PER_LOGICAL <= 1) ? 1 :
        $clog2(MAX_SHARDS_PER_LOGICAL + 1),
    localparam RR_WIDTH = (MAX_SHARDS_PER_LOGICAL <= 1) ? 1 :
                          $clog2(MAX_SHARDS_PER_LOGICAL)
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,

    input  wire [REQUEST_PORTS-1:0]     i_req_valid,
    input  wire [REQUEST_PORTS-1:0]     i_req_push,
    input  wire [REQUEST_PORTS-1:0]     i_req_pp,
    input  wire [LOGICAL_ID_WIDTH-1:0]  i_logical_tree_id [0:REQUEST_PORTS-1],
    input  wire [REQUEST_PORTS-1:0]     i_select_ready,

    output wire [REQUEST_PORTS-1:0]     o_req_ready,
    output wire [REQUEST_PORTS-1:0]     o_select_valid,
    output wire [REQUEST_PORTS-1:0]     o_select_pp,
    output wire [PHYSICAL_ID_WIDTH-1:0] o_physical_tree_id [0:REQUEST_PORTS-1],
    output reg  [REQUEST_PORTS-1:0]     o_reject_empty,
    output reg  [REQUEST_PORTS-1:0]     o_reject_full,
    output reg  [REQUEST_PORTS-1:0]     o_reject_bad_id,

    input  wire [UPDATE_PORTS-1:0]      i_update_valid,
    input  wire [PHYSICAL_ID_WIDTH-1:0] i_update_physical_tree_id [0:UPDATE_PORTS-1],
    input  wire [RANK_WIDTH-1:0]        i_update_head_rank [0:UPDATE_PORTS-1],

    output wire                         o_busy,
    output reg                          o_protocol_error,

    output reg [PHYSICAL_ID_WIDTH-1:0]  o_shard_list [0:LOGICAL_TREE_NUM-1][0:MAX_SHARDS_PER_LOGICAL-1],
    output reg [SHARD_LIST_COUNT_WIDTH-1:0] o_logical_shard_count [0:LOGICAL_TREE_NUM-1],
    output wire [TOTAL_COUNT_WIDTH-1:0] o_logical_count [0:LOGICAL_TREE_NUM-1],
    output reg [RR_WIDTH-1:0]           o_push_rr_ptr [0:LOGICAL_TREE_NUM-1],
    output reg                          o_logical_busy [0:LOGICAL_TREE_NUM-1],
    output reg [SHARD_COUNT_WIDTH-1:0]  o_shard_count [0:PHYSICAL_TREE_NUM-1],
    output reg [RANK_WIDTH-1:0]         o_shard_head_rank [0:PHYSICAL_TREE_NUM-1],
    output reg                          o_shard_empty [0:PHYSICAL_TREE_NUM-1],
    output reg                          o_shard_full [0:PHYSICAL_TREE_NUM-1],
    output reg                          o_shard_head_valid [0:PHYSICAL_TREE_NUM-1],
    output reg                          o_update_pending [0:PHYSICAL_TREE_NUM-1],
    output wire [LOGICAL_ID_WIDTH-1:0]  o_pending_logical_tree_id [0:PHYSICAL_TREE_NUM-1],
    output reg                          o_pending_push [0:PHYSICAL_TREE_NUM-1],
    output reg                          o_pending_pp [0:PHYSICAL_TREE_NUM-1]
);

    function integer configured_shard_count;
        input integer logical_id;
        begin
            if ((logical_id >= 0) && (logical_id < LOGICAL_TREE_NUM))
                configured_shard_count = SHARD_COUNTS[logical_id];
            else
                configured_shard_count = 0;
        end
    endfunction

    // The projected cache is an optional native-mode specialization.  Keep
    // the generic live-min implementation as the automatic fallback for
    // configurations wider than the explicit 16-leaf tournament.
    localparam integer HEAD_CACHE_LEAVES = 16;
    localparam PROJECTED_HEAD_CACHE_ACTIVE =
        (COMPLETION_PROJECTED_HEAD_CACHE != 0) &&
        (MAX_SHARDS_PER_LOGICAL <= HEAD_CACHE_LEAVES);
    localparam integer HEAD_TUPLE_ID_LSB = 0;
    localparam integer HEAD_TUPLE_RANK_LSB = PHYSICAL_ID_WIDTH;
    localparam integer HEAD_TUPLE_FULL_BIT =
        PHYSICAL_ID_WIDTH + RANK_WIDTH;
    localparam integer HEAD_TUPLE_VALID_BIT =
        HEAD_TUPLE_FULL_BIT + 1;
    localparam integer HEAD_TUPLE_WIDTH =
        HEAD_TUPLE_VALID_BIT + 1;

    function automatic [HEAD_TUPLE_WIDTH-1:0] choose_head_tuple;
        input [HEAD_TUPLE_WIDTH-1:0] left_tuple;
        input [HEAD_TUPLE_WIDTH-1:0] right_tuple;
        reg right_wins;
        begin
            right_wins =
                right_tuple[HEAD_TUPLE_VALID_BIT] &&
                (!left_tuple[HEAD_TUPLE_VALID_BIT] ||
                 (right_tuple[HEAD_TUPLE_RANK_LSB +: RANK_WIDTH] <
                  left_tuple[HEAD_TUPLE_RANK_LSB +: RANK_WIDTH]) ||
                 ((right_tuple[HEAD_TUPLE_RANK_LSB +: RANK_WIDTH] ==
                   left_tuple[HEAD_TUPLE_RANK_LSB +: RANK_WIDTH]) &&
                  (right_tuple[HEAD_TUPLE_ID_LSB +: PHYSICAL_ID_WIDTH] <
                   left_tuple[HEAD_TUPLE_ID_LSB +: PHYSICAL_ID_WIDTH])));
            choose_head_tuple = right_wins ? right_tuple : left_tuple;
        end
    endfunction

    function integer configured_flat_offset;
        input integer logical_id;
        integer offset_logical;
        begin
            // Keep the generated count vector in the runtime-ID decode cone.
            // This elaborates to the same timing-friendly structure as the
            // accepted Stage15 implementation, while SHARD_OFFSETS remains
            // the generated manifest value and is checked below against this
            // prefix sum.  No mapping value is maintained by hand.
            configured_flat_offset = 0;
            for (offset_logical = 0; offset_logical < LOGICAL_TREE_NUM;
                 offset_logical = offset_logical + 1) begin
                if (offset_logical < logical_id)
                    configured_flat_offset =
                        configured_flat_offset + SHARD_COUNTS[offset_logical];
            end
        end
    endfunction

    function integer configured_physical_id;
        input integer logical_id;
        input integer slot;
        integer flat_index;
        begin
            configured_physical_id = 0;
            if ((logical_id >= 0) && (logical_id < LOGICAL_TREE_NUM) &&
                (slot >= 0) && (slot < configured_shard_count(logical_id))) begin
                flat_index = configured_flat_offset(logical_id) + slot;
                if (USE_EXPLICIT_SHARD_MAP != 0)
                    configured_physical_id = EXPLICIT_SHARD_MAP[flat_index];
                else
                    configured_physical_id = flat_index;
            end
        end
    endfunction

    function integer configured_local_slot;
        input integer logical_id;
        input integer physical_id;
        integer function_slot;
        begin
            configured_local_slot = 0;
            for (function_slot = 0;
                 function_slot < MAX_SHARDS_PER_LOGICAL;
                 function_slot = function_slot + 1) begin
                if ((function_slot < configured_shard_count(logical_id)) &&
                    (configured_physical_id(logical_id, function_slot) ==
                     physical_id))
                    configured_local_slot = function_slot;
            end
        end
    endfunction

    function integer configured_logical_owner;
        input integer physical_id;
        integer function_logical;
        integer function_slot;
        begin
            // Physical ownership is part of the generated configuration, not
            // per-operation state.  Keep the legacy pending-owner output for
            // interface compatibility, but derive it directly from the static
            // shard map instead of writing one LOGICAL_ID register per shard.
            configured_logical_owner = 0;
            for (function_logical = 0;
                 function_logical < LOGICAL_TREE_NUM;
                 function_logical = function_logical + 1) begin
                for (function_slot = 0;
                     function_slot < MAX_SHARDS_PER_LOGICAL;
                     function_slot = function_slot + 1) begin
                    if ((function_slot <
                         configured_shard_count(function_logical)) &&
                        (configured_physical_id(function_logical,
                                                function_slot) ==
                         physical_id))
                        configured_logical_owner = function_logical;
                end
            end
        end
    endfunction

    integer check_logical;
    integer check_slot;
    integer check_other_logical;
    integer check_other_slot;
    integer check_total;
    integer check_physical;
    integer check_other_physical;
    initial begin
        if ((LOGICAL_TREE_NUM < 1) || (PHYSICAL_TREE_NUM < 1) ||
            (SHARD_CAPACITY < 1) || (RANK_WIDTH < 1) ||
            (MAX_SHARDS_PER_LOGICAL < 1) || (REQUEST_PORTS < 1) ||
            (UPDATE_PORTS < 1))
            $fatal(1, "ShardDirectory parameters must be positive");
        if ((FIXED_LOGICAL_PORTS != 0) &&
            (REQUEST_PORTS != LOGICAL_TREE_NUM))
            $fatal(1, "Fixed logical ports require one port per logical PIFO");
        if ((PROJECTED_HEAD_CACHE_ACTIVE != 0) &&
            ((FIXED_LOGICAL_PORTS == 0) ||
             (FIXED_RPU_UPDATE_PORTS == 0)))
            $fatal(1, "Projected Head cache requires fixed logical and RPU ports");

        check_total = 0;
        for (check_logical = 0; check_logical < LOGICAL_TREE_NUM;
             check_logical = check_logical + 1) begin
            if ((SHARD_COUNTS[check_logical] < 1) ||
                (SHARD_COUNTS[check_logical] >
                 MAX_SHARDS_PER_LOGICAL))
                $fatal(1, "Each logical PIFO must own 1..MAX_SHARDS_PER_LOGICAL shards");
            if (SHARD_OFFSETS[check_logical] != check_total)
                $fatal(1, "SHARD_OFFSETS must be the contiguous prefix sum of SHARD_COUNTS");
            check_total = check_total + SHARD_COUNTS[check_logical];
        end
        if (check_total != PHYSICAL_TREE_NUM)
            $fatal(1, "The shard-count sum must equal PHYSICAL_TREE_NUM");

        for (check_logical = 0; check_logical < LOGICAL_TREE_NUM;
             check_logical = check_logical + 1) begin
            for (check_slot = 0;
                 check_slot < SHARD_COUNTS[check_logical];
                 check_slot = check_slot + 1) begin
                check_physical =
                    configured_physical_id(check_logical, check_slot);
                if ((check_physical < 0) ||
                    (check_physical >= PHYSICAL_TREE_NUM))
                    $fatal(1, "Configured physical shard ID is out of range");

                for (check_other_logical = check_logical;
                     check_other_logical < LOGICAL_TREE_NUM;
                     check_other_logical = check_other_logical + 1) begin
                    for (check_other_slot = 0;
                         check_other_slot <
                         SHARD_COUNTS[check_other_logical];
                         check_other_slot = check_other_slot + 1) begin
                        check_other_physical = configured_physical_id(
                            check_other_logical, check_other_slot);
                        if (((check_other_logical > check_logical) ||
                             (check_other_slot > check_slot)) &&
                            (check_other_physical == check_physical))
                            $fatal(1, "A physical shard may belong to only one logical PIFO");
                    end
                end
            end
        end
    end

    // The fixed update topology is a compile-time contract with the BMW
    // Engine.  Keep its proof in simulation without synthesizing defensive
    // modulo/decode logic back into the optimized datapath.
    // synthesis translate_off
    integer fixed_update_check_port;
    integer fixed_update_check_physical;
    always @(posedge i_clk) begin
        if (i_arst_n && (FIXED_RPU_UPDATE_PORTS != 0)) begin
            for (fixed_update_check_port = 0;
                 fixed_update_check_port < UPDATE_PORTS;
                 fixed_update_check_port = fixed_update_check_port + 1) begin
                if (i_update_valid[fixed_update_check_port]) begin
                    fixed_update_check_physical =
                        i_update_physical_tree_id[fixed_update_check_port];
                    assert ((fixed_update_check_physical <
                             PHYSICAL_TREE_NUM) &&
                            ((fixed_update_check_physical % UPDATE_PORTS) ==
                             fixed_update_check_port))
                    else $error(
                        "BMW root update arrived on the wrong RPU lane: lane=%0d physical=%0d update_ports=%0d",
                        fixed_update_check_port,
                        i_update_physical_tree_id[fixed_update_check_port],
                        UPDATE_PORTS);
                end
            end
        end
    end
    // synthesis translate_on

    genvar owner_physical;
    generate
        for (owner_physical = 0;
             owner_physical < PHYSICAL_TREE_NUM;
             owner_physical = owner_physical + 1) begin : GEN_STATIC_OWNER
            localparam integer LOGICAL_OWNER =
                configured_logical_owner(owner_physical);
            assign o_pending_logical_tree_id[owner_physical] =
                LOGICAL_ID_WIDTH'(LOGICAL_OWNER);
        end
    endgenerate

    reg [REQUEST_PORTS-1:0] grant_valid_reg;
    reg [REQUEST_PORTS-1:0] grant_push_reg;
    reg [REQUEST_PORTS-1:0] grant_pp_reg;
    reg [LOGICAL_ID_WIDTH-1:0]
        grant_logical_tree_id_reg [0:REQUEST_PORTS-1];
    reg [PHYSICAL_ID_WIDTH-1:0]
        grant_physical_tree_id_reg [0:REQUEST_PORTS-1];

    reg [REQUEST_PORTS-1:0] grant_fill_valid;
    reg [REQUEST_PORTS-1:0] grant_fill_push;
    reg [REQUEST_PORTS-1:0] grant_fill_pp;
    reg [LOGICAL_ID_WIDTH-1:0]
        grant_fill_logical_tree_id [0:REQUEST_PORTS-1];
    reg [PHYSICAL_ID_WIDTH-1:0]
        grant_fill_physical_tree_id [0:REQUEST_PORTS-1];

    reg [TOTAL_COUNT_WIDTH-1:0]
        logical_count_state [0:LOGICAL_TREE_NUM-1];
    reg [TOTAL_COUNT_WIDTH-1:0]
        logical_count_derived [0:LOGICAL_TREE_NUM-1];
    integer count_reduce_logical;
    integer count_reduce_slot;
    integer count_reduce_physical;
    always_comb begin
        for (count_reduce_logical = 0;
             count_reduce_logical < LOGICAL_TREE_NUM;
             count_reduce_logical = count_reduce_logical + 1) begin
            logical_count_derived[count_reduce_logical] =
                {TOTAL_COUNT_WIDTH{1'b0}};
            count_reduce_physical = 0;
            for (count_reduce_slot = 0;
                 count_reduce_slot < MAX_SHARDS_PER_LOGICAL;
                 count_reduce_slot = count_reduce_slot + 1) begin
                if (count_reduce_slot <
                    SHARD_COUNTS[count_reduce_logical]) begin
                    count_reduce_physical = configured_physical_id(
                        count_reduce_logical, count_reduce_slot);
                    logical_count_derived[count_reduce_logical] =
                        logical_count_derived[count_reduce_logical] +
                        TOTAL_COUNT_WIDTH'(
                            o_shard_count[count_reduce_physical]);
                end
            end
        end
    end

    genvar count_output_logical;
    generate
        for (count_output_logical = 0;
             count_output_logical < LOGICAL_TREE_NUM;
             count_output_logical = count_output_logical + 1) begin :
             GEN_LOGICAL_COUNT_OUTPUT
            assign o_logical_count[count_output_logical] =
                (DERIVE_LOGICAL_COUNT != 0) ?
                    logical_count_derived[count_output_logical] :
                    logical_count_state[count_output_logical];
        end
    endgenerate
    reg [LOGICAL_TREE_NUM-1:0] selection_logical_reserved;
    reg [REQUEST_PORTS-1:0] request_stall;
    reg candidate_found [0:REQUEST_PORTS-1];
    reg resource_exists [0:REQUEST_PORTS-1];
    wire [REQUEST_PORTS-1:0] select_fire;

    wire [LOGICAL_ID_WIDTH-1:0]
        request_logical_tree_id [0:REQUEST_PORTS-1];
    wire [LOGICAL_ID_WIDTH-1:0]
        commit_logical_tree_id [0:REQUEST_PORTS-1];

    genvar logical_port;
    generate
        for (logical_port = 0; logical_port < REQUEST_PORTS;
             logical_port = logical_port + 1) begin : GEN_LOGICAL_PORT_ID
            if (FIXED_LOGICAL_PORTS != 0) begin : GEN_FIXED
                assign request_logical_tree_id[logical_port] =
                    LOGICAL_ID_WIDTH'(logical_port);
                assign commit_logical_tree_id[logical_port] =
                    LOGICAL_ID_WIDTH'(logical_port);
            end else begin : GEN_RUNTIME
                assign request_logical_tree_id[logical_port] =
                    i_logical_tree_id[logical_port];
                assign commit_logical_tree_id[logical_port] =
                    grant_logical_tree_id_reg[logical_port];
            end
        end
    endgenerate

    // Compute each logical PIFO's global Head shard as a parallel minimum
    // proof.  The previous request-port scan carried candidate_found and
    // best_rank from one shard to the next, which synthesized into a serial
    // comparator/priority chain.  Here every configured shard independently
    // proves that no other available Head has a lower (rank, physical-ID)
    // tuple.  The resulting one-hot mask preserves the existing lower
    // physical-ID tie-break without adding a pipeline stage.
    wire [MAX_SHARDS_PER_LOGICAL-1:0]
        logical_head_resource_mask [0:LOGICAL_TREE_NUM-1];
    wire [MAX_SHARDS_PER_LOGICAL-1:0]
        logical_head_available_mask [0:LOGICAL_TREE_NUM-1];
    wire [MAX_SHARDS_PER_LOGICAL-1:0]
        logical_head_min_mask [0:LOGICAL_TREE_NUM-1];
    wire [MAX_SHARDS_PER_LOGICAL-1:0]
        logical_head_min_full_mask [0:LOGICAL_TREE_NUM-1];
    wire [MAX_SHARDS_PER_LOGICAL-1:0]
        logical_head_outranked [0:LOGICAL_TREE_NUM-1]
                               [0:MAX_SHARDS_PER_LOGICAL-1];
    wire [MAX_SHARDS_PER_LOGICAL-1:0]
        logical_head_pair_first_precedes [0:LOGICAL_TREE_NUM-1]
                                         [0:MAX_SHARDS_PER_LOGICAL-1];
    wire [PHYSICAL_ID_WIDTH-1:0]
        logical_head_physical_term [0:LOGICAL_TREE_NUM-1]
                                   [0:MAX_SHARDS_PER_LOGICAL-1];
    reg logical_head_resource_exists [0:LOGICAL_TREE_NUM-1];
    reg logical_head_candidate_found [0:LOGICAL_TREE_NUM-1];
    reg logical_head_min_full [0:LOGICAL_TREE_NUM-1];
    reg [PHYSICAL_ID_WIDTH-1:0]
        logical_head_min_physical_tree_id [0:LOGICAL_TREE_NUM-1];

    integer head_reduce_logical;
    integer head_reduce_slot;
    genvar head_logical;
    genvar head_slot;
    genvar head_other_slot;
    genvar cache_logical;
    genvar cache_leaf;
    genvar cache_pair_l1;
    genvar cache_pair_l2;
    genvar cache_pair_l3;
    generate
        if (PROJECTED_HEAD_CACHE_ACTIVE == 0) begin : GEN_LIVE_HEAD_MIN
          for (head_logical = 0; head_logical < LOGICAL_TREE_NUM;
               head_logical = head_logical + 1) begin : GEN_LOGICAL_HEAD_MIN
            for (head_slot = 0;
                 head_slot < MAX_SHARDS_PER_LOGICAL;
                 head_slot = head_slot + 1) begin : GEN_HEAD_SLOT
                if (head_slot < SHARD_COUNTS[head_logical]) begin : GEN_USED
                    localparam integer HEAD_PHYSICAL_ID =
                        configured_physical_id(head_logical, head_slot);
                    assign logical_head_resource_mask[head_logical][head_slot] =
                        o_shard_head_valid[HEAD_PHYSICAL_ID];
                    if (FIXED_LOGICAL_PORTS != 0) begin : GEN_FIXED_AVAILABLE
                        // Fixed port P can issue only for logical P.  Since a
                        // busy logical owns exactly one pending physical shard,
                        // the request-level busy test already excludes every
                        // pending shard of this logical before Head selection.
                        assign logical_head_available_mask
                            [head_logical][head_slot] =
                            o_shard_head_valid[HEAD_PHYSICAL_ID];
                    end else begin : GEN_RUNTIME_AVAILABLE
                        assign logical_head_available_mask
                            [head_logical][head_slot] =
                            o_shard_head_valid[HEAD_PHYSICAL_ID] &&
                            !o_update_pending[HEAD_PHYSICAL_ID];
                    end
                    assign logical_head_min_full_mask[head_logical][head_slot] =
                        logical_head_min_mask[head_logical][head_slot] &&
                        o_shard_full[HEAD_PHYSICAL_ID];
                    assign logical_head_physical_term[head_logical][head_slot] =
                        {PHYSICAL_ID_WIDTH{
                            logical_head_min_mask[head_logical][head_slot]}} &
                        HEAD_PHYSICAL_ID[PHYSICAL_ID_WIDTH-1:0];
                    for (head_other_slot = 0;
                         head_other_slot < MAX_SHARDS_PER_LOGICAL;
                         head_other_slot = head_other_slot + 1) begin : GEN_OTHER
                        if ((head_other_slot < SHARD_COUNTS[head_logical]) &&
                            (head_other_slot > head_slot)) begin : GEN_PAIR
                            localparam integer OTHER_PHYSICAL_ID =
                                configured_physical_id(
                                    head_logical, head_other_slot);
                            // One total-order comparison serves both ends of
                             // the unordered shard pair.  Physical IDs are
                             // unique, so the reverse relation is exactly the
                             // complement even when ranks are equal.
                            assign logical_head_pair_first_precedes
                                [head_logical][head_slot][head_other_slot] =
                                (o_shard_head_rank[HEAD_PHYSICAL_ID] <
                                 o_shard_head_rank[OTHER_PHYSICAL_ID]) ||
                                ((o_shard_head_rank[HEAD_PHYSICAL_ID] ==
                                  o_shard_head_rank[OTHER_PHYSICAL_ID]) &&
                                 (HEAD_PHYSICAL_ID < OTHER_PHYSICAL_ID));
                            assign logical_head_outranked
                                [head_logical][head_slot][head_other_slot] =
                                logical_head_available_mask
                                    [head_logical][head_other_slot] &&
                                !logical_head_pair_first_precedes
                                    [head_logical][head_slot]
                                    [head_other_slot];
                        end else if ((head_other_slot <
                                     SHARD_COUNTS[head_logical]) &&
                                    (head_other_slot < head_slot)) begin :
                                    GEN_REUSE_PAIR
                            assign logical_head_pair_first_precedes
                                [head_logical][head_slot][head_other_slot] =
                                1'b0;
                            assign logical_head_outranked
                                [head_logical][head_slot][head_other_slot] =
                                logical_head_available_mask
                                    [head_logical][head_other_slot] &&
                                logical_head_pair_first_precedes
                                    [head_logical][head_other_slot]
                                    [head_slot];
                        end else begin : GEN_NO_COMPARE
                            assign logical_head_pair_first_precedes
                                [head_logical][head_slot][head_other_slot] =
                                1'b0;
                            assign logical_head_outranked
                                [head_logical][head_slot][head_other_slot] =
                                1'b0;
                        end
                    end

                    assign logical_head_min_mask[head_logical][head_slot] =
                        logical_head_available_mask[head_logical][head_slot] &&
                        !(|logical_head_outranked[head_logical][head_slot]);
                end else begin : GEN_UNUSED
                    assign logical_head_resource_mask[head_logical][head_slot] =
                        1'b0;
                    assign logical_head_available_mask[head_logical][head_slot] =
                        1'b0;
                    assign logical_head_min_mask[head_logical][head_slot] =
                        1'b0;
                    assign logical_head_min_full_mask[head_logical][head_slot] =
                        1'b0;
                    assign logical_head_outranked[head_logical][head_slot] =
                        {MAX_SHARDS_PER_LOGICAL{1'b0}};
                    assign logical_head_pair_first_precedes
                        [head_logical][head_slot] =
                        {MAX_SHARDS_PER_LOGICAL{1'b0}};
                    assign logical_head_physical_term[head_logical][head_slot] =
                        {PHYSICAL_ID_WIDTH{1'b0}};
                end
            end
          end

          always_comb begin
              for (head_reduce_logical = 0;
                   head_reduce_logical < LOGICAL_TREE_NUM;
                   head_reduce_logical = head_reduce_logical + 1) begin
                  logical_head_resource_exists[head_reduce_logical] =
                      |logical_head_resource_mask[head_reduce_logical];
                  logical_head_candidate_found[head_reduce_logical] =
                      |logical_head_min_mask[head_reduce_logical];
                  logical_head_min_full[head_reduce_logical] =
                      |logical_head_min_full_mask[head_reduce_logical];
                  logical_head_min_physical_tree_id[head_reduce_logical] =
                      {PHYSICAL_ID_WIDTH{1'b0}};
                  for (head_reduce_slot = 0;
                       head_reduce_slot < MAX_SHARDS_PER_LOGICAL;
                       head_reduce_slot = head_reduce_slot + 1) begin
                      logical_head_min_physical_tree_id[head_reduce_logical] =
                          logical_head_min_physical_tree_id[head_reduce_logical] |
                          logical_head_physical_term
                              [head_reduce_logical][head_reduce_slot];
                  end
              end
          end
        end else begin : GEN_PROJECTED_HEAD_CACHE
            wire [HEAD_CACHE_LEAVES-1:0]
                completion_context [0:LOGICAL_TREE_NUM-1];
            wire [HEAD_TUPLE_WIDTH-1:0]
                projected_tuple [0:LOGICAL_TREE_NUM-1]
                                [0:HEAD_CACHE_LEAVES-1];
            wire [HEAD_TUPLE_WIDTH-1:0]
                tournament_l1 [0:LOGICAL_TREE_NUM-1][0:7];
            wire [HEAD_TUPLE_WIDTH-1:0]
                tournament_l2 [0:LOGICAL_TREE_NUM-1][0:3];
            wire [HEAD_TUPLE_WIDTH-1:0]
                tournament_l3 [0:LOGICAL_TREE_NUM-1][0:1];
            wire [HEAD_TUPLE_WIDTH-1:0]
                tournament_root [0:LOGICAL_TREE_NUM-1];

            reg cached_valid [0:LOGICAL_TREE_NUM-1];
            reg cached_full [0:LOGICAL_TREE_NUM-1];
            reg [PHYSICAL_ID_WIDTH-1:0]
                cached_physical_id [0:LOGICAL_TREE_NUM-1];

            for (cache_logical = 0;
                 cache_logical < LOGICAL_TREE_NUM;
                 cache_logical = cache_logical + 1) begin : GEN_CACHE_LOGICAL
                for (cache_leaf = 0;
                     cache_leaf < HEAD_CACHE_LEAVES;
                     cache_leaf = cache_leaf + 1) begin : GEN_CACHE_LEAF
                    if (cache_leaf < SHARD_COUNTS[cache_logical]) begin : GEN_USED
                        localparam integer CACHE_PHYSICAL_ID =
                            configured_physical_id(cache_logical, cache_leaf);
                        localparam integer CACHE_UPDATE_PORT =
                            CACHE_PHYSICAL_ID % UPDATE_PORTS;
                        wire update_context;
                        wire update_effect;

                        assign update_context =
                            i_update_valid[CACHE_UPDATE_PORT] &&
                            (i_update_physical_tree_id[CACHE_UPDATE_PORT] ==
                             PHYSICAL_ID_WIDTH'(CACHE_PHYSICAL_ID)) &&
                            o_update_pending[CACHE_PHYSICAL_ID] &&
                            o_logical_busy[cache_logical];
                        assign update_effect = update_context &&
                            ((o_pending_push[CACHE_PHYSICAL_ID] &&
                              (o_shard_count[CACHE_PHYSICAL_ID] <
                               SHARD_CAPACITY)) ||
                             (!o_pending_push[CACHE_PHYSICAL_ID] &&
                              (o_shard_count[CACHE_PHYSICAL_ID] != 0) &&
                              (o_logical_count[cache_logical] != 0)));

                        assign completion_context[cache_logical][cache_leaf] =
                            update_context;
                        assign projected_tuple[cache_logical][cache_leaf] = {
                            update_effect ?
                                (o_pending_push[CACHE_PHYSICAL_ID] ||
                                 (o_shard_count[CACHE_PHYSICAL_ID] != 1)) :
                                o_shard_head_valid[CACHE_PHYSICAL_ID],
                            update_effect ?
                                (o_pending_push[CACHE_PHYSICAL_ID] &&
                                 (o_shard_count[CACHE_PHYSICAL_ID] ==
                                  SHARD_CAPACITY - 1)) :
                                o_shard_full[CACHE_PHYSICAL_ID],
                            update_effect ?
                                ((!o_pending_push[CACHE_PHYSICAL_ID] &&
                                  (o_shard_count[CACHE_PHYSICAL_ID] == 1)) ?
                                     {RANK_WIDTH{1'b1}} :
                                     i_update_head_rank[CACHE_UPDATE_PORT]) :
                                o_shard_head_rank[CACHE_PHYSICAL_ID],
                            PHYSICAL_ID_WIDTH'(CACHE_PHYSICAL_ID)
                        };
                    end else begin : GEN_UNUSED
                        assign completion_context[cache_logical][cache_leaf] =
                            1'b0;
                        assign projected_tuple[cache_logical][cache_leaf] = {
                            1'b0,
                            1'b0,
                            {RANK_WIDTH{1'b1}},
                            {PHYSICAL_ID_WIDTH{1'b0}}
                        };
                    end
                end

                for (cache_pair_l1 = 0; cache_pair_l1 < 8;
                     cache_pair_l1 = cache_pair_l1 + 1) begin : GEN_CACHE_L1
                    assign tournament_l1[cache_logical][cache_pair_l1] =
                        choose_head_tuple(
                            projected_tuple[cache_logical][cache_pair_l1 * 2],
                            projected_tuple[cache_logical]
                                           [cache_pair_l1 * 2 + 1]);
                end
                for (cache_pair_l2 = 0; cache_pair_l2 < 4;
                     cache_pair_l2 = cache_pair_l2 + 1) begin : GEN_CACHE_L2
                    assign tournament_l2[cache_logical][cache_pair_l2] =
                        choose_head_tuple(
                            tournament_l1[cache_logical][cache_pair_l2 * 2],
                            tournament_l1[cache_logical]
                                         [cache_pair_l2 * 2 + 1]);
                end
                for (cache_pair_l3 = 0; cache_pair_l3 < 2;
                     cache_pair_l3 = cache_pair_l3 + 1) begin : GEN_CACHE_L3
                    assign tournament_l3[cache_logical][cache_pair_l3] =
                        choose_head_tuple(
                            tournament_l2[cache_logical][cache_pair_l3 * 2],
                            tournament_l2[cache_logical]
                                         [cache_pair_l3 * 2 + 1]);
                end
                assign tournament_root[cache_logical] =
                    choose_head_tuple(tournament_l3[cache_logical][0],
                                      tournament_l3[cache_logical][1]);
            end

            integer cache_seq_logical;
            always @(posedge i_clk or negedge i_arst_n) begin
                if (!i_arst_n) begin
                    for (cache_seq_logical = 0;
                         cache_seq_logical < LOGICAL_TREE_NUM;
                        cache_seq_logical = cache_seq_logical + 1) begin
                        cached_valid[cache_seq_logical] <= 1'b0;
                        cached_full[cache_seq_logical] <= 1'b0;
                        cached_physical_id[cache_seq_logical] <=
                            {PHYSICAL_ID_WIDTH{1'b0}};
                    end
                end else begin
                    for (cache_seq_logical = 0;
                         cache_seq_logical < LOGICAL_TREE_NUM;
                        cache_seq_logical = cache_seq_logical + 1) begin
                        if (|completion_context[cache_seq_logical]) begin
                            cached_valid[cache_seq_logical] <=
                                tournament_root[cache_seq_logical]
                                               [HEAD_TUPLE_VALID_BIT];
                            cached_full[cache_seq_logical] <=
                                tournament_root[cache_seq_logical]
                                               [HEAD_TUPLE_FULL_BIT];
                            cached_physical_id[cache_seq_logical] <=
                                tournament_root[cache_seq_logical]
                                               [HEAD_TUPLE_ID_LSB +:
                                                PHYSICAL_ID_WIDTH];
                        end
                    end
                end
            end

            // The cache must equal a fresh minimum of committed directory
            // state on every cycle without a concurrent completion.  Keep an
            // independent procedural reference model in simulation so stale,
            // misprojected, and tie-break errors fail at their source rather
            // than later as a packet-order mismatch.
`ifndef SYNTHESIS
            integer cache_check_logical;
            integer cache_check_slot;
            integer cache_check_physical;
            reg cache_check_valid;
            reg cache_check_full;
            reg [RANK_WIDTH-1:0] cache_check_rank;
            reg [PHYSICAL_ID_WIDTH-1:0] cache_check_id;
            always @(negedge i_clk) begin
                if (i_arst_n) begin
                    for (cache_check_logical = 0;
                         cache_check_logical < LOGICAL_TREE_NUM;
                         cache_check_logical = cache_check_logical + 1) begin
                        begin
                            cache_check_valid = 1'b0;
                            cache_check_full = 1'b0;
                            cache_check_rank = {RANK_WIDTH{1'b1}};
                            cache_check_id = {PHYSICAL_ID_WIDTH{1'b0}};
                            for (cache_check_slot = 0;
                                 cache_check_slot <
                                     SHARD_COUNTS[cache_check_logical];
                                 cache_check_slot = cache_check_slot + 1) begin
                                cache_check_physical = configured_physical_id(
                                    cache_check_logical, cache_check_slot);
                                if (o_shard_head_valid[cache_check_physical] &&
                                    (!cache_check_valid ||
                                     (o_shard_head_rank[cache_check_physical] <
                                      cache_check_rank) ||
                                     ((o_shard_head_rank[cache_check_physical] ==
                                       cache_check_rank) &&
                                      (cache_check_physical <
                                       int'(cache_check_id))))) begin
                                    cache_check_valid = 1'b1;
                                    cache_check_full =
                                        o_shard_full[cache_check_physical];
                                    cache_check_rank =
                                        o_shard_head_rank[cache_check_physical];
                                    cache_check_id = PHYSICAL_ID_WIDTH'(
                                        cache_check_physical);
                                end
                            end
                            assert ((cached_valid[cache_check_logical] ==
                                     cache_check_valid) &&
                                    (!cache_check_valid ||
                                     ((cached_full[cache_check_logical] ==
                                       cache_check_full) &&
                                      (cached_physical_id[cache_check_logical] ==
                                       cache_check_id))))
                            else $error("projected Head cache mismatch for logical %0d",
                                        cache_check_logical);
                        end
                    end
                end
            end
`endif

            always_comb begin
                for (head_reduce_logical = 0;
                     head_reduce_logical < LOGICAL_TREE_NUM;
                     head_reduce_logical = head_reduce_logical + 1) begin
                    logical_head_resource_exists[head_reduce_logical] =
                        cached_valid[head_reduce_logical];
                    logical_head_candidate_found[head_reduce_logical] =
                        cached_valid[head_reduce_logical];
                    logical_head_min_full[head_reduce_logical] =
                        cached_full[head_reduce_logical];
                    logical_head_min_physical_tree_id
                        [head_reduce_logical] =
                            cached_physical_id[head_reduce_logical];
                end
            end
        end
    endgenerate

    // Build the round-robin Push choice once per logical PIFO.  P/P fallback,
    // empty-P/P, and ordinary Push all consume the same result; computing it
    // at each request branch replicated the rotated shard scan three times.
    reg logical_push_resource_exists [0:LOGICAL_TREE_NUM-1];
    reg logical_push_candidate_found [0:LOGICAL_TREE_NUM-1];
    reg [PHYSICAL_ID_WIDTH-1:0]
        logical_push_physical_tree_id [0:LOGICAL_TREE_NUM-1];

    genvar push_logical;
    generate
        for (push_logical = 0; push_logical < LOGICAL_TREE_NUM;
             push_logical = push_logical + 1) begin : GEN_LOGICAL_PUSH_SELECT
            integer push_scan;
            integer push_slot;
            integer push_physical;
            always_comb begin
                logical_push_resource_exists[push_logical] = 1'b0;
                logical_push_candidate_found[push_logical] = 1'b0;
                logical_push_physical_tree_id[push_logical] =
                    {PHYSICAL_ID_WIDTH{1'b0}};
                push_slot = 0;
                push_physical = 0;

                for (push_scan = 0;
                     push_scan < MAX_SHARDS_PER_LOGICAL;
                     push_scan = push_scan + 1) begin
                    push_slot = int'(o_push_rr_ptr[push_logical]) +
                        push_scan;
                    if (push_slot >= SHARD_COUNTS[push_logical])
                        push_slot = push_slot -
                            SHARD_COUNTS[push_logical];
                    push_physical = configured_physical_id(
                        push_logical, push_slot);

                    if ((push_scan < SHARD_COUNTS[push_logical]) &&
                        !o_shard_full[push_physical]) begin
                        logical_push_resource_exists[push_logical] = 1'b1;
                        if (!logical_push_candidate_found[push_logical] &&
                            ((FIXED_LOGICAL_PORTS != 0) ||
                             !o_update_pending[push_physical])) begin
                            logical_push_candidate_found[push_logical] = 1'b1;
                            logical_push_physical_tree_id[push_logical] =
                                push_physical[PHYSICAL_ID_WIDTH-1:0];
                        end
                    end
                end
            end
        end
    endgenerate

    genvar output_port;
    generate
        for (output_port = 0; output_port < REQUEST_PORTS;
             output_port = output_port + 1) begin : GEN_GRANT_OUTPUTS
            assign o_select_valid[output_port] =
                grant_fill_valid[output_port];
            assign o_select_pp[output_port] = grant_fill_pp[output_port];
            assign o_physical_tree_id[output_port] =
                grant_fill_physical_tree_id[output_port];
        end
    endgenerate

    integer request_port;
    integer reservation_port;
    always_comb begin
        selection_logical_reserved = {LOGICAL_TREE_NUM{1'b0}};
        for (reservation_port = 0;
             reservation_port < REQUEST_PORTS;
             reservation_port = reservation_port + 1) begin
            if ((FIXED_LOGICAL_PORTS == 0) &&
                grant_valid_reg[reservation_port]) begin
                selection_logical_reserved[
                    grant_logical_tree_id_reg[reservation_port]] = 1'b1;
            end
        end

        for (request_port = 0; request_port < REQUEST_PORTS;
             request_port = request_port + 1) begin
            grant_fill_valid[request_port] = 1'b0;
            grant_fill_push[request_port] = i_req_push[request_port];
            grant_fill_pp[request_port] = 1'b0;
            grant_fill_logical_tree_id[request_port] =
                request_logical_tree_id[request_port];
            grant_fill_physical_tree_id[request_port] =
                {PHYSICAL_ID_WIDTH{1'b0}};
            o_reject_empty[request_port] = 1'b0;
            o_reject_full[request_port] = 1'b0;
            o_reject_bad_id[request_port] = 1'b0;
            request_stall[request_port] = 1'b0;
            candidate_found[request_port] = 1'b0;
            resource_exists[request_port] = 1'b0;

            if (!grant_valid_reg[request_port] &&
                i_req_valid[request_port]) begin
                if ((FIXED_LOGICAL_PORTS == 0) &&
                    (int'(request_logical_tree_id[request_port]) >=
                     LOGICAL_TREE_NUM)) begin
                    o_reject_bad_id[request_port] = 1'b1;
                end else if (((FIXED_LOGICAL_PORTS == 0) &&
                              selection_logical_reserved[
                                  request_logical_tree_id[request_port]]) ||
                             o_logical_busy[
                                 request_logical_tree_id[request_port]]) begin
                    request_stall[request_port] = 1'b1;
                end else if (i_req_pp[request_port]) begin
                    // A same-logical compound operation reuses one original
                    // P/P TaskFIFO word only when Push and Pop can both execute
                    // safely on one physical shard.  For a non-empty logical
                    // PIFO that shard is the current global-min Head shard.  An
                    // empty logical PIFO uses the ordinary RR Push target.
                    resource_exists[request_port] =
                        logical_head_resource_exists[
                            request_logical_tree_id[request_port]];
                    candidate_found[request_port] =
                        logical_head_candidate_found[
                            request_logical_tree_id[request_port]];
                    grant_fill_physical_tree_id[request_port] =
                        logical_head_min_physical_tree_id[
                            request_logical_tree_id[request_port]];
                    if (candidate_found[request_port] &&
                        !logical_head_min_full[
                            request_logical_tree_id[request_port]]) begin
                        grant_fill_valid[request_port] = 1'b1;
                        grant_fill_pp[request_port] = 1'b1;
                    end else if (resource_exists[request_port] &&
                                 candidate_found[request_port]) begin
                        // The global-min shard is locally full.  Preserve the
                        // original Push-first semantics by falling back to the
                        // existing two-request path: dispatch only the Push now
                        // and let its completion expose the paired Pop later.
                        resource_exists[request_port] =
                            logical_push_resource_exists[
                                request_logical_tree_id[request_port]];
                        candidate_found[request_port] =
                            logical_push_candidate_found[
                                request_logical_tree_id[request_port]];
                        grant_fill_physical_tree_id[request_port] =
                            logical_push_physical_tree_id[
                                request_logical_tree_id[request_port]];
                        if (candidate_found[request_port])
                            grant_fill_valid[request_port] = 1'b1;
                        else if (resource_exists[request_port])
                            request_stall[request_port] = 1'b1;
                        else
                            o_reject_full[request_port] = 1'b1;
                    end else if (resource_exists[request_port]) begin
                        request_stall[request_port] = 1'b1;
                    end else begin
                        // Empty logical PIFO: Push and Pop use the same normal
                        // RR Push target, leaving the logical count unchanged
                        // after both RPU phases complete.
                        resource_exists[request_port] =
                            logical_push_resource_exists[
                                request_logical_tree_id[request_port]];
                        candidate_found[request_port] =
                            logical_push_candidate_found[
                                request_logical_tree_id[request_port]];
                        grant_fill_physical_tree_id[request_port] =
                            logical_push_physical_tree_id[
                                request_logical_tree_id[request_port]];
                        if (candidate_found[request_port]) begin
                            grant_fill_valid[request_port] = 1'b1;
                            grant_fill_pp[request_port] = 1'b1;
                        end else if (resource_exists[request_port]) begin
                            request_stall[request_port] = 1'b1;
                        end else begin
                            o_reject_full[request_port] = 1'b1;
                        end
                    end
                end else if (i_req_push[request_port]) begin
                    resource_exists[request_port] =
                        logical_push_resource_exists[
                            request_logical_tree_id[request_port]];
                    candidate_found[request_port] =
                        logical_push_candidate_found[
                            request_logical_tree_id[request_port]];
                    grant_fill_physical_tree_id[request_port] =
                        logical_push_physical_tree_id[
                            request_logical_tree_id[request_port]];
                    if (candidate_found[request_port])
                        grant_fill_valid[request_port] = 1'b1;
                    else if (resource_exists[request_port])
                        request_stall[request_port] = 1'b1;
                    else
                        o_reject_full[request_port] = 1'b1;
                end else begin
                    resource_exists[request_port] =
                        logical_head_resource_exists[
                            request_logical_tree_id[request_port]];
                    candidate_found[request_port] =
                        logical_head_candidate_found[
                            request_logical_tree_id[request_port]];
                    grant_fill_physical_tree_id[request_port] =
                        logical_head_min_physical_tree_id[
                            request_logical_tree_id[request_port]];
                    if (candidate_found[request_port]) begin
                        grant_fill_valid[request_port] = 1'b1;
                    end else if (resource_exists[request_port])
                        request_stall[request_port] = 1'b1;
                    else
                        o_reject_empty[request_port] = 1'b1;
                end
            end

            if ((FIXED_LOGICAL_PORTS == 0) &&
                grant_fill_valid[request_port]) begin
                selection_logical_reserved[
                    grant_fill_logical_tree_id[request_port]] = 1'b1;
            end

        end
    end

    assign select_fire = o_select_valid & i_select_ready;
    assign o_req_ready = ~grant_valid_reg & ~request_stall &
        i_select_ready;

    integer busy_logical;
    reg any_busy;
    always_comb begin
        any_busy = 1'b0;
        for (busy_logical = 0; busy_logical < LOGICAL_TREE_NUM;
             busy_logical = busy_logical + 1)
            any_busy = any_busy | o_logical_busy[busy_logical];
    end
    assign o_busy = any_busy | (|grant_valid_reg);

    integer logical_index;
    integer shard_index;
    integer next_slot;
    integer commit_port;
    integer earlier_commit_port;
    integer update_port;
    integer duplicate_port;
    integer completed_physical;
    integer completed_logical;
    reg commit_conflict;
    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            o_protocol_error <= 1'b0;

            grant_valid_reg <= {REQUEST_PORTS{1'b0}};
            grant_push_reg <= {REQUEST_PORTS{1'b0}};
            grant_pp_reg <= {REQUEST_PORTS{1'b0}};
            for (commit_port = 0; commit_port < REQUEST_PORTS;
                 commit_port = commit_port + 1) begin
                if (FIXED_LOGICAL_PORTS == 0)
                    grant_logical_tree_id_reg[commit_port] <=
                        {LOGICAL_ID_WIDTH{1'b0}};
                grant_physical_tree_id_reg[commit_port] <=
                    {PHYSICAL_ID_WIDTH{1'b0}};
            end

            for (logical_index = 0;
                 logical_index < LOGICAL_TREE_NUM;
                 logical_index = logical_index + 1) begin
                if (DERIVE_LOGICAL_COUNT == 0)
                    logical_count_state[logical_index] <=
                        {TOTAL_COUNT_WIDTH{1'b0}};
                o_push_rr_ptr[logical_index] <= {RR_WIDTH{1'b0}};
                o_logical_busy[logical_index] <= 1'b0;
                o_logical_shard_count[logical_index] <=
                    SHARD_LIST_COUNT_WIDTH'(
                        configured_shard_count(logical_index));
                for (shard_index = 0;
                     shard_index < MAX_SHARDS_PER_LOGICAL;
                     shard_index = shard_index + 1)
                    o_shard_list[logical_index][shard_index] <=
                        PHYSICAL_ID_WIDTH'(
                            configured_physical_id(logical_index,
                                                   shard_index));
            end

            for (shard_index = 0;
                 shard_index < PHYSICAL_TREE_NUM;
                 shard_index = shard_index + 1) begin
                o_shard_count[shard_index] <=
                    {SHARD_COUNT_WIDTH{1'b0}};
                o_shard_head_rank[shard_index] <=
                    {RANK_WIDTH{1'b1}};
                o_shard_empty[shard_index] <= 1'b1;
                o_shard_full[shard_index] <= 1'b0;
                o_shard_head_valid[shard_index] <= 1'b0;
                o_update_pending[shard_index] <= 1'b0;
                o_pending_push[shard_index] <= 1'b0;
                o_pending_pp[shard_index] <= 1'b0;
            end
        end else begin
            // Stage A captures only a selection that was actually accepted by
            // the caller.  Stage B below commits the previous cycle's context.
            // The per-port buffer is intentionally not fall-through: the live
            // candidate still names the just-dispatched request on this edge.
            for (commit_port = 0; commit_port < REQUEST_PORTS;
                 commit_port = commit_port + 1) begin
                if (grant_valid_reg[commit_port]) begin
                    grant_valid_reg[commit_port] <= 1'b0;
                end else if (select_fire[commit_port]) begin
                    grant_valid_reg[commit_port] <= 1'b1;
                    grant_push_reg[commit_port] <=
                        grant_fill_push[commit_port];
                    grant_pp_reg[commit_port] <=
                        grant_fill_pp[commit_port];
                    if (FIXED_LOGICAL_PORTS == 0)
                        grant_logical_tree_id_reg[commit_port] <=
                            grant_fill_logical_tree_id[commit_port];
                    grant_physical_tree_id_reg[commit_port] <=
                        grant_fill_physical_tree_id[commit_port];
                end
            end

            for (commit_port = 0; commit_port < REQUEST_PORTS;
                 commit_port = commit_port + 1) begin
                if (grant_valid_reg[commit_port]) begin
                    commit_conflict = 1'b0;
                    for (earlier_commit_port = 0;
                         earlier_commit_port < commit_port;
                        earlier_commit_port =
                             earlier_commit_port + 1) begin
                        if ((FIXED_LOGICAL_PORTS == 0) &&
                            grant_valid_reg[earlier_commit_port] &&
                            ((commit_logical_tree_id[
                                  earlier_commit_port] ==
                              commit_logical_tree_id[commit_port]) ||
                             (grant_physical_tree_id_reg[
                                  earlier_commit_port] ==
                              grant_physical_tree_id_reg[commit_port])))
                            commit_conflict = 1'b1;
                    end

                    if (commit_conflict ||
                        o_logical_busy[
                            commit_logical_tree_id[commit_port]] ||
                        o_update_pending[
                            grant_physical_tree_id_reg[commit_port]]) begin
                        o_protocol_error <= 1'b1;
                    end else begin
                        o_logical_busy[
                            commit_logical_tree_id[commit_port]] <= 1'b1;
                        o_update_pending[
                            grant_physical_tree_id_reg[commit_port]] <= 1'b1;
                        o_pending_push[
                            grant_physical_tree_id_reg[commit_port]] <=
                                grant_push_reg[commit_port] ||
                                grant_pp_reg[commit_port];
                        o_pending_pp[
                            grant_physical_tree_id_reg[commit_port]] <=
                                grant_pp_reg[commit_port];

                        if (grant_push_reg[commit_port] ||
                            grant_pp_reg[commit_port]) begin
                            next_slot = configured_local_slot(
                                int'(commit_logical_tree_id[
                                    commit_port]),
                                int'(grant_physical_tree_id_reg[
                                    commit_port])) + 1;
                            if (next_slot >= configured_shard_count(
                                int'(commit_logical_tree_id[
                                    commit_port]))) begin
                                next_slot = 0;
                            end
                            o_push_rr_ptr[
                                commit_logical_tree_id[commit_port]] <=
                                next_slot[RR_WIDTH-1:0];
                        end
                    end
                end
            end

            // A one-shard logical PIFO has no alternative round-robin target:
            // configured_local_slot() is always zero and the wrapped next
            // slot is therefore always zero.  Keep those static pointers at
            // zero so synthesis can remove their registers and the associated
            // dynamic physical-ID/lane decode.  Multi-shard logical PIFOs
            // retain the original update behavior above.
            for (logical_index = 0; logical_index < LOGICAL_TREE_NUM;
                 logical_index = logical_index + 1) begin
                if (SHARD_COUNTS[logical_index] == 1)
                    o_push_rr_ptr[logical_index] <= {RR_WIDTH{1'b0}};
            end

            if (FIXED_RPU_UPDATE_PORTS != 0) begin
                // Rotating placement fixes the root of physical tree P in
                // RPU lane P modulo UPDATE_PORTS.  Iterate over shard state,
                // not update ports, so every state element has one constant
                // completion source and one local physical-ID equality test.
                for (shard_index = 0;
                     shard_index < PHYSICAL_TREE_NUM;
                     shard_index = shard_index + 1) begin
                    update_port = shard_index % UPDATE_PORTS;
                    if (i_update_valid[update_port] &&
                        (i_update_physical_tree_id[update_port] ==
                         PHYSICAL_ID_WIDTH'(shard_index))) begin
                        completed_logical =
                            int'(o_pending_logical_tree_id[shard_index]);
                        if (!o_update_pending[shard_index]) begin
                            o_protocol_error <= 1'b1;
                        end else if (completed_logical >=
                                     LOGICAL_TREE_NUM) begin
                            o_protocol_error <= 1'b1;
                        end else if (!o_logical_busy[
                                     completed_logical]) begin
                            o_protocol_error <= 1'b1;
                        end else begin
                            // A P/P word first reports its Push summary and
                            // later reports its Pop replacement Head.  Retain
                            // the single logical/physical context between the
                            // two fixed-lane completions exactly as before.
                            if (!(o_pending_pp[shard_index] &&
                                  o_pending_push[shard_index])) begin
                                o_update_pending[shard_index] <= 1'b0;
                                o_logical_busy[
                                    completed_logical] <= 1'b0;
                                o_pending_pp[shard_index] <= 1'b0;
                            end

                            if (o_pending_push[shard_index]) begin
                                if (o_pending_pp[shard_index])
                                    o_pending_push[shard_index] <= 1'b0;
                                if (o_shard_count[shard_index] >=
                                    SHARD_CAPACITY) begin
                                    o_protocol_error <= 1'b1;
                                end else begin
                                    o_shard_count[shard_index] <=
                                        o_shard_count[shard_index] + 1'b1;
                                    if (DERIVE_LOGICAL_COUNT == 0)
                                        logical_count_state[
                                            completed_logical] <=
                                            logical_count_state[
                                                completed_logical] + 1'b1;
                                    o_shard_empty[shard_index] <= 1'b0;
                                    o_shard_head_valid[
                                        shard_index] <= 1'b1;
                                    o_shard_head_rank[shard_index] <=
                                        i_update_head_rank[update_port];
                                    if (o_shard_count[shard_index] ==
                                        SHARD_CAPACITY - 1)
                                        o_shard_full[
                                            shard_index] <= 1'b1;
                                end
                            end else begin
                                if ((o_shard_count[shard_index] == 0) ||
                                    ((DERIVE_LOGICAL_COUNT == 0) &&
                                     (logical_count_state[
                                      completed_logical] == 0))) begin
                                    o_protocol_error <= 1'b1;
                                end else begin
                                    o_shard_count[shard_index] <=
                                        o_shard_count[shard_index] - 1'b1;
                                    if (DERIVE_LOGICAL_COUNT == 0)
                                        logical_count_state[
                                            completed_logical] <=
                                            logical_count_state[
                                                completed_logical] - 1'b1;
                                    o_shard_full[shard_index] <= 1'b0;
                                    if (o_shard_count[shard_index] == 1) begin
                                        o_shard_empty[
                                            shard_index] <= 1'b1;
                                        o_shard_head_valid[
                                            shard_index] <= 1'b0;
                                        o_shard_head_rank[
                                            shard_index] <=
                                                {RANK_WIDTH{1'b1}};
                                    end else begin
                                        o_shard_empty[
                                            shard_index] <= 1'b0;
                                        o_shard_head_valid[
                                            shard_index] <= 1'b1;
                                        o_shard_head_rank[
                                            shard_index] <=
                                            i_update_head_rank[update_port];
                                    end
                                end
                            end
                        end
                    end
                end
            end else begin
                // Generic standalone interface: any update port may name any
                // physical shard, so retain the original dynamic write path
                // and duplicate-port diagnostics.
                for (update_port = 0; update_port < UPDATE_PORTS;
                     update_port = update_port + 1) begin
                    if (i_update_valid[update_port]) begin
                        completed_physical =
                            int'(i_update_physical_tree_id[
                                update_port]);
                        if (completed_physical >= PHYSICAL_TREE_NUM) begin
                            o_protocol_error <= 1'b1;
                        end else if (!o_update_pending[
                                     completed_physical]) begin
                            o_protocol_error <= 1'b1;
                        end else begin
                            completed_logical =
                                int'(o_pending_logical_tree_id[
                                    completed_physical]);
                            if (completed_logical >= LOGICAL_TREE_NUM) begin
                                o_protocol_error <= 1'b1;
                            end else if (!o_logical_busy[
                                         completed_logical]) begin
                                o_protocol_error <= 1'b1;
                            end else begin
                                // One original P/P word produces a Push root
                                // completion followed later by a Pop root
                                // completion.  Keep the single logical lock and
                                // physical context live across the intermediate
                                // Push summary; retire them only after the Pop.
                                if (!(o_pending_pp[
                                          completed_physical] &&
                                      o_pending_push[
                                          completed_physical])) begin
                                    o_update_pending[
                                        completed_physical] <= 1'b0;
                                    o_logical_busy[
                                        completed_logical] <= 1'b0;
                                    o_pending_pp[
                                        completed_physical] <= 1'b0;
                                end

                                if (o_pending_push[
                                    completed_physical]) begin
                                    if (o_pending_pp[
                                        completed_physical])
                                        o_pending_push[
                                            completed_physical] <= 1'b0;
                                    if (o_shard_count[
                                        completed_physical] >=
                                        SHARD_CAPACITY) begin
                                        o_protocol_error <= 1'b1;
                                    end else begin
                                        o_shard_count[
                                            completed_physical] <=
                                            o_shard_count[
                                                completed_physical] + 1'b1;
                                        if (DERIVE_LOGICAL_COUNT == 0)
                                            logical_count_state[
                                                completed_logical] <=
                                                logical_count_state[
                                                    completed_logical] + 1'b1;
                                        o_shard_empty[
                                            completed_physical] <= 1'b0;
                                        o_shard_head_valid[
                                            completed_physical] <= 1'b1;
                                        o_shard_head_rank[
                                            completed_physical] <=
                                            i_update_head_rank[
                                                update_port];
                                        if (o_shard_count[
                                            completed_physical] ==
                                            SHARD_CAPACITY - 1)
                                            o_shard_full[
                                                completed_physical] <=
                                                    1'b1;
                                    end
                                end else begin
                                    if ((o_shard_count[
                                         completed_physical] == 0) ||
                                        ((DERIVE_LOGICAL_COUNT == 0) &&
                                         (logical_count_state[
                                          completed_logical] == 0))) begin
                                        o_protocol_error <= 1'b1;
                                    end else begin
                                        o_shard_count[
                                            completed_physical] <=
                                            o_shard_count[
                                                completed_physical] - 1'b1;
                                        if (DERIVE_LOGICAL_COUNT == 0)
                                            logical_count_state[
                                                completed_logical] <=
                                                logical_count_state[
                                                    completed_logical] - 1'b1;
                                        o_shard_full[
                                            completed_physical] <= 1'b0;
                                        if (o_shard_count[
                                            completed_physical] == 1) begin
                                            o_shard_empty[
                                                completed_physical] <=
                                                    1'b1;
                                            o_shard_head_valid[
                                                completed_physical] <=
                                                    1'b0;
                                            o_shard_head_rank[
                                                completed_physical] <=
                                                    {RANK_WIDTH{1'b1}};
                                        end else begin
                                            o_shard_empty[
                                                completed_physical] <=
                                                    1'b0;
                                            o_shard_head_valid[
                                                completed_physical] <=
                                                    1'b1;
                                            o_shard_head_rank[
                                                completed_physical] <=
                                                    i_update_head_rank[
                                                        update_port];
                                        end
                                    end
                                end
                            end
                        end

                        for (duplicate_port = update_port + 1;
                             duplicate_port < UPDATE_PORTS;
                             duplicate_port = duplicate_port + 1) begin
                            if (i_update_valid[duplicate_port] &&
                                (i_update_physical_tree_id[
                                    duplicate_port] ==
                                 i_update_physical_tree_id[
                                    update_port]))
                                o_protocol_error <= 1'b1;
                        end
                    end
                end
            end
        end
    end

endmodule
