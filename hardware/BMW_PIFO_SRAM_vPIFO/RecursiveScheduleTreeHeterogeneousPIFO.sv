`timescale 1ns / 10ps

// Variable-depth semantic scheduling tree over one heterogeneous BMW domain.
//
// A full packet Push expands into one logical operation at every PIFO on the
// target-node-to-root path.  Split Push modes additionally support a shaping
// boundary: LOCAL stops after inserting the boundary node, while PARENT_REF
// resumes above that boundary using references only.
//
// A root Pop is followed recursively whenever a popped element is tagged as a
// child reference.  Multiple Pop chains may be in flight; a small tag reorder
// buffer restores external root-Pop order when different logical nodes finish
// at different times.
//
// The most-significant metadata bit is the element-kind tag (0=packet,
// 1=child reference).  Packet producers must therefore reserve that bit.
module RecursiveScheduleTreeHeterogeneousPIFO #(
    parameter PTW = 16,
    parameter MTW = 16,
    parameter CTW = 10,
    parameter LEVEL = 6,
    parameter LOGICAL_TREE_NUM = 4,
    parameter SEMANTIC_TREE_NUM = 1,
    parameter PHYSICAL_TREE_NUM = 6,
    parameter SHARD_CAPACITY = 126,
    parameter FIFO_SIZE = 8,
    parameter MAX_SHARDS_PER_LOGICAL = 3,
    parameter MAX_TREE_DEPTH = 3,
    parameter TASK_ORDER_WIDTH = 32,
    parameter LOGICAL_PENDING_DEPTH = 16,
    parameter POP_RESULT_FIFO_DEPTH = LOGICAL_TREE_NUM + LEVEL,
    parameter POP_TRACK_DEPTH = 16,
    parameter integer USE_EXPLICIT_SHARD_MAP = 0,
    parameter integer TREE_ROOTS [0:SEMANTIC_TREE_NUM-1] = '{default:0},
    parameter integer NODE_PARENT [0:LOGICAL_TREE_NUM-1] = '{default:0},
    parameter integer NODE_DEPTH [0:LOGICAL_TREE_NUM-1] = '{default:0},
    parameter integer NODE_TREE_ID [0:LOGICAL_TREE_NUM-1] = '{default:0},
    parameter integer SHARD_COUNTS [0:LOGICAL_TREE_NUM-1] = '{default:1},
    parameter integer SHARD_OFFSETS [0:LOGICAL_TREE_NUM-1] = '{default:0},
    parameter integer EXPLICIT_SHARD_MAP [0:PHYSICAL_TREE_NUM-1] =
        '{default:0},

    localparam DATA_WIDTH = MTW + PTW,
    localparam LOGICAL_ID_WIDTH = (LOGICAL_TREE_NUM <= 1) ? 1 :
                                  $clog2(LOGICAL_TREE_NUM),
    localparam SEMANTIC_TREE_ID_WIDTH = (SEMANTIC_TREE_NUM <= 1) ? 1 :
                                        $clog2(SEMANTIC_TREE_NUM),
    localparam PHYSICAL_ID_WIDTH = (PHYSICAL_TREE_NUM <= 1) ? 1 :
                                   $clog2(PHYSICAL_TREE_NUM),
    localparam SHARD_COUNT_WIDTH = (SHARD_CAPACITY <= 1) ? 1 :
                                   $clog2(SHARD_CAPACITY + 1),
    localparam TRACK_PTR_WIDTH = (POP_TRACK_DEPTH <= 1) ? 1 :
                                 $clog2(POP_TRACK_DEPTH),
    localparam TRACK_COUNT_WIDTH = (POP_TRACK_DEPTH <= 1) ? 1 :
                                   $clog2(POP_TRACK_DEPTH + 1),
    localparam PENDING_COUNT_WIDTH = (LOGICAL_PENDING_DEPTH <= 1) ? 1 :
                                     $clog2(LOGICAL_PENDING_DEPTH + 1),
    localparam TOTAL_COUNT_WIDTH =
        (PHYSICAL_TREE_NUM * SHARD_CAPACITY <= 1) ? 1 :
        $clog2(PHYSICAL_TREE_NUM * SHARD_CAPACITY + 1)
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,

    input  wire                         i_push,
    input  wire [1:0]                   i_push_mode,
    input  wire [LOGICAL_ID_WIDTH-1:0]  i_push_target_node_id,
    input  wire [LOGICAL_ID_WIDTH-1:0]  i_push_boundary_node_id,
    input  wire [PTW-1:0]
        i_push_rank_by_node [0:LOGICAL_TREE_NUM-1],
    input  wire [DATA_WIDTH-1:0]        i_push_packet_data,
    output wire                         o_push_ready,
    output wire                         o_reject_bad_push_path,

    input  wire                         i_pop,
    input  wire [SEMANTIC_TREE_ID_WIDTH-1:0]
                                        i_pop_semantic_tree_id,
    output wire                         o_pop_ready,
    output wire                         o_reject_bad_tree_id,
    output reg                          o_pop_out,
    output reg [SEMANTIC_TREE_ID_WIDTH-1:0]
                                        o_pop_semantic_tree_id,
    output reg [LOGICAL_ID_WIDTH-1:0]   o_pop_packet_node_id,
    output reg [DATA_WIDTH-1:0]         o_pop_data,

    output wire                         o_busy,
    output wire                         o_protocol_error,
    output wire [TRACK_COUNT_WIDTH-1:0] o_outstanding_pop_count,
    output wire [PENDING_COUNT_WIDTH-1:0] o_pending_count,
    output wire [TOTAL_COUNT_WIDTH-1:0]
        o_logical_count [0:LOGICAL_TREE_NUM-1],
    // Physical dispatch/debug visibility.  These signals are optional to
    // existing wrappers, but allow integration tests to verify the configured
    // logical-to-shard topology without reaching through hierarchy.
    output wire [LOGICAL_TREE_NUM-1:0] o_physical_dispatch_fire,
    output wire [LOGICAL_TREE_NUM-1:0] o_physical_dispatch_push,
    output wire [PHYSICAL_ID_WIDTH-1:0]
        o_selected_physical_tree_id [0:LOGICAL_TREE_NUM-1],
    output wire [SHARD_COUNT_WIDTH-1:0]
        o_physical_shard_count [0:PHYSICAL_TREE_NUM-1]
);

    localparam REQUEST_PORTS = LOGICAL_TREE_NUM;
    localparam [1:0] PUSH_MODE_FULL = 2'd0;
    localparam [1:0] PUSH_MODE_LOCAL = 2'd1;
    localparam [1:0] PUSH_MODE_PARENT_REF = 2'd2;
    localparam [LOGICAL_ID_WIDTH:0] LOGICAL_TREE_NUM_LIMIT =
        LOGICAL_TREE_NUM;
    localparam [SEMANTIC_TREE_ID_WIDTH:0] SEMANTIC_TREE_NUM_LIMIT =
        SEMANTIC_TREE_NUM;

    initial begin : validate_parameters
        integer node;
        integer tree;
        if ((PTW < 1) || (MTW < (LOGICAL_ID_WIDTH + 1)) ||
            (LOGICAL_TREE_NUM < 1) || (SEMANTIC_TREE_NUM < 1) ||
            (PHYSICAL_TREE_NUM < LOGICAL_TREE_NUM) ||
            (MAX_TREE_DEPTH < 1) || (POP_TRACK_DEPTH < 2) ||
            (LOGICAL_PENDING_DEPTH < REQUEST_PORTS))
            $fatal(1,
                "RecursiveScheduleTreeHeterogeneousPIFO parameters invalid");
        for (tree = 0; tree < SEMANTIC_TREE_NUM; tree = tree + 1) begin
            if ((TREE_ROOTS[tree] < 0) ||
                (TREE_ROOTS[tree] >= LOGICAL_TREE_NUM) ||
                (NODE_PARENT[TREE_ROOTS[tree]] != TREE_ROOTS[tree]) ||
                (NODE_DEPTH[TREE_ROOTS[tree]] != 0) ||
                (NODE_TREE_ID[TREE_ROOTS[tree]] != tree))
                $fatal(1, "invalid recursive schedule-tree root table");
        end
        for (node = 0; node < LOGICAL_TREE_NUM; node = node + 1) begin
            if ((NODE_PARENT[node] < 0) ||
                (NODE_PARENT[node] >= LOGICAL_TREE_NUM) ||
                (NODE_TREE_ID[node] < 0) ||
                (NODE_TREE_ID[node] >= SEMANTIC_TREE_NUM) ||
                (NODE_DEPTH[node] < 0) ||
                (NODE_DEPTH[node] >= MAX_TREE_DEPTH) ||
                ((NODE_PARENT[node] == node) &&
                 (TREE_ROOTS[NODE_TREE_ID[node]] != node)) ||
                ((NODE_PARENT[node] != node) &&
                 ((NODE_TREE_ID[NODE_PARENT[node]] != NODE_TREE_ID[node]) ||
                  (NODE_DEPTH[NODE_PARENT[node]] + 1 != NODE_DEPTH[node]))))
                $fatal(1, "invalid recursive schedule-node topology table");
        end
    end

    // ------------------------------------------------------------------
    // Full, local-subtree, and resumed-parent operation generation
    // ------------------------------------------------------------------
    reg push_path_valid;
    reg [LOGICAL_TREE_NUM-1:0] push_path_mask;
    reg [LOGICAL_ID_WIDTH-1:0]
        push_child_for_node [0:LOGICAL_TREE_NUM-1];
    integer push_path_count;
    integer push_walk_step;
    integer push_walk_node;
    integer push_walk_parent;
    integer push_init_node;
    reg push_walk_active;
    reg push_reached_root;
    reg push_reached_boundary;
    reg push_first_is_reference;
    reg push_mode_valid;
    integer push_boundary_node;

    always @* begin
        push_path_valid = 1'b0;
        push_path_mask = {LOGICAL_TREE_NUM{1'b0}};
        push_path_count = 0;
        push_walk_node = 0;
        push_walk_parent = 0;
        push_walk_active = 1'b0;
        push_reached_root = 1'b0;
        push_reached_boundary = 1'b0;
        push_first_is_reference = 1'b0;
        push_mode_valid = (i_push_mode == PUSH_MODE_FULL) ||
                          (i_push_mode == PUSH_MODE_LOCAL) ||
                          (i_push_mode == PUSH_MODE_PARENT_REF);
        push_boundary_node = 0;
        for (push_init_node = 0;
             push_init_node < LOGICAL_TREE_NUM;
             push_init_node = push_init_node + 1)
            push_child_for_node[push_init_node] =
                {LOGICAL_ID_WIDTH{1'b0}};

        if (push_mode_valid &&
            ({1'b0, i_push_target_node_id} < LOGICAL_TREE_NUM_LIMIT) &&
            ({1'b0, i_push_boundary_node_id} < LOGICAL_TREE_NUM_LIMIT)) begin
            push_boundary_node = int'(i_push_boundary_node_id);
            if (i_push_mode == PUSH_MODE_PARENT_REF) begin
                push_walk_node = NODE_PARENT[push_boundary_node];
                if (push_walk_node != push_boundary_node) begin
                    push_child_for_node[push_walk_node] =
                        i_push_boundary_node_id;
                    push_first_is_reference = 1'b1;
                    push_walk_active = 1'b1;
                end
            end else begin
                push_walk_node = int'(i_push_target_node_id);
                push_walk_active = 1'b1;
            end
            for (push_walk_step = 0;
                 push_walk_step < MAX_TREE_DEPTH;
                 push_walk_step = push_walk_step + 1) begin
                if (push_walk_active) begin
                    if (push_path_mask[push_walk_node]) begin
                        push_walk_active = 1'b0;
                    end else begin
                        push_path_mask[push_walk_node] = 1'b1;
                        push_path_count = push_path_count + 1;
                        if ((i_push_mode == PUSH_MODE_LOCAL) &&
                            (push_walk_node == push_boundary_node)) begin
                            push_reached_boundary = 1'b1;
                            push_walk_active = 1'b0;
                        end else begin
                            push_walk_parent = NODE_PARENT[push_walk_node];
                            if (push_walk_parent == push_walk_node) begin
                                push_reached_root = 1'b1;
                                push_walk_active = 1'b0;
                            end else if ((push_walk_parent < 0) ||
                                         (push_walk_parent >=
                                          LOGICAL_TREE_NUM)) begin
                                push_walk_active = 1'b0;
                            end else begin
                                push_child_for_node[push_walk_parent] =
                                    push_walk_node[LOGICAL_ID_WIDTH-1:0];
                                push_walk_node = push_walk_parent;
                            end
                        end
                    end
                end
            end
            if (i_push_mode == PUSH_MODE_LOCAL)
                push_path_valid = push_reached_boundary &&
                                  !push_walk_active;
            else
                push_path_valid = push_reached_root && !push_walk_active;
        end
    end

    // ------------------------------------------------------------------
    // Recursive Pop routing and completion tags
    // ------------------------------------------------------------------
    reg [TRACK_PTR_WIDTH-1:0]
        route_tag_mem [0:LOGICAL_TREE_NUM-1][0:POP_TRACK_DEPTH-1];
    reg [TRACK_PTR_WIDTH-1:0]
        route_head [0:LOGICAL_TREE_NUM-1];
    reg [TRACK_PTR_WIDTH-1:0]
        route_tail [0:LOGICAL_TREE_NUM-1];
    reg [TRACK_COUNT_WIDTH-1:0]
        route_count [0:LOGICAL_TREE_NUM-1];

    reg [TRACK_PTR_WIDTH-1:0]
        context_tag_mem [0:LOGICAL_TREE_NUM-1][0:POP_TRACK_DEPTH-1];
    reg [TRACK_PTR_WIDTH-1:0]
        context_head [0:LOGICAL_TREE_NUM-1];
    reg [TRACK_PTR_WIDTH-1:0]
        context_tail [0:LOGICAL_TREE_NUM-1];
    reg [TRACK_COUNT_WIDTH-1:0]
        context_count [0:LOGICAL_TREE_NUM-1];

    reg [DATA_WIDTH-1:0] completed_data [0:POP_TRACK_DEPTH-1];
    reg [LOGICAL_ID_WIDTH-1:0]
        completed_node [0:POP_TRACK_DEPTH-1];
    reg [SEMANTIC_TREE_ID_WIDTH-1:0]
        completed_tree [0:POP_TRACK_DEPTH-1];
    reg [POP_TRACK_DEPTH-1:0] completed_valid;
    reg [TRACK_PTR_WIDTH-1:0] pop_tag_head;
    reg [TRACK_PTR_WIDTH-1:0] pop_tag_tail;
    reg [TRACK_COUNT_WIDTH-1:0] outstanding_pop_count;

    wire pop_tree_id_valid =
        {1'b0, i_pop_semantic_tree_id} < SEMANTIC_TREE_NUM_LIMIT;
    reg [LOGICAL_ID_WIDTH-1:0] selected_pop_root_id;
    always @* begin
        selected_pop_root_id = {LOGICAL_ID_WIDTH{1'b0}};
        if (pop_tree_id_valid)
            selected_pop_root_id =
                TREE_ROOTS[int'(i_pop_semantic_tree_id)]
                    [LOGICAL_ID_WIDTH-1:0];
    end

    wire core_pop_valid;
    wire [LOGICAL_ID_WIDTH-1:0] core_pop_logical_tree_id;
    wire [DATA_WIDTH-1:0] core_pop_data;
    wire returned_is_reference = core_pop_data[DATA_WIDTH-1];
    wire [LOGICAL_ID_WIDTH-1:0] returned_child_id =
        core_pop_data[DATA_WIDTH-2 -: LOGICAL_ID_WIDTH];

    reg returned_context_valid;
    reg [TRACK_PTR_WIDTH-1:0] returned_context_tag;
    reg returned_reference_valid;
    always @* begin
        returned_context_valid = 1'b0;
        returned_context_tag = {TRACK_PTR_WIDTH{1'b0}};
        returned_reference_valid = 1'b0;
        if (core_pop_valid &&
            ({1'b0, core_pop_logical_tree_id} <
             LOGICAL_TREE_NUM_LIMIT)) begin
            returned_context_valid =
                context_count[int'(core_pop_logical_tree_id)] != 0;
            returned_context_tag =
                context_tag_mem[int'(core_pop_logical_tree_id)]
                               [context_head[int'(
                                    core_pop_logical_tree_id)]];
            if (returned_is_reference &&
                ({1'b0, returned_child_id} <
                 LOGICAL_TREE_NUM_LIMIT))
                returned_reference_valid =
                    (NODE_PARENT[int'(returned_child_id)] ==
                     int'(core_pop_logical_tree_id)) &&
                    (NODE_TREE_ID[int'(returned_child_id)] ==
                     NODE_TREE_ID[int'(core_pop_logical_tree_id)]);
        end
    end

    // ------------------------------------------------------------------
    // Native complete-operation interface to the heterogeneous BMW core
    // ------------------------------------------------------------------
    reg [REQUEST_PORTS-1:0] core_req_valid;
    reg [REQUEST_PORTS-1:0] core_req_push;
    reg [REQUEST_PORTS-1:0] core_req_pop;
    reg [LOGICAL_ID_WIDTH-1:0]
        core_req_logical_tree_id [0:REQUEST_PORTS-1];
    reg [DATA_WIDTH-1:0]
        core_req_push_data [0:REQUEST_PORTS-1];
    reg [TASK_ORDER_WIDTH-1:0]
        core_req_order [0:REQUEST_PORTS-1];
    reg [REQUEST_PORTS-1:0]
        core_req_merge_mask [0:REQUEST_PORTS-1];
    wire [REQUEST_PORTS-1:0] core_req_capture_ready;
    wire [REQUEST_PORTS-1:0] core_req_capture_fire;
    wire [REQUEST_PORTS-1:0] core_req_capture_bad_id;
    wire [PENDING_COUNT_WIDTH-1:0]
        core_pending_effective_free_count;
    wire [PENDING_COUNT_WIDTH-1:0] core_pending_count;
    wire core_busy;
    wire core_protocol_error;

    integer existing_route_request_count;
    integer combined_request_count;
    integer request_count_node;
    reg [LOGICAL_TREE_NUM-1:0] existing_route_mask;
    reg [LOGICAL_TREE_NUM-1:0] requested_node_mask;
    always @* begin
        existing_route_mask = {LOGICAL_TREE_NUM{1'b0}};
        existing_route_request_count = 0;
        for (request_count_node = 0;
             request_count_node < LOGICAL_TREE_NUM;
             request_count_node = request_count_node + 1) begin
            if ((NODE_PARENT[request_count_node] != request_count_node) &&
                (route_count[request_count_node] != 0)) begin
                existing_route_mask[request_count_node] = 1'b1;
                existing_route_request_count =
                    existing_route_request_count + 1;
            end
        end

        requested_node_mask = existing_route_mask;
        if (i_push && push_path_valid)
            requested_node_mask = requested_node_mask | push_path_mask;
        if (i_pop && pop_tree_id_valid)
            requested_node_mask[selected_pop_root_id] = 1'b1;
        combined_request_count = 0;
        for (request_count_node = 0;
             request_count_node < LOGICAL_TREE_NUM;
             request_count_node = request_count_node + 1)
            combined_request_count = combined_request_count +
                requested_node_mask[request_count_node];
    end

    wire combined_capacity_available =
        int'(core_pending_effective_free_count) >=
        combined_request_count;
    wire track_slot_available =
        outstanding_pop_count < POP_TRACK_DEPTH;
    assign o_push_ready = i_arst_n && combined_capacity_available;
    assign o_pop_ready = i_arst_n && track_slot_available &&
        combined_capacity_available;
    wire push_input_fire =
        i_push && o_push_ready && push_path_valid;
    wire pop_input_fire =
        i_pop && o_pop_ready && pop_tree_id_valid;
    assign o_reject_bad_push_path =
        i_push && o_push_ready && !push_path_valid;
    assign o_reject_bad_tree_id =
        i_pop && o_pop_ready && !pop_tree_id_valid;

    reg [TASK_ORDER_WIDTH-1:0] task_order_counter;
    integer request_node;
    reg request_node_has_route_pop;
    reg request_node_has_root_pop;
    reg [LOGICAL_ID_WIDTH-1:0] request_child_id;
    always @* begin
        for (request_node = 0;
             request_node < LOGICAL_TREE_NUM;
             request_node = request_node + 1) begin
            request_node_has_route_pop =
                (NODE_PARENT[request_node] != request_node) &&
                (route_count[request_node] != 0);
            request_node_has_root_pop = pop_input_fire &&
                (int'(selected_pop_root_id) == request_node);
            core_req_push[request_node] = push_input_fire &&
                push_path_mask[request_node];
            core_req_pop[request_node] =
                request_node_has_route_pop || request_node_has_root_pop;
            core_req_valid[request_node] =
                core_req_push[request_node] || core_req_pop[request_node];
            core_req_logical_tree_id[request_node] =
                request_node[LOGICAL_ID_WIDTH-1:0];
            core_req_order[request_node] = task_order_counter;
            core_req_merge_mask[request_node] =
                {REQUEST_PORTS{1'b0}};
            request_child_id = push_child_for_node[request_node];
            if (!push_first_is_reference &&
                (int'(i_push_target_node_id) == request_node))
                core_req_push_data[request_node] =
                    {1'b0,
                     i_push_packet_data[DATA_WIDTH-2:PTW],
                     i_push_rank_by_node[request_node]};
            else
                core_req_push_data[request_node] =
                    {1'b1,
                     request_child_id,
                     {(MTW-LOGICAL_ID_WIDTH-1){1'b0}},
                     i_push_rank_by_node[request_node]};
        end
    end

    // ------------------------------------------------------------------
    // Queue, tag, and result state
    // ------------------------------------------------------------------
    reg local_protocol_error;
    integer reset_node;
    integer reset_entry;
    integer update_node;
    reg route_dequeue;
    reg route_enqueue;
    reg context_enqueue;
    reg context_dequeue;
    reg [TRACK_PTR_WIDTH-1:0] context_enqueue_tag;
    reg output_dequeue;

    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            task_order_counter <= {TASK_ORDER_WIDTH{1'b0}};
            local_protocol_error <= 1'b0;
            completed_valid <= {POP_TRACK_DEPTH{1'b0}};
            pop_tag_head <= {TRACK_PTR_WIDTH{1'b0}};
            pop_tag_tail <= {TRACK_PTR_WIDTH{1'b0}};
            outstanding_pop_count <= {TRACK_COUNT_WIDTH{1'b0}};
            o_pop_out <= 1'b0;
            o_pop_semantic_tree_id <=
                {SEMANTIC_TREE_ID_WIDTH{1'b0}};
            o_pop_packet_node_id <= {LOGICAL_ID_WIDTH{1'b0}};
            o_pop_data <= {DATA_WIDTH{1'b0}};
            for (reset_node = 0;
                 reset_node < LOGICAL_TREE_NUM;
                 reset_node = reset_node + 1) begin
                route_head[reset_node] <= {TRACK_PTR_WIDTH{1'b0}};
                route_tail[reset_node] <= {TRACK_PTR_WIDTH{1'b0}};
                route_count[reset_node] <= {TRACK_COUNT_WIDTH{1'b0}};
                context_head[reset_node] <= {TRACK_PTR_WIDTH{1'b0}};
                context_tail[reset_node] <= {TRACK_PTR_WIDTH{1'b0}};
                context_count[reset_node] <= {TRACK_COUNT_WIDTH{1'b0}};
                for (reset_entry = 0;
                     reset_entry < POP_TRACK_DEPTH;
                     reset_entry = reset_entry + 1) begin
                    route_tag_mem[reset_node][reset_entry] <=
                        {TRACK_PTR_WIDTH{1'b0}};
                    context_tag_mem[reset_node][reset_entry] <=
                        {TRACK_PTR_WIDTH{1'b0}};
                end
            end
            for (reset_entry = 0;
                 reset_entry < POP_TRACK_DEPTH;
                 reset_entry = reset_entry + 1) begin
                completed_data[reset_entry] <= {DATA_WIDTH{1'b0}};
                completed_node[reset_entry] <=
                    {LOGICAL_ID_WIDTH{1'b0}};
                completed_tree[reset_entry] <=
                    {SEMANTIC_TREE_ID_WIDTH{1'b0}};
            end
        end else begin
            task_order_counter <= task_order_counter + 1'b1;
            o_pop_out <= 1'b0;
            output_dequeue = completed_valid[pop_tag_head];

            if (output_dequeue) begin
                o_pop_out <= 1'b1;
                o_pop_semantic_tree_id <= completed_tree[pop_tag_head];
                o_pop_packet_node_id <= completed_node[pop_tag_head];
                o_pop_data <= completed_data[pop_tag_head];
                completed_valid[pop_tag_head] <= 1'b0;
                if (pop_tag_head == TRACK_PTR_WIDTH'(
                        POP_TRACK_DEPTH - 1))
                    pop_tag_head <= {TRACK_PTR_WIDTH{1'b0}};
                else
                    pop_tag_head <= pop_tag_head + 1'b1;
            end

            if (pop_input_fire) begin
                completed_tree[pop_tag_tail] <=
                    i_pop_semantic_tree_id;
                if (pop_tag_tail == TRACK_PTR_WIDTH'(
                        POP_TRACK_DEPTH - 1))
                    pop_tag_tail <= {TRACK_PTR_WIDTH{1'b0}};
                else
                    pop_tag_tail <= pop_tag_tail + 1'b1;
            end

            case ({pop_input_fire, output_dequeue})
                2'b10: outstanding_pop_count <=
                    outstanding_pop_count + 1'b1;
                2'b01: outstanding_pop_count <=
                    outstanding_pop_count - 1'b1;
                default: outstanding_pop_count <=
                    outstanding_pop_count;
            endcase

            if (i_push && o_push_ready && !push_path_valid)
                local_protocol_error <= 1'b1;
            if (i_pop && o_pop_ready && !pop_tree_id_valid)
                local_protocol_error <= 1'b1;
            if (|(core_req_valid & core_req_capture_bad_id))
                local_protocol_error <= 1'b1;
            if (push_input_fire &&
                ((core_req_capture_fire & push_path_mask) !=
                 push_path_mask))
                local_protocol_error <= 1'b1;
            if (pop_input_fire &&
                !core_req_capture_fire[selected_pop_root_id])
                local_protocol_error <= 1'b1;

            if (core_pop_valid &&
                (!returned_context_valid ||
                 (returned_is_reference &&
                  !returned_reference_valid)))
                local_protocol_error <= 1'b1;

            if (core_pop_valid && returned_context_valid &&
                !returned_is_reference) begin
                if (completed_valid[returned_context_tag])
                    local_protocol_error <= 1'b1;
                else begin
                    completed_valid[returned_context_tag] <= 1'b1;
                    completed_data[returned_context_tag] <= core_pop_data;
                    completed_node[returned_context_tag] <=
                        core_pop_logical_tree_id;
                end
            end

            for (update_node = 0;
                 update_node < LOGICAL_TREE_NUM;
                 update_node = update_node + 1) begin
                route_dequeue =
                    (route_count[update_node] != 0) &&
                    core_req_capture_fire[update_node] &&
                    core_req_pop[update_node] &&
                    (NODE_PARENT[update_node] != update_node);
                route_enqueue = core_pop_valid &&
                    returned_context_valid && returned_reference_valid &&
                    (int'(returned_child_id) == update_node);

                if (route_enqueue &&
                    (route_count[update_node] == POP_TRACK_DEPTH) &&
                    !route_dequeue) begin
                    local_protocol_error <= 1'b1;
                end else begin
                    case ({route_enqueue, route_dequeue})
                        2'b10: route_count[update_node] <=
                            route_count[update_node] + 1'b1;
                        2'b01: route_count[update_node] <=
                            route_count[update_node] - 1'b1;
                        default: route_count[update_node] <=
                            route_count[update_node];
                    endcase
                    if (route_enqueue) begin
                        route_tag_mem[update_node]
                                     [route_tail[update_node]] <=
                            returned_context_tag;
                        if (route_tail[update_node] ==
                            TRACK_PTR_WIDTH'(POP_TRACK_DEPTH - 1))
                            route_tail[update_node] <=
                                {TRACK_PTR_WIDTH{1'b0}};
                        else
                            route_tail[update_node] <=
                                route_tail[update_node] + 1'b1;
                    end
                    if (route_dequeue) begin
                        if (route_head[update_node] ==
                            TRACK_PTR_WIDTH'(POP_TRACK_DEPTH - 1))
                            route_head[update_node] <=
                                {TRACK_PTR_WIDTH{1'b0}};
                        else
                            route_head[update_node] <=
                                route_head[update_node] + 1'b1;
                    end
                end

                context_enqueue =
                    core_req_capture_fire[update_node] &&
                    core_req_pop[update_node];
                context_dequeue = core_pop_valid &&
                    (int'(core_pop_logical_tree_id) == update_node) &&
                    returned_context_valid;
                context_enqueue_tag = pop_tag_tail;
                if (NODE_PARENT[update_node] != update_node)
                    context_enqueue_tag =
                        route_tag_mem[update_node]
                                     [route_head[update_node]];

                if (context_enqueue &&
                    (context_count[update_node] == POP_TRACK_DEPTH) &&
                    !context_dequeue) begin
                    local_protocol_error <= 1'b1;
                end else begin
                    case ({context_enqueue, context_dequeue})
                        2'b10: context_count[update_node] <=
                            context_count[update_node] + 1'b1;
                        2'b01: context_count[update_node] <=
                            context_count[update_node] - 1'b1;
                        default: context_count[update_node] <=
                            context_count[update_node];
                    endcase
                    if (context_enqueue) begin
                        context_tag_mem[update_node]
                                       [context_tail[update_node]] <=
                            context_enqueue_tag;
                        if (context_tail[update_node] ==
                            TRACK_PTR_WIDTH'(POP_TRACK_DEPTH - 1))
                            context_tail[update_node] <=
                                {TRACK_PTR_WIDTH{1'b0}};
                        else
                            context_tail[update_node] <=
                                context_tail[update_node] + 1'b1;
                    end
                    if (context_dequeue) begin
                        if (context_head[update_node] ==
                            TRACK_PTR_WIDTH'(POP_TRACK_DEPTH - 1))
                            context_head[update_node] <=
                                {TRACK_PTR_WIDTH{1'b0}};
                        else
                            context_head[update_node] <=
                                context_head[update_node] + 1'b1;
                    end
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
        .SINGLE_POP_RETURN(0),
        .USE_EXPLICIT_SHARD_MAP(USE_EXPLICIT_SHARD_MAP),
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
        .o_dispatch_fire(o_physical_dispatch_fire),
        .o_dispatch_push(o_physical_dispatch_push),
        .o_dispatch_logical_tree_id(),
        .o_selected_physical_tree_id(o_selected_physical_tree_id),
        .o_dispatch_data(),
        .o_dispatch_source_port(),
        .o_dispatch_reject_empty(),
        .o_dispatch_reject_full(),
        .o_logical_pending_count(),
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
        .o_task_fifo_full(),
        .o_task_write(),
        .o_task_push(),
        .o_task_pop(),
        .o_shard_list(),
        .o_logical_shard_count(),
        .o_logical_count(o_logical_count),
        .o_push_rr_ptr(),
        .o_shard_count(o_physical_shard_count),
        .o_shard_head_rank(),
        .o_shard_empty(),
        .o_shard_full(),
        .o_shard_head_valid(),
        .o_update_pending(),
        .o_logical_busy(),
        .o_pending_logical_tree_id(),
        .o_pending_push()
    );

    integer busy_node;
    reg route_or_context_busy;
    always @* begin
        route_or_context_busy = 1'b0;
        for (busy_node = 0;
             busy_node < LOGICAL_TREE_NUM;
             busy_node = busy_node + 1)
            route_or_context_busy = route_or_context_busy ||
                (route_count[busy_node] != 0) ||
                (context_count[busy_node] != 0);
    end

    assign o_outstanding_pop_count = outstanding_pop_count;
    assign o_pending_count = core_pending_count;
    assign o_busy = core_busy || route_or_context_busy ||
        (outstanding_pop_count != 0);
    assign o_protocol_error = core_protocol_error ||
        local_protocol_error;

endmodule
