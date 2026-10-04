`timescale 1ns / 1ps

// Configuration-driven two-tier smoke regression.  Logical 0 retains the
// existing hierarchical root meaning; the highest generated logical ID is
// exercised as a leaf so logical count changes are covered without a 4-tree
// testbench assumption.
module GeneratedHierarchicalHeterogeneousPIFO_tb;
    localparam PTW = 16;
    localparam MTW = 16;
    localparam DATA_WIDTH = PTW + MTW;
    localparam LEVEL = VpifoConfigPkg::LEVEL;
    localparam LOGICAL_TREE_NUM = VpifoConfigPkg::LOGICAL_TREE_NUM;
    localparam PHYSICAL_TREE_NUM = VpifoConfigPkg::PHYSICAL_TREE_NUM;
    localparam MAX_SHARDS_PER_LOGICAL =
        VpifoConfigPkg::MAX_SHARDS_PER_LOGICAL;
    localparam LOGICAL_ID_WIDTH = VpifoConfigPkg::LOGICAL_ID_WIDTH;
    localparam PHYSICAL_ID_WIDTH = VpifoConfigPkg::PHYSICAL_ID_WIDTH;
    localparam SHARD_LIST_COUNT_WIDTH =
        (MAX_SHARDS_PER_LOGICAL <= 1) ? 1 :
        $clog2(MAX_SHARDS_PER_LOGICAL + 1);
    localparam TOTAL_COUNT_WIDTH =
        $clog2(PHYSICAL_TREE_NUM * VpifoConfigPkg::SHARD_CAPACITY + 1);
    localparam TARGET_LEAF = LOGICAL_TREE_NUM - 1;

    reg clk;
    reg arst_n;
    reg push;
    reg [LOGICAL_ID_WIDTH-1:0] push_tree_id;
    reg [PTW-1:0] push_priority;
    reg [DATA_WIDTH-1:0] push_data;
    reg pop;

    wire push_ready;
    wire reject_bad_leaf_id;
    wire pop_req_ready;
    wire pop_out;
    wire [LOGICAL_ID_WIDTH-1:0] pop_tree_id;
    wire [DATA_WIDTH-1:0] pop_data;
    wire protocol_error;
    wire [PHYSICAL_ID_WIDTH-1:0]
        internal_task_physical_tree_id [0:LOGICAL_TREE_NUM-1];
    wire [LOGICAL_TREE_NUM-1:0] internal_task_fire;
    wire [PHYSICAL_ID_WIDTH-1:0]
        shard_list [0:LOGICAL_TREE_NUM-1][0:MAX_SHARDS_PER_LOGICAL-1];
    wire [SHARD_LIST_COUNT_WIDTH-1:0]
        logical_shard_count [0:LOGICAL_TREE_NUM-1];
    wire [TOTAL_COUNT_WIDTH-1:0]
        logical_count [0:LOGICAL_TREE_NUM-1];

    integer failures;
    integer logical_id;
    integer shard_index;
    integer watchdog;
    reg [DATA_WIDTH-1:0] expected_data;

    HierarchicalHeterogeneousPIFO dut (
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
        .o_protocol_error(protocol_error),
        .o_internal_task_fire(internal_task_fire),
        .o_internal_task_physical_tree_id(internal_task_physical_tree_id),
        .o_shard_list(shard_list),
        .o_logical_shard_count(logical_shard_count),
        .o_logical_count(logical_count)
    );

    always #5 clk = ~clk;

    task check;
        input condition;
        input [8*160-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                failures = failures + 1;
            end
        end
    endtask

    task wait_for_logical_count;
        input integer requested_logical;
        input integer expected_count;
        begin
            watchdog = 0;
            while ((logical_count[requested_logical] != expected_count) &&
                   watchdog < 12000) begin
                @(posedge clk);
                watchdog = watchdog + 1;
            end
            check(logical_count[requested_logical] == expected_count,
                  "hierarchical logical count timed out");
        end
    endtask

    initial begin
        if (LOGICAL_TREE_NUM < 2)
            $fatal(1, "hierarchical generated test requires root plus one leaf");
        clk = 1'b0;
        arst_n = 1'b0;
        push = 1'b0;
        pop = 1'b0;
        push_tree_id = '0;
        push_priority = '0;
        push_data = '1;
        failures = 0;
        expected_data = 32'h5a17c0de ^ TARGET_LEAF;
        repeat (4) @(posedge clk);
        arst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (logical_id = 0; logical_id < LOGICAL_TREE_NUM;
             logical_id = logical_id + 1) begin
            check(logical_shard_count[logical_id] ==
                      VpifoConfigPkg::SHARD_COUNTS[logical_id],
                  "hierarchical RTL shard count differs from generated count");
            for (shard_index = 0;
                 shard_index < VpifoConfigPkg::SHARD_COUNTS[logical_id];
                 shard_index = shard_index + 1) begin
                check(shard_list[logical_id][shard_index] ==
                          VpifoConfigPkg::SHARD_OFFSETS[logical_id] + shard_index,
                      "hierarchical RTL shard list differs from generated layout");
            end
        end

        @(negedge clk);
        watchdog = 0;
        while (!push_ready && watchdog < 8000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (!push_ready)
            $fatal(1, "timeout waiting for generated hierarchical Push");
        push_tree_id = TARGET_LEAF[LOGICAL_ID_WIDTH-1:0];
        push_priority = 16'd9;
        push_data = expected_data;
        push = 1'b1;
        #1;
        check(!reject_bad_leaf_id, "highest generated leaf ID was rejected");
        @(posedge clk);
        @(negedge clk);
        push = 1'b0;
        push_tree_id = '0;
        push_data = '1;

        wait_for_logical_count(0, 1);
        wait_for_logical_count(TARGET_LEAF, 1);

        @(negedge clk);
        watchdog = 0;
        while (!pop_req_ready && watchdog < 8000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (!pop_req_ready)
            $fatal(1, "timeout waiting for generated hierarchical Pop");
        pop = 1'b1;
        @(posedge clk);
        @(negedge clk);
        pop = 1'b0;

        watchdog = 0;
        while (!pop_out && watchdog < 16000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(pop_out, "generated hierarchical packet Pop timed out");
        check(pop_tree_id == TARGET_LEAF,
              "generated hierarchical Pop returned wrong leaf ID");
        check(pop_data == expected_data,
              "generated hierarchical Pop returned wrong packet data");
        wait_for_logical_count(0, 0);
        wait_for_logical_count(TARGET_LEAF, 0);
        check(!protocol_error, "generated hierarchical protocol error");

        if (failures == 0)
            $display("PASS: GeneratedHierarchicalHeterogeneousPIFO_tb logical=%0d physical=%0d leaf=%0d",
                     LOGICAL_TREE_NUM, PHYSICAL_TREE_NUM, TARGET_LEAF);
        else
            $fatal(1, "GeneratedHierarchicalHeterogeneousPIFO_tb failures: %0d",
                   failures);
        $finish;
    end
endmodule
