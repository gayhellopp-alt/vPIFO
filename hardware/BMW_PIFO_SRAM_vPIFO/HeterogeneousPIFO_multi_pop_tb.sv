`timescale 1ns / 1ps

// Directed integration coverage for real multi-lane Engine Pop returns.
// Logical 0 is arranged to Pop physical shard 3 while logicals 1..3 use fixed
// shards 4..6, so all four requests dispatch onto distinct Engine lanes.
module HeterogeneousPIFO_multi_pop_tb;
    localparam PTW = 16;
    localparam MTW = 16;
    localparam DATA_WIDTH = PTW + MTW;
    localparam LOGICAL_TREE_NUM = 4;
    localparam PHYSICAL_TREE_NUM = 7;
    localparam LEVEL = 4;
    localparam REQUEST_PORTS = 4;
    localparam LOGICAL_ID_WIDTH = 2;
    localparam PHYSICAL_ID_WIDTH = 3;
    localparam PENDING_COUNT_WIDTH = 4;

    reg clk;
    reg arst_n;
    reg [REQUEST_PORTS-1:0] req_valid;
    reg [REQUEST_PORTS-1:0] req_push;
    reg [LOGICAL_ID_WIDTH-1:0]
        logical_tree_id [0:REQUEST_PORTS-1];
    reg [DATA_WIDTH-1:0] push_data [0:REQUEST_PORTS-1];
    reg [31:0] req_order [0:REQUEST_PORTS-1];
    reg [REQUEST_PORTS-1:0]
        req_merge_mask [0:REQUEST_PORTS-1];

    wire [REQUEST_PORTS-1:0] req_capture_ready;
    wire [REQUEST_PORTS-1:0] req_capture_fire;
    wire [LOGICAL_TREE_NUM-1:0] dispatch_fire;
    wire [PHYSICAL_ID_WIDTH-1:0]
        selected_physical_tree_id [0:LOGICAL_TREE_NUM-1];
    wire [PENDING_COUNT_WIDTH-1:0] pending_count;
    wire busy;
    wire pop_valid;
    wire [LOGICAL_ID_WIDTH-1:0] pop_logical_tree_id;
    wire [DATA_WIDTH-1:0] pop_data_out;
    wire protocol_error;
    wire [7:0] logical_count [0:LOGICAL_TREE_NUM-1];
    wire [4:0] shard_count [0:PHYSICAL_TREE_NUM-1];
    wire [PTW-1:0] shard_head_rank [0:PHYSICAL_TREE_NUM-1];

    reg [DATA_WIDTH-1:0] expected_pop_data [0:LOGICAL_TREE_NUM-1];
    reg [LOGICAL_TREE_NUM-1:0] pop_seen;
    integer failures;
    integer order_value;
    integer watchdog;
    integer port;
    integer monitor_lane;
    integer dispatches_this_cycle;
    integer pop_received;
    integer max_pop_dispatches_same_cycle;
    integer max_pop_returns_same_cycle;

    HeterogeneousPIFO dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_req_valid(req_valid),
        .i_req_push(req_push),
        .i_req_pop(~req_push),
        .i_logical_tree_id(logical_tree_id),
        .i_push_data(push_data),
        .i_req_order(req_order),
        .i_req_merge_mask(req_merge_mask),
        .o_req_capture_ready(req_capture_ready),
        .o_req_capture_fire(req_capture_fire),
        .o_req_capture_bad_id(),
        .o_dispatch_fire(dispatch_fire),
        .o_dispatch_push(),
        .o_dispatch_logical_tree_id(),
        .o_selected_physical_tree_id(selected_physical_tree_id),
        .o_dispatch_data(),
        .o_dispatch_source_port(),
        .o_dispatch_reject_empty(),
        .o_dispatch_reject_full(),
        .o_logical_pending_count(),
        .o_pending_count(pending_count),
        .o_pending_effective_free_count(),
        .o_busy(busy),
        .o_pop_valid(pop_valid),
        .o_pop_logical_tree_id(pop_logical_tree_id),
        .o_pop_data(pop_data_out),
        .o_internal_root_pop_valid(),
        .o_internal_root_pop_data(),
        .o_protocol_error(protocol_error),
        .o_task_fifo_full(),
        .o_task_write(),
        .o_task_push(),
        .o_task_pop(),
        .o_shard_list(),
        .o_logical_shard_count(),
        .o_logical_count(logical_count),
        .o_push_rr_ptr(),
        .o_shard_count(shard_count),
        .o_shard_head_rank(shard_head_rank),
        .o_shard_empty(),
        .o_shard_full(),
        .o_shard_head_valid(),
        .o_update_pending(),
        .o_logical_busy(),
        .o_pending_logical_tree_id(),
        .o_pending_push()
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

    task clear_requests;
        integer clear_port;
        begin
            req_valid = {REQUEST_PORTS{1'b0}};
            req_push = {REQUEST_PORTS{1'b0}};
            for (clear_port = 0; clear_port < REQUEST_PORTS;
                 clear_port = clear_port + 1) begin
                logical_tree_id[clear_port] =
                    {LOGICAL_ID_WIDTH{1'b0}};
                push_data[clear_port] = {DATA_WIDTH{1'b1}};
                req_order[clear_port] = 0;
                req_merge_mask[clear_port] =
                    {REQUEST_PORTS{1'b0}};
            end
        end
    endtask

    task wait_for_logical_count;
        input integer logical_id;
        input integer expected_count;
        begin
            watchdog = 0;
            while ((logical_count[logical_id] != expected_count) &&
                   watchdog < 8000) begin
                @(posedge clk);
                watchdog = watchdog + 1;
            end
            check(logical_count[logical_id] == expected_count,
                  "logical count did not reach directed value");
        end
    endtask

    task issue_push;
        input integer logical_id;
        input [DATA_WIDTH-1:0] data_value;
        integer old_count;
        begin
            old_count = logical_count[logical_id];
            @(negedge clk);
            watchdog = 0;
            while (!req_capture_ready[0] && watchdog < 4000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            clear_requests();
            req_valid[0] = 1'b1;
            req_push[0] = 1'b1;
            logical_tree_id[0] = logical_id[LOGICAL_ID_WIDTH-1:0];
            push_data[0] = data_value;
            req_order[0] = order_value;
            order_value = order_value + 1;
            #1;
            check(req_capture_fire[0],
                  "directed Push was not captured");
            @(posedge clk);
            @(negedge clk);
            clear_requests();
            wait_for_logical_count(logical_id, old_count + 1);
        end
    endtask

    task issue_four_pops;
        begin
            @(negedge clk);
            watchdog = 0;
            while ((req_capture_ready != 4'b1111) &&
                   watchdog < 4000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            clear_requests();
            req_valid = 4'b1111;
            req_push = 4'b0000;
            for (port = 0; port < REQUEST_PORTS; port = port + 1) begin
                logical_tree_id[port] =
                    port[LOGICAL_ID_WIDTH-1:0];
                req_order[port] = order_value + port;
            end
            order_value = order_value + REQUEST_PORTS;
            #1;
            check(req_capture_fire == 4'b1111,
                  "four directed Pops were not captured together");
            @(posedge clk);
            @(negedge clk);
            clear_requests();
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (!arst_n) begin
            pop_received = 0;
            pop_seen = {LOGICAL_TREE_NUM{1'b0}};
            max_pop_dispatches_same_cycle = 0;
            max_pop_returns_same_cycle = 0;
        end else begin
            dispatches_this_cycle = 0;
            for (monitor_lane = 0;
                 monitor_lane < LOGICAL_TREE_NUM;
                 monitor_lane = monitor_lane + 1)
                if (dispatch_fire[monitor_lane])
                    dispatches_this_cycle =
                        dispatches_this_cycle + 1;
            if (dispatches_this_cycle >
                max_pop_dispatches_same_cycle)
                max_pop_dispatches_same_cycle =
                    dispatches_this_cycle;
            if (dispatches_this_cycle > 0)
                $display("MULTI_POP_DISPATCH time=%0t count=%0d mask=%b physical=%0d,%0d,%0d,%0d",
                         $time, dispatches_this_cycle, dispatch_fire,
                         selected_physical_tree_id[0],
                         selected_physical_tree_id[1],
                         selected_physical_tree_id[2],
                         selected_physical_tree_id[3]);
            if (dut.GEN_GENERIC_POP_RETURN.pop_fifo_enqueued_count >
                max_pop_returns_same_cycle)
                max_pop_returns_same_cycle =
                    dut.GEN_GENERIC_POP_RETURN.pop_fifo_enqueued_count;
            if (dut.GEN_GENERIC_POP_RETURN.pop_fifo_enqueued_count > 0)
                $display("MULTI_POP_RETURN time=%0t count=%0d mask=%b tree=%0d,%0d,%0d,%0d",
                         $time,
                         dut.GEN_GENERIC_POP_RETURN.pop_fifo_enqueued_count,
                         dut.pop_fifo_enqueue_valid,
                         dut.engine_tree_id[0], dut.engine_tree_id[1],
                         dut.engine_tree_id[2], dut.engine_tree_id[3]);
            if (pop_valid) begin
                pop_received = pop_received + 1;
                check(pop_logical_tree_id < LOGICAL_TREE_NUM,
                      "Pop result logical ID out of range");
                if (pop_logical_tree_id < LOGICAL_TREE_NUM) begin
                    check(!pop_seen[pop_logical_tree_id],
                          "logical returned more than once");
                    check(pop_data_out ==
                          expected_pop_data[pop_logical_tree_id],
                          "four-lane Pop result data mismatch");
                    pop_seen[pop_logical_tree_id] = 1'b1;
                end
            end
        end
    end

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        failures = 0;
        order_value = 1;
        pop_received = 0;
        pop_seen = 0;
        max_pop_dispatches_same_cycle = 0;
        max_pop_returns_same_cycle = 0;
        clear_requests();
        for (port = 0; port < LOGICAL_TREE_NUM; port = port + 1)
            expected_pop_data[port] = {DATA_WIDTH{1'b0}};

        repeat (5) @(posedge clk);
        arst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Round-robin logical 0 across physical 0..3.  Its smallest rank is
        // deliberately placed in physical 3 (lane 3).
        issue_push(0, {16'hd000, 16'd100});
        issue_push(0, {16'hd001, 16'd200});
        issue_push(0, {16'hd002, 16'd300});
        issue_push(0, {16'hd003, 16'd4});
        issue_push(1, {16'hd101, 16'd11});
        issue_push(2, {16'hd202, 16'd12});
        issue_push(3, {16'hd303, 16'd13});

        check(shard_count[0] == 1 && shard_count[1] == 1 &&
              shard_count[2] == 1 && shard_count[3] == 1,
              "logical 0 did not populate all four shards");
        check(shard_head_rank[3] == 4,
              "logical 0 minimum was not placed in lane 3");

        expected_pop_data[0] = {16'hd003, 16'd4};
        expected_pop_data[1] = {16'hd101, 16'd11};
        expected_pop_data[2] = {16'hd202, 16'd12};
        expected_pop_data[3] = {16'hd303, 16'd13};
        issue_four_pops();

        watchdog = 0;
        while ((pop_received < 4) && watchdog < 12000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        repeat (2) @(posedge clk);
        check(pop_received == 4 && pop_seen == 4'b1111,
              "four directed Pop results did not all drain");
        check(max_pop_returns_same_cycle >= 2,
              "Engine did not produce a real multi-Pop return cycle");
        check(logical_count[0] == 3 && logical_count[1] == 0 &&
              logical_count[2] == 0 && logical_count[3] == 0,
              "four-lane Pop phase left wrong logical counts");
        check(dut.GEN_GENERIC_POP_RETURN.pop_result_count == 0,
              "PopResultFIFO did not drain four-lane burst");
        check(pending_count == 0 && !busy,
              "four-lane Pop test did not return idle");
        check(!protocol_error,
              "four-lane Pop test raised protocol error");

        $display("Multi-Pop stats: max_pop_dispatches_same_cycle=%0d max_pop_returns_same_cycle=%0d pop_results=%0d seen=%b",
                 max_pop_dispatches_same_cycle,
                 max_pop_returns_same_cycle, pop_received, pop_seen);
        if (failures == 0)
            $display("PASS: HeterogeneousPIFO_multi_pop_tb");
        else
            $fatal(1, "HeterogeneousPIFO_multi_pop_tb failures=%0d",
                   failures);
        $finish;
    end
endmodule
