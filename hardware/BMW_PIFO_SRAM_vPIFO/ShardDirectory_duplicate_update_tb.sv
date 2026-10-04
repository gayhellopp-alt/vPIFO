`timescale 1ns / 1ps

// Defensive duplicate-update test.  A malformed same-shard update burst must
// set protocol_error and use a deterministic lowest-port winner; a later port
// must not silently overwrite the accepted summary.
module ShardDirectory_duplicate_update_tb;
    localparam LOGICAL_TREE_NUM = 4;
    localparam PHYSICAL_TREE_NUM = 7;
    localparam SHARD_CAPACITY = 30;
    localparam RANK_WIDTH = 16;
    localparam REQUEST_PORTS = 1;
    localparam UPDATE_PORTS = 2;
    localparam LOGICAL_ID_WIDTH = 2;
    localparam PHYSICAL_ID_WIDTH = 3;
    localparam integer SHARD_COUNTS [0:LOGICAL_TREE_NUM-1] =
        '{4, 1, 1, 1};
    localparam integer SHARD_OFFSETS [0:LOGICAL_TREE_NUM-1] =
        '{0, 4, 5, 6};

    reg clk;
    reg arst_n;
    reg [REQUEST_PORTS-1:0] req_valid;
    reg [REQUEST_PORTS-1:0] req_push;
    reg [REQUEST_PORTS-1:0] req_pp;
    reg [LOGICAL_ID_WIDTH-1:0]
        logical_tree_id [0:REQUEST_PORTS-1];
    reg [REQUEST_PORTS-1:0] select_ready;
    wire [REQUEST_PORTS-1:0] select_valid;
    wire [PHYSICAL_ID_WIDTH-1:0]
        physical_tree_id [0:REQUEST_PORTS-1];
    reg [UPDATE_PORTS-1:0] update_valid;
    reg [PHYSICAL_ID_WIDTH-1:0]
        update_physical_tree_id [0:UPDATE_PORTS-1];
    reg [RANK_WIDTH-1:0]
        update_head_rank [0:UPDATE_PORTS-1];

    wire protocol_error;
    wire [7:0] logical_count [0:LOGICAL_TREE_NUM-1];
    wire [4:0] shard_count [0:PHYSICAL_TREE_NUM-1];
    wire [RANK_WIDTH-1:0]
        shard_head_rank [0:PHYSICAL_TREE_NUM-1];
    wire update_pending [0:PHYSICAL_TREE_NUM-1];
    wire logical_busy [0:LOGICAL_TREE_NUM-1];

    integer failures;
    integer port;

    ShardDirectory #(
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(PHYSICAL_TREE_NUM),
        .SHARD_CAPACITY(SHARD_CAPACITY),
        .RANK_WIDTH(RANK_WIDTH),
        .MAX_SHARDS_PER_LOGICAL(4),
        .REQUEST_PORTS(REQUEST_PORTS),
        .UPDATE_PORTS(UPDATE_PORTS),
        .SHARD_COUNTS(SHARD_COUNTS),
        .SHARD_OFFSETS(SHARD_OFFSETS)
    ) dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_req_valid(req_valid),
        .i_req_push(req_push),
        .i_req_pp(req_pp),
        .i_logical_tree_id(logical_tree_id),
        .i_select_ready(select_ready),
        .o_req_ready(),
        .o_select_valid(select_valid),
        .o_select_pp(),
        .o_physical_tree_id(physical_tree_id),
        .o_reject_empty(),
        .o_reject_full(),
        .o_reject_bad_id(),
        .i_update_valid(update_valid),
        .i_update_physical_tree_id(update_physical_tree_id),
        .i_update_head_rank(update_head_rank),
        .o_busy(),
        .o_protocol_error(protocol_error),
        .o_shard_list(),
        .o_logical_shard_count(),
        .o_logical_count(logical_count),
        .o_push_rr_ptr(),
        .o_logical_busy(logical_busy),
        .o_shard_count(shard_count),
        .o_shard_head_rank(shard_head_rank),
        .o_shard_empty(),
        .o_shard_full(),
        .o_shard_head_valid(),
        .o_update_pending(update_pending),
        .o_pending_logical_tree_id(),
        .o_pending_push(),
        .o_pending_pp()
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

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        failures = 0;
        req_valid = 0;
        req_push = 0;
        req_pp = 0;
        select_ready = 0;
        logical_tree_id[0] = 0;
        update_valid = 0;
        for (port = 0; port < UPDATE_PORTS; port = port + 1) begin
            update_physical_tree_id[port] = 0;
            update_head_rank[port] = 0;
        end

        repeat (4) @(posedge clk);
        arst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Create one legitimate pending Push completion for physical shard 0.
        @(negedge clk);
        req_valid[0] = 1'b1;
        req_push[0] = 1'b1;
        select_ready[0] = 1'b1;
        #1;
        check(select_valid[0] && physical_tree_id[0] == 0,
              "duplicate-update setup selected wrong shard");
        @(posedge clk);
        #1;
        @(posedge clk);
        #1;
        @(negedge clk);
        req_valid = 0;
        select_ready = 0;
        check(update_pending[0] && logical_busy[0],
              "duplicate-update setup did not create pending context");

        // Both ports claim the same completion but disagree on the new Head.
        // Lowest update-port index is the deterministic defensive winner.
        update_valid = 2'b11;
        update_physical_tree_id[0] = 0;
        update_physical_tree_id[1] = 0;
        update_head_rank[0] = 16'd111;
        update_head_rank[1] = 16'd222;
        @(posedge clk);
        #1;
        update_valid = 0;

        check(protocol_error,
              "duplicate same-shard update did not set protocol_error");
        check(logical_count[0] == 1 && shard_count[0] == 1,
              "duplicate same-shard update changed count more than once");
        check(!update_pending[0] && !logical_busy[0],
              "accepted duplicate-update winner did not retire context");
        check(shard_head_rank[0] == 16'd111,
              "later duplicate update overwrote lowest-port Head winner");

        $display("Duplicate-update stats: protocol_error=%0d logical_count=%0d shard_count=%0d head=%0d",
                 protocol_error, logical_count[0], shard_count[0],
                 shard_head_rank[0]);
        if (failures == 0)
            $display("PASS: ShardDirectory_duplicate_update_tb");
        else
            $fatal(1,
                   "ShardDirectory_duplicate_update_tb failures=%0d",
                   failures);
        $finish;
    end
endmodule
