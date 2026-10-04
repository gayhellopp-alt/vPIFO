`timescale 1ns / 1ps

// Parameterized full-capacity qualification for the M=2 BMW engine.
//
// Override LEVEL and TREE_NUM on the simulator command line.  The test fills
// every interleaved tree to its structural capacity, leaves all trees resident
// simultaneously, and then drains them while checking ordering and isolation.
module BMW2EngineCapacity_tb #(
    parameter integer PTW = 16,
    parameter integer MTW = 16,
    parameter integer CTW = 10,
    parameter integer LEVEL = 4,
    parameter integer TREE_NUM = 8,
    parameter integer FIFO_SIZE = 8
);
    localparam integer TREE_ID_WIDTH =
        (TREE_NUM <= 1) ? 1 : $clog2(TREE_NUM);
    localparam integer TREE_WORDS = (1 << LEVEL) - 1;
    localparam integer TREE_CAPACITY = 2 * TREE_WORDS;
    localparam integer TREE_GROUPS =
        (TREE_NUM + LEVEL - 1) / LEVEL;
    localparam integer SRAM_REQUIRED_DEPTH = TREE_GROUPS * TREE_WORDS;
    localparam integer MAX_WATCHDOG_CYCLES = 2000 + 40 * LEVEL;

    reg clk;
    reg arst_n;
    reg [TREE_ID_WIDTH-1:0] push_tree_id [0:LEVEL-1];
    reg [LEVEL-1:0] push;
    reg [(MTW+PTW)-1:0] push_data [0:LEVEL-1];
    reg [LEVEL-1:0] pop;
    reg [TREE_ID_WIDTH-1:0] pop_tree_id [0:LEVEL-1];

    wire [TREE_ID_WIDTH-1:0] tree_id [0:LEVEL-1];
    wire [(MTW+PTW)-1:0] pop_data [0:LEVEL-1];
    wire [LEVEL-1:0] is_level0_pop;
    wire [LEVEL-1:0] root_update_valid;
    wire [PTW-1:0] root_update_head_rank [0:LEVEL-1];
    wire [LEVEL-1:0] task_fifo_full;

    integer failures;
    integer pushes_checked;
    integer pops_checked;
    integer tree_index;
    integer rank_index;
    integer lane_index;
    integer max_read_addr [0:LEVEL-1];
    integer max_write_addr [0:LEVEL-1];
    integer read_accesses [0:LEVEL-1];
    integer write_accesses [0:LEVEL-1];

    PIFO_SRAM_TOP #(
        .PTW(PTW),
        .MTW(MTW),
        .CTW(CTW),
        .LEVEL(LEVEL),
        .TREE_NUM(TREE_NUM),
        .FIFO_SIZE(FIFO_SIZE)
    ) dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_push_tree_id(push_tree_id),
        .i_push(push),
        .i_push_data(push_data),
        .i_pop(pop),
        .i_pop_tree_id(pop_tree_id),
        .o_tree_id(tree_id),
        .o_pop_data(pop_data),
        .o_is_level0_pop(is_level0_pop),
        .o_root_update_valid(root_update_valid),
        .o_root_update_head_rank(root_update_head_rank),
        .o_task_fifo_full(task_fifo_full)
    );

    always #5 clk = ~clk;

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

    function automatic [(MTW+PTW)-1:0] expected_item;
        input integer requested_tree;
        input integer requested_rank;
        reg [MTW-1:0] metadata;
        reg [PTW-1:0] rank_value;
        begin
            metadata = requested_tree * 257 + requested_rank;
            rank_value = requested_rank;
            expected_item = {metadata, rank_value};
        end
    endfunction

    task automatic clear_inputs;
        integer lane;
        begin
            push = '0;
            pop = '0;
            for (lane = 0; lane < LEVEL; lane = lane + 1) begin
                push_tree_id[lane] = '0;
                pop_tree_id[lane] = '0;
                push_data[lane] = '0;
            end
        end
    endtask

    task automatic drive_word;
        input integer requested_tree;
        input requested_push;
        input requested_pop;
        input [(MTW+PTW)-1:0] requested_data;
        integer lane;
        integer watchdog;
        begin
            lane = requested_tree % LEVEL;
            watchdog = 0;
            while (task_fifo_full[lane] &&
                   (watchdog < MAX_WATCHDOG_CYCLES)) begin
                @(negedge clk);
                clear_inputs();
                watchdog = watchdog + 1;
            end
            check(watchdog < MAX_WATCHDOG_CYCLES,
                  "timeout waiting for TaskFIFO space");

            @(negedge clk);
            clear_inputs();
            push[lane] = requested_push;
            pop[lane] = requested_pop;
            push_tree_id[lane] = requested_tree[TREE_ID_WIDTH-1:0];
            pop_tree_id[lane] = requested_tree[TREE_ID_WIDTH-1:0];
            push_data[lane] = requested_data;
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_inputs();
        end
    endtask

    task automatic wait_for_push_completion;
        input integer requested_tree;
        input integer expected_head_rank;
        integer lane;
        integer watchdog;
        reg completed;
        begin
            lane = requested_tree % LEVEL;
            watchdog = 0;
            completed = 1'b0;
            while (!completed &&
                   (watchdog < MAX_WATCHDOG_CYCLES)) begin
                @(posedge clk);
                #1;
                if (root_update_valid[lane]) begin
                    check(tree_id[lane] ==
                              requested_tree[TREE_ID_WIDTH-1:0],
                          "push root update tree ID mismatch");
                    check(root_update_head_rank[lane] ==
                              expected_head_rank[PTW-1:0],
                          "push root head rank mismatch");
                    completed = 1'b1;
                end
                check(!is_level0_pop[lane],
                      "unexpected pop completion during push");
                watchdog = watchdog + 1;
            end
            check(completed, "timeout waiting for push completion");
            repeat (2 * LEVEL + 4) @(posedge clk);
            pushes_checked = pushes_checked + 1;
        end
    endtask

    task automatic wait_for_pop_completion;
        input integer requested_tree;
        input integer expected_rank;
        integer lane;
        integer watchdog;
        integer expected_next_head;
        reg pop_seen;
        reg update_seen;
        reg [(MTW+PTW)-1:0] item;
        begin
            lane = requested_tree % LEVEL;
            item = expected_item(requested_tree, expected_rank);
            if (expected_rank == TREE_CAPACITY)
                expected_next_head = {PTW{1'b1}};
            else
                expected_next_head = expected_rank + 1;

            watchdog = 0;
            pop_seen = 1'b0;
            update_seen = 1'b0;
            while (!(pop_seen && update_seen) &&
                   (watchdog < MAX_WATCHDOG_CYCLES)) begin
                @(posedge clk);
                #1;
                if (is_level0_pop[lane]) begin
                    check(!pop_seen,
                          "duplicate level-0 pop completion");
                    check(tree_id[lane] ==
                              requested_tree[TREE_ID_WIDTH-1:0],
                          "pop tree ID mismatch");
                    check(pop_data[lane] == item,
                          "pop data/rank mismatch");
                    pop_seen = 1'b1;
                end
                if (root_update_valid[lane]) begin
                    check(tree_id[lane] ==
                              requested_tree[TREE_ID_WIDTH-1:0],
                          "pop root update tree ID mismatch");
                    check(root_update_head_rank[lane] ==
                              expected_next_head[PTW-1:0],
                          "pop replacement head rank mismatch");
                    update_seen = 1'b1;
                end
                watchdog = watchdog + 1;
            end
            check(pop_seen, "timeout waiting for pop data");
            check(update_seen, "timeout waiting for pop root update");
            repeat (LEVEL + 4) @(posedge clk);
            pops_checked = pops_checked + 1;
        end
    endtask

    task automatic push_one;
        input integer requested_tree;
        input integer requested_rank;
        begin
            drive_word(requested_tree, 1'b1, 1'b0,
                       expected_item(requested_tree, requested_rank));
            wait_for_push_completion(requested_tree, requested_rank);
        end
    endtask

    task automatic pop_one;
        input integer requested_tree;
        input integer expected_rank;
        begin
            drive_word(requested_tree, 1'b0, 1'b1, '0);
            wait_for_pop_completion(requested_tree, expected_rank);
        end
    endtask

    // Independently check the address-sizing invariant exercised by the DUT.
    // All requested experiment points have TREE_NUM divisible by LEVEL, so a
    // full-capacity sweep should touch the final address in every RPU bank.
    // Sample after nonblocking clock updates settle.  This is also the point
    // at which the completion checks observe stable root-update information.
    always @(posedge clk) begin : address_monitor
        integer lane;
        #1;
        if (arst_n) begin
            for (lane = 0; lane < LEVEL; lane = lane + 1) begin
                if (dut.re[lane]) begin
                    check(dut.raddr[lane] < SRAM_REQUIRED_DEPTH,
                          "SRAM read address exceeds required depth");
                    if ((read_accesses[lane] == 0) ||
                        (dut.raddr[lane] > max_read_addr[lane]))
                        max_read_addr[lane] = dut.raddr[lane];
                    read_accesses[lane] = read_accesses[lane] + 1;
                end
                if (dut.we[lane]) begin
                    check(dut.waddr[lane] < SRAM_REQUIRED_DEPTH,
                          "SRAM write address exceeds required depth");
                    if ((write_accesses[lane] == 0) ||
                        (dut.waddr[lane] > max_write_addr[lane]))
                        max_write_addr[lane] = dut.waddr[lane];
                    write_accesses[lane] = write_accesses[lane] + 1;
                end
            end
        end
    end

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        failures = 0;
        pushes_checked = 0;
        pops_checked = 0;
        clear_inputs();
        for (lane_index = 0; lane_index < LEVEL;
             lane_index = lane_index + 1) begin
            max_read_addr[lane_index] = 0;
            max_write_addr[lane_index] = 0;
            read_accesses[lane_index] = 0;
            write_accesses[lane_index] = 0;
        end

        check((TREE_NUM % LEVEL) == 0,
              "capacity sweep requires TREE_NUM divisible by LEVEL");
        $display("BMW2_CAPACITY CONFIG level=%0d tree_num=%0d tree_capacity=%0d total_capacity=%0d sram_required_depth=%0d",
                 LEVEL, TREE_NUM, TREE_CAPACITY,
                 TREE_NUM * TREE_CAPACITY, SRAM_REQUIRED_DEPTH);

        repeat (5) @(posedge clk);
        arst_n = 1'b1;
        repeat (5) @(posedge clk);

        // Descending insertion makes every new item the expected root head.
        // All trees remain populated so writes from later tree IDs can expose
        // aliasing in the rotating placement of earlier tree IDs.
        for (tree_index = 0; tree_index < TREE_NUM;
             tree_index = tree_index + 1) begin
            $display("BMW2_CAPACITY fill tree=%0d/%0d",
                     tree_index, TREE_NUM-1);
            for (rank_index = TREE_CAPACITY; rank_index >= 1;
                 rank_index = rank_index - 1)
                push_one(tree_index, rank_index);
        end

        // A different tree traversal order prevents the drain order from
        // simply mirroring the fill order.
        for (tree_index = TREE_NUM-1; tree_index >= 0;
             tree_index = tree_index - 1) begin
            $display("BMW2_CAPACITY drain tree=%0d/%0d",
                     tree_index, TREE_NUM-1);
            for (rank_index = 1; rank_index <= TREE_CAPACITY;
                 rank_index = rank_index + 1)
                pop_one(tree_index, rank_index);
        end

        check(pushes_checked == TREE_NUM * TREE_CAPACITY,
              "push completion count mismatch");
        check(pops_checked == TREE_NUM * TREE_CAPACITY,
              "pop completion count mismatch");
        for (lane_index = 0; lane_index < LEVEL;
             lane_index = lane_index + 1) begin
            $display("BMW2_CAPACITY bank=%0d reads=%0d writes=%0d max_read_addr=%0d max_write_addr=%0d expected_max=%0d",
                     lane_index, read_accesses[lane_index],
                     write_accesses[lane_index],
                     max_read_addr[lane_index],
                     max_write_addr[lane_index],
                     SRAM_REQUIRED_DEPTH-1);
            check(read_accesses[lane_index] > 0,
                  "RPU bank had no observed read access");
            check(write_accesses[lane_index] > 0,
                  "RPU bank had no observed write access");
            check(max_read_addr[lane_index] == SRAM_REQUIRED_DEPTH-1,
                  "RPU bank did not exercise final read address");
            check(max_write_addr[lane_index] == SRAM_REQUIRED_DEPTH-1,
                  "RPU bank did not exercise final write address");
        end

        if (failures == 0) begin
            $display("PASS: BMW2EngineCapacity_tb level=%0d tree_num=%0d pushes=%0d pops=%0d",
                     LEVEL, TREE_NUM, pushes_checked, pops_checked);
        end else begin
            $fatal(1,
                   "BMW2EngineCapacity_tb failures=%0d level=%0d tree_num=%0d",
                   failures, LEVEL, TREE_NUM);
        end
        $finish;
    end
endmodule
