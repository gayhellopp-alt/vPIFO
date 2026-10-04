`timescale 1ns / 10ps

// Stage-5 integration: a stateful shaping transaction frontend feeding the
// Stage-4.5 heterogeneous timing PIFO and Stage-28 scheduling hierarchy.
// Existing direct scheduling traffic keeps the strict priority implemented by
// ShapingReleaseToParent; this wrapper changes only how release_time is made.
module NonWorkConservingPIFOStage5 #(
    parameter PTW = 16,
    parameter MTW = 16,
    parameter CTW = 10,
    parameter SCHEDULER_LEVEL = VpifoConfigPkg::LEVEL,
    parameter SCHEDULER_LOGICAL_TREE_NUM =
        VpifoConfigPkg::LOGICAL_TREE_NUM,
    parameter SCHEDULER_SEMANTIC_TREE_NUM = 1,
    parameter SCHEDULER_FOREST_MODE = 0,
    parameter SCHEDULER_PHYSICAL_TREE_NUM =
        VpifoConfigPkg::PHYSICAL_TREE_NUM,
    parameter SCHEDULER_SHARD_CAPACITY =
        VpifoConfigPkg::SHARD_CAPACITY,
    parameter SCHEDULER_FIFO_SIZE = 8,
    parameter SCHEDULER_MAX_SHARDS_PER_LOGICAL =
        VpifoConfigPkg::MAX_SHARDS_PER_LOGICAL,
    parameter SCHEDULER_POP_RESULT_FIFO_DEPTH =
        SCHEDULER_LOGICAL_TREE_NUM + SCHEDULER_LEVEL,
    parameter SCHEDULER_TASK_ORDER_WIDTH = 32,
    parameter SCHEDULER_LEAF_ROUTE_QUEUE_DEPTH =
        SCHEDULER_FIFO_SIZE,
    parameter SCHEDULER_LOGICAL_PENDING_DEPTH =
        SCHEDULER_LOGICAL_TREE_NUM + 3 + SCHEDULER_FIFO_SIZE,
    parameter integer SCHEDULER_USE_EXPLICIT_SHARD_MAP =
        VpifoConfigPkg::USE_EXPLICIT_SHARD_MAP,
    parameter integer SCHEDULER_SHARD_COUNTS
        [0:SCHEDULER_LOGICAL_TREE_NUM-1] =
        VpifoConfigPkg::SHARD_COUNTS,
    parameter integer SCHEDULER_SHARD_OFFSETS
        [0:SCHEDULER_LOGICAL_TREE_NUM-1] =
        VpifoConfigPkg::SHARD_OFFSETS,
    parameter integer SCHEDULER_EXPLICIT_SHARD_MAP
        [0:SCHEDULER_PHYSICAL_TREE_NUM-1] =
        VpifoConfigPkg::EXPLICIT_SHARD_MAP,
    parameter integer SCHEDULER_TREE_ROOTS
        [0:SCHEDULER_SEMANTIC_TREE_NUM-1] = '{default:0},
    parameter integer SCHEDULER_NODE_PARENT
        [0:SCHEDULER_LOGICAL_TREE_NUM-1] = '{default:0},
    parameter integer SCHEDULER_NODE_TREE_ID
        [0:SCHEDULER_LOGICAL_TREE_NUM-1] = '{default:0},
    parameter integer SCHEDULER_NODE_IS_ROOT
        [0:SCHEDULER_LOGICAL_TREE_NUM-1] = '{default:0},

    parameter TIME_WIDTH = 16,
    parameter TRANSACTION_FLOW_NUM = 16,
    parameter SEQUENCE_WIDTH = 8,
    parameter SHAPING_EVENT_TABLE_DEPTH = 16,
    parameter SHAPING_RELEASE_FIFO_DEPTH = 8,
    parameter SHAPING_RELEASE_ISSUE_PORTS = 2,
    parameter SHAPING_LEVEL = 4,
    parameter SHAPING_LOGICAL_TREE_NUM = 1,
    parameter SHAPING_PHYSICAL_TREE_NUM = 2,
    parameter SHAPING_SHARD_CAPACITY = 30,
    parameter SHAPING_MAX_SHARDS_PER_LOGICAL = 2,
    parameter SHAPING_FIFO_SIZE = 8,
    parameter SHAPING_TASK_ORDER_WIDTH = 32,
    parameter SHAPING_LOGICAL_PENDING_DEPTH =
        SHAPING_RELEASE_ISSUE_PORTS + SHAPING_FIFO_SIZE + 1,
    parameter SHAPING_HEAD_SUMMARY_REGISTERED = 1,
    parameter integer SHAPING_USE_EXPLICIT_SHARD_MAP = 0,
    parameter integer SHAPING_SHARD_COUNTS
        [0:SHAPING_LOGICAL_TREE_NUM-1] = '{default:2},
    parameter integer SHAPING_SHARD_OFFSETS
        [0:SHAPING_LOGICAL_TREE_NUM-1] = '{default:0},
    parameter integer SHAPING_EXPLICIT_SHARD_MAP
        [0:SHAPING_PHYSICAL_TREE_NUM-1] = '{default:0},

    localparam SCHEDULER_LOGICAL_ID_WIDTH =
        (SCHEDULER_LOGICAL_TREE_NUM <= 1) ? 1 :
        $clog2(SCHEDULER_LOGICAL_TREE_NUM),
    localparam SCHEDULER_SEMANTIC_TREE_ID_WIDTH =
        (SCHEDULER_SEMANTIC_TREE_NUM <= 1) ? 1 :
        $clog2(SCHEDULER_SEMANTIC_TREE_NUM),
    localparam SCHEDULER_DATA_WIDTH = MTW + PTW,
    localparam SCHEDULER_TOTAL_COUNT_WIDTH =
        (SCHEDULER_PHYSICAL_TREE_NUM * SCHEDULER_SHARD_CAPACITY <= 1) ?
        1 : $clog2(SCHEDULER_PHYSICAL_TREE_NUM *
                   SCHEDULER_SHARD_CAPACITY + 1),
    localparam SCHEDULER_PENDING_COUNT_WIDTH =
        (SCHEDULER_LOGICAL_PENDING_DEPTH <= 1) ? 1 :
        $clog2(SCHEDULER_LOGICAL_PENDING_DEPTH + 1),
    localparam SHAPING_LOGICAL_ID_WIDTH =
        (SHAPING_LOGICAL_TREE_NUM <= 1) ? 1 :
        $clog2(SHAPING_LOGICAL_TREE_NUM),
    localparam SHAPING_TABLE_COUNT_WIDTH =
        (SHAPING_EVENT_TABLE_DEPTH <= 1) ? 1 :
        $clog2(SHAPING_EVENT_TABLE_DEPTH + 1),
    localparam SHAPING_RELEASE_COUNT_WIDTH =
        (SHAPING_RELEASE_FIFO_DEPTH <= 1) ? 1 :
        $clog2(SHAPING_RELEASE_FIFO_DEPTH + 1),
    localparam SHAPING_PENDING_COUNT_WIDTH =
        (SHAPING_LOGICAL_PENDING_DEPTH <= 1) ? 1 :
        $clog2(SHAPING_LOGICAL_PENDING_DEPTH + 1),
    localparam SHAPING_TOTAL_COUNT_WIDTH =
        (SHAPING_PHYSICAL_TREE_NUM * SHAPING_SHARD_CAPACITY <= 1) ?
        1 : $clog2(SHAPING_PHYSICAL_TREE_NUM *
                   SHAPING_SHARD_CAPACITY + 1),
    localparam TRANSACTION_FLOW_ID_WIDTH =
        (TRANSACTION_FLOW_NUM <= 1) ? 1 :
        $clog2(TRANSACTION_FLOW_NUM),
    localparam TRANSACTION_CONFIGURED_COUNT_WIDTH =
        (TRANSACTION_FLOW_NUM <= 1) ? 1 :
        $clog2(TRANSACTION_FLOW_NUM + 1),
    localparam TRANSACTION_PAYLOAD_WIDTH =
        SHAPING_LOGICAL_ID_WIDTH + SCHEDULER_LOGICAL_ID_WIDTH +
        PTW + SCHEDULER_DATA_WIDTH
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,
    input  wire [TIME_WIDTH-1:0]        i_time,

    input  wire                         i_transaction_cfg_valid,
    output wire                         o_transaction_cfg_ready,
    input  wire [TRANSACTION_FLOW_ID_WIDTH-1:0]
                                        i_transaction_cfg_flow_id,
    input  wire                         i_transaction_cfg_enable,
    input  wire [2:0]                   i_transaction_cfg_mode,
    input  wire [TIME_WIDTH-1:0]
                                        i_transaction_cfg_default_service_time,
    input  wire                         i_transaction_cfg_state_valid,
    input  wire [TIME_WIDTH-1:0]
                                        i_transaction_cfg_next_release_time,
    input  wire [TIME_WIDTH-1:0]
                                        i_transaction_cfg_bucket_capacity_time,
    input  wire                         i_transaction_cfg_bucket_state_valid,
    input  wire [TIME_WIDTH-1:0]
                                        i_transaction_cfg_bucket_credit_time,
    input  wire [TIME_WIDTH-1:0]
                                        i_transaction_cfg_bucket_state_time,
    output wire                         o_transaction_cfg_reject_bad_flow_id,

    input  wire                         i_transaction_valid,
    output wire                         o_transaction_ready,
    input  wire [TRANSACTION_FLOW_ID_WIDTH-1:0]
                                        i_transaction_flow_id,
    input  wire [SHAPING_LOGICAL_ID_WIDTH-1:0]
                                        i_transaction_shaping_logical_tree_id,
    input  wire [TIME_WIDTH-1:0]
                                        i_transaction_packet_service_time,
    input  wire [TIME_WIDTH-1:0]
                                        i_transaction_absolute_release_time,
    input  wire [SCHEDULER_LOGICAL_ID_WIDTH-1:0]
                                        i_transaction_parent_leaf_tree_id,
    input  wire [PTW-1:0]               i_transaction_parent_priority,
    input  wire [SCHEDULER_DATA_WIDTH-1:0]
                                        i_transaction_packet_data,
    output wire                         o_transaction_reject_bad_flow_id,
    output wire                         o_transaction_reject_unconfigured,
    output wire                         o_transaction_reject_bad_route,
    output wire                         o_transaction_fire,
    output wire [TIME_WIDTH-1:0]        o_transaction_release_time,
    output wire [TIME_WIDTH-1:0]
                                        o_transaction_next_release_time,
    output wire [TIME_WIDTH-1:0]
                                        o_transaction_bucket_credit_time,
    output wire [TIME_WIDTH-1:0]
                                        o_transaction_bucket_state_time,

    input  wire [TRANSACTION_FLOW_ID_WIDTH-1:0]
                                        i_transaction_state_read_flow_id,
    output wire                         o_transaction_state_read_configured,
    output wire [2:0]                   o_transaction_state_read_mode,
    output wire [TIME_WIDTH-1:0]
        o_transaction_state_read_default_service_time,
    output wire                         o_transaction_state_read_valid,
    output wire [TIME_WIDTH-1:0]
        o_transaction_state_read_next_release_time,
    output wire                         o_transaction_state_read_bucket_valid,
    output wire [TIME_WIDTH-1:0]
        o_transaction_state_read_bucket_capacity_time,
    output wire [TIME_WIDTH-1:0]
        o_transaction_state_read_bucket_credit_time,
    output wire [TIME_WIDTH-1:0]
        o_transaction_state_read_bucket_state_time,
    output wire [31:0]                  o_transaction_count,
    output wire [31:0]                  o_rejected_transaction_count,
    output wire [31:0]                  o_late_absolute_count,
    output wire [31:0]                  o_saturated_time_count,
    output wire [TRANSACTION_CONFIGURED_COUNT_WIDTH-1:0]
                                        o_configured_flow_count,

    input  wire                         i_direct_push_valid,
    output wire                         o_direct_push_ready,
    input  wire [SCHEDULER_LOGICAL_ID_WIDTH-1:0]
                                        i_direct_leaf_tree_id,
    input  wire [PTW-1:0]               i_direct_priority,
    input  wire [SCHEDULER_DATA_WIDTH-1:0]
                                        i_direct_packet_data,
    output wire                         o_direct_reject_bad_leaf_id,

    input  wire                         i_packet_pop_valid,
    input  wire [SCHEDULER_SEMANTIC_TREE_ID_WIDTH-1:0]
                                        i_packet_pop_semantic_tree_id,
    output wire                         o_packet_pop_ready,
    output wire                         o_packet_out_valid,
    output wire [SCHEDULER_SEMANTIC_TREE_ID_WIDTH-1:0]
                                        o_packet_out_semantic_tree_id,
    output wire [SCHEDULER_LOGICAL_ID_WIDTH-1:0]
                                        o_packet_out_leaf_tree_id,
    output wire [SCHEDULER_DATA_WIDTH-1:0]
                                        o_packet_out_data,

    output wire                         o_shaping_to_parent_fire,
    output wire                         o_direct_to_parent_fire,
    output wire                         o_shaping_release_pending,
    output wire                         o_shaping_deferred,
    output wire                         o_deferred_by_direct_push,
    output wire                         o_deferred_by_scheduling_pop,
    output wire                         o_deferred_by_parent_backpressure,
    output wire [31:0]                  o_shaping_deferred_cycles,
    output wire [TIME_WIDTH-1:0]        o_release_delay_last,
    output wire [TIME_WIDTH-1:0]        o_release_delay_max,
    output wire [SHAPING_TABLE_COUNT_WIDTH-1:0]
                                        o_shaping_event_table_count,
    output wire [SHAPING_RELEASE_COUNT_WIDTH-1:0]
                                        o_shaping_release_fifo_count,
    output wire [SHAPING_TOTAL_COUNT_WIDTH-1:0]
        o_shaping_logical_count [0:SHAPING_LOGICAL_TREE_NUM-1],
    output wire [SHAPING_PENDING_COUNT_WIDTH-1:0]
        o_shaping_logical_pending_count [0:SHAPING_LOGICAL_TREE_NUM-1],
    output wire [SCHEDULER_TOTAL_COUNT_WIDTH-1:0]
        o_scheduler_logical_count [0:SCHEDULER_LOGICAL_TREE_NUM-1],
    output wire [SCHEDULER_PENDING_COUNT_WIDTH-1:0]
                                        o_scheduler_pending_count,
    output wire                         o_shaping_busy,
    output wire                         o_scheduler_busy,
    output wire                         o_busy,
    output wire                         o_protocol_error
);

    localparam [SCHEDULER_LOGICAL_ID_WIDTH-1:0] SCHEDULER_ROOT_ID =
        {SCHEDULER_LOGICAL_ID_WIDTH{1'b0}};

    wire shaping_route_id_valid =
        int'(i_transaction_shaping_logical_tree_id) <
        SHAPING_LOGICAL_TREE_NUM;
    reg parent_route_id_valid;
    always @* begin
        parent_route_id_valid = 1'b0;
        if (int'(i_transaction_parent_leaf_tree_id) <
            SCHEDULER_LOGICAL_TREE_NUM) begin
            if (SCHEDULER_FOREST_MODE != 0)
                parent_route_id_valid =
                    SCHEDULER_NODE_IS_ROOT[
                        int'(i_transaction_parent_leaf_tree_id)] == 0;
            else
                parent_route_id_valid =
                    i_transaction_parent_leaf_tree_id !=
                    SCHEDULER_ROOT_ID;
        end
    end
    wire transaction_route_valid = shaping_route_id_valid &&
        parent_route_id_valid;

    wire [TRANSACTION_PAYLOAD_WIDTH-1:0] transaction_input_payload = {
        i_transaction_shaping_logical_tree_id,
        i_transaction_parent_leaf_tree_id,
        i_transaction_parent_priority,
        i_transaction_packet_data
    };
    wire transaction_event_valid;
    wire transaction_event_ready;
    wire [TIME_WIDTH-1:0] transaction_event_release_time;
    wire [TRANSACTION_PAYLOAD_WIDTH-1:0] transaction_event_payload;
    wire transaction_protocol_error;

    ShapingTransactionEngine #(
        .TIME_WIDTH(TIME_WIDTH),
        .FLOW_NUM(TRANSACTION_FLOW_NUM),
        .PAYLOAD_WIDTH(TRANSACTION_PAYLOAD_WIDTH)
    ) transaction_engine (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_time(i_time),
        .i_cfg_valid(i_transaction_cfg_valid),
        .o_cfg_ready(o_transaction_cfg_ready),
        .i_cfg_flow_id(i_transaction_cfg_flow_id),
        .i_cfg_enable(i_transaction_cfg_enable),
        .i_cfg_mode(i_transaction_cfg_mode),
        .i_cfg_default_service_time(
            i_transaction_cfg_default_service_time),
        .i_cfg_state_valid(i_transaction_cfg_state_valid),
        .i_cfg_next_release_time(
            i_transaction_cfg_next_release_time),
        .i_cfg_bucket_capacity_time(
            i_transaction_cfg_bucket_capacity_time),
        .i_cfg_bucket_state_valid(
            i_transaction_cfg_bucket_state_valid),
        .i_cfg_bucket_credit_time(
            i_transaction_cfg_bucket_credit_time),
        .i_cfg_bucket_state_time(
            i_transaction_cfg_bucket_state_time),
        .o_cfg_reject_bad_flow_id(
            o_transaction_cfg_reject_bad_flow_id),
        .i_tx_valid(i_transaction_valid),
        .o_tx_ready(o_transaction_ready),
        .i_tx_flow_id(i_transaction_flow_id),
        .i_tx_context_valid(transaction_route_valid),
        .i_tx_packet_service_time(
            i_transaction_packet_service_time),
        .i_tx_absolute_release_time(
            i_transaction_absolute_release_time),
        .i_tx_payload(transaction_input_payload),
        .o_tx_reject_bad_flow_id(
            o_transaction_reject_bad_flow_id),
        .o_tx_reject_unconfigured(
            o_transaction_reject_unconfigured),
        .o_tx_reject_bad_context(o_transaction_reject_bad_route),
        .o_transaction_fire(o_transaction_fire),
        .o_transaction_release_time(o_transaction_release_time),
        .o_transaction_next_release_time(
            o_transaction_next_release_time),
        .o_transaction_bucket_credit_time(
            o_transaction_bucket_credit_time),
        .o_transaction_bucket_state_time(
            o_transaction_bucket_state_time),
        .o_event_valid(transaction_event_valid),
        .i_event_ready(transaction_event_ready),
        .o_event_release_time(transaction_event_release_time),
        .o_event_payload(transaction_event_payload),
        .i_state_read_flow_id(i_transaction_state_read_flow_id),
        .o_state_read_configured(
            o_transaction_state_read_configured),
        .o_state_read_mode(o_transaction_state_read_mode),
        .o_state_read_default_service_time(
            o_transaction_state_read_default_service_time),
        .o_state_read_valid(o_transaction_state_read_valid),
        .o_state_read_next_release_time(
            o_transaction_state_read_next_release_time),
        .o_state_read_bucket_valid(
            o_transaction_state_read_bucket_valid),
        .o_state_read_bucket_capacity_time(
            o_transaction_state_read_bucket_capacity_time),
        .o_state_read_bucket_credit_time(
            o_transaction_state_read_bucket_credit_time),
        .o_state_read_bucket_state_time(
            o_transaction_state_read_bucket_state_time),
        .o_transaction_count(o_transaction_count),
        .o_rejected_transaction_count(
            o_rejected_transaction_count),
        .o_late_absolute_count(o_late_absolute_count),
        .o_saturated_time_count(o_saturated_time_count),
        .o_configured_flow_count(o_configured_flow_count),
        .o_protocol_error(transaction_protocol_error)
    );

    wire [SHAPING_LOGICAL_ID_WIDTH-1:0]
        transaction_shaping_logical_tree_id =
            transaction_event_payload[TRANSACTION_PAYLOAD_WIDTH-1 -:
                                      SHAPING_LOGICAL_ID_WIDTH];
    wire [SCHEDULER_LOGICAL_ID_WIDTH-1:0]
        transaction_parent_leaf_tree_id =
            transaction_event_payload[
                SCHEDULER_DATA_WIDTH + PTW +:
                SCHEDULER_LOGICAL_ID_WIDTH];
    wire [PTW-1:0] transaction_parent_priority =
        transaction_event_payload[SCHEDULER_DATA_WIDTH +: PTW];
    wire [SCHEDULER_DATA_WIDTH-1:0] transaction_packet_data =
        transaction_event_payload[SCHEDULER_DATA_WIDTH-1:0];

    wire stage45_protocol_error;
    wire stage45_shaping_reject_bad_id;
    wire [SHAPING_LOGICAL_TREE_NUM-1:0] unused_release_reserved;
    wire [SHAPING_LOGICAL_TREE_NUM-1:0] unused_completion_valid;
    wire [SHAPING_RELEASE_ISSUE_PORTS-1:0] unused_due_issue_valid;
    wire [SHAPING_RELEASE_ISSUE_PORTS-1:0] unused_due_capture_fire;

    NonWorkConservingPIFOStage45 #(
        .PTW(PTW),
        .MTW(MTW),
        .CTW(CTW),
        .SCHEDULER_LEVEL(SCHEDULER_LEVEL),
        .SCHEDULER_LOGICAL_TREE_NUM(SCHEDULER_LOGICAL_TREE_NUM),
        .SCHEDULER_SEMANTIC_TREE_NUM(
            SCHEDULER_SEMANTIC_TREE_NUM),
        .SCHEDULER_FOREST_MODE(SCHEDULER_FOREST_MODE),
        .SCHEDULER_PHYSICAL_TREE_NUM(SCHEDULER_PHYSICAL_TREE_NUM),
        .SCHEDULER_SHARD_CAPACITY(SCHEDULER_SHARD_CAPACITY),
        .SCHEDULER_FIFO_SIZE(SCHEDULER_FIFO_SIZE),
        .SCHEDULER_MAX_SHARDS_PER_LOGICAL(
            SCHEDULER_MAX_SHARDS_PER_LOGICAL),
        .SCHEDULER_POP_RESULT_FIFO_DEPTH(
            SCHEDULER_POP_RESULT_FIFO_DEPTH),
        .SCHEDULER_TASK_ORDER_WIDTH(SCHEDULER_TASK_ORDER_WIDTH),
        .SCHEDULER_LEAF_ROUTE_QUEUE_DEPTH(
            SCHEDULER_LEAF_ROUTE_QUEUE_DEPTH),
        .SCHEDULER_LOGICAL_PENDING_DEPTH(
            SCHEDULER_LOGICAL_PENDING_DEPTH),
        .SCHEDULER_USE_EXPLICIT_SHARD_MAP(
            SCHEDULER_USE_EXPLICIT_SHARD_MAP),
        .SCHEDULER_SHARD_COUNTS(SCHEDULER_SHARD_COUNTS),
        .SCHEDULER_SHARD_OFFSETS(SCHEDULER_SHARD_OFFSETS),
        .SCHEDULER_EXPLICIT_SHARD_MAP(
            SCHEDULER_EXPLICIT_SHARD_MAP),
        .SCHEDULER_TREE_ROOTS(SCHEDULER_TREE_ROOTS),
        .SCHEDULER_NODE_PARENT(SCHEDULER_NODE_PARENT),
        .SCHEDULER_NODE_TREE_ID(SCHEDULER_NODE_TREE_ID),
        .SCHEDULER_NODE_IS_ROOT(SCHEDULER_NODE_IS_ROOT),
        .TIME_WIDTH(TIME_WIDTH),
        .SEQUENCE_WIDTH(SEQUENCE_WIDTH),
        .SHAPING_EVENT_TABLE_DEPTH(SHAPING_EVENT_TABLE_DEPTH),
        .SHAPING_RELEASE_FIFO_DEPTH(SHAPING_RELEASE_FIFO_DEPTH),
        .SHAPING_RELEASE_ISSUE_PORTS(SHAPING_RELEASE_ISSUE_PORTS),
        .SHAPING_LEVEL(SHAPING_LEVEL),
        .SHAPING_LOGICAL_TREE_NUM(SHAPING_LOGICAL_TREE_NUM),
        .SHAPING_PHYSICAL_TREE_NUM(SHAPING_PHYSICAL_TREE_NUM),
        .SHAPING_SHARD_CAPACITY(SHAPING_SHARD_CAPACITY),
        .SHAPING_MAX_SHARDS_PER_LOGICAL(
            SHAPING_MAX_SHARDS_PER_LOGICAL),
        .SHAPING_FIFO_SIZE(SHAPING_FIFO_SIZE),
        .SHAPING_TASK_ORDER_WIDTH(SHAPING_TASK_ORDER_WIDTH),
        .SHAPING_LOGICAL_PENDING_DEPTH(
            SHAPING_LOGICAL_PENDING_DEPTH),
        .SHAPING_HEAD_SUMMARY_REGISTERED(
            SHAPING_HEAD_SUMMARY_REGISTERED),
        .SHAPING_USE_EXPLICIT_SHARD_MAP(
            SHAPING_USE_EXPLICIT_SHARD_MAP),
        .SHAPING_SHARD_COUNTS(SHAPING_SHARD_COUNTS),
        .SHAPING_SHARD_OFFSETS(SHAPING_SHARD_OFFSETS),
        .SHAPING_EXPLICIT_SHARD_MAP(SHAPING_EXPLICIT_SHARD_MAP)
    ) stage45 (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_time(i_time),
        .i_shaping_event_valid(transaction_event_valid),
        .o_shaping_event_ready(transaction_event_ready),
        .i_shaping_logical_tree_id(
            transaction_shaping_logical_tree_id),
        .i_shaping_release_time(transaction_event_release_time),
        .i_shaping_parent_leaf_tree_id(
            transaction_parent_leaf_tree_id),
        .i_shaping_parent_priority(transaction_parent_priority),
        .i_shaping_packet_data(transaction_packet_data),
        .o_shaping_reject_bad_id(stage45_shaping_reject_bad_id),
        .i_direct_push_valid(i_direct_push_valid),
        .o_direct_push_ready(o_direct_push_ready),
        .i_direct_leaf_tree_id(i_direct_leaf_tree_id),
        .i_direct_priority(i_direct_priority),
        .i_direct_packet_data(i_direct_packet_data),
        .o_direct_reject_bad_leaf_id(o_direct_reject_bad_leaf_id),
        .i_packet_pop_valid(i_packet_pop_valid),
        .i_packet_pop_semantic_tree_id(
            i_packet_pop_semantic_tree_id),
        .o_packet_pop_ready(o_packet_pop_ready),
        .o_packet_out_valid(o_packet_out_valid),
        .o_packet_out_semantic_tree_id(
            o_packet_out_semantic_tree_id),
        .o_packet_out_leaf_tree_id(o_packet_out_leaf_tree_id),
        .o_packet_out_data(o_packet_out_data),
        .o_shaping_to_parent_fire(o_shaping_to_parent_fire),
        .o_direct_to_parent_fire(o_direct_to_parent_fire),
        .o_shaping_release_pending(o_shaping_release_pending),
        .o_shaping_deferred(o_shaping_deferred),
        .o_deferred_by_direct_push(o_deferred_by_direct_push),
        .o_deferred_by_scheduling_pop(
            o_deferred_by_scheduling_pop),
        .o_deferred_by_parent_backpressure(
            o_deferred_by_parent_backpressure),
        .o_shaping_deferred_cycles(o_shaping_deferred_cycles),
        .o_release_delay_last(o_release_delay_last),
        .o_release_delay_max(o_release_delay_max),
        .o_shaping_event_table_count(o_shaping_event_table_count),
        .o_shaping_release_fifo_count(o_shaping_release_fifo_count),
        .o_shaping_release_reserved(unused_release_reserved),
        .o_shaping_completion_valid(unused_completion_valid),
        .o_shaping_due_issue_valid(unused_due_issue_valid),
        .o_shaping_due_capture_fire(unused_due_capture_fire),
        .o_shaping_due_issue_count(),
        .o_shaping_logical_count(o_shaping_logical_count),
        .o_shaping_logical_pending_count(
            o_shaping_logical_pending_count),
        .o_scheduler_logical_count(o_scheduler_logical_count),
        .o_scheduler_pending_count(o_scheduler_pending_count),
        .o_shaping_busy(o_shaping_busy),
        .o_scheduler_busy(o_scheduler_busy),
        .o_busy(o_busy),
        .o_protocol_error(stage45_protocol_error)
    );

    assign o_protocol_error = transaction_protocol_error ||
        stage45_protocol_error || stage45_shaping_reject_bad_id;

    initial begin
        if ((TRANSACTION_FLOW_NUM < 1) ||
            (SCHEDULER_LOGICAL_TREE_NUM < 2) ||
            (SCHEDULER_SEMANTIC_TREE_NUM < 1) ||
            (SHAPING_LOGICAL_TREE_NUM < 1))
            $fatal(1, "NonWorkConservingPIFOStage5 parameters invalid");
    end

endmodule
