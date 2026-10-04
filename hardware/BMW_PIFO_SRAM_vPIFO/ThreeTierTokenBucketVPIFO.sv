`timescale 1ns / 10ps

// Experiment integration for
//
//                         Root (SP)
//                       /     |     \
//                      F      X      Y
//                            WFQ    WFQ
//                           /  \    /  \
//                          D    E  C    Z (SP)
//                                    / \
//                                   A   B
//
// The shaped ingress enters through the independent timing domain.  The
// SHAPED_TARGET_NODE parameter selects the logical scheduling node that is
// admitted after release (the default experiment uses X; a node-level Y
// experiment uses the same path with SHAPED_TARGET_NODE=2).  All other
// traffic uses the direct scheduling path.  Scheduling Pop requests and
// direct Pushes retain priority over a due shaping release, matching
// ShapingReleaseToParent.
module ThreeTierTokenBucketVPIFO #(
    parameter PTW = 16,
    parameter MTW = 16,
    parameter CTW = 10,
    parameter TIME_WIDTH = 32,
    parameter SEQUENCE_WIDTH = 8,
    parameter integer SAFE_SEQUENCE_WRAP = 1,
    parameter TRANSACTION_FLOW_NUM = 1,
    parameter SCHEDULE_PENDING_DEPTH = 32,
    parameter SCHEDULE_POP_TRACK_DEPTH = 32,
    parameter TIMING_EVENT_TABLE_DEPTH = 32,
    parameter TIMING_RELEASE_FIFO_DEPTH = 16,
    parameter TIMING_PENDING_DEPTH = 10,
    parameter integer SPLIT_SHAPING = 0,
    parameter integer SHAPED_TARGET_NODE = 1,
    parameter integer SCHEDULE_TREE_ROOTS [0:0] = '{0},
    parameter integer SCHEDULE_NODE_PARENT [0:3] = '{0, 0, 0, 2},
    parameter integer SCHEDULE_NODE_DEPTH [0:3] = '{0, 1, 1, 2},
    parameter integer SCHEDULE_NODE_TREE_ID [0:3] = '{0, 0, 0, 0},
    parameter integer SCHEDULE_SHARD_COUNTS [0:3] = '{3, 1, 1, 1},
    parameter integer SCHEDULE_SHARD_OFFSETS [0:3] = '{0, 3, 4, 5},
    parameter integer SCHEDULE_EXPLICIT_SHARD_MAP [0:5] =
        '{0, 1, 2, 3, 4, 5},
    parameter integer TIMING_SHARD_COUNTS [0:0] = '{2},
    parameter integer TIMING_SHARD_OFFSETS [0:0] = '{0},
    parameter integer TIMING_EXPLICIT_SHARD_MAP [0:1] = '{0, 1},

    localparam SCHEDULE_LOGICAL_TREE_NUM = 4,
    localparam SCHEDULE_LOGICAL_ID_WIDTH = 2,
    localparam SCHEDULE_PHYSICAL_TREE_NUM = 6,
    localparam SCHEDULE_PHYSICAL_ID_WIDTH = 3,
    localparam SCHEDULE_SHARD_COUNT_WIDTH =
        (126 <= 1) ? 1 : $clog2(126 + 1),
    localparam SCHEDULE_DATA_WIDTH = MTW + PTW,
    localparam SCHEDULE_BUNDLE_WIDTH =
        SCHEDULE_DATA_WIDTH + SCHEDULE_LOGICAL_TREE_NUM * PTW,
    localparam TIMING_EVENT_DATA_WIDTH =
        SCHEDULE_LOGICAL_ID_WIDTH + SCHEDULE_BUNDLE_WIDTH,
    localparam FLOW_ID_WIDTH = (TRANSACTION_FLOW_NUM <= 1) ? 1 :
                               $clog2(TRANSACTION_FLOW_NUM),
    localparam TIMING_TABLE_COUNT_WIDTH =
        (TIMING_EVENT_TABLE_DEPTH <= 1) ? 1 :
        $clog2(TIMING_EVENT_TABLE_DEPTH + 1),
    localparam TIMING_RELEASE_COUNT_WIDTH =
        (TIMING_RELEASE_FIFO_DEPTH <= 1) ? 1 :
        $clog2(TIMING_RELEASE_FIFO_DEPTH + 1),
    localparam SCHEDULE_PENDING_COUNT_WIDTH =
        (SCHEDULE_PENDING_DEPTH <= 1) ? 1 :
        $clog2(SCHEDULE_PENDING_DEPTH + 1),
    localparam SCHEDULE_TRACK_COUNT_WIDTH =
        (SCHEDULE_POP_TRACK_DEPTH <= 1) ? 1 :
        $clog2(SCHEDULE_POP_TRACK_DEPTH + 1),
    localparam SCHEDULE_TOTAL_COUNT_WIDTH = $clog2(6 * 126 + 1)
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,
    input  wire [TIME_WIDTH-1:0]        i_time,

    // Token-Bucket configuration.  The program mode is fixed to mode 4.
    input  wire                         i_token_cfg_valid,
    output wire                         o_token_cfg_ready,
    input  wire [FLOW_ID_WIDTH-1:0]     i_token_cfg_flow_id,
    input  wire                         i_token_cfg_enable,
    input  wire [TIME_WIDTH-1:0]
                                        i_token_cfg_bucket_capacity_time,
    input  wire                         i_token_cfg_bucket_state_valid,
    input  wire [TIME_WIDTH-1:0]
                                        i_token_cfg_bucket_credit_time,
    input  wire [TIME_WIDTH-1:0]
                                        i_token_cfg_bucket_state_time,
    output wire                         o_token_cfg_reject_bad_flow_id,

    // Shaped ingress (historically named D in the first experiment).  Ranks
    // are computed by the scheduling transaction frontend and travel through
    // the timing event table unchanged.  One configured transaction context
    // can represent an aggregate logical node, as in the Y regression.
    input  wire                         i_d_valid,
    output wire                         o_d_ready,
    input  wire [FLOW_ID_WIDTH-1:0]     i_d_flow_id,
    input  wire [SCHEDULE_LOGICAL_ID_WIDTH-1:0]
                                        i_d_target_node_id,
    input  wire [TIME_WIDTH-1:0]        i_d_packet_service_time,
    input  wire [PTW-1:0]
        i_d_rank_by_node [0:SCHEDULE_LOGICAL_TREE_NUM-1],
    input  wire [SCHEDULE_DATA_WIDTH-1:0] i_d_packet_data,
    output wire                         o_d_transaction_fire,
    output wire [TIME_WIDTH-1:0]        o_d_eligibility_time,
    output wire                         o_d_reject_bad_flow_id,
    output wire                         o_d_reject_unconfigured,

    // Direct scheduling path for A/B/C/E/F (and for an optional D bypass
    // baseline).  The target node determines the path to Root.
    input  wire                         i_direct_valid,
    output wire                         o_direct_ready,
    input  wire [SCHEDULE_LOGICAL_ID_WIDTH-1:0]
                                        i_direct_target_node_id,
    input  wire [PTW-1:0]
        i_direct_rank_by_node [0:SCHEDULE_LOGICAL_TREE_NUM-1],
    input  wire [SCHEDULE_DATA_WIDTH-1:0] i_direct_packet_data,
    output wire                         o_direct_reject_bad_path,

    input  wire                         i_packet_pop_valid,
    output wire                         o_packet_pop_ready,
    output wire                         o_packet_out_valid,
    output wire [SCHEDULE_LOGICAL_ID_WIDTH-1:0]
                                        o_packet_out_node_id,
    output wire [SCHEDULE_DATA_WIDTH-1:0] o_packet_out_data,

    output wire                         o_shaping_to_schedule_fire,
    output wire                         o_direct_to_schedule_fire,
    output wire                         o_shaping_release_pending,
    output wire [TIME_WIDTH-1:0]        o_shaping_head_release_time,
    output wire                         o_shaping_deferred,
    output wire                         o_deferred_by_direct_push,
    output wire                         o_deferred_by_scheduling_pop,
    output wire                         o_deferred_by_schedule_backpressure,
    output reg [31:0]                   o_shaping_deferred_cycles,
    output reg [TIME_WIDTH-1:0]         o_release_delay_last,
    output reg [TIME_WIDTH-1:0]         o_release_delay_max,
    output wire [TIMING_TABLE_COUNT_WIDTH-1:0]
                                        o_timing_event_table_count,
    output wire [TIMING_RELEASE_COUNT_WIDTH-1:0]
                                        o_timing_release_fifo_count,
    output wire [SCHEDULE_TOTAL_COUNT_WIDTH-1:0]
        o_schedule_logical_count [0:SCHEDULE_LOGICAL_TREE_NUM-1],
    output wire [SCHEDULE_PENDING_COUNT_WIDTH-1:0]
                                        o_schedule_pending_count,
    output wire [SCHEDULE_TRACK_COUNT_WIDTH-1:0]
                                        o_schedule_outstanding_pop_count,
    output wire [SCHEDULE_LOGICAL_TREE_NUM-1:0]
        o_schedule_physical_dispatch_fire,
    output wire [SCHEDULE_LOGICAL_TREE_NUM-1:0]
        o_schedule_physical_dispatch_push,
    output wire [SCHEDULE_PHYSICAL_ID_WIDTH-1:0]
        o_schedule_selected_physical_tree_id
            [0:SCHEDULE_LOGICAL_TREE_NUM-1],
    output wire [SCHEDULE_SHARD_COUNT_WIDTH-1:0]
        o_schedule_shard_count [0:SCHEDULE_PHYSICAL_TREE_NUM-1],
    output wire                         o_timing_busy,
    output wire                         o_schedule_busy,
    output wire                         o_busy,
    output wire                         o_protocol_error
);

    // ------------------------------------------------------------------
    // Scheduling transaction bundle
    // ------------------------------------------------------------------
    wire [SCHEDULE_BUNDLE_WIDTH-1:0] d_schedule_bundle;
    wire [SCHEDULE_BUNDLE_WIDTH-1:0] direct_schedule_bundle;
    assign d_schedule_bundle[SCHEDULE_DATA_WIDTH-1:0] =
        i_d_packet_data;
    assign direct_schedule_bundle[SCHEDULE_DATA_WIDTH-1:0] =
        i_direct_packet_data;

    genvar bundle_node;
    generate
        for (bundle_node = 0;
             bundle_node < SCHEDULE_LOGICAL_TREE_NUM;
             bundle_node = bundle_node + 1) begin : pack_input_ranks
            assign d_schedule_bundle[
                SCHEDULE_DATA_WIDTH + bundle_node * PTW +: PTW] =
                    i_d_rank_by_node[bundle_node];
            assign direct_schedule_bundle[
                SCHEDULE_DATA_WIDTH + bundle_node * PTW +: PTW] =
                    i_direct_rank_by_node[bundle_node];
        end
    endgenerate

    wire [TIMING_EVENT_DATA_WIDTH-1:0] transaction_input_payload =
        {SHAPED_TARGET_NODE[SCHEDULE_LOGICAL_ID_WIDTH-1:0],
         d_schedule_bundle};

    // ------------------------------------------------------------------
    // Per-flow eligibility-time Token Bucket
    // ------------------------------------------------------------------
    wire transaction_event_valid;
    wire transaction_event_ready;
    wire timing_domain_event_valid;
    wire timing_domain_event_ready;
    wire [TIME_WIDTH-1:0] timing_domain_event_release_time;
    wire [TIMING_EVENT_DATA_WIDTH-1:0] timing_domain_event_payload;
    wire [TIME_WIDTH-1:0] transaction_event_release_time;
    wire [TIMING_EVENT_DATA_WIDTH-1:0] transaction_event_payload;
    wire transaction_engine_protocol_error;

    // A split transaction is first captured here, then issued to the local
    // scheduling subtree and finally to the timing PIFO.  This preserves the
    // enqueue-time Token-Bucket commit point without a cross-domain ready
    // combinational loop.
    reg split_transaction_pending;
    reg split_local_sent;
    reg [SCHEDULE_LOGICAL_ID_WIDTH-1:0] split_target_node;
    reg [SCHEDULE_BUNDLE_WIDTH-1:0] split_schedule_bundle;
    reg [TIME_WIDTH-1:0] split_release_time;
    reg [TIMING_EVENT_DATA_WIDTH-1:0] split_event_payload;

    ShapingTransactionEngine #(
        .TIME_WIDTH(TIME_WIDTH),
        .FLOW_NUM(TRANSACTION_FLOW_NUM),
        .PAYLOAD_WIDTH(TIMING_EVENT_DATA_WIDTH)
    ) transaction_engine (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_time(i_time),
        .i_cfg_valid(i_token_cfg_valid),
        .o_cfg_ready(o_token_cfg_ready),
        .i_cfg_flow_id(i_token_cfg_flow_id),
        .i_cfg_enable(i_token_cfg_enable),
        .i_cfg_mode(3'd4),
        .i_cfg_default_service_time({TIME_WIDTH{1'b0}}),
        .i_cfg_state_valid(1'b0),
        .i_cfg_next_release_time({TIME_WIDTH{1'b0}}),
        .i_cfg_bucket_capacity_time(
            i_token_cfg_bucket_capacity_time),
        .i_cfg_bucket_state_valid(i_token_cfg_bucket_state_valid),
        .i_cfg_bucket_credit_time(i_token_cfg_bucket_credit_time),
        .i_cfg_bucket_state_time(i_token_cfg_bucket_state_time),
        .o_cfg_reject_bad_flow_id(o_token_cfg_reject_bad_flow_id),
        .i_tx_valid(i_d_valid),
        .o_tx_ready(o_d_ready),
        .i_tx_flow_id(i_d_flow_id),
        .i_tx_context_valid(1'b1),
        .i_tx_packet_service_time(i_d_packet_service_time),
        .i_tx_absolute_release_time({TIME_WIDTH{1'b0}}),
        .i_tx_payload(transaction_input_payload),
        .o_tx_reject_bad_flow_id(o_d_reject_bad_flow_id),
        .o_tx_reject_unconfigured(o_d_reject_unconfigured),
        .o_tx_reject_bad_context(),
        .o_transaction_fire(o_d_transaction_fire),
        .o_transaction_release_time(o_d_eligibility_time),
        .o_transaction_next_release_time(),
        .o_transaction_bucket_credit_time(),
        .o_transaction_bucket_state_time(),
        .o_event_valid(transaction_event_valid),
        .i_event_ready(transaction_event_ready),
        .o_event_release_time(transaction_event_release_time),
        .o_event_payload(transaction_event_payload),
        .i_state_read_flow_id({FLOW_ID_WIDTH{1'b0}}),
        .o_state_read_configured(),
        .o_state_read_mode(),
        .o_state_read_default_service_time(),
        .o_state_read_valid(),
        .o_state_read_next_release_time(),
        .o_state_read_bucket_valid(),
        .o_state_read_bucket_capacity_time(),
        .o_state_read_bucket_credit_time(),
        .o_state_read_bucket_state_time(),
        .o_transaction_count(),
        .o_rejected_transaction_count(),
        .o_late_absolute_count(),
        .o_saturated_time_count(),
        .o_configured_flow_count(),
        .o_protocol_error(transaction_engine_protocol_error)
    );

    // ------------------------------------------------------------------
    // Independent timing BMW domain: one logical timing PIFO, two shards
    // ------------------------------------------------------------------
    localparam TIMING_LOGICAL_TREE_NUM = 1;
    localparam TIMING_PHYSICAL_TREE_NUM = 2;
    localparam TIMING_RANK_WIDTH = TIME_WIDTH + SEQUENCE_WIDTH;
    localparam TIMING_EVENT_ID_WIDTH =
        (TIMING_EVENT_TABLE_DEPTH <= 1) ? 1 :
        $clog2(TIMING_EVENT_TABLE_DEPTH);

    wire timing_release_valid;
    wire timing_release_ready;
    wire [TIMING_EVENT_ID_WIDTH-1:0] timing_release_event_id;
    wire [TIME_WIDTH-1:0] timing_release_time;
    wire [TIMING_EVENT_DATA_WIDTH-1:0] timing_release_data;
    wire timing_protocol_error;

    MultiLogicalShapingPIFO #(
        .TIME_WIDTH(TIME_WIDTH),
        .SEQUENCE_WIDTH(SEQUENCE_WIDTH),
        .SAFE_SEQUENCE_WRAP(SAFE_SEQUENCE_WRAP),
        .EVENT_DATA_WIDTH(TIMING_EVENT_DATA_WIDTH),
        .EVENT_TABLE_DEPTH(TIMING_EVENT_TABLE_DEPTH),
        .RELEASE_FIFO_DEPTH(TIMING_RELEASE_FIFO_DEPTH),
        .RELEASE_ISSUE_PORTS(1),
        .LEVEL(6),
        .LOGICAL_TREE_NUM(TIMING_LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(TIMING_PHYSICAL_TREE_NUM),
        .SHARD_CAPACITY(126),
        .MAX_SHARDS_PER_LOGICAL(2),
        .FIFO_SIZE(8),
        .TASK_ORDER_WIDTH(32),
        .LOGICAL_PENDING_DEPTH(TIMING_PENDING_DEPTH),
        .USE_EXPLICIT_SHARD_MAP(0),
        .SHARD_COUNTS(TIMING_SHARD_COUNTS),
        .SHARD_OFFSETS(TIMING_SHARD_OFFSETS),
        .EXPLICIT_SHARD_MAP(TIMING_EXPLICIT_SHARD_MAP)
    ) timing_domain (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_time(i_time),
        .i_event_valid(timing_domain_event_valid),
        .o_event_ready(timing_domain_event_ready),
        .i_event_logical_tree_id(1'b0),
        .i_event_release_time(timing_domain_event_release_time),
        .i_event_data(timing_domain_event_payload),
        .o_release_valid(timing_release_valid),
        .i_release_ready(timing_release_ready),
        .o_release_event_id(timing_release_event_id),
        .o_release_logical_tree_id(),
        .o_release_time(timing_release_time),
        .o_release_data(timing_release_data),
        .o_logical_head_valid(),
        .o_logical_head_rank(),
        .o_logical_head_physical_tree_id(),
        .o_release_reserved(),
        .o_completion_valid(),
        .o_due_issue_valid(),
        .o_due_capture_fire(),
        .o_due_issue_logical_tree_id(),
        .o_due_issue_physical_tree_id(),
        .o_due_issue_rank(),
        .o_due_issue_count(),
        .o_core_dispatch_fire(),
        .o_core_selected_physical_tree_id(),
        .o_logical_pending_count(),
        .o_logical_count(),
        .o_shard_count(),
        .o_shard_head_rank(),
        .o_shard_head_valid(),
        .o_shard_update_pending(),
        .o_event_table_count(o_timing_event_table_count),
        .o_release_fifo_count(o_timing_release_fifo_count),
        .o_busy(o_timing_busy),
        .o_protocol_error(timing_protocol_error)
    );

    wire [SCHEDULE_LOGICAL_ID_WIDTH-1:0] release_target_node =
        timing_release_data[TIMING_EVENT_DATA_WIDTH-1 -:
                            SCHEDULE_LOGICAL_ID_WIDTH];
    wire [SCHEDULE_BUNDLE_WIDTH-1:0] release_schedule_bundle =
        timing_release_data[SCHEDULE_BUNDLE_WIDTH-1:0];

    // ------------------------------------------------------------------
    // Scheduling-first admission and split shaping join
    // ------------------------------------------------------------------
    wire scheduler_push_valid;
    wire scheduler_push_ready;
    wire [SCHEDULE_LOGICAL_ID_WIDTH-1:0] scheduler_push_target;
    wire [SCHEDULE_BUNDLE_WIDTH-1:0] scheduler_push_bundle;
    wire [1:0] scheduler_push_mode;
    wire [SCHEDULE_LOGICAL_ID_WIDTH-1:0] scheduler_push_boundary;

    wire split_mode = SPLIT_SHAPING != 0;
    wire split_local_present = split_mode && split_transaction_pending &&
        !split_local_sent;
    wire split_local_selected = split_local_present && !i_direct_valid;
    wire release_selected = timing_release_valid && !i_direct_valid &&
        !split_local_present && !i_packet_pop_valid;

    wire split_capture_fire = split_mode && transaction_event_valid &&
        transaction_event_ready;
    wire split_local_fire = split_local_selected && scheduler_push_ready;
    wire split_timing_fire = split_mode && split_transaction_pending &&
        split_local_sent && timing_domain_event_ready;

    assign timing_domain_event_valid = split_mode ?
        (split_transaction_pending && split_local_sent) :
        transaction_event_valid;
    assign transaction_event_ready = split_mode ?
        !split_transaction_pending :
        timing_domain_event_ready;
    assign timing_domain_event_release_time = split_mode ?
        split_release_time : transaction_event_release_time;
    assign timing_domain_event_payload = split_mode ?
        split_event_payload : transaction_event_payload;

    assign scheduler_push_valid = i_direct_valid ||
        split_local_selected || release_selected;
    assign scheduler_push_target = i_direct_valid ?
        i_direct_target_node_id :
        (split_local_selected ? split_target_node : release_target_node);
    assign scheduler_push_bundle = i_direct_valid ?
        direct_schedule_bundle :
        (split_local_selected ? split_schedule_bundle :
                                release_schedule_bundle);
    assign scheduler_push_mode = i_direct_valid ? 2'd0 :
        (split_local_selected ? 2'd1 :
         (split_mode ? 2'd2 : 2'd0));
    assign scheduler_push_boundary = split_mode ?
        SHAPED_TARGET_NODE[SCHEDULE_LOGICAL_ID_WIDTH-1:0] :
        {SCHEDULE_LOGICAL_ID_WIDTH{1'b0}};

    assign o_direct_ready = scheduler_push_ready;
    assign timing_release_ready = release_selected &&
        scheduler_push_ready;
    assign o_direct_to_schedule_fire = i_direct_valid &&
        scheduler_push_ready;
    assign o_shaping_to_schedule_fire = timing_release_valid &&
        timing_release_ready;
    assign o_shaping_deferred = timing_release_valid &&
        !timing_release_ready;
    assign o_deferred_by_direct_push = timing_release_valid &&
        (i_direct_valid || split_local_present);
    assign o_deferred_by_scheduling_pop = timing_release_valid &&
        !i_direct_valid && !split_local_present && i_packet_pop_valid;
    assign o_deferred_by_schedule_backpressure = timing_release_valid &&
        !i_direct_valid && !split_local_present && !i_packet_pop_valid &&
        !scheduler_push_ready;

    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            split_transaction_pending <= 1'b0;
            split_local_sent <= 1'b0;
            split_target_node <=
                {SCHEDULE_LOGICAL_ID_WIDTH{1'b0}};
            split_schedule_bundle <= {SCHEDULE_BUNDLE_WIDTH{1'b0}};
            split_release_time <= {TIME_WIDTH{1'b0}};
            split_event_payload <= {TIMING_EVENT_DATA_WIDTH{1'b0}};
        end else begin
            if (split_capture_fire) begin
                split_transaction_pending <= 1'b1;
                split_local_sent <= 1'b0;
                split_target_node <= i_d_target_node_id;
                split_schedule_bundle <= d_schedule_bundle;
                split_release_time <= transaction_event_release_time;
                split_event_payload <= transaction_event_payload;
            end
            if (split_local_fire)
                split_local_sent <= 1'b1;
            if (split_timing_fire) begin
                split_transaction_pending <= 1'b0;
                split_local_sent <= 1'b0;
            end
        end
    end

    wire [SCHEDULE_DATA_WIDTH-1:0] scheduler_packet_data =
        scheduler_push_bundle[SCHEDULE_DATA_WIDTH-1:0];
    wire [PTW-1:0]
        scheduler_rank_by_node [0:SCHEDULE_LOGICAL_TREE_NUM-1];
    generate
        for (bundle_node = 0;
             bundle_node < SCHEDULE_LOGICAL_TREE_NUM;
             bundle_node = bundle_node + 1) begin : unpack_parent_ranks
            assign scheduler_rank_by_node[bundle_node] =
                scheduler_push_bundle[
                    SCHEDULE_DATA_WIDTH + bundle_node * PTW +: PTW];
        end
    endgenerate

    // ------------------------------------------------------------------
    // Shared heterogeneous scheduling domain, six physical M=2/L=6 shards
    // ------------------------------------------------------------------
    wire scheduler_protocol_error;
    RecursiveScheduleTreeHeterogeneousPIFO #(
        .PTW(PTW),
        .MTW(MTW),
        .CTW(CTW),
        .LEVEL(6),
        .LOGICAL_TREE_NUM(SCHEDULE_LOGICAL_TREE_NUM),
        .SEMANTIC_TREE_NUM(1),
        .PHYSICAL_TREE_NUM(6),
        .SHARD_CAPACITY(126),
        .FIFO_SIZE(8),
        .MAX_SHARDS_PER_LOGICAL(3),
        .MAX_TREE_DEPTH(3),
        .TASK_ORDER_WIDTH(32),
        .LOGICAL_PENDING_DEPTH(SCHEDULE_PENDING_DEPTH),
        .POP_RESULT_FIFO_DEPTH(12),
        .POP_TRACK_DEPTH(SCHEDULE_POP_TRACK_DEPTH),
        .USE_EXPLICIT_SHARD_MAP(0),
        .TREE_ROOTS(SCHEDULE_TREE_ROOTS),
        .NODE_PARENT(SCHEDULE_NODE_PARENT),
        .NODE_DEPTH(SCHEDULE_NODE_DEPTH),
        .NODE_TREE_ID(SCHEDULE_NODE_TREE_ID),
        .SHARD_COUNTS(SCHEDULE_SHARD_COUNTS),
        .SHARD_OFFSETS(SCHEDULE_SHARD_OFFSETS),
        .EXPLICIT_SHARD_MAP(SCHEDULE_EXPLICIT_SHARD_MAP)
    ) schedule_domain (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_push(scheduler_push_valid),
        .i_push_mode(scheduler_push_mode),
        .i_push_target_node_id(scheduler_push_target),
        .i_push_boundary_node_id(scheduler_push_boundary),
        .i_push_rank_by_node(scheduler_rank_by_node),
        .i_push_packet_data(scheduler_packet_data),
        .o_push_ready(scheduler_push_ready),
        .o_reject_bad_push_path(o_direct_reject_bad_path),
        .i_pop(i_packet_pop_valid),
        .i_pop_semantic_tree_id(1'b0),
        .o_pop_ready(o_packet_pop_ready),
        .o_reject_bad_tree_id(),
        .o_pop_out(o_packet_out_valid),
        .o_pop_semantic_tree_id(),
        .o_pop_packet_node_id(o_packet_out_node_id),
        .o_pop_data(o_packet_out_data),
        .o_busy(o_schedule_busy),
        .o_protocol_error(scheduler_protocol_error),
        .o_outstanding_pop_count(
            o_schedule_outstanding_pop_count),
        .o_pending_count(o_schedule_pending_count),
        .o_logical_count(o_schedule_logical_count),
        .o_physical_dispatch_fire(o_schedule_physical_dispatch_fire),
        .o_physical_dispatch_push(o_schedule_physical_dispatch_push),
        .o_selected_physical_tree_id(
            o_schedule_selected_physical_tree_id),
        .o_physical_shard_count(o_schedule_shard_count)
    );

    assign o_shaping_release_pending = timing_release_valid;
    assign o_shaping_head_release_time = timing_release_time;
    wire [TIME_WIDTH-1:0] current_release_delay =
        i_time - timing_release_time;
    reg local_protocol_error;
    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            o_shaping_deferred_cycles <= 32'b0;
            o_release_delay_last <= {TIME_WIDTH{1'b0}};
            o_release_delay_max <= {TIME_WIDTH{1'b0}};
            local_protocol_error <= 1'b0;
        end else begin
            if (o_shaping_deferred)
                o_shaping_deferred_cycles <=
                    o_shaping_deferred_cycles + 1'b1;
            if (o_shaping_to_schedule_fire) begin
                if ((i_time < timing_release_time) ||
                    (int'(release_target_node) != SHAPED_TARGET_NODE))
                    local_protocol_error <= 1'b1;
                o_release_delay_last <= current_release_delay;
                if (current_release_delay > o_release_delay_max)
                    o_release_delay_max <= current_release_delay;
            end
        end
    end

    assign o_busy = o_timing_busy || o_schedule_busy ||
        split_transaction_pending;
    assign o_protocol_error = local_protocol_error ||
        transaction_engine_protocol_error || timing_protocol_error ||
        scheduler_protocol_error;

    initial begin
        if (((SPLIT_SHAPING != 0) && (SHAPED_TARGET_NODE == 0)) ||
            (SHAPED_TARGET_NODE < 0) ||
            (SHAPED_TARGET_NODE >= SCHEDULE_LOGICAL_TREE_NUM) ||
            (SCHEDULE_NODE_PARENT[SHAPED_TARGET_NODE] ==
             SHAPED_TARGET_NODE))
            $fatal(1, "invalid shaping target node");
    end

endmodule
