`timescale 1ns / 1ps

// Full-capacity regression for one generated heterogeneous configuration.
// Experiment-only control dimensions are intentionally fixed so LEVEL changes
// only the BMW physical geometry and the number of Engine return lanes.
module GeneratedHeterogeneousCapacity_tb;
    localparam integer PTW = 16;
    localparam integer MTW = 16;
    localparam integer DATA_WIDTH = PTW + MTW;
    localparam integer LEVEL = VpifoConfigPkg::LEVEL;
    localparam integer LOGICAL_TREE_NUM = VpifoConfigPkg::LOGICAL_TREE_NUM;
    localparam integer PHYSICAL_TREE_NUM = VpifoConfigPkg::PHYSICAL_TREE_NUM;
    localparam integer SHARD_CAPACITY = VpifoConfigPkg::SHARD_CAPACITY;
    localparam integer MAX_SHARDS_PER_LOGICAL =
        VpifoConfigPkg::MAX_SHARDS_PER_LOGICAL;
    localparam integer REQUEST_PORTS = 4;
    localparam integer LOGICAL_PENDING_DEPTH = 12;
    localparam integer POP_RESULT_FIFO_DEPTH = 10;
    localparam integer LOGICAL_ID_WIDTH = VpifoConfigPkg::LOGICAL_ID_WIDTH;
    localparam integer PHYSICAL_ID_WIDTH = VpifoConfigPkg::PHYSICAL_ID_WIDTH;
    localparam integer SHARD_COUNT_WIDTH =
        (SHARD_CAPACITY <= 1) ? 1 : $clog2(SHARD_CAPACITY + 1);
    localparam integer TOTAL_COUNT_WIDTH =
        (PHYSICAL_TREE_NUM * SHARD_CAPACITY <= 1) ? 1 :
        $clog2(PHYSICAL_TREE_NUM * SHARD_CAPACITY + 1);
    localparam integer SHARD_LIST_COUNT_WIDTH =
        (MAX_SHARDS_PER_LOGICAL <= 1) ? 1 :
        $clog2(MAX_SHARDS_PER_LOGICAL + 1);
    localparam integer PENDING_COUNT_WIDTH =
        $clog2(LOGICAL_PENDING_DEPTH + 1);

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
    wire [PENDING_COUNT_WIDTH-1:0] pending_count;
    wire busy;
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
    wire [SHARD_COUNT_WIDTH-1:0]
        shard_count [0:PHYSICAL_TREE_NUM-1];
    wire shard_full [0:PHYSICAL_TREE_NUM-1];
    wire update_pending [0:PHYSICAL_TREE_NUM-1];
    wire logical_busy [0:LOGICAL_TREE_NUM-1];

    integer failures;
    integer order_value;
    integer logical_index;
    integer physical_index;
    integer shard_index;
    integer rank_value;
    integer expected_count;
    integer target_capacity;
    integer watchdog;

    HeterogeneousPIFO #(
        .REQUEST_PORTS(REQUEST_PORTS),
        .LOGICAL_PENDING_DEPTH(LOGICAL_PENDING_DEPTH),
        .POP_RESULT_FIFO_DEPTH(POP_RESULT_FIFO_DEPTH)
    ) dut (
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
        .o_pending_count(pending_count),
        .o_busy(busy),
        .o_pop_valid(pop_valid),
        .o_pop_logical_tree_id(pop_logical_tree_id),
        .o_pop_data(pop_data_out),
        .o_protocol_error(protocol_error),
        .o_shard_list(shard_list),
        .o_logical_shard_count(logical_shard_count),
        .o_logical_count(logical_count),
        .o_shard_count(shard_count),
        .o_shard_full(shard_full),
        .o_update_pending(update_pending),
        .o_logical_busy(logical_busy)
    );

    always #5 clk = ~clk;

    function automatic [DATA_WIDTH-1:0] expected_word;
        input integer requested_logical;
        input integer requested_rank;
        reg [15:0] metadata;
        reg [15:0] rank;
        begin
            rank = requested_rank[15:0];
            metadata = 16'h4000 + (requested_logical * 16'h1000) + rank;
            expected_word = {metadata, rank};
        end
    endfunction

    task automatic clear_requests;
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

    task automatic check;
        input condition;
        input [8*200-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                failures = failures + 1;
            end
        end
    endtask

    task automatic issue_request;
        input integer requested_logical;
        input push_operation;
        input [DATA_WIDTH-1:0] data_value;
        integer capture_watchdog;
        begin
            @(negedge clk);
            capture_watchdog = 0;
            while (!req_capture_ready[0] && capture_watchdog < 20000) begin
                @(negedge clk);
                capture_watchdog = capture_watchdog + 1;
            end
            if (!req_capture_ready[0])
                $fatal(1, "timeout waiting for request capture readiness");
            clear_requests();
            req_valid[0] = 1'b1;
            req_push[0] = push_operation;
            logical_tree_id[0] =
                requested_logical[LOGICAL_ID_WIDTH-1:0];
            push_data[0] = data_value;
            req_order[0] = order_value;
            order_value = order_value + 1;
            #1;
            check(req_capture_fire[0], "request was not captured");
            check(!req_capture_bad_id[0], "valid logical ID was rejected");
            @(posedge clk);
            @(negedge clk);
            clear_requests();
        end
    endtask

    task automatic wait_for_count;
        input integer requested_logical;
        input integer requested_count;
        integer count_watchdog;
        begin
            count_watchdog = 0;
            while ((logical_count[requested_logical] != requested_count) &&
                   count_watchdog < 20000) begin
                @(negedge clk);
                count_watchdog = count_watchdog + 1;
            end
            if (logical_count[requested_logical] != requested_count)
                $fatal(1,
                       "logical %0d count timeout: expected=%0d actual=%0d",
                       requested_logical, requested_count,
                       logical_count[requested_logical]);
        end
    endtask

    task automatic wait_for_pop;
        input integer requested_logical;
        input [DATA_WIDTH-1:0] requested_data;
        integer pop_watchdog;
        begin
            pop_watchdog = 0;
            while (!pop_valid && pop_watchdog < 20000) begin
                @(negedge clk);
                pop_watchdog = pop_watchdog + 1;
            end
            if (!pop_valid)
                $fatal(1, "logical %0d Pop timed out", requested_logical);
            check(pop_logical_tree_id == requested_logical,
                  "Pop returned the wrong logical ID");
            check(pop_data_out == requested_data,
                  "Pop returned data out of rank order or with bad metadata");
        end
    endtask

    initial begin
        if (LOGICAL_TREE_NUM != 4)
            $fatal(1, "capacity matrix requires exactly four logical PIFOs");
        if ((LEVEL < 4) || (LEVEL > 6))
            $fatal(1, "capacity matrix requires LEVEL 4, 5, or 6");

        clk = 1'b0;
        arst_n = 1'b0;
        failures = 0;
        order_value = 1;
        clear_requests();
        repeat (4) @(posedge clk);
        arst_n = 1'b1;
        repeat (3) @(posedge clk);

        for (logical_index = 0; logical_index < LOGICAL_TREE_NUM;
             logical_index = logical_index + 1) begin
            check(logical_shard_count[logical_index] ==
                      VpifoConfigPkg::SHARD_COUNTS[logical_index],
                  "Directory shard count differs from generated layout");
            for (shard_index = 0;
                 shard_index < VpifoConfigPkg::SHARD_COUNTS[logical_index];
                 shard_index = shard_index + 1) begin
                check(shard_list[logical_index][shard_index] ==
                          VpifoConfigPkg::SHARD_OFFSETS[logical_index] +
                          shard_index,
                      "Directory shard list differs from generated layout");
            end
        end

        // Descending insertion makes each drain prove global cross-shard
        // minimum selection rather than merely preserving insertion order.
        for (logical_index = 0; logical_index < LOGICAL_TREE_NUM;
             logical_index = logical_index + 1) begin
            target_capacity = VpifoConfigPkg::REQUIRED_CAPACITY[logical_index];
            expected_count = 0;
            for (rank_value = target_capacity; rank_value >= 1;
                 rank_value = rank_value - 1) begin
                issue_request(logical_index, 1'b1,
                              expected_word(logical_index, rank_value));
                expected_count = expected_count + 1;
                wait_for_count(logical_index, expected_count);
            end
        end

        for (physical_index = 0; physical_index < PHYSICAL_TREE_NUM;
             physical_index = physical_index + 1) begin
            check(shard_count[physical_index] == SHARD_CAPACITY,
                  "full-capacity fill did not fill every physical shard");
            check(shard_full[physical_index],
                  "full-capacity shard did not assert full");
        end

        for (logical_index = 0; logical_index < LOGICAL_TREE_NUM;
             logical_index = logical_index + 1) begin
            target_capacity = VpifoConfigPkg::REQUIRED_CAPACITY[logical_index];
            expected_count = target_capacity;
            for (rank_value = 1; rank_value <= target_capacity;
                 rank_value = rank_value + 1) begin
                issue_request(logical_index, 1'b0, '1);
                wait_for_pop(logical_index,
                             expected_word(logical_index, rank_value));
                expected_count = expected_count - 1;
                wait_for_count(logical_index, expected_count);
            end
        end

        watchdog = 0;
        while (busy && watchdog < 20000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        check(!busy, "HeterogeneousPIFO remained busy after full drain");
        check(pending_count == 0, "request buffer was not empty after full drain");
        for (logical_index = 0; logical_index < LOGICAL_TREE_NUM;
             logical_index = logical_index + 1) begin
            check(logical_count[logical_index] == 0,
                  "logical count was non-zero after full drain");
            check(!logical_busy[logical_index],
                  "logical busy was set after full drain");
        end
        for (physical_index = 0; physical_index < PHYSICAL_TREE_NUM;
             physical_index = physical_index + 1) begin
            check(shard_count[physical_index] == 0,
                  "physical shard count was non-zero after full drain");
            check(!update_pending[physical_index],
                  "physical update remained pending after full drain");
        end
        check(!protocol_error, "full-capacity regression set protocol_error");

        if (failures == 0)
            $display("PASS: GeneratedHeterogeneousCapacity_tb L=%0d N=%0d operations=%0d",
                     LEVEL, PHYSICAL_TREE_NUM,
                     2 * PHYSICAL_TREE_NUM * SHARD_CAPACITY);
        else
            $fatal(1, "GeneratedHeterogeneousCapacity_tb failures: %0d", failures);
        $finish;
    end
endmodule
