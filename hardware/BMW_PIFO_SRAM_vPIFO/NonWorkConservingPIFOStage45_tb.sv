`timescale 1ns / 1ps

// End-to-end Stage-4.5 test:
// shaping child -> release admission -> Stage-28 hierarchical scheduler ->
// packet output.  It specifically checks scheduling Pop priority, direct Push
// priority, parent backpressure, release delay accounting, and final drain.
module NonWorkConservingPIFOStage45_tb;
    localparam PTW = 16;
    localparam MTW = 16;
    localparam DATA_WIDTH = PTW + MTW;
    localparam TIME_WIDTH = 16;
    localparam SCHED_LOGICAL_NUM = 4;
    localparam SCHED_PHYSICAL_NUM = 7;
    localparam SCHED_LOGICAL_ID_WIDTH = 2;
    localparam SCHED_PENDING_DEPTH = 15;
    localparam SCHED_PENDING_COUNT_WIDTH = 4;
    localparam SCHED_TOTAL_COUNT_WIDTH = 6;
    localparam SHAPING_LOGICAL_NUM = 2;
    localparam SHAPING_PHYSICAL_NUM = 3;
    localparam SHAPING_LOGICAL_ID_WIDTH = 1;
    localparam SHAPING_PENDING_DEPTH = 11;
    localparam SHAPING_PENDING_COUNT_WIDTH = 4;
    localparam SHAPING_TOTAL_COUNT_WIDTH = 5;
    localparam integer SCHED_SHARD_COUNTS
        [0:SCHED_LOGICAL_NUM-1] = '{4, 1, 1, 1};
    localparam integer SCHED_SHARD_OFFSETS
        [0:SCHED_LOGICAL_NUM-1] = '{0, 4, 5, 6};
    localparam integer SHAPING_SHARD_COUNTS
        [0:SHAPING_LOGICAL_NUM-1] = '{2, 1};
    localparam integer SHAPING_SHARD_OFFSETS
        [0:SHAPING_LOGICAL_NUM-1] = '{0, 2};

    localparam [DATA_WIDTH-1:0] PACKET_0 = 32'hA000_0005;
    localparam [DATA_WIDTH-1:0] PACKET_1 = 32'hB000_000A;
    localparam [DATA_WIDTH-1:0] SHAPED_PACKET = 32'hC000_0007;

    reg clk;
    reg arst_n;
    reg [TIME_WIDTH-1:0] wall_time;

    reg shaping_event_valid;
    wire shaping_event_ready;
    reg [SHAPING_LOGICAL_ID_WIDTH-1:0] shaping_logical_id;
    reg [TIME_WIDTH-1:0] shaping_release_time;
    reg [SCHED_LOGICAL_ID_WIDTH-1:0] shaping_parent_leaf_id;
    reg [PTW-1:0] shaping_parent_priority;
    reg [DATA_WIDTH-1:0] shaping_packet_data;
    wire shaping_reject_bad_id;

    reg direct_push_valid;
    wire direct_push_ready;
    reg [SCHED_LOGICAL_ID_WIDTH-1:0] direct_leaf_id;
    reg [PTW-1:0] direct_priority;
    reg [DATA_WIDTH-1:0] direct_packet_data;
    wire direct_reject_bad_leaf_id;

    reg packet_pop_valid;
    wire packet_pop_ready;
    wire packet_out_valid;
    wire [SCHED_LOGICAL_ID_WIDTH-1:0] packet_out_leaf_id;
    wire [DATA_WIDTH-1:0] packet_out_data;

    wire shaping_to_parent_fire;
    wire direct_to_parent_fire;
    wire shaping_release_pending;
    wire shaping_deferred;
    wire deferred_by_direct_push;
    wire deferred_by_scheduling_pop;
    wire deferred_by_parent_backpressure;
    wire [31:0] shaping_deferred_cycles;
    wire [TIME_WIDTH-1:0] release_delay_last;
    wire [TIME_WIDTH-1:0] release_delay_max;
    wire [3:0] shaping_event_table_count;
    wire [1:0] shaping_release_fifo_count;
    wire [SHAPING_LOGICAL_NUM-1:0] shaping_release_reserved;
    wire [SHAPING_LOGICAL_NUM-1:0] shaping_completion_valid;
    wire [1:0] shaping_due_issue_valid;
    wire [1:0] shaping_due_capture_fire;
    wire [1:0] shaping_due_issue_count;
    wire [SHAPING_TOTAL_COUNT_WIDTH-1:0]
        shaping_logical_count [0:SHAPING_LOGICAL_NUM-1];
    wire [SHAPING_PENDING_COUNT_WIDTH-1:0]
        shaping_logical_pending_count [0:SHAPING_LOGICAL_NUM-1];
    wire [SCHED_TOTAL_COUNT_WIDTH-1:0]
        scheduler_logical_count [0:SCHED_LOGICAL_NUM-1];
    wire [SCHED_PENDING_COUNT_WIDTH-1:0] scheduler_pending_count;
    wire shaping_busy;
    wire scheduler_busy;
    wire busy;
    wire protocol_error;

    integer failures;
    integer watchdog;
    integer output_count;
    integer shaping_fire_count;
    integer direct_fire_count;
    integer pop_priority_defer_count;
    integer push_priority_defer_count;
    integer parent_backpressure_defer_count;
    integer logical_index;
    reg [DATA_WIDTH-1:0] output_data [0:2];
    reg [SCHED_LOGICAL_ID_WIDTH-1:0] output_leaf [0:2];

    NonWorkConservingPIFOStage45 #(
        .PTW(PTW),
        .MTW(MTW),
        .SCHEDULER_LEVEL(4),
        .SCHEDULER_LOGICAL_TREE_NUM(SCHED_LOGICAL_NUM),
        .SCHEDULER_PHYSICAL_TREE_NUM(SCHED_PHYSICAL_NUM),
        .SCHEDULER_SHARD_CAPACITY(8),
        .SCHEDULER_MAX_SHARDS_PER_LOGICAL(4),
        .SCHEDULER_LOGICAL_PENDING_DEPTH(SCHED_PENDING_DEPTH),
        .SCHEDULER_SHARD_COUNTS(SCHED_SHARD_COUNTS),
        .SCHEDULER_SHARD_OFFSETS(SCHED_SHARD_OFFSETS),
        .TIME_WIDTH(TIME_WIDTH),
        .SEQUENCE_WIDTH(8),
        .SHAPING_EVENT_TABLE_DEPTH(8),
        .SHAPING_RELEASE_FIFO_DEPTH(2),
        .SHAPING_RELEASE_ISSUE_PORTS(2),
        .SHAPING_LEVEL(4),
        .SHAPING_LOGICAL_TREE_NUM(SHAPING_LOGICAL_NUM),
        .SHAPING_PHYSICAL_TREE_NUM(SHAPING_PHYSICAL_NUM),
        .SHAPING_SHARD_CAPACITY(8),
        .SHAPING_MAX_SHARDS_PER_LOGICAL(2),
        .SHAPING_LOGICAL_PENDING_DEPTH(SHAPING_PENDING_DEPTH),
        .SHAPING_SHARD_COUNTS(SHAPING_SHARD_COUNTS),
        .SHAPING_SHARD_OFFSETS(SHAPING_SHARD_OFFSETS)
    ) dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_time(wall_time),
        .i_shaping_event_valid(shaping_event_valid),
        .o_shaping_event_ready(shaping_event_ready),
        .i_shaping_logical_tree_id(shaping_logical_id),
        .i_shaping_release_time(shaping_release_time),
        .i_shaping_parent_leaf_tree_id(shaping_parent_leaf_id),
        .i_shaping_parent_priority(shaping_parent_priority),
        .i_shaping_packet_data(shaping_packet_data),
        .o_shaping_reject_bad_id(shaping_reject_bad_id),
        .i_direct_push_valid(direct_push_valid),
        .o_direct_push_ready(direct_push_ready),
        .i_direct_leaf_tree_id(direct_leaf_id),
        .i_direct_priority(direct_priority),
        .i_direct_packet_data(direct_packet_data),
        .o_direct_reject_bad_leaf_id(direct_reject_bad_leaf_id),
        .i_packet_pop_valid(packet_pop_valid),
        .i_packet_pop_semantic_tree_id(1'b0),
        .o_packet_pop_ready(packet_pop_ready),
        .o_packet_out_valid(packet_out_valid),
        .o_packet_out_semantic_tree_id(),
        .o_packet_out_leaf_tree_id(packet_out_leaf_id),
        .o_packet_out_data(packet_out_data),
        .o_shaping_to_parent_fire(shaping_to_parent_fire),
        .o_direct_to_parent_fire(direct_to_parent_fire),
        .o_shaping_release_pending(shaping_release_pending),
        .o_shaping_deferred(shaping_deferred),
        .o_deferred_by_direct_push(deferred_by_direct_push),
        .o_deferred_by_scheduling_pop(deferred_by_scheduling_pop),
        .o_deferred_by_parent_backpressure(
            deferred_by_parent_backpressure),
        .o_shaping_deferred_cycles(shaping_deferred_cycles),
        .o_release_delay_last(release_delay_last),
        .o_release_delay_max(release_delay_max),
        .o_shaping_event_table_count(shaping_event_table_count),
        .o_shaping_release_fifo_count(shaping_release_fifo_count),
        .o_shaping_release_reserved(shaping_release_reserved),
        .o_shaping_completion_valid(shaping_completion_valid),
        .o_shaping_due_issue_valid(shaping_due_issue_valid),
        .o_shaping_due_capture_fire(shaping_due_capture_fire),
        .o_shaping_due_issue_count(shaping_due_issue_count),
        .o_shaping_logical_count(shaping_logical_count),
        .o_shaping_logical_pending_count(
            shaping_logical_pending_count),
        .o_scheduler_logical_count(scheduler_logical_count),
        .o_scheduler_pending_count(scheduler_pending_count),
        .o_shaping_busy(shaping_busy),
        .o_scheduler_busy(scheduler_busy),
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

    task issue_direct_push;
        input integer leaf_id;
        input integer root_priority;
        input [DATA_WIDTH-1:0] data_value;
        begin
            @(negedge clk);
            direct_leaf_id = leaf_id[SCHED_LOGICAL_ID_WIDTH-1:0];
            direct_priority = root_priority[PTW-1:0];
            direct_packet_data = data_value;
            direct_push_valid = 1'b1;
            watchdog = 0;
            while (!direct_push_ready && watchdog < 8000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            check(direct_push_ready, "direct Push did not become ready");
            @(posedge clk);
            @(negedge clk);
            direct_push_valid = 1'b0;
            direct_leaf_id = 0;
            direct_priority = 0;
            direct_packet_data = 0;
        end
    endtask

    task issue_shaping_event;
        input integer shaping_id;
        input integer release_value;
        input integer parent_leaf_id;
        input integer root_priority;
        input [DATA_WIDTH-1:0] data_value;
        begin
            @(negedge clk);
            shaping_logical_id =
                shaping_id[SHAPING_LOGICAL_ID_WIDTH-1:0];
            shaping_release_time = release_value[TIME_WIDTH-1:0];
            shaping_parent_leaf_id =
                parent_leaf_id[SCHED_LOGICAL_ID_WIDTH-1:0];
            shaping_parent_priority = root_priority[PTW-1:0];
            shaping_packet_data = data_value;
            shaping_event_valid = 1'b1;
            watchdog = 0;
            while (!shaping_event_ready && watchdog < 8000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            check(shaping_event_ready,
                  "shaping event input did not become ready");
            @(posedge clk);
            @(negedge clk);
            shaping_event_valid = 1'b0;
            shaping_logical_id = 0;
            shaping_release_time = 0;
            shaping_parent_leaf_id = 0;
            shaping_parent_priority = 0;
            shaping_packet_data = 0;
        end
    endtask

    task issue_packet_pop;
        begin
            @(negedge clk);
            packet_pop_valid = 1'b1;
            watchdog = 0;
            while (!packet_pop_ready && watchdog < 8000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            check(packet_pop_ready, "packet Pop did not become ready");
            @(posedge clk);
            @(negedge clk);
            packet_pop_valid = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (arst_n) begin
            if (packet_out_valid && (output_count < 3)) begin
                output_data[output_count] = packet_out_data;
                output_leaf[output_count] = packet_out_leaf_id;
                output_count = output_count + 1;
            end
            if (shaping_to_parent_fire)
                shaping_fire_count = shaping_fire_count + 1;
            if (direct_to_parent_fire)
                direct_fire_count = direct_fire_count + 1;
            if (deferred_by_scheduling_pop)
                pop_priority_defer_count =
                    pop_priority_defer_count + 1;
            if (deferred_by_direct_push)
                push_priority_defer_count =
                    push_priority_defer_count + 1;
            if (deferred_by_parent_backpressure)
                parent_backpressure_defer_count =
                    parent_backpressure_defer_count + 1;
            if (shaping_to_parent_fire &&
                (direct_push_valid || packet_pop_valid)) begin
                $display("FAIL: shaping release bypassed scheduling priority");
                failures = failures + 1;
            end
        end
    end

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        wall_time = 0;
        shaping_event_valid = 1'b0;
        shaping_logical_id = 0;
        shaping_release_time = 0;
        shaping_parent_leaf_id = 0;
        shaping_parent_priority = 0;
        shaping_packet_data = 0;
        direct_push_valid = 1'b0;
        direct_leaf_id = 0;
        direct_priority = 0;
        direct_packet_data = 0;
        packet_pop_valid = 1'b0;
        failures = 0;
        watchdog = 0;
        output_count = 0;
        shaping_fire_count = 0;
        direct_fire_count = 0;
        pop_priority_defer_count = 0;
        push_priority_defer_count = 0;
        parent_backpressure_defer_count = 0;
        output_data[0] = 0;
        output_data[1] = 0;
        output_data[2] = 0;
        output_leaf[0] = 0;
        output_leaf[1] = 0;
        output_leaf[2] = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        arst_n = 1'b1;

        // Seed the work-conserving scheduler with one eligible packet.
        issue_direct_push(1, 5, PACKET_0);
        watchdog = 0;
        while (((scheduler_logical_count[0] != 1) ||
                (scheduler_logical_count[1] != 1)) &&
               watchdog < 12000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(scheduler_logical_count[0] == 1 &&
              scheduler_logical_count[1] == 1,
              "initial direct packet did not enter root and leaf");

        // Insert a future event.  Before time 20 it must not appear in the
        // parent scheduling PIFO even though the shaping queue is non-empty.
        issue_shaping_event(0, 20, 2, 20, SHAPED_PACKET);
        watchdog = 0;
        while ((shaping_logical_count[0] != 1) &&
               watchdog < 12000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(shaping_logical_count[0] == 1,
              "shaping event did not enter timing BMW tree");
        @(negedge clk);
        wall_time = 16'd19;
        repeat (50) @(posedge clk);
        check(shaping_fire_count == 0,
              "shaping event entered parent before release_time");
        check(scheduler_logical_count[0] == 1 &&
              scheduler_logical_count[2] == 0,
              "future shaping event became scheduler-visible early");

        // Wait until the timer Pop result is resident in ReleaseFIFO.  At the
        // immediately following edge, issue a real scheduler Pop.  It must
        // consume PACKET_0 while the shaping event remains queued.
        @(negedge clk);
        wall_time = 16'd20;
        watchdog = 0;
        while (!shaping_release_pending && watchdog < 16000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        check(shaping_release_pending,
              "due shaping event did not reach ReleaseFIFO");
        packet_pop_valid = 1'b1;
        #1;
        check(!shaping_to_parent_fire,
              "Pop-present cycle did not suppress shaping release");
        watchdog = 0;
        while (!packet_pop_ready && watchdog < 8000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        check(packet_pop_ready,
              "priority Pop could not enter packet scheduler");
        @(posedge clk);

        // Without opening a gap, replace the Pop with a direct Push.  Direct
        // scheduling traffic must again win over the pending shaping release.
        @(negedge clk);
        packet_pop_valid = 1'b0;
        wall_time = 16'd21;
        direct_leaf_id = 1;
        direct_priority = 16'd10;
        direct_packet_data = PACKET_1;
        direct_push_valid = 1'b1;
        watchdog = 0;
        while (!direct_push_ready && watchdog < 8000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        check(direct_push_ready,
              "priority direct Push could not enter packet scheduler");
        #1;
        check(!shaping_to_parent_fire,
              "direct-Push cycle did not suppress shaping release");
        @(posedge clk);
        @(negedge clk);
        direct_push_valid = 1'b0;
        direct_leaf_id = 0;
        direct_priority = 0;
        direct_packet_data = 0;
        wall_time = 16'd22;

        watchdog = 0;
        while ((shaping_fire_count != 1) && watchdog < 16000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(shaping_fire_count == 1,
              "shaping release was not eventually admitted to parent");
        check(pop_priority_defer_count > 0,
              "scheduler Pop priority was not observed");
        check(push_priority_defer_count > 0,
              "direct Push priority was not observed");
        check(shaping_deferred_cycles >= 2,
              "release deferral cycles were not recorded");
        check(release_delay_last >= 2 && release_delay_max >= 2,
              "release delay accounting missed arbitration delay");

        // Wait for the first Pop to finish before requesting the remaining
        // root-to-leaf operations.
        watchdog = 0;
        while ((output_count < 1) && watchdog < 20000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(output_count >= 1 && output_data[0] == PACKET_0 &&
              output_leaf[0] == 1,
              "priority Pop did not return the initial direct packet");

        watchdog = 0;
        while (((scheduler_logical_count[0] != 2) ||
                (scheduler_logical_count[1] != 1) ||
                (scheduler_logical_count[2] != 1) ||
                scheduler_busy) && watchdog < 20000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(scheduler_logical_count[0] == 2 &&
              scheduler_logical_count[1] == 1 &&
              scheduler_logical_count[2] == 1,
              "direct and shaped packets did not settle in parent tree");

        issue_packet_pop();
        watchdog = 0;
        while ((output_count < 2) && watchdog < 20000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        issue_packet_pop();
        watchdog = 0;
        while ((output_count < 3) && watchdog < 20000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(output_count == 3,
              "end-to-end scheduler did not return all packets");
        check(output_data[1] == PACKET_1 && output_leaf[1] == 1,
              "direct packet did not precede lower-priority shaped packet");
        check(output_data[2] == SHAPED_PACKET && output_leaf[2] == 2,
              "shaping release did not traverse parent root-to-leaf path");

        watchdog = 0;
        while (busy && watchdog < 20000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(!busy, "combined shaping/scheduling system did not quiesce");
        check(shaping_event_table_count == 0 &&
              shaping_release_fifo_count == 0 &&
              shaping_release_reserved == 0 &&
              shaping_completion_valid == 0,
              "shaping storage state did not fully drain");
        check(scheduler_pending_count == 0,
              "scheduler shared pending pool did not drain");
        for (logical_index = 0;
             logical_index < SCHED_LOGICAL_NUM;
             logical_index = logical_index + 1)
            check(scheduler_logical_count[logical_index] == 0,
                  "scheduler logical count did not return to zero");
        for (logical_index = 0;
             logical_index < SHAPING_LOGICAL_NUM;
             logical_index = logical_index + 1) begin
            check(shaping_logical_count[logical_index] == 0,
                  "shaping logical count did not return to zero");
            check(shaping_logical_pending_count[logical_index] == 0,
                  "shaping logical pending count did not return to zero");
        end
        check(!shaping_reject_bad_id &&
              !direct_reject_bad_leaf_id,
              "a valid event was rejected as a bad ID");
        check(!protocol_error, "combined protocol_error asserted");

        if (failures == 0) begin
            $display("PASS: Stage4.5 shaping-to-Stage28 scheduling test");
            $display("defer(pop/push/parent)=%0d/%0d/%0d delay=%0d max=%0d",
                     pop_priority_defer_count,
                     push_priority_defer_count,
                     parent_backpressure_defer_count,
                     release_delay_last, release_delay_max);
        end else begin
            $display("FAIL: Stage4.5 integration failures=%0d", failures);
            $fatal(1);
        end
        $finish;
    end

endmodule
