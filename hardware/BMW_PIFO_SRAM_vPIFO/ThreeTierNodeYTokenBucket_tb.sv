`timescale 1ns / 10ps

// Node-level shaping regression.
//
// The instance under test uses SHAPED_TARGET_NODE=Y.  The four transactions
// below alternate C/Z representative packets, but they all share one timing
// and Token-Bucket context.  This is intentionally aggregate Y shaping; it is
// not per-flow shaping inside the Y scheduling node.
module ThreeTierNodeYTokenBucket_tb #(
    parameter integer SCHEDULE_PENDING_DEPTH = 32,
    parameter integer SCHEDULE_POP_TRACK_DEPTH = 32
);
    localparam PTW = 16;
    localparam MTW = 16;
    localparam DATA_WIDTH = PTW + MTW;
    localparam TIME_WIDTH = 32;
    localparam LOGICAL_TREE_NUM = 4;
    localparam SCHEDULE_PENDING_COUNT_WIDTH =
        (SCHEDULE_PENDING_DEPTH <= 1) ? 1 :
        $clog2(SCHEDULE_PENDING_DEPTH + 1);
    localparam SCHEDULE_TRACK_COUNT_WIDTH =
        (SCHEDULE_POP_TRACK_DEPTH <= 1) ? 1 :
        $clog2(SCHEDULE_POP_TRACK_DEPTH + 1);
    localparam PACKETS = 4;
    localparam TOTAL_SHAPED_PACKETS = PACKETS + 1;
    localparam SERVICE_TIME = 150;
    localparam PACKET_BITS = 1500 * 8;
    localparam CLOCK_HZ = 125000000;
    localparam [1:0] NODE_ROOT = 2'd0;
    localparam [1:0] NODE_X = 2'd1;
    localparam [1:0] NODE_Y = 2'd2;
    localparam [1:0] NODE_Z = 2'd3;

    reg clk;
    reg arst_n;
    reg [TIME_WIDTH-1:0] wall_time;
    reg token_cfg_valid;
    wire token_cfg_ready;
    reg token_cfg_state_valid;
    reg [TIME_WIDTH-1:0] token_cfg_capacity;
    reg [TIME_WIDTH-1:0] token_cfg_credit;
    reg [TIME_WIDTH-1:0] token_cfg_state_time;

    reg d_valid;
    wire d_ready;
    reg [1:0] d_target;
    reg [TIME_WIDTH-1:0] d_service_time;
    reg [PTW-1:0] d_rank [0:LOGICAL_TREE_NUM-1];
    reg [DATA_WIDTH-1:0] d_data;
    wire d_transaction_fire;
    wire [TIME_WIDTH-1:0] d_eligibility_time;

    reg direct_valid;
    wire direct_ready;
    reg [1:0] direct_target;
    reg [PTW-1:0] direct_rank [0:LOGICAL_TREE_NUM-1];
    reg [DATA_WIDTH-1:0] direct_data;

    reg pop_valid;
    wire pop_ready;
    wire packet_out_valid;
    wire [1:0] packet_out_node;
    wire [DATA_WIDTH-1:0] packet_out_data;
    wire shaping_fire;
    wire shaping_pending;
    wire [TIME_WIDTH-1:0] shaping_release_time;
    wire direct_fire;
    wire shaping_deferred;
    wire deferred_by_direct_push;
    wire [31:0] shaping_deferred_cycles;
    wire [5:0] timing_event_count;
    wire [4:0] timing_release_count;
    wire [9:0] schedule_logical_count [0:LOGICAL_TREE_NUM-1];
    wire [SCHEDULE_PENDING_COUNT_WIDTH-1:0] schedule_pending_count;
    wire [SCHEDULE_TRACK_COUNT_WIDTH-1:0] schedule_outstanding_count;
    wire timing_busy;
    wire schedule_busy;
    wire busy;
    wire protocol_error;

    integer init_index;
    integer tx_count;
    integer release_count;
    integer output_count;
    integer direct_fire_count;
    integer direct_deferred_count;
    integer watchdog;
    integer blocker_fire_base;
    integer accepted_blockers;
    longint eligibility_rate_bps;
    longint actual_rate_bps;
    longint rate_numerator;
    longint eligibility_duration;
    longint actual_duration;
    reg [TIME_WIDTH-1:0]
        eligibility_log [0:TOTAL_SHAPED_PACKETS-1];
    reg [TIME_WIDTH-1:0]
        release_log [0:TOTAL_SHAPED_PACKETS-1];

    always #4 clk = ~clk;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n)
            wall_time <= {TIME_WIDTH{1'b0}};
        else
            wall_time <= wall_time + 1'b1;
    end

    ThreeTierTokenBucketVPIFO #(
        .PTW(PTW),
        .MTW(MTW),
        .TIME_WIDTH(TIME_WIDTH),
        .TRANSACTION_FLOW_NUM(1),
        .SPLIT_SHAPING(1),
        .SHAPED_TARGET_NODE(2),
        .SCHEDULE_PENDING_DEPTH(SCHEDULE_PENDING_DEPTH),
        .SCHEDULE_POP_TRACK_DEPTH(SCHEDULE_POP_TRACK_DEPTH),
        .TIMING_EVENT_TABLE_DEPTH(32),
        .TIMING_RELEASE_FIFO_DEPTH(16)
    ) dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_time(wall_time),
        .i_token_cfg_valid(token_cfg_valid),
        .o_token_cfg_ready(token_cfg_ready),
        .i_token_cfg_flow_id(1'b0),
        .i_token_cfg_enable(1'b1),
        .i_token_cfg_bucket_capacity_time(token_cfg_capacity),
        .i_token_cfg_bucket_state_valid(token_cfg_state_valid),
        .i_token_cfg_bucket_credit_time(token_cfg_credit),
        .i_token_cfg_bucket_state_time(token_cfg_state_time),
        .o_token_cfg_reject_bad_flow_id(),
        .i_d_valid(d_valid),
        .o_d_ready(d_ready),
        .i_d_flow_id(1'b0),
        .i_d_target_node_id(d_target),
        .i_d_packet_service_time(d_service_time),
        .i_d_rank_by_node(d_rank),
        .i_d_packet_data(d_data),
        .o_d_transaction_fire(d_transaction_fire),
        .o_d_eligibility_time(d_eligibility_time),
        .o_d_reject_bad_flow_id(),
        .o_d_reject_unconfigured(),
        .i_direct_valid(direct_valid),
        .o_direct_ready(direct_ready),
        .i_direct_target_node_id(direct_target),
        .i_direct_rank_by_node(direct_rank),
        .i_direct_packet_data(direct_data),
        .o_direct_reject_bad_path(),
        .i_packet_pop_valid(pop_valid),
        .o_packet_pop_ready(pop_ready),
        .o_packet_out_valid(packet_out_valid),
        .o_packet_out_node_id(packet_out_node),
        .o_packet_out_data(packet_out_data),
        .o_shaping_to_schedule_fire(shaping_fire),
        .o_direct_to_schedule_fire(direct_fire),
        .o_shaping_release_pending(shaping_pending),
        .o_shaping_head_release_time(shaping_release_time),
        .o_shaping_deferred(shaping_deferred),
        .o_deferred_by_direct_push(deferred_by_direct_push),
        .o_deferred_by_scheduling_pop(),
        .o_deferred_by_schedule_backpressure(),
        .o_shaping_deferred_cycles(shaping_deferred_cycles),
        .o_release_delay_last(),
        .o_release_delay_max(),
        .o_timing_event_table_count(timing_event_count),
        .o_timing_release_fifo_count(timing_release_count),
        .o_schedule_logical_count(schedule_logical_count),
        .o_schedule_pending_count(schedule_pending_count),
        .o_schedule_outstanding_pop_count(schedule_outstanding_count),
        .o_schedule_physical_dispatch_fire(),
        .o_schedule_physical_dispatch_push(),
        .o_schedule_selected_physical_tree_id(),
        .o_schedule_shard_count(),
        .o_timing_busy(timing_busy),
        .o_schedule_busy(schedule_busy),
        .o_busy(busy),
        .o_protocol_error(protocol_error)
    );

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            tx_count <= 0;
            release_count <= 0;
            output_count <= 0;
            direct_fire_count <= 0;
            direct_deferred_count <= 0;
        end else begin
            if (d_transaction_fire) begin
                if (tx_count >= TOTAL_SHAPED_PACKETS)
                    $fatal(1, "node-Y transaction log overflow");
                eligibility_log[tx_count] <= d_eligibility_time;
                tx_count <= tx_count + 1;
            end
            if (shaping_fire) begin
                if (release_count >= TOTAL_SHAPED_PACKETS)
                    $fatal(1, "node-Y release log overflow");
                if (wall_time < shaping_release_time)
                    $fatal(1, "Y admitted before aggregate eligibility");
                release_log[release_count] <= wall_time;
                release_count <= release_count + 1;
            end
            if (direct_fire)
                direct_fire_count <= direct_fire_count + 1;
            if (deferred_by_direct_push)
                direct_deferred_count <= direct_deferred_count + 1;
            if (packet_out_valid)
                output_count <= output_count + 1;
        end
    end

    task automatic configure_empty_bucket;
        begin
            while (!token_cfg_ready)
                @(negedge clk);
            token_cfg_capacity = 0;
            token_cfg_credit = 0;
            token_cfg_state_time = wall_time;
            token_cfg_state_valid = 1'b1;
            token_cfg_valid = 1'b1;
            @(negedge clk);
            token_cfg_valid = 1'b0;
        end
    endtask

    task automatic send_y_packet;
        input [1:0] target;
        input [14:0] packet_id;
        input [15:0] y_rank;
        input [15:0] z_rank;
        begin
            // C targets Y directly; A/B target Z and stop at Y.  All share
            // the same aggregate Y Token Bucket context.
            d_target = target;
            d_rank[0] = 16'd1;
            d_rank[1] = 16'hffff;
            d_rank[2] = y_rank;
            d_rank[3] = z_rank;
            d_data = {1'b0, packet_id, 16'b0};
            d_valid = 1'b1;
            @(posedge clk);
            while (!d_ready)
                @(posedge clk);
            @(negedge clk);
            d_valid = 1'b0;
        end
    endtask

    task automatic send_direct_x;
        input [14:0] packet_id;
        begin
            direct_target = NODE_X;
            direct_rank[0] = 16'd0;
            direct_rank[1] = 16'd0;
            direct_rank[2] = 16'hffff;
            direct_rank[3] = 16'hffff;
            direct_data = {1'b0, packet_id, 16'b0};
            direct_valid = 1'b1;
            @(posedge clk);
            while (!direct_ready)
                @(posedge clk);
            @(negedge clk);
            direct_valid = 1'b0;
        end
    endtask

    task automatic pop_and_expect_y_subtree;
        input [1:0] expected_node;
        input [14:0] packet_id;
        begin
            while (!pop_ready)
                @(negedge clk);
            pop_valid = 1'b1;
            @(negedge clk);
            pop_valid = 1'b0;
            watchdog = 0;
            while (!packet_out_valid && (watchdog < 100000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (!packet_out_valid)
                $fatal(1, "timeout waiting for node-Y output");
            if ((packet_out_node !== expected_node) ||
                (packet_out_data[30:16] !== packet_id))
                $fatal(1, "Y-subtree packet mismatch node=%0d/%0d id=%0d/%0d",
                    packet_out_node, expected_node,
                    packet_out_data[30:16], packet_id);
        end
    endtask

    task automatic pop_and_expect_x;
        input [14:0] packet_id;
        begin
            while (!pop_ready)
                @(negedge clk);
            pop_valid = 1'b1;
            @(negedge clk);
            pop_valid = 1'b0;
            watchdog = 0;
            while (!packet_out_valid && (watchdog < 100000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (!packet_out_valid)
                $fatal(1, "timeout waiting for independent X output");
            if ((packet_out_node !== NODE_X) ||
                (packet_out_data[30:16] !== packet_id))
                $fatal(1, "independent X packet was affected by Y shaping");
        end
    endtask

    task automatic pop_and_expect_root;
        input [14:0] packet_id;
        begin
            while (!pop_ready)
                @(negedge clk);
            pop_valid = 1'b1;
            @(negedge clk);
            pop_valid = 1'b0;
            watchdog = 0;
            while (!packet_out_valid && (watchdog < 100000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (!packet_out_valid)
                $fatal(1, "timeout waiting for root blocker output");
            if ((packet_out_node !== NODE_ROOT) ||
                (packet_out_data[30:16] !== packet_id))
                $fatal(1, "root blocker packet mismatch");
        end
    endtask

    task automatic wait_for_empty_domains;
        begin
            watchdog = 0;
            while ((busy || timing_busy || schedule_busy ||
                    (timing_event_count != 0) ||
                    (timing_release_count != 0) ||
                    (schedule_pending_count != 0) ||
                    (schedule_outstanding_count != 0) ||
                    (schedule_logical_count[NODE_ROOT] != 0) ||
                    (schedule_logical_count[NODE_X] != 0) ||
                    (schedule_logical_count[NODE_Y] != 0) ||
                    (schedule_logical_count[NODE_Z] != 0)) &&
                   (watchdog < 100000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (watchdog == 100000)
                $fatal(1,
                    "timeout waiting for empty Timing/Scheduling domains");
        end
    endtask

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        wall_time = 0;
        token_cfg_valid = 1'b0;
        token_cfg_state_valid = 1'b0;
        token_cfg_capacity = 0;
        token_cfg_credit = 0;
        token_cfg_state_time = 0;
        d_valid = 1'b0;
        d_target = NODE_Y;
        d_service_time = SERVICE_TIME;
        d_data = 0;
        direct_valid = 1'b0;
        direct_target = NODE_ROOT;
        direct_data = 0;
        pop_valid = 1'b0;
        for (init_index = 0; init_index < LOGICAL_TREE_NUM;
             init_index = init_index + 1) begin
            d_rank[init_index] = 16'hffff;
            direct_rank[init_index] = 16'hffff;
        end

        repeat (8) @(negedge clk);
        arst_n = 1'b1;
        repeat (4) @(negedge clk);
        configure_empty_bucket();

        // X is independently active while the aggregate Y node is hidden.
        send_direct_x(15'd90);
        send_y_packet(NODE_Y, 15'd1, 16'd10, 16'hffff); // C
        send_y_packet(NODE_Z, 15'd2, 16'd20, 16'd0);    // A in Z
        send_y_packet(NODE_Y, 15'd3, 16'd30, 16'hffff); // C
        send_y_packet(NODE_Z, 15'd4, 16'd40, 16'd1);    // B in Z

        if (tx_count != PACKETS)
            $fatal(1, "expected %0d Y transactions, got %0d",
                PACKETS, tx_count);
        watchdog = 0;
        while ((schedule_logical_count[NODE_ROOT] != 1 ||
                schedule_logical_count[NODE_Y] != PACKETS ||
                schedule_logical_count[NODE_Z] != 2) &&
               (release_count == 0) && (watchdog < 10000)) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if ((release_count != 0) ||
            (schedule_logical_count[NODE_Y] != PACKETS) ||
            (schedule_logical_count[NODE_Z] != 2) ||
            (schedule_logical_count[NODE_ROOT] != 1))
            $fatal(1, "local Y subtree did not settle before release: Root=%0d Y=%0d Z=%0d releases=%0d",
                schedule_logical_count[NODE_ROOT],
                schedule_logical_count[NODE_Y],
                schedule_logical_count[NODE_Z], release_count);

        while (release_count != PACKETS)
            @(negedge clk);
        for (init_index = 1; init_index < PACKETS; init_index = init_index + 1)
            if ((eligibility_log[init_index] -
                 eligibility_log[init_index - 1]) != SERVICE_TIME)
                $fatal(1, "aggregate Y eligibility gap mismatch at %0d",
                    init_index);
        for (init_index = 0; init_index < PACKETS; init_index = init_index + 1)
            if (release_log[init_index] < eligibility_log[init_index])
                $fatal(1, "aggregate Y release preceded eligibility at %0d",
                    init_index);

        watchdog = 0;
        while ((schedule_logical_count[NODE_Y] != PACKETS ||
                schedule_logical_count[NODE_Z] != 2 ||
                schedule_logical_count[NODE_ROOT] != (PACKETS + 1) ||
                schedule_busy || timing_busy) && (watchdog < 100000)) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (watchdog == 100000)
            $fatal(1, "timeout waiting for Y scheduling admission");

        // Root rank 0 sends the independent X packet first.  It must not be
        // delayed by the Y timing domain.
        pop_and_expect_x(15'd90);
        pop_and_expect_y_subtree(NODE_Y, 15'd1);
        pop_and_expect_y_subtree(NODE_Z, 15'd2);
        pop_and_expect_y_subtree(NODE_Y, 15'd3);
        pop_and_expect_y_subtree(NODE_Z, 15'd4);

        wait_for_empty_domains();
        rate_numerator = PACKETS - 1;
        rate_numerator = rate_numerator * PACKET_BITS * CLOCK_HZ;
        eligibility_duration =
            longint'(eligibility_log[PACKETS - 1]) -
            longint'(eligibility_log[0]);
        actual_duration = longint'(release_log[PACKETS - 1]) -
            longint'(release_log[0]);
        eligibility_rate_bps = rate_numerator / eligibility_duration;
        actual_rate_bps = rate_numerator / actual_duration;
        if ((eligibility_rate_bps != 64'd10000000000) ||
            (actual_rate_bps != 64'd10000000000))
            $fatal(1,
                "aggregate Y 1500B rate mismatch eligibility=%0d actual=%0d",
                eligibility_rate_bps, actual_rate_bps);

        // Reconfigure the aggregate bucket and queue one more Y packet.  Its
        // local scheduling element is resident before Root can see REF(Y).
        // Sustained direct Root Pushes then hold an already-due release in the
        // Timing-to-Scheduling ready/valid path.
        configure_empty_bucket();
        send_y_packet(NODE_Y, 15'd5, 16'd50, 16'hffff);
        watchdog = 0;
        while (((schedule_logical_count[NODE_Y] != 1) ||
                (schedule_logical_count[NODE_ROOT] != 0) ||
                (timing_event_count == 0)) && (watchdog < 100000)) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (watchdog == 100000)
            $fatal(1, "split Y packet did not reach local/timing domains");

        direct_target = NODE_ROOT;
        direct_rank[0] = 16'd0;
        direct_rank[1] = 16'hffff;
        direct_rank[2] = 16'hffff;
        direct_rank[3] = 16'hffff;
        direct_data = {1'b0, 15'd91, 16'b0};
        blocker_fire_base = direct_fire_count;
        direct_valid = 1'b1;
        watchdog = 0;
        while (!shaping_pending && (watchdog < 100000)) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (watchdog == 100000)
            $fatal(1, "timeout waiting for blocked due Y release");
        repeat (8) @(negedge clk);
        if ((release_count != PACKETS) || !shaping_deferred ||
            (direct_deferred_count == 0) ||
            (timing_release_count == 0))
            $fatal(1,
                "due Y release was not retained under direct priority");
        direct_valid = 1'b0;
        accepted_blockers = direct_fire_count - blocker_fire_base;
        if (accepted_blockers == 0)
            $fatal(1, "direct-priority phase accepted no blocker");

        watchdog = 0;
        while ((release_count != TOTAL_SHAPED_PACKETS) &&
               (watchdog < 100000)) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (watchdog == 100000)
            $fatal(1, "blocked Y release never resumed");
        if (release_log[PACKETS] < eligibility_log[PACKETS])
            $fatal(1, "contended Y release preceded eligibility");

        watchdog = 0;
        while (((schedule_logical_count[NODE_ROOT] !=
                 (accepted_blockers[9:0] + 10'd1)) ||
                schedule_busy || timing_busy) &&
               (watchdog < 100000)) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (watchdog == 100000)
            $fatal(1, "contended Y release did not settle in Root");
        for (init_index = 0; init_index < accepted_blockers;
             init_index = init_index + 1)
            pop_and_expect_root(15'd91);
        pop_and_expect_y_subtree(NODE_Y, 15'd5);
        wait_for_empty_domains();

        repeat (3) @(negedge clk);
        if (output_count != PACKETS + accepted_blockers + 2)
            $fatal(1, "expected %0d outputs, got %0d",
                PACKETS + accepted_blockers + 2, output_count);
        if ((tx_count != TOTAL_SHAPED_PACKETS) ||
            (release_count != TOTAL_SHAPED_PACKETS))
            $fatal(1, "Y exactly-once mismatch tx=%0d release=%0d",
                tx_count, release_count);
        if (protocol_error)
            $fatal(1, "node-Y Token Bucket protocol_error");

        $display("PASS: aggregate Y Token Bucket shaping, rate, arbitration, and drain");
        $display("Y_RATE,packet_bytes=1500,target_bps=10000000000,eligibility_bps=%0d,actual_bps=%0d",
            eligibility_rate_bps, actual_rate_bps);
        $display("Y_ELIGIBILITY,%0d,%0d,%0d,%0d",
            eligibility_log[0], eligibility_log[1],
            eligibility_log[2], eligibility_log[3]);
        $display("Y_ACTUAL_RELEASE,%0d,%0d,%0d,%0d",
            release_log[0], release_log[1], release_log[2], release_log[3]);
        $display("Y_ARBITRATION,direct_blockers=%0d,deferred_cycles=%0d,contended_eligibility=%0d,contended_release=%0d",
            accepted_blockers, shaping_deferred_cycles,
            eligibility_log[PACKETS], release_log[PACKETS]);
        $finish;
    end

    initial begin
        repeat (300000) @(posedge clk);
        $fatal(1, "node-Y Token Bucket timeout");
    end
endmodule
