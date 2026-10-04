`timescale 1ns / 1ps

module ShapingDueArbiter_tb;
    localparam LOGICAL_TREE_NUM = 3;
    localparam PHYSICAL_TREE_NUM = 6;
    localparam TIME_WIDTH = 16;
    localparam SEQUENCE_WIDTH = 8;
    localparam RANK_WIDTH = TIME_WIDTH + SEQUENCE_WIDTH;
    localparam ISSUE_PORTS = 3;

    reg [TIME_WIDTH-1:0] wall_time;
    reg [LOGICAL_TREE_NUM-1:0] head_valid;
    reg [RANK_WIDTH-1:0] head_rank [0:LOGICAL_TREE_NUM-1];
    reg [2:0] head_physical_id [0:LOGICAL_TREE_NUM-1];
    reg [LOGICAL_TREE_NUM-1:0] logical_busy;
    reg [LOGICAL_TREE_NUM-1:0] logical_pending;
    reg [LOGICAL_TREE_NUM-1:0] reserved;
    reg [LOGICAL_TREE_NUM-1:0] blocked;
    reg global_barrier;
    reg [1:0] issue_limit;
    wire [ISSUE_PORTS-1:0] issue_valid;
    wire [1:0] issue_logical_id [0:ISSUE_PORTS-1];
    wire [2:0] issue_physical_id [0:ISSUE_PORTS-1];
    wire [RANK_WIDTH-1:0] issue_rank [0:ISSUE_PORTS-1];
    wire [1:0] issue_count;

    integer failures;

    ShapingDueArbiter #(
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(PHYSICAL_TREE_NUM),
        .TIME_WIDTH(TIME_WIDTH),
        .SEQUENCE_WIDTH(SEQUENCE_WIDTH),
        .ISSUE_PORTS(ISSUE_PORTS)
    ) dut (
        .i_time(wall_time),
        .i_head_valid(head_valid),
        .i_head_rank(head_rank),
        .i_head_physical_tree_id(head_physical_id),
        .i_logical_busy(logical_busy),
        .i_logical_pending(logical_pending),
        .i_reserved(reserved),
        .i_blocked(blocked),
        .i_global_barrier(global_barrier),
        .i_issue_limit(issue_limit),
        .o_issue_valid(issue_valid),
        .o_issue_logical_tree_id(issue_logical_id),
        .o_issue_physical_tree_id(issue_physical_id),
        .o_issue_rank(issue_rank),
        .o_issue_count(issue_count)
    );

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

    initial begin
        failures = 0;
        wall_time = 16'd20;
        head_valid = 3'b111;
        head_rank[0] = {16'd10, 8'd0};
        head_rank[1] = {16'd11, 8'd1};
        head_rank[2] = {16'd12, 8'd2};
        head_physical_id[0] = 3'd4;
        head_physical_id[1] = 3'd1;
        head_physical_id[2] = 3'd5;
        logical_busy = 3'b000;
        logical_pending = 3'b000;
        reserved = 3'b000;
        blocked = 3'b000;
        global_barrier = 1'b0;
        issue_limit = 2'd3;
        #1;
        check(issue_count == 3 && issue_valid == 3'b111,
              "all stable due heads were not selected");
        check(issue_logical_id[0] == 0 &&
              issue_logical_id[1] == 1 &&
              issue_logical_id[2] == 2,
              "stable heads were not selected in global rank order");

        // The old implementation skipped logical 0 here and selected logical
        // 1.  Strict release order requires a zero-length eligible prefix.
        logical_busy = 3'b001;
        #1;
        check(issue_count == 0 && issue_valid == 0,
              "later head bypassed an older busy head");
        logical_busy = 3'b000;
        logical_pending = 3'b001;
        #1;
        check(issue_count == 0,
              "later head bypassed an older pending head");
        logical_pending = 3'b000;
        blocked = 3'b001;
        #1;
        check(issue_count == 0,
              "later head bypassed an older blocked head");
        blocked = 3'b000;

        // A reserved rank is already in the completion reorder domain, so
        // later heads may safely be issued in parallel with it.
        reserved = 3'b001;
        #1;
        check(issue_count == 2 && issue_logical_id[0] == 1 &&
              issue_logical_id[1] == 2,
              "reserved head did not permit safe following issues");
        reserved = 3'b000;

        global_barrier = 1'b1;
        #1;
        check(issue_count == 0,
              "unknown-head/input barrier did not stop due issues");
        global_barrier = 1'b0;

        wall_time = 16'd9;
        #1;
        check(issue_count == 0,
              "a future global head did not block all later heads");
        wall_time = 16'd20;
        issue_limit = 2'd1;
        #1;
        check(issue_count == 1 && issue_logical_id[0] == 0,
              "issue credit limit did not preserve oldest-first selection");

        if (failures == 0)
            $display("PASS: shaping due-prefix/global-order arbiter test");
        else begin
            $display("FAIL: shaping arbiter failures=%0d", failures);
            $fatal(1);
        end
        $finish;
    end

endmodule
