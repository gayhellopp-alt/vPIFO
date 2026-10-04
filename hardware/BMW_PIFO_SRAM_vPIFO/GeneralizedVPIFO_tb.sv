`timescale 1ns / 1ps

// Stages 2-4 integration test:
//   global typed IDs -> two domain-local layouts -> static timing release edge
//   -> schedule root/leaf recursion.  Two timing nodes expire together and a
//   normal schedule Push is deliberately accepted while release is pending.
module GeneralizedVPIFO_tb;

    localparam PTW = 16;
    localparam MTW = 16;
    localparam DATA_WIDTH = PTW + MTW;
    localparam TIME_WIDTH = 16;
    localparam FLOW_NUM = 4;
    localparam FLOW_ID_WIDTH = 2;
    localparam GLOBAL_ID_WIDTH =
        GeneralizedVpifoConfigPkg::GLOBAL_ID_WIDTH;
    localparam SCHEDULE_NUM =
        GeneralizedVpifoConfigPkg::SCHEDULE_LOGICAL_TREE_NUM;
    localparam TIMING_NUM =
        GeneralizedVpifoConfigPkg::TIMING_LOGICAL_TREE_NUM;
    localparam SCHEDULE_COUNT_WIDTH = 7;
    localparam TIMING_COUNT_WIDTH = 7;
    localparam SCHEDULE_PENDING_COUNT_WIDTH = 4;
    localparam TIMING_PENDING_COUNT_WIDTH = 4;

    localparam [GLOBAL_ID_WIDTH-1:0] ROOT = 0;
    localparam [GLOBAL_ID_WIDTH-1:0] LEAF_A = 1;
    localparam [GLOBAL_ID_WIDTH-1:0] LEAF_B = 2;
    localparam [GLOBAL_ID_WIDTH-1:0] SHAPE_A = 3;
    localparam [GLOBAL_ID_WIDTH-1:0] SHAPE_B = 4;
    localparam [DATA_WIDTH-1:0] DIRECT_PACKET = 32'h6100_0001;
    localparam [DATA_WIDTH-1:0] SHAPED_A = 32'h6200_0002;
    localparam [DATA_WIDTH-1:0] SHAPED_B = 32'h6300_0003;

    reg clk;
    reg arst_n;
    reg [TIME_WIDTH-1:0] wall_time;

    reg cfg_valid;
    wire cfg_ready;
    reg [FLOW_ID_WIDTH-1:0] cfg_flow_id;
    reg cfg_enable;
    reg [2:0] cfg_mode;
    reg [TIME_WIDTH-1:0] cfg_service_time;
    reg cfg_state_valid;
    reg [TIME_WIDTH-1:0] cfg_next_release;
    reg [TIME_WIDTH-1:0] cfg_bucket_capacity_time;
    reg cfg_bucket_state_valid;
    reg [TIME_WIDTH-1:0] cfg_bucket_credit_time;
    reg [TIME_WIDTH-1:0] cfg_bucket_state_time;
    wire cfg_reject;

    reg transaction_valid;
    wire transaction_ready;
    reg [FLOW_ID_WIDTH-1:0] transaction_flow_id;
    reg [GLOBAL_ID_WIDTH-1:0] transaction_timing_node_id;
    reg [TIME_WIDTH-1:0] transaction_service_time;
    reg [TIME_WIDTH-1:0] transaction_absolute_time;
    reg [PTW-1:0] transaction_priority;
    reg [DATA_WIDTH-1:0] transaction_data;
    wire transaction_reject_flow;
    wire transaction_reject_unconfigured;
    wire transaction_reject_route;
    wire transaction_fire;
    wire [TIME_WIDTH-1:0] transaction_release_time;
    wire [TIME_WIDTH-1:0] transaction_next_release_time;
    wire transaction_map_valid;
    wire transaction_timing_local_id;
    wire [1:0] transaction_release_schedule_local_id;
    wire [2:0] transaction_declared_program_mode;

    reg direct_valid;
    wire direct_ready;
    reg [GLOBAL_ID_WIDTH-1:0] direct_schedule_node_id;
    reg [PTW-1:0] direct_priority;
    reg [DATA_WIDTH-1:0] direct_data;
    wire direct_reject;
    wire direct_map_valid;
    wire [1:0] direct_schedule_local_id;

    reg packet_pop_valid;
    wire packet_pop_ready;
    wire packet_out_valid;
    wire [GLOBAL_ID_WIDTH-1:0] packet_out_node_id;
    wire [DATA_WIDTH-1:0] packet_out_data;

    wire timing_to_schedule_fire;
    wire direct_to_schedule_fire;
    wire timing_release_pending;
    wire timing_deferred;
    wire deferred_by_direct_push;
    wire deferred_by_scheduling_pop;
    wire deferred_by_schedule_backpressure;
    wire [31:0] timing_deferred_cycles;
    wire [TIME_WIDTH-1:0] release_delay_last;
    wire [TIME_WIDTH-1:0] release_delay_max;
    wire [4:0] timing_event_table_count;
    wire [3:0] timing_release_fifo_count;
    wire [TIMING_COUNT_WIDTH-1:0]
        timing_logical_count [0:TIMING_NUM-1];
    wire [TIMING_PENDING_COUNT_WIDTH-1:0]
        timing_logical_pending_count [0:TIMING_NUM-1];
    wire [SCHEDULE_COUNT_WIDTH-1:0]
        schedule_logical_count [0:SCHEDULE_NUM-1];
    wire [SCHEDULE_PENDING_COUNT_WIDTH-1:0]
        schedule_pending_count;
    wire timing_busy;
    wire schedule_busy;
    wire busy;
    wire protocol_error;

    integer failures;
    integer watchdog;
    integer timing_release_count;
    integer output_count;
    integer deferred_by_direct_count;
    integer index;
    reg [TIME_WIDTH-1:0] actual_release_time [0:1];
    reg [DATA_WIDTH-1:0] output_data [0:2];
    reg [GLOBAL_ID_WIDTH-1:0] output_node [0:2];

    GeneralizedVPIFO #(
        .PTW(PTW),
        .MTW(MTW),
        .TIME_WIDTH(TIME_WIDTH),
        .TRANSACTION_FLOW_NUM(FLOW_NUM),
        .TIMING_EVENT_TABLE_DEPTH(16),
        .TIMING_RELEASE_FIFO_DEPTH(8),
        .TIMING_RELEASE_ISSUE_PORTS(2)
    ) dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_time(wall_time),
        .i_transaction_cfg_valid(cfg_valid),
        .o_transaction_cfg_ready(cfg_ready),
        .i_transaction_cfg_flow_id(cfg_flow_id),
        .i_transaction_cfg_enable(cfg_enable),
        .i_transaction_cfg_mode(cfg_mode),
        .i_transaction_cfg_default_service_time(cfg_service_time),
        .i_transaction_cfg_state_valid(cfg_state_valid),
        .i_transaction_cfg_next_release_time(cfg_next_release),
        .i_transaction_cfg_bucket_capacity_time(cfg_bucket_capacity_time),
        .i_transaction_cfg_bucket_state_valid(cfg_bucket_state_valid),
        .i_transaction_cfg_bucket_credit_time(cfg_bucket_credit_time),
        .i_transaction_cfg_bucket_state_time(cfg_bucket_state_time),
        .o_transaction_cfg_reject_bad_flow_id(cfg_reject),
        .i_transaction_valid(transaction_valid),
        .o_transaction_ready(transaction_ready),
        .i_transaction_flow_id(transaction_flow_id),
        .i_transaction_timing_node_id(transaction_timing_node_id),
        .i_transaction_packet_service_time(transaction_service_time),
        .i_transaction_absolute_release_time(transaction_absolute_time),
        .i_transaction_parent_priority(transaction_priority),
        .i_transaction_packet_data(transaction_data),
        .o_transaction_reject_bad_flow_id(transaction_reject_flow),
        .o_transaction_reject_unconfigured(
            transaction_reject_unconfigured),
        .o_transaction_reject_bad_route(transaction_reject_route),
        .o_transaction_fire(transaction_fire),
        .o_transaction_release_time(transaction_release_time),
        .o_transaction_next_release_time(transaction_next_release_time),
        .o_transaction_bucket_credit_time(),
        .o_transaction_bucket_state_time(),
        .o_transaction_map_valid(transaction_map_valid),
        .o_transaction_timing_local_id(transaction_timing_local_id),
        .o_transaction_release_schedule_local_id(
            transaction_release_schedule_local_id),
        .o_transaction_declared_program_mode(
            transaction_declared_program_mode),
        .i_transaction_state_read_flow_id(2'd0),
        .o_transaction_state_read_configured(),
        .o_transaction_state_read_mode(),
        .o_transaction_state_read_default_service_time(),
        .o_transaction_state_read_valid(),
        .o_transaction_state_read_next_release_time(),
        .o_transaction_state_read_bucket_valid(),
        .o_transaction_state_read_bucket_capacity_time(),
        .o_transaction_state_read_bucket_credit_time(),
        .o_transaction_state_read_bucket_state_time(),
        .o_transaction_count(),
        .o_rejected_transaction_count(),
        .o_late_absolute_count(),
        .o_saturated_time_count(),
        .o_configured_flow_count(),
        .i_direct_push_valid(direct_valid),
        .o_direct_push_ready(direct_ready),
        .i_direct_schedule_node_id(direct_schedule_node_id),
        .i_direct_priority(direct_priority),
        .i_direct_packet_data(direct_data),
        .o_direct_reject_bad_schedule_node(direct_reject),
        .o_direct_map_valid(direct_map_valid),
        .o_direct_schedule_local_id(direct_schedule_local_id),
        .i_packet_pop_valid(packet_pop_valid),
        .i_packet_pop_schedule_root_node_id(ROOT),
        .o_packet_pop_ready(packet_pop_ready),
        .o_packet_pop_reject_bad_schedule_root(),
        .o_packet_out_valid(packet_out_valid),
        .o_packet_out_semantic_tree_id(),
        .o_packet_out_schedule_node_id(packet_out_node_id),
        .o_packet_out_data(packet_out_data),
        .o_timing_to_schedule_fire(timing_to_schedule_fire),
        .o_direct_to_schedule_fire(direct_to_schedule_fire),
        .o_timing_release_pending(timing_release_pending),
        .o_timing_deferred(timing_deferred),
        .o_deferred_by_direct_push(deferred_by_direct_push),
        .o_deferred_by_scheduling_pop(deferred_by_scheduling_pop),
        .o_deferred_by_schedule_backpressure(
            deferred_by_schedule_backpressure),
        .o_timing_deferred_cycles(timing_deferred_cycles),
        .o_release_delay_last(release_delay_last),
        .o_release_delay_max(release_delay_max),
        .o_timing_event_table_count(timing_event_table_count),
        .o_timing_release_fifo_count(timing_release_fifo_count),
        .o_timing_logical_count(timing_logical_count),
        .o_timing_logical_pending_count(timing_logical_pending_count),
        .o_schedule_logical_count(schedule_logical_count),
        .o_schedule_pending_count(schedule_pending_count),
        .o_timing_busy(timing_busy),
        .o_schedule_busy(schedule_busy),
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

    task configure_flow;
        input integer flow_id;
        input [2:0] mode;
        input integer default_service;
        input state_valid;
        input integer next_release;
        begin
            @(negedge clk);
            cfg_flow_id = flow_id[FLOW_ID_WIDTH-1:0];
            cfg_enable = 1'b1;
            cfg_mode = mode;
            cfg_service_time = default_service[TIME_WIDTH-1:0];
            cfg_state_valid = state_valid;
            cfg_next_release = next_release[TIME_WIDTH-1:0];
            cfg_bucket_capacity_time = 0;
            cfg_bucket_state_valid = 1'b0;
            cfg_bucket_credit_time = 0;
            cfg_bucket_state_time = 0;
            cfg_valid = 1'b1;
            watchdog = 0;
            while (!cfg_ready && watchdog < 1000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            check(cfg_ready, "flow configuration did not become ready");
            @(posedge clk);
            @(negedge clk);
            cfg_valid = 1'b0;
        end
    endtask

    task configure_token_bucket;
        input integer flow_id;
        input integer capacity_time;
        input state_valid;
        input integer credit_time;
        input integer state_time;
        begin
            @(negedge clk);
            cfg_flow_id = flow_id[FLOW_ID_WIDTH-1:0];
            cfg_enable = 1'b1;
            cfg_mode = 3'd4;
            cfg_service_time = 0;
            cfg_state_valid = 1'b0;
            cfg_next_release = 0;
            cfg_bucket_capacity_time = capacity_time[TIME_WIDTH-1:0];
            cfg_bucket_state_valid = state_valid;
            cfg_bucket_credit_time = credit_time[TIME_WIDTH-1:0];
            cfg_bucket_state_time = state_time[TIME_WIDTH-1:0];
            cfg_valid = 1'b1;
            watchdog = 0;
            while (!cfg_ready && watchdog < 1000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            check(cfg_ready, "token-bucket flow configuration stalled");
            @(posedge clk);
            @(negedge clk);
            cfg_valid = 1'b0;
        end
    endtask

    task issue_transaction;
        input integer flow_id;
        input [GLOBAL_ID_WIDTH-1:0] timing_node;
        input integer service_time;
        input integer absolute_time;
        input integer priority_value;
        input [DATA_WIDTH-1:0] data_value;
        input integer expected_release;
        input integer expected_timing_local;
        input integer expected_schedule_local;
        input [2:0] expected_program_mode;
        begin
            @(negedge clk);
            transaction_flow_id = flow_id[FLOW_ID_WIDTH-1:0];
            transaction_timing_node_id = timing_node;
            transaction_service_time = service_time[TIME_WIDTH-1:0];
            transaction_absolute_time = absolute_time[TIME_WIDTH-1:0];
            transaction_priority = priority_value[PTW-1:0];
            transaction_data = data_value;
            transaction_valid = 1'b1;
            watchdog = 0;
            while (!transaction_ready && watchdog < 12000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            #1;
            check(transaction_ready && transaction_fire,
                  "valid generalized transaction did not fire");
            check(transaction_map_valid &&
                  transaction_timing_local_id == expected_timing_local &&
                  transaction_release_schedule_local_id ==
                      expected_schedule_local &&
                  transaction_declared_program_mode == expected_program_mode,
                  "global timing node mapping mismatch");
            check(transaction_release_time == expected_release,
                  "transaction release-time computation mismatch");
            @(posedge clk);
            @(negedge clk);
            transaction_valid = 1'b0;
        end
    endtask

    task issue_pop;
        begin
            @(negedge clk);
            packet_pop_valid = 1'b1;
            watchdog = 0;
            while (!packet_pop_ready && watchdog < 20000) begin
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
        if (arst_n && timing_to_schedule_fire) begin
            if (timing_release_count < 2)
                actual_release_time[timing_release_count] <= wall_time;
            timing_release_count <= timing_release_count + 1;
        end
        if (arst_n && deferred_by_direct_push)
            deferred_by_direct_count <= deferred_by_direct_count + 1;
        if (arst_n && packet_out_valid) begin
            if (output_count < 3) begin
                output_data[output_count] <= packet_out_data;
                output_node[output_count] <= packet_out_node_id;
            end
            output_count <= output_count + 1;
        end
    end

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        wall_time = 0;
        cfg_valid = 1'b0;
        cfg_flow_id = 0;
        cfg_enable = 1'b0;
        cfg_mode = 0;
        cfg_service_time = 0;
        cfg_state_valid = 1'b0;
        cfg_next_release = 0;
        cfg_bucket_capacity_time = 0;
        cfg_bucket_state_valid = 1'b0;
        cfg_bucket_credit_time = 0;
        cfg_bucket_state_time = 0;
        transaction_valid = 1'b0;
        transaction_flow_id = 0;
        transaction_timing_node_id = 0;
        transaction_service_time = 0;
        transaction_absolute_time = 0;
        transaction_priority = 0;
        transaction_data = 0;
        direct_valid = 1'b0;
        direct_schedule_node_id = 0;
        direct_priority = 0;
        direct_data = 0;
        packet_pop_valid = 1'b0;
        failures = 0;
        watchdog = 0;
        timing_release_count = 0;
        output_count = 0;
        deferred_by_direct_count = 0;
        actual_release_time[0] = 0;
        actual_release_time[1] = 0;
        output_data[0] = 0;
        output_data[1] = 0;
        output_data[2] = 0;
        output_node[0] = 0;
        output_node[1] = 0;
        output_node[2] = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        arst_n = 1'b1;

        // Static type rejection: a schedule node cannot enter timing and a
        // timing node cannot use the direct schedule ingress.
        transaction_timing_node_id = LEAF_A;
        transaction_valid = 1'b1;
        #1;
        check(transaction_ready && transaction_reject_route &&
              !transaction_fire,
              "schedule node was not rejected from timing ingress");
        @(posedge clk);
        @(negedge clk);
        transaction_valid = 1'b0;

        direct_schedule_node_id = SHAPE_A;
        direct_valid = 1'b1;
        #1;
        check(direct_ready && direct_reject && !direct_to_schedule_fire,
              "timing node was not rejected from schedule ingress");
        @(posedge clk);
        @(negedge clk);
        direct_valid = 1'b0;

        configure_token_bucket(0, 5, 1'b1, 5, 20);
        configure_flow(1, 3'd3, 0, 1'b0, 0);
        issue_transaction(0, SHAPE_A, 5, 0, 2, SHAPED_A,
                          20, 0, 1, 3'd4);
        issue_transaction(1, SHAPE_B, 0, 20, 1, SHAPED_B,
                          20, 1, 2, 3'd3);

        watchdog = 0;
        while (((timing_logical_count[0] != 1) ||
                (timing_logical_count[1] != 1)) &&
               watchdog < 20000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(timing_logical_count[0] == 1 &&
              timing_logical_count[1] == 1,
              "events did not enter both timing logical VPIFOs");

        @(negedge clk);
        wall_time = 19;
        repeat (80) @(posedge clk);
        check(timing_release_count == 0 &&
              schedule_logical_count[0] == 0,
              "future timing event reached scheduling domain early");

        @(negedge clk);
        wall_time = 20;
        watchdog = 0;
        while (!timing_release_pending && watchdog < 20000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        check(timing_release_pending,
              "same-time timing events did not reach release queue");

        // Deliberately collide a normal schedule Push with a pending timing
        // release.  Scheduling ingress wins; timing data remains queued.
        direct_schedule_node_id = LEAF_A;
        direct_priority = 0;
        direct_data = DIRECT_PACKET;
        direct_valid = 1'b1;
        #1;
        check(direct_map_valid && direct_schedule_local_id == 1,
              "global schedule leaf mapping mismatch");
        watchdog = 0;
        while (!direct_ready && watchdog < 20000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        @(posedge clk);
        @(negedge clk);
        direct_valid = 1'b0;

        watchdog = 0;
        while ((timing_release_count < 2) && watchdog < 30000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(timing_release_count == 2,
              "both same-time timing events were not released exactly once");
        check(actual_release_time[0] >= 20 && actual_release_time[1] >= 20,
              "a timing event released before eligibility");
        check(deferred_by_direct_count > 0,
              "schedule-priority collision did not defer timing release");

        watchdog = 0;
        while (((schedule_logical_count[0] != 3) ||
                (schedule_logical_count[1] != 2) ||
                (schedule_logical_count[2] != 1) || schedule_busy) &&
               watchdog < 30000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(schedule_logical_count[0] == 3 &&
              schedule_logical_count[1] == 2 &&
              schedule_logical_count[2] == 1,
              "static release edges targeted the wrong schedule leaves");

        issue_pop();
        while ((output_count < 1) && watchdog < 50000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        issue_pop();
        while ((output_count < 2) && watchdog < 50000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        issue_pop();
        while ((output_count < 3) && watchdog < 50000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(output_count == 3, "scheduler did not return all packets");
        check(output_data[0] == DIRECT_PACKET && output_node[0] == LEAF_A,
              "direct packet/global leaf output mismatch");
        check(output_data[1] == SHAPED_B && output_node[1] == LEAF_B,
              "shape_b static edge or schedule rank mismatch");
        check(output_data[2] == SHAPED_A && output_node[2] == LEAF_A,
              "shape_a static edge or schedule rank mismatch");

        watchdog = 0;
        while (busy && watchdog < 30000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(!busy && timing_event_table_count == 0 &&
              timing_release_fifo_count == 0 &&
              schedule_pending_count == 0,
              "two-domain system did not quiesce cleanly");
        for (index = 0; index < TIMING_NUM; index = index + 1)
            check(timing_logical_count[index] == 0 &&
                  timing_logical_pending_count[index] == 0,
                  "timing-domain accounting did not return to zero");
        for (index = 0; index < SCHEDULE_NUM; index = index + 1)
            check(schedule_logical_count[index] == 0,
                  "schedule-domain accounting did not return to zero");
        check(!cfg_reject && !transaction_reject_flow &&
              !transaction_reject_unconfigured && !protocol_error,
              "unexpected generalized VPIFO error");

        if (failures == 0) begin
            $display("PASS: generalized two-domain VPIFO end-to-end test");
            $display("release=%0d/%0d delay_max=%0d deferred=%0d",
                     actual_release_time[0], actual_release_time[1],
                     release_delay_max, deferred_by_direct_count);
        end else begin
            $display("FAIL: generalized VPIFO failures=%0d", failures);
            $fatal(1);
        end
        $finish;
    end

endmodule
