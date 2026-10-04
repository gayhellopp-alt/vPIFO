`timescale 1ns / 1ps

// Forces two safe sequence wraps with a four-bit sequence field.  The event
// held at the input during each wrap must remain backpressured until every
// event from the previous epoch has left the shaping domain.
module MultiLogicalShapingPIFO_sequence_wrap_tb;
    localparam TIME_WIDTH = 8;
    localparam SEQUENCE_WIDTH = 4;
    localparam EVENT_DATA_WIDTH = 32;
    localparam EVENT_TABLE_DEPTH = 16;
    localparam RELEASE_FIFO_DEPTH = 4;
    localparam LEVEL = 4;
    localparam LOGICAL_TREE_NUM = 1;
    localparam PHYSICAL_TREE_NUM = 2;
    localparam SHARD_CAPACITY = 8;
    localparam MAX_SHARDS_PER_LOGICAL = 2;
    localparam LOGICAL_PENDING_DEPTH = 10;
    localparam LOGICAL_ID_WIDTH = 1;
    localparam TOTAL_COUNT_WIDTH = 5;
    localparam TABLE_COUNT_WIDTH = 5;
    localparam RELEASE_COUNT_WIDTH = 3;
    localparam integer SHARD_COUNTS [0:LOGICAL_TREE_NUM-1] = '{2};
    localparam integer SHARD_OFFSETS [0:LOGICAL_TREE_NUM-1] = '{0};

    reg clk;
    reg arst_n;
    reg [TIME_WIDTH-1:0] wall_time;
    reg event_valid;
    wire event_ready;
    reg [TIME_WIDTH-1:0] event_release_time;
    reg [EVENT_DATA_WIDTH-1:0] event_data;
    wire release_valid;
    reg release_ready;
    wire [TIME_WIDTH-1:0] release_time;
    wire [EVENT_DATA_WIDTH-1:0] release_data;
    wire [TOTAL_COUNT_WIDTH-1:0] logical_count [0:0];
    wire [TABLE_COUNT_WIDTH-1:0] event_table_count;
    wire [RELEASE_COUNT_WIDTH-1:0] release_fifo_count;
    wire busy;
    wire protocol_error;

    integer failures;
    integer watchdog;
    integer accepted_count;
    integer released_count;
    integer index;

    MultiLogicalShapingPIFO #(
        .TIME_WIDTH(TIME_WIDTH),
        .SEQUENCE_WIDTH(SEQUENCE_WIDTH),
        .SAFE_SEQUENCE_WRAP(1),
        .EVENT_DATA_WIDTH(EVENT_DATA_WIDTH),
        .EVENT_TABLE_DEPTH(EVENT_TABLE_DEPTH),
        .RELEASE_FIFO_DEPTH(RELEASE_FIFO_DEPTH),
        .RELEASE_ISSUE_PORTS(1),
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
        .i_event_logical_tree_id(1'b0),
        .i_event_release_time(event_release_time),
        .i_event_data(event_data),
        .o_release_valid(release_valid),
        .i_release_ready(release_ready),
        .o_release_event_id(),
        .o_release_logical_tree_id(),
        .o_release_time(release_time),
        .o_release_data(release_data),
        .o_logical_head_valid(),
        .o_logical_head_rank(),
        .o_logical_head_physical_tree_id(),
        .o_release_reserved(),
        .o_completion_valid(),
        .o_due_issue_valid(),
        .o_due_capture_fire(),
        .o_due_issue_logical_tree_id(),
        .o_due_issue_physical_tree_id(),
        .o_due_issue_rank(),
        .o_due_issue_count(),
        .o_core_dispatch_fire(),
        .o_core_selected_physical_tree_id(),
        .o_logical_pending_count(),
        .o_logical_count(logical_count),
        .o_shard_count(),
        .o_shard_head_rank(),
        .o_shard_head_valid(),
        .o_shard_update_pending(),
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
        input [TIME_WIDTH-1:0] release_value;
        input [EVENT_DATA_WIDTH-1:0] data_value;
        integer old_count;
        begin
            old_count = logical_count[0];
            @(negedge clk);
            event_release_time = release_value;
            event_data = data_value;
            event_valid = 1'b1;
            watchdog = 0;
            while (!event_ready && watchdog < 8000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            check(event_ready, "event input did not become ready");
            @(posedge clk);
            @(negedge clk);
            event_valid = 1'b0;
            event_release_time = {TIME_WIDTH{1'b0}};
            event_data = {EVENT_DATA_WIDTH{1'b0}};
            watchdog = 0;
            while ((logical_count[0] != old_count + 1) &&
                   watchdog < 8000) begin
                @(posedge clk);
                watchdog = watchdog + 1;
            end
            check(logical_count[0] == old_count + 1,
                  "logical count did not increment after event capture");
        end
    endtask

    task hold_event_through_barrier;
        input [TIME_WIDTH-1:0] release_value;
        input [EVENT_DATA_WIDTH-1:0] data_value;
        begin
            @(negedge clk);
            event_release_time = release_value;
            event_data = data_value;
            event_valid = 1'b1;
            watchdog = 0;
            while (!event_ready && watchdog < 30000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            check(event_ready,
                  "held event did not become ready after epoch drain");
            @(posedge clk);
            @(negedge clk);
            event_valid = 1'b0;
            event_release_time = {TIME_WIDTH{1'b0}};
            event_data = {EVENT_DATA_WIDTH{1'b0}};
        end
    endtask

    always @(posedge clk) begin
        if (arst_n) begin
            if (event_valid && event_ready)
                accepted_count = accepted_count + 1;

            if (release_valid && release_ready) begin
                if (wall_time < release_time) begin
                    $display("FAIL: early release at time %0t", $time);
                    failures = failures + 1;
                end
                if (released_count < 16) begin
                    if ((release_data != (32'hA000_0000 + released_count)) ||
                        (release_time != 8'd50)) begin
                        $display("FAIL: epoch-A order/data mismatch index=%0d data=%h time=%0d",
                                 released_count, release_data, release_time);
                        failures = failures + 1;
                    end
                end else if (released_count < 32) begin
                    if ((release_data !=
                         (32'hB000_0000 + (released_count - 16))) ||
                        (release_time != 8'd100)) begin
                        $display("FAIL: epoch-B order/data mismatch index=%0d data=%h time=%0d",
                                 released_count - 16, release_data, release_time);
                        failures = failures + 1;
                    end
                end else if ((release_data != 32'hC000_0000) ||
                             (release_time != 8'd150)) begin
                    $display("FAIL: post-wrap event mismatch data=%h time=%0d",
                             release_data, release_time);
                    failures = failures + 1;
                end
                released_count = released_count + 1;
            end
        end
    end

    // The safety invariant under test: no input can be accepted while the old
    // sequence epoch is still live, even after physical capacity becomes free.
    always @(negedge clk) begin
        if (arst_n && dut.sequence_wrap_pending && event_ready) begin
            $display("FAIL: event_ready asserted during sequence drain barrier");
            failures = failures + 1;
        end
        if (arst_n && dut.sequence_wrap_pending && !busy) begin
            $display("FAIL: busy deasserted during sequence drain barrier");
            failures = failures + 1;
        end
    end

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        wall_time = 0;
        event_valid = 1'b0;
        event_release_time = 0;
        event_data = 0;
        release_ready = 1'b0;
        failures = 0;
        watchdog = 0;
        accepted_count = 0;
        released_count = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        arst_n = 1'b1;

        // Fill sequence values 0..15 with equal-time events.
        for (index = 0; index < 16; index = index + 1)
            issue_event(8'd50, 32'hA000_0000 + index);

        check(dut.sequence_wrap_pending,
              "first maximum sequence did not arm drain barrier");
        check(dut.sequence_counter == 4'hf,
              "sequence counter did not hold at maximum during drain");
        check(!event_ready, "event input was not blocked at first wrap");

        // Hold the first event of the next epoch continuously at the input.
        @(negedge clk);
        wall_time = 8'd50;
        watchdog = 0;
        while ((release_fifo_count != RELEASE_FIFO_DEPTH) &&
               watchdog < 16000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(release_fifo_count == RELEASE_FIFO_DEPTH,
              "ReleaseFIFO did not fill during first wrap barrier");
        repeat (4) begin
            @(negedge clk);
            check(dut.sequence_wrap_pending && !event_ready,
                  "first wrap barrier did not survive output backpressure");
        end
        release_ready = 1'b1;
        hold_event_through_barrier(8'd100, 32'hB000_0000);
        check(released_count == 16,
              "first sequence epoch did not release exactly once");
        check(accepted_count == 17,
              "held event was not accepted after first epoch drained");
        release_ready = 1'b0;

        // B0 used sequence zero after the first wrap.  Fill B1..B15 to force
        // a second wrap and repeat the continuously-valid admission check.
        for (index = 1; index < 16; index = index + 1)
            issue_event(8'd100, 32'hB000_0000 + index);

        check(dut.sequence_wrap_pending,
              "second maximum sequence did not arm drain barrier");
        check(dut.sequence_counter == 4'hf,
              "sequence counter did not hold at second maximum");
        check(!event_ready, "event input was not blocked at second wrap");

        @(negedge clk);
        wall_time = 8'd100;
        watchdog = 0;
        while ((release_fifo_count != RELEASE_FIFO_DEPTH) &&
               watchdog < 16000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(release_fifo_count == RELEASE_FIFO_DEPTH,
              "ReleaseFIFO did not fill during second wrap barrier");
        repeat (4) begin
            @(negedge clk);
            check(dut.sequence_wrap_pending && !event_ready,
                  "second wrap barrier did not survive output backpressure");
        end
        release_ready = 1'b1;
        hold_event_through_barrier(8'd150, 32'hC000_0000);
        check(released_count == 32,
              "second sequence epoch did not release exactly once");
        check(accepted_count == 33,
              "held event was not accepted after second epoch drained");
        wall_time = 8'd150;

        watchdog = 0;
        while ((released_count < 33) && watchdog < 16000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(released_count == 33,
              "post-second-wrap event was not released");

        watchdog = 0;
        while ((busy || dut.sequence_wrap_pending) && watchdog < 16000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(!busy, "shaping engine did not quiesce");
        check(!dut.sequence_wrap_pending,
              "sequence drain barrier did not clear after final drain");
        check(event_table_count == 0 && release_fifo_count == 0 &&
              logical_count[0] == 0,
              "shaping storage did not return to zero");
        check(!protocol_error, "shaping protocol_error asserted");

        if (failures == 0) begin
            $display("PASS: safe sequence wrap/drain test");
            $display("accepted=%0d released=%0d wraps=2",
                     accepted_count, released_count);
        end else begin
            $display("FAIL: sequence wrap test failures=%0d", failures);
            $fatal(1);
        end
        $finish;
    end
endmodule
