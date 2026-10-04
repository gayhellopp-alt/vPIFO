`timescale 1ns / 10ps

// A/B experiment for aggregate Y non-work-conserving shaping.
//
// Both cases offer the same finite burst of C/A/B packets and run the same
// one-outstanding recursive Pop consumer.  The bypass case sends each packet
// through a FULL Scheduling Push.  The shaped case sends the same packet and
// ranks through LOCAL(Y) plus a Token-Bucket-timed PARENT_REF(Y) release.
module ThreeTierNodeYShapingAB_tb #(
    parameter integer TARGET_SERVICE_TIME = 750,
    parameter integer PACKETS = 60,
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
    localparam PACKET_BYTES = 1500;
    localparam PACKET_BITS = PACKET_BYTES * 8;
    localparam CLOCK_HZ = 125000000;
    localparam BIN_SERVICE_INTERVALS = 4;
    localparam RATE_TOLERANCE_PPM = 10000;
    localparam BIN_CYCLES =
        TARGET_SERVICE_TIME * BIN_SERVICE_INTERVALS;
    localparam MAX_BINS = PACKETS + 16;
    localparam longint TARGET_BPS =
        (64'd12000 * 64'd125000000) /
        longint'(TARGET_SERVICE_TIME);

    localparam [1:0] NODE_ROOT = 2'd0;
    localparam [1:0] NODE_Y = 2'd2;
    localparam [1:0] NODE_Z = 2'd3;
    localparam [2:0] FLOW_C = 3'd3;
    localparam [2:0] FLOW_A = 3'd4;
    localparam [2:0] FLOW_B = 3'd5;

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
    wire [5:0] timing_event_count;
    wire [4:0] timing_release_count;
    wire [9:0] schedule_logical_count [0:LOGICAL_TREE_NUM-1];
    wire [SCHEDULE_PENDING_COUNT_WIDTH-1:0] schedule_pending_count;
    wire [SCHEDULE_TRACK_COUNT_WIDTH-1:0] schedule_outstanding_count;
    wire timing_busy;
    wire schedule_busy;
    wire busy;
    wire protocol_error;

    integer case_mode;
    longint case_epoch;
    integer bypass_output_count;
    integer shaped_output_count;
    integer bypass_accept_count;
    integer shaped_accept_count;
    integer shaped_release_count;
    integer shaped_backlogged_output_count;
    reg bypass_seen [0:PACKETS-1];
    reg shaped_seen [0:PACKETS-1];
    reg [TIME_WIDTH-1:0] bypass_output_cycle [0:PACKETS-1];
    reg [TIME_WIDTH-1:0] shaped_output_cycle [0:PACKETS-1];
    reg [2:0] bypass_output_flow [0:PACKETS-1];
    reg [2:0] shaped_output_flow [0:PACKETS-1];
    reg [1:0] bypass_output_node [0:PACKETS-1];
    reg [1:0] shaped_output_node [0:PACKETS-1];
    integer bypass_bins [0:MAX_BINS-1];
    integer shaped_bins [0:MAX_BINS-1];
    integer init_index;
    integer watchdog;
    integer csv_file;
    integer event_file;

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
        .SEQUENCE_WIDTH(32),
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
        .o_shaping_deferred(),
        .o_deferred_by_direct_push(),
        .o_deferred_by_scheduling_pop(),
        .o_deferred_by_schedule_backpressure(),
        .o_shaping_deferred_cycles(),
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

    function automatic [DATA_WIDTH-1:0] make_packet_data;
        input [2:0] flow;
        input integer packet_id;
        begin
            make_packet_data =
                {1'b0, flow, packet_id[11:0], 16'b0};
        end
    endfunction

    function automatic integer active_output_count;
        input integer mode;
        begin
            active_output_count = (mode == 0) ?
                bypass_output_count : shaped_output_count;
        end
    endfunction

    always @(posedge clk) begin
        if (arst_n) begin
            if ((case_mode == 0) && direct_fire)
                bypass_accept_count <= bypass_accept_count + 1;
            if ((case_mode == 1) && d_transaction_fire)
                shaped_accept_count <= shaped_accept_count + 1;
            if ((case_mode == 1) && shaping_fire) begin
                if (wall_time < shaping_release_time)
                    $fatal(1, "A/B Y reference admitted before eligibility");
                shaped_release_count <= shaped_release_count + 1;
            end

            if (packet_out_valid && ((case_mode == 0) ||
                                     (case_mode == 1))) begin
                integer packet_id;
                integer packet_flow;
                packet_id = int'(packet_out_data[27:16]);
                packet_flow = int'(packet_out_data[30:28]);
                if ((packet_id < 0) || (packet_id >= PACKETS))
                    $fatal(1, "A/B output packet id out of range: %0d",
                        packet_id);
                if ((packet_flow < int'(FLOW_C)) ||
                    (packet_flow > int'(FLOW_B)))
                    $fatal(1, "A/B output flow out of range: %0d",
                        packet_flow);
                if (((packet_flow == int'(FLOW_C)) &&
                     (packet_out_node != NODE_Y)) ||
                    ((packet_flow != int'(FLOW_C)) &&
                     (packet_out_node != NODE_Z)))
                    $fatal(1,
                        "A/B output node mismatch flow=%0d node=%0d",
                        packet_flow, packet_out_node);

                if (case_mode == 0) begin
                    if (bypass_seen[packet_id])
                        $fatal(1, "duplicate bypass packet id=%0d",
                            packet_id);
                    if (bypass_output_count >= PACKETS)
                        $fatal(1, "bypass output log overflow");
                    bypass_seen[packet_id] <= 1'b1;
                    bypass_output_cycle[bypass_output_count] <=
                        TIME_WIDTH'(longint'(wall_time) - case_epoch);
                    bypass_output_flow[bypass_output_count] <=
                        packet_flow[2:0];
                    bypass_output_node[bypass_output_count] <=
                        packet_out_node;
                    bypass_output_count <= bypass_output_count + 1;
                end else begin
                    if (shaped_seen[packet_id])
                        $fatal(1, "duplicate shaped packet id=%0d",
                            packet_id);
                    if (shaped_output_count >= PACKETS)
                        $fatal(1, "shaped output log overflow");
                    shaped_seen[packet_id] <= 1'b1;
                    shaped_output_cycle[shaped_output_count] <=
                        TIME_WIDTH'(longint'(wall_time) - case_epoch);
                    shaped_output_flow[shaped_output_count] <=
                        packet_flow[2:0];
                    shaped_output_node[shaped_output_count] <=
                        packet_out_node;
                    if ((shaped_output_count < (PACKETS - 1)) &&
                        ((shaped_accept_count >
                          (shaped_output_count + 1)) || d_valid))
                        shaped_backlogged_output_count <=
                            shaped_backlogged_output_count + 1;
                    shaped_output_count <= shaped_output_count + 1;
                end
            end
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
            @(posedge clk);
            @(negedge clk);
            token_cfg_valid = 1'b0;
        end
    endtask

    task automatic prepare_packet;
        input integer packet_id;
        input integer use_shaping;
        integer rank_index;
        integer flow;
        reg [1:0] target;
        reg [DATA_WIDTH-1:0] data;
        begin
            case (packet_id % 3)
                0: begin
                    flow = int'(FLOW_C);
                    target = NODE_Y;
                end
                1: begin
                    flow = int'(FLOW_A);
                    target = NODE_Z;
                end
                default: begin
                    flow = int'(FLOW_B);
                    target = NODE_Z;
                end
            endcase
            data = make_packet_data(flow[2:0], packet_id);

            for (rank_index = 0; rank_index < LOGICAL_TREE_NUM;
                 rank_index = rank_index + 1) begin
                if (use_shaping != 0)
                    d_rank[rank_index] = 16'hffff;
                else
                    direct_rank[rank_index] = 16'hffff;
            end
            if (use_shaping != 0) begin
                d_target = target;
                d_rank[NODE_ROOT] = 16'd2;
                d_rank[NODE_Y] = PTW'(packet_id);
                if (target == NODE_Z)
                    d_rank[NODE_Z] = PTW'(packet_id);
                d_data = data;
            end else begin
                direct_target = target;
                direct_rank[NODE_ROOT] = 16'd2;
                direct_rank[NODE_Y] = PTW'(packet_id);
                if (target == NODE_Z)
                    direct_rank[NODE_Z] = PTW'(packet_id);
                direct_data = data;
            end
        end
    endtask

    task automatic burst_producer;
        input integer use_shaping;
        integer packet_id;
        reg accepted;
        begin
            for (packet_id = 0; packet_id < PACKETS;
                 packet_id = packet_id + 1) begin
                @(negedge clk);
                prepare_packet(packet_id, use_shaping);
                accepted = 1'b0;
                if (use_shaping != 0)
                    d_valid = 1'b1;
                else
                    direct_valid = 1'b1;
                while (!accepted) begin
                    @(posedge clk);
                    if ((use_shaping != 0) ? d_ready : direct_ready)
                        accepted = 1'b1;
                end
                @(negedge clk);
                d_valid = 1'b0;
                direct_valid = 1'b0;
            end
        end
    endtask

    task automatic fast_pop_consumer;
        input integer mode;
        integer output_target;
        reg accepted;
        begin
            while (active_output_count(mode) < PACKETS) begin
                @(negedge clk);
                pop_valid = 1'b0;
                if (schedule_logical_count[NODE_ROOT] != 0) begin
                    output_target = active_output_count(mode) + 1;
                    accepted = 1'b0;
                    pop_valid = 1'b1;
                    while (!accepted) begin
                        @(posedge clk);
                        if (pop_ready)
                            accepted = 1'b1;
                    end
                    @(negedge clk);
                    pop_valid = 1'b0;
                    while (active_output_count(mode) < output_target)
                        @(negedge clk);
                end
            end
            pop_valid = 1'b0;
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
                    (schedule_logical_count[NODE_Y] != 0) ||
                    (schedule_logical_count[NODE_Z] != 0)) &&
                   (watchdog < 2000000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (watchdog == 2000000)
                $fatal(1,
                    "A/B drain timeout timing=%0d/%0d schedule=%0d/%0d logical=%0d,%0d,%0d busy=%0d",
                    timing_event_count, timing_release_count,
                    schedule_pending_count, schedule_outstanding_count,
                    schedule_logical_count[NODE_ROOT],
                    schedule_logical_count[NODE_Y],
                    schedule_logical_count[NODE_Z], busy);
        end
    endtask

    task automatic reset_case;
        begin
            @(negedge clk);
            case_mode = -1;
            arst_n = 1'b0;
            d_valid = 1'b0;
            direct_valid = 1'b0;
            pop_valid = 1'b0;
            token_cfg_valid = 1'b0;
            repeat (8) @(negedge clk);
            arst_n = 1'b1;
            repeat (4) @(negedge clk);
        end
    endtask

    task automatic run_case;
        input integer use_shaping;
        begin
            reset_case();
            if (use_shaping != 0)
                configure_empty_bucket();
            @(negedge clk);
            case_mode = use_shaping;
            case_epoch = longint'(wall_time);
            fork
                burst_producer(use_shaping);
                fast_pop_consumer(use_shaping);
            join
            wait_for_empty_domains();
            if (protocol_error)
                $fatal(1, "A/B protocol_error mode=%0d", use_shaping);
        end
    endtask

    task automatic write_results;
        integer packet_index;
        integer bin_index;
        integer max_bin;
        integer bypass_cumulative;
        integer shaped_cumulative;
        integer bypass_gap;
        integer shaped_gap;
        integer bypass_peak;
        integer shaped_peak;
        integer bypass_min_gap;
        integer shaped_min_gap;
        integer shaped_max_gap;
        longint bypass_rate;
        longint shaped_rate;
        longint bypass_interval_bps;
        longint shaped_interval_bps;
        longint shaped_rate_error;
        longint shaped_rate_error_ppm;
        begin
            for (bin_index = 0; bin_index < MAX_BINS;
                 bin_index = bin_index + 1) begin
                bypass_bins[bin_index] = 0;
                shaped_bins[bin_index] = 0;
            end
            max_bin = 0;
            for (packet_index = 0; packet_index < PACKETS;
                 packet_index = packet_index + 1) begin
                bin_index = bypass_output_cycle[packet_index] / BIN_CYCLES;
                if ((bin_index < 0) || (bin_index >= MAX_BINS))
                    $fatal(1, "bypass bin overflow: %0d", bin_index);
                bypass_bins[bin_index] = bypass_bins[bin_index] + 1;
                if (bin_index > max_bin)
                    max_bin = bin_index;
                bin_index = shaped_output_cycle[packet_index] / BIN_CYCLES;
                if ((bin_index < 0) || (bin_index >= MAX_BINS))
                    $fatal(1, "shaped bin overflow: %0d", bin_index);
                shaped_bins[bin_index] = shaped_bins[bin_index] + 1;
                if (bin_index > max_bin)
                    max_bin = bin_index;
            end

            bypass_peak = 0;
            shaped_peak = 0;
            for (bin_index = 0; bin_index <= max_bin;
                 bin_index = bin_index + 1) begin
                if (bypass_bins[bin_index] > bypass_peak)
                    bypass_peak = bypass_bins[bin_index];
                if (shaped_bins[bin_index] > shaped_peak)
                    shaped_peak = shaped_bins[bin_index];
            end
            bypass_min_gap = 32'h7fffffff;
            shaped_min_gap = 32'h7fffffff;
            shaped_max_gap = 0;
            for (packet_index = 1; packet_index < PACKETS;
                 packet_index = packet_index + 1) begin
                bypass_gap = bypass_output_cycle[packet_index] -
                    bypass_output_cycle[packet_index - 1];
                shaped_gap = shaped_output_cycle[packet_index] -
                    shaped_output_cycle[packet_index - 1];
                if (bypass_gap < bypass_min_gap)
                    bypass_min_gap = bypass_gap;
                if (shaped_gap < shaped_min_gap)
                    shaped_min_gap = shaped_gap;
                if (shaped_gap > shaped_max_gap)
                    shaped_max_gap = shaped_gap;
            end
            bypass_interval_bps =
                (longint'(PACKETS) - 64'd1) * longint'(PACKET_BITS) *
                longint'(CLOCK_HZ) /
                (longint'(bypass_output_cycle[PACKETS - 1]) -
                 longint'(bypass_output_cycle[0]));
            shaped_interval_bps =
                (longint'(PACKETS) - 64'd1) * longint'(PACKET_BITS) *
                longint'(CLOCK_HZ) /
                (longint'(shaped_output_cycle[PACKETS - 1]) -
                 longint'(shaped_output_cycle[0]));
            shaped_rate_error = (shaped_interval_bps >= TARGET_BPS) ?
                (shaped_interval_bps - TARGET_BPS) :
                (TARGET_BPS - shaped_interval_bps);
            shaped_rate_error_ppm =
                shaped_rate_error * 64'd1000000 / TARGET_BPS;

            if ((bypass_accept_count != PACKETS) ||
                (shaped_accept_count != PACKETS) ||
                (shaped_release_count != PACKETS) ||
                (bypass_output_count != PACKETS) ||
                (shaped_output_count != PACKETS))
                $fatal(1,
                    "A/B exactly-once mismatch accept=%0d/%0d release=%0d output=%0d/%0d",
                    bypass_accept_count, shaped_accept_count,
                    shaped_release_count, bypass_output_count,
                    shaped_output_count);
            if (shaped_backlogged_output_count != (PACKETS - 1))
                $fatal(1,
                    "A/B shaped source was not backlogged at every non-final output: %0d/%0d",
                    shaped_backlogged_output_count, PACKETS - 1);
            for (packet_index = 0; packet_index < PACKETS;
                 packet_index = packet_index + 1)
                if (!bypass_seen[packet_index] || !shaped_seen[packet_index])
                    $fatal(1, "A/B missing packet id=%0d", packet_index);
            if (bypass_peak <= shaped_peak)
                $fatal(1, "A/B bypass did not produce a larger burst");
            if (bypass_peak < (shaped_peak * 2))
                $fatal(1, "A/B burst contrast is too small");
            if (shaped_peak > (BIN_SERVICE_INTERVALS + 1))
                $fatal(1, "A/B shaped fixed-window peak is too large: %0d",
                    shaped_peak);
            if (shaped_min_gap <
                (TARGET_SERVICE_TIME - 32))
                $fatal(1,
                    "A/B shaped output gap too small: %0d cycles",
                    shaped_min_gap);
            if (shaped_max_gap >
                (TARGET_SERVICE_TIME + 32))
                $fatal(1,
                    "A/B shaped output gap too large: %0d cycles",
                    shaped_max_gap);
            if (shaped_rate_error_ppm > RATE_TOLERANCE_PPM)
                $fatal(1,
                    "A/B shaped rate misses target: actual=%0d target=%0d error_ppm=%0d",
                    shaped_interval_bps, TARGET_BPS,
                    shaped_rate_error_ppm);
            if (bypass_interval_bps <= shaped_interval_bps)
                $fatal(1,
                    "A/B bypass interval rate did not exceed shaped rate");

            csv_file = $fopen("non_conserving_ab_timeseries.csv", "w");
            if (csv_file == 0)
                $fatal(1, "failed to create A/B timeseries CSV");
            $fwrite(csv_file,
                "target_bps,packet_bytes,bin_index,bin_start_cycle,bin_end_cycle,bypass_packets,shaped_packets,bypass_bps,shaped_bps,bypass_cumulative,shaped_cumulative\n");
            bypass_cumulative = 0;
            shaped_cumulative = 0;
            for (bin_index = 0; bin_index <= max_bin;
                 bin_index = bin_index + 1) begin
                bypass_cumulative = bypass_cumulative +
                    bypass_bins[bin_index];
                shaped_cumulative = shaped_cumulative +
                    shaped_bins[bin_index];
                bypass_rate = longint'(bypass_bins[bin_index]) *
                    longint'(PACKET_BITS) * longint'(CLOCK_HZ) /
                    longint'(BIN_CYCLES);
                shaped_rate = longint'(shaped_bins[bin_index]) *
                    longint'(PACKET_BITS) * longint'(CLOCK_HZ) /
                    longint'(BIN_CYCLES);
                $fwrite(csv_file,
                    "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    TARGET_BPS, PACKET_BYTES, bin_index,
                    bin_index * BIN_CYCLES,
                    (bin_index + 1) * BIN_CYCLES,
                    bypass_bins[bin_index], shaped_bins[bin_index],
                    bypass_rate, shaped_rate,
                    bypass_cumulative, shaped_cumulative);
            end
            $fclose(csv_file);

            event_file = $fopen("non_conserving_ab_events.csv", "w");
            if (event_file == 0)
                $fatal(1, "failed to create A/B event CSV");
            $fwrite(event_file,
                "mode,output_index,flow,node,output_cycle,interdeparture_cycles\n");
            for (packet_index = 0; packet_index < PACKETS;
                 packet_index = packet_index + 1) begin
                bypass_gap = (packet_index == 0) ? -1 :
                    bypass_output_cycle[packet_index] -
                    bypass_output_cycle[packet_index - 1];
                shaped_gap = (packet_index == 0) ? -1 :
                    shaped_output_cycle[packet_index] -
                    shaped_output_cycle[packet_index - 1];
                $fwrite(event_file,
                    "bypass,%0d,%0d,%0d,%0d,%0d\n",
                    packet_index, bypass_output_flow[packet_index],
                    bypass_output_node[packet_index],
                    bypass_output_cycle[packet_index], bypass_gap);
                $fwrite(event_file,
                    "token_bucket,%0d,%0d,%0d,%0d,%0d\n",
                    packet_index, shaped_output_flow[packet_index],
                    shaped_output_node[packet_index],
                    shaped_output_cycle[packet_index], shaped_gap);
            end
            $fclose(event_file);

            $display("NON_CONSERVING_AB_RESULT,target_bps=%0d,packets=%0d,packet_bytes=%0d,bin_cycles=%0d",
                TARGET_BPS, PACKETS, PACKET_BYTES, BIN_CYCLES);
            $display("NON_CONSERVING_AB_BYPASS,peak_bin_packets=%0d,min_gap=%0d,interval_bps=%0d,first=%0d,last=%0d",
                bypass_peak, bypass_min_gap, bypass_interval_bps,
                bypass_output_cycle[0],
                bypass_output_cycle[PACKETS - 1]);
            $display("NON_CONSERVING_AB_SHAPED,peak_bin_packets=%0d,min_gap=%0d,max_gap=%0d,interval_bps=%0d,error_ppm=%0d,backlogged_outputs=%0d/%0d,first=%0d,last=%0d",
                shaped_peak, shaped_min_gap, shaped_max_gap,
                shaped_interval_bps, shaped_rate_error_ppm,
                shaped_backlogged_output_count, PACKETS - 1,
                shaped_output_cycle[0],
                shaped_output_cycle[PACKETS - 1]);
            $display("PASS: same-burst Y Token Bucket versus scheduling bypass A/B experiment");
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
        d_service_time = TARGET_SERVICE_TIME;
        d_data = 0;
        direct_valid = 1'b0;
        direct_target = NODE_Y;
        direct_data = 0;
        pop_valid = 1'b0;
        case_mode = -1;
        case_epoch = 0;
        bypass_output_count = 0;
        shaped_output_count = 0;
        bypass_accept_count = 0;
        shaped_accept_count = 0;
        shaped_release_count = 0;
        shaped_backlogged_output_count = 0;
        for (init_index = 0; init_index < LOGICAL_TREE_NUM;
             init_index = init_index + 1) begin
            d_rank[init_index] = 16'hffff;
            direct_rank[init_index] = 16'hffff;
        end
        for (init_index = 0; init_index < PACKETS;
             init_index = init_index + 1) begin
            bypass_seen[init_index] = 1'b0;
            shaped_seen[init_index] = 1'b0;
            bypass_output_cycle[init_index] = 0;
            shaped_output_cycle[init_index] = 0;
            bypass_output_flow[init_index] = 0;
            shaped_output_flow[init_index] = 0;
            bypass_output_node[init_index] = 0;
            shaped_output_node[init_index] = 0;
        end

        run_case(0);
        run_case(1);
        write_results();
        $finish;
    end

    initial begin
        repeat (10000000) @(posedge clk);
        $fatal(1, "A/B experiment timeout");
    end

    initial begin
        if ((TARGET_SERVICE_TIME < 64) || (PACKETS < 6) ||
            (PACKETS > 120))
            $fatal(1, "invalid A/B experiment parameters");
    end
endmodule
