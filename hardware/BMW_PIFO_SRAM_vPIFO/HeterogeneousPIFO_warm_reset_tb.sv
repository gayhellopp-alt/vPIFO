`timescale 1ns / 1ps

// Populated warm-reset integration test.  The pre-reset population uses ranks
// smaller than every post-reset rank so any retained BMW node becomes directly
// visible in the first post-reset Pop sequence.
module HeterogeneousPIFO_warm_reset_tb;
    localparam PTW = 16;
    localparam MTW = 16;
    localparam DATA_WIDTH = PTW + MTW;
    localparam LOGICAL_TREE_NUM = 4;
    localparam REQUEST_PORTS = 4;
    localparam LOGICAL_ID_WIDTH = 2;
    localparam PENDING_COUNT_WIDTH = 4;
    localparam OLD_ITEM_COUNT = 8;
    localparam NEW_ITEM_COUNT = 4;

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
    wire [PENDING_COUNT_WIDTH-1:0] pending_count;
    wire busy;
    wire pop_valid;
    wire [LOGICAL_ID_WIDTH-1:0] pop_logical_tree_id;
    wire [DATA_WIDTH-1:0] pop_data_out;
    wire protocol_error;
    wire [7:0] logical_count [0:LOGICAL_TREE_NUM-1];

    reg [DATA_WIDTH-1:0] expected_new_data [0:NEW_ITEM_COUNT-1];
    integer failures;
    integer order_value;
    integer watchdog;
    integer port;
    integer item;
    integer post_reset_pop_count;

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
        .o_dispatch_fire(),
        .o_dispatch_push(),
        .o_dispatch_logical_tree_id(),
        .o_selected_physical_tree_id(),
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
                logical_tree_id[clear_port] = 0;
                push_data[clear_port] = {DATA_WIDTH{1'b1}};
                req_order[clear_port] = 0;
                req_merge_mask[clear_port] = 0;
            end
        end
    endtask

    task issue_request;
        input push_operation;
        input [DATA_WIDTH-1:0] data_value;
        begin
            @(negedge clk);
            watchdog = 0;
            while (!req_capture_ready[0] && watchdog < 4000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            clear_requests();
            req_valid[0] = 1'b1;
            req_push[0] = push_operation;
            logical_tree_id[0] = 1;
            push_data[0] = data_value;
            req_order[0] = order_value;
            order_value = order_value + 1;
            #1;
            check(req_capture_fire[0],
                  "warm-reset directed request was not captured");
            @(posedge clk);
            @(negedge clk);
            clear_requests();
        end
    endtask

    task wait_for_count;
        input integer expected_count;
        begin
            watchdog = 0;
            while ((logical_count[1] != expected_count) &&
                   watchdog < 8000) begin
                @(posedge clk);
                watchdog = watchdog + 1;
            end
            check(logical_count[1] == expected_count,
                  "warm-reset logical count did not reach expected value");
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (!arst_n) begin
            post_reset_pop_count = 0;
        end else if (pop_valid) begin
            check(pop_logical_tree_id == 1,
                  "post-reset Pop returned wrong logical ID");
            if (post_reset_pop_count < NEW_ITEM_COUNT) begin
                if (pop_data_out !=
                    expected_new_data[post_reset_pop_count])
                    $display("WARM_RESET_MISMATCH index=%0d expected=%h actual=%h",
                             post_reset_pop_count,
                             expected_new_data[post_reset_pop_count],
                             pop_data_out);
                check(pop_data_out ==
                      expected_new_data[post_reset_pop_count],
                      "pre-reset BMW data leaked into post-reset Pop");
            end else begin
                check(1'b0,
                      "more post-reset Pop results than new requests");
            end
            post_reset_pop_count = post_reset_pop_count + 1;
        end
    end

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        failures = 0;
        order_value = 1;
        post_reset_pop_count = 0;
        clear_requests();
        for (item = 0; item < NEW_ITEM_COUNT; item = item + 1)
            expected_new_data[item] =
                {16'hb000 + item[15:0], 16'd100 + item[15:0]};

        repeat (5) @(posedge clk);
        arst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Populate one fixed physical shard with a multi-level old tree.
        for (item = 0; item < OLD_ITEM_COUNT; item = item + 1) begin
            issue_request(1'b1,
                {16'ha000 + item[15:0], 16'd1 + item[15:0]});
            wait_for_count(item + 1);
        end
        check(logical_count[1] == OLD_ITEM_COUNT,
              "pre-reset population did not complete");

        watchdog = 0;
        while (busy && watchdog < 8000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(!busy, "pre-reset population did not quiesce");

        // This is a warm reset: initial RAM initialization does not re-run.
        @(negedge clk);
        arst_n = 1'b0;
        repeat (4) @(posedge clk);
        #1;
        check(logical_count[1] == 0 && pending_count == 0 &&
              !pop_valid,
              "warm reset did not clear visible control state");
        @(negedge clk);
        arst_n = 1'b1;
        repeat (3) @(posedge clk);

        // New ranks are all larger than the old ranks, making any retained
        // pre-reset tree node win immediately if it remains reachable.
        for (item = 0; item < NEW_ITEM_COUNT; item = item + 1) begin
            issue_request(1'b1, expected_new_data[item]);
            wait_for_count(item + 1);
        end

        for (item = 0; item < NEW_ITEM_COUNT; item = item + 1) begin
            issue_request(1'b0, {DATA_WIDTH{1'b1}});
            wait_for_count(NEW_ITEM_COUNT - item - 1);
        end

        watchdog = 0;
        while ((post_reset_pop_count < NEW_ITEM_COUNT) &&
               watchdog < 12000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        repeat (2) @(posedge clk);
        check(post_reset_pop_count == NEW_ITEM_COUNT,
              "post-reset Pop results did not drain");
        check(logical_count[1] == 0 && pending_count == 0 && !busy,
              "post-reset logical/control state did not drain");
        check(!protocol_error,
              "populated warm-reset test raised protocol error");

        $display("Warm-reset stats: old_items=%0d new_items=%0d post_reset_results=%0d",
                 OLD_ITEM_COUNT, NEW_ITEM_COUNT, post_reset_pop_count);
        if (failures == 0)
            $display("PASS: HeterogeneousPIFO_warm_reset_tb");
        else
            $fatal(1, "HeterogeneousPIFO_warm_reset_tb failures=%0d",
                   failures);
        $finish;
    end
endmodule
