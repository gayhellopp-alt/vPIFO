`timescale 1ns / 10ps

// Stage25-based hard-coded three-tier heterogeneous scheduler.
//
// Topology:
//   logical 0       : root, 11 M=2/L=6 shards
//   logical 1, 2    : middle nodes, 6 and 5 shards
//   logical 3 .. 13 : leaves, one shard each
//
// Ports 0/1/2 atomically capture leaf/middle/root operations for one packet.
// Port 2 is a native root P/P descriptor when Packet In/Out arrive together;
// port 3 carries the routed middle or leaf Pop.  Only one external Pop chain
// is active at a time; packet Pushes may continue while it is in flight.
module ThreeTierHeterogeneousVPIFO #(
    parameter PTW = 16,
    parameter MTW = 16,
    parameter CTW = 10,
    parameter FIFO_SIZE = 8,
    parameter TASK_ORDER_WIDTH = 32,
    parameter LOGICAL_PENDING_DEPTH = 16,
    parameter MIDDLE_COUNT = 2,
    parameter LEAF_COUNT = 11,
    parameter LOGICAL_TREE_NUM = 1 + MIDDLE_COUNT + LEAF_COUNT,
    parameter PHYSICAL_TREE_NUM = 33,
    parameter SHARD_CAPACITY = 126,
    parameter MAX_SHARDS_PER_LOGICAL = 11,
    parameter integer SHARD_COUNTS [0:LOGICAL_TREE_NUM-1] =
        '{11, 6, 5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
    parameter integer SHARD_OFFSETS [0:LOGICAL_TREE_NUM-1] =
        '{0, 11, 17, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32},
    parameter integer EXPLICIT_SHARD_MAP [0:PHYSICAL_TREE_NUM-1] =
        '{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
    localparam LEVEL = 6,
    localparam REQUEST_PORTS = 4,
    localparam POP_RESULT_FIFO_DEPTH = 32,
    localparam LOGICAL_ID_WIDTH = $clog2(LOGICAL_TREE_NUM),
    localparam PENDING_COUNT_WIDTH = $clog2(LOGICAL_PENDING_DEPTH + 1)
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

    localparam integer FIRST_LEAF_ID = 1 + MIDDLE_COUNT;
    localparam integer LAST_LEAF_ID = LOGICAL_TREE_NUM - 1;

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
    wire [PENDING_COUNT_WIDTH-1:0] core_pending_effective_free_count;
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

    wire push_leaf_id_valid;
    wire push_input_fire;
    wire pop_input_fire;
    wire route_input_fire;
    wire [LOGICAL_ID_WIDTH-1:0] push_middle_id;
    wire [LOGICAL_ID_WIDTH-1:0] returned_child_id;
    wire returned_child_is_middle;
    wire returned_child_is_leaf;

    function automatic [LOGICAL_ID_WIDTH-1:0] middle_for_leaf;
        input [LOGICAL_ID_WIDTH-1:0] leaf_id;
        integer leaf_index;
        begin
            leaf_index = int'(leaf_id) - FIRST_LEAF_ID;
            if ((leaf_index < 0) || (leaf_index >= LEAF_COUNT))
                middle_for_leaf = {LOGICAL_ID_WIDTH{1'b0}};
            else
                middle_for_leaf = LOGICAL_ID_WIDTH'(
                    1 + ((leaf_index * MIDDLE_COUNT) / LEAF_COUNT));
        end
    endfunction

    assign push_leaf_id_valid =
        (i_leaf_id >= LOGICAL_ID_WIDTH'(FIRST_LEAF_ID)) &&
        (i_leaf_id <= LOGICAL_ID_WIDTH'(LAST_LEAF_ID));
    assign push_middle_id = middle_for_leaf(i_leaf_id);

    // Reserve all same-cycle capture slots before asserting the packet event.
    assign o_push_ready = i_arst_n &&
        (core_pending_effective_free_count >=
         (PENDING_COUNT_WIDTH'(3) +
          (route_pending ? PENDING_COUNT_WIDTH'(1) :
                           PENDING_COUNT_WIDTH'(0))));
    assign o_pop_ready = i_arst_n && !pop_chain_busy &&
        (core_pending_effective_free_count >=
         (PENDING_COUNT_WIDTH'(1) +
          (route_pending ? PENDING_COUNT_WIDTH'(1) :
                           PENDING_COUNT_WIDTH'(0)) +
          ((i_push_valid && push_leaf_id_valid) ?
              PENDING_COUNT_WIDTH'(2) : PENDING_COUNT_WIDTH'(0))));

    assign push_input_fire =
        i_push_valid && o_push_ready && push_leaf_id_valid;
    assign pop_input_fire = i_pop_valid && o_pop_ready;
    assign route_input_fire =
        route_pending && core_req_capture_fire[3];

    assign core_req_valid[0] = push_input_fire;
    assign core_req_push[0] = 1'b1;
    assign core_req_pop[0] = 1'b0;
    assign core_req_logical_tree_id[0] = i_leaf_id;
    assign core_req_push_data[0] = {i_payload, i_leaf_rank};
    assign core_req_order[0] = task_order_counter;

    assign core_req_valid[1] = push_input_fire;
    assign core_req_push[1] = 1'b1;
    assign core_req_pop[1] = 1'b0;
    assign core_req_logical_tree_id[1] = push_middle_id;
    assign core_req_push_data[1] =
        {i_leaf_id,
         {(MTW-LOGICAL_ID_WIDTH){1'b0}},
         i_middle_rank};
    assign core_req_order[1] = task_order_counter;

    assign core_req_valid[2] = push_input_fire || pop_input_fire;
    assign core_req_push[2] = push_input_fire;
    assign core_req_pop[2] = pop_input_fire;
    assign core_req_logical_tree_id[2] =
        {LOGICAL_ID_WIDTH{1'b0}};
    assign core_req_push_data[2] =
        {push_middle_id,
         {(MTW-LOGICAL_ID_WIDTH){1'b0}},
         i_root_rank};
    assign core_req_order[2] = task_order_counter;

    assign core_req_valid[3] = route_pending;
    assign core_req_push[3] = 1'b0;
    assign core_req_pop[3] = 1'b1;
    assign core_req_logical_tree_id[3] = route_logical_id;
    assign core_req_push_data[3] = {(MTW+PTW){1'b1}};
    assign core_req_order[3] = task_order_counter;

    // Native descriptors do not need half-request provenance.
    assign core_req_merge_mask[0] = {REQUEST_PORTS{1'b0}};
    assign core_req_merge_mask[1] = {REQUEST_PORTS{1'b0}};
    assign core_req_merge_mask[2] = {REQUEST_PORTS{1'b0}};
    assign core_req_merge_mask[3] = {REQUEST_PORTS{1'b0}};

    assign returned_child_id =
        core_pop_data[(MTW+PTW)-1 -: LOGICAL_ID_WIDTH];
    assign returned_child_is_middle =
        (returned_child_id >= LOGICAL_ID_WIDTH'(1)) &&
        (returned_child_id <= LOGICAL_ID_WIDTH'(MIDDLE_COUNT));
    assign returned_child_is_leaf =
        (returned_child_id >= LOGICAL_ID_WIDTH'(FIRST_LEAF_ID)) &&
        (returned_child_id <= LOGICAL_ID_WIDTH'(LAST_LEAF_ID));

    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            task_order_counter <= {TASK_ORDER_WIDTH{1'b0}};
            pop_chain_busy <= 1'b0;
            route_pending <= 1'b0;
            route_logical_id <= {LOGICAL_ID_WIDTH{1'b0}};
            expected_pop_logical_id <= {LOGICAL_ID_WIDTH{1'b0}};
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
                  core_req_capture_fire[1] &&
                  core_req_capture_fire[2]))
                local_protocol_error <= 1'b1;
            if (pop_input_fire && !core_req_capture_fire[2])
                local_protocol_error <= 1'b1;
            if (|(core_req_valid & core_req_capture_bad_id))
                local_protocol_error <= 1'b1;

            if (pop_input_fire) begin
                pop_chain_busy <= 1'b1;
                expected_pop_logical_id <=
                    {LOGICAL_ID_WIDTH{1'b0}};
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

                if (core_pop_logical_tree_id ==
                    LOGICAL_ID_WIDTH'(0)) begin
                    if (!returned_child_is_middle)
                        local_protocol_error <= 1'b1;
                    else begin
                        route_logical_id <= returned_child_id;
                        route_pending <= 1'b1;
                    end
                end else if ((core_pop_logical_tree_id >=
                              LOGICAL_ID_WIDTH'(1)) &&
                             (core_pop_logical_tree_id <=
                              LOGICAL_ID_WIDTH'(MIDDLE_COUNT))) begin
                    if (!returned_child_is_leaf ||
                        (middle_for_leaf(returned_child_id) !=
                         core_pop_logical_tree_id))
                        local_protocol_error <= 1'b1;
                    else begin
                        route_logical_id <= returned_child_id;
                        route_pending <= 1'b1;
                    end
                end else begin
                    if ((core_pop_logical_tree_id <
                         LOGICAL_ID_WIDTH'(FIRST_LEAF_ID)) ||
                        (core_pop_logical_tree_id >
                         LOGICAL_ID_WIDTH'(LAST_LEAF_ID)))
                        local_protocol_error <= 1'b1;
                    o_pop_valid <= 1'b1;
                    o_pop_leaf_id <= core_pop_logical_tree_id;
                    o_pop_payload <=
                        core_pop_data[(MTW+PTW)-1 -: MTW];
                    pop_chain_busy <= 1'b0;
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
