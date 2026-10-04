`timescale 1ns / 10ps

// Four-logical-tree, six-shard, unbalanced hierarchy:
//
//   logical 0 (root, 3 shards)
//   |-- logical 1 (direct leaf, 1 shard)
//   `-- logical 2 (middle, 1 shard)
//       `-- logical 3 (deep leaf, 1 shard)
//
// A packet for logical 1 generates root+leaf Pushes.  A packet for logical 3
// generates root+middle+leaf Pushes.  The root operation remains one native
// compound P/P descriptor when Packet In and Packet Out are accepted together.
module UnbalancedHeterogeneousVPIFO4P6 #(
    parameter PTW = 16,
    parameter MTW = 32,
    parameter CTW = 10,
    parameter FIFO_SIZE = 8,
    parameter TASK_ORDER_WIDTH = 32,
    parameter LOGICAL_PENDING_DEPTH = 8,
    localparam LOGICAL_ID_WIDTH = 2
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,
    input  wire                         i_push_valid,
    output wire                         o_push_ready,
    input  wire [LOGICAL_ID_WIDTH-1:0]  i_leaf_id,
    input  wire [PTW-1:0]               i_root_rank,
    input  wire [PTW-1:0]               i_middle_rank,
    input  wire [PTW-1:0]               i_leaf_rank,
    input  wire [MTW-1:0]               i_payload,
    input  wire                         i_pop_valid,
    output wire                         o_pop_ready,
    output reg                          o_pop_valid,
    output reg [LOGICAL_ID_WIDTH-1:0]   o_pop_leaf_id,
    output reg [MTW-1:0]                o_pop_payload,
    output wire                         o_busy,
    output wire                         o_protocol_error
);

    localparam integer LEVEL = 6;
    localparam integer LOGICAL_TREE_NUM = 4;
    localparam integer PHYSICAL_TREE_NUM = 6;
    localparam integer SHARD_CAPACITY = 126;
    localparam integer MAX_SHARDS_PER_LOGICAL = 3;
    localparam integer REQUEST_PORTS = 4;
    localparam integer POP_RESULT_FIFO_DEPTH = 1;
    localparam integer PENDING_COUNT_WIDTH =
        $clog2(LOGICAL_PENDING_DEPTH + 1);

    localparam [LOGICAL_ID_WIDTH-1:0] ROOT_ID = 2'd0;
    localparam [LOGICAL_ID_WIDTH-1:0] DIRECT_LEAF_ID = 2'd1;
    localparam [LOGICAL_ID_WIDTH-1:0] MIDDLE_ID = 2'd2;
    localparam [LOGICAL_ID_WIDTH-1:0] DEEP_LEAF_ID = 2'd3;

    localparam integer SHARD_COUNTS [0:LOGICAL_TREE_NUM-1] =
        '{3, 1, 1, 1};
    localparam integer SHARD_OFFSETS [0:LOGICAL_TREE_NUM-1] =
        '{0, 3, 4, 5};
    localparam integer EXPLICIT_SHARD_MAP [0:PHYSICAL_TREE_NUM-1] =
        '{0, 0, 0, 0, 0, 0};

    wire [REQUEST_PORTS-1:0] core_req_valid;
    wire [REQUEST_PORTS-1:0] core_req_push;
    wire [REQUEST_PORTS-1:0] core_req_pop;
    wire [LOGICAL_ID_WIDTH-1:0]
        core_req_logical_tree_id [0:REQUEST_PORTS-1];
    wire [(MTW+PTW)-1:0] core_req_push_data [0:REQUEST_PORTS-1];
    wire [TASK_ORDER_WIDTH-1:0] core_req_order [0:REQUEST_PORTS-1];
    wire [REQUEST_PORTS-1:0]
        core_req_merge_mask [0:REQUEST_PORTS-1];
    wire [REQUEST_PORTS-1:0] core_req_capture_ready;
    wire [REQUEST_PORTS-1:0] core_req_capture_fire;
    wire [REQUEST_PORTS-1:0] core_req_capture_bad_id;
    wire [PENDING_COUNT_WIDTH-1:0]
        core_pending_effective_free_count;
    wire core_busy;
    wire core_pop_valid;
    wire [LOGICAL_ID_WIDTH-1:0] core_pop_logical_tree_id;
    wire [(MTW+PTW)-1:0] core_pop_data;
    wire core_protocol_error;

    reg [TASK_ORDER_WIDTH-1:0] task_order_counter;
    reg pop_chain_busy;
    reg route_pending;
    reg [LOGICAL_ID_WIDTH-1:0] route_logical_id;
    reg [LOGICAL_ID_WIDTH-1:0] expected_pop_logical_id;
    reg local_protocol_error;

    wire push_is_direct;
    wire push_is_deep;
    wire push_leaf_id_valid;
    wire push_input_fire;
    wire pop_input_fire;
    wire route_input_fire;
    wire [LOGICAL_ID_WIDTH-1:0] root_child_id;
    wire [LOGICAL_ID_WIDTH-1:0] returned_child_id;
    wire [PENDING_COUNT_WIDTH-1:0] push_required_slots;
    wire [PENDING_COUNT_WIDTH-1:0] route_required_slots;
    wire [PENDING_COUNT_WIDTH-1:0] simultaneous_push_extra_slots;

    assign push_is_direct = i_leaf_id == DIRECT_LEAF_ID;
    assign push_is_deep = i_leaf_id == DEEP_LEAF_ID;
    assign push_leaf_id_valid = push_is_direct || push_is_deep;
    assign root_child_id = push_is_direct ? DIRECT_LEAF_ID : MIDDLE_ID;
    assign push_required_slots = push_is_direct ?
        PENDING_COUNT_WIDTH'(2) : PENDING_COUNT_WIDTH'(3);
    assign route_required_slots = route_pending ?
        PENDING_COUNT_WIDTH'(1) : PENDING_COUNT_WIDTH'(0);
    assign simultaneous_push_extra_slots =
        (i_push_valid && push_leaf_id_valid) ?
            (push_required_slots - PENDING_COUNT_WIDTH'(1)) :
            PENDING_COUNT_WIDTH'(0);

    // A simultaneous root Push and Pop occupies one native compound slot.
    assign o_push_ready = i_arst_n &&
        (core_pending_effective_free_count >=
         (push_required_slots + route_required_slots));
    assign o_pop_ready = i_arst_n && !pop_chain_busy &&
        (core_pending_effective_free_count >=
         (PENDING_COUNT_WIDTH'(1) + route_required_slots +
          simultaneous_push_extra_slots));

    assign push_input_fire =
        i_push_valid && o_push_ready && push_leaf_id_valid;
    assign pop_input_fire = i_pop_valid && o_pop_ready;
    assign route_input_fire =
        route_pending && core_req_capture_fire[3];

    // Port 0 is the destination leaf Push for both paths.
    assign core_req_valid[0] = push_input_fire;
    assign core_req_push[0] = 1'b1;
    assign core_req_pop[0] = 1'b0;
    assign core_req_logical_tree_id[0] = i_leaf_id;
    assign core_req_push_data[0] = {i_payload, i_leaf_rank};
    assign core_req_order[0] = task_order_counter;

    // Port 1 exists only on the deeper root->middle->leaf path.
    assign core_req_valid[1] = push_input_fire && push_is_deep;
    assign core_req_push[1] = 1'b1;
    assign core_req_pop[1] = 1'b0;
    assign core_req_logical_tree_id[1] = MIDDLE_ID;
    assign core_req_push_data[1] =
        {DEEP_LEAF_ID,
         {(MTW-LOGICAL_ID_WIDTH){1'b0}},
         i_middle_rank};
    assign core_req_order[1] = task_order_counter;

    // Port 2 is the root native Push, Pop, or compound P/P operation.
    assign core_req_valid[2] = push_input_fire || pop_input_fire;
    assign core_req_push[2] = push_input_fire;
    assign core_req_pop[2] = pop_input_fire;
    assign core_req_logical_tree_id[2] = ROOT_ID;
    assign core_req_push_data[2] =
        {root_child_id,
         {(MTW-LOGICAL_ID_WIDTH){1'b0}},
         i_root_rank};
    assign core_req_order[2] = task_order_counter;

    // Port 3 carries the next Pop in the variable-depth routed chain.
    assign core_req_valid[3] = route_pending;
    assign core_req_push[3] = 1'b0;
    assign core_req_pop[3] = 1'b1;
    assign core_req_logical_tree_id[3] = route_logical_id;
    assign core_req_push_data[3] = {(MTW+PTW){1'b1}};
    assign core_req_order[3] = task_order_counter;

    assign core_req_merge_mask[0] = {REQUEST_PORTS{1'b0}};
    assign core_req_merge_mask[1] = {REQUEST_PORTS{1'b0}};
    assign core_req_merge_mask[2] = {REQUEST_PORTS{1'b0}};
    assign core_req_merge_mask[3] = {REQUEST_PORTS{1'b0}};

    assign returned_child_id =
        core_pop_data[(MTW+PTW)-1 -: LOGICAL_ID_WIDTH];

    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            task_order_counter <= {TASK_ORDER_WIDTH{1'b0}};
            pop_chain_busy <= 1'b0;
            route_pending <= 1'b0;
            route_logical_id <= ROOT_ID;
            expected_pop_logical_id <= ROOT_ID;
            local_protocol_error <= 1'b0;
            o_pop_valid <= 1'b0;
            o_pop_leaf_id <= {LOGICAL_ID_WIDTH{1'b0}};
            o_pop_payload <= {MTW{1'b0}};
        end else begin
            task_order_counter <= task_order_counter + 1'b1;
            o_pop_valid <= 1'b0;

            if (i_push_valid && o_push_ready && !push_leaf_id_valid)
                local_protocol_error <= 1'b1;
            if (push_input_fire &&
                !(core_req_capture_fire[0] &&
                  core_req_capture_fire[2] &&
                  (!push_is_deep || core_req_capture_fire[1])))
                local_protocol_error <= 1'b1;
            if (pop_input_fire && !core_req_capture_fire[2])
                local_protocol_error <= 1'b1;
            if (|(core_req_valid & core_req_capture_bad_id))
                local_protocol_error <= 1'b1;

            if (pop_input_fire) begin
                pop_chain_busy <= 1'b1;
                expected_pop_logical_id <= ROOT_ID;
            end

            if (route_input_fire) begin
                route_pending <= 1'b0;
                expected_pop_logical_id <= route_logical_id;
            end

            if (core_pop_valid) begin
                if (!pop_chain_busy ||
                    (core_pop_logical_tree_id !=
                     expected_pop_logical_id))
                    local_protocol_error <= 1'b1;

                if (core_pop_logical_tree_id == ROOT_ID) begin
                    if ((returned_child_id != DIRECT_LEAF_ID) &&
                        (returned_child_id != MIDDLE_ID)) begin
                        local_protocol_error <= 1'b1;
                    end else begin
                        route_logical_id <= returned_child_id;
                        route_pending <= 1'b1;
                    end
                end else if (core_pop_logical_tree_id == MIDDLE_ID) begin
                    if (returned_child_id != DEEP_LEAF_ID) begin
                        local_protocol_error <= 1'b1;
                    end else begin
                        route_logical_id <= DEEP_LEAF_ID;
                        route_pending <= 1'b1;
                    end
                end else if ((core_pop_logical_tree_id ==
                              DIRECT_LEAF_ID) ||
                             (core_pop_logical_tree_id ==
                              DEEP_LEAF_ID)) begin
                    o_pop_valid <= 1'b1;
                    o_pop_leaf_id <= core_pop_logical_tree_id;
                    o_pop_payload <=
                        core_pop_data[(MTW+PTW)-1 -: MTW];
                    pop_chain_busy <= 1'b0;
                end else begin
                    local_protocol_error <= 1'b1;
                end
            end
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
        .NATIVE_COMPOUND_REQUESTS(1),
        .SINGLE_POP_RETURN(1),
        .USE_EXPLICIT_SHARD_MAP(0),
        .SHARD_COUNTS(SHARD_COUNTS),
        .SHARD_OFFSETS(SHARD_OFFSETS),
        .EXPLICIT_SHARD_MAP(EXPLICIT_SHARD_MAP)
    ) core (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_req_valid(core_req_valid),
        .i_req_push(core_req_push),
        .i_req_pop(core_req_pop),
        .i_logical_tree_id(core_req_logical_tree_id),
        .i_push_data(core_req_push_data),
        .i_req_order(core_req_order),
        .i_req_merge_mask(core_req_merge_mask),
        .o_req_capture_ready(core_req_capture_ready),
        .o_req_capture_fire(core_req_capture_fire),
        .o_req_capture_bad_id(core_req_capture_bad_id),
        .o_pending_effective_free_count(
            core_pending_effective_free_count),
        .o_busy(core_busy),
        .o_pop_valid(core_pop_valid),
        .o_pop_logical_tree_id(core_pop_logical_tree_id),
        .o_pop_data(core_pop_data),
        .o_protocol_error(core_protocol_error)
    );

    assign o_busy = core_busy || pop_chain_busy || route_pending;
    assign o_protocol_error =
        core_protocol_error || local_protocol_error;

endmodule
