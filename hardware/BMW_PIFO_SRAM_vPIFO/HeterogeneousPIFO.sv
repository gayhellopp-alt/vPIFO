`timescale 1ns / 10ps

// Vector logical-to-physical wrapper around the original PIFO_SRAM_TOP.
//
// Requests are first captured in a shared logical pending pool.  They remain
// logical until the oldest request of a non-busy logical PIFO can be mapped by
// ShardDirectory and written into an original physical TaskFIFO.
// Arbitration is local to the target Engine lane:
//   1. the oldest pending request for each logical PIFO is eligible;
//   2. each lane accepts one FIFO word;
//   3. that word contains both Push and Pop only when the requests were captured
//      as one generation event, as in the original vector TaskGenerator.
//
// A per-logical candidate register isolates the pending-pool head lookup from
// directory mapping and lane arbitration; there is no global single-issue
// register.  Capture fire and physical dispatch fire remain separate interfaces
// with separate meanings.
module HeterogeneousPIFO #(
    parameter PTW = 16,
    parameter MTW = 16,
    parameter CTW = 10,
    parameter LEVEL = VpifoConfigPkg::LEVEL,
    parameter LOGICAL_TREE_NUM = VpifoConfigPkg::LOGICAL_TREE_NUM,
    parameter PHYSICAL_TREE_NUM = VpifoConfigPkg::PHYSICAL_TREE_NUM,
    parameter SHARD_CAPACITY = VpifoConfigPkg::SHARD_CAPACITY,
    parameter FIFO_SIZE = 8,
    parameter MAX_SHARDS_PER_LOGICAL =
        VpifoConfigPkg::MAX_SHARDS_PER_LOGICAL,
    parameter REQUEST_PORTS = LEVEL,
    parameter TASK_ORDER_WIDTH = 32,
    parameter LOGICAL_PENDING_DEPTH = REQUEST_PORTS + FIFO_SIZE,
    parameter POP_RESULT_FIFO_DEPTH = LOGICAL_TREE_NUM + LEVEL,
    parameter HIERARCHICAL_MODE = 0,
    // When set, each input slot is a complete logical operation with
    // independent Push/Pop bits.  The legacy half-request/provenance path is
    // retained for wrappers that have not yet moved their operation boundary.
    parameter integer NATIVE_COMPOUND_REQUESTS = 0,
    // The fixed three-tier wrapper admits at most one Pop chain at a time.
    // Its return path can therefore use a one-entry registered serializer
    // instead of the generic multi-enqueue PopResultFIFO.
    parameter integer SINGLE_POP_RETURN = 0,
    // Native complete-operation wrappers expose one request head per logical
    // OQ, matching the fixed per-OQ control boundary in the public vPIFO RTL.
    // Legacy wrappers retain runtime logical IDs and their established
    // Stage15 timing/dispatch contract unless explicitly overridden.
    parameter integer DIRECTORY_FIXED_LOGICAL_PORTS =
        NATIVE_COMPOUND_REQUESTS,
    // Native BMW integration also has a fixed completion topology: root
    // update lane L only returns physical IDs whose modulo LEVEL is L.
    // Preserve the generic Directory update interface for legacy wrappers.
    parameter integer DIRECTORY_FIXED_RPU_UPDATE_PORTS =
        NATIVE_COMPOUND_REQUESTS,
    // Native fixed-port integrations may derive each logical total directly
    // from its shard counters and avoid a second synchronized counter bank.
    parameter integer DIRECTORY_DERIVE_LOGICAL_COUNT =
        NATIVE_COMPOUND_REQUESTS,
    // Native fixed-port integration can register the completion-projected
    // per-logical Head and remove live shard comparison from dispatch.  The
    // implementation remains available for controlled ablation, but is not
    // enabled by default: on the boundary21 configuration its completion
    // path is longer and larger than the live-min implementation.
    parameter integer DIRECTORY_COMPLETION_PROJECTED_HEAD_CACHE =
        0,
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
                          $clog2(MAX_SHARDS_PER_LOGICAL),
    localparam POP_FIFO_PTR_WIDTH =
        (POP_RESULT_FIFO_DEPTH <= 1) ? 1 :
        $clog2(POP_RESULT_FIFO_DEPTH),
    localparam POP_FIFO_COUNT_WIDTH =
        (POP_RESULT_FIFO_DEPTH <= 1) ? 1 :
        $clog2(POP_RESULT_FIFO_DEPTH + 1),
    localparam POP_FIFO_ENQUEUE_COUNT_WIDTH = (LEVEL <= 1) ? 1 :
                                              $clog2(LEVEL + 1),
    localparam SOURCE_PORT_WIDTH = (REQUEST_PORTS <= 1) ? 1 :
                                   $clog2(REQUEST_PORTS),
    localparam PENDING_SLOT_WIDTH =
        (LOGICAL_PENDING_DEPTH <= 1) ? 1 :
        $clog2(LOGICAL_PENDING_DEPTH),
    localparam PENDING_COUNT_WIDTH =
        (LOGICAL_PENDING_DEPTH <= 1) ? 1 :
        $clog2(LOGICAL_PENDING_DEPTH + 1),
    localparam CANDIDATE_PAIR_COUNT =
        (LOGICAL_TREE_NUM * (LOGICAL_TREE_NUM - 1)) / 2,
    localparam CANDIDATE_PAIR_STORAGE_WIDTH =
        (CANDIDATE_PAIR_COUNT <= 0) ? 1 : CANDIDATE_PAIR_COUNT
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,

    input  wire [REQUEST_PORTS-1:0]     i_req_valid,
    input  wire [REQUEST_PORTS-1:0]     i_req_push,
    input  wire [REQUEST_PORTS-1:0]     i_req_pop,
    input  wire [LOGICAL_ID_WIDTH-1:0]  i_logical_tree_id [0:REQUEST_PORTS-1],
    input  wire [(MTW+PTW)-1:0]         i_push_data [0:REQUEST_PORTS-1],
    input  wire [TASK_ORDER_WIDTH-1:0]  i_req_order [0:REQUEST_PORTS-1],
    input  wire [REQUEST_PORTS-1:0]     i_req_merge_mask [0:REQUEST_PORTS-1],

    output wire [REQUEST_PORTS-1:0]     o_req_capture_ready,
    output wire [REQUEST_PORTS-1:0]     o_req_capture_fire,
    output wire [REQUEST_PORTS-1:0]     o_req_capture_bad_id,
    output wire [LOGICAL_TREE_NUM-1:0]  o_dispatch_fire,
    output wire [LOGICAL_TREE_NUM-1:0]  o_dispatch_push,
    output wire [LOGICAL_ID_WIDTH-1:0]  o_dispatch_logical_tree_id [0:LOGICAL_TREE_NUM-1],
    output wire [PHYSICAL_ID_WIDTH-1:0] o_selected_physical_tree_id [0:LOGICAL_TREE_NUM-1],
    output wire [(MTW+PTW)-1:0]         o_dispatch_data [0:LOGICAL_TREE_NUM-1],
    output wire [SOURCE_PORT_WIDTH-1:0] o_dispatch_source_port [0:LOGICAL_TREE_NUM-1],
    output wire [LOGICAL_TREE_NUM-1:0]  o_dispatch_reject_empty,
    output wire [LOGICAL_TREE_NUM-1:0]  o_dispatch_reject_full,
    output wire [PENDING_COUNT_WIDTH-1:0] o_logical_pending_count [0:LOGICAL_TREE_NUM-1],
    output wire [PENDING_COUNT_WIDTH-1:0] o_pending_count,
    output wire [PENDING_COUNT_WIDTH-1:0] o_pending_effective_free_count,
    output wire                         o_busy,

    output wire                         o_pop_valid,
    output wire [LOGICAL_ID_WIDTH-1:0]  o_pop_logical_tree_id,
    output wire [(MTW+PTW)-1:0]         o_pop_data,

    output wire                         o_internal_root_pop_valid,
    output wire [(MTW+PTW)-1:0]         o_internal_root_pop_data,

    output wire                         o_protocol_error,
    output wire [LEVEL-1:0]             o_task_fifo_full,
    output wire [LEVEL-1:0]             o_task_write,
    output wire [LEVEL-1:0]             o_task_push,
    output wire [LEVEL-1:0]             o_task_pop,

    output wire [PHYSICAL_ID_WIDTH-1:0] o_shard_list [0:LOGICAL_TREE_NUM-1][0:MAX_SHARDS_PER_LOGICAL-1],
    output wire [SHARD_LIST_COUNT_WIDTH-1:0] o_logical_shard_count [0:LOGICAL_TREE_NUM-1],
    output wire [TOTAL_COUNT_WIDTH-1:0] o_logical_count [0:LOGICAL_TREE_NUM-1],
    output wire [RR_WIDTH-1:0]          o_push_rr_ptr [0:LOGICAL_TREE_NUM-1],
    output wire [SHARD_COUNT_WIDTH-1:0] o_shard_count [0:PHYSICAL_TREE_NUM-1],
    output wire [PTW-1:0]               o_shard_head_rank [0:PHYSICAL_TREE_NUM-1],
    output wire                         o_shard_empty [0:PHYSICAL_TREE_NUM-1],
    output wire                         o_shard_full [0:PHYSICAL_TREE_NUM-1],
    output wire                         o_shard_head_valid [0:PHYSICAL_TREE_NUM-1],
    output wire                         o_update_pending [0:PHYSICAL_TREE_NUM-1],
    output wire                         o_logical_busy [0:LOGICAL_TREE_NUM-1],
    output wire [LOGICAL_ID_WIDTH-1:0]  o_pending_logical_tree_id [0:PHYSICAL_TREE_NUM-1],
    output wire                         o_pending_push [0:PHYSICAL_TREE_NUM-1]
);

    initial begin
        if ((REQUEST_PORTS < 1) || (TASK_ORDER_WIDTH < 2) ||
            (LOGICAL_PENDING_DEPTH < REQUEST_PORTS) ||
            ((SINGLE_POP_RETURN == 0) &&
             (POP_RESULT_FIFO_DEPTH < LOGICAL_TREE_NUM)))
            $fatal(1, "HeterogeneousPIFO request/order/result parameters are invalid");
    end

    wire [LOGICAL_TREE_NUM-1:0] pending_head_valid;
    wire [LOGICAL_TREE_NUM-1:0] pending_head_push;
    wire [LOGICAL_TREE_NUM-1:0] pending_head_pop;
    wire [(MTW+PTW)-1:0]
        pending_head_push_data [0:LOGICAL_TREE_NUM-1];
    wire [TASK_ORDER_WIDTH-1:0]
        pending_head_order [0:LOGICAL_TREE_NUM-1];
    wire [SOURCE_PORT_WIDTH-1:0]
        pending_head_source_port [0:LOGICAL_TREE_NUM-1];
    wire [PENDING_SLOT_WIDTH-1:0]
        pending_head_slot_id [0:LOGICAL_TREE_NUM-1];
    wire [LOGICAL_PENDING_DEPTH-1:0]
        pending_head_merge_slots [0:LOGICAL_TREE_NUM-1];
    wire [CANDIDATE_PAIR_STORAGE_WIDTH-1:0]
        pending_head_first_older;
    wire [CANDIDATE_PAIR_STORAGE_WIDTH-1:0]
        pending_head_pair_same_event_state;
    wire [LOGICAL_TREE_NUM-1:0]
        pending_partner_resolve_valid;
    wire [PENDING_SLOT_WIDTH-1:0]
        pending_partner_resolve_slot_id [0:LOGICAL_TREE_NUM-1];
    wire pending_buffer_full;
    wire pending_buffer_protocol_error;

    // One stable candidate per logical PIFO separates the associative
    // pending-head scan from physical shard selection and lane arbitration.
    // Each pending descriptor already carries independent Push and Pop bits.
    // A compound P/P is therefore one slot and needs no provenance relation,
    // partner search, or two-slot retirement descriptor.
    reg [LOGICAL_TREE_NUM-1:0] candidate_primary_valid;
    reg [LOGICAL_TREE_NUM-1:0] candidate_partner_resolving;
    reg [LOGICAL_TREE_NUM-1:0] candidate_dispatch_ready;
    wire [LOGICAL_TREE_NUM-1:0] candidate_valid;
    reg [LOGICAL_TREE_NUM-1:0] candidate_push;
    reg [LOGICAL_TREE_NUM-1:0] candidate_pop;
    reg [(MTW+PTW)-1:0]
        candidate_push_data [0:LOGICAL_TREE_NUM-1];
    reg [SOURCE_PORT_WIDTH-1:0]
        candidate_source_port [0:LOGICAL_TREE_NUM-1];
    reg [PENDING_SLOT_WIDTH-1:0]
        candidate_slot_id [0:LOGICAL_TREE_NUM-1];
    reg [LOGICAL_TREE_NUM-1:0]
        candidate_partner_valid;
    reg [PENDING_SLOT_WIDTH-1:0]
        candidate_partner_slot_id [0:LOGICAL_TREE_NUM-1];
    reg [LOGICAL_PENDING_DEPTH-1:0]
        candidate_merge_slots [0:LOGICAL_TREE_NUM-1];
    // Legacy half-request mode needs one relation bit per unordered logical
    // pair to recover exact arrival and same-event semantics.  Native complete
    // operations use the public-vPIFO-style lane scan below; synthesis can
    // therefore remove this state and its LRB relation source in native mode.
    reg [CANDIDATE_PAIR_STORAGE_WIDTH-1:0]
        candidate_first_older;
    reg [CANDIDATE_PAIR_STORAGE_WIDTH-1:0]
        candidate_pair_same_event_state;
    wire [LOGICAL_TREE_NUM-1:0]
        candidate_pair_older [0:LOGICAL_TREE_NUM-1];
    wire [LOGICAL_TREE_NUM-1:0]
        candidate_pair_same_event [0:LOGICAL_TREE_NUM-1];
    reg [LOGICAL_TREE_NUM-1:0] candidate_primary_fill;
    reg [LOGICAL_TREE_NUM-1:0] relation_candidate_present;
    reg [LOGICAL_TREE_NUM-1:0] candidate_refill_block;
    wire [LOGICAL_TREE_NUM-1:0]
        dispatch_retire_partner_valid;
    wire [LOGICAL_TREE_NUM-1:0] dispatch_retire_valid;
    wire [LOGICAL_TREE_NUM-1:0] native_pp_fallback_fire;

    assign candidate_valid = candidate_dispatch_ready;

    function integer candidate_pair_index;
        input integer first_logical;
        input integer second_logical;
        begin
            candidate_pair_index =
                (first_logical *
                 (2 * LOGICAL_TREE_NUM - first_logical - 1)) / 2 +
                (second_logical - first_logical - 1);
        end
    endfunction

    genvar candidate_relation_row;
    genvar candidate_relation_column;
    generate
        for (candidate_relation_row = 0;
             candidate_relation_row < LOGICAL_TREE_NUM;
             candidate_relation_row = candidate_relation_row + 1) begin :
             GEN_CANDIDATE_RELATION_ROW
            for (candidate_relation_column = 0;
                 candidate_relation_column < LOGICAL_TREE_NUM;
                 candidate_relation_column =
                     candidate_relation_column + 1) begin :
                 GEN_CANDIDATE_RELATION_COLUMN
                if (candidate_relation_row <
                    candidate_relation_column) begin : GEN_FORWARD_RELATION
                    localparam integer CANDIDATE_PAIR_INDEX =
                        candidate_pair_index(candidate_relation_row,
                                             candidate_relation_column);
                    assign candidate_pair_older[candidate_relation_row]
                                                [candidate_relation_column] =
                        candidate_first_older[CANDIDATE_PAIR_INDEX];
                    assign candidate_pair_same_event[
                               candidate_relation_row]
                               [candidate_relation_column] =
                        candidate_pair_same_event_state[
                            CANDIDATE_PAIR_INDEX];
                end else if (candidate_relation_row >
                             candidate_relation_column) begin :
                             GEN_REVERSE_RELATION
                    localparam integer CANDIDATE_PAIR_INDEX =
                        candidate_pair_index(candidate_relation_column,
                                             candidate_relation_row);
                    assign candidate_pair_older[candidate_relation_row]
                                                [candidate_relation_column] =
                        !candidate_first_older[CANDIDATE_PAIR_INDEX];
                    assign candidate_pair_same_event[
                               candidate_relation_row]
                               [candidate_relation_column] =
                        candidate_pair_same_event_state[
                            CANDIDATE_PAIR_INDEX];
                end else begin : GEN_SELF_RELATION
                    assign candidate_pair_older[candidate_relation_row]
                                                [candidate_relation_column] =
                        1'b0;
                    assign candidate_pair_same_event[
                               candidate_relation_row]
                               [candidate_relation_column] = 1'b0;
                end
            end
        end
    endgenerate

    wire [LOGICAL_ID_WIDTH-1:0]
        directory_logical_tree_id [0:LOGICAL_TREE_NUM-1];
    wire [LOGICAL_TREE_NUM-1:0] directory_select_valid;
    wire [LOGICAL_TREE_NUM-1:0] directory_select_pp;
    reg  [LOGICAL_TREE_NUM-1:0] directory_select_ready;
    wire [PHYSICAL_ID_WIDTH-1:0]
        directory_physical_tree_id [0:LOGICAL_TREE_NUM-1];
    wire [LOGICAL_TREE_NUM-1:0] directory_reject_bad_id;
    wire directory_protocol_error;
    wire directory_busy;

    wire [LEVEL-1:0] engine_push;
    wire [LEVEL-1:0] engine_pop;
    reg  [PHYSICAL_ID_WIDTH-1:0] engine_push_tree_id [0:LEVEL-1];
    reg  [PHYSICAL_ID_WIDTH-1:0] engine_pop_tree_id [0:LEVEL-1];
    reg  [(MTW+PTW)-1:0] engine_push_data [0:LEVEL-1];
    wire [PHYSICAL_ID_WIDTH-1:0] engine_tree_id [0:LEVEL-1];
    wire [(MTW+PTW)-1:0] engine_pop_data [0:LEVEL-1];
    wire [LEVEL-1:0] engine_is_level0_pop;
    wire [LEVEL-1:0] engine_root_update_valid;
    wire [PTW-1:0] engine_root_update_head_rank [0:LEVEL-1];
    wire [LEVEL-1:0] engine_task_fifo_full;

    reg [LEVEL-1:0] engine_push_reg;
    reg [LEVEL-1:0] engine_pop_reg;
    integer arbitration_lane;
    integer arbitration_logical;
    integer arbitration_other_logical;
    reg [LOGICAL_TREE_NUM-1:0]
        lane_pp_candidate [0:LEVEL-1];
    reg [LOGICAL_TREE_NUM-1:0]
        lane_push_candidate [0:LEVEL-1];
    reg [LOGICAL_TREE_NUM-1:0]
        lane_pop_candidate [0:LEVEL-1];
    reg [LOGICAL_TREE_NUM-1:0]
        lane_any_candidate [0:LEVEL-1];
    reg [LOGICAL_TREE_NUM-1:0]
        lane_pp_winner [0:LEVEL-1];
    reg [LOGICAL_TREE_NUM-1:0]
        lane_push_winner [0:LEVEL-1];
    reg [LOGICAL_TREE_NUM-1:0]
        lane_pop_winner [0:LEVEL-1];
    reg [LOGICAL_TREE_NUM-1:0]
        lane_any_winner [0:LEVEL-1];
    reg [LOGICAL_TREE_NUM-1:0]
        lane_pp_select [0:LEVEL-1];
    reg [LOGICAL_TREE_NUM-1:0]
        lane_push_select [0:LEVEL-1];
    reg [LOGICAL_TREE_NUM-1:0]
        lane_pop_select [0:LEVEL-1];

    genvar logical_wire;
    generate
        for (logical_wire = 0;
             logical_wire < LOGICAL_TREE_NUM;
             logical_wire = logical_wire + 1) begin :
             dispatch_metadata
            assign directory_logical_tree_id[logical_wire] =
                logical_wire[LOGICAL_ID_WIDTH-1:0];
            assign o_dispatch_logical_tree_id[logical_wire] =
                logical_wire[LOGICAL_ID_WIDTH-1:0];
            assign o_dispatch_push[logical_wire] =
                candidate_push[logical_wire];
            assign o_dispatch_data[logical_wire] =
                candidate_push_data[logical_wire];
            assign o_dispatch_source_port[logical_wire] =
                candidate_source_port[logical_wire];
        end
    endgenerate

    LogicalRequestBuffer #(
        .DATA_WIDTH(MTW+PTW),
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .REQUEST_PORTS(REQUEST_PORTS),
        .ORDER_WIDTH(TASK_ORDER_WIDTH),
        .DEPTH(LOGICAL_PENDING_DEPTH),
        .NATIVE_COMPOUND_REQUESTS(NATIVE_COMPOUND_REQUESTS)
    ) logical_pending (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_req_valid(i_req_valid),
        .i_req_push(i_req_push),
        .i_req_pop(i_req_pop),
        .i_logical_tree_id(i_logical_tree_id),
        .i_push_data(i_push_data),
        .i_req_order(i_req_order),
        .i_req_merge_mask(i_req_merge_mask),
        .o_req_ready(o_req_capture_ready),
        .o_req_capture_fire(o_req_capture_fire),
        .o_req_bad_id(o_req_capture_bad_id),
        .i_retire_valid(dispatch_retire_valid),
        .i_retire_primary_slot_id(candidate_slot_id),
        .i_retire_partner_valid(
            dispatch_retire_partner_valid),
        .i_retire_partner_slot_id(
            candidate_partner_slot_id),
        .o_head_valid(pending_head_valid),
        .o_head_push(pending_head_push),
        .o_head_pop(pending_head_pop),
        .o_head_push_data(pending_head_push_data),
        .o_head_order(pending_head_order),
        .o_head_source_port(pending_head_source_port),
        .o_head_slot_id(pending_head_slot_id),
        .o_head_merge_slots(pending_head_merge_slots),
        .o_head_pair_older(),
        .o_head_pair_same_event(),
        .o_head_first_older(pending_head_first_older),
        .o_head_pair_same_event_state(
            pending_head_pair_same_event_state),
        .i_partner_resolve_valid(candidate_partner_resolving),
        .i_partner_resolve_primary_push(candidate_push),
        .i_partner_resolve_primary_slot_id(candidate_slot_id),
        .i_partner_resolve_primary_merge_slots(
            candidate_merge_slots),
        .o_partner_resolve_valid(
            pending_partner_resolve_valid),
        .o_partner_resolve_slot_id(
            pending_partner_resolve_slot_id),
        .o_logical_pending_count(o_logical_pending_count),
        .o_pending_count(o_pending_count),
        .o_effective_free_count(o_pending_effective_free_count),
        .o_full(pending_buffer_full),
        .o_slot_older(),
        .o_protocol_error(pending_buffer_protocol_error)
    );

    integer candidate_logical;
    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            candidate_primary_valid <=
                {LOGICAL_TREE_NUM{1'b0}};
            candidate_partner_resolving <=
                {LOGICAL_TREE_NUM{1'b0}};
            candidate_dispatch_ready <=
                {LOGICAL_TREE_NUM{1'b0}};
            candidate_push <= {LOGICAL_TREE_NUM{1'b0}};
            candidate_pop <= {LOGICAL_TREE_NUM{1'b0}};
            candidate_partner_valid <=
                {LOGICAL_TREE_NUM{1'b0}};
            candidate_refill_block <=
                {LOGICAL_TREE_NUM{1'b0}};
            for (candidate_logical = 0;
                 candidate_logical < LOGICAL_TREE_NUM;
                 candidate_logical = candidate_logical + 1) begin
                candidate_push_data[candidate_logical] <=
                    {(MTW+PTW){1'b0}};
                candidate_source_port[candidate_logical] <=
                    {SOURCE_PORT_WIDTH{1'b0}};
                candidate_slot_id[candidate_logical] <=
                    {PENDING_SLOT_WIDTH{1'b0}};
                candidate_partner_slot_id[
                    candidate_logical] <=
                    {PENDING_SLOT_WIDTH{1'b0}};
                candidate_merge_slots[candidate_logical] <=
                    {LOGICAL_PENDING_DEPTH{1'b0}};
            end
        end else begin
            for (candidate_logical = 0;
                 candidate_logical < LOGICAL_TREE_NUM;
                 candidate_logical = candidate_logical + 1) begin
                if (native_pp_fallback_fire[candidate_logical]) begin
                    // Directory could not execute Push and Pop on one shard
                    // (the current Head shard was full), so it dispatched
                    // only the Push to a free shard.  Keep this one logical
                    // descriptor live and expose its residual Pop after the
                    // Directory busy interval completes.
                    candidate_push[candidate_logical] <= 1'b0;
                    candidate_pop[candidate_logical] <= 1'b1;
                    candidate_partner_valid[candidate_logical] <= 1'b0;
                end else if (o_dispatch_fire[candidate_logical]) begin
                    candidate_primary_valid[
                        candidate_logical] <= 1'b0;
                    candidate_partner_resolving[
                        candidate_logical] <= 1'b0;
                    candidate_dispatch_ready[
                        candidate_logical] <= 1'b0;
                    candidate_partner_valid[
                        candidate_logical] <= 1'b0;
                    candidate_refill_block[candidate_logical] <=
                        1'b1;
                end else begin
                    if (candidate_refill_block[candidate_logical])
                        candidate_refill_block[
                            candidate_logical] <= 1'b0;

                    // The one-cycle block after dispatch covers the cycle in
                    // which LogicalRequestBuffer commits its registered
                    // retirement mask.  A later candidate may be prepared
                    // while the logical PIFO is still busy in the RPU.
                    if ((NATIVE_COMPOUND_REQUESTS == 0) &&
                        candidate_partner_resolving[
                            candidate_logical]) begin
                        // Partner resolution consumes only the registered
                        // primary description.  Whether a partner is found or
                        // not, the result is captured exactly once and the
                        // candidate becomes dispatch-ready on this edge.
                        candidate_partner_valid[
                            candidate_logical] <=
                            pending_partner_resolve_valid[
                                candidate_logical];
                        candidate_partner_slot_id[
                            candidate_logical] <=
                            pending_partner_resolve_slot_id[
                                candidate_logical];
                        candidate_partner_resolving[
                            candidate_logical] <= 1'b0;
                        candidate_dispatch_ready[
                            candidate_logical] <= 1'b1;
                    end else if (!candidate_primary_valid[
                                     candidate_logical] &&
                        !candidate_refill_block[
                            candidate_logical] &&
                        pending_head_valid[candidate_logical]) begin
                        candidate_primary_valid[
                            candidate_logical] <= 1'b1;
                        candidate_push[candidate_logical] <=
                            pending_head_push[candidate_logical];
                        candidate_pop[candidate_logical] <=
                            pending_head_pop[candidate_logical];
                        candidate_push_data[candidate_logical] <=
                            pending_head_push_data[
                                candidate_logical];
                        candidate_source_port[candidate_logical] <=
                            pending_head_source_port[
                                candidate_logical];
                        candidate_slot_id[candidate_logical] <=
                            pending_head_slot_id[
                                candidate_logical];
                        candidate_merge_slots[
                            candidate_logical] <=
                            pending_head_merge_slots[
                                candidate_logical];
                        candidate_partner_valid[
                            candidate_logical] <= 1'b0;
                        candidate_partner_slot_id[
                            candidate_logical] <=
                            {PENDING_SLOT_WIDTH{1'b0}};
                        if (NATIVE_COMPOUND_REQUESTS != 0) begin
                            candidate_partner_resolving[
                                candidate_logical] <= 1'b0;
                            candidate_partner_valid[
                                candidate_logical] <=
                                pending_head_push[candidate_logical] &&
                                pending_head_pop[candidate_logical];
                            candidate_dispatch_ready[
                                candidate_logical] <= 1'b1;
                        end else if (|pending_head_merge_slots[
                                candidate_logical]) begin
                            candidate_partner_resolving[
                                candidate_logical] <= 1'b1;
                            candidate_dispatch_ready[
                                candidate_logical] <= 1'b0;
                        end else begin
                            // No provenance edge means that a reciprocal
                            // partner cannot exist.  Ordinary requests become
                            // ready directly after primary fill without an
                            // unnecessary resolution cycle.
                            candidate_partner_resolving[
                                candidate_logical] <= 1'b0;
                            candidate_dispatch_ready[
                                candidate_logical] <= 1'b1;
                        end
                    end
                end
            end
        end
    end

    integer relation_logical;
    always @* begin
        candidate_primary_fill = {LOGICAL_TREE_NUM{1'b0}};
        relation_candidate_present = {LOGICAL_TREE_NUM{1'b0}};
        if (NATIVE_COMPOUND_REQUESTS == 0) begin
            for (relation_logical = 0;
                 relation_logical < LOGICAL_TREE_NUM;
                 relation_logical = relation_logical + 1) begin
                candidate_primary_fill[relation_logical] =
                    !candidate_primary_valid[relation_logical] &&
                    !candidate_refill_block[relation_logical] &&
                    pending_head_valid[relation_logical];
                relation_candidate_present[relation_logical] =
                    candidate_primary_valid[relation_logical] ||
                    candidate_primary_fill[relation_logical];
            end
        end
    end

    integer relation_source_logical;
    integer relation_target_logical;
    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            candidate_first_older <=
                {CANDIDATE_PAIR_STORAGE_WIDTH{1'b0}};
            candidate_pair_same_event_state <=
                {CANDIDATE_PAIR_STORAGE_WIDTH{1'b0}};
        end else if (NATIVE_COMPOUND_REQUESTS == 0) begin
            for (relation_source_logical = 0;
                 relation_source_logical < LOGICAL_TREE_NUM;
                 relation_source_logical =
                     relation_source_logical + 1) begin
                for (relation_target_logical =
                         relation_source_logical + 1;
                     relation_target_logical < LOGICAL_TREE_NUM;
                     relation_target_logical =
                         relation_target_logical + 1) begin
                    if (relation_candidate_present[
                            relation_source_logical] &&
                        relation_candidate_present[
                            relation_target_logical] &&
                        (candidate_primary_fill[
                             relation_source_logical] ||
                         candidate_primary_fill[
                             relation_target_logical])) begin
                        candidate_first_older[
                            candidate_pair_index(
                                relation_source_logical,
                                relation_target_logical)] <=
                            pending_head_first_older[
                                candidate_pair_index(
                                    relation_source_logical,
                                    relation_target_logical)];
                        candidate_pair_same_event_state[
                            candidate_pair_index(
                                relation_source_logical,
                                relation_target_logical)] <=
                            pending_head_pair_same_event_state[
                                candidate_pair_index(
                                    relation_source_logical,
                                    relation_target_logical)];
                    end
                end
            end
        end else begin
            candidate_first_older <=
                {CANDIDATE_PAIR_STORAGE_WIDTH{1'b0}};
            candidate_pair_same_event_state <=
                {CANDIDATE_PAIR_STORAGE_WIDTH{1'b0}};
        end
    end

    // Lane arbitration follows two compile-time control contracts.  Legacy
    // half requests retain exact global-oldest and reciprocal-event ordering.
    // Native complete operations match the public vPIFO control strictness:
    // FIFO order is kept within each logical queue, while independent logical
    // queues use a deterministic fixed scan on their selected Engine lane.
    always @* begin
        directory_select_ready = {LOGICAL_TREE_NUM{1'b0}};
        engine_push_reg = {LEVEL{1'b0}};
        engine_pop_reg = {LEVEL{1'b0}};

        for (arbitration_lane = 0; arbitration_lane < LEVEL;
             arbitration_lane = arbitration_lane + 1) begin
            lane_pp_candidate[arbitration_lane] =
                {LOGICAL_TREE_NUM{1'b0}};
            lane_push_candidate[arbitration_lane] =
                {LOGICAL_TREE_NUM{1'b0}};
            lane_pop_candidate[arbitration_lane] =
                {LOGICAL_TREE_NUM{1'b0}};
            lane_any_candidate[arbitration_lane] =
                {LOGICAL_TREE_NUM{1'b0}};
            lane_pp_winner[arbitration_lane] =
                {LOGICAL_TREE_NUM{1'b0}};
            lane_push_winner[arbitration_lane] =
                {LOGICAL_TREE_NUM{1'b0}};
            lane_pop_winner[arbitration_lane] =
                {LOGICAL_TREE_NUM{1'b0}};
            lane_any_winner[arbitration_lane] =
                {LOGICAL_TREE_NUM{1'b0}};
            lane_pp_select[arbitration_lane] =
                {LOGICAL_TREE_NUM{1'b0}};
            lane_push_select[arbitration_lane] =
                {LOGICAL_TREE_NUM{1'b0}};
            lane_pop_select[arbitration_lane] =
                {LOGICAL_TREE_NUM{1'b0}};
            engine_push_tree_id[arbitration_lane] =
                {PHYSICAL_ID_WIDTH{1'b0}};
            engine_pop_tree_id[arbitration_lane] =
                {PHYSICAL_ID_WIDTH{1'b0}};
            engine_push_data[arbitration_lane] =
                {(MTW+PTW){1'b1}};
        end

        for (arbitration_lane = 0; arbitration_lane < LEVEL;
             arbitration_lane = arbitration_lane + 1) begin
            for (arbitration_logical = 0;
                 arbitration_logical < LOGICAL_TREE_NUM;
                 arbitration_logical = arbitration_logical + 1) begin
                if (directory_select_valid[arbitration_logical] &&
                    ((int'(directory_physical_tree_id[
                          arbitration_logical]) % LEVEL) ==
                     arbitration_lane)) begin
                    lane_pp_candidate[arbitration_lane]
                        [arbitration_logical] =
                            directory_select_pp[arbitration_logical];
                    lane_push_candidate[arbitration_lane]
                        [arbitration_logical] =
                            !directory_select_pp[arbitration_logical] &&
                            candidate_push[arbitration_logical];
                    lane_pop_candidate[arbitration_lane]
                        [arbitration_logical] =
                            !directory_select_pp[arbitration_logical] &&
                            candidate_pop[arbitration_logical] &&
                            !candidate_push[arbitration_logical];
                    lane_any_candidate[arbitration_lane]
                        [arbitration_logical] = 1'b1;
                end
            end

            if (NATIVE_COMPOUND_REQUESTS != 0) begin
                // Lowest logical ID wins among currently dispatchable heads on
                // one lane.  Each proof depends only on lower IDs, so there is
                // no candidate age state and no cross-logical route from LRB.
                for (arbitration_logical = 0;
                     arbitration_logical < LOGICAL_TREE_NUM;
                     arbitration_logical = arbitration_logical + 1) begin
                    lane_any_winner[arbitration_lane]
                        [arbitration_logical] =
                            lane_any_candidate[arbitration_lane]
                                [arbitration_logical];
                    for (arbitration_other_logical = 0;
                         arbitration_other_logical < arbitration_logical;
                         arbitration_other_logical =
                             arbitration_other_logical + 1)
                        if (lane_any_candidate[arbitration_lane]
                                              [arbitration_other_logical])
                            lane_any_winner[arbitration_lane]
                                           [arbitration_logical] = 1'b0;
                end
            end else begin
                // Parallel exact-age proofs for the legacy half-request path.
                // Class winners are also needed to co-issue only reciprocal
                // Push/Pop members of one captured event.
                for (arbitration_logical = 0;
                     arbitration_logical < LOGICAL_TREE_NUM;
                     arbitration_logical = arbitration_logical + 1) begin
                    lane_pp_winner[arbitration_lane]
                        [arbitration_logical] =
                            lane_pp_candidate[arbitration_lane]
                                [arbitration_logical];
                    lane_push_winner[arbitration_lane]
                        [arbitration_logical] =
                            lane_push_candidate[arbitration_lane]
                                [arbitration_logical];
                    lane_pop_winner[arbitration_lane]
                        [arbitration_logical] =
                            lane_pop_candidate[arbitration_lane]
                                [arbitration_logical];
                    lane_any_winner[arbitration_lane]
                        [arbitration_logical] =
                            lane_any_candidate[arbitration_lane]
                                [arbitration_logical];
                    for (arbitration_other_logical = 0;
                         arbitration_other_logical < LOGICAL_TREE_NUM;
                         arbitration_other_logical =
                             arbitration_other_logical + 1) begin
                        if (arbitration_other_logical !=
                            arbitration_logical) begin
                            if (lane_pp_candidate[arbitration_lane]
                                    [arbitration_other_logical] &&
                                !candidate_pair_older[
                                    arbitration_logical]
                                    [arbitration_other_logical])
                                lane_pp_winner[arbitration_lane]
                                    [arbitration_logical] = 1'b0;
                            if (lane_push_candidate[arbitration_lane]
                                    [arbitration_other_logical] &&
                                !candidate_pair_older[
                                    arbitration_logical]
                                    [arbitration_other_logical])
                                lane_push_winner[arbitration_lane]
                                    [arbitration_logical] = 1'b0;
                            if (lane_pop_candidate[arbitration_lane]
                                    [arbitration_other_logical] &&
                                !candidate_pair_older[
                                    arbitration_logical]
                                    [arbitration_other_logical])
                                lane_pop_winner[arbitration_lane]
                                    [arbitration_logical] = 1'b0;
                            if (lane_any_candidate[arbitration_lane]
                                    [arbitration_other_logical] &&
                                !candidate_pair_older[
                                    arbitration_logical]
                                    [arbitration_other_logical])
                                lane_any_winner[arbitration_lane]
                                    [arbitration_logical] = 1'b0;
                        end
                    end
                end
            end

            // Selecting the global oldest candidate removes the second
            // serial cross-class oldest comparison from the dispatch path.
            // If that winner is an ordinary Push or Pop, the oldest opposite
            // class request may co-issue only when both came from the same
            // captured event.  This is equivalent to the previous three-class
            // selection rule while keeping P/P atomicity and request order.
            for (arbitration_logical = 0;
                 arbitration_logical < LOGICAL_TREE_NUM;
                 arbitration_logical = arbitration_logical + 1) begin
                lane_pp_select[arbitration_lane]
                    [arbitration_logical] =
                        lane_any_winner[arbitration_lane]
                            [arbitration_logical] &&
                        lane_pp_candidate[arbitration_lane]
                            [arbitration_logical];
                if (NATIVE_COMPOUND_REQUESTS != 0) begin
                    lane_push_select[arbitration_lane]
                        [arbitration_logical] =
                            lane_any_winner[arbitration_lane]
                                [arbitration_logical] &&
                            lane_push_candidate[arbitration_lane]
                                [arbitration_logical];
                    lane_pop_select[arbitration_lane]
                        [arbitration_logical] =
                            lane_any_winner[arbitration_lane]
                                [arbitration_logical] &&
                            lane_pop_candidate[arbitration_lane]
                                [arbitration_logical];
                end else begin
                    lane_push_select[arbitration_lane]
                        [arbitration_logical] =
                            (lane_any_winner[arbitration_lane]
                                 [arbitration_logical] &&
                             lane_push_candidate[arbitration_lane]
                                 [arbitration_logical]) ||
                            (lane_push_winner[arbitration_lane]
                                 [arbitration_logical] &&
                             (|(candidate_pair_same_event[
                                    arbitration_logical] &
                                lane_any_winner[arbitration_lane] &
                                lane_pop_candidate[arbitration_lane])));
                    lane_pop_select[arbitration_lane]
                        [arbitration_logical] =
                            (lane_any_winner[arbitration_lane]
                                 [arbitration_logical] &&
                             lane_pop_candidate[arbitration_lane]
                                 [arbitration_logical]) ||
                            (lane_pop_winner[arbitration_lane]
                                 [arbitration_logical] &&
                             (|(candidate_pair_same_event[
                                    arbitration_logical] &
                                lane_any_winner[arbitration_lane] &
                                lane_push_candidate[arbitration_lane])));
                end
            end

            if (!engine_task_fifo_full[arbitration_lane]) begin
                directory_select_ready = directory_select_ready |
                    lane_pp_select[arbitration_lane] |
                    lane_push_select[arbitration_lane] |
                    lane_pop_select[arbitration_lane];
                engine_push_reg[arbitration_lane] =
                    (|lane_pp_select[arbitration_lane]) ||
                    (|lane_push_select[arbitration_lane]);
                engine_pop_reg[arbitration_lane] =
                    (|lane_pp_select[arbitration_lane]) ||
                    (|lane_pop_select[arbitration_lane]);

                for (arbitration_logical = 0;
                     arbitration_logical < LOGICAL_TREE_NUM;
                     arbitration_logical = arbitration_logical + 1) begin
                    if (lane_pp_select[arbitration_lane]
                            [arbitration_logical] ||
                        lane_push_select[arbitration_lane]
                            [arbitration_logical]) begin
                        engine_push_tree_id[arbitration_lane] =
                            engine_push_tree_id[arbitration_lane] |
                            directory_physical_tree_id[
                                arbitration_logical];
                        engine_push_data[arbitration_lane] =
                            candidate_push_data[
                                arbitration_logical];
                    end
                    if (lane_pp_select[arbitration_lane]
                            [arbitration_logical] ||
                        lane_pop_select[arbitration_lane]
                            [arbitration_logical])
                        engine_pop_tree_id[arbitration_lane] =
                            engine_pop_tree_id[arbitration_lane] |
                            directory_physical_tree_id[
                                arbitration_logical];
                end
            end
        end
    end

    assign engine_push = engine_push_reg;
    assign engine_pop = engine_pop_reg;
    assign o_dispatch_fire =
        directory_select_valid & directory_select_ready;
    assign native_pp_fallback_fire =
        (NATIVE_COMPOUND_REQUESTS != 0) ?
            (o_dispatch_fire & candidate_push & candidate_pop &
             ~directory_select_pp) :
            {LOGICAL_TREE_NUM{1'b0}};
    assign dispatch_retire_valid =
        o_dispatch_fire & ~native_pp_fallback_fire;
    assign dispatch_retire_partner_valid =
        (NATIVE_COMPOUND_REQUESTS == 0) ?
            (o_dispatch_fire & directory_select_pp &
             candidate_partner_valid) :
            {LOGICAL_TREE_NUM{1'b0}};
    assign o_selected_physical_tree_id =
        directory_physical_tree_id;

    reg [LEVEL-1:0] pop_fifo_enqueue_valid;
    wire [(MTW+PTW)-1:0] pop_fifo_enqueue_data [0:LEVEL-1];
    reg [LOGICAL_ID_WIDTH-1:0]
        pop_fifo_enqueue_logical_id [0:LEVEL-1];
    reg internal_root_pop_valid_reg;
    reg [(MTW+PTW)-1:0] internal_root_pop_data_reg;
    reg pop_context_protocol_error;
    reg engine_protocol_error;
    integer pop_lane;
    reg [PHYSICAL_ID_WIDTH-1:0] pop_physical_id;

    // The old root Head appears one cycle before Pop completion clears the
    // directory context.  Capture the logical owner on that live context.
    always @* begin
        pop_fifo_enqueue_valid = {LEVEL{1'b0}};
        internal_root_pop_valid_reg = 1'b0;
        internal_root_pop_data_reg = {(MTW+PTW){1'b1}};
        pop_context_protocol_error = 1'b0;
        pop_physical_id = {PHYSICAL_ID_WIDTH{1'b0}};
        for (pop_lane = 0; pop_lane < LEVEL;
             pop_lane = pop_lane + 1) begin
            pop_fifo_enqueue_logical_id[pop_lane] =
                {LOGICAL_ID_WIDTH{1'b0}};
            if (engine_is_level0_pop[pop_lane]) begin
                pop_physical_id = engine_tree_id[pop_lane];
                if (pop_physical_id >= PHYSICAL_TREE_NUM) begin
                    pop_context_protocol_error = 1'b1;
                end else if (!o_update_pending[pop_physical_id] ||
                             o_pending_push[pop_physical_id]) begin
                    pop_context_protocol_error = 1'b1;
                end else if ((HIERARCHICAL_MODE != 0) &&
                             (o_pending_logical_tree_id[
                                  pop_physical_id] ==
                              {LOGICAL_ID_WIDTH{1'b0}})) begin
                    if (internal_root_pop_valid_reg) begin
                        pop_context_protocol_error = 1'b1;
                    end else begin
                        internal_root_pop_valid_reg = 1'b1;
                        internal_root_pop_data_reg =
                            engine_pop_data[pop_lane];
                    end
                end else begin
                    pop_fifo_enqueue_valid[pop_lane] = 1'b1;
                    pop_fifo_enqueue_logical_id[pop_lane] =
                        o_pending_logical_tree_id[pop_physical_id];
                end
            end
        end
    end

    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n)
            engine_protocol_error <= 1'b0;
        else if (pop_context_protocol_error)
            engine_protocol_error <= 1'b1;
    end

    genvar lane;
    generate
        for (lane = 0; lane < LEVEL; lane = lane + 1) begin :
            pop_fifo_data_route
            assign pop_fifo_enqueue_data[lane] =
                engine_pop_data[lane];
        end
    endgenerate

    wire pop_fifo_overflow;
    generate
        if (SINGLE_POP_RETURN != 0) begin : GEN_SINGLE_POP_RETURN
            reg pop_valid_reg;
            reg [(MTW+PTW)-1:0] pop_data_reg;
            reg [LOGICAL_ID_WIDTH-1:0] pop_logical_id_reg;
            reg holding_valid_reg;
            reg [(MTW+PTW)-1:0] holding_data_reg;
            reg [LOGICAL_ID_WIDTH-1:0] holding_logical_id_reg;
            reg pop_return_error_reg;
            integer single_pop_lane;
            integer single_pop_count;

            always @(posedge i_clk or negedge i_arst_n) begin
                if (!i_arst_n) begin
                    pop_valid_reg <= 1'b0;
                    pop_data_reg <= {(MTW+PTW){1'b1}};
                    pop_logical_id_reg <= {LOGICAL_ID_WIDTH{1'b0}};
                    holding_valid_reg <= 1'b0;
                    holding_data_reg <= {(MTW+PTW){1'b1}};
                    holding_logical_id_reg <=
                        {LOGICAL_ID_WIDTH{1'b0}};
                    pop_return_error_reg <= 1'b0;
                end else begin
                    // Match the generic FIFO's no-fall-through latency: an
                    // Engine return is captured here, then becomes visible on
                    // the following edge.  The wrapper always consumes the
                    // one-cycle output pulse.
                    pop_valid_reg <= holding_valid_reg;
                    if (holding_valid_reg) begin
                        pop_data_reg <= holding_data_reg;
                        pop_logical_id_reg <= holding_logical_id_reg;
                    end
                    holding_valid_reg <= 1'b0;
                    single_pop_count = 0;
                    for (single_pop_lane = 0;
                         single_pop_lane < LEVEL;
                         single_pop_lane = single_pop_lane + 1) begin
                        if (pop_fifo_enqueue_valid[single_pop_lane]) begin
                            single_pop_count = single_pop_count + 1;
                            if (single_pop_count == 1) begin
                                holding_valid_reg <= 1'b1;
                                holding_data_reg <=
                                    pop_fifo_enqueue_data[single_pop_lane];
                                holding_logical_id_reg <=
                                    pop_fifo_enqueue_logical_id[
                                        single_pop_lane];
                            end
                        end
                    end
                    if (single_pop_count > 1)
                        pop_return_error_reg <= 1'b1;
                end
            end

            assign o_pop_valid = pop_valid_reg;
            assign o_pop_data = pop_data_reg;
            assign o_pop_logical_tree_id = pop_logical_id_reg;
            assign pop_fifo_overflow = pop_return_error_reg;
        end else begin : GEN_GENERIC_POP_RETURN
            wire [POP_FIFO_COUNT_WIDTH-1:0] pop_result_count;
            wire [POP_FIFO_PTR_WIDTH-1:0] pop_result_head_ptr;
            wire [POP_FIFO_PTR_WIDTH-1:0] pop_result_tail_ptr;
            wire [POP_FIFO_ENQUEUE_COUNT_WIDTH-1:0]
                pop_fifo_enqueued_count;
            wire pop_fifo_dequeued;
            wire pop_fifo_head_wrapped;
            wire pop_fifo_tail_wrapped;

            PopResultFIFO #(
                .DATA_WIDTH(MTW+PTW),
                .LOGICAL_ID_WIDTH(LOGICAL_ID_WIDTH),
                .ENQUEUE_PORTS(LEVEL),
                .DEPTH(POP_RESULT_FIFO_DEPTH)
            ) pop_result_fifo (
                .i_clk(i_clk),
                .i_arst_n(i_arst_n),
                .i_enqueue_valid(pop_fifo_enqueue_valid),
                .i_enqueue_data(pop_fifo_enqueue_data),
                .i_enqueue_logical_id(pop_fifo_enqueue_logical_id),
                .i_dequeue_ready(1'b1),
                .o_dequeue_valid(o_pop_valid),
                .o_dequeue_data(o_pop_data),
                .o_dequeue_logical_id(o_pop_logical_tree_id),
                .o_overflow(pop_fifo_overflow),
                .o_count(pop_result_count),
                .o_head_ptr(pop_result_head_ptr),
                .o_tail_ptr(pop_result_tail_ptr),
                .o_enqueued_count(pop_fifo_enqueued_count),
                .o_dequeued(pop_fifo_dequeued),
                .o_head_wrapped(pop_fifo_head_wrapped),
                .o_tail_wrapped(pop_fifo_tail_wrapped)
            );
        end
    endgenerate

    ShardDirectory #(
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(PHYSICAL_TREE_NUM),
        .SHARD_CAPACITY(SHARD_CAPACITY),
        .RANK_WIDTH(PTW),
        .MAX_SHARDS_PER_LOGICAL(MAX_SHARDS_PER_LOGICAL),
        .REQUEST_PORTS(LOGICAL_TREE_NUM),
        .UPDATE_PORTS(LEVEL),
        .FIXED_LOGICAL_PORTS(DIRECTORY_FIXED_LOGICAL_PORTS),
        .FIXED_RPU_UPDATE_PORTS(DIRECTORY_FIXED_RPU_UPDATE_PORTS),
        .DERIVE_LOGICAL_COUNT(DIRECTORY_DERIVE_LOGICAL_COUNT),
        .COMPLETION_PROJECTED_HEAD_CACHE(
            DIRECTORY_COMPLETION_PROJECTED_HEAD_CACHE),
        .USE_EXPLICIT_SHARD_MAP(USE_EXPLICIT_SHARD_MAP),
        .SHARD_COUNTS(SHARD_COUNTS),
        .SHARD_OFFSETS(SHARD_OFFSETS),
        .EXPLICIT_SHARD_MAP(EXPLICIT_SHARD_MAP)
    ) directory (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_req_valid(candidate_valid),
        .i_req_push(candidate_push),
        .i_req_pp((NATIVE_COMPOUND_REQUESTS != 0) ?
                  (candidate_push & candidate_pop) :
                  candidate_partner_valid),
        .i_logical_tree_id(directory_logical_tree_id),
        .i_select_ready(directory_select_ready),
        .o_req_ready(),
        .o_select_valid(directory_select_valid),
        .o_select_pp(directory_select_pp),
        .o_physical_tree_id(directory_physical_tree_id),
        .o_reject_empty(o_dispatch_reject_empty),
        .o_reject_full(o_dispatch_reject_full),
        .o_reject_bad_id(directory_reject_bad_id),
        .i_update_valid(engine_root_update_valid),
        .i_update_physical_tree_id(engine_tree_id),
        .i_update_head_rank(engine_root_update_head_rank),
        .o_busy(directory_busy),
        .o_protocol_error(directory_protocol_error),
        .o_shard_list(o_shard_list),
        .o_logical_shard_count(o_logical_shard_count),
        .o_logical_count(o_logical_count),
        .o_push_rr_ptr(o_push_rr_ptr),
        .o_logical_busy(o_logical_busy),
        .o_shard_count(o_shard_count),
        .o_shard_head_rank(o_shard_head_rank),
        .o_shard_empty(o_shard_empty),
        .o_shard_full(o_shard_full),
        .o_shard_head_valid(o_shard_head_valid),
        .o_update_pending(o_update_pending),
        .o_pending_logical_tree_id(
            o_pending_logical_tree_id),
        .o_pending_push(o_pending_push),
        .o_pending_pp()
    );

    PIFO_SRAM_TOP #(
        .PTW(PTW),
        .MTW(MTW),
        .CTW(CTW),
        .LEVEL(LEVEL),
        .TREE_NUM(PHYSICAL_TREE_NUM),
        .FIFO_SIZE(FIFO_SIZE),
        // Lane arbitration asserts engine_push/engine_pop only when the
        // corresponding TaskFIFO is not full, so its write-enable is already
        // an accepted transaction.  Avoid repeating that full/read guard on
        // every distributed-RAM WE endpoint.
        .TASKFIFO_WRITE_ENABLE_IS_ACCEPTED(1)
    ) engine (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_push_tree_id(engine_push_tree_id),
        .i_push(engine_push),
        .i_push_data(engine_push_data),
        .i_pop(engine_pop),
        .i_pop_tree_id(engine_pop_tree_id),
        .o_tree_id(engine_tree_id),
        .o_pop_data(engine_pop_data),
        .o_is_level0_pop(engine_is_level0_pop),
        .o_root_update_valid(engine_root_update_valid),
        .o_root_update_head_rank(engine_root_update_head_rank),
        .o_task_fifo_full(engine_task_fifo_full)
    );

    assign o_internal_root_pop_valid =
        internal_root_pop_valid_reg;
    assign o_internal_root_pop_data =
        internal_root_pop_data_reg;
    assign o_task_fifo_full = engine_task_fifo_full;
    assign o_task_push = engine_push;
    assign o_task_pop = engine_pop;
    assign o_task_write = engine_push | engine_pop;
    assign o_busy = directory_busy ||
                    (o_pending_count != {PENDING_COUNT_WIDTH{1'b0}});
    assign o_protocol_error =
        directory_protocol_error | engine_protocol_error |
        pending_buffer_protocol_error | pop_fifo_overflow |
        (|directory_reject_bad_id);

endmodule
