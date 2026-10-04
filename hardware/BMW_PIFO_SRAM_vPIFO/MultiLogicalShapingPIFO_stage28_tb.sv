`timescale 1ns / 1ps

// Stage-28 compatibility test for the standalone shaping engine.
// Physical heads 0, 2 and 4 create a same-lane arbitration case while three
// logical timer Pops are captured together.  A depth-three ReleaseFIFO then
// proves that the fourth due event cannot be issued without reserved credit.
module MultiLogicalShapingPIFO_stage28_tb;
    localparam TIME_WIDTH = 16;
    localparam SEQUENCE_WIDTH = 8;
    localparam EVENT_DATA_WIDTH = 32;
    localparam EVENT_TABLE_DEPTH = 8;
    localparam RELEASE_FIFO_DEPTH = 3;
    localparam RELEASE_ISSUE_PORTS = 3;
    localparam LEVEL = 4;
    localparam LOGICAL_TREE_NUM = 3;
    localparam PHYSICAL_TREE_NUM = 6;
    localparam SHARD_CAPACITY = 8;
    localparam MAX_SHARDS_PER_LOGICAL = 2;
    localparam LOGICAL_PENDING_DEPTH = 12;
    localparam RANK_WIDTH = TIME_WIDTH + SEQUENCE_WIDTH;
    localparam LOGICAL_ID_WIDTH = 2;
    localparam PHYSICAL_ID_WIDTH = 3;
    localparam SHARD_COUNT_WIDTH = 4;
    localparam TOTAL_COUNT_WIDTH = 6;
    localparam PENDING_COUNT_WIDTH = 4;
    localparam TABLE_COUNT_WIDTH = 4;
    localparam RELEASE_COUNT_WIDTH = 2;
    localparam ISSUE_COUNT_WIDTH = 2;
    localparam integer SHARD_COUNTS [0:LOGICAL_TREE_NUM-1] =
        '{2, 2, 2};
    localparam integer SHARD_OFFSETS [0:LOGICAL_TREE_NUM-1] =
        '{0, 2, 4};

    reg clk;
    reg arst_n;
    reg [TIME_WIDTH-1:0] wall_time;
    reg event_valid;
    wire event_ready;
    reg [LOGICAL_ID_WIDTH-1:0] event_logical_id;
    reg [TIME_WIDTH-1:0] event_release_time;
    reg [EVENT_DATA_WIDTH-1:0] event_data;
    wire release_valid;
    reg release_ready;
    wire [2:0] release_event_id;
    wire [LOGICAL_ID_WIDTH-1:0] release_logical_id;
    wire [TIME_WIDTH-1:0] release_time;
    wire [EVENT_DATA_WIDTH-1:0] release_data;
    wire [LOGICAL_TREE_NUM-1:0] logical_head_valid;
    wire [RANK_WIDTH-1:0]
        logical_head_rank [0:LOGICAL_TREE_NUM-1];
    wire [PHYSICAL_ID_WIDTH-1:0]
        logical_head_physical_id [0:LOGICAL_TREE_NUM-1];
    wire [LOGICAL_TREE_NUM-1:0] release_reserved;
    wire [LOGICAL_TREE_NUM-1:0] completion_valid;
    wire [RELEASE_ISSUE_PORTS-1:0] due_issue_valid;
    wire [RELEASE_ISSUE_PORTS-1:0] due_capture_fire;
    wire [LOGICAL_ID_WIDTH-1:0]
        due_logical_id [0:RELEASE_ISSUE_PORTS-1];
    wire [PHYSICAL_ID_WIDTH-1:0]
        due_physical_id [0:RELEASE_ISSUE_PORTS-1];
    wire [RANK_WIDTH-1:0]
        due_rank [0:RELEASE_ISSUE_PORTS-1];
    wire [ISSUE_COUNT_WIDTH-1:0] due_issue_count;
    wire [LOGICAL_TREE_NUM-1:0] core_dispatch_fire;
    wire [PHYSICAL_ID_WIDTH-1:0]
        selected_physical_id [0:LOGICAL_TREE_NUM-1];
    wire [PENDING_COUNT_WIDTH-1:0]
        logical_pending_count [0:LOGICAL_TREE_NUM-1];
    wire [TOTAL_COUNT_WIDTH-1:0]
        logical_count [0:LOGICAL_TREE_NUM-1];
    wire [SHARD_COUNT_WIDTH-1:0]
        shard_count [0:PHYSICAL_TREE_NUM-1];
    wire [RANK_WIDTH-1:0]
        shard_head_rank [0:PHYSICAL_TREE_NUM-1];
    wire shard_head_valid [0:PHYSICAL_TREE_NUM-1];
    wire shard_update_pending [0:PHYSICAL_TREE_NUM-1];
    wire [TABLE_COUNT_WIDTH-1:0] event_table_count;
    wire [RELEASE_COUNT_WIDTH-1:0] release_fifo_count;
    wire busy;
    wire protocol_error;

    integer failures;
    integer watchdog;
    integer release_seen;
    integer capture_count_this_cycle;
    integer max_due_captures_same_cycle;
    integer issue_index;
    integer logical_index;

    MultiLogicalShapingPIFO #(
        .TIME_WIDTH(TIME_WIDTH),
        .SEQUENCE_WIDTH(SEQUENCE_WIDTH),
        .EVENT_DATA_WIDTH(EVENT_DATA_WIDTH),
        .EVENT_TABLE_DEPTH(EVENT_TABLE_DEPTH),
        .RELEASE_FIFO_DEPTH(RELEASE_FIFO_DEPTH),
        .RELEASE_ISSUE_PORTS(RELEASE_ISSUE_PORTS),
        .LEVEL(LEVEL),
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(PHYSICAL_TREE_NUM),
        .SHARD_CAPACITY(SHARD_CAPACITY),
        .MAX_SHARDS_PER_LOGICAL(MAX_SHARDS_PER_LOGICAL),
        .FIFO_SIZE(8),
        .LOGICAL_PENDING_DEPTH(LOGICAL_PENDING_DEPTH),
        .SHARD_COUNTS(SHARD_COUNTS),
        .SHARD_OFFSETS(SHARD_OFFSETS)
    ) dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_time(wall_time),
        .i_event_valid(event_valid),
        .o_event_ready(event_ready),
        .i_event_logical_tree_id(event_logical_id),
        .i_event_release_time(event_release_time),
        .i_event_data(event_data),
        .o_release_valid(release_valid),
        .i_release_ready(release_ready),
        .o_release_event_id(release_event_id),
        .o_release_logical_tree_id(release_logical_id),
        .o_release_time(release_time),
        .o_release_data(release_data),
        .o_logical_head_valid(logical_head_valid),
        .o_logical_head_rank(logical_head_rank),
        .o_logical_head_physical_tree_id(logical_head_physical_id),
        .o_release_reserved(release_reserved),
        .o_completion_valid(completion_valid),
        .o_due_issue_valid(due_issue_valid),
        .o_due_capture_fire(due_capture_fire),
        .o_due_issue_logical_tree_id(due_logical_id),
        .o_due_issue_physical_tree_id(due_physical_id),
        .o_due_issue_rank(due_rank),
        .o_due_issue_count(due_issue_count),
        .o_core_dispatch_fire(core_dispatch_fire),
        .o_core_selected_physical_tree_id(selected_physical_id),
        .o_logical_pending_count(logical_pending_count),
        .o_logical_count(logical_count),
        .o_shard_count(shard_count),
        .o_shard_head_rank(shard_head_rank),
        .o_shard_head_valid(shard_head_valid),
        .o_shard_update_pending(shard_update_pending),
        .o_event_table_count(event_table_count),
        .o_release_fifo_count(release_fifo_count),
        .o_busy(busy),
        .o_protocol_error(protocol_error)
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

    task issue_event;
        input integer logical_id;
        input integer release_value;
        input [EVENT_DATA_WIDTH-1:0] data_value;
        integer old_count;
        begin
            old_count = logical_count[logical_id];
            @(negedge clk);
            event_logical_id = logical_id[LOGICAL_ID_WIDTH-1:0];
            event_release_time = release_value[TIME_WIDTH-1:0];
            event_data = data_value;
            event_valid = 1'b1;
            watchdog = 0;
            while (!event_ready && watchdog < 4000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            check(event_ready, "event input did not become ready");
            @(posedge clk);
            @(negedge clk);
            event_valid = 1'b0;
            event_logical_id = {LOGICAL_ID_WIDTH{1'b0}};
            event_release_time = {TIME_WIDTH{1'b0}};
            event_data = {EVENT_DATA_WIDTH{1'b0}};
            watchdog = 0;
            while ((logical_count[logical_id] != old_count + 1) &&
                   watchdog < 8000) begin
                @(posedge clk);
                watchdog = watchdog + 1;
            end
            check(logical_count[logical_id] == old_count + 1,
                  "shaping logical count did not increment");
        end
    endtask

    always @(posedge clk) begin
        if (arst_n) begin
            capture_count_this_cycle = 0;
            for (issue_index = 0;
                 issue_index < RELEASE_ISSUE_PORTS;
                 issue_index = issue_index + 1)
                if (due_capture_fire[issue_index])
                    capture_count_this_cycle =
                        capture_count_this_cycle + 1;
            if (capture_count_this_cycle >
                max_due_captures_same_cycle)
                max_due_captures_same_cycle =
                    capture_count_this_cycle;

            if (release_valid && (wall_time < release_time)) begin
                $display("FAIL: early release at time %0t", $time);
                failures = failures + 1;
            end
        end
    end

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        wall_time = 16'd0;
        event_valid = 1'b0;
        event_logical_id = 0;
        event_release_time = 0;
        event_data = 0;
        release_ready = 1'b0;
        failures = 0;
        watchdog = 0;
        release_seen = 0;
        max_due_captures_same_cycle = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        arst_n = 1'b1;

        // Sequence order is A, B, C, D.  D is the second logical-0 Push and
        // therefore goes to physical shard 1 rather than shard 0.
        issue_event(0, 50, 32'hA000_0001);
        issue_event(1, 50, 32'hB000_0002);
        issue_event(2, 50, 32'hC000_0003);
        issue_event(0, 50, 32'hD000_0004);
        check(event_table_count == 4,
              "event table did not retain four shaping payloads");
        check(shard_count[0] == 1 && shard_count[1] == 1 &&
              shard_count[2] == 1 && shard_count[4] == 1,
              "events did not span the intended heterogeneous shards");

        @(negedge clk);
        wall_time = 16'd49;
        repeat (40) @(posedge clk);
        check(release_fifo_count == 0,
              "not-yet-due event entered ReleaseFIFO");
        check(release_reserved == 0,
              "not-yet-due event reserved release credit");

        @(negedge clk);
        wall_time = 16'd50;
        watchdog = 0;
        while ((release_fifo_count != RELEASE_FIFO_DEPTH) &&
               watchdog < 16000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(release_fifo_count == RELEASE_FIFO_DEPTH,
              "ReleaseFIFO did not fill to its reserved-credit limit");
        check(event_table_count == 4,
              "payload was freed before parent accepted a release");
        check(release_valid && (release_event_id == 0) &&
              (release_logical_id == 0) &&
              (release_time == 50) &&
              (release_data == 32'hA000_0001),
              "blocked ReleaseFIFO head did not expose EventTable payload");
        repeat (4) begin
            @(posedge clk);
            #1;
            check(release_valid && (release_event_id == 0) &&
                  (release_logical_id == 0) &&
                  (release_time == 50) &&
                  (release_data == 32'hA000_0001) &&
                  (event_table_count == 4),
                  "blocked table-backed release head was not stable");
        end
        check(logical_count[0] == 1,
              "fourth due event issued without ReleaseFIFO credit");
        check(max_due_captures_same_cycle == 3,
              "three logical due Pops were not captured together");

        @(negedge clk);
        release_ready = 1'b1;
        watchdog = 0;
        while ((release_seen < 4) && watchdog < 20000) begin
            @(posedge clk);
            if (release_valid && release_ready) begin
                case (release_seen)
                    0: check(release_data == 32'hA000_0001,
                             "first equal-time event violated sequence order");
                    1: check(release_data == 32'hB000_0002,
                             "second equal-time event violated sequence order");
                    2: check(release_data == 32'hC000_0003,
                             "third equal-time event violated sequence order");
                    3: check(release_data == 32'hD000_0004,
                             "fourth equal-time event violated sequence order");
                    default: failures = failures + 1;
                endcase
                check(release_time == 50,
                      "released event carried wrong release_time");
                release_seen = release_seen + 1;
            end
            watchdog = watchdog + 1;
        end
        check(release_seen == 4,
              "did not receive every shaping event exactly once");

        @(negedge clk);
        release_ready = 1'b0;
        watchdog = 0;
        while (busy && watchdog < 16000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(!busy, "shaping engine did not quiesce");
        check(event_table_count == 0 && release_fifo_count == 0,
              "event storage or ReleaseFIFO did not drain");
        check(release_reserved == 0 && completion_valid == 0,
              "release reservation/completion state did not drain");
        for (logical_index = 0;
             logical_index < LOGICAL_TREE_NUM;
             logical_index = logical_index + 1) begin
            check(logical_count[logical_index] == 0,
                  "shaping logical count did not return to zero");
            check(logical_pending_count[logical_index] == 0,
                  "shaping logical pending count did not return to zero");
        end
        check(!protocol_error, "shaping protocol_error asserted");

        if (failures == 0) begin
            $display("PASS: Stage28 shaping multi-shard/credit/order test");
            $display("max_due_captures_same_cycle=%0d releases=%0d",
                     max_due_captures_same_cycle, release_seen);
        end else begin
            $display("FAIL: Stage28 shaping test failures=%0d", failures);
            $fatal(1);
        end
        $finish;
    end

endmodule
