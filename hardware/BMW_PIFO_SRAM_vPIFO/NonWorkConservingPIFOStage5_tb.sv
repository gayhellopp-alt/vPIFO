`timescale 1ns / 1ps

// Stage-5 end-to-end test:
// stateful shaping transaction -> heterogeneous timing PIFO -> Stage-28
// hierarchical scheduling PIFO -> root-to-leaf packet output.
module NonWorkConservingPIFOStage5_tb;

    localparam PTW = 16;
    localparam MTW = 16;
    localparam DATA_WIDTH = PTW + MTW;
    localparam TIME_WIDTH = 16;
    localparam FLOW_NUM = 4;
    localparam FLOW_ID_WIDTH = 2;
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

    localparam [DATA_WIDTH-1:0] PACKET_0 = 32'h5100_0001;
    localparam [DATA_WIDTH-1:0] PACKET_1 = 32'h5200_0002;
    localparam [DATA_WIDTH-1:0] PACKET_2 = 32'h5300_0003;

    reg clk;
    reg arst_n;
    reg [TIME_WIDTH-1:0] wall_time;

    reg transaction_cfg_valid;
    wire transaction_cfg_ready;
    reg [FLOW_ID_WIDTH-1:0] transaction_cfg_flow_id;
    reg transaction_cfg_enable;
    reg [2:0] transaction_cfg_mode;
    reg [TIME_WIDTH-1:0] transaction_cfg_default_service_time;
    reg transaction_cfg_state_valid;
    reg [TIME_WIDTH-1:0] transaction_cfg_next_release_time;
    reg [TIME_WIDTH-1:0] transaction_cfg_bucket_capacity_time;
    reg transaction_cfg_bucket_state_valid;
    reg [TIME_WIDTH-1:0] transaction_cfg_bucket_credit_time;
    reg [TIME_WIDTH-1:0] transaction_cfg_bucket_state_time;
    wire transaction_cfg_reject_bad_flow_id;

    reg transaction_valid;
    wire transaction_ready;
    reg [FLOW_ID_WIDTH-1:0] transaction_flow_id;
    reg [SHAPING_LOGICAL_ID_WIDTH-1:0]
        transaction_shaping_logical_id;
    reg [TIME_WIDTH-1:0] transaction_packet_service_time;
    reg [TIME_WIDTH-1:0] transaction_absolute_release_time;
    reg [SCHED_LOGICAL_ID_WIDTH-1:0] transaction_parent_leaf_id;
    reg [PTW-1:0] transaction_parent_priority;
    reg [DATA_WIDTH-1:0] transaction_packet_data;
    wire transaction_reject_bad_flow_id;
    wire transaction_reject_unconfigured;
    wire transaction_reject_bad_route;
    wire transaction_fire;
    wire [TIME_WIDTH-1:0] transaction_release_time;
    wire [TIME_WIDTH-1:0] transaction_next_release_time;
    wire [TIME_WIDTH-1:0] transaction_bucket_credit_time;
    wire [TIME_WIDTH-1:0] transaction_bucket_state_time;

    reg [FLOW_ID_WIDTH-1:0] transaction_state_read_flow_id;
    wire transaction_state_read_configured;
    wire [2:0] transaction_state_read_mode;
    wire [TIME_WIDTH-1:0]
        transaction_state_read_default_service_time;
    wire transaction_state_read_valid;
    wire [TIME_WIDTH-1:0]
        transaction_state_read_next_release_time;
    wire transaction_state_read_bucket_valid;
    wire [TIME_WIDTH-1:0]
        transaction_state_read_bucket_capacity_time;
    wire [TIME_WIDTH-1:0]
        transaction_state_read_bucket_credit_time;
    wire [TIME_WIDTH-1:0]
        transaction_state_read_bucket_state_time;
    wire [31:0] transaction_count;
    wire [31:0] rejected_transaction_count;
    wire [31:0] late_absolute_count;
    wire [31:0] saturated_time_count;
    wire [2:0] configured_flow_count;

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
    integer shaping_fire_count;
    integer output_count;
    integer logical_index;
    reg [TIME_WIDTH-1:0] actual_release_time [0:2];
    reg [DATA_WIDTH-1:0] output_data [0:2];
    reg [SCHED_LOGICAL_ID_WIDTH-1:0] output_leaf [0:2];

    NonWorkConservingPIFOStage5 #(
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
        .TRANSACTION_FLOW_NUM(FLOW_NUM),
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
        .i_transaction_cfg_valid(transaction_cfg_valid),
        .o_transaction_cfg_ready(transaction_cfg_ready),
        .i_transaction_cfg_flow_id(transaction_cfg_flow_id),
        .i_transaction_cfg_enable(transaction_cfg_enable),
        .i_transaction_cfg_mode(transaction_cfg_mode),
        .i_transaction_cfg_default_service_time(
            transaction_cfg_default_service_time),
        .i_transaction_cfg_state_valid(transaction_cfg_state_valid),
        .i_transaction_cfg_next_release_time(
            transaction_cfg_next_release_time),
        .i_transaction_cfg_bucket_capacity_time(
            transaction_cfg_bucket_capacity_time),
        .i_transaction_cfg_bucket_state_valid(
            transaction_cfg_bucket_state_valid),
        .i_transaction_cfg_bucket_credit_time(
            transaction_cfg_bucket_credit_time),
        .i_transaction_cfg_bucket_state_time(
            transaction_cfg_bucket_state_time),
        .o_transaction_cfg_reject_bad_flow_id(
            transaction_cfg_reject_bad_flow_id),
        .i_transaction_valid(transaction_valid),
        .o_transaction_ready(transaction_ready),
        .i_transaction_flow_id(transaction_flow_id),
        .i_transaction_shaping_logical_tree_id(
            transaction_shaping_logical_id),
        .i_transaction_packet_service_time(
            transaction_packet_service_time),
        .i_transaction_absolute_release_time(
            transaction_absolute_release_time),
        .i_transaction_parent_leaf_tree_id(
            transaction_parent_leaf_id),
        .i_transaction_parent_priority(transaction_parent_priority),
        .i_transaction_packet_data(transaction_packet_data),
        .o_transaction_reject_bad_flow_id(
            transaction_reject_bad_flow_id),
        .o_transaction_reject_unconfigured(
            transaction_reject_unconfigured),
        .o_transaction_reject_bad_route(transaction_reject_bad_route),
        .o_transaction_fire(transaction_fire),
        .o_transaction_release_time(transaction_release_time),
        .o_transaction_next_release_time(
            transaction_next_release_time),
        .o_transaction_bucket_credit_time(
            transaction_bucket_credit_time),
        .o_transaction_bucket_state_time(
            transaction_bucket_state_time),
        .i_transaction_state_read_flow_id(
            transaction_state_read_flow_id),
        .o_transaction_state_read_configured(
            transaction_state_read_configured),
        .o_transaction_state_read_mode(transaction_state_read_mode),
        .o_transaction_state_read_default_service_time(
            transaction_state_read_default_service_time),
        .o_transaction_state_read_valid(
            transaction_state_read_valid),
        .o_transaction_state_read_next_release_time(
            transaction_state_read_next_release_time),
        .o_transaction_state_read_bucket_valid(
            transaction_state_read_bucket_valid),
        .o_transaction_state_read_bucket_capacity_time(
            transaction_state_read_bucket_capacity_time),
        .o_transaction_state_read_bucket_credit_time(
            transaction_state_read_bucket_credit_time),
        .o_transaction_state_read_bucket_state_time(
            transaction_state_read_bucket_state_time),
        .o_transaction_count(transaction_count),
        .o_rejected_transaction_count(rejected_transaction_count),
        .o_late_absolute_count(late_absolute_count),
        .o_saturated_time_count(saturated_time_count),
        .o_configured_flow_count(configured_flow_count),
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

    task configure_token_bucket;
        input integer flow_id;
        input integer capacity_time;
        input state_valid;
        input integer credit_time;
        input integer state_time;
        begin
            @(negedge clk);
            transaction_cfg_flow_id = flow_id[FLOW_ID_WIDTH-1:0];
            transaction_cfg_enable = 1'b1;
            transaction_cfg_mode = 3'd4;
            transaction_cfg_default_service_time = 0;
            transaction_cfg_state_valid = 1'b0;
            transaction_cfg_next_release_time = 0;
            transaction_cfg_bucket_capacity_time =
                capacity_time[TIME_WIDTH-1:0];
            transaction_cfg_bucket_state_valid = state_valid;
            transaction_cfg_bucket_credit_time =
                credit_time[TIME_WIDTH-1:0];
            transaction_cfg_bucket_state_time =
                state_time[TIME_WIDTH-1:0];
            transaction_cfg_valid = 1'b1;
            watchdog = 0;
            while (!transaction_cfg_ready && watchdog < 1000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            check(transaction_cfg_ready,
                  "token-bucket configuration did not become ready");
            @(posedge clk);
            @(negedge clk);
            transaction_cfg_valid = 1'b0;
        end
    endtask

    task configure_flow;
        input integer flow_id;
        input [2:0] mode;
        input integer default_service_time;
        input state_valid;
        input integer next_release_time;
        begin
            @(negedge clk);
            transaction_cfg_flow_id = flow_id[FLOW_ID_WIDTH-1:0];
            transaction_cfg_enable = 1'b1;
            transaction_cfg_mode = mode;
            transaction_cfg_default_service_time =
                default_service_time[TIME_WIDTH-1:0];
            transaction_cfg_state_valid = state_valid;
            transaction_cfg_next_release_time =
                next_release_time[TIME_WIDTH-1:0];
            transaction_cfg_bucket_capacity_time = 0;
            transaction_cfg_bucket_state_valid = 1'b0;
            transaction_cfg_bucket_credit_time = 0;
            transaction_cfg_bucket_state_time = 0;
            transaction_cfg_valid = 1'b1;
            watchdog = 0;
            while (!transaction_cfg_ready && watchdog < 1000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            check(transaction_cfg_ready,
                  "transaction configuration did not become ready");
            @(posedge clk);
            @(negedge clk);
            transaction_cfg_valid = 1'b0;
        end
    endtask

    task issue_transaction;
        input integer flow_id;
        input integer shaping_logical_id;
        input integer service_time;
        input integer absolute_release_time;
        input integer parent_leaf_id;
        input integer root_priority;
        input [DATA_WIDTH-1:0] data_value;
        input integer expected_release_time;
        input integer expected_next_release_time;
        begin
            @(negedge clk);
            transaction_flow_id = flow_id[FLOW_ID_WIDTH-1:0];
            transaction_shaping_logical_id =
                shaping_logical_id[SHAPING_LOGICAL_ID_WIDTH-1:0];
            transaction_packet_service_time =
                service_time[TIME_WIDTH-1:0];
            transaction_absolute_release_time =
                absolute_release_time[TIME_WIDTH-1:0];
            transaction_parent_leaf_id =
                parent_leaf_id[SCHED_LOGICAL_ID_WIDTH-1:0];
            transaction_parent_priority = root_priority[PTW-1:0];
            transaction_packet_data = data_value;
            transaction_valid = 1'b1;
            watchdog = 0;
            while (!transaction_ready && watchdog < 12000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            check(transaction_ready,
                  "transaction did not become ready");
            #1;
            check(transaction_fire,
                  "ready transaction did not present a shaping event");
            check(transaction_release_time ==
                  expected_release_time[TIME_WIDTH-1:0],
                  "computed release_time mismatch");
            check(transaction_next_release_time ==
                  expected_next_release_time[TIME_WIDTH-1:0],
                  "computed next_release_time mismatch");
            @(posedge clk);
            @(negedge clk);
            transaction_valid = 1'b0;
        end
    endtask

    task issue_packet_pop;
        begin
            @(negedge clk);
            packet_pop_valid = 1'b1;
            watchdog = 0;
            while (!packet_pop_ready && watchdog < 12000) begin
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
        if (arst_n && shaping_to_parent_fire) begin
            if (shaping_fire_count < 3)
                actual_release_time[shaping_fire_count] <= wall_time;
            shaping_fire_count <= shaping_fire_count + 1;
        end
        if (arst_n && packet_out_valid) begin
            if (output_count < 3) begin
                output_data[output_count] <= packet_out_data;
                output_leaf[output_count] <= packet_out_leaf_id;
            end
            output_count <= output_count + 1;
        end
    end

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        wall_time = 0;
        transaction_cfg_valid = 1'b0;
        transaction_cfg_flow_id = 0;
        transaction_cfg_enable = 1'b0;
        transaction_cfg_mode = 0;
        transaction_cfg_default_service_time = 0;
        transaction_cfg_state_valid = 1'b0;
        transaction_cfg_next_release_time = 0;
        transaction_cfg_bucket_capacity_time = 0;
        transaction_cfg_bucket_state_valid = 1'b0;
        transaction_cfg_bucket_credit_time = 0;
        transaction_cfg_bucket_state_time = 0;
        transaction_valid = 1'b0;
        transaction_flow_id = 0;
        transaction_shaping_logical_id = 0;
        transaction_packet_service_time = 0;
        transaction_absolute_release_time = 0;
        transaction_parent_leaf_id = 0;
        transaction_parent_priority = 0;
        transaction_packet_data = 0;
        transaction_state_read_flow_id = 0;
        direct_push_valid = 1'b0;
        direct_leaf_id = 0;
        direct_priority = 0;
        direct_packet_data = 0;
        packet_pop_valid = 1'b0;
        failures = 0;
        watchdog = 0;
        shaping_fire_count = 0;
        output_count = 0;
        actual_release_time[0] = 0;
        actual_release_time[1] = 0;
        actual_release_time[2] = 0;
        output_data[0] = 0;
        output_data[1] = 0;
        output_data[2] = 0;
        output_leaf[0] = 0;
        output_leaf[1] = 0;
        output_leaf[2] = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        arst_n = 1'b1;

        // A per-flow token bucket has five time-credit units reserved at t=20.
        // The first five-unit packet is eligible at 20; later accepted packets
        // reserve one five-cycle refill interval each.
        configure_token_bucket(0, 5, 1'b1, 5, 20);
        #1;
        check(transaction_state_read_configured &&
              transaction_state_read_bucket_valid &&
              transaction_state_read_mode == 3'd4 &&
              transaction_state_read_bucket_capacity_time == 5 &&
              transaction_state_read_bucket_credit_time == 5 &&
              transaction_state_read_bucket_state_time == 20,
              "configured token-bucket readback mismatch");

        issue_transaction(0, 0, 5, 0, 1, 1,
                          PACKET_0, 20, 0);
        issue_transaction(0, 0, 5, 0, 1, 2,
                          PACKET_1, 25, 0);
        issue_transaction(0, 0, 5, 0, 1, 3,
                          PACKET_2, 30, 0);

        check(transaction_count == 3 &&
              transaction_state_read_bucket_credit_time == 0 &&
              transaction_state_read_bucket_state_time == 30,
              "token-bucket state did not advance once per accepted event");
        watchdog = 0;
        while ((shaping_logical_count[0] != 3) &&
               watchdog < 16000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(shaping_logical_count[0] == 3,
              "computed events did not enter shaping BMW tree");

        // Non-work-conserving boundary: a non-empty shaping tree does not make
        // any child reference visible in the scheduling parent before t=20.
        @(negedge clk);
        wall_time = 19;
        repeat (80) @(posedge clk);
        check(shaping_fire_count == 0,
              "first transaction released before computed time");
        check(scheduler_logical_count[0] == 0 &&
              scheduler_logical_count[1] == 0,
              "parent scheduler observed a future event");

        @(negedge clk);
        wall_time = 20;
        watchdog = 0;
        while ((shaping_fire_count < 1) && watchdog < 20000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(shaping_fire_count == 1,
              "first computed event did not release at/after t=20");
        check(actual_release_time[0] >= 20,
              "first actual release preceded configured release");

        @(negedge clk);
        wall_time = 24;
        repeat (80) @(posedge clk);
        check(shaping_fire_count == 1,
              "second transaction released before t=25");

        @(negedge clk);
        wall_time = 25;
        watchdog = 0;
        while ((shaping_fire_count < 2) && watchdog < 20000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(shaping_fire_count == 2 && actual_release_time[1] >= 25,
              "second computed event release mismatch");

        @(negedge clk);
        wall_time = 29;
        repeat (80) @(posedge clk);
        check(shaping_fire_count == 2,
              "third transaction released before t=30");

        @(negedge clk);
        wall_time = 30;
        watchdog = 0;
        while ((shaping_fire_count < 3) && watchdog < 20000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(shaping_fire_count == 3 && actual_release_time[2] >= 30,
              "third computed event release mismatch");

        watchdog = 0;
        while (((scheduler_logical_count[0] != 3) ||
                (scheduler_logical_count[1] != 3) ||
                scheduler_busy) && watchdog < 24000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(scheduler_logical_count[0] == 3 &&
              scheduler_logical_count[1] == 3,
              "released references did not settle in parent scheduling tree");

        issue_packet_pop();
        watchdog = 0;
        while ((output_count < 1) && watchdog < 24000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        issue_packet_pop();
        watchdog = 0;
        while ((output_count < 2) && watchdog < 24000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        issue_packet_pop();
        watchdog = 0;
        while ((output_count < 3) && watchdog < 24000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(output_count == 3,
              "scheduler did not return all transaction-generated packets");
        check(output_data[0] == PACKET_0 && output_leaf[0] == 1,
              "first shaped packet output mismatch");
        check(output_data[1] == PACKET_1 && output_leaf[1] == 1,
              "second shaped packet output mismatch");
        check(output_data[2] == PACKET_2 && output_leaf[2] == 1,
              "third shaped packet output mismatch");

        watchdog = 0;
        while (busy && watchdog < 24000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(!busy, "Stage-5 system did not quiesce");
        check(shaping_event_table_count == 0 &&
              shaping_release_fifo_count == 0,
              "Stage-5 shaping storage did not drain");
        check(scheduler_pending_count == 0,
              "Stage-5 scheduler pending pool did not drain");
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
        check(configured_flow_count == 1 &&
              rejected_transaction_count == 0 &&
              late_absolute_count == 0 && saturated_time_count == 0,
              "Stage-5 transaction accounting mismatch");
        check(!transaction_cfg_reject_bad_flow_id &&
              !transaction_reject_bad_flow_id &&
              !transaction_reject_unconfigured &&
              !transaction_reject_bad_route &&
              !direct_reject_bad_leaf_id,
              "a valid Stage-5 request was rejected");
        check(!protocol_error, "Stage-5 protocol_error asserted");

        if (failures == 0) begin
            $display("PASS: Stage5 transaction-to-Stage28 end-to-end test");
            $display("computed=20/25/30 actual=%0d/%0d/%0d delay_max=%0d",
                     actual_release_time[0], actual_release_time[1],
                     actual_release_time[2], release_delay_max);
        end else begin
            $display("FAIL: Stage5 integration failures=%0d", failures);
            $fatal(1);
        end
        $finish;
    end

endmodule
