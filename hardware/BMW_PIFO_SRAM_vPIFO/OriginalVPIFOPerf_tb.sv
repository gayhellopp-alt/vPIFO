`timescale 1ns / 1ps

// Cycle benchmark for the original, non-heterogeneous PIFO_SRAM_TOP.
// The DUT sources are taken from commit 89ab35258c10867db3c731b2283e5991a37174cc.
// This bench deliberately uses only ports and hierarchy present in that commit.
module OriginalVPIFOPerf_tb;
    localparam integer PTW = 16;
    localparam integer MTW = 16;
    localparam integer CTW = 10;
    localparam integer LEVEL = 4;
    localparam integer TREE_NUM = 4;
    localparam integer FIFO_SIZE = 8;
    localparam integer TREE_ID_WIDTH = $clog2(TREE_NUM);

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
    wire [LEVEL-1:0] task_fifo_full;

    integer failures;
    integer global_cycles;
    integer phase_id;
    integer phase_cycles;
    integer phase_words;
    integer phase_pops;
    integer phase_stalls;
    integer phase_transactions;
    integer phase_primitives;
    integer idle_watchdog;
    integer idle_streak;
    integer workload_index;
    integer logical_id;
    integer setup_index;
    reg phase_active;

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
        .o_task_fifo_full(task_fifo_full)
    );

    always #5 clk = ~clk;

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

    task clear_inputs;
        integer lane;
        begin
            push = {LEVEL{1'b0}};
            pop = {LEVEL{1'b0}};
            for (lane = 0; lane < LEVEL; lane = lane + 1) begin
                push_tree_id[lane] = {TREE_ID_WIDTH{1'b0}};
                pop_tree_id[lane] = {TREE_ID_WIDTH{1'b0}};
                push_data[lane] = {(MTW+PTW){1'b0}};
            end
        end
    endtask

    function automatic dut_is_idle;
        begin
            // TaskFIFO empty is insufficient because TaskDistribute may have
            // already removed a word while its operation is still in flight.
            dut_is_idle = (&dut.TaskFIFO_empty) &&
                          !(|dut.rpu_push) && !(|dut.rpu_pop) &&
                          !(|dut.push_dn) && !(|dut.pop_dn) &&
                          !(|dut.read) && !(|dut.write) &&
                          !(|dut.we) && !(|dut.re) &&
                          (dut.td.rpu_state[0] == 2'b00) &&
                          (dut.td.rpu_state[1] == 2'b00) &&
                          (dut.td.rpu_state[2] == 2'b00) &&
                          (dut.td.rpu_state[3] == 2'b00) &&
                          (dut.td.TaskHead_type[0] == 2'b00) &&
                          (dut.td.TaskHead_type[1] == 2'b00) &&
                          (dut.td.TaskHead_type[2] == 2'b00) &&
                          (dut.td.TaskHead_type[3] == 2'b00) &&
                          (dut.td.TaskHead_type_after[0] == 2'b00) &&
                          (dut.td.TaskHead_type_after[1] == 2'b00) &&
                          (dut.td.TaskHead_type_after[2] == 2'b00) &&
                          (dut.td.TaskHead_type_after[3] == 2'b00);
        end
    endfunction

    task wait_idle;
        begin
            @(negedge clk);
            clear_inputs();
            idle_watchdog = 0;
            idle_streak = 0;
            while ((idle_streak < 1) && (idle_watchdog < 20000)) begin
                @(posedge clk);
                #1;
                if (dut_is_idle())
                    idle_streak = idle_streak + 1;
                else
                    idle_streak = 0;
                idle_watchdog = idle_watchdog + 1;
            end
            check(idle_streak == 1, "timeout waiting for original DUT idle");
        end
    endtask

    task drive_task;
        input integer requested_tree;
        input requested_push;
        input requested_pop;
        input integer requested_rank;
        input integer requested_tag;
        integer lane;
        reg accepted;
        begin
            lane = requested_tree % LEVEL;
            accepted = 1'b0;
            while (!accepted) begin
                @(negedge clk);
                clear_inputs();
                #1;
                if (!task_fifo_full[lane]) begin
                    push[lane] = requested_push;
                    pop[lane] = requested_pop;
                    push_tree_id[lane] =
                        requested_tree[TREE_ID_WIDTH-1:0];
                    pop_tree_id[lane] =
                        requested_tree[TREE_ID_WIDTH-1:0];
                    push_data[lane] = {
                        requested_tag[MTW-1:0],
                        requested_rank[PTW-1:0]
                    };
                    accepted = 1'b1;
                end else if (phase_active) begin
                    phase_stalls = phase_stalls + 1;
                end
                @(posedge clk);
                #1;
            end
            if (phase_active) begin
                phase_words = phase_words + 1;
                phase_transactions = phase_transactions + 1;
                phase_primitives = phase_primitives +
                    requested_push + requested_pop;
            end
        end
    endtask

    task drive_pp;
        input integer requested_tree;
        input integer requested_rank;
        input integer requested_tag;
        begin
            drive_task(requested_tree, 1'b1, 1'b1,
                       requested_rank, requested_tag);
        end
    endtask

    task drive_push;
        input integer requested_tree;
        input integer requested_rank;
        input integer requested_tag;
        begin
            drive_task(requested_tree, 1'b1, 1'b0,
                       requested_rank, requested_tag);
        end
    endtask

    task drive_pop;
        input integer requested_tree;
        begin
            drive_task(requested_tree, 1'b0, 1'b1, 0, 0);
        end
    endtask

    task begin_phase;
        input integer requested_phase;
        begin
            wait_idle();
            phase_id = requested_phase;
            phase_cycles = 0;
            phase_words = 0;
            phase_pops = 0;
            phase_stalls = 0;
            phase_transactions = 0;
            phase_primitives = 0;
            phase_active = 1'b1;
            $display("ORIGINAL_PERF START phase=%0d time=%0t",
                     phase_id, $time);
        end
    endtask

    task finish_phase;
        input integer expected_transactions;
        input integer expected_primitives;
        input integer expected_pops;
        begin
            wait_idle();
            phase_active = 1'b0;
            check(phase_transactions == expected_transactions,
                  "original phase transaction count mismatch");
            check(phase_primitives == expected_primitives,
                  "original phase primitive count mismatch");
            check(phase_words == expected_transactions,
                  "original phase TaskFIFO word count mismatch");
            check(phase_pops == expected_pops,
                  "original phase Pop completion count mismatch");
            $display("ORIGINAL_PERF phase=%0d transactions=%0d primitives=%0d cycles=%0d cycles_per_transaction_x1000=%0d taskfifo_words=%0d pop_completions=%0d input_full_stall_cycles=%0d",
                     phase_id, phase_transactions, phase_primitives,
                     phase_cycles,
                     (phase_cycles * 1000) / phase_transactions,
                     phase_words, phase_pops, phase_stalls);
        end
    endtask

    always @(posedge clk) begin
        if (!arst_n) begin
            global_cycles = 0;
            phase_cycles = 0;
            phase_pops = 0;
        end else begin
            global_cycles = global_cycles + 1;
            if (phase_active) begin
                phase_cycles = phase_cycles + 1;
                phase_pops = phase_pops + $countones(is_level0_pop);
            end
        end
    end

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        failures = 0;
        phase_active = 1'b0;
        phase_id = 0;
        clear_inputs();

        repeat (4) @(posedge clk);
        arst_n = 1'b1;
        repeat (2) @(posedge clk);
        #1;

        // Phase 1: exact transaction-sequence equivalent.  One original tree
        // continuously receives 20 same-tree compound P/P words.
        begin_phase(1);
        for (workload_index = 0; workload_index < 20;
             workload_index = workload_index + 1)
            drive_pp(1, 100 + workload_index,
                     16'ha000 + workload_index);
        finish_phase(20, 40, 20);

        // Phase 2: exact transaction-sequence equivalent.  Four original
        // trees interleave the same 40 compound P/P words.
        begin_phase(2);
        for (workload_index = 0; workload_index < 40;
             workload_index = workload_index + 1)
            drive_pp(workload_index % TREE_NUM,
                     200 + workload_index,
                     16'hb000 + workload_index);
        finish_phase(40, 80, 40);

        // Phase 3 control: the operation count and occupancy match, but an
        // original tree cannot rotate one logical PIFO through four shards.
        drive_push(0, 40, 16'h7000);
        drive_push(0, 10, 16'h7001);
        drive_push(0, 30, 16'h7002);
        drive_push(0, 20, 16'h7003);
        wait_idle();
        begin_phase(3);
        for (workload_index = 0; workload_index < 16;
             workload_index = workload_index + 1)
            drive_pp(0, 50 + workload_index * 10,
                     16'hc000 + workload_index);
        finish_phase(16, 32, 16);
        for (workload_index = 0; workload_index < 4;
             workload_index = workload_index + 1)
            drive_pop(0);
        wait_idle();

        // Phase 4 control: 29/30 occupied preserves a safe one-word P/P in
        // the original core.  The heterogeneous full-minimum fallback state
        // (one shard full while sibling shards have room) has no original
        // non-sharded equivalent.
        for (setup_index = 0; setup_index < 29;
             setup_index = setup_index + 1)
            drive_push(0, 100 + setup_index,
                       16'h8000 + setup_index);
        wait_idle();
        begin_phase(4);
        for (workload_index = 0; workload_index < 12;
             workload_index = workload_index + 1)
            drive_pp(0, 1 + workload_index,
                     16'hd000 + workload_index);
        finish_phase(12, 24, 12);
        for (workload_index = 0; workload_index < 29;
             workload_index = workload_index + 1)
            drive_pop(0);
        wait_idle();

        // Phase 5: exact transaction mix and initial occupancy.  Each original
        // tree starts with eight elements, then receives the same 64-operation
        // P/P, Push, Pop, P/P pattern as the heterogeneous performance test.
        for (logical_id = 0; logical_id < TREE_NUM;
             logical_id = logical_id + 1)
            for (setup_index = 0; setup_index < 8;
                 setup_index = setup_index + 1)
                drive_push(logical_id,
                           500 + logical_id * 100 + setup_index,
                           16'he000 + logical_id * 16 + setup_index);
        wait_idle();
        begin_phase(5);
        for (workload_index = 0; workload_index < 64;
             workload_index = workload_index + 1) begin
            logical_id = workload_index % TREE_NUM;
            case ((workload_index / TREE_NUM) % 4)
                0, 3:
                    drive_pp(logical_id,
                             50 + workload_index,
                             16'hf000 + workload_index);
                1:
                    drive_push(logical_id,
                               50 + workload_index,
                               16'hf000 + workload_index);
                default:
                    drive_pop(logical_id);
            endcase
        end
        finish_phase(64, 96, 48);

        if (failures == 0)
            $display("PASS: OriginalVPIFOPerf_tb");
        else
            $fatal(1, "OriginalVPIFOPerf_tb failures=%0d", failures);
        $finish;
    end
endmodule
