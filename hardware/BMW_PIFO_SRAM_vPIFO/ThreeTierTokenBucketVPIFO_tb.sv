`timescale 1ns / 10ps

module ThreeTierTokenBucketVPIFO_tb #(
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
    wire [SCHEDULE_PENDING_COUNT_WIDTH-1:0] schedule_pending_count;
    wire [9:0] schedule_logical_count [0:LOGICAL_TREE_NUM-1];
    wire timing_busy;
    wire schedule_busy;
    wire busy;
    wire protocol_error;

    integer watchdog;
    integer tx_count;
    integer release_count;
    integer output_count;
    integer init_rank;
    reg [TIME_WIDTH-1:0] eligibility_log [0:2];
    reg [TIME_WIDTH-1:0] actual_release_log [0:2];

    always #2 clk = ~clk;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n)
            wall_time <= 0;
        else
            wall_time <= wall_time + 1'b1;
    end

    ThreeTierTokenBucketVPIFO #(
        .PTW(PTW),
        .MTW(MTW),
        .TIME_WIDTH(TIME_WIDTH),
        .TRANSACTION_FLOW_NUM(1),
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
        .i_d_target_node_id(NODE_X),
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
        .o_direct_to_schedule_fire(),
        .o_shaping_release_pending(shaping_pending),
        .o_shaping_head_release_time(shaping_release_time),
        .o_shaping_deferred(),
        .o_deferred_by_direct_push(),
        .o_deferred_by_scheduling_pop(),
        .o_deferred_by_schedule_backpressure(),
        .o_shaping_deferred_cycles(),
        .o_release_delay_last(),
        .o_release_delay_max(),
        .o_timing_event_table_count(),
        .o_timing_release_fifo_count(),
        .o_schedule_logical_count(schedule_logical_count),
        .o_schedule_pending_count(schedule_pending_count),
        .o_schedule_outstanding_pop_count(),
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
        end else begin
            if (d_transaction_fire) begin
                if (tx_count >= 3)
                    $fatal(1, "unexpected extra D transaction");
                eligibility_log[tx_count] <= d_eligibility_time;
                tx_count <= tx_count + 1;
            end
            if (shaping_fire) begin
                if (release_count >= 3)
                    $fatal(1, "unexpected extra shaping release");
                if (wall_time < shaping_release_time)
                    $fatal(1, "D released before eligibility");
                actual_release_log[release_count] <= wall_time;
                release_count <= release_count + 1;
            end
            if (packet_out_valid)
                output_count <= output_count + 1;
        end
    end

    task automatic configure_empty_bucket;
        input [TIME_WIDTH-1:0] capacity;
        begin
            while (!token_cfg_ready)
                @(negedge clk);
            token_cfg_capacity = capacity;
            token_cfg_credit = 0;
            token_cfg_state_time = wall_time;
            token_cfg_state_valid = 1'b1;
            token_cfg_valid = 1'b1;
            @(negedge clk);
            token_cfg_valid = 1'b0;
        end
    endtask

    task automatic send_direct;
        input [1:0] target;
        input [14:0] packet_id;
        input [15:0] root_rank;
        input [15:0] x_rank;
        input [15:0] y_rank;
        input [15:0] z_rank;
        begin
            direct_target = target;
            direct_rank[0] = root_rank;
            direct_rank[1] = x_rank;
            direct_rank[2] = y_rank;
            direct_rank[3] = z_rank;
            direct_data = {1'b0, packet_id, 16'b0};
            direct_valid = 1'b1;
            @(posedge clk);
            while (!direct_ready)
                @(posedge clk);
            @(negedge clk);
            direct_valid = 1'b0;
        end
    endtask

    task automatic send_d;
        input [14:0] packet_id;
        input [15:0] x_rank;
        begin
            d_rank[0] = 16'd1;
            d_rank[1] = x_rank;
            d_rank[2] = 16'hffff;
            d_rank[3] = 16'hffff;
            d_data = {1'b0, packet_id, 16'b0};
            d_valid = 1'b1;
            @(posedge clk);
            while (!d_ready)
                @(posedge clk);
            @(negedge clk);
            d_valid = 1'b0;
        end
    endtask

    task automatic pop_and_expect;
        input [1:0] expected_node;
        input [14:0] expected_packet_id;
        begin
            while (!pop_ready)
                @(negedge clk);
            pop_valid = 1'b1;
            @(negedge clk);
            pop_valid = 1'b0;
            watchdog = 0;
            while (!packet_out_valid && (watchdog < 30000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (!packet_out_valid)
                $fatal(1, "timeout waiting for scheduled packet");
            if ((packet_out_node !== expected_node) ||
                (packet_out_data[30:16] !== expected_packet_id))
                $fatal(1,
                    "packet mismatch node=%0d/%0d id=%0d/%0d",
                    packet_out_node, expected_node,
                    packet_out_data[30:16], expected_packet_id);
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
        d_service_time = 32'd8;
        d_data = 0;
        direct_valid = 1'b0;
        direct_target = 0;
        direct_data = 0;
        pop_valid = 1'b0;
        for (init_rank = 0; init_rank < LOGICAL_TREE_NUM;
             init_rank = init_rank + 1) begin
            d_rank[init_rank] = 16'hffff;
            direct_rank[init_rank] = 16'hffff;
        end

        repeat (8) @(negedge clk);
        arst_n = 1'b1;
        repeat (4) @(negedge clk);

        // An explicitly empty bucket makes even D's first packet wait.
        configure_empty_bucket(32'd16);

        send_direct(NODE_ROOT, 15'd6, 16'd0,
                    16'hffff, 16'hffff, 16'hffff); // F
        send_direct(NODE_X, 15'd5, 16'd1,
                    16'd5, 16'hffff, 16'hffff);    // E
        send_direct(NODE_Z, 15'd1, 16'd2,
                    16'hffff, 16'd10, 16'd0);      // A
        send_direct(NODE_Y, 15'd3, 16'd2,
                    16'hffff, 16'd20, 16'hffff);   // C
        send_direct(NODE_Z, 15'd2, 16'd2,
                    16'hffff, 16'd30, 16'd1);      // B

        send_d(15'd4, 16'd10); // D0
        send_d(15'd7, 16'd20); // D1
        send_d(15'd8, 16'd30); // D2

        if (tx_count != 3)
            $fatal(1, "D transactions were not accepted");
        if (!((eligibility_log[0] < eligibility_log[1]) &&
              (eligibility_log[1] < eligibility_log[2])))
            $fatal(1, "Token-Bucket eligibility order is not strict");

        // Before the first eligibility time, X contains E only.
        while (wall_time + 1 < eligibility_log[0])
            @(negedge clk);
        if (release_count != 0)
            $fatal(1, "D was released before its first eligibility time");

        watchdog = 0;
        while ((release_count != 3) && (watchdog < 30000)) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (release_count != 3)
            $fatal(1, "timeout waiting for all D releases");
        repeat (2) @(negedge clk);
        if ((actual_release_log[0] < eligibility_log[0]) ||
            (actual_release_log[1] < eligibility_log[1]) ||
            (actual_release_log[2] < eligibility_log[2]))
            $fatal(1, "actual D admission violated eligibility");

        watchdog = 0;
        while ((schedule_pending_count != 0 || schedule_busy) &&
               (watchdog < 30000)) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (watchdog == 30000)
            $fatal(1, "timeout draining schedule Push operations");
        if ((schedule_logical_count[0] != 8) ||
            (schedule_logical_count[1] != 4) ||
            (schedule_logical_count[2] != 3) ||
            (schedule_logical_count[3] != 2))
            $fatal(1, "wrong counts after D release: %0d %0d %0d %0d",
                schedule_logical_count[0], schedule_logical_count[1],
                schedule_logical_count[2], schedule_logical_count[3]);

        // Root SP, X WFQ ranks, Y WFQ ranks, and Z SP ranks all participate.
        pop_and_expect(NODE_ROOT, 15'd6); // F
        pop_and_expect(NODE_X, 15'd5);    // E
        pop_and_expect(NODE_X, 15'd4);    // D0
        pop_and_expect(NODE_X, 15'd7);    // D1
        pop_and_expect(NODE_X, 15'd8);    // D2
        pop_and_expect(NODE_Z, 15'd1);    // A
        pop_and_expect(NODE_Y, 15'd3);    // C
        pop_and_expect(NODE_Z, 15'd2);    // B

        watchdog = 0;
        while (busy && (watchdog < 30000)) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        // The output counter samples the registered one-cycle pulse at the
        // following edge; allow that final accounting edge to retire.
        repeat (2) @(negedge clk);
        if (|{schedule_logical_count[0], schedule_logical_count[1],
              schedule_logical_count[2], schedule_logical_count[3]})
            $fatal(1, "schedule domain did not drain");
        if (timing_busy)
            $fatal(1, "timing domain did not drain");
        if (output_count != 8)
            $fatal(1, "expected 8 outputs, got %0d", output_count);
        if (protocol_error)
            $fatal(1,
                "three-tier Token-Bucket protocol_error local=%b tx=%b timing=%b(tlocal=%b tcore=%b table=%b fifo=%b) schedule=%b recursive_local=%b core=%b",
                dut.local_protocol_error,
                dut.transaction_engine_protocol_error,
                dut.timing_protocol_error,
                dut.timing_domain.local_protocol_error,
                dut.timing_domain.core_protocol_error,
                dut.timing_domain.event_table_protocol_error,
                dut.timing_domain.release_fifo_overflow,
                dut.scheduler_protocol_error,
                dut.schedule_domain.local_protocol_error,
                dut.schedule_domain.core_protocol_error);

        $display("PASS: D Token Bucket -> timing BMW -> X -> Root");
        $display("D_ELIGIBILITY,%0d,%0d,%0d",
            eligibility_log[0], eligibility_log[1], eligibility_log[2]);
        $display("D_ACTUAL_RELEASE,%0d,%0d,%0d",
            actual_release_log[0], actual_release_log[1],
            actual_release_log[2]);
        $finish;
    end

    initial begin
        repeat (300000) @(posedge clk);
        $fatal(1, "timeout");
    end
endmodule
