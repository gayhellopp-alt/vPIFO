`timescale 1ns / 1ps

module ShardDirectory_tb;
    localparam LOGICAL_TREE_NUM = 4;
    localparam PHYSICAL_TREE_NUM = 7;
    localparam SHARD_CAPACITY = 30;
    localparam RANK_WIDTH = 16;
    localparam REQUEST_PORTS = 4;
    localparam UPDATE_PORTS = 4;
    localparam LOGICAL_ID_WIDTH = 2;
    localparam PHYSICAL_ID_WIDTH = 3;
    localparam integer BASELINE_COUNTS [0:LOGICAL_TREE_NUM-1] =
        '{4, 1, 1, 1};
    localparam integer BASELINE_OFFSETS [0:LOGICAL_TREE_NUM-1] =
        '{0, 4, 5, 6};
    localparam integer ALT_OFFSETS [0:LOGICAL_TREE_NUM-1] =
        '{0, 2, 4, 5};

    reg clk;
    reg arst_n;
    reg [REQUEST_PORTS-1:0] req_valid;
    reg [REQUEST_PORTS-1:0] req_push;
    reg [REQUEST_PORTS-1:0] req_pp;
    reg [LOGICAL_ID_WIDTH-1:0]
        logical_tree_id [0:REQUEST_PORTS-1];
    reg [REQUEST_PORTS-1:0] select_ready;
    wire [REQUEST_PORTS-1:0] req_ready;
    wire [REQUEST_PORTS-1:0] select_valid;
    wire [REQUEST_PORTS-1:0] select_pp;
    wire [PHYSICAL_ID_WIDTH-1:0]
        physical_tree_id [0:REQUEST_PORTS-1];
    wire [REQUEST_PORTS-1:0] reject_empty;
    wire [REQUEST_PORTS-1:0] reject_full;
    wire [REQUEST_PORTS-1:0] reject_bad_id;
    reg [UPDATE_PORTS-1:0] update_valid;
    reg [PHYSICAL_ID_WIDTH-1:0]
        update_physical_tree_id [0:UPDATE_PORTS-1];
    reg [RANK_WIDTH-1:0]
        update_head_rank [0:UPDATE_PORTS-1];
    wire busy;
    wire protocol_error;

    wire [PHYSICAL_ID_WIDTH-1:0]
        shard_list [0:LOGICAL_TREE_NUM-1][0:3];
    wire [2:0] logical_shard_count [0:LOGICAL_TREE_NUM-1];
    wire [7:0] logical_count [0:LOGICAL_TREE_NUM-1];
    wire [1:0] push_rr_ptr [0:LOGICAL_TREE_NUM-1];
    wire [4:0] shard_count [0:PHYSICAL_TREE_NUM-1];
    wire [RANK_WIDTH-1:0]
        shard_head_rank [0:PHYSICAL_TREE_NUM-1];
    wire shard_empty [0:PHYSICAL_TREE_NUM-1];
    wire shard_full [0:PHYSICAL_TREE_NUM-1];
    wire shard_head_valid [0:PHYSICAL_TREE_NUM-1];
    wire update_pending [0:PHYSICAL_TREE_NUM-1];
    wire logical_busy [0:LOGICAL_TREE_NUM-1];
    wire [LOGICAL_ID_WIDTH-1:0]
        pending_logical_tree_id [0:PHYSICAL_TREE_NUM-1];
    wire pending_push [0:PHYSICAL_TREE_NUM-1];
    wire pending_pp [0:PHYSICAL_TREE_NUM-1];

    // An explicit, non-contiguous alternative mapping:
    //   logical 0 -> {2,0}
    //   logical 1 -> {5,1}
    //   logical 2 -> {6}
    //   logical 3 -> {4,3}
    localparam integer ALT_COUNTS [0:LOGICAL_TREE_NUM-1] =
        '{2, 2, 1, 2};
    localparam integer ALT_MAP [0:PHYSICAL_TREE_NUM-1] =
        '{2, 0, 5, 1, 6, 4, 3};
    reg alt_req_valid;
    reg alt_req_push;
    reg alt_req_pp;
    reg [LOGICAL_ID_WIDTH-1:0]
        alt_logical_tree_id [0:0];
    reg alt_select_ready;
    wire alt_req_ready;
    wire alt_select_valid;
    wire alt_select_pp;
    wire [PHYSICAL_ID_WIDTH-1:0]
        alt_physical_tree_id [0:0];
    reg alt_update_valid;
    reg [PHYSICAL_ID_WIDTH-1:0]
        alt_update_physical_tree_id [0:0];
    reg [RANK_WIDTH-1:0] alt_update_head_rank [0:0];
    wire [PHYSICAL_ID_WIDTH-1:0]
        alt_shard_list [0:LOGICAL_TREE_NUM-1][0:3];
    wire [2:0] alt_logical_shard_count [0:LOGICAL_TREE_NUM-1];
    wire alt_protocol_error;
    wire [2:0] alt_logical_count [0:LOGICAL_TREE_NUM-1];
    wire alt_shard_count [0:PHYSICAL_TREE_NUM-1];
    wire [RANK_WIDTH-1:0]
        alt_shard_head_rank [0:PHYSICAL_TREE_NUM-1];
    wire alt_shard_empty [0:PHYSICAL_TREE_NUM-1];
    wire alt_shard_full [0:PHYSICAL_TREE_NUM-1];

    integer failures;
    integer i;

    ShardDirectory #(
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(PHYSICAL_TREE_NUM),
        .SHARD_CAPACITY(SHARD_CAPACITY),
        .MAX_SHARDS_PER_LOGICAL(4),
        .REQUEST_PORTS(REQUEST_PORTS),
        .UPDATE_PORTS(UPDATE_PORTS),
        .SHARD_COUNTS(BASELINE_COUNTS),
        .SHARD_OFFSETS(BASELINE_OFFSETS)
    ) dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_req_valid(req_valid),
        .i_req_push(req_push),
        .i_req_pp(req_pp),
        .i_logical_tree_id(logical_tree_id),
        .i_select_ready(select_ready),
        .o_req_ready(req_ready),
        .o_select_valid(select_valid),
        .o_select_pp(select_pp),
        .o_physical_tree_id(physical_tree_id),
        .o_reject_empty(reject_empty),
        .o_reject_full(reject_full),
        .o_reject_bad_id(reject_bad_id),
        .i_update_valid(update_valid),
        .i_update_physical_tree_id(update_physical_tree_id),
        .i_update_head_rank(update_head_rank),
        .o_busy(busy),
        .o_protocol_error(protocol_error),
        .o_shard_list(shard_list),
        .o_logical_shard_count(logical_shard_count),
        .o_logical_count(logical_count),
        .o_push_rr_ptr(push_rr_ptr),
        .o_logical_busy(logical_busy),
        .o_shard_count(shard_count),
        .o_shard_head_rank(shard_head_rank),
        .o_shard_empty(shard_empty),
        .o_shard_full(shard_full),
        .o_shard_head_valid(shard_head_valid),
        .o_update_pending(update_pending),
        .o_pending_logical_tree_id(
            pending_logical_tree_id),
        .o_pending_push(pending_push),
        .o_pending_pp(pending_pp)
    );

    ShardDirectory #(
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(PHYSICAL_TREE_NUM),
        .MAX_SHARDS_PER_LOGICAL(4),
        .REQUEST_PORTS(1),
        .UPDATE_PORTS(1),
        .SHARD_CAPACITY(1),
        .USE_EXPLICIT_SHARD_MAP(1),
        .SHARD_COUNTS(ALT_COUNTS),
        .SHARD_OFFSETS(ALT_OFFSETS),
        .EXPLICIT_SHARD_MAP(ALT_MAP)
    ) alt_dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_req_valid(alt_req_valid),
        .i_req_push(alt_req_push),
        .i_req_pp(alt_req_pp),
        .i_logical_tree_id(alt_logical_tree_id),
        .i_select_ready(alt_select_ready),
        .o_req_ready(alt_req_ready),
        .o_select_valid(alt_select_valid),
        .o_select_pp(alt_select_pp),
        .o_physical_tree_id(alt_physical_tree_id),
        .o_reject_empty(),
        .o_reject_full(),
        .o_reject_bad_id(),
        .i_update_valid(alt_update_valid),
        .i_update_physical_tree_id(
            alt_update_physical_tree_id),
        .i_update_head_rank(alt_update_head_rank),
        .o_busy(),
        .o_protocol_error(alt_protocol_error),
        .o_shard_list(alt_shard_list),
        .o_logical_shard_count(alt_logical_shard_count),
        .o_logical_count(alt_logical_count),
        .o_push_rr_ptr(),
        .o_logical_busy(),
        .o_shard_count(alt_shard_count),
        .o_shard_head_rank(alt_shard_head_rank),
        .o_shard_empty(alt_shard_empty),
        .o_shard_full(alt_shard_full),
        .o_shard_head_valid(),
        .o_update_pending(),
        .o_pending_logical_tree_id(),
        .o_pending_push(),
        .o_pending_pp()
    );

    always #5 clk = ~clk;

    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s at time %0t",
                         message, $time);
                failures = failures + 1;
            end
        end
    endtask

    task retire_default;
        input integer port_count;
        input integer rank_base;
        integer port;
        begin
            @(negedge clk);
            update_valid = {UPDATE_PORTS{1'b0}};
            for (port = 0; port < port_count;
                 port = port + 1) begin
                update_valid[port] = 1'b1;
                if (port == 0)
                    update_physical_tree_id[port] = 0;
                else
                    update_physical_tree_id[port] =
                        port + 3;
                update_head_rank[port] =
                    rank_base + port;
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            update_valid = {UPDATE_PORTS{1'b0}};
            req_valid = {REQUEST_PORTS{1'b0}};
            select_ready = {REQUEST_PORTS{1'b0}};
        end
    endtask

    task root_request_and_update;
        input do_push;
        input integer expected_physical;
        input integer new_head;
        begin
            @(negedge clk);
            req_valid = 4'b0001;
            req_push = do_push ? 4'b0001 : 4'b0000;
            logical_tree_id[0] = 0;
            select_ready = 4'b0001;
            #1;
            check(select_valid[0] &&
                  physical_tree_id[0] == expected_physical,
                  "default root selection mismatch");
            @(posedge clk);
            #1;
            @(posedge clk);
            #1;
            @(negedge clk);
            req_valid = 0;
            select_ready = 0;
            update_valid = 4'b0001;
            update_physical_tree_id[0] =
                expected_physical;
            update_head_rank[0] = new_head;
            @(posedge clk);
            #1;
            @(negedge clk);
            update_valid = 0;
        end
    endtask

    task reset_alt_fallback_case;
        begin
            @(negedge clk);
            arst_n = 1'b0;
            req_valid = 0;
            req_push = 0;
            req_pp = 0;
            select_ready = 0;
            update_valid = 0;
            alt_req_valid = 1'b0;
            alt_req_push = 1'b0;
            alt_req_pp = 1'b0;
            alt_logical_tree_id[0] = 3;
            alt_select_ready = 1'b0;
            alt_update_valid = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            arst_n = 1'b1;
            repeat (2) @(posedge clk);
            @(negedge clk);
        end
    endtask

    task alt_request_and_update;
        input do_push;
        input do_pp;
        input integer expected_physical;
        input integer new_head;
        begin
            alt_req_valid = 1'b1;
            alt_req_push = do_push;
            alt_req_pp = do_pp;
            alt_select_ready = 1'b1;
            #1;
            check(alt_select_valid &&
                  alt_physical_tree_id[0] == expected_physical,
                  "alternative fallback setup selection");
            if (do_pp)
                check(!alt_select_pp,
                      "full-minimum fallback unexpectedly formed one word");
            @(posedge clk);
            #1;
            @(posedge clk);
            #1;
            @(negedge clk);
            alt_req_valid = 1'b0;
            alt_req_pp = 1'b0;
            alt_select_ready = 1'b0;
            alt_update_valid = 1'b1;
            alt_update_physical_tree_id[0] =
                expected_physical;
            alt_update_head_rank[0] = new_head;
            @(posedge clk);
            @(negedge clk);
            alt_update_valid = 1'b0;
        end
    endtask

    task run_alt_fallback_case;
        input integer pushed_rank;
        input integer expected_pop_physical;
        begin
            reset_alt_fallback_case();

            // Fill physical 4 with rank 9, then create and remove an equal
            // rank entry in physical 3.  The lower-ID tie-break removes
            // physical 3 and leaves full physical 4 as the global minimum.
            alt_request_and_update(1'b1, 1'b0, 4, 9);
            alt_request_and_update(1'b1, 1'b0, 3, 9);
            alt_request_and_update(1'b0, 1'b0, 3, 16'hffff);
            check(alt_shard_count[4] == 1 &&
                  alt_shard_full[4] &&
                  alt_shard_count[3] == 0,
                  "directed fallback precondition");

            // The P/P first falls back to a normal Push on physical 3.
            alt_request_and_update(
                1'b1, 1'b1, 3, pushed_rank);

            // Its still-pending Pop must re-read the post-Push directory.
            alt_req_valid = 1'b1;
            alt_req_push = 1'b0;
            alt_select_ready = 1'b1;
            #1;
            check(alt_select_valid && !alt_select_pp &&
                  alt_physical_tree_id[0] ==
                      expected_pop_physical,
                  "fallback Pop did not use post-Push global Head");
            @(posedge clk);
            #1;
            @(posedge clk);
            #1;
            @(negedge clk);
            alt_req_valid = 1'b0;
            alt_select_ready = 1'b0;
            alt_update_valid = 1'b1;
            alt_update_physical_tree_id[0] =
                expected_pop_physical;
            alt_update_head_rank[0] = 16'hffff;
            @(posedge clk);
            @(negedge clk);
            alt_update_valid = 1'b0;
            #1;

            check(alt_logical_count[3] == 1,
                  "fallback compound operation changed net count");
            if (expected_pop_physical == 3) begin
                check(alt_shard_count[3] == 0 &&
                      alt_shard_empty[3] &&
                      alt_shard_count[4] == 1 &&
                      alt_shard_head_rank[4] == 9,
                      "new/equal fallback winner left wrong state");
            end else begin
                check(alt_shard_count[3] == 1 &&
                      alt_shard_head_rank[3] == pushed_rank &&
                      alt_shard_count[4] == 0 &&
                      alt_shard_empty[4],
                      "old-Head fallback winner left wrong state");
            end
            $display("Fallback directed case: pushed_rank=%0d pop_physical=%0d",
                     pushed_rank, expected_pop_physical);
        end
    endtask

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        req_valid = 0;
        req_push = 0;
        req_pp = 0;
        select_ready = 0;
        update_valid = 0;
        alt_req_valid = 1'b0;
        alt_req_push = 1'b0;
        alt_req_pp = 1'b0;
        alt_logical_tree_id[0] = 0;
        alt_select_ready = 1'b0;
        alt_update_valid = 1'b0;
        alt_update_physical_tree_id[0] = 0;
        alt_update_head_rank[0] = 0;
        failures = 0;
        for (i = 0; i < REQUEST_PORTS; i = i + 1) begin
            logical_tree_id[i] = 0;
            update_physical_tree_id[i] = 0;
            update_head_rank[i] = 0;
        end

        repeat (4) @(posedge clk);
        arst_n = 1'b1;
        repeat (2) @(posedge clk);
        #1;

        check(logical_shard_count[0] == 4 &&
              logical_shard_count[1] == 1 &&
              logical_shard_count[2] == 1 &&
              logical_shard_count[3] == 1,
              "default heterogeneous shard counts");
        check(shard_list[0][0] == 0 &&
              shard_list[0][1] == 1 &&
              shard_list[0][2] == 2 &&
              shard_list[0][3] == 3,
              "default root mapping");
        check(shard_list[1][0] == 4 &&
              shard_list[2][0] == 5 &&
              shard_list[3][0] == 6,
              "default leaf mappings");

        check(alt_logical_shard_count[0] == 2 &&
              alt_logical_shard_count[1] == 2 &&
              alt_logical_shard_count[2] == 1 &&
              alt_logical_shard_count[3] == 2,
              "alternative shard counts");
        check(alt_shard_list[0][0] == 2 &&
              alt_shard_list[0][1] == 0 &&
              alt_shard_list[1][0] == 5 &&
              alt_shard_list[1][1] == 1 &&
              alt_shard_list[2][0] == 6 &&
              alt_shard_list[3][0] == 4 &&
              alt_shard_list[3][1] == 3,
              "explicit non-contiguous shard map");

        // Four independent logical requests commit together.
        @(negedge clk);
        req_valid = 4'b1111;
        req_push = 4'b1111;
        select_ready = 4'b1111;
        logical_tree_id[0] = 0;
        logical_tree_id[1] = 1;
        logical_tree_id[2] = 2;
        logical_tree_id[3] = 3;
        #1;
        check(select_valid == 4'b1111,
              "four directory selections were not concurrent");
        check(physical_tree_id[0] == 0 &&
              physical_tree_id[1] == 4 &&
              physical_tree_id[2] == 5 &&
              physical_tree_id[3] == 6,
              "concurrent default selections");
        @(posedge clk);
        #1;
        @(posedge clk);
        #1;
        check(logical_busy[0] && logical_busy[1] &&
              logical_busy[2] && logical_busy[3],
              "four logical pending contexts");
        retire_default(4, 40);
        check(!busy, "concurrent updates did not retire");

        // Complete the root RR cycle and create a deterministic tie.
        root_request_and_update(1'b1, 1, 20);
        root_request_and_update(1'b1, 2, 20);
        root_request_and_update(1'b1, 3, 50);
        check(logical_count[0] == 4,
              "root count after RR pushes");
        root_request_and_update(1'b0, 1, 16'hffff);
        check(shard_count[1] == 0,
              "equal-rank tie did not choose lower physical ID");

        // Alternative explicit mapping participates in selection logic.
        @(negedge clk);
        alt_req_valid = 1'b1;
        alt_req_push = 1'b1;
        alt_select_ready = 1'b1;
        alt_logical_tree_id[0] = 3;
        #1;
        check(alt_req_ready && alt_select_valid &&
              alt_physical_tree_id[0] == 4,
              "alternative mapping Push selection");
        @(posedge clk);
        #1;
        @(posedge clk);
        #1;
        @(negedge clk);
        alt_req_valid = 1'b0;
        alt_select_ready = 1'b0;
        alt_update_valid = 1'b1;
        alt_update_physical_tree_id[0] = 4;
        alt_update_head_rank[0] = 9;
        @(posedge clk);
        @(negedge clk);
        alt_update_valid = 1'b0;

        // The same logical PIFO must stay inside its explicit {4,3} set.
        alt_req_valid = 1'b1;
        alt_req_push = 1'b1;
        alt_select_ready = 1'b1;
        #1;
        check(alt_select_valid &&
              alt_physical_tree_id[0] == 3,
              "alternative mapping RR Push selection");
        @(posedge clk);
        #1;
        @(posedge clk);
        #1;
        @(negedge clk);
        alt_req_valid = 1'b0;
        alt_select_ready = 1'b0;
        alt_update_valid = 1'b1;
        alt_update_physical_tree_id[0] = 3;
        alt_update_head_rank[0] = 9;
        @(posedge clk);
        @(negedge clk);
        alt_update_valid = 1'b0;
        alt_req_valid = 1'b1;
        alt_req_push = 1'b0;
        alt_select_ready = 1'b1;
        #1;
        check(alt_select_valid &&
              alt_physical_tree_id[0] == 3,
              "alternative mapping equal-rank Pop tie-break");
        @(posedge clk);
        #1;
        @(posedge clk);
        #1;
        @(negedge clk);
        alt_req_valid = 1'b0;
        alt_select_ready = 1'b0;
        alt_update_valid = 1'b1;
        alt_update_physical_tree_id[0] = 3;
        alt_update_head_rank[0] = 16'hffff;
        @(posedge clk);
        @(negedge clk);
        alt_update_valid = 1'b0;

        // physical 4 remains full with the minimum Head, while physical 3
        // has just been popped empty.  A same-logical P/P cannot safely use
        // one word on the minimum shard, so selection falls back to a normal
        // Push on the available shard and leaves its paired Pop pending.
        check(alt_shard_count[4] == 1 && alt_shard_full[4] &&
              alt_shard_count[3] == 0 && !alt_shard_full[3],
              "P/P full-min-shard fallback precondition");
        alt_req_valid = 1'b1;
        alt_req_push = 1'b1;
        alt_req_pp = 1'b1;
        alt_select_ready = 1'b0;
        #1;
        check(alt_select_valid && !alt_select_pp &&
              alt_physical_tree_id[0] == 3,
              "full minimum shard did not select split fallback Push");
        // The upstream descriptor is stable while ready is low; selection
        // must therefore remain stable until a real fire captures it.
        repeat (2) begin
            @(posedge clk);
            #1;
            check(alt_select_valid && !alt_select_pp &&
                  alt_physical_tree_id[0] == 3,
                  "blocked directory selection did not remain stable");
        end
        alt_select_ready = 1'b1;
        @(posedge clk);
        #1;
        @(posedge clk);
        #1;
        @(negedge clk);
        alt_req_valid = 1'b0;
        alt_req_pp = 1'b0;
        alt_select_ready = 1'b0;
        alt_update_valid = 1'b1;
        alt_update_physical_tree_id[0] = 3;
        alt_update_head_rank[0] = 12;
        @(posedge clk);
        @(negedge clk);
        alt_update_valid = 1'b0;

        // The paired Pop is now an ordinary pending Pop.  It must re-read the
        // post-Push directory, select the still-global minimum physical 4,
        // and restore the compound operation's net logical count to one.
        alt_req_valid = 1'b1;
        alt_req_push = 1'b0;
        alt_select_ready = 1'b1;
        #1;
        check(alt_select_valid && !alt_select_pp &&
              alt_physical_tree_id[0] == 4,
              "split fallback Pop did not reselect global minimum");
        @(posedge clk);
        #1;
        @(posedge clk);
        #1;
        @(negedge clk);
        alt_req_valid = 1'b0;
        alt_select_ready = 1'b0;
        alt_update_valid = 1'b1;
        alt_update_physical_tree_id[0] = 4;
        alt_update_head_rank[0] = 16'hffff;
        @(posedge clk);
        @(negedge clk);
        alt_update_valid = 1'b0;
        #1;
        check(alt_logical_count[3] == 1 &&
              alt_shard_count[3] == 1 &&
              alt_shard_head_rank[3] == 12 &&
              !alt_shard_empty[3] &&
              alt_shard_count[4] == 0 &&
              alt_shard_empty[4],
              "split fallback did not preserve net count/final Head");

        // Complete the two missing rank relationships under the same
        // full-minimum precondition.  A better new rank must be popped from
        // physical 3; an equal rank also selects physical 3 by ID tie-break.
        run_alt_fallback_case(7, 3);
        run_alt_fallback_case(9, 3);

        check(!protocol_error,
              "default directory protocol error");
        check(!alt_protocol_error,
              "alternative directory protocol error");
        if (failures == 0)
            $display("PASS: ShardDirectory_tb");
        else
            $fatal(1, "ShardDirectory_tb failures=%0d",
                   failures);
        $finish;
    end
endmodule
