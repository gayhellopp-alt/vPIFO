`timescale 1ns / 10ps

// Packet-level two-tier wrapper with vector task generation.
//
// Request port assignment:
//   0                         packet leaf Push
//   1                         packet root Push
//   2                         external root Pop
//   3 + logical_id            routed leaf Pop
//
// Packet tasks are atomically captured by the core shared logical pending pool.
// Physical shard selection and physical TaskFIFO dispatch occur later, only
// when that logical PIFO's directory state is current.  Returned root tokens
// use one small queue per logical leaf, so no global root-route lock is needed.
module HierarchicalHeterogeneousPIFO #(
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
    parameter POP_RESULT_FIFO_DEPTH = LOGICAL_TREE_NUM + LEVEL,
    parameter TASK_ORDER_WIDTH = 32,
    parameter LEAF_ROUTE_QUEUE_DEPTH = FIFO_SIZE,
    parameter LOGICAL_PENDING_DEPTH =
        LOGICAL_TREE_NUM + 3 + FIFO_SIZE,
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
    localparam REQUEST_PORTS = LOGICAL_TREE_NUM + 3,
    localparam ROUTE_PTR_WIDTH =
        (LEAF_ROUTE_QUEUE_DEPTH <= 1) ? 1 :
        $clog2(LEAF_ROUTE_QUEUE_DEPTH),
    localparam ROUTE_COUNT_WIDTH =
        (LEAF_ROUTE_QUEUE_DEPTH <= 1) ? 1 :
        $clog2(LEAF_ROUTE_QUEUE_DEPTH + 1),
    localparam SOURCE_PORT_WIDTH = (REQUEST_PORTS <= 1) ? 1 :
                                   $clog2(REQUEST_PORTS),
    localparam PENDING_COUNT_WIDTH =
        (LOGICAL_PENDING_DEPTH <= 1) ? 1 :
        $clog2(LOGICAL_PENDING_DEPTH + 1)
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,

    input  wire                         i_push,
    input  wire [LOGICAL_ID_WIDTH-1:0]  i_push_tree_id,
    input  wire [PTW-1:0]               i_push_priority,
    input  wire [(MTW+PTW)-1:0]         i_push_data,
    output wire                         o_push_ready,
    output wire                         o_reject_bad_leaf_id,

    input  wire                         i_pop,
    output wire                         o_pop_req_ready,
    output wire                         o_pop_out,
    output wire [LOGICAL_ID_WIDTH-1:0]  o_pop_tree_id,
    output wire [(MTW+PTW)-1:0]         o_pop_data,

    output wire                         o_busy,
    output wire                         o_protocol_error,

    output wire [REQUEST_PORTS-1:0]     o_internal_capture_fire,
    output wire [LOGICAL_TREE_NUM-1:0]  o_internal_task_fire,
    output wire [LOGICAL_TREE_NUM-1:0]  o_internal_task_push,
    output wire [LOGICAL_ID_WIDTH-1:0]  o_internal_task_logical_tree_id [0:LOGICAL_TREE_NUM-1],
    output wire [PHYSICAL_ID_WIDTH-1:0] o_internal_task_physical_tree_id [0:LOGICAL_TREE_NUM-1],
    output wire [(MTW+PTW)-1:0]         o_internal_task_data [0:LOGICAL_TREE_NUM-1],
    output wire [PENDING_COUNT_WIDTH-1:0] o_logical_pending_count [0:LOGICAL_TREE_NUM-1],
    output wire [PENDING_COUNT_WIDTH-1:0] o_pending_count,
    output wire                         o_root_pop_routed,
    output wire [LOGICAL_ID_WIDTH-1:0]  o_root_pop_leaf_tree_id,
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

    localparam [LOGICAL_ID_WIDTH-1:0] ROOT_LOGICAL_ID =
        {LOGICAL_ID_WIDTH{1'b0}};
    localparam [LOGICAL_ID_WIDTH:0] LOGICAL_TREE_NUM_LIMIT =
        LOGICAL_TREE_NUM;

    initial begin
        if ((LOGICAL_TREE_NUM < 2) || (LEVEL < 1) ||
            (MTW < LOGICAL_ID_WIDTH) || (TASK_ORDER_WIDTH < 2) ||
            (LEAF_ROUTE_QUEUE_DEPTH < 1))
            $fatal(1, "HierarchicalHeterogeneousPIFO parameters are invalid");
    end

    reg [TASK_ORDER_WIDTH-1:0] task_order_counter;
    reg local_protocol_error;

    reg [TASK_ORDER_WIDTH-1:0]
        leaf_route_order_mem [0:LOGICAL_TREE_NUM-1]
                             [0:LEAF_ROUTE_QUEUE_DEPTH-1];
    reg [ROUTE_PTR_WIDTH-1:0]
        leaf_route_head [0:LOGICAL_TREE_NUM-1];
    reg [ROUTE_PTR_WIDTH-1:0]
        leaf_route_tail [0:LOGICAL_TREE_NUM-1];
    reg [ROUTE_COUNT_WIDTH-1:0]
        leaf_route_count [0:LOGICAL_TREE_NUM-1];

    wire [REQUEST_PORTS-1:0] core_req_valid;
    wire [REQUEST_PORTS-1:0] core_req_push;
    wire [LOGICAL_ID_WIDTH-1:0]
        core_req_logical_tree_id [0:REQUEST_PORTS-1];
    wire [(MTW+PTW)-1:0]
        core_req_push_data [0:REQUEST_PORTS-1];
    wire [TASK_ORDER_WIDTH-1:0]
        core_req_order [0:REQUEST_PORTS-1];
    wire [REQUEST_PORTS-1:0]
        core_req_merge_mask [0:REQUEST_PORTS-1];
    wire [REQUEST_PORTS-1:0] core_req_capture_ready;
    wire [REQUEST_PORTS-1:0] core_req_capture_fire;
    wire [REQUEST_PORTS-1:0] core_req_capture_bad_id;
    wire [LOGICAL_TREE_NUM-1:0] core_dispatch_fire;
    wire [LOGICAL_TREE_NUM-1:0] core_dispatch_push;
    wire [LOGICAL_ID_WIDTH-1:0]
        core_dispatch_logical_tree_id [0:LOGICAL_TREE_NUM-1];
    wire [PHYSICAL_ID_WIDTH-1:0]
        core_selected_physical_tree_id [0:LOGICAL_TREE_NUM-1];
    wire [(MTW+PTW)-1:0]
        core_dispatch_data [0:LOGICAL_TREE_NUM-1];
    wire [SOURCE_PORT_WIDTH-1:0]
        core_dispatch_source_port [0:LOGICAL_TREE_NUM-1];
    wire [LOGICAL_TREE_NUM-1:0] core_dispatch_reject_empty;
    wire [LOGICAL_TREE_NUM-1:0] core_dispatch_reject_full;
    wire [PENDING_COUNT_WIDTH-1:0]
        core_pending_effective_free_count;

    wire core_busy;
    wire core_pop_valid;
    wire [LOGICAL_ID_WIDTH-1:0] core_pop_logical_tree_id;
    wire [(MTW+PTW)-1:0] core_pop_data;
    wire core_root_pop_valid;
    wire [(MTW+PTW)-1:0] core_root_pop_data;
    wire [LOGICAL_ID_WIDTH-1:0] core_root_pop_leaf_id;
    wire core_root_pop_leaf_valid;
    wire core_protocol_error;

    wire push_leaf_id_valid;
    wire push_input_fire;
    wire pop_input_fire;

    assign push_leaf_id_valid =
        (i_push_tree_id != ROOT_LOGICAL_ID) &&
        ({1'b0, i_push_tree_id} < LOGICAL_TREE_NUM_LIMIT);
    // A packet Push expands atomically into leaf Push and root Push.  Reserve
    // two shared-pool slots before accepting the input pulse.  A simultaneous
    // external Pop is accepted only when a third slot is available.
    assign o_push_ready =
        i_arst_n &&
        (core_pending_effective_free_count >=
         (i_pop ? 3 : 2));
    assign push_input_fire =
        i_push && o_push_ready && push_leaf_id_valid;
    assign o_reject_bad_leaf_id =
        i_push && o_push_ready && !push_leaf_id_valid;

    assign o_pop_req_ready =
        i_arst_n &&
        (core_pending_effective_free_count >=
         ((i_push && push_leaf_id_valid) ? 3 : 1));
    assign pop_input_fire = i_pop && o_pop_req_ready;

    // Ports 0/1 are one atomic packet Push generation event.  Capture into the
    // logical pool is distinct from later physical TaskFIFO dispatch.
    assign core_req_valid[0] = push_input_fire;
    assign core_req_push[0] = 1'b1;
    assign core_req_logical_tree_id[0] = i_push_tree_id;
    assign core_req_push_data[0] = i_push_data;
    assign core_req_order[0] = task_order_counter;

    assign core_req_valid[1] = push_input_fire;
    assign core_req_push[1] = 1'b1;
    assign core_req_logical_tree_id[1] = ROOT_LOGICAL_ID;
    assign core_req_push_data[1] =
        {i_push_tree_id,
         {(MTW-LOGICAL_ID_WIDTH){1'b0}},
         i_push_priority};
    assign core_req_order[1] = task_order_counter;

    assign core_req_valid[2] = pop_input_fire;
    assign core_req_push[2] = 1'b0;
    assign core_req_logical_tree_id[2] = ROOT_LOGICAL_ID;
    assign core_req_push_data[2] = {(MTW+PTW){1'b1}};
    assign core_req_order[2] = task_order_counter;

    assign core_root_pop_leaf_id =
        core_root_pop_data[(MTW+PTW)-1 -: LOGICAL_ID_WIDTH];
    assign core_root_pop_leaf_valid =
        core_root_pop_valid &&
        (core_root_pop_leaf_id != ROOT_LOGICAL_ID) &&
        ({1'b0, core_root_pop_leaf_id} <
         LOGICAL_TREE_NUM_LIMIT);

    genvar route_logical;
    generate
        for (route_logical = 0;
             route_logical < LOGICAL_TREE_NUM;
             route_logical = route_logical + 1) begin :
             route_request
            localparam integer ROUTE_PORT = 3 + route_logical;
            assign core_req_valid[ROUTE_PORT] =
                (route_logical != 0) &&
                ((leaf_route_count[route_logical] != 0) ||
                 (core_root_pop_leaf_valid &&
                  (core_root_pop_leaf_id == route_logical)));
            assign core_req_push[ROUTE_PORT] = 1'b0;
            assign core_req_logical_tree_id[ROUTE_PORT] =
                route_logical[LOGICAL_ID_WIDTH-1:0];
            assign core_req_push_data[ROUTE_PORT] =
                {(MTW+PTW){1'b1}};
            assign core_req_order[ROUTE_PORT] =
                (leaf_route_count[route_logical] != 0) ?
                leaf_route_order_mem[route_logical]
                                    [leaf_route_head[
                                        route_logical]] :
                task_order_counter;
        end
    endgenerate

    // Explicit provenance authorizes P/P packing.  The core converts this
    // same-capture port relation into a relation between concrete pending
    // slots; numeric order equality alone is never sufficient.
    genvar merge_port;
    generate
        for (merge_port = 0;
             merge_port < REQUEST_PORTS;
             merge_port = merge_port + 1) begin :
             merge_relation
            assign core_req_merge_mask[merge_port] =
                (((merge_port == 0) || (merge_port == 1)) &&
                 push_input_fire && pop_input_fire) ?
                    ({{(REQUEST_PORTS-3){1'b0}}, 3'b100}) :
                ((merge_port == 2) &&
                 push_input_fire && pop_input_fire) ?
                    ({{(REQUEST_PORTS-3){1'b0}}, 3'b011}) :
                    {REQUEST_PORTS{1'b0}};
        end
    endgenerate

    integer reset_logical;
    integer reset_route_entry;
    integer route_update_logical;
    reg route_dequeue;
    reg route_enqueue;
    reg route_bypass_accept;
    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            task_order_counter <= {TASK_ORDER_WIDTH{1'b0}};
            local_protocol_error <= 1'b0;

            for (reset_logical = 0;
                 reset_logical < LOGICAL_TREE_NUM;
                 reset_logical = reset_logical + 1) begin
                leaf_route_head[reset_logical] <=
                    {ROUTE_PTR_WIDTH{1'b0}};
                leaf_route_tail[reset_logical] <=
                    {ROUTE_PTR_WIDTH{1'b0}};
                leaf_route_count[reset_logical] <=
                    {ROUTE_COUNT_WIDTH{1'b0}};
                for (reset_route_entry = 0;
                     reset_route_entry < LEAF_ROUTE_QUEUE_DEPTH;
                     reset_route_entry =
                         reset_route_entry + 1)
                    leaf_route_order_mem[reset_logical]
                        [reset_route_entry] <=
                            {TASK_ORDER_WIDTH{1'b0}};
            end
        end else begin
            task_order_counter <= task_order_counter + 1'b1;

            if (core_root_pop_valid &&
                !core_root_pop_leaf_valid)
                local_protocol_error <= 1'b1;

            for (route_update_logical = 1;
                 route_update_logical < LOGICAL_TREE_NUM;
                 route_update_logical =
                     route_update_logical + 1) begin
                route_dequeue =
                    (leaf_route_count[route_update_logical] != 0) &&
                    core_req_capture_fire[
                        3 + route_update_logical];
                route_bypass_accept =
                    (leaf_route_count[route_update_logical] == 0) &&
                    core_root_pop_leaf_valid &&
                    (int'(core_root_pop_leaf_id) ==
                     route_update_logical) &&
                    core_req_capture_fire[
                        3 + route_update_logical];
                route_enqueue =
                    core_root_pop_leaf_valid &&
                    (int'(core_root_pop_leaf_id) ==
                     route_update_logical) &&
                    !route_bypass_accept;

                if (route_enqueue &&
                    (leaf_route_count[route_update_logical] ==
                     LEAF_ROUTE_QUEUE_DEPTH) &&
                    !route_dequeue) begin
                    local_protocol_error <= 1'b1;
                end else begin
                    case ({route_enqueue, route_dequeue})
                        2'b10:
                            leaf_route_count[
                                route_update_logical] <=
                                leaf_route_count[
                                    route_update_logical] + 1'b1;
                        2'b01:
                            leaf_route_count[
                                route_update_logical] <=
                                leaf_route_count[
                                    route_update_logical] - 1'b1;
                        default:
                            leaf_route_count[
                                route_update_logical] <=
                                leaf_route_count[
                                    route_update_logical];
                    endcase

                    if (route_enqueue) begin
                        leaf_route_order_mem[
                            route_update_logical]
                            [leaf_route_tail[
                                route_update_logical]] <=
                                    task_order_counter;
                        if (leaf_route_tail[
                            route_update_logical] ==
                            ROUTE_PTR_WIDTH'(
                                LEAF_ROUTE_QUEUE_DEPTH - 1))
                            leaf_route_tail[
                                route_update_logical] <=
                                    {ROUTE_PTR_WIDTH{1'b0}};
                        else
                            leaf_route_tail[
                                route_update_logical] <=
                                    leaf_route_tail[
                                        route_update_logical] + 1'b1;
                    end

                    if (route_dequeue) begin
                        if (leaf_route_head[
                            route_update_logical] ==
                            ROUTE_PTR_WIDTH'(
                                LEAF_ROUTE_QUEUE_DEPTH - 1))
                            leaf_route_head[
                                route_update_logical] <=
                                    {ROUTE_PTR_WIDTH{1'b0}};
                        else
                            leaf_route_head[
                                route_update_logical] <=
                                    leaf_route_head[
                                        route_update_logical] + 1'b1;
                    end
                end
            end

            if (|(core_req_valid & core_req_capture_bad_id))
                local_protocol_error <= 1'b1;

            // Packet Push admission is atomic by construction.
            if (push_input_fire &&
                !(core_req_capture_fire[0] &&
                  core_req_capture_fire[1]))
                local_protocol_error <= 1'b1;
            if (pop_input_fire && !core_req_capture_fire[2])
                local_protocol_error <= 1'b1;
        end
    end

    HeterogeneousPIFO #(
        .PTW(PTW),
        .MTW(MTW),
        .CTW(CTW),
        .LEVEL(LEVEL),
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(PHYSICAL_TREE_NUM),
        .SHARD_CAPACITY(SHARD_CAPACITY),
        .FIFO_SIZE(FIFO_SIZE),
        .MAX_SHARDS_PER_LOGICAL(MAX_SHARDS_PER_LOGICAL),
        .REQUEST_PORTS(REQUEST_PORTS),
        .TASK_ORDER_WIDTH(TASK_ORDER_WIDTH),
        .LOGICAL_PENDING_DEPTH(LOGICAL_PENDING_DEPTH),
        .POP_RESULT_FIFO_DEPTH(POP_RESULT_FIFO_DEPTH),
        .HIERARCHICAL_MODE(1),
        .USE_EXPLICIT_SHARD_MAP(USE_EXPLICIT_SHARD_MAP),
        .SHARD_COUNTS(SHARD_COUNTS),
        .SHARD_OFFSETS(SHARD_OFFSETS),
        .EXPLICIT_SHARD_MAP(EXPLICIT_SHARD_MAP)
    ) core (
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
        .o_dispatch_fire(core_dispatch_fire),
        .o_dispatch_push(core_dispatch_push),
        .o_dispatch_logical_tree_id(
            core_dispatch_logical_tree_id),
        .o_selected_physical_tree_id(
            core_selected_physical_tree_id),
        .o_dispatch_data(core_dispatch_data),
        .o_dispatch_source_port(core_dispatch_source_port),
        .o_dispatch_reject_empty(core_dispatch_reject_empty),
        .o_dispatch_reject_full(core_dispatch_reject_full),
        .o_logical_pending_count(o_logical_pending_count),
        .o_pending_count(o_pending_count),
        .o_pending_effective_free_count(
            core_pending_effective_free_count),
        .o_busy(core_busy),
        .o_pop_valid(core_pop_valid),
        .o_pop_logical_tree_id(core_pop_logical_tree_id),
        .o_pop_data(core_pop_data),
        .o_internal_root_pop_valid(core_root_pop_valid),
        .o_internal_root_pop_data(core_root_pop_data),
        .o_protocol_error(core_protocol_error),
        .o_task_fifo_full(o_task_fifo_full),
        .o_task_write(o_task_write),
        .o_task_push(o_task_push),
        .o_task_pop(o_task_pop),
        .o_shard_list(o_shard_list),
        .o_logical_shard_count(o_logical_shard_count),
        .o_logical_count(o_logical_count),
        .o_push_rr_ptr(o_push_rr_ptr),
        .o_shard_count(o_shard_count),
        .o_shard_head_rank(o_shard_head_rank),
        .o_shard_empty(o_shard_empty),
        .o_shard_full(o_shard_full),
        .o_shard_head_valid(o_shard_head_valid),
        .o_update_pending(o_update_pending),
        .o_logical_busy(o_logical_busy),
        .o_pending_logical_tree_id(
            o_pending_logical_tree_id),
        .o_pending_push(o_pending_push)
    );

    assign o_pop_out = core_pop_valid;
    assign o_pop_tree_id = core_pop_logical_tree_id;
    assign o_pop_data = core_pop_data;
    assign o_internal_capture_fire = core_req_capture_fire;
    assign o_internal_task_fire = core_dispatch_fire;
    assign o_internal_task_push = core_dispatch_push;
    assign o_internal_task_logical_tree_id =
        core_dispatch_logical_tree_id;
    assign o_internal_task_physical_tree_id =
        core_selected_physical_tree_id;
    assign o_internal_task_data = core_dispatch_data;
    assign o_root_pop_routed = core_root_pop_leaf_valid;
    assign o_root_pop_leaf_tree_id = core_root_pop_leaf_id;

    integer busy_route_logical;
    reg route_queue_busy;
    always @* begin
        route_queue_busy = 1'b0;
        for (busy_route_logical = 1;
             busy_route_logical < LOGICAL_TREE_NUM;
             busy_route_logical = busy_route_logical + 1)
            route_queue_busy = route_queue_busy |
                (leaf_route_count[busy_route_logical] != 0);
    end

    assign o_busy = core_busy || route_queue_busy;
    assign o_protocol_error =
        core_protocol_error | local_protocol_error;

endmodule
