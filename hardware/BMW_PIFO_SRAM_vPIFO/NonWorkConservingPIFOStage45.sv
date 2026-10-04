`timescale 1ns / 10ps

// Stage 4.5 non-work-conserving integration for the Stage-28 scheduler.
//
// Shaping events are ordered by {release_time, insertion_sequence} in a
// separate heterogeneous BMW-PIFO.  A timer Pop reserves release-FIFO credit
// before it is sent to the non-backpressurable BMW pipeline.  Completed events
// are restored to global release order, then admitted to the packet scheduler
// only when no direct scheduling Push or external scheduling Pop is present.
module NonWorkConservingPIFOStage45 #(
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
    parameter SEQUENCE_WIDTH = 8,
    parameter SHAPING_EVENT_TABLE_DEPTH = 16,
    parameter SHAPING_RELEASE_FIFO_DEPTH = 8,
    parameter SHAPING_RELEASE_ISSUE_PORTS = 2,
    parameter SHAPING_LEVEL = 4,
    parameter SHAPING_LOGICAL_TREE_NUM = 1,
    // The legacy BMW datapath derives a physical-tree ID width with
    // $clog2(TREE_NUM), so it cannot elaborate a one-physical-tree instance.
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
    localparam SCHEDULER_PHYSICAL_ID_WIDTH =
        (SCHEDULER_PHYSICAL_TREE_NUM <= 1) ? 1 :
        $clog2(SCHEDULER_PHYSICAL_TREE_NUM),
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
    localparam SHAPING_PHYSICAL_ID_WIDTH =
        (SHAPING_PHYSICAL_TREE_NUM <= 1) ? 1 :
        $clog2(SHAPING_PHYSICAL_TREE_NUM),
    localparam SHAPING_RANK_WIDTH = TIME_WIDTH + SEQUENCE_WIDTH,
    localparam SHAPING_EVENT_ID_WIDTH =
        (SHAPING_EVENT_TABLE_DEPTH <= 1) ? 1 :
        $clog2(SHAPING_EVENT_TABLE_DEPTH),
    localparam SHAPING_TABLE_COUNT_WIDTH =
        (SHAPING_EVENT_TABLE_DEPTH <= 1) ? 1 :
        $clog2(SHAPING_EVENT_TABLE_DEPTH + 1),
    localparam SHAPING_RELEASE_COUNT_WIDTH =
        (SHAPING_RELEASE_FIFO_DEPTH <= 1) ? 1 :
        $clog2(SHAPING_RELEASE_FIFO_DEPTH + 1),
    localparam SHAPING_ISSUE_COUNT_WIDTH =
        (SHAPING_RELEASE_ISSUE_PORTS <= 1) ? 1 :
        $clog2(SHAPING_RELEASE_ISSUE_PORTS + 1),
    localparam SHAPING_TOTAL_COUNT_WIDTH =
        (SHAPING_PHYSICAL_TREE_NUM * SHAPING_SHARD_CAPACITY <= 1) ?
        1 : $clog2(SHAPING_PHYSICAL_TREE_NUM *
                   SHAPING_SHARD_CAPACITY + 1),
    localparam SHAPING_PENDING_COUNT_WIDTH =
        (SHAPING_LOGICAL_PENDING_DEPTH <= 1) ? 1 :
        $clog2(SHAPING_LOGICAL_PENDING_DEPTH + 1),
    localparam SHAPING_SHARD_COUNT_WIDTH =
        (SHAPING_SHARD_CAPACITY <= 1) ? 1 :
        $clog2(SHAPING_SHARD_CAPACITY + 1),
    localparam SHAPING_EVENT_DATA_WIDTH =
        SCHEDULER_LOGICAL_ID_WIDTH + PTW + SCHEDULER_DATA_WIDTH,
    localparam SCHEDULER_REQUEST_PORTS =
        SCHEDULER_LOGICAL_TREE_NUM + 3
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,
    input  wire [TIME_WIDTH-1:0]        i_time,

    input  wire                         i_shaping_event_valid,
    output wire                         o_shaping_event_ready,
    input  wire [SHAPING_LOGICAL_ID_WIDTH-1:0]
                                        i_shaping_logical_tree_id,
    input  wire [TIME_WIDTH-1:0]        i_shaping_release_time,
    input  wire [SCHEDULER_LOGICAL_ID_WIDTH-1:0]
                                        i_shaping_parent_leaf_tree_id,
    input  wire [PTW-1:0]               i_shaping_parent_priority,
    input  wire [SCHEDULER_DATA_WIDTH-1:0]
                                        i_shaping_packet_data,
    output wire                         o_shaping_reject_bad_id,

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
    output reg [31:0]                   o_shaping_deferred_cycles,
    output reg [TIME_WIDTH-1:0]         o_release_delay_last,
    output reg [TIME_WIDTH-1:0]         o_release_delay_max,

    output wire [SHAPING_TABLE_COUNT_WIDTH-1:0]
                                        o_shaping_event_table_count,
    output wire [SHAPING_RELEASE_COUNT_WIDTH-1:0]
                                        o_shaping_release_fifo_count,
    output wire [SHAPING_LOGICAL_TREE_NUM-1:0]
                                        o_shaping_release_reserved,
    output wire [SHAPING_LOGICAL_TREE_NUM-1:0]
                                        o_shaping_completion_valid,
    output wire [SHAPING_RELEASE_ISSUE_PORTS-1:0]
                                        o_shaping_due_issue_valid,
    output wire [SHAPING_RELEASE_ISSUE_PORTS-1:0]
                                        o_shaping_due_capture_fire,
    output wire [SHAPING_ISSUE_COUNT_WIDTH-1:0]
                                        o_shaping_due_issue_count,
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

    localparam [SCHEDULER_LOGICAL_ID_WIDTH-1:0]
        SCHEDULER_ROOT_ID = {SCHEDULER_LOGICAL_ID_WIDTH{1'b0}};

    wire shaping_logical_id_valid =
        int'(i_shaping_logical_tree_id) < SHAPING_LOGICAL_TREE_NUM;
    reg shaping_parent_leaf_id_valid;
    always @* begin
        shaping_parent_leaf_id_valid = 1'b0;
        if (int'(i_shaping_parent_leaf_tree_id) <
            SCHEDULER_LOGICAL_TREE_NUM) begin
            if (SCHEDULER_FOREST_MODE != 0)
                shaping_parent_leaf_id_valid =
                    SCHEDULER_NODE_IS_ROOT[
                        int'(i_shaping_parent_leaf_tree_id)] == 0;
            else
                shaping_parent_leaf_id_valid =
                    i_shaping_parent_leaf_tree_id != SCHEDULER_ROOT_ID;
        end
    end
    wire shaping_ids_valid =
        shaping_logical_id_valid && shaping_parent_leaf_id_valid;

    wire [SHAPING_LOGICAL_ID_WIDTH-1:0]
        sanitized_shaping_logical_id = shaping_logical_id_valid ?
            i_shaping_logical_tree_id :
            {SHAPING_LOGICAL_ID_WIDTH{1'b0}};
    wire shaping_engine_event_ready;
    assign o_shaping_event_ready = shaping_engine_event_ready;
    assign o_shaping_reject_bad_id =
        i_shaping_event_valid && o_shaping_event_ready &&
        !shaping_ids_valid;

    wire [SHAPING_EVENT_DATA_WIDTH-1:0] shaping_event_data =
        {i_shaping_parent_leaf_tree_id,
         i_shaping_parent_priority,
         i_shaping_packet_data};

    wire shaping_release_valid;
    wire shaping_release_ready;
    wire [SHAPING_EVENT_ID_WIDTH-1:0] shaping_release_event_id;
    wire [SHAPING_LOGICAL_ID_WIDTH-1:0]
        shaping_release_logical_tree_id;
    wire [TIME_WIDTH-1:0] shaping_release_time;
    wire [SHAPING_EVENT_DATA_WIDTH-1:0] shaping_release_data;
    wire [SHAPING_LOGICAL_TREE_NUM-1:0] shaping_head_valid;
    wire [SHAPING_RANK_WIDTH-1:0]
        shaping_head_rank [0:SHAPING_LOGICAL_TREE_NUM-1];
    wire [SHAPING_PHYSICAL_ID_WIDTH-1:0]
        shaping_head_physical_id [0:SHAPING_LOGICAL_TREE_NUM-1];
    wire [SHAPING_LOGICAL_ID_WIDTH-1:0]
        shaping_due_logical_id [0:SHAPING_RELEASE_ISSUE_PORTS-1];
    wire [SHAPING_PHYSICAL_ID_WIDTH-1:0]
        shaping_due_physical_id [0:SHAPING_RELEASE_ISSUE_PORTS-1];
    wire [SHAPING_RANK_WIDTH-1:0]
        shaping_due_rank [0:SHAPING_RELEASE_ISSUE_PORTS-1];
    wire [SHAPING_LOGICAL_TREE_NUM-1:0] shaping_core_dispatch_fire;
    wire [SHAPING_PHYSICAL_ID_WIDTH-1:0]
        shaping_selected_physical_id [0:SHAPING_LOGICAL_TREE_NUM-1];
    wire [SHAPING_SHARD_COUNT_WIDTH-1:0]
        shaping_shard_count [0:SHAPING_PHYSICAL_TREE_NUM-1];
    wire [SHAPING_RANK_WIDTH-1:0]
        shaping_shard_head_rank [0:SHAPING_PHYSICAL_TREE_NUM-1];
    wire shaping_shard_head_valid [0:SHAPING_PHYSICAL_TREE_NUM-1];
    wire shaping_shard_update_pending [0:SHAPING_PHYSICAL_TREE_NUM-1];
    wire shaping_protocol_error;

    MultiLogicalShapingPIFO #(
        .TIME_WIDTH(TIME_WIDTH),
        .SEQUENCE_WIDTH(SEQUENCE_WIDTH),
        .EVENT_DATA_WIDTH(SHAPING_EVENT_DATA_WIDTH),
        .EVENT_TABLE_DEPTH(SHAPING_EVENT_TABLE_DEPTH),
        .RELEASE_FIFO_DEPTH(SHAPING_RELEASE_FIFO_DEPTH),
        .RELEASE_ISSUE_PORTS(SHAPING_RELEASE_ISSUE_PORTS),
        .LEVEL(SHAPING_LEVEL),
        .LOGICAL_TREE_NUM(SHAPING_LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(SHAPING_PHYSICAL_TREE_NUM),
        .SHARD_CAPACITY(SHAPING_SHARD_CAPACITY),
        .MAX_SHARDS_PER_LOGICAL(SHAPING_MAX_SHARDS_PER_LOGICAL),
        .FIFO_SIZE(SHAPING_FIFO_SIZE),
        .TASK_ORDER_WIDTH(SHAPING_TASK_ORDER_WIDTH),
        .LOGICAL_PENDING_DEPTH(SHAPING_LOGICAL_PENDING_DEPTH),
        .HEAD_SUMMARY_REGISTERED(SHAPING_HEAD_SUMMARY_REGISTERED),
        .USE_EXPLICIT_SHARD_MAP(SHAPING_USE_EXPLICIT_SHARD_MAP),
        .SHARD_COUNTS(SHAPING_SHARD_COUNTS),
        .SHARD_OFFSETS(SHAPING_SHARD_OFFSETS),
        .EXPLICIT_SHARD_MAP(SHAPING_EXPLICIT_SHARD_MAP)
    ) shaping_engine (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_time(i_time),
        .i_event_valid(i_shaping_event_valid && shaping_ids_valid),
        .o_event_ready(shaping_engine_event_ready),
        .i_event_logical_tree_id(sanitized_shaping_logical_id),
        .i_event_release_time(i_shaping_release_time),
        .i_event_data(shaping_event_data),
        .o_release_valid(shaping_release_valid),
        .i_release_ready(shaping_release_ready),
        .o_release_event_id(shaping_release_event_id),
        .o_release_logical_tree_id(shaping_release_logical_tree_id),
        .o_release_time(shaping_release_time),
        .o_release_data(shaping_release_data),
        .o_logical_head_valid(shaping_head_valid),
        .o_logical_head_rank(shaping_head_rank),
        .o_logical_head_physical_tree_id(shaping_head_physical_id),
        .o_release_reserved(o_shaping_release_reserved),
        .o_completion_valid(o_shaping_completion_valid),
        .o_due_issue_valid(o_shaping_due_issue_valid),
        .o_due_capture_fire(o_shaping_due_capture_fire),
        .o_due_issue_logical_tree_id(shaping_due_logical_id),
        .o_due_issue_physical_tree_id(shaping_due_physical_id),
        .o_due_issue_rank(shaping_due_rank),
        .o_due_issue_count(o_shaping_due_issue_count),
        .o_core_dispatch_fire(shaping_core_dispatch_fire),
        .o_core_selected_physical_tree_id(shaping_selected_physical_id),
        .o_logical_pending_count(o_shaping_logical_pending_count),
        .o_logical_count(o_shaping_logical_count),
        .o_shard_count(shaping_shard_count),
        .o_shard_head_rank(shaping_shard_head_rank),
        .o_shard_head_valid(shaping_shard_head_valid),
        .o_shard_update_pending(shaping_shard_update_pending),
        .o_event_table_count(o_shaping_event_table_count),
        .o_release_fifo_count(o_shaping_release_fifo_count),
        .o_busy(o_shaping_busy),
        .o_protocol_error(shaping_protocol_error)
    );

    wire [SCHEDULER_LOGICAL_ID_WIDTH-1:0]
        shaping_parent_leaf_tree_id =
            shaping_release_data[SHAPING_EVENT_DATA_WIDTH-1 -:
                                 SCHEDULER_LOGICAL_ID_WIDTH];
    wire [PTW-1:0] shaping_parent_priority =
        shaping_release_data[SCHEDULER_DATA_WIDTH +: PTW];
    wire [SCHEDULER_DATA_WIDTH-1:0] shaping_packet_data =
        shaping_release_data[SCHEDULER_DATA_WIDTH-1:0];

    wire parent_push_valid;
    wire parent_push_ready;
    wire [SCHEDULER_LOGICAL_ID_WIDTH-1:0] parent_leaf_tree_id;
    wire [PTW-1:0] parent_priority;
    wire [SCHEDULER_DATA_WIDTH-1:0] parent_packet_data;

    ShapingReleaseToParent #(
        .LOGICAL_ID_WIDTH(SCHEDULER_LOGICAL_ID_WIDTH),
        .PRIORITY_WIDTH(PTW),
        .DATA_WIDTH(SCHEDULER_DATA_WIDTH)
    ) parent_admission (
        .i_direct_valid(i_direct_push_valid),
        .o_direct_ready(o_direct_push_ready),
        .i_direct_leaf_tree_id(i_direct_leaf_tree_id),
        .i_direct_priority(i_direct_priority),
        .i_direct_data(i_direct_packet_data),
        .i_scheduling_pop_present(i_packet_pop_valid),
        .i_shaping_valid(shaping_release_valid),
        .o_shaping_ready(shaping_release_ready),
        .i_shaping_leaf_tree_id(shaping_parent_leaf_tree_id),
        .i_shaping_priority(shaping_parent_priority),
        .i_shaping_data(shaping_packet_data),
        .o_parent_valid(parent_push_valid),
        .i_parent_ready(parent_push_ready),
        .o_parent_leaf_tree_id(parent_leaf_tree_id),
        .o_parent_priority(parent_priority),
        .o_parent_data(parent_packet_data),
        .o_direct_fire(o_direct_to_parent_fire),
        .o_shaping_fire(o_shaping_to_parent_fire),
        .o_shaping_deferred(o_shaping_deferred),
        .o_deferred_by_direct_push(o_deferred_by_direct_push),
        .o_deferred_by_scheduling_pop(
            o_deferred_by_scheduling_pop),
        .o_deferred_by_parent_backpressure(
            o_deferred_by_parent_backpressure)
    );

    assign o_shaping_release_pending = shaping_release_valid;

    wire [SCHEDULER_REQUEST_PORTS-1:0]
        scheduler_internal_capture_fire;
    wire [SCHEDULER_LOGICAL_TREE_NUM-1:0]
        scheduler_internal_task_fire;
    wire [SCHEDULER_LOGICAL_TREE_NUM-1:0]
        scheduler_internal_task_push;
    wire scheduler_protocol_error;

    generate
        if (SCHEDULER_FOREST_MODE != 0) begin : schedule_forest
            ScheduleForestHeterogeneousPIFO #(
                .PTW(PTW),
                .MTW(MTW),
                .CTW(CTW),
                .LEVEL(SCHEDULER_LEVEL),
                .LOGICAL_TREE_NUM(SCHEDULER_LOGICAL_TREE_NUM),
                .SEMANTIC_TREE_NUM(SCHEDULER_SEMANTIC_TREE_NUM),
                .PHYSICAL_TREE_NUM(SCHEDULER_PHYSICAL_TREE_NUM),
                .SHARD_CAPACITY(SCHEDULER_SHARD_CAPACITY),
                .FIFO_SIZE(SCHEDULER_FIFO_SIZE),
                .MAX_SHARDS_PER_LOGICAL(
                    SCHEDULER_MAX_SHARDS_PER_LOGICAL),
                .POP_RESULT_FIFO_DEPTH(
                    SCHEDULER_POP_RESULT_FIFO_DEPTH),
                .TASK_ORDER_WIDTH(SCHEDULER_TASK_ORDER_WIDTH),
                .LEAF_ROUTE_QUEUE_DEPTH(
                    SCHEDULER_LEAF_ROUTE_QUEUE_DEPTH),
                .LOGICAL_PENDING_DEPTH(
                    SCHEDULER_LOGICAL_PENDING_DEPTH),
                .USE_EXPLICIT_SHARD_MAP(
                    SCHEDULER_USE_EXPLICIT_SHARD_MAP),
                .TREE_ROOTS(SCHEDULER_TREE_ROOTS),
                .NODE_PARENT(SCHEDULER_NODE_PARENT),
                .NODE_TREE_ID(SCHEDULER_NODE_TREE_ID),
                .NODE_IS_ROOT(SCHEDULER_NODE_IS_ROOT),
                .SHARD_COUNTS(SCHEDULER_SHARD_COUNTS),
                .SHARD_OFFSETS(SCHEDULER_SHARD_OFFSETS),
                .EXPLICIT_SHARD_MAP(SCHEDULER_EXPLICIT_SHARD_MAP)
            ) packet_scheduler (
                .i_clk(i_clk),
                .i_arst_n(i_arst_n),
                .i_push(parent_push_valid),
                .i_push_leaf_id(parent_leaf_tree_id),
                .i_push_priority(parent_priority),
                .i_push_data(parent_packet_data),
                .o_push_ready(parent_push_ready),
                .o_reject_bad_leaf_id(o_direct_reject_bad_leaf_id),
                .i_pop(i_packet_pop_valid),
                .i_pop_semantic_tree_id(
                    i_packet_pop_semantic_tree_id),
                .o_pop_req_ready(o_packet_pop_ready),
                .o_reject_bad_tree_id(),
                .o_pop_out(o_packet_out_valid),
                .o_pop_semantic_tree_id(
                    o_packet_out_semantic_tree_id),
                .o_pop_leaf_id(o_packet_out_leaf_tree_id),
                .o_pop_data(o_packet_out_data),
                .o_root_pop_routed(),
                .o_root_pop_root_id(),
                .o_root_pop_leaf_id(),
                .o_busy(o_scheduler_busy),
                .o_protocol_error(scheduler_protocol_error),
                .o_logical_count(o_scheduler_logical_count),
                .o_logical_pending_count(),
                .o_pending_count(o_scheduler_pending_count)
            );
        end else begin : schedule_single_tree
            assign o_packet_out_semantic_tree_id =
                {SCHEDULER_SEMANTIC_TREE_ID_WIDTH{1'b0}};
            HierarchicalHeterogeneousPIFO #(
                .PTW(PTW),
                .MTW(MTW),
                .CTW(CTW),
                .LEVEL(SCHEDULER_LEVEL),
                .LOGICAL_TREE_NUM(SCHEDULER_LOGICAL_TREE_NUM),
                .PHYSICAL_TREE_NUM(SCHEDULER_PHYSICAL_TREE_NUM),
                .SHARD_CAPACITY(SCHEDULER_SHARD_CAPACITY),
                .FIFO_SIZE(SCHEDULER_FIFO_SIZE),
                .MAX_SHARDS_PER_LOGICAL(
                    SCHEDULER_MAX_SHARDS_PER_LOGICAL),
                .POP_RESULT_FIFO_DEPTH(
                    SCHEDULER_POP_RESULT_FIFO_DEPTH),
                .TASK_ORDER_WIDTH(SCHEDULER_TASK_ORDER_WIDTH),
                .LEAF_ROUTE_QUEUE_DEPTH(
                    SCHEDULER_LEAF_ROUTE_QUEUE_DEPTH),
                .LOGICAL_PENDING_DEPTH(
                    SCHEDULER_LOGICAL_PENDING_DEPTH),
                .USE_EXPLICIT_SHARD_MAP(
                    SCHEDULER_USE_EXPLICIT_SHARD_MAP),
                .SHARD_COUNTS(SCHEDULER_SHARD_COUNTS),
                .SHARD_OFFSETS(SCHEDULER_SHARD_OFFSETS),
                .EXPLICIT_SHARD_MAP(SCHEDULER_EXPLICIT_SHARD_MAP)
            ) packet_scheduler (
                .i_clk(i_clk),
                .i_arst_n(i_arst_n),
                .i_push(parent_push_valid),
                .i_push_tree_id(parent_leaf_tree_id),
                .i_push_priority(parent_priority),
                .i_push_data(parent_packet_data),
                .o_push_ready(parent_push_ready),
                .o_reject_bad_leaf_id(o_direct_reject_bad_leaf_id),
                .i_pop(i_packet_pop_valid),
                .o_pop_req_ready(o_packet_pop_ready),
                .o_pop_out(o_packet_out_valid),
                .o_pop_tree_id(o_packet_out_leaf_tree_id),
                .o_pop_data(o_packet_out_data),
                .o_busy(o_scheduler_busy),
                .o_protocol_error(scheduler_protocol_error),
                .o_internal_capture_fire(
                    scheduler_internal_capture_fire),
                .o_internal_task_fire(scheduler_internal_task_fire),
                .o_internal_task_push(scheduler_internal_task_push),
                .o_internal_task_logical_tree_id(),
                .o_internal_task_physical_tree_id(),
                .o_internal_task_data(),
                .o_logical_pending_count(),
                .o_pending_count(o_scheduler_pending_count),
                .o_root_pop_routed(),
                .o_root_pop_leaf_tree_id(),
                .o_task_fifo_full(),
                .o_task_write(),
                .o_task_push(),
                .o_task_pop(),
                .o_shard_list(),
                .o_logical_shard_count(),
                .o_logical_count(o_scheduler_logical_count),
                .o_push_rr_ptr(),
                .o_shard_count(),
                .o_shard_head_rank(),
                .o_shard_empty(),
                .o_shard_full(),
                .o_shard_head_valid(),
                .o_update_pending(),
                .o_logical_busy(),
                .o_pending_logical_tree_id(),
                .o_pending_push()
            );
        end
    endgenerate

    reg local_protocol_error;
    wire [TIME_WIDTH-1:0] current_release_delay =
        i_time - shaping_release_time;
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

            if (o_shaping_to_parent_fire) begin
                if (i_time < shaping_release_time)
                    local_protocol_error <= 1'b1;
                o_release_delay_last <= current_release_delay;
                if (current_release_delay > o_release_delay_max)
                    o_release_delay_max <= current_release_delay;
            end

            if (o_shaping_reject_bad_id)
                local_protocol_error <= 1'b1;
            if (o_shaping_to_parent_fire &&
                (i_direct_push_valid || i_packet_pop_valid))
                local_protocol_error <= 1'b1;
        end
    end

    assign o_busy = o_shaping_busy || o_scheduler_busy;
    assign o_protocol_error = local_protocol_error ||
        shaping_protocol_error || scheduler_protocol_error;

    initial begin
        if ((SCHEDULER_LOGICAL_TREE_NUM < 2) ||
            (SCHEDULER_SEMANTIC_TREE_NUM < 1) ||
            (SHAPING_LOGICAL_TREE_NUM < 1) ||
            (SHAPING_PHYSICAL_TREE_NUM < 2) ||
            (SHAPING_PHYSICAL_TREE_NUM < SHAPING_LOGICAL_TREE_NUM) ||
            (TIME_WIDTH < 1) || (SEQUENCE_WIDTH < 1))
            $fatal(1, "NonWorkConservingPIFOStage45 parameters invalid");
    end

endmodule
