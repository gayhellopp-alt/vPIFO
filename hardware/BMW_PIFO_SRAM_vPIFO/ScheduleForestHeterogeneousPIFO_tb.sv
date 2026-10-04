`timescale 1ns / 1ps

module ScheduleForestHeterogeneousPIFO_tb;
    localparam PTW = 16;
    localparam MTW = 16;
    localparam DATA_WIDTH = PTW + MTW;
    localparam LOGICAL_TREE_NUM = 4;
    localparam SEMANTIC_TREE_NUM = 2;
    localparam PHYSICAL_TREE_NUM = 6;
    localparam LEVEL = 4;
    localparam SHARD_CAPACITY = 30;
    localparam LOGICAL_PENDING_DEPTH = LOGICAL_TREE_NUM + 3 + 8;
    localparam TOTAL_COUNT_WIDTH =
        $clog2(PHYSICAL_TREE_NUM * SHARD_CAPACITY + 1);
    localparam PENDING_COUNT_WIDTH =
        $clog2(LOGICAL_PENDING_DEPTH + 1);
    localparam integer TREE_ROOTS [0:SEMANTIC_TREE_NUM-1] =
        '{0, 2};
    localparam integer NODE_PARENT [0:LOGICAL_TREE_NUM-1] =
        '{0, 0, 2, 2};
    localparam integer NODE_TREE_ID [0:LOGICAL_TREE_NUM-1] =
        '{0, 0, 1, 1};
    localparam integer NODE_IS_ROOT [0:LOGICAL_TREE_NUM-1] =
        '{1, 0, 1, 0};
    localparam integer SHARD_COUNTS [0:LOGICAL_TREE_NUM-1] =
        '{2, 1, 1, 2};
    localparam integer SHARD_OFFSETS [0:LOGICAL_TREE_NUM-1] =
        '{0, 2, 3, 4};
    localparam integer EXPLICIT_SHARD_MAP [0:PHYSICAL_TREE_NUM-1] =
        '{0, 1, 2, 3, 4, 5};

    reg clk;
    reg arst_n;
    reg push;
    reg [1:0] push_leaf_id;
    reg [PTW-1:0] push_priority;
    reg [DATA_WIDTH-1:0] push_data;
    reg pop;
    reg pop_semantic_tree_id;

    wire push_ready;
    wire reject_bad_leaf_id;
    wire pop_req_ready;
    wire reject_bad_tree_id;
    wire pop_out;
    wire pop_out_semantic_tree_id;
    wire [1:0] pop_out_leaf_id;
    wire [DATA_WIDTH-1:0] pop_out_data;
    wire root_pop_routed;
    wire [1:0] root_pop_root_id;
    wire [1:0] root_pop_leaf_id;
    wire busy;
    wire protocol_error;
    wire [TOTAL_COUNT_WIDTH-1:0]
        logical_count [0:LOGICAL_TREE_NUM-1];
    wire [PENDING_COUNT_WIDTH-1:0]
        logical_pending_count [0:LOGICAL_TREE_NUM-1];
    wire [PENDING_COUNT_WIDTH-1:0] pending_count;

    integer failures;
    integer routed_tree0;
    integer routed_tree1;
    integer watchdog;

    ScheduleForestHeterogeneousPIFO #(
        .PTW(PTW),
        .MTW(MTW),
        .CTW(10),
        .LEVEL(LEVEL),
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .SEMANTIC_TREE_NUM(SEMANTIC_TREE_NUM),
        .PHYSICAL_TREE_NUM(PHYSICAL_TREE_NUM),
        .SHARD_CAPACITY(SHARD_CAPACITY),
        .FIFO_SIZE(8),
        .MAX_SHARDS_PER_LOGICAL(2),
        .LOGICAL_PENDING_DEPTH(LOGICAL_PENDING_DEPTH),
        .TREE_ROOTS(TREE_ROOTS),
        .NODE_PARENT(NODE_PARENT),
        .NODE_TREE_ID(NODE_TREE_ID),
        .NODE_IS_ROOT(NODE_IS_ROOT),
        .SHARD_COUNTS(SHARD_COUNTS),
        .SHARD_OFFSETS(SHARD_OFFSETS),
        .EXPLICIT_SHARD_MAP(EXPLICIT_SHARD_MAP)
    ) dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_push(push),
        .i_push_leaf_id(push_leaf_id),
        .i_push_priority(push_priority),
        .i_push_data(push_data),
        .o_push_ready(push_ready),
        .o_reject_bad_leaf_id(reject_bad_leaf_id),
        .i_pop(pop),
        .i_pop_semantic_tree_id(pop_semantic_tree_id),
        .o_pop_req_ready(pop_req_ready),
        .o_reject_bad_tree_id(reject_bad_tree_id),
        .o_pop_out(pop_out),
        .o_pop_semantic_tree_id(pop_out_semantic_tree_id),
        .o_pop_leaf_id(pop_out_leaf_id),
        .o_pop_data(pop_out_data),
        .o_root_pop_routed(root_pop_routed),
        .o_root_pop_root_id(root_pop_root_id),
        .o_root_pop_leaf_id(root_pop_leaf_id),
        .o_busy(busy),
        .o_protocol_error(protocol_error),
        .o_logical_count(logical_count),
        .o_logical_pending_count(logical_pending_count),
        .o_pending_count(pending_count)
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

    function [DATA_WIDTH-1:0] packet;
        input integer tag;
        input integer rank;
        begin
            packet = {tag[15:0], rank[PTW-1:0]};
        end
    endfunction

    task issue_push;
        input integer leaf_id;
        input integer rank;
        input integer tag;
        integer wait_cycles;
        begin
            @(negedge clk);
            push_leaf_id = leaf_id[1:0];
            push_priority = rank[PTW-1:0];
            push_data = packet(tag, rank);
            push = 1'b1;
            wait_cycles = 0;
            while (!push_ready && wait_cycles < 4000) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!push_ready)
                $fatal(1, "timeout waiting for forest Push admission");
            @(posedge clk);
            @(negedge clk);
            push = 1'b0;
        end
    endtask

    task issue_pop;
        input integer semantic_tree_id;
        integer wait_cycles;
        begin
            @(negedge clk);
            pop_semantic_tree_id = semantic_tree_id[0];
            pop = 1'b1;
            wait_cycles = 0;
            while (!pop_req_ready && wait_cycles < 4000) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!pop_req_ready)
                $fatal(1, "timeout waiting for forest Pop admission");
            @(posedge clk);
            @(negedge clk);
            pop = 1'b0;
        end
    endtask

    task issue_cross_tree_push_pop;
        input integer leaf_id;
        input integer rank;
        input integer tag;
        input integer semantic_tree_id;
        integer wait_cycles;
        begin
            @(negedge clk);
            push_leaf_id = leaf_id[1:0];
            push_priority = rank[PTW-1:0];
            push_data = packet(tag, rank);
            pop_semantic_tree_id = semantic_tree_id[0];
            push = 1'b1;
            pop = 1'b1;
            wait_cycles = 0;
            while ((!push_ready || !pop_req_ready) &&
                   wait_cycles < 4000) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!push_ready || !pop_req_ready)
                $fatal(1, "timeout waiting for cross-tree Push/Pop");
            @(posedge clk);
            @(negedge clk);
            push = 1'b0;
            pop = 1'b0;
        end
    endtask

    task wait_counts;
        input integer count_root0;
        input integer count_leaf1;
        input integer count_root2;
        input integer count_leaf3;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (((logical_count[0] != count_root0) ||
                    (logical_count[1] != count_leaf1) ||
                    (logical_count[2] != count_root2) ||
                    (logical_count[3] != count_leaf3)) &&
                   wait_cycles < 12000) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            check(wait_cycles < 12000,
                  "timeout waiting for expected forest logical counts");
            if (wait_cycles >= 12000)
                $display("counts got=%0d,%0d,%0d,%0d want=%0d,%0d,%0d,%0d pending=%0d",
                         logical_count[0], logical_count[1],
                         logical_count[2], logical_count[3],
                         count_root0, count_leaf1,
                         count_root2, count_leaf3, pending_count);
        end
    endtask

    task expect_packet;
        input integer semantic_tree_id;
        input integer leaf_id;
        input integer rank;
        input integer tag;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!pop_out && wait_cycles < 12000) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            check(wait_cycles < 12000,
                  "timeout waiting for forest packet result");
            if (pop_out) begin
                check(pop_out_semantic_tree_id == semantic_tree_id[0],
                      "packet escaped through the wrong semantic tree");
                check(pop_out_leaf_id == leaf_id[1:0],
                      "packet result returned the wrong leaf node");
                check(pop_out_data == packet(tag, rank),
                      "packet result payload/rank mismatch");
                @(posedge clk);
            end
        end
    endtask

    always @(posedge clk) begin
        if (arst_n) begin
            if (protocol_error) begin
                $display("FAIL: protocol_error asserted at time %0t", $time);
                failures = failures + 1;
            end
            if (root_pop_routed) begin
                if (root_pop_root_id == 0) begin
                    routed_tree0 = routed_tree0 + 1;
                    check(root_pop_leaf_id == 1,
                          "tree 0 root routed outside tree 0");
                end else if (root_pop_root_id == 2) begin
                    routed_tree1 = routed_tree1 + 1;
                    check(root_pop_leaf_id == 3,
                          "tree 1 root routed outside tree 1");
                end else begin
                    check(1'b0, "unknown root produced a route result");
                end
            end
        end
    end

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        push = 1'b0;
        push_leaf_id = 2'b0;
        push_priority = {PTW{1'b0}};
        push_data = {DATA_WIDTH{1'b1}};
        pop = 1'b0;
        pop_semantic_tree_id = 1'b0;
        failures = 0;
        routed_tree0 = 0;
        routed_tree1 = 0;

        repeat (5) @(posedge clk);
        arst_n = 1'b1;
        repeat (3) @(posedge clk);

        // Roots 0 and 2 and leaves 1 and 3 occupy one namespace, while their
        // physical shard ranges are [0,3) and [3,6), respectively.
        issue_push(1, 20, 16'hA1);
        issue_push(3, 5, 16'hB1);
        issue_push(1, 10, 16'hA2);
        issue_push(3, 15, 16'hB2);
        wait_counts(2, 2, 2, 2);

        issue_pop(0);
        expect_packet(0, 1, 10, 16'hA2);
        issue_pop(1);
        expect_packet(1, 3, 5, 16'hB1);

        // A tree-0 Push concurrent with a tree-1 Pop must not be tagged as a
        // same-root P/P relation and must not alter tree-1 selection.
        issue_cross_tree_push_pop(1, 1, 16'hA0, 1);
        expect_packet(1, 3, 15, 16'hB2);
        wait_counts(2, 2, 0, 0);

        // The same wrapper must still preserve the original same-tree
        // Push-before-Pop/P/P behavior when both sides resolve to root 0.
        issue_cross_tree_push_pop(1, 0, 16'hC0, 0);
        expect_packet(0, 1, 0, 16'hC0);
        wait_counts(2, 2, 0, 0);

        issue_pop(0);
        expect_packet(0, 1, 1, 16'hA0);
        issue_pop(0);
        expect_packet(0, 1, 20, 16'hA1);

        wait_counts(0, 0, 0, 0);
        watchdog = 0;
        while (busy && watchdog < 12000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(!busy, "forest remained busy after complete drain");
        check(pending_count == 0,
              "shared logical pending pool did not drain");
        check((logical_pending_count[0] == 0) &&
              (logical_pending_count[1] == 0) &&
              (logical_pending_count[2] == 0) &&
              (logical_pending_count[3] == 0),
              "per-logical pending state did not drain");
        check(routed_tree0 == 4,
              "tree 0 did not produce exactly four root routes");
        check(routed_tree1 == 2,
              "tree 1 did not produce exactly two root routes");
        check(!reject_bad_leaf_id && !reject_bad_tree_id,
              "valid forest traffic was rejected");

        if (failures == 0)
            $display("PASS: ScheduleForestHeterogeneousPIFO_tb");
        else
            $fatal(1, "ScheduleForestHeterogeneousPIFO_tb failures=%0d",
                   failures);
        $finish;
    end

endmodule
