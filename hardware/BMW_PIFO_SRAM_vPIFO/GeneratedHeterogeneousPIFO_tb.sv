`timescale 1ns / 1ps

// Configuration-driven flat-core smoke regression.  Every array dimension,
// ID width, and expected shard range comes from the generated package.
module GeneratedHeterogeneousPIFO_tb;
    localparam PTW = 16;
    localparam MTW = 16;
    localparam DATA_WIDTH = PTW + MTW;
    localparam LEVEL = VpifoConfigPkg::LEVEL;
    localparam LOGICAL_TREE_NUM = VpifoConfigPkg::LOGICAL_TREE_NUM;
    localparam PHYSICAL_TREE_NUM = VpifoConfigPkg::PHYSICAL_TREE_NUM;
    localparam MAX_SHARDS_PER_LOGICAL =
        VpifoConfigPkg::MAX_SHARDS_PER_LOGICAL;
    localparam REQUEST_PORTS = LEVEL;
    localparam LOGICAL_ID_WIDTH = VpifoConfigPkg::LOGICAL_ID_WIDTH;
    localparam PHYSICAL_ID_WIDTH = VpifoConfigPkg::PHYSICAL_ID_WIDTH;
    localparam SHARD_LIST_COUNT_WIDTH =
        (MAX_SHARDS_PER_LOGICAL <= 1) ? 1 :
        $clog2(MAX_SHARDS_PER_LOGICAL + 1);
    localparam TOTAL_COUNT_WIDTH =
        $clog2(PHYSICAL_TREE_NUM * VpifoConfigPkg::SHARD_CAPACITY + 1);

    reg clk;
    reg arst_n;
    reg [REQUEST_PORTS-1:0] req_valid;
    reg [REQUEST_PORTS-1:0] req_push;
    reg [LOGICAL_ID_WIDTH-1:0]
        logical_tree_id [0:REQUEST_PORTS-1];
    reg [DATA_WIDTH-1:0] push_data [0:REQUEST_PORTS-1];
    reg [31:0] req_order [0:REQUEST_PORTS-1];
    reg [REQUEST_PORTS-1:0] req_merge_mask [0:REQUEST_PORTS-1];

    wire [REQUEST_PORTS-1:0] req_capture_ready;
    wire [REQUEST_PORTS-1:0] req_capture_fire;
    wire [REQUEST_PORTS-1:0] req_capture_bad_id;
    wire [LOGICAL_TREE_NUM-1:0] dispatch_fire;
    wire [LOGICAL_TREE_NUM-1:0] dispatch_push;
    wire [PHYSICAL_ID_WIDTH-1:0]
        selected_physical_tree_id [0:LOGICAL_TREE_NUM-1];
    wire [$clog2(REQUEST_PORTS + 8 + 1)-1:0] pending_count;
    wire pop_valid;
    wire [LOGICAL_ID_WIDTH-1:0] pop_logical_tree_id;
    wire [DATA_WIDTH-1:0] pop_data_out;
    wire protocol_error;
    wire [PHYSICAL_ID_WIDTH-1:0]
        shard_list [0:LOGICAL_TREE_NUM-1][0:MAX_SHARDS_PER_LOGICAL-1];
    wire [SHARD_LIST_COUNT_WIDTH-1:0]
        logical_shard_count [0:LOGICAL_TREE_NUM-1];
    wire [TOTAL_COUNT_WIDTH-1:0]
        logical_count [0:LOGICAL_TREE_NUM-1];

    integer failures;
    integer logical_id;
    integer shard_index;
    integer port_index;
    integer watchdog;
    integer order_value;
    reg [DATA_WIDTH-1:0] expected_data [0:LOGICAL_TREE_NUM-1];

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
        .o_req_capture_bad_id(req_capture_bad_id),
        .o_dispatch_fire(dispatch_fire),
        .o_dispatch_push(dispatch_push),
        .o_selected_physical_tree_id(selected_physical_tree_id),
        .o_pending_count(pending_count),
        .o_pop_valid(pop_valid),
        .o_pop_logical_tree_id(pop_logical_tree_id),
        .o_pop_data(pop_data_out),
        .o_protocol_error(protocol_error),
        .o_shard_list(shard_list),
        .o_logical_shard_count(logical_shard_count),
        .o_logical_count(logical_count)
    );

    always #5 clk = ~clk;

    task clear_requests;
        integer port;
        begin
            req_valid = '0;
            req_push = '0;
            for (port = 0; port < REQUEST_PORTS; port = port + 1) begin
                logical_tree_id[port] = '0;
                push_data[port] = '1;
                req_order[port] = '0;
                req_merge_mask[port] = '0;
            end
        end
    endtask

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

    task issue_request;
        input integer requested_logical;
        input push_operation;
        input [DATA_WIDTH-1:0] data_value;
        begin
            @(negedge clk);
            watchdog = 0;
            while (!req_capture_ready[0] && watchdog < 4000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (!req_capture_ready[0])
                $fatal(1, "timeout waiting for generated request capture");
            clear_requests();
            req_valid[0] = 1'b1;
            req_push[0] = push_operation;
            logical_tree_id[0] = requested_logical[LOGICAL_ID_WIDTH-1:0];
            push_data[0] = data_value;
            req_order[0] = order_value;
            order_value = order_value + 1;
            #1;
            check(req_capture_fire[0], "request was not captured");
            check(!req_capture_bad_id[0], "valid generated logical ID rejected");
            @(posedge clk);
            @(negedge clk);
            clear_requests();
        end
    endtask

    task wait_for_count;
        input integer requested_logical;
        input integer expected_count;
        begin
            watchdog = 0;
            while ((logical_count[requested_logical] != expected_count) &&
                   watchdog < 8000) begin
                @(posedge clk);
                watchdog = watchdog + 1;
            end
            check(logical_count[requested_logical] == expected_count,
                  "logical count did not reach expected value");
        end
    endtask

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        failures = 0;
        order_value = 1;
        clear_requests();
        repeat (4) @(posedge clk);
        arst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (logical_id = 0; logical_id < LOGICAL_TREE_NUM;
             logical_id = logical_id + 1) begin
            check(logical_shard_count[logical_id] ==
                      VpifoConfigPkg::SHARD_COUNTS[logical_id],
                  "RTL shard count differs from generated count");
            for (shard_index = 0;
                 shard_index < VpifoConfigPkg::SHARD_COUNTS[logical_id];
                 shard_index = shard_index + 1) begin
                check(shard_list[logical_id][shard_index] ==
                          VpifoConfigPkg::SHARD_OFFSETS[logical_id] + shard_index,
                      "RTL shard list differs from generated continuous layout");
            end
            expected_data[logical_id] =
                {(16'h5000 + logical_id[15:0]),
                 (16'h0100 + logical_id[15:0])};
            issue_request(logical_id, 1'b1, expected_data[logical_id]);
            wait_for_count(logical_id, 1);
        end

        for (logical_id = 0; logical_id < LOGICAL_TREE_NUM;
             logical_id = logical_id + 1) begin
            issue_request(logical_id, 1'b0, '1);
            watchdog = 0;
            while (!pop_valid && watchdog < 8000) begin
                @(posedge clk);
                watchdog = watchdog + 1;
            end
            check(pop_valid, "generated flat-core Pop timed out");
            check(pop_logical_tree_id == logical_id,
                  "generated flat-core Pop returned wrong logical ID");
            check(pop_data_out == expected_data[logical_id],
                  "generated flat-core Pop returned wrong data");
            wait_for_count(logical_id, 0);
        end

        check(!protocol_error, "generated flat-core protocol error");
        if (failures == 0)
            $display("PASS: GeneratedHeterogeneousPIFO_tb logical=%0d physical=%0d",
                     LOGICAL_TREE_NUM, PHYSICAL_TREE_NUM);
        else
            $fatal(1, "GeneratedHeterogeneousPIFO_tb failures: %0d", failures);
        $finish;
    end
endmodule
