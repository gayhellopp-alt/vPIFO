`timescale 1ns / 10ps

// Stage-28-compatible multi-logical shaping engine.
//
//   event input -> EventTable + heterogeneous BMW Push
//   registered logical heads -> due arbitration -> heterogeneous BMW Pops
//   PopResultFIFO output -> per-logical completion slots -> rank reorder
//   -> backpressurable ID-only ShapingReleaseFIFO -> EventTable payload read
//
// A release FIFO credit is reserved when a timer Pop is captured.  Because
// BMW Pop results cannot be backpressured, this is the point at which capacity
// must be guaranteed.  A reservation is cleared only after its result enters
// the release FIFO.
module MultiLogicalShapingPIFO #(
    parameter TIME_WIDTH = 16,
    parameter SEQUENCE_WIDTH = 8,
    parameter integer SAFE_SEQUENCE_WRAP = 0,
    parameter EVENT_DATA_WIDTH = 64,
    parameter EVENT_TABLE_DEPTH = 16,
    parameter RELEASE_FIFO_DEPTH = 8,
    parameter RELEASE_ISSUE_PORTS = 2,
    parameter LEVEL = 4,
    parameter LOGICAL_TREE_NUM = 2,
    parameter PHYSICAL_TREE_NUM = 3,
    parameter SHARD_CAPACITY = 30,
    parameter MAX_SHARDS_PER_LOGICAL = 2,
    parameter FIFO_SIZE = 8,
    parameter TASK_ORDER_WIDTH = 32,
    parameter LOGICAL_PENDING_DEPTH =
        RELEASE_ISSUE_PORTS + FIFO_SIZE + 1,
    parameter HEAD_SUMMARY_REGISTERED = 1,
    parameter integer USE_EXPLICIT_SHARD_MAP = 0,
    parameter integer SHARD_COUNTS [0:LOGICAL_TREE_NUM-1] = '{default:1},
    parameter integer SHARD_OFFSETS [0:LOGICAL_TREE_NUM-1] = '{default:0},
    parameter integer EXPLICIT_SHARD_MAP [0:PHYSICAL_TREE_NUM-1] =
        '{default:0},

    localparam RANK_WIDTH = TIME_WIDTH + SEQUENCE_WIDTH,
    localparam EVENT_ID_WIDTH = (EVENT_TABLE_DEPTH <= 1) ? 1 :
                                $clog2(EVENT_TABLE_DEPTH),
    localparam LOGICAL_ID_WIDTH = (LOGICAL_TREE_NUM <= 1) ? 1 :
                                  $clog2(LOGICAL_TREE_NUM),
    localparam PHYSICAL_ID_WIDTH = (PHYSICAL_TREE_NUM <= 1) ? 1 :
                                   $clog2(PHYSICAL_TREE_NUM),
    localparam SHARD_COUNT_WIDTH = (SHARD_CAPACITY <= 1) ? 1 :
                                   $clog2(SHARD_CAPACITY + 1),
    localparam TOTAL_COUNT_WIDTH =
        (PHYSICAL_TREE_NUM * SHARD_CAPACITY <= 1) ? 1 :
        $clog2(PHYSICAL_TREE_NUM * SHARD_CAPACITY + 1),
    localparam PENDING_COUNT_WIDTH =
        (LOGICAL_PENDING_DEPTH <= 1) ? 1 :
        $clog2(LOGICAL_PENDING_DEPTH + 1),
    localparam TABLE_COUNT_WIDTH = (EVENT_TABLE_DEPTH <= 1) ? 1 :
                                   $clog2(EVENT_TABLE_DEPTH + 1),
    localparam RELEASE_COUNT_WIDTH = (RELEASE_FIFO_DEPTH <= 1) ? 1 :
                                     $clog2(RELEASE_FIFO_DEPTH + 1),
    localparam ISSUE_COUNT_WIDTH = (RELEASE_ISSUE_PORTS <= 1) ? 1 :
                                   $clog2(RELEASE_ISSUE_PORTS + 1),
    localparam REQUEST_PORTS = RELEASE_ISSUE_PORTS + 1,
    localparam CORE_DATA_WIDTH = EVENT_ID_WIDTH + RANK_WIDTH,
    localparam SHARD_LIST_COUNT_WIDTH =
        (MAX_SHARDS_PER_LOGICAL <= 1) ? 1 :
        $clog2(MAX_SHARDS_PER_LOGICAL + 1),
    localparam RR_WIDTH = (MAX_SHARDS_PER_LOGICAL <= 1) ? 1 :
                          $clog2(MAX_SHARDS_PER_LOGICAL),
    localparam SOURCE_PORT_WIDTH = (REQUEST_PORTS <= 1) ? 1 :
                                   $clog2(REQUEST_PORTS)
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,
    input  wire [TIME_WIDTH-1:0]        i_time,

    input  wire                         i_event_valid,
    output wire                         o_event_ready,
    input  wire [LOGICAL_ID_WIDTH-1:0]  i_event_logical_tree_id,
    input  wire [TIME_WIDTH-1:0]        i_event_release_time,
    input  wire [EVENT_DATA_WIDTH-1:0]  i_event_data,

    output wire                         o_release_valid,
    input  wire                         i_release_ready,
    output wire [EVENT_ID_WIDTH-1:0]    o_release_event_id,
    output wire [LOGICAL_ID_WIDTH-1:0]  o_release_logical_tree_id,
    output wire [TIME_WIDTH-1:0]        o_release_time,
    output wire [EVENT_DATA_WIDTH-1:0]  o_release_data,

    output wire [LOGICAL_TREE_NUM-1:0]  o_logical_head_valid,
    output wire [RANK_WIDTH-1:0]        o_logical_head_rank [0:LOGICAL_TREE_NUM-1],
    output wire [PHYSICAL_ID_WIDTH-1:0] o_logical_head_physical_tree_id [0:LOGICAL_TREE_NUM-1],
    output wire [LOGICAL_TREE_NUM-1:0]  o_release_reserved,
    output wire [LOGICAL_TREE_NUM-1:0]  o_completion_valid,
    output wire [RELEASE_ISSUE_PORTS-1:0] o_due_issue_valid,
    output wire [RELEASE_ISSUE_PORTS-1:0] o_due_capture_fire,
    output wire [LOGICAL_ID_WIDTH-1:0]
        o_due_issue_logical_tree_id [0:RELEASE_ISSUE_PORTS-1],
    output wire [PHYSICAL_ID_WIDTH-1:0]
        o_due_issue_physical_tree_id [0:RELEASE_ISSUE_PORTS-1],
    output wire [RANK_WIDTH-1:0]
        o_due_issue_rank [0:RELEASE_ISSUE_PORTS-1],
    output wire [ISSUE_COUNT_WIDTH-1:0] o_due_issue_count,

    output wire [LOGICAL_TREE_NUM-1:0]  o_core_dispatch_fire,
    output wire [PHYSICAL_ID_WIDTH-1:0]
        o_core_selected_physical_tree_id [0:LOGICAL_TREE_NUM-1],
    output wire [PENDING_COUNT_WIDTH-1:0]
        o_logical_pending_count [0:LOGICAL_TREE_NUM-1],
    output wire [TOTAL_COUNT_WIDTH-1:0]
        o_logical_count [0:LOGICAL_TREE_NUM-1],
    output wire [SHARD_COUNT_WIDTH-1:0]
        o_shard_count [0:PHYSICAL_TREE_NUM-1],
    output wire [RANK_WIDTH-1:0]
        o_shard_head_rank [0:PHYSICAL_TREE_NUM-1],
    output wire                         o_shard_head_valid [0:PHYSICAL_TREE_NUM-1],
    output wire                         o_shard_update_pending [0:PHYSICAL_TREE_NUM-1],
    output wire [TABLE_COUNT_WIDTH-1:0] o_event_table_count,
    output wire [RELEASE_COUNT_WIDTH-1:0] o_release_fifo_count,
    output wire                         o_busy,
    output wire                         o_protocol_error
);

    // Declared before the EventTable instance to avoid an implicit-net
    // declaration in Vivado 2019.2.
    wire input_capture_fire;

    initial begin
        if ((TIME_WIDTH < 1) || (SEQUENCE_WIDTH < 1) ||
            ((SAFE_SEQUENCE_WRAP != 0) && (SAFE_SEQUENCE_WRAP != 1)) ||
            (EVENT_DATA_WIDTH < 1) || (EVENT_TABLE_DEPTH < 1) ||
            (RELEASE_FIFO_DEPTH < 1) ||
            (RELEASE_ISSUE_PORTS < 1) || (LEVEL < 1) ||
            (LOGICAL_TREE_NUM < 1) || (PHYSICAL_TREE_NUM < 1) ||
            (LOGICAL_PENDING_DEPTH < REQUEST_PORTS))
            $fatal(1, "MultiLogicalShapingPIFO parameters are invalid");
    end

    // ------------------------------------------------------------------
    // Event table allocation/read/free
    // ------------------------------------------------------------------
    wire event_table_allocate_ready;
    wire [EVENT_ID_WIDTH-1:0] event_table_allocate_id;
    wire event_table_read_valid;
    wire [EVENT_DATA_WIDTH-1:0] event_table_read_data;
    wire [TIME_WIDTH-1:0] event_table_read_release_time;
    wire [EVENT_ID_WIDTH-1:0] event_table_read_id;
    wire event_table_protocol_error;
    wire [EVENT_TABLE_DEPTH-1:0] event_table_valid_entries;
    wire release_fifo_dequeue_valid;
    wire [EVENT_ID_WIDTH-1:0] release_fifo_dequeue_event_id;
    wire [LOGICAL_ID_WIDTH-1:0] release_fifo_dequeue_logical_id;

    wire release_fifo_dequeue_fire =
        o_release_valid && i_release_ready;

    assign event_table_read_id = release_fifo_dequeue_event_id;
    assign o_release_valid = release_fifo_dequeue_valid &&
        event_table_read_valid;
    assign o_release_event_id = o_release_valid ?
        release_fifo_dequeue_event_id : {EVENT_ID_WIDTH{1'b0}};
    assign o_release_logical_tree_id = o_release_valid ?
        release_fifo_dequeue_logical_id : {LOGICAL_ID_WIDTH{1'b0}};
    assign o_release_time = o_release_valid ?
        event_table_read_release_time : {TIME_WIDTH{1'b0}};
    assign o_release_data = o_release_valid ?
        event_table_read_data : {EVENT_DATA_WIDTH{1'b0}};

    ShapingEventTable #(
        .EVENT_DATA_WIDTH(EVENT_DATA_WIDTH),
        .TIME_WIDTH(TIME_WIDTH),
        .DEPTH(EVENT_TABLE_DEPTH)
    ) event_table (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_allocate_fire(input_capture_fire),
        .i_allocate_data(i_event_data),
        .i_allocate_release_time(i_event_release_time),
        .o_allocate_ready(event_table_allocate_ready),
        .o_allocate_id(event_table_allocate_id),
        .i_read_id(event_table_read_id),
        .o_read_valid(event_table_read_valid),
        .o_read_data(event_table_read_data),
        .o_read_release_time(event_table_read_release_time),
        .i_free_fire(release_fifo_dequeue_fire),
        .i_free_id(o_release_event_id),
        .o_count(o_event_table_count),
        .o_valid_entries(event_table_valid_entries),
        .o_protocol_error(event_table_protocol_error)
    );

    // ------------------------------------------------------------------
    // Stage-28 HeterogeneousPIFO request interface
    // ------------------------------------------------------------------
    reg [REQUEST_PORTS-1:0] core_req_valid;
    reg [REQUEST_PORTS-1:0] core_req_push;
    reg [LOGICAL_ID_WIDTH-1:0]
        core_req_logical_tree_id [0:REQUEST_PORTS-1];
    reg [CORE_DATA_WIDTH-1:0]
        core_req_push_data [0:REQUEST_PORTS-1];
    reg [TASK_ORDER_WIDTH-1:0]
        core_req_order [0:REQUEST_PORTS-1];
    reg [REQUEST_PORTS-1:0]
        core_req_merge_mask [0:REQUEST_PORTS-1];

    wire [REQUEST_PORTS-1:0] core_req_capture_ready;
    wire [REQUEST_PORTS-1:0] core_req_capture_fire;
    wire [REQUEST_PORTS-1:0] core_req_capture_bad_id;
    wire [LOGICAL_TREE_NUM-1:0] core_dispatch_push;
    wire [LOGICAL_ID_WIDTH-1:0]
        core_dispatch_logical_id [0:LOGICAL_TREE_NUM-1];
    wire [CORE_DATA_WIDTH-1:0]
        core_dispatch_data [0:LOGICAL_TREE_NUM-1];
    wire [SOURCE_PORT_WIDTH-1:0]
        core_dispatch_source_port [0:LOGICAL_TREE_NUM-1];
    wire [LOGICAL_TREE_NUM-1:0] core_dispatch_reject_empty;
    wire [LOGICAL_TREE_NUM-1:0] core_dispatch_reject_full;
    wire [PENDING_COUNT_WIDTH-1:0] core_pending_count;
    wire [PENDING_COUNT_WIDTH-1:0]
        core_pending_effective_free_count;
    wire core_busy;
    wire core_pop_valid;
    wire [LOGICAL_ID_WIDTH-1:0] core_pop_logical_tree_id;
    wire [CORE_DATA_WIDTH-1:0] core_pop_data;
    wire core_protocol_error;
    wire [LEVEL-1:0] core_task_fifo_full;
    wire [LEVEL-1:0] core_task_write;
    wire [LEVEL-1:0] core_task_push;
    wire [LEVEL-1:0] core_task_pop;
    wire [PHYSICAL_ID_WIDTH-1:0]
        unused_shard_list [0:LOGICAL_TREE_NUM-1]
                          [0:MAX_SHARDS_PER_LOGICAL-1];
    wire [SHARD_LIST_COUNT_WIDTH-1:0]
        unused_logical_shard_count [0:LOGICAL_TREE_NUM-1];
    wire [RR_WIDTH-1:0]
        unused_push_rr_ptr [0:LOGICAL_TREE_NUM-1];
    wire core_shard_empty [0:PHYSICAL_TREE_NUM-1];
    wire core_shard_full [0:PHYSICAL_TREE_NUM-1];
    wire core_logical_busy_unpacked [0:LOGICAL_TREE_NUM-1];
    wire [LOGICAL_ID_WIDTH-1:0]
        unused_pending_logical_tree_id [0:PHYSICAL_TREE_NUM-1];
    wire unused_pending_push [0:PHYSICAL_TREE_NUM-1];

    wire input_logical_id_valid =
        int'(i_event_logical_tree_id) < LOGICAL_TREE_NUM;
    reg sequence_wrap_pending;
    wire sequence_accept_ready =
        (SAFE_SEQUENCE_WRAP == 0) || !sequence_wrap_pending;
    reg input_logical_has_capacity;
    integer input_capacity_scan;
    always @* begin
        input_logical_has_capacity = 1'b0;
        for (input_capacity_scan = 0;
             input_capacity_scan < LOGICAL_TREE_NUM;
             input_capacity_scan = input_capacity_scan + 1) begin
            if (input_logical_id_valid &&
                (int'(i_event_logical_tree_id) == input_capacity_scan))
                input_logical_has_capacity =
                    int'(o_logical_count[input_capacity_scan]) <
                    (SHARD_COUNTS[input_capacity_scan] * SHARD_CAPACITY);
        end
    end

    wire input_request_valid = i_event_valid &&
        input_logical_id_valid && input_logical_has_capacity &&
        event_table_allocate_ready && sequence_accept_ready;
    assign o_event_ready = input_logical_id_valid &&
        input_logical_has_capacity && event_table_allocate_ready &&
        core_req_capture_ready[0] && sequence_accept_ready;
    assign input_capture_fire = core_req_capture_fire[0];

    reg [SEQUENCE_WIDTH-1:0] sequence_counter;
    reg [TASK_ORDER_WIDTH-1:0] request_order_base;
    wire [RANK_WIDTH-1:0] input_rank =
        {i_event_release_time, sequence_counter};

    // ------------------------------------------------------------------
    // Logical-head summary and due selection
    // ------------------------------------------------------------------
    wire [LOGICAL_TREE_NUM-1:0] logical_busy_packed;
    wire [LOGICAL_TREE_NUM-1:0] logical_pending_nonzero;
    genvar logical_pack;
    generate
        for (logical_pack = 0; logical_pack < LOGICAL_TREE_NUM;
             logical_pack = logical_pack + 1) begin : GEN_LOGICAL_PACK
            assign logical_busy_packed[logical_pack] =
                core_logical_busy_unpacked[logical_pack];
            assign logical_pending_nonzero[logical_pack] =
                o_logical_pending_count[logical_pack] !=
                {PENDING_COUNT_WIDTH{1'b0}};
        end
    endgenerate

    ShapingLogicalHeadSummary #(
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(PHYSICAL_TREE_NUM),
        .MAX_SHARDS_PER_LOGICAL(MAX_SHARDS_PER_LOGICAL),
        .RANK_WIDTH(RANK_WIDTH),
        .REGISTER_OUTPUT(HEAD_SUMMARY_REGISTERED),
        .USE_EXPLICIT_SHARD_MAP(USE_EXPLICIT_SHARD_MAP),
        .SHARD_COUNTS(SHARD_COUNTS),
        .SHARD_OFFSETS(SHARD_OFFSETS),
        .EXPLICIT_SHARD_MAP(EXPLICIT_SHARD_MAP)
    ) logical_head_summary (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_shard_head_rank(o_shard_head_rank),
        .i_shard_head_valid(o_shard_head_valid),
        .i_shard_update_pending(o_shard_update_pending),
        .o_head_valid(o_logical_head_valid),
        .o_head_rank(o_logical_head_rank),
        .o_head_physical_tree_id(o_logical_head_physical_tree_id)
    );

    reg [LOGICAL_TREE_NUM-1:0] input_blocked_logical;
    always @* begin
        input_blocked_logical = {LOGICAL_TREE_NUM{1'b0}};
        // Only the target logical PIFO is blocked.  Other due PIFOs may make
        // progress while this insertion is captured or waits for a slot.
        if (input_request_valid)
            input_blocked_logical[i_event_logical_tree_id] = 1'b1;
    end

    reg [LOGICAL_TREE_NUM-1:0] release_reserved_reg;
    reg [RANK_WIDTH-1:0] reserved_rank [0:LOGICAL_TREE_NUM-1];
    reg [LOGICAL_TREE_NUM-1:0] completion_valid_reg;
    reg [EVENT_ID_WIDTH-1:0]
        completion_event_id [0:LOGICAL_TREE_NUM-1];

    // A later logical head must not pass an older head whose value is
    // temporarily unavailable or whose logical PIFO is processing a normal
    // shaping insertion.  Reserved timer Pops are exempt: their ranks are
    // already represented in the completion reorder state below.
    reg logical_head_unknown;
    integer unknown_scan;
    always @* begin
        logical_head_unknown = 1'b0;
        for (unknown_scan = 0; unknown_scan < LOGICAL_TREE_NUM;
             unknown_scan = unknown_scan + 1) begin
            if ((o_logical_count[unknown_scan] !=
                 {TOTAL_COUNT_WIDTH{1'b0}}) &&
                !o_logical_head_valid[unknown_scan] &&
                !release_reserved_reg[unknown_scan])
                logical_head_unknown = 1'b1;
        end
    end
    wire global_order_barrier = input_request_valid ||
        (|(logical_pending_nonzero & ~release_reserved_reg)) ||
        logical_head_unknown;

    integer reserved_count_integer;
    integer release_credit_integer;
    integer pending_budget_integer;
    integer issue_limit_integer;
    reg [ISSUE_COUNT_WIDTH-1:0] issue_limit;
    integer credit_scan;
    always @* begin
        reserved_count_integer = 0;
        for (credit_scan = 0; credit_scan < LOGICAL_TREE_NUM;
             credit_scan = credit_scan + 1)
            if (release_reserved_reg[credit_scan])
                reserved_count_integer = reserved_count_integer + 1;

        release_credit_integer = RELEASE_FIFO_DEPTH -
            int'(o_release_fifo_count) - reserved_count_integer;
        pending_budget_integer =
            int'(core_pending_effective_free_count) -
            (input_request_valid ? 1 : 0);
        issue_limit_integer = RELEASE_ISSUE_PORTS;
        if (release_credit_integer < issue_limit_integer)
            issue_limit_integer = release_credit_integer;
        if (pending_budget_integer < issue_limit_integer)
            issue_limit_integer = pending_budget_integer;
        if (issue_limit_integer < 0)
            issue_limit_integer = 0;
        issue_limit = issue_limit_integer[ISSUE_COUNT_WIDTH-1:0];
    end

    wire [RELEASE_ISSUE_PORTS-1:0] due_issue_valid;
    wire [LOGICAL_ID_WIDTH-1:0]
        due_issue_logical_id [0:RELEASE_ISSUE_PORTS-1];
    wire [PHYSICAL_ID_WIDTH-1:0]
        due_issue_physical_id [0:RELEASE_ISSUE_PORTS-1];
    wire [RANK_WIDTH-1:0]
        due_issue_rank [0:RELEASE_ISSUE_PORTS-1];

    ShapingDueArbiter #(
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(PHYSICAL_TREE_NUM),
        .TIME_WIDTH(TIME_WIDTH),
        .SEQUENCE_WIDTH(SEQUENCE_WIDTH),
        .ISSUE_PORTS(RELEASE_ISSUE_PORTS)
    ) due_arbiter (
        .i_time(i_time),
        .i_head_valid(o_logical_head_valid),
        .i_head_rank(o_logical_head_rank),
        .i_head_physical_tree_id(o_logical_head_physical_tree_id),
        .i_logical_busy(logical_busy_packed),
        .i_logical_pending(logical_pending_nonzero),
        .i_reserved(release_reserved_reg),
        .i_blocked(input_blocked_logical),
        .i_global_barrier(global_order_barrier),
        .i_issue_limit(issue_limit),
        .o_issue_valid(due_issue_valid),
        .o_issue_logical_tree_id(due_issue_logical_id),
        .o_issue_physical_tree_id(due_issue_physical_id),
        .o_issue_rank(due_issue_rank),
        .o_issue_count(o_due_issue_count)
    );

    integer request_port;
    always @* begin
        core_req_valid = {REQUEST_PORTS{1'b0}};
        core_req_push = {REQUEST_PORTS{1'b0}};
        for (request_port = 0; request_port < REQUEST_PORTS;
             request_port = request_port + 1) begin
            core_req_logical_tree_id[request_port] =
                {LOGICAL_ID_WIDTH{1'b0}};
            core_req_push_data[request_port] =
                {CORE_DATA_WIDTH{1'b1}};
            core_req_order[request_port] = request_order_base +
                request_port[TASK_ORDER_WIDTH-1:0];
            core_req_merge_mask[request_port] =
                {REQUEST_PORTS{1'b0}};
        end

        core_req_valid[0] = input_request_valid;
        core_req_push[0] = 1'b1;
        core_req_logical_tree_id[0] = i_event_logical_tree_id;
        core_req_push_data[0] = {event_table_allocate_id, input_rank};

        for (request_port = 0;
             request_port < RELEASE_ISSUE_PORTS;
             request_port = request_port + 1) begin
            core_req_valid[request_port + 1] =
                due_issue_valid[request_port];
            core_req_push[request_port + 1] = 1'b0;
            core_req_logical_tree_id[request_port + 1] =
                due_issue_logical_id[request_port];
            core_req_push_data[request_port + 1] =
                {CORE_DATA_WIDTH{1'b1}};
        end
    end

    genvar due_output;
    generate
        for (due_output = 0; due_output < RELEASE_ISSUE_PORTS;
             due_output = due_output + 1) begin : GEN_DUE_OUTPUT
            assign o_due_issue_logical_tree_id[due_output] =
                due_issue_logical_id[due_output];
            assign o_due_issue_physical_tree_id[due_output] =
                due_issue_physical_id[due_output];
            assign o_due_issue_rank[due_output] =
                due_issue_rank[due_output];
            assign o_due_capture_fire[due_output] =
                core_req_capture_fire[due_output + 1];
        end
    endgenerate
    assign o_due_issue_valid = due_issue_valid;

    HeterogeneousPIFO #(
        .PTW(RANK_WIDTH),
        .MTW(EVENT_ID_WIDTH),
        .CTW(10),
        .LEVEL(LEVEL),
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(PHYSICAL_TREE_NUM),
        .SHARD_CAPACITY(SHARD_CAPACITY),
        .FIFO_SIZE(FIFO_SIZE),
        .MAX_SHARDS_PER_LOGICAL(MAX_SHARDS_PER_LOGICAL),
        .REQUEST_PORTS(REQUEST_PORTS),
        .TASK_ORDER_WIDTH(TASK_ORDER_WIDTH),
        .LOGICAL_PENDING_DEPTH(LOGICAL_PENDING_DEPTH),
        .POP_RESULT_FIFO_DEPTH(LOGICAL_TREE_NUM + LEVEL),
        .HIERARCHICAL_MODE(0),
        .USE_EXPLICIT_SHARD_MAP(USE_EXPLICIT_SHARD_MAP),
        .SHARD_COUNTS(SHARD_COUNTS),
        .SHARD_OFFSETS(SHARD_OFFSETS),
        .EXPLICIT_SHARD_MAP(EXPLICIT_SHARD_MAP)
    ) shaping_core (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_req_valid(core_req_valid),
        .i_req_push(core_req_push),
        .i_req_pop(~core_req_push),
        .i_logical_tree_id(core_req_logical_tree_id),
        .i_push_data(core_req_push_data),
        .i_req_order(core_req_order),
        .i_req_merge_mask(core_req_merge_mask),
        .o_req_capture_ready(core_req_capture_ready),
        .o_req_capture_fire(core_req_capture_fire),
        .o_req_capture_bad_id(core_req_capture_bad_id),
        .o_dispatch_fire(o_core_dispatch_fire),
        .o_dispatch_push(core_dispatch_push),
        .o_dispatch_logical_tree_id(core_dispatch_logical_id),
        .o_selected_physical_tree_id(
            o_core_selected_physical_tree_id),
        .o_dispatch_data(core_dispatch_data),
        .o_dispatch_source_port(core_dispatch_source_port),
        .o_dispatch_reject_empty(core_dispatch_reject_empty),
        .o_dispatch_reject_full(core_dispatch_reject_full),
        .o_logical_pending_count(o_logical_pending_count),
        .o_pending_count(core_pending_count),
        .o_pending_effective_free_count(
            core_pending_effective_free_count),
        .o_busy(core_busy),
        .o_pop_valid(core_pop_valid),
        .o_pop_logical_tree_id(core_pop_logical_tree_id),
        .o_pop_data(core_pop_data),
        .o_internal_root_pop_valid(),
        .o_internal_root_pop_data(),
        .o_protocol_error(core_protocol_error),
        .o_task_fifo_full(core_task_fifo_full),
        .o_task_write(core_task_write),
        .o_task_push(core_task_push),
        .o_task_pop(core_task_pop),
        .o_shard_list(unused_shard_list),
        .o_logical_shard_count(unused_logical_shard_count),
        .o_logical_count(o_logical_count),
        .o_push_rr_ptr(unused_push_rr_ptr),
        .o_shard_count(o_shard_count),
        .o_shard_head_rank(o_shard_head_rank),
        .o_shard_empty(core_shard_empty),
        .o_shard_full(core_shard_full),
        .o_shard_head_valid(o_shard_head_valid),
        .o_update_pending(o_shard_update_pending),
        .o_logical_busy(core_logical_busy_unpacked),
        .o_pending_logical_tree_id(
            unused_pending_logical_tree_id),
        .o_pending_push(unused_pending_push)
    );

    // ------------------------------------------------------------------
    // Completion capture and global release-order restoration
    // ------------------------------------------------------------------
    wire [EVENT_ID_WIDTH-1:0] core_pop_event_id =
        core_pop_data[CORE_DATA_WIDTH-1 -: EVENT_ID_WIDTH];
    wire [RANK_WIDTH-1:0] core_pop_rank =
        core_pop_data[RANK_WIDTH-1:0];
    integer core_pop_event_index;
    reg core_pop_event_valid;
    always @* begin
        core_pop_event_index = int'(core_pop_event_id);
        core_pop_event_valid = 1'b0;
        if ((core_pop_event_index >= 0) &&
            (core_pop_event_index < EVENT_TABLE_DEPTH))
            core_pop_event_valid =
                event_table_valid_entries[core_pop_event_index];
    end

    reg completion_emit_reserved_found;
    reg [LOGICAL_ID_WIDTH-1:0] completion_emit_logical_id;
    reg [RANK_WIDTH-1:0] completion_emit_rank;
    integer completion_scan;
    always @* begin
        completion_emit_reserved_found = 1'b0;
        completion_emit_logical_id = {LOGICAL_ID_WIDTH{1'b0}};
        completion_emit_rank = {RANK_WIDTH{1'b1}};
        for (completion_scan = 0;
             completion_scan < LOGICAL_TREE_NUM;
             completion_scan = completion_scan + 1) begin
            if (release_reserved_reg[completion_scan] &&
                (!completion_emit_reserved_found ||
                 (reserved_rank[completion_scan] <
                  completion_emit_rank) ||
                 ((reserved_rank[completion_scan] ==
                   completion_emit_rank) &&
                  (completion_scan <
                   completion_emit_logical_id)))) begin
                completion_emit_reserved_found = 1'b1;
                completion_emit_logical_id =
                    completion_scan[LOGICAL_ID_WIDTH-1:0];
                completion_emit_rank = reserved_rank[completion_scan];
            end
        end
    end

    wire release_fifo_enqueue_valid =
        completion_emit_reserved_found &&
        completion_valid_reg[completion_emit_logical_id];
    wire release_fifo_enqueue_ready;
    wire release_fifo_enqueue_fire =
        release_fifo_enqueue_valid && release_fifo_enqueue_ready;
    wire release_fifo_overflow;

    ShapingReleaseFIFO #(
        .EVENT_ID_WIDTH(EVENT_ID_WIDTH),
        .LOGICAL_ID_WIDTH(LOGICAL_ID_WIDTH),
        .DEPTH(RELEASE_FIFO_DEPTH)
    ) release_fifo (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_enqueue_valid(release_fifo_enqueue_valid),
        .o_enqueue_ready(release_fifo_enqueue_ready),
        .i_enqueue_event_id(
            completion_event_id[completion_emit_logical_id]),
        .i_enqueue_logical_id(completion_emit_logical_id),
        .o_dequeue_valid(release_fifo_dequeue_valid),
        .i_dequeue_ready(i_release_ready && event_table_read_valid),
        .o_dequeue_event_id(release_fifo_dequeue_event_id),
        .o_dequeue_logical_id(release_fifo_dequeue_logical_id),
        .o_count(o_release_fifo_count),
        .o_overflow(release_fifo_overflow)
    );

    // With safe wrap enabled, accepting the maximum sequence value closes the
    // input epoch.  Ordinary unsigned rank comparisons remain valid because a
    // new epoch is not admitted until every old-epoch event has left all
    // shaping storage and in-flight completion state.
    wire sequence_epoch_drained =
        !core_busy &&
        (o_event_table_count == {TABLE_COUNT_WIDTH{1'b0}}) &&
        (o_release_fifo_count == {RELEASE_COUNT_WIDTH{1'b0}}) &&
        !(|release_reserved_reg) && !(|completion_valid_reg);

    reg local_protocol_error;
    integer reset_logical;
    integer capture_issue;
    integer pop_logical_integer;
    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            sequence_counter <= {SEQUENCE_WIDTH{1'b0}};
            sequence_wrap_pending <= 1'b0;
            request_order_base <= {TASK_ORDER_WIDTH{1'b0}};
            release_reserved_reg <= {LOGICAL_TREE_NUM{1'b0}};
            completion_valid_reg <= {LOGICAL_TREE_NUM{1'b0}};
            local_protocol_error <= 1'b0;
            for (reset_logical = 0;
                 reset_logical < LOGICAL_TREE_NUM;
                 reset_logical = reset_logical + 1) begin
                reserved_rank[reset_logical] <= {RANK_WIDTH{1'b1}};
                completion_event_id[reset_logical] <=
                    {EVENT_ID_WIDTH{1'b0}};
            end
        end else begin
            request_order_base <= request_order_base + REQUEST_PORTS;

            if (i_event_valid && !input_logical_id_valid)
                local_protocol_error <= 1'b1;
            if (|core_req_capture_bad_id)
                local_protocol_error <= 1'b1;
            if ((|core_dispatch_reject_empty) ||
                (|core_dispatch_reject_full))
                local_protocol_error <= 1'b1;
            if (release_fifo_enqueue_valid &&
                !release_fifo_enqueue_ready)
                local_protocol_error <= 1'b1;
            if (release_fifo_dequeue_valid &&
                !event_table_read_valid)
                local_protocol_error <= 1'b1;

            if (SAFE_SEQUENCE_WRAP != 0) begin
                if (sequence_wrap_pending) begin
                    if (sequence_epoch_drained) begin
                        sequence_counter <= {SEQUENCE_WIDTH{1'b0}};
                        sequence_wrap_pending <= 1'b0;
                    end
                end else if (input_capture_fire) begin
                    if (&sequence_counter) begin
                        sequence_wrap_pending <= 1'b1;
                    end else begin
                        sequence_counter <= sequence_counter + 1'b1;
                    end
                end
            end else if (input_capture_fire) begin
                if (&sequence_counter &&
                    ((o_event_table_count != 0) ||
                     (o_release_fifo_count != 0) ||
                     (|release_reserved_reg)))
                    local_protocol_error <= 1'b1;
                sequence_counter <= sequence_counter + 1'b1;
            end

            if (&request_order_base &&
                (core_busy || (|release_reserved_reg)))
                local_protocol_error <= 1'b1;

            for (capture_issue = 0;
                 capture_issue < RELEASE_ISSUE_PORTS;
                capture_issue = capture_issue + 1) begin
                if (core_req_capture_fire[capture_issue + 1]) begin
                    if (release_reserved_reg[
                            due_issue_logical_id[capture_issue]]) begin
                        local_protocol_error <= 1'b1;
                    end
                    release_reserved_reg[
                        due_issue_logical_id[capture_issue]] <= 1'b1;
                    reserved_rank[
                        due_issue_logical_id[capture_issue]] <=
                            due_issue_rank[capture_issue];
                end
            end

            if (core_pop_valid) begin
                pop_logical_integer = int'(core_pop_logical_tree_id);
                if ((pop_logical_integer < 0) ||
                    (pop_logical_integer >= LOGICAL_TREE_NUM)) begin
                    local_protocol_error <= 1'b1;
                end else begin
                    if (!release_reserved_reg[pop_logical_integer] ||
                        completion_valid_reg[pop_logical_integer] ||
                        !core_pop_event_valid ||
                        (core_pop_rank !=
                         reserved_rank[pop_logical_integer]) ||
                        (i_time <
                         core_pop_rank[RANK_WIDTH-1 -: TIME_WIDTH]))
                        local_protocol_error <= 1'b1;
                    completion_valid_reg[pop_logical_integer] <= 1'b1;
                    completion_event_id[pop_logical_integer] <=
                        core_pop_event_id;
                end
            end

            if (release_fifo_enqueue_fire) begin
                release_reserved_reg[completion_emit_logical_id] <= 1'b0;
                completion_valid_reg[completion_emit_logical_id] <= 1'b0;
            end
        end
    end

    assign o_release_reserved = release_reserved_reg;
    assign o_completion_valid = completion_valid_reg;
    assign o_busy = core_busy ||
        (o_event_table_count != {TABLE_COUNT_WIDTH{1'b0}}) ||
        (o_release_fifo_count != {RELEASE_COUNT_WIDTH{1'b0}}) ||
        (|release_reserved_reg) || (|completion_valid_reg) ||
        ((SAFE_SEQUENCE_WRAP != 0) && sequence_wrap_pending);
    assign o_protocol_error = local_protocol_error ||
        core_protocol_error || event_table_protocol_error ||
        release_fifo_overflow;

endmodule
