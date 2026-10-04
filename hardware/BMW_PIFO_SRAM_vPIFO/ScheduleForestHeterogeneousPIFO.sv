`timescale 1ns / 10ps

// Two-tier scheduling forest over one heterogeneous BMW execution domain.
//
// A semantic tree is identified separately from its logical PIFO nodes:
//   semantic tree -> TREE_ROOTS[tree_id]
//   leaf node     -> NODE_PARENT[leaf_id]
//
// All roots and leaves use one unified logical-node namespace and share one
// HeterogeneousPIFO instance (therefore one PIFO_SRAM_TOP and one LEVEL-wide
// RPU set).  SHARD_COUNTS/SHARD_OFFSETS may place each semantic tree in a
// contiguous physical-shard range, but that is storage isolation only.
//
// Request ports:
//   0                         packet leaf Push
//   1                         matching root-reference Push
//   2                         external semantic-tree root Pop
//   3 + logical_node_id       root-result routed leaf Pop
module ScheduleForestHeterogeneousPIFO #(
    parameter PTW = 16,
    parameter MTW = 16,
    parameter CTW = 10,
    parameter LEVEL = GeneralizedVpifoConfigPkg::SCHEDULE_LEVEL,
    parameter LOGICAL_TREE_NUM =
        GeneralizedVpifoConfigPkg::SCHEDULE_LOGICAL_TREE_NUM,
    parameter SEMANTIC_TREE_NUM =
        GeneralizedVpifoConfigPkg::SCHEDULE_SEMANTIC_TREE_NUM,
    parameter PHYSICAL_TREE_NUM =
        GeneralizedVpifoConfigPkg::SCHEDULE_PHYSICAL_TREE_NUM,
    parameter SHARD_CAPACITY =
        GeneralizedVpifoConfigPkg::SCHEDULE_SHARD_CAPACITY,
    parameter FIFO_SIZE = 8,
    parameter MAX_SHARDS_PER_LOGICAL =
        GeneralizedVpifoConfigPkg::SCHEDULE_MAX_SHARDS_PER_LOGICAL,
    parameter POP_RESULT_FIFO_DEPTH = LOGICAL_TREE_NUM + LEVEL,
    parameter TASK_ORDER_WIDTH = 32,
    parameter LEAF_ROUTE_QUEUE_DEPTH = FIFO_SIZE,
    parameter LOGICAL_PENDING_DEPTH =
        LOGICAL_TREE_NUM + 3 + FIFO_SIZE,
    parameter integer USE_EXPLICIT_SHARD_MAP = 0,
    parameter integer TREE_ROOTS [0:SEMANTIC_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_TREE_ROOTS,
    parameter integer NODE_PARENT [0:LOGICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_NODE_PARENT,
    parameter integer NODE_TREE_ID [0:LOGICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_NODE_TREE_ID,
    parameter integer NODE_IS_ROOT [0:LOGICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_NODE_IS_ROOT,
    parameter integer SHARD_COUNTS [0:LOGICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_SHARD_COUNTS,
    parameter integer SHARD_OFFSETS [0:LOGICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_SHARD_OFFSETS,
    parameter integer EXPLICIT_SHARD_MAP [0:PHYSICAL_TREE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_EXPLICIT_SHARD_MAP,

    localparam LOGICAL_ID_WIDTH = (LOGICAL_TREE_NUM <= 1) ? 1 :
                                  $clog2(LOGICAL_TREE_NUM),
    localparam SEMANTIC_TREE_ID_WIDTH = (SEMANTIC_TREE_NUM <= 1) ? 1 :
                                        $clog2(SEMANTIC_TREE_NUM),
    localparam TOTAL_COUNT_WIDTH =
        (PHYSICAL_TREE_NUM * SHARD_CAPACITY <= 1) ? 1 :
        $clog2(PHYSICAL_TREE_NUM * SHARD_CAPACITY + 1),
    localparam REQUEST_PORTS = LOGICAL_TREE_NUM + 3,
    localparam ROUTE_PTR_WIDTH = (LEAF_ROUTE_QUEUE_DEPTH <= 1) ? 1 :
                                 $clog2(LEAF_ROUTE_QUEUE_DEPTH),
    localparam ROUTE_COUNT_WIDTH = (LEAF_ROUTE_QUEUE_DEPTH <= 1) ? 1 :
                                   $clog2(LEAF_ROUTE_QUEUE_DEPTH + 1),
    localparam SOURCE_PORT_WIDTH = (REQUEST_PORTS <= 1) ? 1 :
                                   $clog2(REQUEST_PORTS),
    localparam PENDING_COUNT_WIDTH = (LOGICAL_PENDING_DEPTH <= 1) ? 1 :
                                     $clog2(LOGICAL_PENDING_DEPTH + 1)
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,

    input  wire                         i_push,
    input  wire [LOGICAL_ID_WIDTH-1:0]  i_push_leaf_id,
    input  wire [PTW-1:0]               i_push_priority,
    input  wire [(MTW+PTW)-1:0]         i_push_data,
    output wire                         o_push_ready,
    output wire                         o_reject_bad_leaf_id,

    input  wire                         i_pop,
    input  wire [SEMANTIC_TREE_ID_WIDTH-1:0]
                                        i_pop_semantic_tree_id,
    output wire                         o_pop_req_ready,
    output wire                         o_reject_bad_tree_id,
    output wire                         o_pop_out,
    output wire [SEMANTIC_TREE_ID_WIDTH-1:0]
                                        o_pop_semantic_tree_id,
    output wire [LOGICAL_ID_WIDTH-1:0]  o_pop_leaf_id,
    output wire [(MTW+PTW)-1:0]         o_pop_data,

    output wire                         o_root_pop_routed,
    output wire [LOGICAL_ID_WIDTH-1:0]  o_root_pop_root_id,
    output wire [LOGICAL_ID_WIDTH-1:0]  o_root_pop_leaf_id,
    output wire                         o_busy,
    output wire                         o_protocol_error,
    output wire [TOTAL_COUNT_WIDTH-1:0]
        o_logical_count [0:LOGICAL_TREE_NUM-1],
    output wire [PENDING_COUNT_WIDTH-1:0]
        o_logical_pending_count [0:LOGICAL_TREE_NUM-1],
    output wire [PENDING_COUNT_WIDTH-1:0] o_pending_count
);

    localparam [LOGICAL_ID_WIDTH:0] LOGICAL_TREE_NUM_LIMIT =
        LOGICAL_TREE_NUM;
    localparam [SEMANTIC_TREE_ID_WIDTH:0] SEMANTIC_TREE_NUM_LIMIT =
        SEMANTIC_TREE_NUM;

    initial begin : validate_forest
        integer validate_node;
        integer validate_tree;
        if ((LOGICAL_TREE_NUM < 2) || (SEMANTIC_TREE_NUM < 1) ||
            (PHYSICAL_TREE_NUM < LOGICAL_TREE_NUM) || (LEVEL < 1) ||
            (MTW < LOGICAL_ID_WIDTH) || (TASK_ORDER_WIDTH < 2) ||
            (LEAF_ROUTE_QUEUE_DEPTH < 1))
            $fatal(1, "ScheduleForestHeterogeneousPIFO parameters invalid");
        for (validate_tree = 0; validate_tree < SEMANTIC_TREE_NUM;
             validate_tree = validate_tree + 1) begin
            if ((TREE_ROOTS[validate_tree] < 0) ||
                (TREE_ROOTS[validate_tree] >= LOGICAL_TREE_NUM) ||
                (NODE_IS_ROOT[TREE_ROOTS[validate_tree]] == 0) ||
                (NODE_TREE_ID[TREE_ROOTS[validate_tree]] != validate_tree))
                $fatal(1, "invalid semantic schedule-tree root table");
        end
        for (validate_node = 0; validate_node < LOGICAL_TREE_NUM;
             validate_node = validate_node + 1) begin
            if ((NODE_TREE_ID[validate_node] < 0) ||
                (NODE_TREE_ID[validate_node] >= SEMANTIC_TREE_NUM) ||
                (NODE_PARENT[validate_node] < 0) ||
                (NODE_PARENT[validate_node] >= LOGICAL_TREE_NUM) ||
                (NODE_PARENT[validate_node] !=
                 TREE_ROOTS[NODE_TREE_ID[validate_node]]) ||
                ((NODE_IS_ROOT[validate_node] != 0) &&
                 (validate_node != NODE_PARENT[validate_node])) ||
                ((NODE_IS_ROOT[validate_node] == 0) &&
                 (NODE_IS_ROOT[NODE_PARENT[validate_node]] == 0)))
                $fatal(1, "invalid semantic schedule-node topology table");
        end
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
    wire [REQUEST_PORTS-1:0] core_req_capture_fire;
    wire [REQUEST_PORTS-1:0] core_req_capture_bad_id;
    wire [PENDING_COUNT_WIDTH-1:0]
        core_pending_effective_free_count;
    wire core_busy;
    wire core_pop_valid;
    wire [LOGICAL_ID_WIDTH-1:0] core_pop_logical_tree_id;
    wire [(MTW+PTW)-1:0] core_pop_data;
    wire core_protocol_error;

    reg push_leaf_id_valid;
    reg pop_tree_id_valid;
    reg [LOGICAL_ID_WIDTH-1:0] push_parent_root_id;
    reg [LOGICAL_ID_WIDTH-1:0] selected_pop_root_id;
    always @* begin
        push_leaf_id_valid = 1'b0;
        push_parent_root_id = {LOGICAL_ID_WIDTH{1'b0}};
        if ({1'b0, i_push_leaf_id} < LOGICAL_TREE_NUM_LIMIT) begin
            push_leaf_id_valid = NODE_IS_ROOT[int'(i_push_leaf_id)] == 0;
            push_parent_root_id =
                NODE_PARENT[int'(i_push_leaf_id)][LOGICAL_ID_WIDTH-1:0];
        end

        pop_tree_id_valid = 1'b0;
        selected_pop_root_id = {LOGICAL_ID_WIDTH{1'b0}};
        if ({1'b0, i_pop_semantic_tree_id} <
            SEMANTIC_TREE_NUM_LIMIT) begin
            pop_tree_id_valid = 1'b1;
            selected_pop_root_id =
                TREE_ROOTS[int'(i_pop_semantic_tree_id)]
                    [LOGICAL_ID_WIDTH-1:0];
        end
    end

    wire push_input_fire =
        i_push && o_push_ready && push_leaf_id_valid;
    wire pop_input_fire =
        i_pop && o_pop_req_ready && pop_tree_id_valid;

    // Invalid IDs are accepted and reported as ordinary request rejection.
    // Valid packet Pushes reserve two atomic capture slots; a simultaneous
    // valid Pop reserves the third slot.
    assign o_push_ready = i_arst_n &&
        (core_pending_effective_free_count >=
         ((i_pop && pop_tree_id_valid) ? 3 : 2));
    assign o_reject_bad_leaf_id =
        i_push && o_push_ready && !push_leaf_id_valid;
    assign o_pop_req_ready = i_arst_n &&
        (core_pending_effective_free_count >=
         ((i_push && push_leaf_id_valid) ? 3 : 1));
    assign o_reject_bad_tree_id =
        i_pop && o_pop_req_ready && !pop_tree_id_valid;

    assign core_req_valid[0] = push_input_fire;
    assign core_req_push[0] = 1'b1;
    assign core_req_logical_tree_id[0] = i_push_leaf_id;
    assign core_req_push_data[0] = i_push_data;
    assign core_req_order[0] = task_order_counter;

    assign core_req_valid[1] = push_input_fire;
    assign core_req_push[1] = 1'b1;
    assign core_req_logical_tree_id[1] = push_parent_root_id;
    assign core_req_push_data[1] =
        {i_push_leaf_id,
         {(MTW-LOGICAL_ID_WIDTH){1'b0}},
         i_push_priority};
    assign core_req_order[1] = task_order_counter;

    assign core_req_valid[2] = pop_input_fire;
    assign core_req_push[2] = 1'b0;
    assign core_req_logical_tree_id[2] = selected_pop_root_id;
    assign core_req_push_data[2] = {(MTW+PTW){1'b1}};
    assign core_req_order[2] = task_order_counter;

    wire core_result_node_in_range = core_pop_valid &&
        ({1'b0, core_pop_logical_tree_id} < LOGICAL_TREE_NUM_LIMIT);
    reg core_result_is_root;
    reg [SEMANTIC_TREE_ID_WIDTH-1:0] core_result_tree_id;
    always @* begin
        core_result_is_root = 1'b0;
        core_result_tree_id = {SEMANTIC_TREE_ID_WIDTH{1'b0}};
        if (core_result_node_in_range) begin
            core_result_is_root =
                NODE_IS_ROOT[int'(core_pop_logical_tree_id)] != 0;
            core_result_tree_id =
                NODE_TREE_ID[int'(core_pop_logical_tree_id)]
                    [SEMANTIC_TREE_ID_WIDTH-1:0];
        end
    end

    wire [LOGICAL_ID_WIDTH-1:0] root_result_leaf_id =
        core_pop_data[(MTW+PTW)-1 -: LOGICAL_ID_WIDTH];
    reg root_result_leaf_valid;
    always @* begin
        root_result_leaf_valid = 1'b0;
        if (core_result_node_in_range && core_result_is_root &&
            ({1'b0, root_result_leaf_id} < LOGICAL_TREE_NUM_LIMIT)) begin
            root_result_leaf_valid =
                (NODE_IS_ROOT[int'(root_result_leaf_id)] == 0) &&
                (NODE_PARENT[int'(root_result_leaf_id)] ==
                 int'(core_pop_logical_tree_id)) &&
                (NODE_TREE_ID[int'(root_result_leaf_id)] ==
                 NODE_TREE_ID[int'(core_pop_logical_tree_id)]);
        end
    end

    genvar route_node;
    generate
        for (route_node = 0; route_node < LOGICAL_TREE_NUM;
             route_node = route_node + 1) begin : route_request
            localparam integer ROUTE_PORT = 3 + route_node;
            assign core_req_valid[ROUTE_PORT] =
                (NODE_IS_ROOT[route_node] == 0) &&
                ((leaf_route_count[route_node] != 0) ||
                 (root_result_leaf_valid &&
                  (root_result_leaf_id == route_node)));
            assign core_req_push[ROUTE_PORT] = 1'b0;
            assign core_req_logical_tree_id[ROUTE_PORT] =
                route_node[LOGICAL_ID_WIDTH-1:0];
            assign core_req_push_data[ROUTE_PORT] =
                {(MTW+PTW){1'b1}};
            assign core_req_order[ROUTE_PORT] =
                (leaf_route_count[route_node] != 0) ?
                leaf_route_order_mem[route_node]
                                    [leaf_route_head[route_node]] :
                task_order_counter;
        end
    endgenerate

    // P/P provenance is legal only when the simultaneous packet Push and
    // external Pop address the same semantic tree root.  Different trees may
    // execute concurrently but must never be fused into one P/P operation.
    wire same_root_generation = push_input_fire && pop_input_fire &&
        (push_parent_root_id == selected_pop_root_id);
    genvar merge_port;
    generate
        for (merge_port = 0; merge_port < REQUEST_PORTS;
             merge_port = merge_port + 1) begin : merge_relation
            assign core_req_merge_mask[merge_port] =
                (((merge_port == 0) || (merge_port == 1)) &&
                 same_root_generation) ?
                    ({{(REQUEST_PORTS-3){1'b0}}, 3'b100}) :
                ((merge_port == 2) && same_root_generation) ?
                    ({{(REQUEST_PORTS-3){1'b0}}, 3'b011}) :
                    {REQUEST_PORTS{1'b0}};
        end
    endgenerate

    integer reset_node;
    integer reset_route_entry;
    integer route_update_node;
    reg route_dequeue;
    reg route_enqueue;
    reg route_bypass_accept;
    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            task_order_counter <= {TASK_ORDER_WIDTH{1'b0}};
            local_protocol_error <= 1'b0;
            for (reset_node = 0; reset_node < LOGICAL_TREE_NUM;
                 reset_node = reset_node + 1) begin
                leaf_route_head[reset_node] <= {ROUTE_PTR_WIDTH{1'b0}};
                leaf_route_tail[reset_node] <= {ROUTE_PTR_WIDTH{1'b0}};
                leaf_route_count[reset_node] <= {ROUTE_COUNT_WIDTH{1'b0}};
                for (reset_route_entry = 0;
                     reset_route_entry < LEAF_ROUTE_QUEUE_DEPTH;
                     reset_route_entry = reset_route_entry + 1)
                    leaf_route_order_mem[reset_node]
                                        [reset_route_entry] <=
                        {TASK_ORDER_WIDTH{1'b0}};
            end
        end else begin
            task_order_counter <= task_order_counter + 1'b1;

            if (core_pop_valid &&
                (!core_result_node_in_range ||
                 (core_result_is_root && !root_result_leaf_valid)))
                local_protocol_error <= 1'b1;

            for (route_update_node = 0;
                 route_update_node < LOGICAL_TREE_NUM;
                 route_update_node = route_update_node + 1) begin
                route_dequeue =
                    (NODE_IS_ROOT[route_update_node] == 0) &&
                    (leaf_route_count[route_update_node] != 0) &&
                    core_req_capture_fire[3 + route_update_node];
                route_bypass_accept =
                    (NODE_IS_ROOT[route_update_node] == 0) &&
                    (leaf_route_count[route_update_node] == 0) &&
                    root_result_leaf_valid &&
                    (int'(root_result_leaf_id) == route_update_node) &&
                    core_req_capture_fire[3 + route_update_node];
                route_enqueue =
                    (NODE_IS_ROOT[route_update_node] == 0) &&
                    root_result_leaf_valid &&
                    (int'(root_result_leaf_id) == route_update_node) &&
                    !route_bypass_accept;

                if (route_enqueue &&
                    (leaf_route_count[route_update_node] ==
                     LEAF_ROUTE_QUEUE_DEPTH) && !route_dequeue) begin
                    local_protocol_error <= 1'b1;
                end else begin
                    case ({route_enqueue, route_dequeue})
                        2'b10: leaf_route_count[route_update_node] <=
                            leaf_route_count[route_update_node] + 1'b1;
                        2'b01: leaf_route_count[route_update_node] <=
                            leaf_route_count[route_update_node] - 1'b1;
                        default: leaf_route_count[route_update_node] <=
                            leaf_route_count[route_update_node];
                    endcase
                    if (route_enqueue) begin
                        leaf_route_order_mem[route_update_node]
                                            [leaf_route_tail[
                                                route_update_node]] <=
                            task_order_counter;
                        if (leaf_route_tail[route_update_node] ==
                            ROUTE_PTR_WIDTH'(LEAF_ROUTE_QUEUE_DEPTH - 1))
                            leaf_route_tail[route_update_node] <=
                                {ROUTE_PTR_WIDTH{1'b0}};
                        else
                            leaf_route_tail[route_update_node] <=
                                leaf_route_tail[route_update_node] + 1'b1;
                    end
                    if (route_dequeue) begin
                        if (leaf_route_head[route_update_node] ==
                            ROUTE_PTR_WIDTH'(LEAF_ROUTE_QUEUE_DEPTH - 1))
                            leaf_route_head[route_update_node] <=
                                {ROUTE_PTR_WIDTH{1'b0}};
                        else
                            leaf_route_head[route_update_node] <=
                                leaf_route_head[route_update_node] + 1'b1;
                    end
                end
            end

            if (|(core_req_valid & core_req_capture_bad_id))
                local_protocol_error <= 1'b1;
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
        .HIERARCHICAL_MODE(0),
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
        .o_req_capture_ready(),
        .o_req_capture_fire(core_req_capture_fire),
        .o_req_capture_bad_id(core_req_capture_bad_id),
        .o_dispatch_fire(),
        .o_dispatch_push(),
        .o_dispatch_logical_tree_id(),
        .o_selected_physical_tree_id(),
        .o_dispatch_data(),
        .o_dispatch_source_port(),
        .o_dispatch_reject_empty(),
        .o_dispatch_reject_full(),
        .o_logical_pending_count(o_logical_pending_count),
        .o_pending_count(o_pending_count),
        .o_pending_effective_free_count(
            core_pending_effective_free_count),
        .o_busy(core_busy),
        .o_pop_valid(core_pop_valid),
        .o_pop_logical_tree_id(core_pop_logical_tree_id),
        .o_pop_data(core_pop_data),
        .o_internal_root_pop_valid(),
        .o_internal_root_pop_data(),
        .o_protocol_error(core_protocol_error),
        .o_task_fifo_full(),
        .o_task_write(),
        .o_task_push(),
        .o_task_pop(),
        .o_shard_list(),
        .o_logical_shard_count(),
        .o_logical_count(o_logical_count),
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

    assign o_pop_out = core_pop_valid && core_result_node_in_range &&
                       !core_result_is_root;
    assign o_pop_semantic_tree_id = core_result_tree_id;
    assign o_pop_leaf_id = core_pop_logical_tree_id;
    assign o_pop_data = core_pop_data;
    assign o_root_pop_routed = root_result_leaf_valid;
    assign o_root_pop_root_id = core_pop_logical_tree_id;
    assign o_root_pop_leaf_id = root_result_leaf_id;

    integer busy_route_node;
    reg route_queue_busy;
    always @* begin
        route_queue_busy = 1'b0;
        for (busy_route_node = 0;
             busy_route_node < LOGICAL_TREE_NUM;
             busy_route_node = busy_route_node + 1)
            if (NODE_IS_ROOT[busy_route_node] == 0)
                route_queue_busy = route_queue_busy |
                    (leaf_route_count[busy_route_node] != 0);
    end

    assign o_busy = core_busy || route_queue_busy;
    assign o_protocol_error =
        core_protocol_error | local_protocol_error;

endmodule
