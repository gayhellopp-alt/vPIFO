`timescale 1ns / 10ps

// Shared logical-request pending pool.
//
// Capture and physical dispatch are deliberately separate:
//   * capture_fire means that a complete allocation plan now owns a reserved
//     slot for the request;
//   * the registered plan commits its descriptors and matrix relations on the
//     following edge, when the reserved slot becomes a visible valid slot;
//   * i_retire_valid means that a previously registered candidate was
//     actually written into an original physical TaskFIFO.  Its registered
//     primary/partner slot IDs are converted directly to a retire mask on
//     that edge and retired from the pool one cycle later.
//
// The pool is associative by logical ID.  Consequently a busy logical PIFO
// does not create head-of-line blocking for unrelated logical PIFOs.  The age
// matrix records exact capture order and does not depend on a wrapping order
// tag.  A same-generation merge relationship is likewise stored as a relation
// between concrete live slots, so unrelated requests can never become a P/P
// word merely because their finite order tags happen to match.
module LogicalRequestBuffer #(
    parameter DATA_WIDTH = 32,
    parameter LOGICAL_TREE_NUM = 4,
    parameter REQUEST_PORTS = 4,
    parameter ORDER_WIDTH = 32,
    parameter DEPTH = 16,
    parameter integer NATIVE_COMPOUND_REQUESTS = 0,

    localparam LOGICAL_ID_WIDTH = (LOGICAL_TREE_NUM <= 1) ? 1 :
                                  $clog2(LOGICAL_TREE_NUM),
    localparam SOURCE_PORT_WIDTH = (REQUEST_PORTS <= 1) ? 1 :
                                   $clog2(REQUEST_PORTS),
    localparam SLOT_ID_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    localparam COUNT_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH + 1),
    localparam HEAD_PAIR_COUNT =
        (LOGICAL_TREE_NUM * (LOGICAL_TREE_NUM - 1)) / 2,
    localparam HEAD_PAIR_STORAGE_WIDTH =
        (HEAD_PAIR_COUNT <= 0) ? 1 : HEAD_PAIR_COUNT
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,

    input  wire [REQUEST_PORTS-1:0]     i_req_valid,
    input  wire [REQUEST_PORTS-1:0]     i_req_push,
    input  wire [REQUEST_PORTS-1:0]     i_req_pop,
    input  wire [LOGICAL_ID_WIDTH-1:0]  i_logical_tree_id [0:REQUEST_PORTS-1],
    input  wire [DATA_WIDTH-1:0]        i_push_data [0:REQUEST_PORTS-1],
    input  wire [ORDER_WIDTH-1:0]       i_req_order [0:REQUEST_PORTS-1],
    input  wire [REQUEST_PORTS-1:0]     i_req_merge_mask [0:REQUEST_PORTS-1],

    output reg  [REQUEST_PORTS-1:0]     o_req_ready,
    output reg  [REQUEST_PORTS-1:0]     o_req_capture_fire,
    output reg  [REQUEST_PORTS-1:0]     o_req_bad_id,

    input  wire [LOGICAL_TREE_NUM-1:0]  i_retire_valid,
    input  wire [SLOT_ID_WIDTH-1:0]     i_retire_primary_slot_id [0:LOGICAL_TREE_NUM-1],
    input  wire [LOGICAL_TREE_NUM-1:0]  i_retire_partner_valid,
    input  wire [SLOT_ID_WIDTH-1:0]     i_retire_partner_slot_id [0:LOGICAL_TREE_NUM-1],
    output reg  [LOGICAL_TREE_NUM-1:0]  o_head_valid,
    output reg  [LOGICAL_TREE_NUM-1:0]  o_head_push,
    output reg  [LOGICAL_TREE_NUM-1:0]  o_head_pop,
    output reg  [DATA_WIDTH-1:0]        o_head_push_data [0:LOGICAL_TREE_NUM-1],
    output reg  [ORDER_WIDTH-1:0]       o_head_order [0:LOGICAL_TREE_NUM-1],
    output reg  [SOURCE_PORT_WIDTH-1:0] o_head_source_port [0:LOGICAL_TREE_NUM-1],
    output reg  [SLOT_ID_WIDTH-1:0]     o_head_slot_id [0:LOGICAL_TREE_NUM-1],
    output reg  [DEPTH-1:0]             o_head_merge_slots [0:LOGICAL_TREE_NUM-1],
    output reg  [LOGICAL_TREE_NUM-1:0]  o_head_pair_older [0:LOGICAL_TREE_NUM-1],
    output reg  [LOGICAL_TREE_NUM-1:0]  o_head_pair_same_event [0:LOGICAL_TREE_NUM-1],
    output reg  [HEAD_PAIR_STORAGE_WIDTH-1:0] o_head_first_older,
    output reg  [HEAD_PAIR_STORAGE_WIDTH-1:0] o_head_pair_same_event_state,
    input  wire [LOGICAL_TREE_NUM-1:0]  i_partner_resolve_valid,
    input  wire [LOGICAL_TREE_NUM-1:0]  i_partner_resolve_primary_push,
    input  wire [SLOT_ID_WIDTH-1:0]     i_partner_resolve_primary_slot_id [0:LOGICAL_TREE_NUM-1],
    input  wire [DEPTH-1:0]             i_partner_resolve_primary_merge_slots [0:LOGICAL_TREE_NUM-1],
    output reg  [LOGICAL_TREE_NUM-1:0]  o_partner_resolve_valid,
    output reg  [SLOT_ID_WIDTH-1:0]     o_partner_resolve_slot_id [0:LOGICAL_TREE_NUM-1],
    output reg  [COUNT_WIDTH-1:0]       o_logical_pending_count [0:LOGICAL_TREE_NUM-1],

    output reg  [COUNT_WIDTH-1:0]       o_pending_count,
    output reg  [COUNT_WIDTH-1:0]       o_effective_free_count,
    output wire                         o_full,
    output wire [DEPTH-1:0]             o_slot_older [0:DEPTH-1],
    output reg                          o_protocol_error
);

    localparam AGE_PAIR_COUNT = (DEPTH * (DEPTH - 1)) / 2;
    localparam AGE_PAIR_STORAGE_WIDTH =
        (AGE_PAIR_COUNT <= 0) ? 1 : AGE_PAIR_COUNT;

    initial begin
        if ((DATA_WIDTH < 1) || (LOGICAL_TREE_NUM < 1) ||
            (REQUEST_PORTS < 1) || (ORDER_WIDTH < 1) || (DEPTH < 1))
            $fatal(1, "LogicalRequestBuffer parameters are invalid");
    end

    reg [DEPTH-1:0] slot_valid;
    reg [DEPTH-1:0] slot_push;
    reg [DEPTH-1:0] slot_pop;
    reg [LOGICAL_ID_WIDTH-1:0] slot_logical_id [0:DEPTH-1];
    // Predecode logical ownership when a slot is committed.  Head selection is
    // on the dispatch-critical path, so it consumes this registered one-hot
    // form instead of re-decoding every binary slot_logical_id each cycle.
    // Keep slot_logical_id for protocol/error checks and diagnostics.
    reg [LOGICAL_TREE_NUM-1:0] slot_logical_onehot [0:DEPTH-1];
    reg [DATA_WIDTH-1:0] slot_push_data [0:DEPTH-1];
    reg [ORDER_WIDTH-1:0] slot_order [0:DEPTH-1];
    reg [SOURCE_PORT_WIDTH-1:0] slot_source_port [0:DEPTH-1];
    reg [DEPTH-1:0] slot_merge_slots [0:DEPTH-1];
    // A strict total order needs one state bit per unordered live-slot pair.
    // Reconstruct the opposite direction instead of storing both directions
    // and the always-zero diagonal.  At DEPTH=12 this reduces the age state
    // from 144 bits to 66 without changing the head/partner algorithms.
    reg [AGE_PAIR_STORAGE_WIDTH-1:0] slot_first_older;
    wire [DEPTH-1:0] slot_older [0:DEPTH-1];
    reg [DEPTH-1:0] slot_older_next [0:DEPTH-1];
    reg [DEPTH-1:0] slot_reserved;
    reg [DEPTH-1:0] logical_live_slot_mask [0:LOGICAL_TREE_NUM-1];
    reg [DEPTH-1:0] logical_oldest_slot_mask [0:LOGICAL_TREE_NUM-1];
    reg [DEPTH-1:0]
        logical_reciprocal_push_mask [0:LOGICAL_TREE_NUM-1];
    reg [DEPTH-1:0] logical_head_slot_mask [0:LOGICAL_TREE_NUM-1];
    reg [DEPTH-1:0] head_older_slots [0:LOGICAL_TREE_NUM-1];

    // One registered capture plan is sufficient for one-plan-per-cycle
    // throughput because commit is an unconditional internal state update.
    // A valid old plan commits on the same edge on which a new plan may fill
    // these registers.  slot_reserved always describes the old/current plan
    // visible before that edge.
    reg allocation_plan_valid;
    reg [REQUEST_PORTS-1:0] allocation_plan_lane_valid;
    reg [DEPTH-1:0] allocation_plan_slot_mask;
    reg allocation_plan_push [0:REQUEST_PORTS-1];
    reg allocation_plan_pop [0:REQUEST_PORTS-1];
    reg [LOGICAL_ID_WIDTH-1:0]
        allocation_plan_logical_id [0:REQUEST_PORTS-1];
    reg [DATA_WIDTH-1:0]
        allocation_plan_push_data [0:REQUEST_PORTS-1];
    reg [ORDER_WIDTH-1:0]
        allocation_plan_order [0:REQUEST_PORTS-1];
    reg [SOURCE_PORT_WIDTH-1:0]
        allocation_plan_source_port [0:REQUEST_PORTS-1];
    reg [SLOT_ID_WIDTH-1:0]
        allocation_plan_slot [0:REQUEST_PORTS-1];
    // Preserve capture provenance in input-lane space.  Expanding this
    // relation into concrete slot one-hot masks while the live allocator was
    // still selecting slots connected the four-port allocation priority
    // chain directly to these plan registers.  The registered slot IDs below
    // are sufficient to perform that expansion locally during commit.
    reg [REQUEST_PORTS-1:0]
        allocation_plan_merge_lane_mask [0:REQUEST_PORTS-1];
    // All lanes captured in one event share the same set of entries that were
    // already older when the event was accepted.  Within-event age remains
    // the lower-input-port ordering and is reconstructed from registered lane
    // valid bits and slot IDs during commit.
    reg [DEPTH-1:0] allocation_plan_base_older_mask;
    wire allocation_plan_commit;
    assign allocation_plan_commit = allocation_plan_valid;

    // Native complete-operation mode uses the shared descriptors as a pool
    // of linked per-logical operation queues.  A queue head is therefore a
    // direct descriptor index; selecting it no longer needs the slot-by-slot
    // ownership scan or the D-by-D age proof used by the legacy half-request
    // interface.  The registered capture plan and delayed retirement mask
    // remain unchanged, preserving capture/retire latency and slot reuse.
    reg [LOGICAL_TREE_NUM-1:0] native_queue_valid;
    reg [SLOT_ID_WIDTH-1:0]
        native_queue_head [0:LOGICAL_TREE_NUM-1];
    reg [SLOT_ID_WIDTH-1:0]
        native_queue_tail [0:LOGICAL_TREE_NUM-1];
    reg [COUNT_WIDTH-1:0]
        native_queue_count [0:LOGICAL_TREE_NUM-1];
    reg [DEPTH-1:0] native_next_valid;
    reg [SLOT_ID_WIDTH-1:0] native_next_slot [0:DEPTH-1];

    reg [LOGICAL_TREE_NUM-1:0] native_commit_valid;
    reg [SLOT_ID_WIDTH-1:0]
        native_commit_first_slot [0:LOGICAL_TREE_NUM-1];
    reg [SLOT_ID_WIDTH-1:0]
        native_commit_last_slot [0:LOGICAL_TREE_NUM-1];
    reg [COUNT_WIDTH-1:0]
        native_commit_count [0:LOGICAL_TREE_NUM-1];
    reg [REQUEST_PORTS-1:0] native_plan_next_valid;
    reg [SLOT_ID_WIDTH-1:0]
        native_plan_next_slot [0:REQUEST_PORTS-1];
    reg [LOGICAL_TREE_NUM-1:0] native_retire_head;
    reg [DEPTH-1:0] retire_request_slot_mask;
    reg [DEPTH-1:0] retire_slot_mask;

    function integer age_pair_index;
        input integer first_slot;
        input integer second_slot;
        begin
            age_pair_index =
                (first_slot * (2 * DEPTH - first_slot - 1)) / 2 +
                (second_slot - first_slot - 1);
        end
    endfunction

    function integer head_pair_index;
        input integer first_logical;
        input integer second_logical;
        begin
            head_pair_index =
                (first_logical *
                 (2 * LOGICAL_TREE_NUM - first_logical - 1)) / 2 +
                (second_logical - first_logical - 1);
        end
    endfunction

    genvar age_row;
    genvar age_column;
    generate
        for (age_row = 0; age_row < DEPTH;
             age_row = age_row + 1) begin : GEN_AGE_ROW
            assign o_slot_older[age_row] = slot_older[age_row];
            for (age_column = 0; age_column < DEPTH;
                 age_column = age_column + 1) begin : GEN_AGE_COLUMN
                if (age_row < age_column) begin : GEN_FORWARD_AGE
                    localparam integer AGE_PAIR_INDEX =
                        age_pair_index(age_row, age_column);
                    assign slot_older[age_row][age_column] =
                        slot_valid[age_row] && slot_valid[age_column] &&
                        slot_first_older[AGE_PAIR_INDEX];
                end else if (age_row > age_column) begin : GEN_REVERSE_AGE
                    localparam integer AGE_PAIR_INDEX =
                        age_pair_index(age_column, age_row);
                    assign slot_older[age_row][age_column] =
                        slot_valid[age_row] && slot_valid[age_column] &&
                        !slot_first_older[AGE_PAIR_INDEX];
                end else begin : GEN_SELF_AGE
                    assign slot_older[age_row][age_column] = 1'b0;
                end
            end
        end
    endgenerate

    integer head_logical;
    integer head_slot_index;
    integer head_other_slot;
    integer selected_head_slot;

    integer native_plan_logical;
    integer native_plan_port;
    integer native_plan_later_port;
    integer native_retire_logical_index;
    always @* begin
        native_commit_valid = {LOGICAL_TREE_NUM{1'b0}};
        native_plan_next_valid = {REQUEST_PORTS{1'b0}};
        native_retire_head = {LOGICAL_TREE_NUM{1'b0}};
        for (native_plan_logical = 0;
             native_plan_logical < LOGICAL_TREE_NUM;
             native_plan_logical = native_plan_logical + 1) begin
            native_commit_first_slot[native_plan_logical] =
                {SLOT_ID_WIDTH{1'b0}};
            native_commit_last_slot[native_plan_logical] =
                {SLOT_ID_WIDTH{1'b0}};
            native_commit_count[native_plan_logical] =
                {COUNT_WIDTH{1'b0}};
        end
        for (native_plan_port = 0;
             native_plan_port < REQUEST_PORTS;
             native_plan_port = native_plan_port + 1) begin
            native_plan_next_slot[native_plan_port] =
                {SLOT_ID_WIDTH{1'b0}};
            if (allocation_plan_commit &&
                allocation_plan_lane_valid[native_plan_port] &&
                (int'(allocation_plan_logical_id[native_plan_port]) <
                 LOGICAL_TREE_NUM)) begin
                for (native_plan_logical = 0;
                     native_plan_logical < LOGICAL_TREE_NUM;
                     native_plan_logical = native_plan_logical + 1) begin
                    if (int'(allocation_plan_logical_id[
                            native_plan_port]) == native_plan_logical) begin
                        if (!native_commit_valid[native_plan_logical])
                            native_commit_first_slot[native_plan_logical] =
                                allocation_plan_slot[native_plan_port];
                        native_commit_valid[native_plan_logical] = 1'b1;
                        native_commit_last_slot[native_plan_logical] =
                            allocation_plan_slot[native_plan_port];
                        native_commit_count[native_plan_logical] =
                            native_commit_count[native_plan_logical] + 1'b1;
                    end
                end
                for (native_plan_later_port = native_plan_port + 1;
                     native_plan_later_port < REQUEST_PORTS;
                     native_plan_later_port =
                         native_plan_later_port + 1) begin
                    if (!native_plan_next_valid[native_plan_port] &&
                        allocation_plan_lane_valid[
                            native_plan_later_port] &&
                        (allocation_plan_logical_id[native_plan_later_port] ==
                         allocation_plan_logical_id[native_plan_port])) begin
                        native_plan_next_valid[native_plan_port] = 1'b1;
                        native_plan_next_slot[native_plan_port] =
                            allocation_plan_slot[native_plan_later_port];
                    end
                end
            end
        end
        for (native_retire_logical_index = 0;
             native_retire_logical_index < LOGICAL_TREE_NUM;
             native_retire_logical_index =
                 native_retire_logical_index + 1) begin
            if (native_queue_valid[native_retire_logical_index] &&
                (int'(native_queue_head[
                    native_retire_logical_index]) < DEPTH))
                native_retire_head[native_retire_logical_index] =
                    retire_slot_mask[native_queue_head[
                        native_retire_logical_index]];
        end
    end

    always @* begin
        o_head_valid = {LOGICAL_TREE_NUM{1'b0}};
        o_head_push = {LOGICAL_TREE_NUM{1'b0}};
        o_head_pop = {LOGICAL_TREE_NUM{1'b0}};
        o_pending_count = {COUNT_WIDTH{1'b0}};
        for (head_slot_index = 0; head_slot_index < DEPTH;
             head_slot_index = head_slot_index + 1)
            if (slot_valid[head_slot_index] ||
                slot_reserved[head_slot_index])
                o_pending_count = o_pending_count + 1'b1;

        for (head_logical = 0;
             head_logical < LOGICAL_TREE_NUM;
             head_logical = head_logical + 1) begin
            o_head_push_data[head_logical] = {DATA_WIDTH{1'b0}};
            o_head_order[head_logical] = {ORDER_WIDTH{1'b0}};
            o_head_source_port[head_logical] =
                {SOURCE_PORT_WIDTH{1'b0}};
            o_head_slot_id[head_logical] = {SLOT_ID_WIDTH{1'b0}};
            o_head_merge_slots[head_logical] = {DEPTH{1'b0}};
            o_logical_pending_count[head_logical] =
                {COUNT_WIDTH{1'b0}};
            selected_head_slot = -1;
            logical_live_slot_mask[head_logical] = {DEPTH{1'b0}};
            logical_oldest_slot_mask[head_logical] = {DEPTH{1'b0}};
            logical_reciprocal_push_mask[head_logical] =
                {DEPTH{1'b0}};
            logical_head_slot_mask[head_logical] = {DEPTH{1'b0}};

            if (NATIVE_COMPOUND_REQUESTS != 0) begin
                o_logical_pending_count[head_logical] =
                    native_queue_count[head_logical];
                if (native_queue_valid[head_logical] &&
                    (int'(native_queue_head[head_logical]) < DEPTH)) begin
                    selected_head_slot =
                        int'(native_queue_head[head_logical]);
                    o_head_valid[head_logical] =
                        slot_valid[selected_head_slot];
                    o_head_push[head_logical] =
                        slot_push[selected_head_slot];
                    o_head_pop[head_logical] =
                        slot_pop[selected_head_slot];
                    o_head_push_data[head_logical] =
                        slot_push_data[selected_head_slot];
                    o_head_order[head_logical] =
                        slot_order[selected_head_slot];
                    o_head_source_port[head_logical] =
                        slot_source_port[selected_head_slot];
                    o_head_slot_id[head_logical] =
                        native_queue_head[head_logical];
                end
            end else begin
                for (head_slot_index = 0;
                     head_slot_index < DEPTH;
                     head_slot_index = head_slot_index + 1) begin
                    if (slot_valid[head_slot_index]) begin
                        if (slot_logical_onehot[head_slot_index]
                                                [head_logical]) begin
                            o_logical_pending_count[head_logical] =
                                o_logical_pending_count[head_logical] +
                                1'b1;
                            logical_live_slot_mask[head_logical]
                                                  [head_slot_index] = 1'b1;
                        end
                    end
                end

                // The exact age matrix is a strict total order over live
                // legacy slots.  Compute every possible oldest slot
                // independently instead of a DEPTH-deep running winner.
                for (head_slot_index = 0;
                     head_slot_index < DEPTH;
                     head_slot_index = head_slot_index + 1) begin
                    logical_oldest_slot_mask[head_logical]
                                            [head_slot_index] =
                        logical_live_slot_mask[head_logical][head_slot_index];
                    for (head_other_slot = 0;
                         head_other_slot < DEPTH;
                         head_other_slot = head_other_slot + 1) begin
                        if ((head_other_slot != head_slot_index) &&
                            logical_live_slot_mask[head_logical]
                                                  [head_other_slot] &&
                            !slot_older[head_slot_index][head_other_slot])
                            logical_oldest_slot_mask[head_logical]
                                                    [head_slot_index] = 1'b0;
                    end
                end

                // Normalize a reciprocal legacy Push/Pop pair to its Push
                // descriptor before exposing the logical OQ head.
                for (head_slot_index = 0;
                     head_slot_index < DEPTH;
                     head_slot_index = head_slot_index + 1) begin
                    for (head_other_slot = 0;
                         head_other_slot < DEPTH;
                         head_other_slot = head_other_slot + 1) begin
                        if (logical_oldest_slot_mask[head_logical]
                                                     [head_other_slot] &&
                            !slot_push[head_other_slot] &&
                            logical_live_slot_mask[head_logical]
                                                  [head_slot_index] &&
                            slot_push[head_slot_index] &&
                            slot_merge_slots[head_other_slot]
                                            [head_slot_index] &&
                            slot_merge_slots[head_slot_index]
                                            [head_other_slot])
                            logical_reciprocal_push_mask[head_logical]
                                                         [head_slot_index] =
                                1'b1;
                    end
                end

                logical_head_slot_mask[head_logical] =
                    logical_oldest_slot_mask[head_logical];
                if (|logical_reciprocal_push_mask[head_logical]) begin
                    for (head_slot_index = 0;
                         head_slot_index < DEPTH;
                         head_slot_index = head_slot_index + 1)
                        if (logical_reciprocal_push_mask[head_logical]
                                                           [head_slot_index])
                            selected_head_slot = head_slot_index;
                    logical_head_slot_mask[head_logical] = {DEPTH{1'b0}};
                    logical_head_slot_mask[head_logical]
                                          [selected_head_slot] = 1'b1;
                end

                for (head_slot_index = 0;
                     head_slot_index < DEPTH;
                     head_slot_index = head_slot_index + 1) begin
                    if (logical_head_slot_mask[head_logical]
                                              [head_slot_index]) begin
                        o_head_valid[head_logical] = 1'b1;
                        o_head_push[head_logical] =
                            o_head_push[head_logical] |
                            slot_push[head_slot_index];
                        o_head_pop[head_logical] =
                            o_head_pop[head_logical] |
                            slot_pop[head_slot_index];
                        o_head_push_data[head_logical] =
                            o_head_push_data[head_logical] |
                            slot_push_data[head_slot_index];
                        o_head_order[head_logical] =
                            o_head_order[head_logical] |
                            slot_order[head_slot_index];
                        o_head_source_port[head_logical] =
                            o_head_source_port[head_logical] |
                            slot_source_port[head_slot_index];
                        o_head_slot_id[head_logical] =
                            o_head_slot_id[head_logical] |
                            SLOT_ID_WIDTH'(head_slot_index);
                        o_head_merge_slots[head_logical] =
                            o_head_merge_slots[head_logical] |
                            slot_merge_slots[head_slot_index];
                    end
                end
            end

            for (head_slot_index = 0;
                 head_slot_index < REQUEST_PORTS;
                 head_slot_index = head_slot_index + 1)
                if (allocation_plan_lane_valid[head_slot_index] &&
                    (int'(allocation_plan_logical_id[
                        head_slot_index]) == head_logical))
                    o_logical_pending_count[head_logical] =
                        o_logical_pending_count[head_logical] + 1'b1;
        end
    end

    // Produce only one relation bit per unordered pair of selected logical
    // heads.  Older is anti-symmetric and same-event is symmetric, so the full
    // compatibility matrices can be reconstructed without calculating the
    // reverse direction a second time.  HeterogeneousPIFO consumes the compact
    // vectors directly.  Outputs remain combinational and preserve the Stage9
    // zero-wait fill.
    integer head_relation_source;
    integer head_relation_target;
    integer head_relation_slot;
    always @* begin
        o_head_first_older = {HEAD_PAIR_STORAGE_WIDTH{1'b0}};
        o_head_pair_same_event_state =
            {HEAD_PAIR_STORAGE_WIDTH{1'b0}};
        for (head_relation_source = 0;
             head_relation_source < LOGICAL_TREE_NUM;
             head_relation_source = head_relation_source + 1) begin
            o_head_pair_older[head_relation_source] =
                {LOGICAL_TREE_NUM{1'b0}};
            o_head_pair_same_event[head_relation_source] =
                {LOGICAL_TREE_NUM{1'b0}};
            head_older_slots[head_relation_source] = {DEPTH{1'b0}};
        end

        // Native descriptors already contain the complete Push/Pop operation.
        // The public vPIFO control boundary keeps FIFO order only inside an
        // operation queue and does not construct a total order across OQs.
        // Keep the cross-logical age/provenance network only for the legacy
        // half-request interface that still needs exact partner recovery.
        if (NATIVE_COMPOUND_REQUESTS == 0) begin
            for (head_relation_source = 0;
                 head_relation_source < LOGICAL_TREE_NUM;
                 head_relation_source = head_relation_source + 1) begin
                for (head_relation_slot = 0;
                     head_relation_slot < DEPTH;
                     head_relation_slot = head_relation_slot + 1)
                    if (logical_head_slot_mask[head_relation_source]
                                              [head_relation_slot])
                        head_older_slots[head_relation_source] =
                            head_older_slots[head_relation_source] |
                            slot_older[head_relation_slot];
            end

            for (head_relation_source = 0;
                 head_relation_source < LOGICAL_TREE_NUM - 1;
                 head_relation_source = head_relation_source + 1) begin
                for (head_relation_target = head_relation_source + 1;
                     head_relation_target < LOGICAL_TREE_NUM;
                     head_relation_target = head_relation_target + 1) begin
                    if (o_head_valid[head_relation_source] &&
                        o_head_valid[head_relation_target]) begin
                        o_head_first_older[
                            head_pair_index(head_relation_source,
                                            head_relation_target)] =
                            |(head_older_slots[head_relation_source] &
                              logical_head_slot_mask[head_relation_target]);
                        o_head_pair_same_event_state[
                            head_pair_index(head_relation_source,
                                            head_relation_target)] =
                            |(o_head_merge_slots[head_relation_source] &
                              logical_head_slot_mask[head_relation_target]) &&
                            |(o_head_merge_slots[head_relation_target] &
                              logical_head_slot_mask[head_relation_source]);
                        o_head_pair_older[head_relation_source]
                            [head_relation_target] =
                            o_head_first_older[
                                head_pair_index(head_relation_source,
                                                head_relation_target)];
                        o_head_pair_older[head_relation_target]
                            [head_relation_source] =
                            !o_head_first_older[
                                head_pair_index(head_relation_source,
                                                head_relation_target)];
                        o_head_pair_same_event[head_relation_source]
                            [head_relation_target] =
                            o_head_pair_same_event_state[
                                head_pair_index(head_relation_source,
                                                head_relation_target)];
                        o_head_pair_same_event[head_relation_target]
                            [head_relation_source] =
                            o_head_pair_same_event_state[
                                head_pair_index(head_relation_source,
                                                head_relation_target)];
                    end
                end
            end
        end
    end

    // Stage-B partner resolution.  The primary slot, request kind, and merge
    // row are all registered by HeterogeneousPIFO before reaching this block.
    // Therefore this scan cannot feed back into primary selection.  A valid
    // result is the oldest live reciprocal Pop for that exact registered
    // primary; capture order tags alone never create a P/P relationship.
    //
    // Resolve every possible partner independently.  The previous running
    // integer winner made each slot's comparison depend on all lower-numbered
    // slots and synthesized as a deep priority/age-selection chain.  The age
    // matrix is a strict total order for live slots, so the selected partner
    // is equivalently the one eligible slot that is older than every other
    // eligible slot.  The resulting mask is one-hot for all legal state and
    // permits a balanced constant OR encoder for the registered slot ID.
    reg [DEPTH-1:0]
        partner_primary_slot_mask [0:LOGICAL_TREE_NUM-1];
    reg [DEPTH-1:0]
        partner_eligible_slot_mask [0:LOGICAL_TREE_NUM-1];
    reg [DEPTH-1:0]
        partner_oldest_slot_mask [0:LOGICAL_TREE_NUM-1];
    integer resolve_logical;
    integer resolve_slot;
    integer resolve_other_slot;
    always @* begin
        o_partner_resolve_valid = {LOGICAL_TREE_NUM{1'b0}};
        for (resolve_logical = 0;
             resolve_logical < LOGICAL_TREE_NUM;
             resolve_logical = resolve_logical + 1) begin
            o_partner_resolve_slot_id[resolve_logical] =
                {SLOT_ID_WIDTH{1'b0}};
            partner_primary_slot_mask[resolve_logical] =
                {DEPTH{1'b0}};
            partner_eligible_slot_mask[resolve_logical] =
                {DEPTH{1'b0}};
            partner_oldest_slot_mask[resolve_logical] =
                {DEPTH{1'b0}};
            if (i_partner_resolve_valid[resolve_logical]) begin
                if (int'(i_partner_resolve_primary_slot_id[
                        resolve_logical]) < DEPTH) begin
                    partner_primary_slot_mask[resolve_logical]
                        [i_partner_resolve_primary_slot_id[
                            resolve_logical]] = 1'b1;
                    if (i_partner_resolve_primary_push[
                            resolve_logical]) begin
                        for (resolve_slot = 0;
                             resolve_slot < DEPTH;
                             resolve_slot = resolve_slot + 1) begin
                            partner_eligible_slot_mask[resolve_logical]
                                [resolve_slot] =
                                i_partner_resolve_primary_merge_slots[
                                    resolve_logical][resolve_slot] &&
                                slot_valid[resolve_slot] &&
                                !slot_push[resolve_slot] &&
                                slot_logical_onehot[resolve_slot]
                                                    [resolve_logical] &&
                                |(slot_merge_slots[resolve_slot] &
                                  partner_primary_slot_mask[
                                      resolve_logical]);
                        end
                    end
                end
            end

            for (resolve_slot = 0;
                 resolve_slot < DEPTH;
                 resolve_slot = resolve_slot + 1) begin
                partner_oldest_slot_mask[resolve_logical][resolve_slot] =
                    partner_eligible_slot_mask[resolve_logical]
                                               [resolve_slot];
                for (resolve_other_slot = 0;
                     resolve_other_slot < DEPTH;
                     resolve_other_slot = resolve_other_slot + 1) begin
                    if ((resolve_other_slot != resolve_slot) &&
                        partner_eligible_slot_mask[resolve_logical]
                                                   [resolve_other_slot] &&
                        !slot_older[resolve_slot][resolve_other_slot])
                        partner_oldest_slot_mask[resolve_logical]
                                                [resolve_slot] = 1'b0;
                end
            end

            o_partner_resolve_valid[resolve_logical] =
                |partner_oldest_slot_mask[resolve_logical];
            for (resolve_slot = 0;
                 resolve_slot < DEPTH;
                 resolve_slot = resolve_slot + 1) begin
                if (partner_oldest_slot_mask[resolve_logical]
                                            [resolve_slot])
                    o_partner_resolve_slot_id[resolve_logical] =
                        o_partner_resolve_slot_id[resolve_logical] |
                        SLOT_ID_WIDTH'(resolve_slot);
            end
        end
    end

    assign o_full = (o_effective_free_count == {COUNT_WIDTH{1'b0}});

    // A dispatch converts the candidate's registered retirement descriptor
    // directly into a one/two-hot mask.  State retirement happens from this
    // registered mask on the following cycle.  No live pending-head scan is
    // used to recover the dispatched slots.
    reg [LOGICAL_TREE_NUM-1:0] retire_check_valid;
    reg [SLOT_ID_WIDTH-1:0]
        retire_check_primary_slot_id [0:LOGICAL_TREE_NUM-1];
    reg [LOGICAL_TREE_NUM-1:0] retire_check_partner_valid;
    reg [SLOT_ID_WIDTH-1:0]
        retire_check_partner_slot_id [0:LOGICAL_TREE_NUM-1];
    // Diagnostic checks are intentionally decoupled from live dispatch.
    // Descriptors are captured first, checked against the pre-retirement
    // state one cycle later, and only then folded into the sticky output.
    reg [LOGICAL_TREE_NUM-1:0] retire_check_error;
    reg [LOGICAL_TREE_NUM-1:0] partner_resolve_check_error;
    reg [DEPTH-1:0] available_slot_mask;
    reg allocation_valid [0:REQUEST_PORTS-1];
    reg [SLOT_ID_WIDTH-1:0] allocation_slot [0:REQUEST_PORTS-1];
    reg [DEPTH-1:0]
        allocation_commit_merge_slots [0:REQUEST_PORTS-1];
    reg [DEPTH-1:0]
        allocation_commit_older_slots [0:REQUEST_PORTS-1];
    reg [REQUEST_PORTS-1:0] allocation_lane_valid_mask;
    reg [DEPTH-1:0] allocation_slot_mask;
    reg [REQUEST_PORTS-1:0] allocation_request_eligible;
    reg [COUNT_WIDTH-1:0]
        allocation_request_ordinal [0:REQUEST_PORTS-1];
    reg [COUNT_WIDTH-1:0]
        allocation_free_before_count [0:DEPTH-1];
    reg [DEPTH-1:0]
        allocation_port_slot_mask [0:REQUEST_PORTS-1];
    integer allocation_port;
    integer allocation_prior_port;
    integer commit_relation_port;
    integer commit_partner_port;
    integer allocation_slot_index;
    integer allocation_prefix_index;
    integer dequeue_logical;
    integer free_count_index;
    reg capture_id_valid;
    always @* begin
        retire_request_slot_mask = {DEPTH{1'b0}};
        for (dequeue_logical = 0;
             dequeue_logical < LOGICAL_TREE_NUM;
             dequeue_logical = dequeue_logical + 1) begin
            if (i_retire_valid[dequeue_logical]) begin
                if (int'(i_retire_primary_slot_id[
                         dequeue_logical]) < DEPTH)
                    retire_request_slot_mask[
                        i_retire_primary_slot_id[
                            dequeue_logical]] = 1'b1;

                if (i_retire_partner_valid[
                    dequeue_logical] &&
                    (int'(i_retire_partner_slot_id[
                         dequeue_logical]) < DEPTH) &&
                    (i_retire_partner_slot_id[
                         dequeue_logical] !=
                     i_retire_primary_slot_id[
                         dequeue_logical]))
                        retire_request_slot_mask[
                            i_retire_partner_slot_id[
                                dequeue_logical]] = 1'b1;
            end
        end

        // A slot is advertised as free only after its registered retirement
        // has updated slot_valid.  This intentionally removes the
        // dispatch-to-capture bypass used by the old full+dequeue path.
        o_effective_free_count = {COUNT_WIDTH{1'b0}};
        for (free_count_index = 0;
             free_count_index < DEPTH;
             free_count_index = free_count_index + 1)
            if (!slot_valid[free_count_index] &&
                !slot_reserved[free_count_index])
                o_effective_free_count =
                    o_effective_free_count + 1'b1;
    end

    always @* begin
        // Registered retirement is not bypassed into availability.  A slot is
        // reusable only after slot_valid has actually cleared.  The current
        // plan's reservations are also excluded even though they are not yet
        // visible to head/partner selection.
        available_slot_mask = ~(slot_valid | slot_reserved);
        o_req_ready = {REQUEST_PORTS{1'b0}};
        o_req_capture_fire = {REQUEST_PORTS{1'b0}};
        o_req_bad_id = {REQUEST_PORTS{1'b0}};
        allocation_lane_valid_mask = {REQUEST_PORTS{1'b0}};
        allocation_slot_mask = {DEPTH{1'b0}};

        // Compute each free slot's zero-based ordinal once from the common
        // live availability snapshot.  Every request lane can then select
        // its k-th free slot in parallel instead of consuming a mutable mask
        // through four cascaded priority encoders.
        for (allocation_slot_index = 0;
             allocation_slot_index < DEPTH;
             allocation_slot_index = allocation_slot_index + 1) begin
            allocation_free_before_count[
                allocation_slot_index] = {COUNT_WIDTH{1'b0}};
            for (allocation_prefix_index = 0;
                 allocation_prefix_index < allocation_slot_index;
                 allocation_prefix_index =
                     allocation_prefix_index + 1) begin
                if (available_slot_mask[allocation_prefix_index])
                    allocation_free_before_count[
                        allocation_slot_index] =
                            allocation_free_before_count[
                                allocation_slot_index] + 1'b1;
            end
        end

        allocation_request_eligible = {REQUEST_PORTS{1'b0}};
        for (allocation_port = 0;
             allocation_port < REQUEST_PORTS;
             allocation_port = allocation_port + 1) begin
            allocation_valid[allocation_port] = 1'b0;
            allocation_slot[allocation_port] =
                {SLOT_ID_WIDTH{1'b0}};
            capture_id_valid =
                (int'(i_logical_tree_id[allocation_port]) <
                 LOGICAL_TREE_NUM);
            o_req_bad_id[allocation_port] =
                i_req_valid[allocation_port] && !capture_id_valid;
            allocation_request_eligible[allocation_port] =
                 i_req_valid[allocation_port] && capture_id_valid;
        end

        for (allocation_port = 0;
             allocation_port < REQUEST_PORTS;
             allocation_port = allocation_port + 1) begin
            allocation_request_ordinal[allocation_port] =
                {COUNT_WIDTH{1'b0}};
            for (allocation_prior_port = 0;
                 allocation_prior_port < allocation_port;
                 allocation_prior_port =
                     allocation_prior_port + 1) begin
                if (allocation_request_eligible[
                        allocation_prior_port])
                    allocation_request_ordinal[
                        allocation_port] =
                            allocation_request_ordinal[
                                allocation_port] + 1'b1;
            end

            allocation_port_slot_mask[allocation_port] =
                {DEPTH{1'b0}};
            for (allocation_slot_index = 0;
                 allocation_slot_index < DEPTH;
                 allocation_slot_index =
                     allocation_slot_index + 1) begin
                if (available_slot_mask[allocation_slot_index] &&
                    (allocation_free_before_count[
                         allocation_slot_index] ==
                     allocation_request_ordinal[
                         allocation_port])) begin
                    allocation_port_slot_mask[allocation_port]
                                             [allocation_slot_index] =
                        1'b1;
                    allocation_slot[allocation_port] =
                        allocation_slot[allocation_port] |
                        (SLOT_ID_WIDTH'(allocation_slot_index) &
                         {SLOT_ID_WIDTH{
                             allocation_port_slot_mask[
                                 allocation_port]
                                 [allocation_slot_index]}});
                end
            end

            capture_id_valid =
                (int'(i_logical_tree_id[allocation_port]) <
                 LOGICAL_TREE_NUM);
            o_req_ready[allocation_port] =
                i_arst_n && capture_id_valid &&
                (|allocation_port_slot_mask[allocation_port]);
            if (allocation_request_eligible[allocation_port] &&
                (|allocation_port_slot_mask[allocation_port])) begin
                allocation_valid[allocation_port] = 1'b1;
                o_req_capture_fire[allocation_port] = 1'b1;
                allocation_lane_valid_mask[allocation_port] = 1'b1;
                allocation_slot_mask = allocation_slot_mask |
                    allocation_port_slot_mask[allocation_port];
            end
        end

    end

    // Expand only registered capture provenance and registered slot IDs into
    // the concrete relation masks consumed by the matrix commit.  This keeps
    // the live four-port allocation priority chain out of relation-plan D
    // inputs while preserving the exact reciprocal-merge and lower-port-age
    // semantics of the previous concrete masks.
    always @* begin
        for (commit_relation_port = 0;
             commit_relation_port < REQUEST_PORTS;
            commit_relation_port = commit_relation_port + 1) begin
            allocation_commit_merge_slots[commit_relation_port] =
                {DEPTH{1'b0}};
            allocation_commit_older_slots[commit_relation_port] =
                allocation_plan_base_older_mask;
            if (allocation_plan_lane_valid[commit_relation_port]) begin
                for (commit_partner_port = 0;
                     commit_partner_port < REQUEST_PORTS;
                     commit_partner_port = commit_partner_port + 1) begin
                    if (allocation_plan_lane_valid[commit_partner_port] &&
                        allocation_plan_merge_lane_mask[
                            commit_relation_port][commit_partner_port])
                        allocation_commit_merge_slots[
                            commit_relation_port][allocation_plan_slot[
                                commit_partner_port]] = 1'b1;
                    if ((commit_partner_port < commit_relation_port) &&
                        allocation_plan_lane_valid[commit_partner_port])
                        allocation_commit_older_slots[
                            commit_relation_port][allocation_plan_slot[
                                commit_partner_port]] = 1'b1;
                end
            end
        end
    end

    integer age_row_index;
    integer age_other_index;
    integer age_capture_port;
    integer age_update_slot;
    always @* begin
        age_update_slot = 0;
        for (age_row_index = 0; age_row_index < DEPTH;
             age_row_index = age_row_index + 1)
            slot_older_next[age_row_index] =
                slot_older[age_row_index];

        if (NATIVE_COMPOUND_REQUESTS == 0) begin
            for (age_row_index = 0; age_row_index < DEPTH;
                 age_row_index = age_row_index + 1) begin
                if (retire_slot_mask[age_row_index]) begin
                    for (age_other_index = 0;
                         age_other_index < DEPTH;
                         age_other_index = age_other_index + 1) begin
                        slot_older_next[age_row_index]
                                       [age_other_index] = 1'b0;
                        slot_older_next[age_other_index]
                                       [age_row_index] = 1'b0;
                    end
                end
            end

            for (age_capture_port = 0;
                 age_capture_port < REQUEST_PORTS;
                 age_capture_port = age_capture_port + 1) begin
                if (allocation_plan_commit &&
                    allocation_plan_lane_valid[age_capture_port]) begin
                    age_update_slot =
                        int'(allocation_plan_slot[age_capture_port]);
                    for (age_other_index = 0;
                         age_other_index < DEPTH;
                         age_other_index = age_other_index + 1) begin
                        slot_older_next[age_update_slot]
                                       [age_other_index] = 1'b0;
                        slot_older_next[age_other_index]
                                       [age_update_slot] =
                            allocation_commit_older_slots[
                                age_capture_port][age_other_index] &&
                            ((slot_valid[age_other_index] &&
                              !retire_slot_mask[age_other_index]) ||
                             allocation_plan_slot_mask[
                                 age_other_index]);
                    end
                    slot_older_next[age_update_slot]
                                   [age_update_slot] = 1'b0;
                end
            end
        end
    end

    integer reset_slot;
    integer reset_other_slot;
    integer update_slot;
    integer sequential_logical;
    integer sequential_capture_port;
    integer plan_check_port;
    integer plan_check_other_port;
    integer retire_check_other_logical;
    // Native complete-operation mode has one registered candidate per logical
    // OQ, and every live slot has exactly one registered one-hot owner.  Two
    // different logical OQs therefore cannot legally retire the same slot.
    // Keep that structural invariant as a simulation assertion instead of a
    // synthesizable LOGICAL_TREE_NUM-squared defensive comparison network.
    // Range, validity, ownership, and uniqueness are all structural invariants
    // of the internal native retirement interface, so keep them out of the
    // native hardware datapath and verify them here instead.
`ifndef SYNTHESIS
    integer native_retire_logical;
    integer native_retire_other_logical;
    always @(posedge i_clk) begin
        if (i_arst_n && (NATIVE_COMPOUND_REQUESTS != 0)) begin
            for (native_retire_logical = 0;
                 native_retire_logical < LOGICAL_TREE_NUM;
                 native_retire_logical = native_retire_logical + 1) begin
                assert (native_queue_valid[native_retire_logical] ==
                        (native_queue_count[native_retire_logical] != 0))
                else $error("native queue valid/count mismatch");
                if (native_queue_valid[native_retire_logical]) begin
                    assert ((int'(native_queue_head[
                                      native_retire_logical]) < DEPTH) &&
                            (int'(native_queue_tail[
                                      native_retire_logical]) < DEPTH) &&
                            slot_valid[native_queue_head[
                                native_retire_logical]] &&
                            slot_valid[native_queue_tail[
                                native_retire_logical]])
                    else $error("native queue head/tail is not live");
                    if (native_queue_count[native_retire_logical] == 1) begin
                        assert ((native_queue_head[
                                     native_retire_logical] ==
                                 native_queue_tail[
                                     native_retire_logical]) &&
                                !native_next_valid[native_queue_head[
                                    native_retire_logical]])
                        else $error("native singleton queue link mismatch");
                    end else begin
                        assert (native_next_valid[native_queue_head[
                                    native_retire_logical]])
                        else $error("native multi-entry queue has no successor");
                    end
                end
                if (i_retire_valid[native_retire_logical]) begin
                    assert (int'(i_retire_primary_slot_id[
                                      native_retire_logical]) < DEPTH)
                    else $error("native retire slot is out of range");
                    if (int'(i_retire_primary_slot_id[
                                 native_retire_logical]) < DEPTH) begin
                        assert (native_queue_valid[
                                    native_retire_logical] &&
                                slot_valid[i_retire_primary_slot_id[
                                              native_retire_logical]] &&
                                (native_queue_head[
                                     native_retire_logical] ==
                                 i_retire_primary_slot_id[
                                     native_retire_logical]))
                        else $error("native retire slot owner mismatch");
                    end
                    assert (!i_retire_partner_valid[
                                native_retire_logical])
                    else $error("native descriptor retired a partner slot");
                    for (native_retire_other_logical =
                             native_retire_logical + 1;
                         native_retire_other_logical < LOGICAL_TREE_NUM;
                         native_retire_other_logical =
                             native_retire_other_logical + 1) begin
                        if (i_retire_valid[
                                native_retire_other_logical]) begin
                            assert (i_retire_primary_slot_id[
                                        native_retire_logical] !=
                                    i_retire_primary_slot_id[
                                        native_retire_other_logical])
                            else $error("two native logical OQs retired the same slot");
                        end
                    end
                end
            end
        end
    end
`endif

    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            slot_valid <= {DEPTH{1'b0}};
            slot_push <= {DEPTH{1'b0}};
            slot_pop <= {DEPTH{1'b0}};
            slot_reserved <= {DEPTH{1'b0}};
            native_queue_valid <= {LOGICAL_TREE_NUM{1'b0}};
            native_next_valid <= {DEPTH{1'b0}};
            allocation_plan_valid <= 1'b0;
            allocation_plan_lane_valid <= {REQUEST_PORTS{1'b0}};
            allocation_plan_slot_mask <= {DEPTH{1'b0}};
            allocation_plan_base_older_mask <= {DEPTH{1'b0}};
            retire_slot_mask <= {DEPTH{1'b0}};
            retire_check_valid <= {LOGICAL_TREE_NUM{1'b0}};
            retire_check_partner_valid <=
                {LOGICAL_TREE_NUM{1'b0}};
            retire_check_error <= {LOGICAL_TREE_NUM{1'b0}};
            partner_resolve_check_error <=
                {LOGICAL_TREE_NUM{1'b0}};
            o_protocol_error <= 1'b0;
            slot_first_older <= {AGE_PAIR_STORAGE_WIDTH{1'b0}};
            for (sequential_logical = 0;
                 sequential_logical < LOGICAL_TREE_NUM;
                 sequential_logical =
                     sequential_logical + 1) begin
                retire_check_primary_slot_id[
                    sequential_logical] <=
                    {SLOT_ID_WIDTH{1'b0}};
                retire_check_partner_slot_id[
                    sequential_logical] <=
                    {SLOT_ID_WIDTH{1'b0}};
                native_queue_head[sequential_logical] <=
                    {SLOT_ID_WIDTH{1'b0}};
                native_queue_tail[sequential_logical] <=
                    {SLOT_ID_WIDTH{1'b0}};
                native_queue_count[sequential_logical] <=
                    {COUNT_WIDTH{1'b0}};
            end
            for (reset_slot = 0; reset_slot < DEPTH;
                 reset_slot = reset_slot + 1) begin
                slot_logical_id[reset_slot] <=
                    {LOGICAL_ID_WIDTH{1'b0}};
                slot_logical_onehot[reset_slot] <=
                    {LOGICAL_TREE_NUM{1'b0}};
                slot_push_data[reset_slot] <= {DATA_WIDTH{1'b0}};
                slot_order[reset_slot] <= {ORDER_WIDTH{1'b0}};
                slot_source_port[reset_slot] <=
                    {SOURCE_PORT_WIDTH{1'b0}};
                slot_merge_slots[reset_slot] <= {DEPTH{1'b0}};
                native_next_slot[reset_slot] <=
                    {SLOT_ID_WIDTH{1'b0}};
            end
            for (sequential_capture_port = 0;
                 sequential_capture_port < REQUEST_PORTS;
                 sequential_capture_port =
                     sequential_capture_port + 1) begin
                allocation_plan_push[sequential_capture_port] <= 1'b0;
                allocation_plan_pop[sequential_capture_port] <= 1'b0;
                allocation_plan_logical_id[
                    sequential_capture_port] <=
                    {LOGICAL_ID_WIDTH{1'b0}};
                allocation_plan_push_data[
                    sequential_capture_port] <= {DATA_WIDTH{1'b0}};
                allocation_plan_order[
                    sequential_capture_port] <= {ORDER_WIDTH{1'b0}};
                allocation_plan_source_port[
                    sequential_capture_port] <=
                    {SOURCE_PORT_WIDTH{1'b0}};
                allocation_plan_slot[
                    sequential_capture_port] <=
                    {SLOT_ID_WIDTH{1'b0}};
                allocation_plan_merge_lane_mask[
                    sequential_capture_port] <=
                    {REQUEST_PORTS{1'b0}};
            end
        end else begin
            retire_slot_mask <= retire_request_slot_mask;
            if (NATIVE_COMPOUND_REQUESTS == 0) begin
                retire_check_valid <= i_retire_valid;
                retire_check_partner_valid <= i_retire_partner_valid;
            end else begin
                retire_check_valid <= {LOGICAL_TREE_NUM{1'b0}};
                retire_check_partner_valid <=
                    {LOGICAL_TREE_NUM{1'b0}};
            end
            retire_check_error <= {LOGICAL_TREE_NUM{1'b0}};
            partner_resolve_check_error <=
                {LOGICAL_TREE_NUM{1'b0}};

            if ((|retire_check_error) ||
                (|partner_resolve_check_error))
                o_protocol_error <= 1'b1;

            // The current plan always commits on this edge.  In parallel, the
            // just-accepted request vector replaces it as the next plan and
            // establishes the only outstanding reservation mask.
            allocation_plan_valid <= |allocation_lane_valid_mask;
            allocation_plan_lane_valid <= allocation_lane_valid_mask;
            allocation_plan_slot_mask <= allocation_slot_mask;
            slot_reserved <= allocation_slot_mask;
            // This mask describes state as observed by the newly accepted
            // vector.  The old plan is still reserved here and commits on the
            // same edge; delayed retirements are excluded exactly as before.
            allocation_plan_base_older_mask <=
                (NATIVE_COMPOUND_REQUESTS != 0) ?
                    {DEPTH{1'b0}} :
                    ((slot_valid | slot_reserved) & ~retire_slot_mask);

            // Diagnostics observe only registered state and never participate
            // in ready, reservation, commit, matrix update, or retirement.
            if (|(slot_valid & slot_reserved))
                o_protocol_error <= 1'b1;
            if (allocation_plan_valid) begin
                if (allocation_plan_slot_mask != slot_reserved)
                    o_protocol_error <= 1'b1;
                for (plan_check_port = 0;
                     plan_check_port < REQUEST_PORTS;
                     plan_check_port = plan_check_port + 1) begin
                    if (allocation_plan_lane_valid[plan_check_port]) begin
                        if ((int'(allocation_plan_slot[
                                 plan_check_port]) >= DEPTH) ||
                            !slot_reserved[allocation_plan_slot[
                                plan_check_port]] ||
                            slot_valid[allocation_plan_slot[
                                plan_check_port]])
                            o_protocol_error <= 1'b1;
                        for (plan_check_other_port =
                                 plan_check_port + 1;
                             plan_check_other_port < REQUEST_PORTS;
                             plan_check_other_port =
                                 plan_check_other_port + 1)
                            if (allocation_plan_lane_valid[
                                    plan_check_other_port] &&
                                (allocation_plan_slot[plan_check_port] ==
                                 allocation_plan_slot[
                                     plan_check_other_port]))
                                o_protocol_error <= 1'b1;
                    end
                end
            end else if (|slot_reserved) begin
                o_protocol_error <= 1'b1;
            end

            if (NATIVE_COMPOUND_REQUESTS != 0) begin
                for (sequential_logical = 0;
                     sequential_logical < LOGICAL_TREE_NUM;
                     sequential_logical = sequential_logical + 1) begin
                    if (native_retire_head[sequential_logical]) begin
                        if (native_next_valid[native_queue_head[
                                sequential_logical]]) begin
                            native_queue_head[sequential_logical] <=
                                native_next_slot[native_queue_head[
                                    sequential_logical]];
                        end else begin
                            native_queue_valid[sequential_logical] <= 1'b0;
                        end
                    end

                    if (native_commit_valid[sequential_logical]) begin
                        // Append to the surviving old queue.  If its sole
                        // descriptor retires on this edge, the new batch
                        // instead becomes a fresh queue and no dead link is
                        // written into the retiring descriptor.
                        if (native_queue_valid[sequential_logical] &&
                            !(native_retire_head[sequential_logical] &&
                              !native_next_valid[native_queue_head[
                                  sequential_logical]])) begin
                            native_next_valid[native_queue_tail[
                                sequential_logical]] <= 1'b1;
                            native_next_slot[native_queue_tail[
                                sequential_logical]] <=
                                native_commit_first_slot[
                                    sequential_logical];
                        end
                        if (!native_queue_valid[sequential_logical] ||
                            (native_retire_head[sequential_logical] &&
                             !native_next_valid[native_queue_head[
                                 sequential_logical]]))
                            native_queue_head[sequential_logical] <=
                                native_commit_first_slot[
                                    sequential_logical];
                        native_queue_tail[sequential_logical] <=
                            native_commit_last_slot[sequential_logical];
                        native_queue_valid[sequential_logical] <= 1'b1;
                    end

                    case ({native_commit_valid[sequential_logical],
                           native_retire_head[sequential_logical]})
                        2'b10:
                            native_queue_count[sequential_logical] <=
                                native_queue_count[sequential_logical] +
                                native_commit_count[sequential_logical];
                        2'b01:
                            native_queue_count[sequential_logical] <=
                                native_queue_count[sequential_logical] - 1'b1;
                        2'b11:
                            native_queue_count[sequential_logical] <=
                                native_queue_count[sequential_logical] +
                                native_commit_count[sequential_logical] -
                                1'b1;
                        default: begin
                        end
                    endcase
                end
            end else begin
                for (reset_slot = 0; reset_slot < DEPTH;
                     reset_slot = reset_slot + 1) begin
                    for (reset_other_slot = reset_slot + 1;
                         reset_other_slot < DEPTH;
                         reset_other_slot = reset_other_slot + 1)
                        slot_first_older[
                            age_pair_index(reset_slot,
                                           reset_other_slot)] <=
                            slot_older_next[reset_slot]
                                           [reset_other_slot];
                end
            end

            if (NATIVE_COMPOUND_REQUESTS == 0) begin
                for (sequential_logical = 0;
                     sequential_logical < LOGICAL_TREE_NUM;
                     sequential_logical =
                         sequential_logical + 1) begin
                    retire_check_primary_slot_id[
                        sequential_logical] <=
                        i_retire_primary_slot_id[
                            sequential_logical];
                    retire_check_partner_slot_id[
                        sequential_logical] <=
                        i_retire_partner_slot_id[
                            sequential_logical];

                    // Partner-resolution diagnostics use the already
                    // registered primary descriptor, but are not part of the
                    // partner search or candidate-ready path.
                    if (i_partner_resolve_valid[
                            sequential_logical]) begin
                        if (int'(i_partner_resolve_primary_slot_id[
                                 sequential_logical]) >= DEPTH) begin
                            partner_resolve_check_error[
                                sequential_logical] <= 1'b1;
                        end else if (!slot_valid[
                                         i_partner_resolve_primary_slot_id[
                                             sequential_logical]] ||
                                    (int'(slot_logical_id[
                                         i_partner_resolve_primary_slot_id[
                                             sequential_logical]]) !=
                                     sequential_logical) ||
                                    (slot_push[
                                         i_partner_resolve_primary_slot_id[
                                             sequential_logical]] !=
                                     i_partner_resolve_primary_push[
                                         sequential_logical])) begin
                            partner_resolve_check_error[
                                sequential_logical] <= 1'b1;
                        end
                    end

                    // Retirement diagnostics observe the registered
                    // descriptor and pre-retirement state.  The resulting
                    // per-logical error bit is itself registered before it
                    // reaches o_protocol_error.
                    if (retire_check_partner_valid[
                            sequential_logical] &&
                        !retire_check_valid[sequential_logical])
                        retire_check_error[sequential_logical] <= 1'b1;

                    if (retire_check_valid[
                        sequential_logical]) begin
                        if (int'(retire_check_primary_slot_id[
                                 sequential_logical]) >= DEPTH) begin
                            retire_check_error[
                                sequential_logical] <= 1'b1;
                        end else begin
                            if (!slot_valid[
                                retire_check_primary_slot_id[
                                    sequential_logical]] ||
                                (int'(slot_logical_id[
                                    retire_check_primary_slot_id[
                                        sequential_logical]]) !=
                                 sequential_logical))
                                retire_check_error[
                                    sequential_logical] <= 1'b1;
                        end

                        if (retire_check_partner_valid[
                            sequential_logical]) begin
                            if ((int'(retire_check_partner_slot_id[
                                     sequential_logical]) >= DEPTH) ||
                                (retire_check_partner_slot_id[
                                     sequential_logical] ==
                                 retire_check_primary_slot_id[
                                     sequential_logical])) begin
                                retire_check_error[
                                    sequential_logical] <= 1'b1;
                            end else if ((int'(
                                         retire_check_primary_slot_id[
                                             sequential_logical]) <
                                         DEPTH) &&
                                        (!slot_valid[
                                            retire_check_partner_slot_id[
                                                sequential_logical]] ||
                                         (slot_logical_id[
                                            retire_check_partner_slot_id[
                                                sequential_logical]] !=
                                          slot_logical_id[
                                            retire_check_primary_slot_id[
                                                sequential_logical]]) ||
                                         !slot_push[
                                            retire_check_primary_slot_id[
                                                sequential_logical]] ||
                                         slot_push[
                                            retire_check_partner_slot_id[
                                                sequential_logical]] ||
                                         !slot_merge_slots[
                                            retire_check_primary_slot_id[
                                                sequential_logical]]
                                            [retire_check_partner_slot_id[
                                                sequential_logical]] ||
                                         !slot_merge_slots[
                                            retire_check_partner_slot_id[
                                                sequential_logical]]
                                            [retire_check_primary_slot_id[
                                                sequential_logical]]))
                                retire_check_error[
                                    sequential_logical] <= 1'b1;
                        end

                        // Legacy half-request mode can retire a primary and a
                        // recovered partner.  Preserve its complete pairwise
                        // duplicate diagnostics.
                        for (retire_check_other_logical =
                                 sequential_logical + 1;
                             retire_check_other_logical < LOGICAL_TREE_NUM;
                             retire_check_other_logical =
                                 retire_check_other_logical + 1) begin
                            if (retire_check_valid[
                                    retire_check_other_logical]) begin
                                if ((int'(retire_check_primary_slot_id[
                                         sequential_logical]) < DEPTH) &&
                                    (int'(retire_check_primary_slot_id[
                                         retire_check_other_logical]) < DEPTH) &&
                                    (retire_check_primary_slot_id[
                                         sequential_logical] ==
                                     retire_check_primary_slot_id[
                                         retire_check_other_logical]))
                                    retire_check_error[
                                        sequential_logical] <= 1'b1;

                                if (retire_check_partner_valid[
                                        sequential_logical] &&
                                    (int'(retire_check_partner_slot_id[
                                         sequential_logical]) < DEPTH) &&
                                    (int'(retire_check_primary_slot_id[
                                         retire_check_other_logical]) < DEPTH) &&
                                    (retire_check_partner_slot_id[
                                         sequential_logical] ==
                                     retire_check_primary_slot_id[
                                         retire_check_other_logical]))
                                    retire_check_error[
                                        sequential_logical] <= 1'b1;

                                if (retire_check_partner_valid[
                                        retire_check_other_logical] &&
                                    (int'(retire_check_primary_slot_id[
                                         sequential_logical]) < DEPTH) &&
                                    (int'(retire_check_partner_slot_id[
                                         retire_check_other_logical]) < DEPTH) &&
                                    (retire_check_primary_slot_id[
                                         sequential_logical] ==
                                     retire_check_partner_slot_id[
                                         retire_check_other_logical]))
                                    retire_check_error[
                                        sequential_logical] <= 1'b1;

                                if (retire_check_partner_valid[
                                        sequential_logical] &&
                                    retire_check_partner_valid[
                                        retire_check_other_logical] &&
                                    (int'(retire_check_partner_slot_id[
                                         sequential_logical]) < DEPTH) &&
                                    (int'(retire_check_partner_slot_id[
                                         retire_check_other_logical]) < DEPTH) &&
                                    (retire_check_partner_slot_id[
                                         sequential_logical] ==
                                     retire_check_partner_slot_id[
                                         retire_check_other_logical]))
                                    retire_check_error[
                                        sequential_logical] <= 1'b1;
                            end
                        end
                    end
                end
            end

            for (update_slot = 0; update_slot < DEPTH;
                 update_slot = update_slot + 1) begin
                if (retire_slot_mask[update_slot]) begin
                    slot_valid[update_slot] <= 1'b0;
                    slot_logical_onehot[update_slot] <=
                        {LOGICAL_TREE_NUM{1'b0}};
                    slot_merge_slots[update_slot] <= {DEPTH{1'b0}};
                    if (NATIVE_COMPOUND_REQUESTS != 0)
                        native_next_valid[update_slot] <= 1'b0;
                end
            end

            for (sequential_capture_port = 0;
                 sequential_capture_port < REQUEST_PORTS;
                 sequential_capture_port =
                     sequential_capture_port + 1) begin
                if (allocation_plan_commit &&
                    allocation_plan_lane_valid[
                        sequential_capture_port]) begin
                    update_slot =
                        int'(allocation_plan_slot[
                            sequential_capture_port]);
                    slot_valid[update_slot] <= 1'b1;
                    slot_push[update_slot] <=
                        allocation_plan_push[
                            sequential_capture_port];
                    slot_pop[update_slot] <=
                        allocation_plan_pop[
                            sequential_capture_port];
                    if (NATIVE_COMPOUND_REQUESTS == 0)
                        slot_logical_id[update_slot] <=
                            allocation_plan_logical_id[
                                sequential_capture_port];
                    if (NATIVE_COMPOUND_REQUESTS == 0)
                        slot_logical_onehot[update_slot] <=
                            (LOGICAL_TREE_NUM'(1) <<
                             allocation_plan_logical_id[
                                 sequential_capture_port]);
                    else
                        slot_logical_onehot[update_slot] <=
                            {LOGICAL_TREE_NUM{1'b0}};
                    slot_push_data[update_slot] <=
                        allocation_plan_push_data[
                            sequential_capture_port];
                    slot_order[update_slot] <=
                        allocation_plan_order[
                            sequential_capture_port];
                    slot_source_port[update_slot] <=
                        allocation_plan_source_port[
                            sequential_capture_port];
                    if (NATIVE_COMPOUND_REQUESTS != 0)
                        slot_merge_slots[update_slot] <= {DEPTH{1'b0}};
                    else
                        slot_merge_slots[update_slot] <=
                            allocation_commit_merge_slots[
                                sequential_capture_port];
                    if (NATIVE_COMPOUND_REQUESTS != 0) begin
                        native_next_valid[update_slot] <=
                            native_plan_next_valid[
                                sequential_capture_port];
                        native_next_slot[update_slot] <=
                            native_plan_next_slot[
                                sequential_capture_port];
                    end
                end

                // Capture the reciprocal provenance relation without
                // expanding registered lane identities into live slot IDs.
                // Lane-valid filtering happens during the following commit.
                for (plan_check_other_port = 0;
                     plan_check_other_port < REQUEST_PORTS;
                     plan_check_other_port =
                         plan_check_other_port + 1)
                    allocation_plan_merge_lane_mask[
                        sequential_capture_port][plan_check_other_port] <=
                        (NATIVE_COMPOUND_REQUESTS == 0) &&
                        i_req_merge_mask[sequential_capture_port]
                                        [plan_check_other_port] &&
                        i_req_merge_mask[plan_check_other_port]
                                        [sequential_capture_port];

                if (allocation_valid[sequential_capture_port]) begin
                    allocation_plan_push[
                        sequential_capture_port] <=
                        i_req_push[sequential_capture_port];
                    allocation_plan_pop[
                        sequential_capture_port] <=
                        (NATIVE_COMPOUND_REQUESTS != 0) ?
                            i_req_pop[sequential_capture_port] :
                            !i_req_push[sequential_capture_port];
                    allocation_plan_logical_id[
                        sequential_capture_port] <=
                        i_logical_tree_id[sequential_capture_port];
                    allocation_plan_push_data[
                        sequential_capture_port] <=
                        i_push_data[sequential_capture_port];
                    allocation_plan_order[
                        sequential_capture_port] <=
                        i_req_order[sequential_capture_port];
                    allocation_plan_source_port[
                        sequential_capture_port] <=
                        sequential_capture_port[
                            SOURCE_PORT_WIDTH-1:0];
                    allocation_plan_slot[
                        sequential_capture_port] <=
                        allocation_slot[sequential_capture_port];
                end else begin
                    allocation_plan_push[
                        sequential_capture_port] <= 1'b0;
                    allocation_plan_pop[
                        sequential_capture_port] <= 1'b0;
                    allocation_plan_logical_id[
                        sequential_capture_port] <=
                        {LOGICAL_ID_WIDTH{1'b0}};
                    allocation_plan_push_data[
                        sequential_capture_port] <=
                        {DATA_WIDTH{1'b0}};
                    allocation_plan_order[
                        sequential_capture_port] <=
                        {ORDER_WIDTH{1'b0}};
                    allocation_plan_source_port[
                        sequential_capture_port] <=
                        {SOURCE_PORT_WIDTH{1'b0}};
                    allocation_plan_slot[
                        sequential_capture_port] <=
                        {SLOT_ID_WIDTH{1'b0}};
                end
            end
        end
    end

endmodule
