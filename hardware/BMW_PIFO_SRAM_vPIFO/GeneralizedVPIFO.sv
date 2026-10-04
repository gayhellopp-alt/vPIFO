`timescale 1ns / 1ps

// Generalized VPIFO top: one node model, two independent execution domains.
//
// @ScheduleVPIFO nodes execute in HierarchicalHeterogeneousPIFO.
// @TimingVPIFO nodes execute in MultiLogicalShapingPIFO.
// VPIFOConnectionTable is the only cross-domain topology authority.  The
// existing Stage-5 datapath remains the execution implementation underneath;
// its packet-carried parent ID is now supplied by the static table instead of
// the transaction input.
module GeneralizedVPIFO #(
    parameter PTW = 16,
    parameter MTW = 16,
    parameter CTW = 10,
    parameter TIME_WIDTH = 16,
    parameter TRANSACTION_FLOW_NUM = 16,
    parameter SEQUENCE_WIDTH = 8,
    parameter TIMING_EVENT_TABLE_DEPTH = 16,
    parameter TIMING_RELEASE_FIFO_DEPTH = 8,
    parameter TIMING_RELEASE_ISSUE_PORTS = 2,
    parameter FIFO_SIZE = 8,
    parameter TASK_ORDER_WIDTH = 32,

    parameter GLOBAL_NODE_NUM =
        GeneralizedVpifoConfigPkg::GLOBAL_NODE_NUM,
    parameter SCHEDULE_LOGICAL_TREE_NUM =
        GeneralizedVpifoConfigPkg::SCHEDULE_LOGICAL_TREE_NUM,
    parameter SCHEDULE_SEMANTIC_TREE_NUM =
        GeneralizedVpifoConfigPkg::SCHEDULE_SEMANTIC_TREE_NUM,
    parameter SCHEDULE_PHYSICAL_TREE_NUM =
        GeneralizedVpifoConfigPkg::SCHEDULE_PHYSICAL_TREE_NUM,
    parameter SCHEDULE_LEVEL =
        GeneralizedVpifoConfigPkg::SCHEDULE_LEVEL,
    parameter SCHEDULE_SHARD_CAPACITY =
        GeneralizedVpifoConfigPkg::SCHEDULE_SHARD_CAPACITY,
    parameter SCHEDULE_MAX_SHARDS_PER_LOGICAL =
        GeneralizedVpifoConfigPkg::SCHEDULE_MAX_SHARDS_PER_LOGICAL,
    parameter TIMING_LOGICAL_TREE_NUM =
        GeneralizedVpifoConfigPkg::TIMING_LOGICAL_TREE_NUM,
    parameter TIMING_PHYSICAL_TREE_NUM =
        GeneralizedVpifoConfigPkg::TIMING_PHYSICAL_TREE_NUM,
    parameter TIMING_LEVEL =
        GeneralizedVpifoConfigPkg::TIMING_LEVEL,
    parameter TIMING_SHARD_CAPACITY =
        GeneralizedVpifoConfigPkg::TIMING_SHARD_CAPACITY,
    parameter TIMING_MAX_SHARDS_PER_LOGICAL =
        GeneralizedVpifoConfigPkg::TIMING_MAX_SHARDS_PER_LOGICAL,

    parameter integer GLOBAL_NODE_KIND [0:GLOBAL_NODE_NUM-1] =
        GeneralizedVpifoConfigPkg::GLOBAL_NODE_KIND,
    parameter integer GLOBAL_TO_SCHEDULE [0:GLOBAL_NODE_NUM-1] =
        GeneralizedVpifoConfigPkg::GLOBAL_TO_SCHEDULE,
    parameter integer GLOBAL_TO_TIMING [0:GLOBAL_NODE_NUM-1] =
        GeneralizedVpifoConfigPkg::GLOBAL_TO_TIMING,
    parameter integer SCHEDULE_TO_GLOBAL
        [0:SCHEDULE_LOGICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_TO_GLOBAL,
    parameter integer SCHEDULE_TREE_ROOTS
        [0:SCHEDULE_SEMANTIC_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_TREE_ROOTS,
    parameter integer SCHEDULE_NODE_PARENT
        [0:SCHEDULE_LOGICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_NODE_PARENT,
    parameter integer SCHEDULE_NODE_TREE_ID
        [0:SCHEDULE_LOGICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_NODE_TREE_ID,
    parameter integer SCHEDULE_NODE_IS_ROOT
        [0:SCHEDULE_LOGICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_NODE_IS_ROOT,
    parameter integer TIMING_RELEASE_TO_SCHEDULE
        [0:TIMING_LOGICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::TIMING_RELEASE_TO_SCHEDULE,
    parameter integer TIMING_PROGRAM_MODE
        [0:TIMING_LOGICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::TIMING_PROGRAM_MODE,
    parameter integer SCHEDULE_SHARD_COUNTS
        [0:SCHEDULE_LOGICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_SHARD_COUNTS,
    parameter integer SCHEDULE_SHARD_OFFSETS
        [0:SCHEDULE_LOGICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_SHARD_OFFSETS,
    parameter integer SCHEDULE_EXPLICIT_SHARD_MAP
        [0:SCHEDULE_PHYSICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_EXPLICIT_SHARD_MAP,
    parameter integer TIMING_SHARD_COUNTS
        [0:TIMING_LOGICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::TIMING_SHARD_COUNTS,
    parameter integer TIMING_SHARD_OFFSETS
        [0:TIMING_LOGICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::TIMING_SHARD_OFFSETS,
    parameter integer TIMING_EXPLICIT_SHARD_MAP
        [0:TIMING_PHYSICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::TIMING_EXPLICIT_SHARD_MAP,

    localparam GLOBAL_ID_WIDTH = (GLOBAL_NODE_NUM <= 1) ? 1 :
                                 $clog2(GLOBAL_NODE_NUM),
    localparam SCHEDULE_ID_WIDTH =
        (SCHEDULE_LOGICAL_TREE_NUM <= 1) ? 1 :
        $clog2(SCHEDULE_LOGICAL_TREE_NUM),
    localparam SCHEDULE_SEMANTIC_TREE_ID_WIDTH =
        (SCHEDULE_SEMANTIC_TREE_NUM <= 1) ? 1 :
        $clog2(SCHEDULE_SEMANTIC_TREE_NUM),
    localparam TIMING_ID_WIDTH =
        (TIMING_LOGICAL_TREE_NUM <= 1) ? 1 :
        $clog2(TIMING_LOGICAL_TREE_NUM),
    localparam DATA_WIDTH = MTW + PTW,
    localparam FLOW_ID_WIDTH = (TRANSACTION_FLOW_NUM <= 1) ? 1 :
                               $clog2(TRANSACTION_FLOW_NUM),
    localparam CONFIGURED_COUNT_WIDTH =
        (TRANSACTION_FLOW_NUM <= 1) ? 1 :
        $clog2(TRANSACTION_FLOW_NUM + 1),
    localparam TIMING_TABLE_COUNT_WIDTH =
        (TIMING_EVENT_TABLE_DEPTH <= 1) ? 1 :
        $clog2(TIMING_EVENT_TABLE_DEPTH + 1),
    localparam TIMING_RELEASE_COUNT_WIDTH =
        (TIMING_RELEASE_FIFO_DEPTH <= 1) ? 1 :
        $clog2(TIMING_RELEASE_FIFO_DEPTH + 1),
    localparam SCHEDULE_PENDING_DEPTH =
        SCHEDULE_LOGICAL_TREE_NUM + 3 + FIFO_SIZE,
    localparam TIMING_PENDING_DEPTH =
        TIMING_RELEASE_ISSUE_PORTS + FIFO_SIZE + 1,
    localparam SCHEDULE_TOTAL_COUNT_WIDTH =
        (SCHEDULE_PHYSICAL_TREE_NUM * SCHEDULE_SHARD_CAPACITY <= 1) ?
        1 : $clog2(SCHEDULE_PHYSICAL_TREE_NUM *
                   SCHEDULE_SHARD_CAPACITY + 1),
    localparam SCHEDULE_PENDING_COUNT_WIDTH =
        (SCHEDULE_PENDING_DEPTH <= 1) ? 1 :
        $clog2(SCHEDULE_PENDING_DEPTH + 1),
    localparam TIMING_TOTAL_COUNT_WIDTH =
        (TIMING_PHYSICAL_TREE_NUM * TIMING_SHARD_CAPACITY <= 1) ?
        1 : $clog2(TIMING_PHYSICAL_TREE_NUM *
                   TIMING_SHARD_CAPACITY + 1),
    localparam TIMING_PENDING_COUNT_WIDTH =
        (TIMING_PENDING_DEPTH <= 1) ? 1 :
        $clog2(TIMING_PENDING_DEPTH + 1)
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,
    input  wire [TIME_WIDTH-1:0]        i_time,

    input  wire                         i_transaction_cfg_valid,
    output wire                         o_transaction_cfg_ready,
    input  wire [FLOW_ID_WIDTH-1:0]     i_transaction_cfg_flow_id,
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
    input  wire [FLOW_ID_WIDTH-1:0]     i_transaction_flow_id,
    input  wire [GLOBAL_ID_WIDTH-1:0]   i_transaction_timing_node_id,
    input  wire [TIME_WIDTH-1:0]
                                        i_transaction_packet_service_time,
    input  wire [TIME_WIDTH-1:0]
                                        i_transaction_absolute_release_time,
    input  wire [PTW-1:0]               i_transaction_parent_priority,
    input  wire [DATA_WIDTH-1:0]        i_transaction_packet_data,
    output wire                         o_transaction_reject_bad_flow_id,
    output wire                         o_transaction_reject_unconfigured,
    output wire                         o_transaction_reject_bad_route,
    output wire                         o_transaction_fire,
    output wire [TIME_WIDTH-1:0]        o_transaction_release_time,
    output wire [TIME_WIDTH-1:0]        o_transaction_next_release_time,
    output wire [TIME_WIDTH-1:0]
                                        o_transaction_bucket_credit_time,
    output wire [TIME_WIDTH-1:0]
                                        o_transaction_bucket_state_time,
    output wire                         o_transaction_map_valid,
    output wire [TIMING_ID_WIDTH-1:0]
                                        o_transaction_timing_local_id,
    output wire [SCHEDULE_ID_WIDTH-1:0]
                                        o_transaction_release_schedule_local_id,
    output wire [2:0]                   o_transaction_declared_program_mode,

    input  wire [FLOW_ID_WIDTH-1:0]
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
    output wire [CONFIGURED_COUNT_WIDTH-1:0]
                                        o_configured_flow_count,

    input  wire                         i_direct_push_valid,
    output wire                         o_direct_push_ready,
    input  wire [GLOBAL_ID_WIDTH-1:0]
                                        i_direct_schedule_node_id,
    input  wire [PTW-1:0]               i_direct_priority,
    input  wire [DATA_WIDTH-1:0]        i_direct_packet_data,
    output wire                         o_direct_reject_bad_schedule_node,
    output wire                         o_direct_map_valid,
    output wire [SCHEDULE_ID_WIDTH-1:0]
                                        o_direct_schedule_local_id,

    input  wire                         i_packet_pop_valid,
    input  wire [GLOBAL_ID_WIDTH-1:0]
                                        i_packet_pop_schedule_root_node_id,
    output wire                         o_packet_pop_ready,
    output wire                         o_packet_pop_reject_bad_schedule_root,
    output wire                         o_packet_out_valid,
    output wire [SCHEDULE_SEMANTIC_TREE_ID_WIDTH-1:0]
                                        o_packet_out_semantic_tree_id,
    output wire [GLOBAL_ID_WIDTH-1:0]
                                        o_packet_out_schedule_node_id,
    output wire [DATA_WIDTH-1:0]        o_packet_out_data,

    output wire                         o_timing_to_schedule_fire,
    output wire                         o_direct_to_schedule_fire,
    output wire                         o_timing_release_pending,
    output wire                         o_timing_deferred,
    output wire                         o_deferred_by_direct_push,
    output wire                         o_deferred_by_scheduling_pop,
    output wire                         o_deferred_by_schedule_backpressure,
    output wire [31:0]                  o_timing_deferred_cycles,
    output wire [TIME_WIDTH-1:0]        o_release_delay_last,
    output wire [TIME_WIDTH-1:0]        o_release_delay_max,
    output wire [TIMING_TABLE_COUNT_WIDTH-1:0]
                                        o_timing_event_table_count,
    output wire [TIMING_RELEASE_COUNT_WIDTH-1:0]
                                        o_timing_release_fifo_count,
    output wire [TIMING_TOTAL_COUNT_WIDTH-1:0]
        o_timing_logical_count [0:TIMING_LOGICAL_TREE_NUM-1],
    output wire [TIMING_PENDING_COUNT_WIDTH-1:0]
        o_timing_logical_pending_count [0:TIMING_LOGICAL_TREE_NUM-1],
    output wire [SCHEDULE_TOTAL_COUNT_WIDTH-1:0]
        o_schedule_logical_count [0:SCHEDULE_LOGICAL_TREE_NUM-1],
    output wire [SCHEDULE_PENDING_COUNT_WIDTH-1:0]
                                        o_schedule_pending_count,
    output wire                         o_timing_busy,
    output wire                         o_schedule_busy,
    output wire                         o_busy,
    output wire                         o_protocol_error
);

    wire timing_map_valid;
    wire [TIMING_ID_WIDTH-1:0] timing_local_id;
    wire [SCHEDULE_ID_WIDTH-1:0] release_schedule_local_id;
    wire [2:0] timing_program_mode;
    wire direct_map_valid;
    wire [SCHEDULE_ID_WIDTH-1:0] direct_schedule_local_id;
    wire schedule_output_local_valid;
    wire [GLOBAL_ID_WIDTH-1:0] schedule_output_global_id;
    wire [SCHEDULE_ID_WIDTH-1:0] schedule_output_local_id;
    wire schedule_root_map_valid;
    wire [SCHEDULE_SEMANTIC_TREE_ID_WIDTH-1:0]
        schedule_pop_semantic_tree_id;

    VPIFOConnectionTable #(
        .GLOBAL_NODE_NUM(GLOBAL_NODE_NUM),
        .SCHEDULE_NODE_NUM(SCHEDULE_LOGICAL_TREE_NUM),
        .SCHEDULE_SEMANTIC_TREE_NUM(SCHEDULE_SEMANTIC_TREE_NUM),
        .TIMING_NODE_NUM(TIMING_LOGICAL_TREE_NUM),
        .GLOBAL_NODE_KIND(GLOBAL_NODE_KIND),
        .GLOBAL_TO_SCHEDULE(GLOBAL_TO_SCHEDULE),
        .GLOBAL_TO_TIMING(GLOBAL_TO_TIMING),
        .SCHEDULE_TO_GLOBAL(SCHEDULE_TO_GLOBAL),
        .SCHEDULE_NODE_TREE_ID(SCHEDULE_NODE_TREE_ID),
        .SCHEDULE_NODE_IS_ROOT(SCHEDULE_NODE_IS_ROOT),
        .TIMING_RELEASE_TO_SCHEDULE(TIMING_RELEASE_TO_SCHEDULE),
        .TIMING_PROGRAM_MODE(TIMING_PROGRAM_MODE)
    ) connection_table (
        .i_timing_global_id(i_transaction_timing_node_id),
        .o_timing_valid(timing_map_valid),
        .o_timing_local_id(timing_local_id),
        .o_release_schedule_local_id(release_schedule_local_id),
        .o_timing_program_mode(timing_program_mode),
        .i_schedule_global_id(i_direct_schedule_node_id),
        .o_schedule_leaf_valid(direct_map_valid),
        .o_schedule_local_id(direct_schedule_local_id),
        .i_schedule_root_global_id(
            i_packet_pop_schedule_root_node_id),
        .o_schedule_root_valid(schedule_root_map_valid),
        .o_schedule_semantic_tree_id(
            schedule_pop_semantic_tree_id),
        .i_schedule_local_id(schedule_output_local_id),
        .o_schedule_local_valid(schedule_output_local_valid),
        .o_schedule_global_id(schedule_output_global_id)
    );

    assign o_transaction_map_valid = timing_map_valid;
    assign o_transaction_timing_local_id = timing_local_id;
    assign o_transaction_release_schedule_local_id =
        release_schedule_local_id;
    assign o_transaction_declared_program_mode = timing_program_mode;
    assign o_direct_map_valid = direct_map_valid;
    assign o_direct_schedule_local_id = direct_schedule_local_id;
    assign o_packet_out_schedule_node_id = schedule_output_global_id;

    wire stage5_transaction_ready;
    wire stage5_transaction_fire;
    wire stage5_transaction_reject_bad_route;
    wire stage5_direct_push_ready;
    wire stage5_direct_reject_bad_leaf_id;
    wire stage5_protocol_error;
    wire stage5_packet_pop_ready;

    wire transaction_bad_route_fire = i_transaction_valid &&
        o_transaction_ready && !timing_map_valid;
    assign o_transaction_ready = timing_map_valid ?
        stage5_transaction_ready : i_arst_n;
    assign o_transaction_fire = stage5_transaction_fire;
    assign o_transaction_reject_bad_route =
        transaction_bad_route_fire || stage5_transaction_reject_bad_route;

    wire direct_bad_route_fire = i_direct_push_valid &&
        o_direct_push_ready && !direct_map_valid;
    assign o_direct_push_ready = direct_map_valid ?
        stage5_direct_push_ready : i_arst_n;
    assign o_direct_reject_bad_schedule_node =
        direct_bad_route_fire || stage5_direct_reject_bad_leaf_id;

    localparam SCHEDULE_FOREST_MODE =
        (SCHEDULE_SEMANTIC_TREE_NUM > 1) ? 1 : 0;
    wire packet_pop_route_valid =
        (SCHEDULE_FOREST_MODE == 0) || schedule_root_map_valid;
    wire packet_pop_bad_route_fire = i_packet_pop_valid &&
        o_packet_pop_ready && !packet_pop_route_valid;
    assign o_packet_pop_ready = packet_pop_route_valid ?
        stage5_packet_pop_ready : i_arst_n;
    assign o_packet_pop_reject_bad_schedule_root =
        packet_pop_bad_route_fire;

    NonWorkConservingPIFOStage5 #(
        .PTW(PTW),
        .MTW(MTW),
        .CTW(CTW),
        .SCHEDULER_LEVEL(SCHEDULE_LEVEL),
        .SCHEDULER_LOGICAL_TREE_NUM(SCHEDULE_LOGICAL_TREE_NUM),
        .SCHEDULER_SEMANTIC_TREE_NUM(SCHEDULE_SEMANTIC_TREE_NUM),
        .SCHEDULER_FOREST_MODE(SCHEDULE_FOREST_MODE),
        .SCHEDULER_PHYSICAL_TREE_NUM(SCHEDULE_PHYSICAL_TREE_NUM),
        .SCHEDULER_SHARD_CAPACITY(SCHEDULE_SHARD_CAPACITY),
        .SCHEDULER_FIFO_SIZE(FIFO_SIZE),
        .SCHEDULER_MAX_SHARDS_PER_LOGICAL(
            SCHEDULE_MAX_SHARDS_PER_LOGICAL),
        .SCHEDULER_TASK_ORDER_WIDTH(TASK_ORDER_WIDTH),
        .SCHEDULER_LOGICAL_PENDING_DEPTH(SCHEDULE_PENDING_DEPTH),
        .SCHEDULER_USE_EXPLICIT_SHARD_MAP(0),
        .SCHEDULER_SHARD_COUNTS(SCHEDULE_SHARD_COUNTS),
        .SCHEDULER_SHARD_OFFSETS(SCHEDULE_SHARD_OFFSETS),
        .SCHEDULER_EXPLICIT_SHARD_MAP(
            SCHEDULE_EXPLICIT_SHARD_MAP),
        .SCHEDULER_TREE_ROOTS(SCHEDULE_TREE_ROOTS),
        .SCHEDULER_NODE_PARENT(SCHEDULE_NODE_PARENT),
        .SCHEDULER_NODE_TREE_ID(SCHEDULE_NODE_TREE_ID),
        .SCHEDULER_NODE_IS_ROOT(SCHEDULE_NODE_IS_ROOT),
        .TIME_WIDTH(TIME_WIDTH),
        .TRANSACTION_FLOW_NUM(TRANSACTION_FLOW_NUM),
        .SEQUENCE_WIDTH(SEQUENCE_WIDTH),
        .SHAPING_EVENT_TABLE_DEPTH(TIMING_EVENT_TABLE_DEPTH),
        .SHAPING_RELEASE_FIFO_DEPTH(TIMING_RELEASE_FIFO_DEPTH),
        .SHAPING_RELEASE_ISSUE_PORTS(TIMING_RELEASE_ISSUE_PORTS),
        .SHAPING_LEVEL(TIMING_LEVEL),
        .SHAPING_LOGICAL_TREE_NUM(TIMING_LOGICAL_TREE_NUM),
        .SHAPING_PHYSICAL_TREE_NUM(TIMING_PHYSICAL_TREE_NUM),
        .SHAPING_SHARD_CAPACITY(TIMING_SHARD_CAPACITY),
        .SHAPING_MAX_SHARDS_PER_LOGICAL(
            TIMING_MAX_SHARDS_PER_LOGICAL),
        .SHAPING_FIFO_SIZE(FIFO_SIZE),
        .SHAPING_TASK_ORDER_WIDTH(TASK_ORDER_WIDTH),
        .SHAPING_LOGICAL_PENDING_DEPTH(TIMING_PENDING_DEPTH),
        .SHAPING_USE_EXPLICIT_SHARD_MAP(0),
        .SHAPING_SHARD_COUNTS(TIMING_SHARD_COUNTS),
        .SHAPING_SHARD_OFFSETS(TIMING_SHARD_OFFSETS),
        .SHAPING_EXPLICIT_SHARD_MAP(TIMING_EXPLICIT_SHARD_MAP)
    ) two_execution_domains (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_time(i_time),
        .i_transaction_cfg_valid(i_transaction_cfg_valid),
        .o_transaction_cfg_ready(o_transaction_cfg_ready),
        .i_transaction_cfg_flow_id(i_transaction_cfg_flow_id),
        .i_transaction_cfg_enable(i_transaction_cfg_enable),
        .i_transaction_cfg_mode(i_transaction_cfg_mode),
        .i_transaction_cfg_default_service_time(
            i_transaction_cfg_default_service_time),
        .i_transaction_cfg_state_valid(i_transaction_cfg_state_valid),
        .i_transaction_cfg_next_release_time(
            i_transaction_cfg_next_release_time),
        .i_transaction_cfg_bucket_capacity_time(
            i_transaction_cfg_bucket_capacity_time),
        .i_transaction_cfg_bucket_state_valid(
            i_transaction_cfg_bucket_state_valid),
        .i_transaction_cfg_bucket_credit_time(
            i_transaction_cfg_bucket_credit_time),
        .i_transaction_cfg_bucket_state_time(
            i_transaction_cfg_bucket_state_time),
        .o_transaction_cfg_reject_bad_flow_id(
            o_transaction_cfg_reject_bad_flow_id),
        .i_transaction_valid(i_transaction_valid && timing_map_valid),
        .o_transaction_ready(stage5_transaction_ready),
        .i_transaction_flow_id(i_transaction_flow_id),
        .i_transaction_shaping_logical_tree_id(timing_local_id),
        .i_transaction_packet_service_time(
            i_transaction_packet_service_time),
        .i_transaction_absolute_release_time(
            i_transaction_absolute_release_time),
        .i_transaction_parent_leaf_tree_id(
            release_schedule_local_id),
        .i_transaction_parent_priority(i_transaction_parent_priority),
        .i_transaction_packet_data(i_transaction_packet_data),
        .o_transaction_reject_bad_flow_id(
            o_transaction_reject_bad_flow_id),
        .o_transaction_reject_unconfigured(
            o_transaction_reject_unconfigured),
        .o_transaction_reject_bad_route(
            stage5_transaction_reject_bad_route),
        .o_transaction_fire(stage5_transaction_fire),
        .o_transaction_release_time(o_transaction_release_time),
        .o_transaction_next_release_time(
            o_transaction_next_release_time),
        .o_transaction_bucket_credit_time(
            o_transaction_bucket_credit_time),
        .o_transaction_bucket_state_time(
            o_transaction_bucket_state_time),
        .i_transaction_state_read_flow_id(
            i_transaction_state_read_flow_id),
        .o_transaction_state_read_configured(
            o_transaction_state_read_configured),
        .o_transaction_state_read_mode(o_transaction_state_read_mode),
        .o_transaction_state_read_default_service_time(
            o_transaction_state_read_default_service_time),
        .o_transaction_state_read_valid(
            o_transaction_state_read_valid),
        .o_transaction_state_read_next_release_time(
            o_transaction_state_read_next_release_time),
        .o_transaction_state_read_bucket_valid(
            o_transaction_state_read_bucket_valid),
        .o_transaction_state_read_bucket_capacity_time(
            o_transaction_state_read_bucket_capacity_time),
        .o_transaction_state_read_bucket_credit_time(
            o_transaction_state_read_bucket_credit_time),
        .o_transaction_state_read_bucket_state_time(
            o_transaction_state_read_bucket_state_time),
        .o_transaction_count(o_transaction_count),
        .o_rejected_transaction_count(o_rejected_transaction_count),
        .o_late_absolute_count(o_late_absolute_count),
        .o_saturated_time_count(o_saturated_time_count),
        .o_configured_flow_count(o_configured_flow_count),
        .i_direct_push_valid(i_direct_push_valid && direct_map_valid),
        .o_direct_push_ready(stage5_direct_push_ready),
        .i_direct_leaf_tree_id(direct_schedule_local_id),
        .i_direct_priority(i_direct_priority),
        .i_direct_packet_data(i_direct_packet_data),
        .o_direct_reject_bad_leaf_id(
            stage5_direct_reject_bad_leaf_id),
        .i_packet_pop_valid(i_packet_pop_valid &&
                            packet_pop_route_valid),
        .i_packet_pop_semantic_tree_id(
            schedule_pop_semantic_tree_id),
        .o_packet_pop_ready(stage5_packet_pop_ready),
        .o_packet_out_valid(o_packet_out_valid),
        .o_packet_out_semantic_tree_id(
            o_packet_out_semantic_tree_id),
        .o_packet_out_leaf_tree_id(schedule_output_local_id),
        .o_packet_out_data(o_packet_out_data),
        .o_shaping_to_parent_fire(o_timing_to_schedule_fire),
        .o_direct_to_parent_fire(o_direct_to_schedule_fire),
        .o_shaping_release_pending(o_timing_release_pending),
        .o_shaping_deferred(o_timing_deferred),
        .o_deferred_by_direct_push(o_deferred_by_direct_push),
        .o_deferred_by_scheduling_pop(o_deferred_by_scheduling_pop),
        .o_deferred_by_parent_backpressure(
            o_deferred_by_schedule_backpressure),
        .o_shaping_deferred_cycles(o_timing_deferred_cycles),
        .o_release_delay_last(o_release_delay_last),
        .o_release_delay_max(o_release_delay_max),
        .o_shaping_event_table_count(o_timing_event_table_count),
        .o_shaping_release_fifo_count(o_timing_release_fifo_count),
        .o_shaping_logical_count(o_timing_logical_count),
        .o_shaping_logical_pending_count(
            o_timing_logical_pending_count),
        .o_scheduler_logical_count(o_schedule_logical_count),
        .o_scheduler_pending_count(o_schedule_pending_count),
        .o_shaping_busy(o_timing_busy),
        .o_scheduler_busy(o_schedule_busy),
        .o_busy(o_busy),
        .o_protocol_error(stage5_protocol_error)
    );

    // Invalid global IDs are ordinary rejected requests; the protocol error
    // remains reserved for internal accounting/invariant failures.
    assign o_protocol_error = stage5_protocol_error ||
        (o_packet_out_valid && !schedule_output_local_valid);

    initial begin
        if ((GLOBAL_NODE_NUM < 3) ||
            (SCHEDULE_LOGICAL_TREE_NUM < 2) ||
            (SCHEDULE_SEMANTIC_TREE_NUM < 1) ||
            (TIMING_LOGICAL_TREE_NUM < 1))
            $fatal(1, "GeneralizedVPIFO parameters invalid");
    end

endmodule
