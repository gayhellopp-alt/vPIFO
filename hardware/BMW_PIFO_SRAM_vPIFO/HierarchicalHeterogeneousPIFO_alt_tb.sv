`timescale 1ns / 1ps

// Complete packet-path smoke test for a non-default explicit heterogeneous map:
//   logical root 0 -> physical {2, 0}
//   logical leaf 1 -> physical {5, 1}
//   logical leaf 2 -> physical {6}
//   logical leaf 3 -> physical {4, 3}
module HierarchicalHeterogeneousPIFO_alt_tb;
    localparam PTW = 16;
    localparam MTW = 16;
    localparam DATA_WIDTH = PTW + MTW;
    localparam LOGICAL_TREE_NUM = 4;
    localparam PHYSICAL_TREE_NUM = 7;
    localparam LEVEL = 4;
    localparam MAX_SHARDS_PER_LOGICAL = 2;
    localparam REQUEST_PORTS = LOGICAL_TREE_NUM + 3;
    localparam LOGICAL_PENDING_DEPTH =
        LOGICAL_TREE_NUM + 3 + 8;
    localparam PENDING_COUNT_WIDTH =
        $clog2(LOGICAL_PENDING_DEPTH + 1);
    localparam PACKET_COUNT = 5;
    localparam integer ALT_SHARD_COUNTS [0:LOGICAL_TREE_NUM-1] =
        '{2, 2, 1, 2};
    localparam integer ALT_SHARD_OFFSETS [0:LOGICAL_TREE_NUM-1] =
        '{0, 2, 4, 5};
    localparam integer ALT_SHARD_MAP [0:PHYSICAL_TREE_NUM-1] =
        '{2, 0, 5, 1, 6, 4, 3};

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

    wire [2:0]
        shard_list [0:LOGICAL_TREE_NUM-1]
                   [0:MAX_SHARDS_PER_LOGICAL-1];
    wire [1:0] logical_shard_count [0:LOGICAL_TREE_NUM-1];
    wire [7:0] logical_count [0:LOGICAL_TREE_NUM-1];
    wire push_rr_ptr [0:LOGICAL_TREE_NUM-1];
    wire [4:0] shard_count [0:PHYSICAL_TREE_NUM-1];
    wire [PTW-1:0] shard_head_rank [0:PHYSICAL_TREE_NUM-1];
    wire shard_empty [0:PHYSICAL_TREE_NUM-1];
    wire shard_full [0:PHYSICAL_TREE_NUM-1];
    wire shard_head_valid [0:PHYSICAL_TREE_NUM-1];
    wire update_pending [0:PHYSICAL_TREE_NUM-1];
    wire logical_busy [0:LOGICAL_TREE_NUM-1];
    wire [1:0]
        pending_logical_tree_id [0:PHYSICAL_TREE_NUM-1];
    wire pending_push [0:PHYSICAL_TREE_NUM-1];

    reg [DATA_WIDTH-1:0] expected_data [0:PACKET_COUNT-1];
    reg result_seen [0:PACKET_COUNT-1];
    integer root_physical_zero_pushes;
    integer root_physical_two_pushes;
    reg [PHYSICAL_TREE_NUM-1:0] leaf_push_physical_seen [1:3];
    integer root_pushes;
    integer leaf_pushes;
    integer root_pops;
    integer root_results;
    integer leaf_pops;
    integer packet_results;
    integer failures;
    integer port_index;
    integer match_index;
    integer result_matches;
    integer i;
    integer watchdog;

    HierarchicalHeterogeneousPIFO #(
        .PTW(PTW),
        .MTW(MTW),
        .LEVEL(LEVEL),
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(PHYSICAL_TREE_NUM),
        .MAX_SHARDS_PER_LOGICAL(MAX_SHARDS_PER_LOGICAL),
        .USE_EXPLICIT_SHARD_MAP(1),
        .SHARD_COUNTS(ALT_SHARD_COUNTS),
        .SHARD_OFFSETS(ALT_SHARD_OFFSETS),
        .EXPLICIT_SHARD_MAP(ALT_SHARD_MAP)
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
        .o_internal_task_logical_tree_id(
            internal_task_logical_tree_id),
        .o_internal_task_physical_tree_id(
            internal_task_physical_tree_id),
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
        .o_pending_logical_tree_id(
            pending_logical_tree_id),
        .o_pending_push(pending_push)
    );

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
        input integer root_rank;
        input integer leaf_rank;
        input integer tag;
        input integer expected_index;
        integer wait_cycles;
        begin
            @(negedge clk);
            wait_cycles = 0;
            while (!push_ready && wait_cycles < 4000) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!push_ready)
                $fatal(1, "alternate map Push slot timeout");
            push_tree_id = leaf_id[1:0];
            push_priority = root_rank[PTW-1:0];
            push_data =
                {tag[MTW-1:0], leaf_rank[PTW-1:0]};
            expected_data[expected_index] = push_data;
            push = 1'b1;
            @(posedge clk);
            @(negedge clk);
            push = 1'b0;
        end
    endtask

    task issue_pop;
        integer wait_cycles;
        begin
            @(negedge clk);
            wait_cycles = 0;
            while (!pop_req_ready && wait_cycles < 4000) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!pop_req_ready)
                $fatal(1, "alternate map Pop slot timeout");
            pop = 1'b1;
            @(posedge clk);
            @(negedge clk);
            pop = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (arst_n) begin
            if (protocol_error)
                $fatal(1, "alternate map protocol error");
            if (|task_fifo_full)
                $fatal(1, "alternate map filled TaskFIFO");

            if (root_pop_routed)
                root_results = root_results + 1;

            for (port_index = 0;
                 port_index < LOGICAL_TREE_NUM;
                 port_index = port_index + 1) begin
                if (internal_task_fire[port_index]) begin
                    if (internal_task_push[port_index] &&
                        (internal_task_logical_tree_id[
                             port_index] == 0)) begin
                        root_pushes = root_pushes + 1;
                        check((internal_task_physical_tree_id[
                                   port_index] == 2) ||
                              (internal_task_physical_tree_id[
                                   port_index] == 0),
                              "alternate root Push left shard set");
                        if (internal_task_physical_tree_id[
                                port_index] == 0)
                            root_physical_zero_pushes =
                                root_physical_zero_pushes + 1;
                        if (internal_task_physical_tree_id[
                                port_index] == 2)
                            root_physical_two_pushes =
                                root_physical_two_pushes + 1;
                    end else if (internal_task_push[port_index]) begin
                        leaf_pushes = leaf_pushes + 1;
                        case (internal_task_logical_tree_id[
                                  port_index])
                            1:
                                check((internal_task_physical_tree_id[
                                           port_index] == 5) ||
                                      (internal_task_physical_tree_id[
                                           port_index] == 1),
                                      "alternate leaf 1 Push map");
                            2:
                                check(internal_task_physical_tree_id[
                                          port_index] == 6,
                                      "alternate leaf 2 Push map");
                            3:
                                check((internal_task_physical_tree_id[
                                           port_index] == 4) ||
                                      (internal_task_physical_tree_id[
                                           port_index] == 3),
                                      "alternate leaf 3 Push map");
                            default:
                                check(1'b0,
                                      "alternate leaf Push logical ID");
                        endcase
                        leaf_push_physical_seen[
                            internal_task_logical_tree_id[port_index]]
                            [internal_task_physical_tree_id[
                                port_index]] = 1'b1;
                    end else if (internal_task_logical_tree_id[
                                     port_index] == 0) begin
                        root_pops = root_pops + 1;
                        check((internal_task_physical_tree_id[
                                   port_index] == 2) ||
                              (internal_task_physical_tree_id[
                                   port_index] == 0),
                              "alternate root Pop left shard set");
                    end else begin
                        leaf_pops = leaf_pops + 1;
                    end
                end
            end

            if (pop_out) begin
                packet_results = packet_results + 1;
                check(pop_tree_id != 0,
                      "alternate root token leaked externally");
                result_matches = 0;
                match_index = -1;
                for (i = 0; i < PACKET_COUNT; i = i + 1) begin
                    if (!result_seen[i] &&
                        (pop_data == expected_data[i])) begin
                        result_matches = result_matches + 1;
                        match_index = i;
                    end
                end
                check(result_matches == 1,
                      "alternate packet result lost or duplicated");
                if (match_index >= 0)
                    result_seen[match_index] = 1'b1;
            end
        end
    end

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        push = 1'b0;
        push_tree_id = 0;
        push_priority = 0;
        push_data = {DATA_WIDTH{1'b1}};
        pop = 1'b0;
        failures = 0;
        root_pushes = 0;
        leaf_pushes = 0;
        root_pops = 0;
        root_results = 0;
        leaf_pops = 0;
        packet_results = 0;
        root_physical_zero_pushes = 0;
        root_physical_two_pushes = 0;
        for (i = 1; i <= 3; i = i + 1)
            leaf_push_physical_seen[i] = 0;
        for (i = 0; i < PACKET_COUNT; i = i + 1) begin
            expected_data[i] = 0;
            result_seen[i] = 1'b0;
        end

        repeat (5) @(posedge clk);
        arst_n = 1'b1;
        repeat (3) @(posedge clk);
        #1;
        check(shard_list[0][0] == 2 &&
              shard_list[0][1] == 0 &&
              shard_list[1][0] == 5 &&
              shard_list[1][1] == 1 &&
              shard_list[2][0] == 6 &&
              shard_list[3][0] == 4 &&
              shard_list[3][1] == 3,
              "alternate explicit directory map");

        issue_packet(1, 50, 20, 16'hB001, 0);
        issue_packet(2, 10,  5, 16'hB002, 1);
        issue_packet(3, 40, 15, 16'hB003, 2);
        issue_packet(1, 20,  7, 16'hB004, 3);
        issue_packet(3, 30,  3, 16'hB005, 4);

        watchdog = 0;
        while (busy && watchdog < 10000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(!busy, "alternate hierarchy Pushes did not drain");

        for (i = 0; i < PACKET_COUNT; i = i + 1)
            issue_pop();

        watchdog = 0;
        while (((packet_results != PACKET_COUNT) || busy) &&
               watchdog < 20000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(packet_results == PACKET_COUNT,
              "alternate hierarchy results did not drain");
        check(root_pushes == PACKET_COUNT &&
              leaf_pushes == PACKET_COUNT &&
              root_pops == PACKET_COUNT &&
              root_results == PACKET_COUNT &&
              leaf_pops == PACKET_COUNT,
              "alternate hierarchy task counts differ");
        $display("Alternate shard coverage: root0=%0d root2=%0d leaf1=%b leaf2=%b leaf3=%b",
                 root_physical_zero_pushes,
                 root_physical_two_pushes,
                 leaf_push_physical_seen[1],
                 leaf_push_physical_seen[2],
                 leaf_push_physical_seen[3]);
        check((root_physical_two_pushes > 0) &&
              (root_physical_zero_pushes > 0),
              "alternate root shards were not both used");
        check(leaf_push_physical_seen[1][5] &&
              leaf_push_physical_seen[1][1] &&
              leaf_push_physical_seen[2][6] &&
              leaf_push_physical_seen[3][4] &&
              leaf_push_physical_seen[3][3],
              "alternate leaf shard distribution incomplete");

        for (i = 0; i < LOGICAL_TREE_NUM; i = i + 1)
            check((logical_count[i] == 0) &&
                  (logical_pending_count[i] == 0) &&
                  !logical_busy[i],
                  "alternate logical state did not drain");
        check(pending_count == 0,
              "alternate logical pending pool did not drain");
        for (i = 0; i < PHYSICAL_TREE_NUM; i = i + 1)
            check((shard_count[i] == 0) &&
                  !update_pending[i],
                  "alternate physical state did not drain");
        for (i = 1; i < LOGICAL_TREE_NUM; i = i + 1)
            check(dut.leaf_route_count[i] == 0,
                  "alternate leaf route did not drain");

        if (failures == 0)
            $display("PASS: HierarchicalHeterogeneousPIFO_alt_tb");
        else
            $fatal(1,
                   "HierarchicalHeterogeneousPIFO_alt_tb failures=%0d",
                   failures);
        $finish;
    end
endmodule
