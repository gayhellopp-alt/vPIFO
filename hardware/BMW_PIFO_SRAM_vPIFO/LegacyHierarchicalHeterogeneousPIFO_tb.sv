`timescale 1ns / 1ps

// Replays the reference-covered prefix of an original SDL-compiler workload.
// Ranks are consumed as precomputed values, matching the original hardware
// boundary; only the compiler's 10/20/... node IDs are explicitly normalized.
module LegacyHierarchicalHeterogeneousPIFO_tb;
    localparam PTW = LegacyTracePkg::PTW;
    localparam MTW = LegacyTracePkg::MTW;
    localparam DATA_WIDTH = PTW + MTW;
    localparam LOGICAL_TREE_NUM = VpifoConfigPkg::LOGICAL_TREE_NUM;
    localparam LOGICAL_ID_WIDTH = VpifoConfigPkg::LOGICAL_ID_WIDTH;

    reg clk;
    reg arst_n;
    reg push;
    reg [LOGICAL_ID_WIDTH-1:0] push_tree_id;
    reg [PTW-1:0] push_priority;
    reg [DATA_WIDTH-1:0] push_data;
    reg pop;

    wire push_ready;
    wire reject_bad_leaf_id;
    wire pop_req_ready;
    wire pop_out;
    wire [LOGICAL_ID_WIDTH-1:0] pop_tree_id;
    wire [DATA_WIDTH-1:0] pop_data;
    wire busy;
    wire protocol_error;

    integer event_index;
    integer observed_pop_count;
    integer failures;
    integer idle_index;
    integer watchdog;
    integer pop_count_before_request;
    integer expected_match_index;
    integer expected_match_count;
    integer result_scan_index;
    reg result_seen [0:LegacyTracePkg::EXPECTED_POP_COUNT-1];

    HierarchicalHeterogeneousPIFO #(
        .PTW(PTW),
        .MTW(MTW)
    ) dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_push(push),
        .i_push_tree_id(push_tree_id),
        .i_push_priority(push_priority),
        .i_push_data(push_data),
        .o_push_ready(push_ready),
        .o_reject_bad_leaf_id(reject_bad_leaf_id),
        .i_pop(pop),
        .o_pop_req_ready(pop_req_ready),
        .o_pop_out(pop_out),
        .o_pop_tree_id(pop_tree_id),
        .o_pop_data(pop_data),
        .o_busy(busy),
        .o_protocol_error(protocol_error)
    );

    always #5 clk = ~clk;

    task wait_for_push_ready;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!push_ready && wait_cycles < 16000) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!push_ready)
                $fatal(1, "legacy workload Push-ready timeout at event %0d",
                       event_index);
        end
    endtask

    task wait_for_pop_ready;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!pop_req_ready && wait_cycles < 16000) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!pop_req_ready)
                $fatal(1, "legacy workload Pop-ready timeout at event %0d",
                       event_index);
        end
    endtask

    always @(posedge clk) begin
        if (arst_n) begin
            if (protocol_error)
                $fatal(1, "legacy workload raised protocol_error");
            if (reject_bad_leaf_id)
                $fatal(1, "legacy workload leaf ID was rejected");
            if (pop_out) begin
                if (observed_pop_count >=
                    LegacyTracePkg::EXPECTED_POP_COUNT) begin
                    failures = failures + 1;
                    $display("FAIL: unexpected extra Pop result meta=%0d",
                             pop_data[DATA_WIDTH-1:PTW]);
                end else begin
                    // The inherited BMW RTL compares rank only.  Metadata is
                    // not a tie breaker, so validate the reference rank/tree
                    // class at each position and separately prove that every
                    // packet metadata value appears exactly once.
                    if (pop_data[PTW-1:0] !=
                        LegacyTracePkg::EXPECTED_PRIORITY0[
                            observed_pop_count]) begin
                        failures = failures + 1;
                        $display("FAIL: Pop %0d leaf rank expected=%0d actual=%0d meta=%0d",
                                 observed_pop_count,
                                 LegacyTracePkg::EXPECTED_PRIORITY0[
                                     observed_pop_count],
                                 pop_data[PTW-1:0],
                                 pop_data[DATA_WIDTH-1:PTW]);
                    end
                    if (pop_tree_id !=
                        LegacyTracePkg::EXPECTED_TREE_ID[
                            observed_pop_count]) begin
                        failures = failures + 1;
                        $display("FAIL: Pop %0d tree expected=%0d actual=%0d",
                                 observed_pop_count,
                                 LegacyTracePkg::EXPECTED_TREE_ID[
                                     observed_pop_count],
                                 pop_tree_id);
                    end
                    expected_match_index = -1;
                    expected_match_count = 0;
                    for (result_scan_index = 0;
                         result_scan_index <
                             LegacyTracePkg::EXPECTED_POP_COUNT;
                         result_scan_index = result_scan_index + 1) begin
                        if (LegacyTracePkg::EXPECTED_META[result_scan_index] ==
                            pop_data[DATA_WIDTH-1:PTW]) begin
                            expected_match_index = result_scan_index;
                            expected_match_count = expected_match_count + 1;
                        end
                    end
                    if (expected_match_count != 1) begin
                        failures = failures + 1;
                        $display("FAIL: Pop metadata %0d is outside reference set",
                                 pop_data[DATA_WIDTH-1:PTW]);
                    end else if (result_seen[expected_match_index]) begin
                        failures = failures + 1;
                        $display("FAIL: Pop metadata %0d was duplicated",
                                 pop_data[DATA_WIDTH-1:PTW]);
                    end else begin
                        result_seen[expected_match_index] = 1'b1;
                    end
                end
                observed_pop_count = observed_pop_count + 1;
            end
        end
    end

    initial begin
        if (LOGICAL_TREE_NUM < 3)
            $fatal(1, "legacy workloads require root plus logical leaves 1 and 2");
        clk = 1'b0;
        arst_n = 1'b0;
        push = 1'b0;
        push_tree_id = '0;
        push_priority = '0;
        push_data = '1;
        pop = 1'b0;
        observed_pop_count = 0;
        failures = 0;
        for (result_scan_index = 0;
             result_scan_index < LegacyTracePkg::EXPECTED_POP_COUNT;
             result_scan_index = result_scan_index + 1)
            result_seen[result_scan_index] = 1'b0;
        repeat (5) @(posedge clk);
        arst_n = 1'b1;
        repeat (3) @(posedge clk);

        // Present one trace operation per cycle whenever the ready contract
        // permits it.  This matches TRACE_READER cadence; a prior task-style
        // driver accidentally inserted a blank cycle between every event.
        @(negedge clk);
        for (event_index = 0;
             event_index < LegacyTracePkg::EVENT_COUNT;
             event_index = event_index + 1) begin
            push = 1'b0;
            pop = 1'b0;
            case (LegacyTracePkg::EVENT_KIND[event_index])
                0: begin
                    for (idle_index = 0;
                         idle_index <
                             LegacyTracePkg::EVENT_IDLE_CYCLE[event_index];
                         idle_index = idle_index + 1)
                        @(negedge clk);
                end
                1: begin
                    wait_for_push_ready();
                    push_tree_id =
                        LegacyTracePkg::EVENT_TREE_ID[event_index];
                    push_priority =
                        LegacyTracePkg::EVENT_PRIORITY1[event_index];
                    push_data = {
                        LegacyTracePkg::EVENT_META[event_index][MTW-1:0],
                        LegacyTracePkg::EVENT_PRIORITY0[event_index][PTW-1:0]
                    };
                    push = 1'b1;
                    @(negedge clk);
                end
                2: begin
                    wait_for_pop_ready();
                    pop_count_before_request = observed_pop_count;
                    pop = 1'b1;
                    @(negedge clk);
                    pop = 1'b0;
                    // batch_reference compares a stable, fully populated PIFO
                    // one result at a time; this avoids making a scheduling
                    // semantic check depend on wrapper-specific queue depth.
                    if (LegacyTracePkg::REPLAY_MODE == "batch_reference") begin
                        watchdog = 0;
                        while ((observed_pop_count == pop_count_before_request) &&
                               watchdog < 16000) begin
                            @(negedge clk);
                            watchdog = watchdog + 1;
                        end
                        if (observed_pop_count == pop_count_before_request)
                            $fatal(1, "batch reference Pop-result timeout");
                    end
                end
                3: begin
                    watchdog = 0;
                    while (busy && watchdog < 100000) begin
                        @(negedge clk);
                        watchdog = watchdog + 1;
                    end
                    if (busy)
                        $fatal(1, "batch reference Push barrier timed out");
                end
                default:
                    $fatal(1, "unknown legacy event type at %0d", event_index);
            endcase
        end
        push = 1'b0;
        pop = 1'b0;

        watchdog = 0;
        while (((observed_pop_count !=
                 LegacyTracePkg::EXPECTED_POP_COUNT) || busy) &&
               watchdog < 100000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        if (observed_pop_count != LegacyTracePkg::EXPECTED_POP_COUNT) begin
            failures = failures + 1;
            $display("FAIL: expected %0d Pop results, observed %0d",
                     LegacyTracePkg::EXPECTED_POP_COUNT,
                     observed_pop_count);
        end
        if (busy) begin
            failures = failures + 1;
            $display("FAIL: legacy workload did not drain");
        end
        for (result_scan_index = 0;
             result_scan_index < LegacyTracePkg::EXPECTED_POP_COUNT;
             result_scan_index = result_scan_index + 1) begin
            if (!result_seen[result_scan_index]) begin
                failures = failures + 1;
                $display("FAIL: reference metadata %0d was not returned",
                         LegacyTracePkg::EXPECTED_META[result_scan_index]);
            end
        end

        if (failures == 0)
            $display("PASS: LegacyHierarchicalHeterogeneousPIFO_tb workload=%0s pops=%0d logical=%0d physical=%0d",
                     LegacyTracePkg::WORKLOAD_NAME,
                     observed_pop_count,
                     VpifoConfigPkg::LOGICAL_TREE_NUM,
                     VpifoConfigPkg::PHYSICAL_TREE_NUM);
        else
            $fatal(1, "legacy workload failures=%0d", failures);
        $finish;
    end
endmodule
