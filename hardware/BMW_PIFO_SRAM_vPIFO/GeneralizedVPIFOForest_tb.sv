`timescale 1ns / 1ps

// End-to-end two-domain/two-schedule-tree test:
// timing node 4 -> schedule leaf 1 under root 0
// timing node 5 -> schedule leaf 3 under root 2
module GeneralizedVPIFOForest_tb;
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
    localparam SCHEDULE_TREE_WIDTH =
        GeneralizedVpifoConfigPkg::SCHEDULE_TREE_ID_WIDTH;
    localparam SCHEDULE_COUNT_WIDTH = 8;
    localparam TIMING_COUNT_WIDTH = 7;
    localparam SCHEDULE_PENDING_COUNT_WIDTH = 4;
    localparam TIMING_PENDING_COUNT_WIDTH = 4;

    localparam [GLOBAL_ID_WIDTH-1:0] ROOT_A = 0;
    localparam [GLOBAL_ID_WIDTH-1:0] LEAF_A = 1;
    localparam [GLOBAL_ID_WIDTH-1:0] ROOT_B = 2;
    localparam [GLOBAL_ID_WIDTH-1:0] LEAF_B = 3;
    localparam [GLOBAL_ID_WIDTH-1:0] SHAPE_A = 4;
    localparam [GLOBAL_ID_WIDTH-1:0] SHAPE_B = 5;
    localparam [DATA_WIDTH-1:0] PACKET_A = 32'hA100_0005;
    localparam [DATA_WIDTH-1:0] PACKET_B = 32'hB100_0001;

    reg clk;
    reg arst_n;
    reg [TIME_WIDTH-1:0] wall_time;

    reg cfg_valid;
    wire cfg_ready;
    reg [FLOW_ID_WIDTH-1:0] cfg_flow_id;
    reg [2:0] cfg_mode;
    reg [TIME_WIDTH-1:0] cfg_service;
    reg cfg_state_valid;
    reg [TIME_WIDTH-1:0] cfg_next_release;

    reg transaction_valid;
    wire transaction_ready;
    reg [FLOW_ID_WIDTH-1:0] transaction_flow_id;
    reg [GLOBAL_ID_WIDTH-1:0] transaction_timing_node_id;
    reg [TIME_WIDTH-1:0] transaction_service;
    reg [TIME_WIDTH-1:0] transaction_absolute;
    reg [PTW-1:0] transaction_priority;
    reg [DATA_WIDTH-1:0] transaction_data;
    wire transaction_fire;
    wire transaction_map_valid;
    wire transaction_timing_local_id;
    wire [1:0] transaction_schedule_local_id;

    reg packet_pop_valid;
    reg [GLOBAL_ID_WIDTH-1:0] packet_pop_root_node_id;
    wire packet_pop_ready;
    wire packet_pop_reject_root;
    wire packet_out_valid;
    wire [SCHEDULE_TREE_WIDTH-1:0] packet_out_tree_id;
    wire [GLOBAL_ID_WIDTH-1:0] packet_out_node_id;
    wire [DATA_WIDTH-1:0] packet_out_data;

    wire timing_to_schedule_fire;
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
    wire busy;
    wire protocol_error;

    integer failures;
    integer watchdog;
    integer release_count;
    integer output_count;
    integer bad_root_reject_count;
    reg [GLOBAL_ID_WIDTH-1:0] captured_output_node [0:1];
    reg [SCHEDULE_TREE_WIDTH-1:0] captured_output_tree [0:1];
    reg [DATA_WIDTH-1:0] captured_output_data [0:1];

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
        .i_transaction_cfg_enable(1'b1),
        .i_transaction_cfg_mode(cfg_mode),
        .i_transaction_cfg_default_service_time(cfg_service),
        .i_transaction_cfg_state_valid(cfg_state_valid),
        .i_transaction_cfg_next_release_time(cfg_next_release),
        .i_transaction_cfg_bucket_capacity_time({TIME_WIDTH{1'b0}}),
        .i_transaction_cfg_bucket_state_valid(1'b0),
        .i_transaction_cfg_bucket_credit_time({TIME_WIDTH{1'b0}}),
        .i_transaction_cfg_bucket_state_time({TIME_WIDTH{1'b0}}),
        .o_transaction_cfg_reject_bad_flow_id(),
        .i_transaction_valid(transaction_valid),
        .o_transaction_ready(transaction_ready),
        .i_transaction_flow_id(transaction_flow_id),
        .i_transaction_timing_node_id(transaction_timing_node_id),
        .i_transaction_packet_service_time(transaction_service),
        .i_transaction_absolute_release_time(transaction_absolute),
        .i_transaction_parent_priority(transaction_priority),
        .i_transaction_packet_data(transaction_data),
        .o_transaction_reject_bad_flow_id(),
        .o_transaction_reject_unconfigured(),
        .o_transaction_reject_bad_route(),
        .o_transaction_fire(transaction_fire),
        .o_transaction_release_time(),
        .o_transaction_next_release_time(),
        .o_transaction_bucket_credit_time(),
        .o_transaction_bucket_state_time(),
        .o_transaction_map_valid(transaction_map_valid),
        .o_transaction_timing_local_id(transaction_timing_local_id),
        .o_transaction_release_schedule_local_id(
            transaction_schedule_local_id),
        .o_transaction_declared_program_mode(),
        .i_transaction_state_read_flow_id(2'b0),
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
        .i_direct_push_valid(1'b0),
        .o_direct_push_ready(),
        .i_direct_schedule_node_id({GLOBAL_ID_WIDTH{1'b0}}),
        .i_direct_priority({PTW{1'b0}}),
        .i_direct_packet_data({DATA_WIDTH{1'b0}}),
        .o_direct_reject_bad_schedule_node(),
        .o_direct_map_valid(),
        .o_direct_schedule_local_id(),
        .i_packet_pop_valid(packet_pop_valid),
        .i_packet_pop_schedule_root_node_id(packet_pop_root_node_id),
        .o_packet_pop_ready(packet_pop_ready),
        .o_packet_pop_reject_bad_schedule_root(
            packet_pop_reject_root),
        .o_packet_out_valid(packet_out_valid),
        .o_packet_out_semantic_tree_id(packet_out_tree_id),
        .o_packet_out_schedule_node_id(packet_out_node_id),
        .o_packet_out_data(packet_out_data),
        .o_timing_to_schedule_fire(timing_to_schedule_fire),
        .o_direct_to_schedule_fire(),
        .o_timing_release_pending(),
        .o_timing_deferred(),
        .o_deferred_by_direct_push(),
        .o_deferred_by_scheduling_pop(),
        .o_deferred_by_schedule_backpressure(),
        .o_timing_deferred_cycles(),
        .o_release_delay_last(),
        .o_release_delay_max(),
        .o_timing_event_table_count(timing_event_table_count),
        .o_timing_release_fifo_count(timing_release_fifo_count),
        .o_timing_logical_count(timing_logical_count),
        .o_timing_logical_pending_count(timing_logical_pending_count),
        .o_schedule_logical_count(schedule_logical_count),
        .o_schedule_pending_count(schedule_pending_count),
        .o_timing_busy(),
        .o_schedule_busy(),
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
        input integer service;
        input state_valid;
        input integer next_release;
        begin
            @(negedge clk);
            cfg_flow_id = flow_id[FLOW_ID_WIDTH-1:0];
            cfg_mode = mode;
            cfg_service = service[TIME_WIDTH-1:0];
            cfg_state_valid = state_valid;
            cfg_next_release = next_release[TIME_WIDTH-1:0];
            cfg_valid = 1'b1;
            watchdog = 0;
            while (!cfg_ready && watchdog < 2000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            check(cfg_ready, "forest flow configuration timed out");
            @(posedge clk);
            @(negedge clk);
            cfg_valid = 1'b0;
        end
    endtask

    task issue_transaction;
        input integer flow_id;
        input [GLOBAL_ID_WIDTH-1:0] timing_node_id;
        input integer absolute_release;
        input integer priority_value;
        input [DATA_WIDTH-1:0] data_value;
        input integer expected_timing_local;
        input integer expected_schedule_local;
        begin
            @(negedge clk);
            transaction_flow_id = flow_id[FLOW_ID_WIDTH-1:0];
            transaction_timing_node_id = timing_node_id;
            transaction_service = 0;
            transaction_absolute = absolute_release[TIME_WIDTH-1:0];
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
                  "forest shaping transaction did not fire");
            check(transaction_map_valid &&
                  transaction_timing_local_id == expected_timing_local &&
                  transaction_schedule_local_id == expected_schedule_local,
                  "timing release edge mapped to the wrong forest leaf");
            @(posedge clk);
            @(negedge clk);
            transaction_valid = 1'b0;
        end
    endtask

    task issue_pop;
        input [GLOBAL_ID_WIDTH-1:0] root_node_id;
        begin
            @(negedge clk);
            packet_pop_root_node_id = root_node_id;
            packet_pop_valid = 1'b1;
            watchdog = 0;
            while (!packet_pop_ready && watchdog < 12000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            check(packet_pop_ready, "forest root Pop admission timed out");
            @(posedge clk);
            @(negedge clk);
            packet_pop_valid = 1'b0;
        end
    endtask

    task wait_output;
        input integer expected_count;
        begin
            watchdog = 0;
            while ((output_count < expected_count) && watchdog < 20000) begin
                @(posedge clk);
                watchdog = watchdog + 1;
            end
            check(output_count == expected_count,
                  "forest packet result timed out");
        end
    endtask

    always @(posedge clk) begin
        if (arst_n && timing_to_schedule_fire)
            release_count <= release_count + 1;
        if (arst_n && packet_out_valid) begin
            if (output_count < 2) begin
                captured_output_node[output_count] <= packet_out_node_id;
                captured_output_tree[output_count] <= packet_out_tree_id;
                captured_output_data[output_count] <= packet_out_data;
            end
            output_count <= output_count + 1;
        end
        if (arst_n && packet_pop_reject_root)
            bad_root_reject_count <= bad_root_reject_count + 1;
        if (arst_n && protocol_error) begin
            $display("FAIL: protocol_error asserted at time %0t", $time);
            failures = failures + 1;
        end
    end

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        wall_time = 0;
        cfg_valid = 1'b0;
        cfg_flow_id = 0;
        cfg_mode = 0;
        cfg_service = 0;
        cfg_state_valid = 1'b0;
        cfg_next_release = 0;
        transaction_valid = 1'b0;
        transaction_flow_id = 0;
        transaction_timing_node_id = 0;
        transaction_service = 0;
        transaction_absolute = 0;
        transaction_priority = 0;
        transaction_data = 0;
        packet_pop_valid = 1'b0;
        packet_pop_root_node_id = ROOT_A;
        failures = 0;
        watchdog = 0;
        release_count = 0;
        output_count = 0;
        bad_root_reject_count = 0;
        captured_output_node[0] = 0;
        captured_output_node[1] = 0;
        captured_output_tree[0] = 0;
        captured_output_tree[1] = 0;
        captured_output_data[0] = 0;
        captured_output_data[1] = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        arst_n = 1'b1;

        // A leaf is not a legal Pop selector: semantic trees are selected by
        // their global root-node IDs in the unified namespace.
        issue_pop(LEAF_A);
        check(bad_root_reject_count == 1,
              "leaf node was not rejected as a schedule-tree root");
        check(output_count == 0,
              "invalid root Pop generated a packet result");

        configure_flow(0, 3'd1, 0, 1'b1, 10);
        configure_flow(1, 3'd3, 0, 1'b0, 0);
        issue_transaction(0, SHAPE_A, 0, 5, PACKET_A, 0, 1);
        issue_transaction(1, SHAPE_B, 10, 1, PACKET_B, 1, 3);

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
        wall_time = 9;
        repeat (80) @(posedge clk);
        check(release_count == 0 &&
              schedule_logical_count[0] == 0 &&
              schedule_logical_count[2] == 0,
              "timing event entered a schedule tree before release_time");

        @(negedge clk);
        wall_time = 10;
        watchdog = 0;
        while ((release_count < 2) && watchdog < 30000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(release_count == 2,
              "both timing domains events were not released exactly once");

        watchdog = 0;
        while (((schedule_logical_count[0] != 1) ||
                (schedule_logical_count[1] != 1) ||
                (schedule_logical_count[2] != 1) ||
                (schedule_logical_count[3] != 1)) &&
               watchdog < 30000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(schedule_logical_count[0] == 1 &&
              schedule_logical_count[1] == 1 &&
              schedule_logical_count[2] == 1 &&
              schedule_logical_count[3] == 1,
              "timing releases did not populate both semantic trees");

        issue_pop(ROOT_A);
        wait_output(1);
        issue_pop(ROOT_B);
        wait_output(2);

        check(captured_output_tree[0] == 0 &&
              captured_output_node[0] == LEAF_A &&
              captured_output_data[0] == PACKET_A,
              "tree A returned a packet from the wrong timing edge/tree");
        check(captured_output_tree[1] == 1 &&
              captured_output_node[1] == LEAF_B &&
              captured_output_data[1] == PACKET_B,
              "tree B returned a packet from the wrong timing edge/tree");

        watchdog = 0;
        while (busy && watchdog < 30000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(!busy && timing_event_table_count == 0 &&
              timing_release_fifo_count == 0 &&
              schedule_pending_count == 0,
              "forest two-domain system did not quiesce");
        check(schedule_logical_count[0] == 0 &&
              schedule_logical_count[1] == 0 &&
              schedule_logical_count[2] == 0 &&
              schedule_logical_count[3] == 0,
              "forest schedule counts did not return to zero");
        check(timing_logical_count[0] == 0 &&
              timing_logical_count[1] == 0 &&
              timing_logical_pending_count[0] == 0 &&
              timing_logical_pending_count[1] == 0,
              "timing domain counts did not return to zero");

        if (failures == 0)
            $display("PASS: GeneralizedVPIFOForest_tb");
        else
            $fatal(1, "GeneralizedVPIFOForest_tb failures=%0d", failures);
        $finish;
    end

endmodule
