`timescale 1ns / 1ps

module HierarchicalHeterogeneousPIFO_tb;
    localparam PTW = 16;
    localparam MTW = 16;
    localparam DATA_WIDTH = PTW + MTW;
    localparam LOGICAL_TREE_NUM = 4;
    localparam PHYSICAL_TREE_NUM = 7;
    localparam LEVEL = 4;
    localparam SHARD_CAPACITY = 30;
    localparam INITIAL_PACKET_COUNT = 12;
    localparam PACKET_COUNT = INITIAL_PACKET_COUNT + 1;
    localparam MODEL_DEPTH = 2048;
    localparam RANDOM_OPERATION_COUNT = 1000;
    localparam REQUEST_PORTS = LOGICAL_TREE_NUM + 3;
    localparam LOGICAL_PENDING_DEPTH =
        LOGICAL_TREE_NUM + 3 + 8;
    localparam integer BASELINE_SHARD_COUNTS [0:LOGICAL_TREE_NUM-1] =
        '{4, 1, 1, 1};
    localparam integer BASELINE_SHARD_OFFSETS [0:LOGICAL_TREE_NUM-1] =
        '{0, 4, 5, 6};
    localparam PENDING_COUNT_WIDTH =
        $clog2(LOGICAL_PENDING_DEPTH + 1);

    reg clk;
    reg arst_n;
    reg push;
    reg [1:0] push_tree_id;
    reg [PTW-1:0] push_priority;
    reg [DATA_WIDTH-1:0] push_data;
    reg pop;

    wire push_ready;
    wire reject_bad_leaf_id;
    wire pop_req_ready;
    wire pop_out;
    wire [1:0] pop_tree_id;
    wire [DATA_WIDTH-1:0] pop_data;
    wire busy;
    wire protocol_error;

    wire [REQUEST_PORTS-1:0] internal_capture_fire;
    wire [LOGICAL_TREE_NUM-1:0] internal_task_fire;
    wire [LOGICAL_TREE_NUM-1:0] internal_task_push;
    wire [LOGICAL_TREE_NUM-1:0] internal_task_pp;
    wire [1:0]
        internal_task_logical_tree_id [0:LOGICAL_TREE_NUM-1];
    wire [2:0]
        internal_task_physical_tree_id [0:LOGICAL_TREE_NUM-1];
    wire [DATA_WIDTH-1:0]
        internal_task_data [0:LOGICAL_TREE_NUM-1];
    wire [PENDING_COUNT_WIDTH-1:0]
        logical_pending_count [0:LOGICAL_TREE_NUM-1];
    wire [PENDING_COUNT_WIDTH-1:0] pending_count;
    wire root_pop_routed;
    wire [1:0] root_pop_leaf_tree_id;
    wire [LEVEL-1:0] task_fifo_full;
    wire [LEVEL-1:0] task_write;
    wire [LEVEL-1:0] task_push;
    wire [LEVEL-1:0] task_pop;

    wire [2:0] shard_list [0:LOGICAL_TREE_NUM-1][0:3];
    wire [2:0] logical_shard_count [0:LOGICAL_TREE_NUM-1];
    wire [7:0] logical_count [0:LOGICAL_TREE_NUM-1];
    wire [1:0] push_rr_ptr [0:LOGICAL_TREE_NUM-1];
    wire [4:0] shard_count [0:PHYSICAL_TREE_NUM-1];
    wire [PTW-1:0] shard_head_rank [0:PHYSICAL_TREE_NUM-1];
    wire shard_empty [0:PHYSICAL_TREE_NUM-1];
    wire shard_full [0:PHYSICAL_TREE_NUM-1];
    wire shard_head_valid [0:PHYSICAL_TREE_NUM-1];
    wire update_pending [0:PHYSICAL_TREE_NUM-1];
    wire logical_busy [0:LOGICAL_TREE_NUM-1];
    wire [1:0] pending_logical_tree_id [0:PHYSICAL_TREE_NUM-1];
    wire pending_push [0:PHYSICAL_TREE_NUM-1];

    reg root_valid [0:MODEL_DEPTH-1];
    reg [PTW-1:0] root_rank [0:MODEL_DEPTH-1];
    reg [1:0] root_leaf [0:MODEL_DEPTH-1];
    integer root_physical [0:MODEL_DEPTH-1];
    integer root_entries;

    reg leaf_valid [0:LOGICAL_TREE_NUM-1][0:MODEL_DEPTH-1];
    reg leaf_reserved [0:LOGICAL_TREE_NUM-1][0:MODEL_DEPTH-1];
    reg [PTW-1:0] leaf_rank [0:LOGICAL_TREE_NUM-1][0:MODEL_DEPTH-1];
    reg [DATA_WIDTH-1:0] leaf_data [0:LOGICAL_TREE_NUM-1][0:MODEL_DEPTH-1];
    integer leaf_entries [0:LOGICAL_TREE_NUM-1];

    reg [1:0] expected_root_route [0:MODEL_DEPTH-1];
    reg [DATA_WIDTH-1:0] expected_root_data [0:MODEL_DEPTH-1];
    integer expected_root_route_head;
    integer expected_root_route_tail;
    integer expected_root_route_count;

    integer expected_leaf_issue_count;
    integer expected_leaf_issue_by_logical [0:LOGICAL_TREE_NUM-1];

    reg [DATA_WIDTH-1:0] expected_output [0:LOGICAL_TREE_NUM-1][0:MODEL_DEPTH-1];
    integer expected_output_head [0:LOGICAL_TREE_NUM-1];
    integer expected_output_tail [0:LOGICAL_TREE_NUM-1];
    integer expected_output_count [0:LOGICAL_TREE_NUM-1];

    integer failures;
    integer packet_pushes;
    integer packet_pop_requests;
    integer internal_root_pushes;
    integer internal_leaf_pushes;
    integer internal_root_pops;
    integer internal_leaf_pops;
    integer same_logical_root_pp_words;
    integer root_results;
    integer root_results_with_route_pending;
    integer packet_results;
    integer max_lane_writes_same_cycle;
    integer multi_lane_write_cycles;
    integer root_leaf_same_cycle_writes;
    integer root_leaf_same_lane_conflicts;
    integer fire_this_cycle;
    integer lane_writes_this_cycle;
    integer fire_port;
    integer i;
    integer init_i;
    integer init_j;
    integer watchdog;
    integer random_operation;
    integer random_leaf;
    integer random_choice;
    integer active_random_packets;
    reg [31:0] random_state;

    HierarchicalHeterogeneousPIFO #(
        .PTW(PTW),
        .MTW(MTW),
        .CTW(10),
        .LEVEL(LEVEL),
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(PHYSICAL_TREE_NUM),
        .SHARD_CAPACITY(SHARD_CAPACITY),
        .FIFO_SIZE(8),
        .MAX_SHARDS_PER_LOGICAL(4),
        .SHARD_COUNTS(BASELINE_SHARD_COUNTS),
        .SHARD_OFFSETS(BASELINE_SHARD_OFFSETS)
    ) dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_push(push),
        .i_push_tree_id(push_tree_id),
        .i_push_priority(push_priority),
        .i_push_data(push_data),
        .o_push_ready(push_ready),
        .o_reject_bad_leaf_id(reject_bad_leaf_id),
        .i_pop(pop),
        .o_pop_req_ready(pop_req_ready),
        .o_pop_out(pop_out),
        .o_pop_tree_id(pop_tree_id),
        .o_pop_data(pop_data),
        .o_busy(busy),
        .o_protocol_error(protocol_error),
        .o_internal_capture_fire(internal_capture_fire),
        .o_internal_task_fire(internal_task_fire),
        .o_internal_task_push(internal_task_push),
        .o_internal_task_logical_tree_id(internal_task_logical_tree_id),
        .o_internal_task_physical_tree_id(internal_task_physical_tree_id),
        .o_internal_task_data(internal_task_data),
        .o_logical_pending_count(logical_pending_count),
        .o_pending_count(pending_count),
        .o_root_pop_routed(root_pop_routed),
        .o_root_pop_leaf_tree_id(root_pop_leaf_tree_id),
        .o_task_fifo_full(task_fifo_full),
        .o_task_write(task_write),
        .o_task_push(task_push),
        .o_task_pop(task_pop),
        .o_shard_list(shard_list),
        .o_logical_shard_count(logical_shard_count),
        .o_logical_count(logical_count),
        .o_push_rr_ptr(push_rr_ptr),
        .o_shard_count(shard_count),
        .o_shard_head_rank(shard_head_rank),
        .o_shard_empty(shard_empty),
        .o_shard_full(shard_full),
        .o_shard_head_valid(shard_head_valid),
        .o_update_pending(update_pending),
        .o_logical_busy(logical_busy),
        .o_pending_logical_tree_id(pending_logical_tree_id),
        .o_pending_push(pending_push)
    );
    assign internal_task_pp = dut.core.directory_select_pp;

    always #5 clk = ~clk;

    task check;
        input condition;
        input [8*160-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s at time %0t", message, $time);
                failures = failures + 1;
            end
        end
    endtask

    task issue_packet;
        input integer leaf_id;
        input integer root_priority_value;
        input integer leaf_priority_value;
        input integer tag;
        integer root_slot;
        integer leaf_slot;
        integer wait_cycles;
        reg [DATA_WIDTH-1:0] item;
        begin
            item = {(16'hA000 + tag[15:0]), leaf_priority_value[PTW-1:0]};
            @(negedge clk);
            wait_cycles = 0;
            while (!push_ready && wait_cycles < 4000) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!push_ready)
                $fatal(1, "timeout waiting for packet Push task slots");
            push_tree_id = leaf_id[1:0];
            push_priority = root_priority_value[PTW-1:0];
            push_data = item;
            push = 1'b1;
            root_slot = root_entries;
            root_valid[root_slot] = 1'b1;
            root_rank[root_slot] = root_priority_value[PTW-1:0];
            root_leaf[root_slot] = leaf_id[1:0];
            root_physical[root_slot] = -1;
            root_entries = root_entries + 1;

            leaf_slot = leaf_entries[leaf_id];
            leaf_valid[leaf_id][leaf_slot] = 1'b1;
            leaf_reserved[leaf_id][leaf_slot] = 1'b0;
            leaf_rank[leaf_id][leaf_slot] = leaf_priority_value[PTW-1:0];
            leaf_data[leaf_id][leaf_slot] = item;
            leaf_entries[leaf_id] = leaf_entries[leaf_id] + 1;
            packet_pushes = packet_pushes + 1;

            @(posedge clk);
            @(negedge clk);
            push = 1'b0;
            push_tree_id = 2'b00;
            push_priority = {PTW{1'b0}};
            push_data = {DATA_WIDTH{1'b1}};
        end
    endtask

    task issue_packet_pop;
        integer wait_cycles;
        begin
            @(negedge clk);
            wait_cycles = 0;
            while (!pop_req_ready && wait_cycles < 4000) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!pop_req_ready)
                $fatal(1, "timeout waiting for packet Pop task slot");
            pop = 1'b1;
            @(posedge clk);
            packet_pop_requests = packet_pop_requests + 1;
            @(negedge clk);
            pop = 1'b0;
        end
    endtask

    // The original TASK_GENERATOR may receive packet Push and root Pop in the
    // same cycle.  The wrapper must retain both tasks and preserve Push-before-
    // Pop order for logical root 0 without turning them into a transaction FSM.
    task issue_packet_and_pop;
        input integer leaf_id;
        input integer root_priority_value;
        input integer leaf_priority_value;
        input integer tag;
        integer root_slot;
        integer leaf_slot;
        integer wait_cycles;
        reg [DATA_WIDTH-1:0] item;
        begin
            item = {(16'hA000 + tag[15:0]), leaf_priority_value[PTW-1:0]};
            @(negedge clk);
            wait_cycles = 0;
            while ((!push_ready || !pop_req_ready) &&
                   (wait_cycles < 4000)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!push_ready || !pop_req_ready)
                $fatal(1, "timeout waiting for same-cycle packet Push/Pop slots");
            push_tree_id = leaf_id[1:0];
            push_priority = root_priority_value[PTW-1:0];
            push_data = item;
            push = 1'b1;
            pop = 1'b1;
            root_slot = root_entries;
            root_valid[root_slot] = 1'b1;
            root_rank[root_slot] = root_priority_value[PTW-1:0];
            root_leaf[root_slot] = leaf_id[1:0];
            root_physical[root_slot] = -1;
            root_entries = root_entries + 1;

            leaf_slot = leaf_entries[leaf_id];
            leaf_valid[leaf_id][leaf_slot] = 1'b1;
            leaf_reserved[leaf_id][leaf_slot] = 1'b0;
            leaf_rank[leaf_id][leaf_slot] = leaf_priority_value[PTW-1:0];
            leaf_data[leaf_id][leaf_slot] = item;
            leaf_entries[leaf_id] = leaf_entries[leaf_id] + 1;
            packet_pushes = packet_pushes + 1;
            packet_pop_requests = packet_pop_requests + 1;

            @(posedge clk);
            @(negedge clk);
            push = 1'b0;
            pop = 1'b0;
            push_tree_id = 2'b00;
            push_priority = {PTW{1'b0}};
            push_data = {DATA_WIDTH{1'b1}};
        end
    endtask

    integer root_match;
    integer root_min_index;
    reg [PTW-1:0] root_min_rank;
    integer leaf_min_index;
    reg [PTW-1:0] leaf_min_rank_value;
    integer leaf_result_match;
    integer leaf_reserved_swap;
    integer routed_leaf_integer;

    task scoreboard_root_pop;
        input integer task_port;
        integer root_scan;
        begin
            root_min_index = -1;
            root_min_rank = {PTW{1'b1}};
            for (root_scan = 0; root_scan < MODEL_DEPTH;
                 root_scan = root_scan + 1) begin
                if (root_valid[root_scan] &&
                    ((root_min_index < 0) ||
                     (root_rank[root_scan] < root_min_rank) ||
                     ((root_rank[root_scan] == root_min_rank) &&
                      (root_physical[root_scan] <
                       root_physical[root_min_index])))) begin
                    root_min_index = root_scan;
                    root_min_rank = root_rank[root_scan];
                end
            end
            check(root_min_index >= 0,
                  "root Pop fired with empty model");
            if (root_min_index >= 0) begin
                check(root_physical[root_min_index] >= 0,
                      "root Pop preceded root Push mapping");
                check(internal_task_physical_tree_id[task_port] ==
                      root_physical[root_min_index],
                      "root Pop missed global-min shard");
                expected_root_route[expected_root_route_tail] =
                    root_leaf[root_min_index];
                expected_root_data[expected_root_route_tail] =
                    {root_leaf[root_min_index],
                     {(MTW-2){1'b0}},
                     root_rank[root_min_index]};
                expected_root_route_tail =
                    (expected_root_route_tail + 1) % MODEL_DEPTH;
                expected_root_route_count =
                    expected_root_route_count + 1;
                root_valid[root_min_index] = 1'b0;
            end
        end
    endtask

    // Independent scoreboard observes every vector request that is actually
    // written into an original per-lane TaskFIFO.  Root completions are
    // processed first because an empty route queue may bypass its leaf Pop
    // into a TaskFIFO on the very same edge.
    always @(posedge clk) begin
        if (!arst_n) begin
            max_lane_writes_same_cycle = 0;
            multi_lane_write_cycles = 0;
            root_leaf_same_cycle_writes = 0;
            root_leaf_same_lane_conflicts = 0;
        end else begin
            if (protocol_error) begin
                $display("FAIL: protocol_error asserted at time %0t", $time);
                failures = failures + 1;
            end
            if (|task_fifo_full) begin
                $display("FAIL: controlled test reached TaskFIFO full at time %0t", $time);
                failures = failures + 1;
            end

            if (root_pop_routed) begin
                root_results = root_results + 1;
                if (expected_leaf_issue_count > 0)
                    root_results_with_route_pending =
                        root_results_with_route_pending + 1;
                check(expected_root_route_count > 0,
                      "root Pop result arrived without an enqueued root Pop");
                if (expected_root_route_count > 0) begin
                    check(dut.core_root_pop_data ==
                          expected_root_data[
                              expected_root_route_head],
                          "root result leaf ID/rank payload mismatch");
                    check(root_pop_leaf_tree_id ==
                          expected_root_route[expected_root_route_head],
                          "root Pop returned wrong logical leaf token");
                    expected_leaf_issue_by_logical[
                        expected_root_route[
                            expected_root_route_head]] =
                        expected_leaf_issue_by_logical[
                            expected_root_route[
                                expected_root_route_head]] + 1;
                    expected_leaf_issue_count = expected_leaf_issue_count + 1;
                    expected_root_route_head =
                        (expected_root_route_head + 1) % MODEL_DEPTH;
                    expected_root_route_count = expected_root_route_count - 1;
                end
            end

            lane_writes_this_cycle = 0;
            for (i = 0; i < LEVEL; i = i + 1)
                if (task_write[i])
                    lane_writes_this_cycle =
                        lane_writes_this_cycle + 1;
            if (lane_writes_this_cycle >
                max_lane_writes_same_cycle)
                max_lane_writes_same_cycle =
                    lane_writes_this_cycle;
            if (lane_writes_this_cycle >= 2)
                multi_lane_write_cycles =
                    multi_lane_write_cycles + 1;

            for (i = 1; i < LOGICAL_TREE_NUM; i = i + 1) begin
                if (internal_task_fire[0] &&
                    internal_task_push[0] &&
                    internal_task_fire[i] &&
                    internal_task_push[i]) begin
                    check((internal_task_physical_tree_id[0] %
                           LEVEL) !=
                          (internal_task_physical_tree_id[i] %
                           LEVEL),
                          "two Pushes fired together on one lane");
                    root_leaf_same_cycle_writes =
                        root_leaf_same_cycle_writes + 1;
                end
            end

            fire_this_cycle = 0;
            for (fire_port = 0;
                 fire_port < LOGICAL_TREE_NUM;
                 fire_port = fire_port + 1) begin
                if (internal_task_fire[fire_port]) begin
                    fire_this_cycle =
                        fire_this_cycle + 1;
                    check(!$isunknown(
                              internal_task_physical_tree_id[
                                  fire_port]),
                          "fired task physical ID contains X/Z");
                    check(internal_task_physical_tree_id[
                              fire_port] < PHYSICAL_TREE_NUM,
                          "fired task physical ID out of range");

                    if (internal_task_push[fire_port] &&
                        (internal_task_logical_tree_id[
                             fire_port] == 0)) begin
                        internal_root_pushes =
                            internal_root_pushes + 1;
                        check(internal_task_physical_tree_id[
                                  fire_port] <= 3,
                              "root Push mapped outside root shard set");
                        root_match = -1;
                        for (i = 0; i < MODEL_DEPTH;
                             i = i + 1) begin
                            if (root_valid[i] &&
                                (root_rank[i] ==
                                 internal_task_data[
                                     fire_port][PTW-1:0]) &&
                                (root_leaf[i] ==
                                 internal_task_data[
                                     fire_port]
                                     [DATA_WIDTH-1 -: 2]) &&
                                (root_physical[i] < 0))
                                root_match = i;
                        end
                        check(root_match >= 0,
                              "root Push was not generated by packet model");
                        if (root_match >= 0) begin
                            check(internal_task_data[
                                      fire_port]
                                      [DATA_WIDTH-1 -: 2] ==
                                  root_leaf[root_match],
                                  "root token lacks logical leaf ID");
                            root_physical[root_match] =
                                internal_task_physical_tree_id[
                                    fire_port];
                        end
                        if (internal_task_pp[fire_port]) begin
                            same_logical_root_pp_words =
                                same_logical_root_pp_words + 1;
                            check(task_push[
                                      internal_task_physical_tree_id[
                                          fire_port] % LEVEL] &&
                                  task_pop[
                                      internal_task_physical_tree_id[
                                          fire_port] % LEVEL],
                                  "root same-logical P/P was not one word");
                            internal_root_pops =
                                internal_root_pops + 1;
                            scoreboard_root_pop(fire_port);
                        end
                    end else if (internal_task_push[
                                     fire_port]) begin
                        internal_leaf_pushes =
                            internal_leaf_pushes + 1;
                        check(internal_task_logical_tree_id[
                                  fire_port] >= 1 &&
                              internal_task_logical_tree_id[
                                  fire_port] <= 3,
                              "leaf Push has invalid logical ID");
                        check(internal_task_physical_tree_id[
                                  fire_port] ==
                              (internal_task_logical_tree_id[
                                   fire_port] + 3),
                              "leaf Push mapped to wrong default shard");
                    end else if (internal_task_logical_tree_id[
                                     fire_port] == 0) begin
                        internal_root_pops =
                            internal_root_pops + 1;
                        scoreboard_root_pop(fire_port);
                    end else begin
                        internal_leaf_pops =
                            internal_leaf_pops + 1;
                        routed_leaf_integer =
                            internal_task_logical_tree_id[fire_port];
                        check(expected_leaf_issue_by_logical[
                                  routed_leaf_integer] > 0,
                              "leaf Pop lacks routed root result");
                        if (expected_leaf_issue_by_logical[
                                routed_leaf_integer] > 0) begin
                            expected_leaf_issue_by_logical[
                                routed_leaf_integer] =
                                expected_leaf_issue_by_logical[
                                    routed_leaf_integer] - 1;
                            expected_leaf_issue_count =
                                expected_leaf_issue_count - 1;

                            leaf_min_index = -1;
                            leaf_min_rank_value =
                                {PTW{1'b1}};
                            for (i = 0; i < MODEL_DEPTH;
                                 i = i + 1) begin
                                if (leaf_valid[
                                      routed_leaf_integer][i] &&
                                    !leaf_reserved[
                                      routed_leaf_integer][i] &&
                                    ((leaf_min_index < 0) ||
                                     (leaf_rank[
                                          routed_leaf_integer][i] <
                                      leaf_min_rank_value))) begin
                                    leaf_min_index = i;
                                    leaf_min_rank_value =
                                        leaf_rank[
                                            routed_leaf_integer][i];
                                end
                            end
                            check(leaf_min_index >= 0,
                                  "routed leaf Pop found empty leaf");
                            if (leaf_min_index >= 0) begin
                                expected_output[
                                    routed_leaf_integer]
                                    [expected_output_tail[
                                         routed_leaf_integer]] =
                                    {{MTW{1'b0}},
                                     leaf_min_rank_value};
                                expected_output_tail[
                                    routed_leaf_integer] =
                                    (expected_output_tail[
                                         routed_leaf_integer] + 1) %
                                    MODEL_DEPTH;
                                expected_output_count[
                                    routed_leaf_integer] =
                                    expected_output_count[
                                        routed_leaf_integer] + 1;
                                leaf_reserved[
                                    routed_leaf_integer]
                                    [leaf_min_index] = 1'b1;
                            end
                        end
                    end
                end
            end
            check(fire_this_cycle >=
                  lane_writes_this_cycle,
                  "TaskFIFO write lacks a fired vector task");

            if (pop_out) begin
                packet_results = packet_results + 1;
                check(pop_tree_id >= 1 && pop_tree_id <= 3,
                      "internal root Pop token leaked to external PopResultFIFO");
                if (pop_tree_id >= 1 && pop_tree_id <= 3) begin
                    check(expected_output_count[pop_tree_id] > 0,
                          "packet result has no independent leaf expectation");
                    if (expected_output_count[pop_tree_id] > 0) begin
                        check(pop_data[PTW-1:0] ==
                              expected_output[pop_tree_id]
                                             [expected_output_head[
                                                  pop_tree_id]]
                                             [PTW-1:0],
                              "leaf result did not have selected minimum rank");
                        leaf_result_match = -1;
                        for (i = 0; i < MODEL_DEPTH; i = i + 1)
                            if (leaf_valid[pop_tree_id][i] &&
                                (leaf_rank[pop_tree_id][i] ==
                                 expected_output[pop_tree_id]
                                                [expected_output_head[
                                                     pop_tree_id]]
                                                [PTW-1:0]) &&
                                (leaf_data[pop_tree_id][i] ==
                                 pop_data))
                                leaf_result_match = i;
                        check(leaf_result_match >= 0,
                              "leaf result rank/payload is not in model");
                        if (leaf_result_match >= 0) begin
                            if (!leaf_reserved[pop_tree_id][
                                    leaf_result_match]) begin
                                // Equal-rank BMW entries have no stable
                                // packet-order guarantee.  Move one abstract
                                // reservation within the same rank class to
                                // the concrete payload that RTL returned.
                                leaf_reserved_swap = -1;
                                for (i = 0; i < MODEL_DEPTH;
                                     i = i + 1)
                                    if (leaf_valid[pop_tree_id][i] &&
                                        leaf_reserved[pop_tree_id][i] &&
                                        (leaf_rank[pop_tree_id][i] ==
                                         pop_data[PTW-1:0]) &&
                                        (leaf_reserved_swap < 0))
                                        leaf_reserved_swap = i;
                                check(leaf_reserved_swap >= 0,
                                      "leaf result lacks rank reservation");
                                if (leaf_reserved_swap >= 0)
                                    leaf_reserved[pop_tree_id][
                                        leaf_reserved_swap] = 1'b0;
                            end
                            leaf_valid[pop_tree_id][
                                leaf_result_match] = 1'b0;
                            leaf_reserved[pop_tree_id][
                                leaf_result_match] = 1'b0;
                        end
                        expected_output_head[pop_tree_id] =
                            (expected_output_head[pop_tree_id] + 1) % MODEL_DEPTH;
                        expected_output_count[pop_tree_id] =
                            expected_output_count[pop_tree_id] - 1;
                    end
                end
            end
        end
    end

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        push = 1'b0;
        push_tree_id = 2'b00;
        push_priority = {PTW{1'b0}};
        push_data = {DATA_WIDTH{1'b1}};
        pop = 1'b0;
        failures = 0;
        packet_pushes = 0;
        packet_pop_requests = 0;
        internal_root_pushes = 0;
        internal_leaf_pushes = 0;
        internal_root_pops = 0;
        internal_leaf_pops = 0;
        same_logical_root_pp_words = 0;
        root_results = 0;
        root_results_with_route_pending = 0;
        packet_results = 0;
        max_lane_writes_same_cycle = 0;
        multi_lane_write_cycles = 0;
        root_leaf_same_cycle_writes = 0;
        root_leaf_same_lane_conflicts = 0;
        root_entries = 0;
        expected_root_route_head = 0;
        expected_root_route_tail = 0;
        expected_root_route_count = 0;
        expected_leaf_issue_count = 0;

        for (init_i = 0; init_i < MODEL_DEPTH;
             init_i = init_i + 1) begin
            root_valid[init_i] = 1'b0;
            root_rank[init_i] = {PTW{1'b0}};
            root_leaf[init_i] = 2'b00;
            root_physical[init_i] = -1;
            expected_root_route[init_i] = 2'b00;
            expected_root_data[init_i] = {DATA_WIDTH{1'b0}};
        end
        for (init_i = 0; init_i < LOGICAL_TREE_NUM;
             init_i = init_i + 1) begin
            leaf_entries[init_i] = 0;
            expected_leaf_issue_by_logical[init_i] = 0;
            expected_output_head[init_i] = 0;
            expected_output_tail[init_i] = 0;
            expected_output_count[init_i] = 0;
            for (init_j = 0; init_j < MODEL_DEPTH;
                 init_j = init_j + 1) begin
                leaf_valid[init_i][init_j] = 1'b0;
                leaf_reserved[init_i][init_j] = 1'b0;
                leaf_rank[init_i][init_j] = {PTW{1'b0}};
                leaf_data[init_i][init_j] = {DATA_WIDTH{1'b0}};
                expected_output[init_i][init_j] = {DATA_WIDTH{1'b0}};
            end
        end

        repeat (5) @(posedge clk);
        arst_n = 1'b1;
        repeat (3) @(posedge clk);

        // Unique root ranks make global ordering deterministic.  Leaf ranks
        // deliberately differ from root order so the test checks both tiers.
        issue_packet(1, 90, 44, 0);
        issue_packet(2, 10, 37, 1);
        issue_packet(3, 70, 18, 2);
        issue_packet(1, 30, 12, 3);
        issue_packet(2, 50, 29, 4);
        issue_packet(3, 20, 41, 5);
        issue_packet(1, 80, 31, 6);
        issue_packet(2, 40,  9, 7);
        issue_packet(3, 60, 24, 8);
        issue_packet(1, 15,  5, 9);
        issue_packet(2, 35, 53, 10);
        issue_packet(3, 25,  7, 11);

        watchdog = 0;
        while (((logical_count[0] != INITIAL_PACKET_COUNT) ||
                (logical_count[1] != 4) ||
                (logical_count[2] != 4) ||
                (logical_count[3] != 4) || busy) && watchdog < 8000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(watchdog < 8000, "timeout waiting for all hierarchical Pushes");
        for (init_i = 0; init_i < 4; init_i = init_i + 1)
            check(shard_count[init_i] == 3,
                  "round-robin root shard count is not three");
        check(shard_count[4] == 4 && shard_count[5] == 4 &&
              shard_count[6] == 4,
              "fixed leaf shard counts are incorrect before Pop phase");

        // Add a new globally minimal root token while presenting a root Pop on
        // the same edge.  The enqueued root Pop must observe the preceding
        // same-cycle root Push, and its routed leaf Pop must return tag 12.
        issue_packet_and_pop(2, 5, 2, 12);

        for (init_i = 0; init_i < INITIAL_PACKET_COUNT;
             init_i = init_i + 1)
            issue_packet_pop();

        watchdog = 0;
        while ((packet_results < PACKET_COUNT) && watchdog < 12000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(packet_results == PACKET_COUNT,
              "timeout waiting for all final packet Pop results");
        check(same_logical_root_pp_words > 0,
              "multi-shard root same-logical P/P not observed");

        watchdog = 0;
        while (busy && watchdog < 4000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(!busy, "hierarchical wrapper did not return idle");

        // Full-hierarchy equal-rank case: the scoreboard uses physical shard
        // ID as the deterministic cross-shard tie-break.
        issue_packet(1, 777, 31, 100);
        issue_packet(2, 777, 32, 101);
        issue_packet_pop();
        issue_packet_pop();

        // Same-leaf equal-root/equal-leaf ranks exercise the one-shard leaf
        // tie behavior independently from the root's cross-shard tie-break.
        // Full packet payload is checked, not only the packet tag.
        issue_packet(1, 778, 55, 102);
        issue_packet(1, 778, 55, 103);
        issue_packet_pop();
        issue_packet_pop();

        // Deterministic constrained-random packet traffic.  The outstanding
        // set is intentionally kept below all assumed TaskFIFO, route-queue,
        // and physical PIFO capacities.
        active_random_packets = 0;
        random_state = 32'h6d2b79f5;
        for (random_operation = 0;
             random_operation < RANDOM_OPERATION_COUNT;
             random_operation = random_operation + 1) begin
            random_state =
                random_state * 32'd1664525 + 32'd1013904223;
            random_choice = random_state % 100;
            if ((active_random_packets == 0) ||
                ((active_random_packets < 6) &&
                 (random_choice < 55))) begin
                random_leaf = 1 + ((random_state >> 8) % 3);
                issue_packet(
                    random_leaf,
                    1000 + random_operation,
                    1 + ((random_operation * 37) % 60000),
                    200 + random_operation);
                active_random_packets =
                    active_random_packets + 1;
            end else begin
                issue_packet_pop();
                active_random_packets =
                    active_random_packets - 1;
            end
        end
        while (active_random_packets > 0) begin
            issue_packet_pop();
            active_random_packets = active_random_packets - 1;
        end

        watchdog = 0;
        while (((packet_results != packet_pushes) || busy) &&
               watchdog < 200000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(packet_results == packet_pushes,
              "random phase packet results did not drain");
        check(!busy, "random phase wrapper did not return idle");

        check(packet_pop_requests == packet_pushes,
              "packet pulse request counts differ");
        check(internal_root_pushes == packet_pushes,
              "each packet did not create exactly one root Push");
        check(internal_leaf_pushes == packet_pushes,
              "each packet did not create exactly one leaf Push");
        check(internal_root_pops == packet_pushes,
              "each packet Pop did not create exactly one root Pop");
        check(root_results == packet_pushes,
              "each root Pop did not return exactly one internal token");
        check(root_results_with_route_pending > 0,
              "root results never overlapped an earlier leaf route");
        check(internal_leaf_pops == packet_pushes,
              "each root token did not create exactly one leaf Pop");
        check(packet_results == packet_pushes,
              "each packet did not appear exactly once externally");
        check(expected_root_route_count == 0,
              "unconsumed expected root route remains");
        check(expected_leaf_issue_count == 0,
              "unissued expected leaf Pop remains");
        for (init_i = 1; init_i < LOGICAL_TREE_NUM;
             init_i = init_i + 1)
            check(expected_leaf_issue_by_logical[init_i] == 0,
                  "per-logical expected leaf route remains");
        check(max_lane_writes_same_cycle >= 2 &&
              multi_lane_write_cycles > 0,
              "no cycle wrote more than one TaskFIFO lane");
        check(root_leaf_same_cycle_writes > 0,
              "root/leaf Push never injected together");
        check(pending_count == 0,
              "logical pending pool did not drain");

        for (init_i = 0; init_i < LOGICAL_TREE_NUM;
             init_i = init_i + 1) begin
            check(logical_count[init_i] == 0,
                  "logical count is nonzero after draining hierarchy");
            check(!logical_busy[init_i],
                  "logical busy remains asserted after draining hierarchy");
            check(expected_output_count[init_i] == 0,
                   "expected packet output queue is not empty");
            check(logical_pending_count[init_i] == 0,
                  "per-logical pending requests remain");
        end
        for (init_i = 0; init_i < PHYSICAL_TREE_NUM;
             init_i = init_i + 1) begin
            check(shard_count[init_i] == 0,
                  "physical shard count is nonzero after draining hierarchy");
            check(!update_pending[init_i],
                  "physical shard pending remains after draining hierarchy");
        end
        check(!protocol_error, "protocol error is sticky at end of test");
        for (init_i = 1; init_i < LOGICAL_TREE_NUM;
             init_i = init_i + 1)
            check(dut.leaf_route_count[init_i] == 0,
                  "local leaf-route queue did not drain");

        $display("Hierarchical stats: random_operations=%0d packet_pushes=%0d packet_pop_requests=%0d root_pushes=%0d leaf_pushes=%0d root_pops=%0d root_results=%0d overlapped_root_results=%0d leaf_pops=%0d packet_results=%0d max_lane_writes=%0d multi_lane_cycles=%0d root_leaf_same_cycle=%0d same_lane_conflicts=%0d",
                 RANDOM_OPERATION_COUNT,
                 packet_pushes, packet_pop_requests, internal_root_pushes,
                 internal_leaf_pushes, internal_root_pops, root_results,
                 root_results_with_route_pending,
                 internal_leaf_pops, packet_results,
                 max_lane_writes_same_cycle, multi_lane_write_cycles,
                 root_leaf_same_cycle_writes,
                 root_leaf_same_lane_conflicts);
        if (failures == 0)
            $display("PASS: HierarchicalHeterogeneousPIFO_tb");
        else begin
            $display("FAIL: HierarchicalHeterogeneousPIFO_tb failures=%0d",
                     failures);
            $fatal(1, "HierarchicalHeterogeneousPIFO_tb failed");
        end
        $finish;
    end

endmodule
