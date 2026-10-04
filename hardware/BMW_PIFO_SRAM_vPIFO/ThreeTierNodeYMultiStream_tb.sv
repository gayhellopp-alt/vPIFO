`timescale 1ns / 10ps

// Full-tree mixed-traffic regression for the 3/1/1/1 scheduling layout.
// C/A/B share one aggregate Y Token Bucket.  F/D/E use the direct path.
module ThreeTierNodeYMultiStream_tb #(
    parameter integer TARGET_SERVICE_TIME = 150,
    parameter integer CLOCK_FREQUENCY_HZ = 125000000,
    parameter integer SUSTAINED_MODE = 0,
    parameter integer SUSTAINED_WARMUP_SERVICE_INTERVALS = 8,
    parameter integer SUSTAINED_MEASUREMENT_SERVICE_INTERVALS = 3000,
    // Maximum number of accepted Root Pops whose final packet result has not
    // returned.  One preserves the historical conservative consumer.  Larger
    // values exercise the recursive Pop track/pending machinery as a pipeline.
    parameter integer SUSTAINED_POP_WINDOW = 1,
    // Preserve the strict historical sustained regression by default.  The
    // rate-curve mode retains protocol, backlog, exactly-once, and final-drain
    // checks while allowing Scheduling throughput to fall below eligibility
    // throughput at deliberately overdriven rate points.
    parameter integer SUSTAINED_RATE_CURVE_MODE = 0,
    parameter integer TIMING_SEQUENCE_WIDTH = 32,
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
    localparam PHYSICAL_TREE_NUM = 6;
    localparam PHYSICAL_ID_WIDTH = 3;
    localparam SHARD_COUNT_WIDTH = 7;

    localparam PHASE1_PACKETS_PER_FLOW = 8;
    localparam PHASE2_PACKETS_PER_FLOW = 40;
    localparam PHASE1_SHAPED_PACKETS = 3 * PHASE1_PACKETS_PER_FLOW;
    localparam PHASE2_SHAPED_PACKETS = 3 * PHASE2_PACKETS_PER_FLOW;
    localparam PHASE1_TOTAL_PACKETS = 6 * PHASE1_PACKETS_PER_FLOW;
    localparam PHASE2_TOTAL_PACKETS = 6 * PHASE2_PACKETS_PER_FLOW;

    localparam VISIBILITY_SERVICE_TIME = 2000;
    localparam PACKET_BYTES = 1500;
    localparam PACKET_BITS = PACKET_BYTES * 8;
    localparam longint CLOCK_HZ = longint'(CLOCK_FREQUENCY_HZ);
    localparam integer STEADY_SERVICE_TIME = TARGET_SERVICE_TIME;
    localparam longint TARGET_BPS =
        (64'd12000 * CLOCK_HZ) /
        longint'(STEADY_SERVICE_TIME);
    localparam integer PHASE2_WATCHDOG_CYCLES =
        (STEADY_SERVICE_TIME * PHASE2_SHAPED_PACKETS) + 500000;
    localparam integer GLOBAL_WATCHDOG_CYCLES =
        PHASE2_WATCHDOG_CYCLES + 2000000;
    localparam integer SUSTAINED_ID_SPACE = 4096;
    localparam integer SUSTAINED_ELIGIBILITY_LOG_DEPTH =
        ((SUSTAINED_MEASUREMENT_SERVICE_INTERVALS + 4096) > 16384) ?
        (SUSTAINED_MEASUREMENT_SERVICE_INTERVALS + 4096) : 16384;
    localparam integer SUSTAINED_WARMUP_CYCLES =
        (STEADY_SERVICE_TIME * SUSTAINED_WARMUP_SERVICE_INTERVALS) +
        2000;
    localparam integer SUSTAINED_MEASUREMENT_CYCLES =
        STEADY_SERVICE_TIME * SUSTAINED_MEASUREMENT_SERVICE_INTERVALS;
    localparam integer SUSTAINED_GLOBAL_WATCHDOG_CYCLES =
        SUSTAINED_WARMUP_CYCLES + SUSTAINED_MEASUREMENT_CYCLES + 10000000;
    localparam integer RUN_WATCHDOG_CYCLES = (SUSTAINED_MODE != 0) ?
        SUSTAINED_GLOBAL_WATCHDOG_CYCLES : GLOBAL_WATCHDOG_CYCLES;
    // Leave scheduler headroom for recursive Pops while direct traffic keeps
    // the Root/X path contended.  The producer still uses valid/ready for
    // admission; this gap controls offered load rather than bypassing it.
    localparam integer DIRECT_OFFER_GAP_CYCLES = 64;
    localparam integer SHAPED_OFFER_GAP_CYCLES = 16;
    // The integrated scheduling domain has 32 pending entries.  Reserve eight
    // so that a due PARENT_REF and in-flight recursive child requests cannot be
    // locked out by speculative Root Pops.
    localparam integer SUSTAINED_PENDING_GUARD = 24;
    localparam realtime CLOCK_HALF_PERIOD_NS =
        500000000.0 / CLOCK_FREQUENCY_HZ;

    localparam [1:0] NODE_ROOT = 2'd0;
    localparam [1:0] NODE_X = 2'd1;
    localparam [1:0] NODE_Y = 2'd2;
    localparam [1:0] NODE_Z = 2'd3;

    localparam [2:0] FLOW_F = 3'd0;
    localparam [2:0] FLOW_D = 3'd1;
    localparam [2:0] FLOW_E = 3'd2;
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
    wire shaping_deferred;
    wire deferred_by_direct_push;
    wire deferred_by_scheduling_pop;
    wire deferred_by_schedule_backpressure;
    wire [31:0] shaping_deferred_cycles;
    wire [TIME_WIDTH-1:0] release_delay_last;
    wire [TIME_WIDTH-1:0] release_delay_max;
    wire [5:0] timing_event_count;
    wire [4:0] timing_release_count;
    wire [9:0] schedule_logical_count [0:LOGICAL_TREE_NUM-1];
    wire [SCHEDULE_PENDING_COUNT_WIDTH-1:0] schedule_pending_count;
    wire [SCHEDULE_TRACK_COUNT_WIDTH-1:0] schedule_outstanding_count;
    wire [LOGICAL_TREE_NUM-1:0] schedule_dispatch_fire;
    wire [LOGICAL_TREE_NUM-1:0] schedule_dispatch_push;
    wire [PHYSICAL_ID_WIDTH-1:0]
        schedule_selected_physical [0:LOGICAL_TREE_NUM-1];
    wire [SHARD_COUNT_WIDTH-1:0]
        schedule_shard_count [0:PHYSICAL_TREE_NUM-1];
    wire timing_busy;
    wire schedule_busy;
    wire busy;
    wire protocol_error;

    integer active_phase;
    integer expected_packets_per_flow;
    integer accepted_count [0:5];
    integer output_count [0:5];
    integer physical_push_count [0:PHYSICAL_TREE_NUM-1];
    integer shaped_tx_count;
    integer shaping_release_count;
    integer shaped_output_count;
    integer watchdog;
    integer monitor_index;
    integer monitor_class;
    integer monitor_sequence;
    integer monitor_physical;
    integer check_index;
    integer min_root_pushes;
    integer max_root_pushes;
    reg packet_seen [0:5][0:PHASE2_PACKETS_PER_FLOW-1];
    reg [TIME_WIDTH-1:0]
        eligibility_log [0:PHASE2_SHAPED_PACKETS-1];
    reg [TIME_WIDTH-1:0]
        root_admission_log [0:PHASE2_SHAPED_PACKETS-1];
    reg [TIME_WIDTH-1:0]
        shaped_output_log [0:PHASE2_SHAPED_PACKETS-1];
    longint rate_numerator;
    longint eligibility_rate_bps;
    longint root_admission_rate_bps;
    longint packet_output_interval_bps;
    longint packet_output_end_to_end_bps;
    longint rate_duration;

    integer sustained_next_sequence [0:5];
    integer sustained_accepted_id_count [0:5][0:SUSTAINED_ID_SPACE-1];
    integer sustained_output_id_count [0:5][0:SUSTAINED_ID_SPACE-1];
    integer sustained_accepted_total;
    integer sustained_shaped_accepted_total;
    integer sustained_output_total;
    integer sustained_shaped_output_total;
    integer sustained_measurement_shaped_packets;
    integer sustained_measurement_tx_packets;
    integer sustained_measurement_admission_packets;
    integer sustained_measurement_pop_accepts;
    integer sustained_pop_accept_total;
    integer sustained_max_outstanding_count;
    integer sustained_max_pending_count;
    integer sustained_max_timing_pending_count;
    integer sustained_max_event_table_count;
    integer sustained_max_release_fifo_count;
    integer sustained_max_schedule_pop_result_count;
    integer sustained_max_timing_pop_result_count;
    integer sustained_direct_cursor;
    integer sustained_shaped_cursor;
    reg sustained_direct_done;
    reg sustained_shaped_done;
    reg sustained_pop_done;
    integer sustained_watchdog;
    integer sustained_flow;
    integer sustained_sequence;
    integer sustained_id;
    integer sustained_gap;
    integer sustained_shard_index;
    integer sustained_flow_index;
    integer sustained_id_index;
    reg sustained_inject_enable;
    reg sustained_pop_enable;
    reg sustained_measurement_active;
    longint sustained_measurement_start_time;
    longint sustained_measurement_end_time;
    longint sustained_measurement_shaped_bytes;
    longint sustained_measurement_tx_bytes;
    longint sustained_measurement_admission_bytes;
    longint sustained_source_valid_cycles;
    longint sustained_source_stalled_cycles;
    longint sustained_work_backlogged_cycles;
    longint sustained_local_subtree_backlogged_cycles;
    longint sustained_timing_backlogged_cycles;
    longint sustained_event_table_backlogged_cycles;
    longint sustained_eligible_release_backlogged_cycles;
    integer sustained_eligibility_log_count;
    reg [TIME_WIDTH-1:0] sustained_eligibility_log
        [0:SUSTAINED_ELIGIBILITY_LOG_DEPTH-1];
    reg sustained_have_first_eligibility;
    reg sustained_have_shaped_output;
    reg sustained_have_window_admission;
    reg sustained_have_window_shaped_output;
    longint sustained_first_eligibility_time;
    longint sustained_last_shaped_output_time;
    longint sustained_first_window_admission_time;
    longint sustained_last_window_admission_time;
    longint sustained_first_window_shaped_output_time;
    longint sustained_last_window_shaped_output_time;

    always #(CLOCK_HALF_PERIOD_NS) clk = ~clk;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n)
            wall_time <= {TIME_WIDTH{1'b0}};
        else
            wall_time <= wall_time + 1'b1;
    end

    ThreeTierTokenBucketVPIFO #(
        .PTW(PTW),
        .MTW(MTW),
        // Long sustained runs use a configurable timing sequence width so
        // wrap/drain behavior can be measured without changing packet IDs.
        .SEQUENCE_WIDTH(TIMING_SEQUENCE_WIDTH),
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
        .o_deferred_by_scheduling_pop(deferred_by_scheduling_pop),
        .o_deferred_by_schedule_backpressure(
            deferred_by_schedule_backpressure),
        .o_shaping_deferred_cycles(shaping_deferred_cycles),
        .o_release_delay_last(release_delay_last),
        .o_release_delay_max(release_delay_max),
        .o_timing_event_table_count(timing_event_count),
        .o_timing_release_fifo_count(timing_release_count),
        .o_schedule_logical_count(schedule_logical_count),
        .o_schedule_pending_count(schedule_pending_count),
        .o_schedule_outstanding_pop_count(schedule_outstanding_count),
        .o_schedule_physical_dispatch_fire(schedule_dispatch_fire),
        .o_schedule_physical_dispatch_push(schedule_dispatch_push),
        .o_schedule_selected_physical_tree_id(schedule_selected_physical),
        .o_schedule_shard_count(schedule_shard_count),
        .o_timing_busy(timing_busy),
        .o_schedule_busy(schedule_busy),
        .o_busy(busy),
        .o_protocol_error(protocol_error)
    );

    function automatic [DATA_WIDTH-1:0] make_packet_data;
        input [2:0] traffic_class;
        input integer packet_sequence;
        begin
            make_packet_data =
                {1'b0, traffic_class, packet_sequence[11:0], 16'd1500};
        end
    endfunction

    function automatic integer total_outputs;
        integer flow_index;
        begin
            total_outputs = 0;
            for (flow_index = 0; flow_index < 6;
                 flow_index = flow_index + 1)
                total_outputs = total_outputs + output_count[flow_index];
        end
    endfunction

    task automatic configure_empty_bucket;
        reg accepted;
        begin
            while (!token_cfg_ready)
                @(negedge clk);
            token_cfg_capacity = 0;
            token_cfg_credit = 0;
            token_cfg_state_time = wall_time;
            token_cfg_state_valid = 1'b1;
            token_cfg_valid = 1'b1;
            accepted = 0;
            while (!accepted) begin
                @(posedge clk);
                if (token_cfg_ready)
                    accepted = 1;
            end
            @(negedge clk);
            token_cfg_valid = 1'b0;
        end
    endtask

    task automatic send_direct_packet;
        input [2:0] traffic_class;
        input integer packet_sequence;
        reg accepted;
        integer rank_index;
        begin
            @(negedge clk);
            for (rank_index = 0; rank_index < LOGICAL_TREE_NUM;
                 rank_index = rank_index + 1)
                direct_rank[rank_index] = 16'hffff;
            case (traffic_class)
                FLOW_F: begin
                    direct_target = NODE_ROOT;
                    direct_rank[NODE_ROOT] = 16'd0;
                end
                FLOW_D: begin
                    direct_target = NODE_X;
                    direct_rank[NODE_ROOT] = 16'd1;
                    direct_rank[NODE_X] = PTW'(2 * packet_sequence);
                end
                FLOW_E: begin
                    direct_target = NODE_X;
                    direct_rank[NODE_ROOT] = 16'd1;
                    direct_rank[NODE_X] = PTW'(2 * packet_sequence + 1);
                end
                default:
                    $fatal(1, "invalid direct traffic class %0d",
                        traffic_class);
            endcase
            direct_data = make_packet_data(traffic_class, packet_sequence);
            direct_valid = 1'b1;
            accepted = 0;
            while (!accepted) begin
                @(posedge clk);
                if (direct_ready)
                    accepted = 1;
            end
            @(negedge clk);
            direct_valid = 1'b0;
        end
    endtask

    task automatic send_shaped_packet;
        input [2:0] traffic_class;
        input integer packet_sequence;
        input integer service_time;
        reg accepted;
        integer rank_index;
        begin
            @(negedge clk);
            for (rank_index = 0; rank_index < LOGICAL_TREE_NUM;
                 rank_index = rank_index + 1)
                d_rank[rank_index] = 16'hffff;
            d_rank[NODE_ROOT] = 16'd2;
            case (traffic_class)
                FLOW_C: begin
                    d_target = NODE_Y;
                    d_rank[NODE_Y] = PTW'(3 * packet_sequence);
                end
                FLOW_A: begin
                    d_target = NODE_Z;
                    d_rank[NODE_Y] = PTW'(3 * packet_sequence + 1);
                    d_rank[NODE_Z] = PTW'(2 * packet_sequence);
                end
                FLOW_B: begin
                    d_target = NODE_Z;
                    d_rank[NODE_Y] = PTW'(3 * packet_sequence + 2);
                    d_rank[NODE_Z] = PTW'(2 * packet_sequence + 1);
                end
                default:
                    $fatal(1, "invalid shaped traffic class %0d",
                        traffic_class);
            endcase
            d_service_time = service_time;
            d_data = make_packet_data(traffic_class, packet_sequence);
            d_valid = 1'b1;
            accepted = 0;
            while (!accepted) begin
                @(posedge clk);
                if (d_ready)
                    accepted = 1;
            end
            @(negedge clk);
            d_valid = 1'b0;
        end
    endtask

    task automatic generate_direct_traffic;
        input integer packets_per_flow;
        integer packet_sequence;
        begin
            for (packet_sequence = 0;
                 packet_sequence < packets_per_flow;
                 packet_sequence = packet_sequence + 1) begin
                send_direct_packet(FLOW_F, packet_sequence);
                send_direct_packet(FLOW_D, packet_sequence);
                send_direct_packet(FLOW_E, packet_sequence);
            end
        end
    endtask

    task automatic generate_shaped_traffic;
        input integer packets_per_flow;
        input integer service_time;
        integer packet_sequence;
        begin
            for (packet_sequence = 0;
                 packet_sequence < packets_per_flow;
                 packet_sequence = packet_sequence + 1) begin
                send_shaped_packet(FLOW_C, packet_sequence, service_time);
                send_shaped_packet(FLOW_A, packet_sequence, service_time);
                send_shaped_packet(FLOW_B, packet_sequence, service_time);
            end
        end
    endtask

    task automatic consume_packets;
        input integer packet_count;
        integer consumed;
        reg accepted;
        integer output_target;
        begin
            output_target = total_outputs();
            for (consumed = 0; consumed < packet_count;
                 consumed = consumed + 1) begin
                while ((schedule_logical_count[NODE_ROOT] == 0) ||
                       !pop_ready)
                    @(negedge clk);
                pop_valid = 1'b1;
                accepted = 0;
                while (!accepted) begin
                    @(posedge clk);
                    if (pop_ready)
                        accepted = 1;
                end
                @(negedge clk);
                pop_valid = 1'b0;
                output_target = output_target + 1;
                while (total_outputs() < output_target)
                    @(negedge clk);
            end
        end
    endtask

    task automatic prepare_sustained_direct_packet;
        input integer traffic_class;
        input integer packet_sequence;
        integer rank_index;
        begin
            for (rank_index = 0; rank_index < LOGICAL_TREE_NUM;
                 rank_index = rank_index + 1)
                direct_rank[rank_index] = 16'hffff;
            case (traffic_class)
                int'(FLOW_F): begin
                    direct_target = NODE_ROOT;
                    direct_rank[NODE_ROOT] = 16'd0;
                end
                int'(FLOW_D): begin
                    direct_target = NODE_X;
                    direct_rank[NODE_ROOT] = 16'd1;
                    direct_rank[NODE_X] =
                        PTW'(2 * packet_sequence);
                end
                int'(FLOW_E): begin
                    direct_target = NODE_X;
                    direct_rank[NODE_ROOT] = 16'd1;
                    direct_rank[NODE_X] =
                        PTW'(2 * packet_sequence + 1);
                end
                default:
                    $fatal(1, "invalid sustained direct traffic class %0d",
                        traffic_class);
            endcase
            direct_data = make_packet_data(
                traffic_class[2:0], packet_sequence);
        end
    endtask

    task automatic prepare_sustained_shaped_packet;
        input integer traffic_class;
        input integer packet_sequence;
        integer rank_index;
        begin
            for (rank_index = 0; rank_index < LOGICAL_TREE_NUM;
                 rank_index = rank_index + 1)
                d_rank[rank_index] = 16'hffff;
            d_rank[NODE_ROOT] = 16'd2;
            case (traffic_class)
                int'(FLOW_C): begin
                    d_target = NODE_Y;
                    d_rank[NODE_Y] = PTW'(3 * packet_sequence);
                end
                int'(FLOW_A): begin
                    d_target = NODE_Z;
                    d_rank[NODE_Y] = PTW'(3 * packet_sequence + 1);
                    d_rank[NODE_Z] = PTW'(2 * packet_sequence);
                end
                int'(FLOW_B): begin
                    d_target = NODE_Z;
                    d_rank[NODE_Y] = PTW'(3 * packet_sequence + 2);
                    d_rank[NODE_Z] =
                        PTW'(2 * packet_sequence + 1);
                end
                default:
                    $fatal(1, "invalid sustained shaped traffic class %0d",
                        traffic_class);
            endcase
            d_service_time = STEADY_SERVICE_TIME;
            d_data = make_packet_data(
                traffic_class[2:0], packet_sequence);
        end
    endtask

    task automatic sustained_direct_producer;
        integer current_flow;
        integer current_sequence;
        reg accepted;
        integer gap_index;
        begin
            sustained_direct_done = 0;
            current_flow = int'(FLOW_F);
            while (sustained_inject_enable) begin
                current_sequence = sustained_next_sequence[current_flow];
                while (sustained_inject_enable &&
                       ((schedule_logical_count[NODE_X] >= 96) ||
                        (schedule_logical_count[NODE_ROOT] >= 300)))
                    @(negedge clk);
                @(negedge clk);
                prepare_sustained_direct_packet(
                    current_flow, current_sequence);
                direct_valid = 1'b1;
                accepted = 0;
                while (sustained_inject_enable && !accepted) begin
                    @(posedge clk);
                    if (direct_ready)
                        accepted = 1;
                end
                @(negedge clk);
                direct_valid = 1'b0;
                if (accepted) begin
                    if (current_sequence >= SUSTAINED_ID_SPACE - 1)
                        sustained_next_sequence[current_flow] = 0;
                    else
                        sustained_next_sequence[current_flow] =
                            current_sequence + 1;
                    case (current_flow)
                        int'(FLOW_F): current_flow = int'(FLOW_D);
                        int'(FLOW_D): current_flow = int'(FLOW_E);
                        default: current_flow = int'(FLOW_F);
                    endcase
                    for (gap_index = 0;
                         gap_index < DIRECT_OFFER_GAP_CYCLES;
                         gap_index = gap_index + 1)
                        @(negedge clk);
                end
            end
            direct_valid = 1'b0;
            sustained_direct_done = 1;
        end
    endtask

    task automatic sustained_shaped_producer;
        integer current_flow;
        integer current_sequence;
        reg accepted;
        integer gap_index;
        begin
            sustained_shaped_done = 0;
            current_flow = int'(FLOW_C);
            while (sustained_inject_enable) begin
                current_sequence = sustained_next_sequence[current_flow];
                while (sustained_inject_enable &&
                       ((schedule_logical_count[NODE_Y] >= 96) ||
                        (schedule_logical_count[NODE_Z] >= 96)))
                    @(negedge clk);
                @(negedge clk);
                prepare_sustained_shaped_packet(
                    current_flow, current_sequence);
                d_valid = 1'b1;
                accepted = 0;
                while (sustained_inject_enable && !accepted) begin
                    @(posedge clk);
                    if (d_ready)
                        accepted = 1;
                end
                @(negedge clk);
                d_valid = 1'b0;
                if (accepted) begin
                    if (current_sequence >= SUSTAINED_ID_SPACE - 1)
                        sustained_next_sequence[current_flow] = 0;
                    else
                        sustained_next_sequence[current_flow] =
                            current_sequence + 1;
                    case (current_flow)
                        int'(FLOW_C): current_flow = int'(FLOW_A);
                        int'(FLOW_A): current_flow = int'(FLOW_B);
                        default: current_flow = int'(FLOW_C);
                    endcase
                    for (gap_index = 0;
                         gap_index < SHAPED_OFFER_GAP_CYCLES;
                         gap_index = gap_index + 1)
                        @(negedge clk);
                end
            end
            d_valid = 1'b0;
            sustained_shaped_done = 1;
        end
    endtask

    task automatic sustained_pop_consumer;
        reg accepted;
        begin
            sustained_pop_done = 1'b0;
            while (sustained_pop_enable) begin
                @(negedge clk);
                pop_valid = 1'b0;
                accepted = 1'b0;
                if ((int'(schedule_outstanding_count) <
                     SUSTAINED_POP_WINDOW) &&
                    (int'(schedule_logical_count[NODE_ROOT]) >
                     int'(schedule_outstanding_count)) &&
                    (int'(schedule_pending_count) <=
                     SUSTAINED_PENDING_GUARD) &&
                    !shaping_pending) begin
                    pop_valid = 1'b1;
                    while (sustained_pop_enable && !accepted) begin
                        @(posedge clk);
                        if (pop_ready)
                            accepted = 1'b1;
                    end
                    @(negedge clk);
                    pop_valid = 1'b0;
                end
            end
            pop_valid = 1'b0;
            sustained_pop_done = 1'b1;
        end
    endtask

    task automatic run_sustained_experiment;
        longint measurement_duration;
        longint envelope_duration;
        longint tx_acceptance_window_bps;
        longint eligibility_timestamp_window_bps;
        longint eligibility_timestamp_interval_bps;
        longint root_admission_window_bps;
        longint root_admission_interval_bps;
        longint packet_output_window_bps;
        longint packet_output_interval_rate;
        longint packet_output_envelope_rate;
        longint relative_error_percent_x100;
        longint source_valid_fraction_percent_x100;
        longint source_stalled_fraction_percent_x100;
        longint work_backlogged_fraction_percent_x100;
        longint local_subtree_backlogged_fraction_percent_x100;
        longint timing_backlogged_fraction_percent_x100;
        longint event_table_backlogged_fraction_percent_x100;
        longint eligible_release_backlogged_fraction_percent_x100;
        longint transaction_acceptance_cycles_per_packet_x1000;
        longint eligibility_cycles_per_packet_x1000;
        longint root_admission_cycles_per_packet_x1000;
        longint packet_output_cycles_per_packet_x1000;
        longint measured_output_count;
        longint measured_admission_count;
        longint eligibility_timestamp_count;
        longint first_window_eligibility_time;
        longint last_window_eligibility_time;
        integer eligibility_scan_index;
        begin
            active_phase = 3;
            sustained_inject_enable = 1'b0;
            sustained_pop_enable = 1'b0;
            sustained_measurement_active = 1'b0;
            repeat (8) @(negedge clk);
            arst_n = 1'b1;
            repeat (4) @(negedge clk);
            configure_empty_bucket();

            sustained_inject_enable = 1'b1;
            sustained_pop_enable = 1'b1;
            fork
                sustained_direct_producer();
                sustained_shaped_producer();
                sustained_pop_consumer();
            join_none

            repeat (SUSTAINED_WARMUP_CYCLES) @(posedge clk);
            // Change the measurement gate between sampling edges.  The
            // monitor below also runs on posedge, so using negedge here makes
            // the half-open [start,end) window deterministic in every
            // simulator.
            @(negedge clk);
            sustained_measurement_start_time = longint'(wall_time);
            sustained_measurement_active = 1'b1;
            repeat (SUSTAINED_MEASUREMENT_CYCLES) @(posedge clk);
            @(negedge clk);
            sustained_measurement_active = 1'b0;
            sustained_measurement_end_time = longint'(wall_time);
            sustained_inject_enable = 1'b0;

            sustained_watchdog = 0;
            while ((!sustained_direct_done || !sustained_shaped_done) &&
                   (sustained_watchdog < 1000000)) begin
                @(negedge clk);
                sustained_watchdog = sustained_watchdog + 1;
            end
            if (sustained_watchdog == 1000000)
                $fatal(1,
                    "sustained producer stop timeout direct=%0d shaped=%0d",
                    sustained_direct_done, sustained_shaped_done);

            sustained_watchdog = 0;
            while ((busy || (timing_event_count != 0) ||
                    (timing_release_count != 0) ||
                    (schedule_pending_count != 0) ||
                    (schedule_outstanding_count != 0) ||
                    (schedule_logical_count[NODE_ROOT] != 0) ||
                    (schedule_logical_count[NODE_X] != 0) ||
                    (schedule_logical_count[NODE_Y] != 0) ||
                    (schedule_logical_count[NODE_Z] != 0)) &&
                   (sustained_watchdog < 10000000)) begin
                @(negedge clk);
                sustained_watchdog = sustained_watchdog + 1;
                if ((sustained_watchdog % 1000000) == 0)
                    $display("SUSTAINED_DRAIN_PROGRESS,cycles=%0d,logical=%0d,%0d,%0d,%0d,timing=%0d/%0d,pending=%0d,outstanding=%0d,busy=%0d,pop=%0d/%0d,accepted=%0d,%0d,%0d,%0d,%0d,%0d,output=%0d,%0d,%0d,%0d,%0d,%0d",
                        sustained_watchdog,
                        schedule_logical_count[NODE_ROOT],
                        schedule_logical_count[NODE_X],
                        schedule_logical_count[NODE_Y],
                        schedule_logical_count[NODE_Z],
                        timing_event_count, timing_release_count,
                        schedule_pending_count, schedule_outstanding_count,
                        busy, pop_valid, pop_ready,
                        accepted_count[0], accepted_count[1], accepted_count[2],
                        accepted_count[3], accepted_count[4], accepted_count[5],
                        output_count[0], output_count[1], output_count[2],
                        output_count[3], output_count[4], output_count[5]);
            end
            if (sustained_watchdog == 10000000)
                $fatal(1,
                    "sustained drain timeout logical=%0d,%0d,%0d,%0d timing=%0d/%0d pending=%0d outstanding=%0d busy=%0d protocol=%0d",
                    schedule_logical_count[NODE_ROOT],
                    schedule_logical_count[NODE_X],
                    schedule_logical_count[NODE_Y],
                    schedule_logical_count[NODE_Z], timing_event_count,
                    timing_release_count, schedule_pending_count,
                    schedule_outstanding_count, busy, protocol_error);

            sustained_pop_enable = 1'b0;
            while (!sustained_pop_done)
                @(negedge clk);

            if (sustained_accepted_total != sustained_output_total)
                $fatal(1,
                    "sustained total packet mismatch accepted=%0d output=%0d",
                    sustained_accepted_total, sustained_output_total);
            if (sustained_shaped_accepted_total !=
                sustained_shaped_output_total)
                $fatal(1,
                    "sustained shaped packet mismatch accepted=%0d output=%0d",
                    sustained_shaped_accepted_total,
                    sustained_shaped_output_total);
            if (protocol_error) begin
                $display("SUSTAINED_PROTOCOL_DETAIL,transaction=%0d,timing=%0d,top_admission=%0d,scheduler=%0d,scheduler_wrapper=%0d,scheduler_core=%0d,logical=%0d,%0d,%0d,%0d,pending=%0d,outstanding=%0d,timing_count=%0d/%0d",
                    dut.transaction_engine_protocol_error,
                    dut.timing_protocol_error,
                    dut.local_protocol_error,
                    dut.scheduler_protocol_error,
                    dut.schedule_domain.local_protocol_error,
                    dut.schedule_domain.core_protocol_error,
                    schedule_logical_count[NODE_ROOT],
                    schedule_logical_count[NODE_X],
                    schedule_logical_count[NODE_Y],
                    schedule_logical_count[NODE_Z],
                    schedule_pending_count,
                    schedule_outstanding_count,
                    timing_event_count,
                    timing_release_count);
                $fatal(1, "sustained protocol_error");
            end
            for (sustained_flow_index = 0;
                 sustained_flow_index < 6;
                 sustained_flow_index = sustained_flow_index + 1)
                if (accepted_count[sustained_flow_index] !=
                    output_count[sustained_flow_index])
                    $fatal(1,
                        "sustained flow mismatch flow=%0d accepted=%0d output=%0d",
                        sustained_flow_index,
                        accepted_count[sustained_flow_index],
                        output_count[sustained_flow_index]);
            for (sustained_flow_index = 0;
                 sustained_flow_index < 6;
                 sustained_flow_index = sustained_flow_index + 1)
                for (sustained_id_index = 0;
                     sustained_id_index < SUSTAINED_ID_SPACE;
                     sustained_id_index = sustained_id_index + 1)
                    if (sustained_accepted_id_count[sustained_flow_index]
                            [sustained_id_index] !=
                        sustained_output_id_count[sustained_flow_index]
                            [sustained_id_index])
                        $fatal(1,
                            "sustained ID mismatch flow=%0d id=%0d accepted=%0d output=%0d",
                            sustained_flow_index, sustained_id_index,
                            sustained_accepted_id_count[sustained_flow_index]
                                [sustained_id_index],
                            sustained_output_id_count[sustained_flow_index]
                                [sustained_id_index]);

            measurement_duration =
                sustained_measurement_end_time -
                sustained_measurement_start_time;
            if (measurement_duration != longint'(
                    SUSTAINED_MEASUREMENT_CYCLES))
                $fatal(1,
                    "measurement duration=%0d expected=%0d",
                    measurement_duration,
                    SUSTAINED_MEASUREMENT_CYCLES);
            tx_acceptance_window_bps =
                sustained_measurement_tx_bytes * 8 * CLOCK_HZ /
                measurement_duration;
            root_admission_window_bps =
                sustained_measurement_admission_bytes * 8 * CLOCK_HZ /
                measurement_duration;
            packet_output_window_bps =
                sustained_measurement_shaped_bytes * 8 * CLOCK_HZ /
                measurement_duration;

            // Classify the transaction-computed eligibility timestamps after
            // the run.  This includes timestamps reserved during warm-up that
            // fall inside the measurement window and excludes transactions
            // accepted in the window whose eligibility lies after it.
            eligibility_timestamp_count = 0;
            first_window_eligibility_time = 0;
            last_window_eligibility_time = 0;
            for (eligibility_scan_index = 0;
                 eligibility_scan_index < sustained_eligibility_log_count;
                 eligibility_scan_index = eligibility_scan_index + 1) begin
                if ((longint'(sustained_eligibility_log[
                         eligibility_scan_index]) >=
                     sustained_measurement_start_time) &&
                    (longint'(sustained_eligibility_log[
                         eligibility_scan_index]) <
                     sustained_measurement_end_time)) begin
                    if (eligibility_timestamp_count == 0)
                        first_window_eligibility_time = longint'(
                            sustained_eligibility_log[
                                eligibility_scan_index]);
                    last_window_eligibility_time = longint'(
                        sustained_eligibility_log[eligibility_scan_index]);
                    eligibility_timestamp_count =
                        eligibility_timestamp_count + 1;
                end
            end
            eligibility_timestamp_window_bps =
                eligibility_timestamp_count * PACKET_BITS * CLOCK_HZ /
                measurement_duration;
            if ((eligibility_timestamp_count >= 2) &&
                (last_window_eligibility_time <=
                 first_window_eligibility_time))
                $fatal(1,
                    "non-increasing eligibility interval first=%0d last=%0d count=%0d",
                    first_window_eligibility_time,
                    last_window_eligibility_time,
                    eligibility_timestamp_count);
            if (eligibility_timestamp_count >= 2)
                eligibility_timestamp_interval_bps =
                    (eligibility_timestamp_count - 1) * PACKET_BITS *
                    CLOCK_HZ /
                    (last_window_eligibility_time -
                     first_window_eligibility_time);
            else
                eligibility_timestamp_interval_bps = 0;

            if (sustained_measurement_admission_packets >= 2 &&
                sustained_have_window_admission) begin
                if (sustained_last_window_admission_time <=
                    sustained_first_window_admission_time)
                    $fatal(1,
                        "non-increasing Root-admission interval first=%0d last=%0d count=%0d",
                        sustained_first_window_admission_time,
                        sustained_last_window_admission_time,
                        sustained_measurement_admission_packets);
                measured_admission_count =
                    longint'(sustained_measurement_admission_packets) - 1;
                root_admission_interval_bps =
                    measured_admission_count * PACKET_BITS * CLOCK_HZ /
                    (sustained_last_window_admission_time -
                     sustained_first_window_admission_time);
            end else
                root_admission_interval_bps = 0;
            if (sustained_measurement_shaped_packets >= 2) begin
                if (!sustained_have_window_shaped_output ||
                    (sustained_last_window_shaped_output_time <=
                     sustained_first_window_shaped_output_time))
                    $fatal(1,
                        "non-increasing packet-output interval first=%0d last=%0d count=%0d",
                        sustained_first_window_shaped_output_time,
                        sustained_last_window_shaped_output_time,
                        sustained_measurement_shaped_packets);
                measured_output_count =
                    longint'(sustained_measurement_shaped_packets) - 1;
                packet_output_interval_rate =
                    measured_output_count * PACKET_BITS * CLOCK_HZ /
                    (sustained_last_window_shaped_output_time -
                     sustained_first_window_shaped_output_time);
            end else
                packet_output_interval_rate = 0;
            if (sustained_have_first_eligibility &&
                sustained_have_shaped_output &&
                (sustained_last_shaped_output_time >=
                 sustained_first_eligibility_time)) begin
                envelope_duration = sustained_last_shaped_output_time -
                    sustained_first_eligibility_time + 1;
                packet_output_envelope_rate =
                    longint'(sustained_shaped_output_total) * PACKET_BITS *
                    CLOCK_HZ / envelope_duration;
            end else
                packet_output_envelope_rate = 0;
            if (packet_output_window_bps >= TARGET_BPS)
                relative_error_percent_x100 =
                    (packet_output_window_bps - TARGET_BPS) * 10000 /
                    TARGET_BPS;
            else
                relative_error_percent_x100 =
                    (TARGET_BPS - packet_output_window_bps) * 10000 /
                    TARGET_BPS;
            source_valid_fraction_percent_x100 =
                sustained_source_valid_cycles * 10000 /
                measurement_duration;
            source_stalled_fraction_percent_x100 =
                sustained_source_stalled_cycles * 10000 /
                measurement_duration;
            work_backlogged_fraction_percent_x100 =
                sustained_work_backlogged_cycles * 10000 /
                measurement_duration;
            local_subtree_backlogged_fraction_percent_x100 =
                sustained_local_subtree_backlogged_cycles * 10000 /
                measurement_duration;
            timing_backlogged_fraction_percent_x100 =
                sustained_timing_backlogged_cycles * 10000 /
                measurement_duration;
            event_table_backlogged_fraction_percent_x100 =
                sustained_event_table_backlogged_cycles * 10000 /
                measurement_duration;
            eligible_release_backlogged_fraction_percent_x100 =
                sustained_eligible_release_backlogged_cycles * 10000 /
                measurement_duration;
            if (sustained_measurement_tx_packets != 0)
                transaction_acceptance_cycles_per_packet_x1000 =
                    measurement_duration * 1000 /
                    longint'(sustained_measurement_tx_packets);
            else
                transaction_acceptance_cycles_per_packet_x1000 = 0;
            if (eligibility_timestamp_count != 0)
                eligibility_cycles_per_packet_x1000 =
                    measurement_duration * 1000 /
                    eligibility_timestamp_count;
            else
                eligibility_cycles_per_packet_x1000 = 0;
            if (sustained_measurement_admission_packets != 0)
                root_admission_cycles_per_packet_x1000 =
                    measurement_duration * 1000 /
                    longint'(sustained_measurement_admission_packets);
            else
                root_admission_cycles_per_packet_x1000 = 0;
            if (sustained_measurement_shaped_packets != 0)
                packet_output_cycles_per_packet_x1000 =
                    measurement_duration * 1000 /
                    longint'(sustained_measurement_shaped_packets);
            else
                packet_output_cycles_per_packet_x1000 = 0;

            if (SUSTAINED_RATE_CURVE_MODE == 0) begin
                if (eligibility_timestamp_count != longint'(
                    SUSTAINED_MEASUREMENT_SERVICE_INTERVALS))
                    $fatal(1,
                        "eligibility timestamp window count=%0d expected=%0d",
                        eligibility_timestamp_count,
                        SUSTAINED_MEASUREMENT_SERVICE_INTERVALS);
                if (eligibility_timestamp_interval_bps != TARGET_BPS)
                    $fatal(1,
                        "eligibility timestamp interval rate=%0d expected=%0d",
                        eligibility_timestamp_interval_bps, TARGET_BPS);
                if (sustained_measurement_admission_packets !=
                    SUSTAINED_MEASUREMENT_SERVICE_INTERVALS)
                    $fatal(1,
                        "Root-admission window count=%0d expected=%0d",
                        sustained_measurement_admission_packets,
                        SUSTAINED_MEASUREMENT_SERVICE_INTERVALS);
                if (sustained_measurement_shaped_packets !=
                    SUSTAINED_MEASUREMENT_SERVICE_INTERVALS)
                    $fatal(1,
                        "packet-output window count=%0d expected=%0d",
                        sustained_measurement_shaped_packets,
                        SUSTAINED_MEASUREMENT_SERVICE_INTERVALS);
            end
            if (work_backlogged_fraction_percent_x100 < 9900)
                $fatal(1,
                    "aggregate shaped work was input-starved: backlog=%0d.%02d%%",
                    work_backlogged_fraction_percent_x100 / 100,
                    work_backlogged_fraction_percent_x100 % 100);

            $display("SUSTAINED_RATE_RESULT");
            $display("rate_curve_mode=%0d", SUSTAINED_RATE_CURVE_MODE);
            $display("clock_frequency_hz=%0d", CLOCK_HZ);
            $display("pop_window=%0d", SUSTAINED_POP_WINDOW);
            $display("requested_rate_gbps=%0d.%03d",
                TARGET_BPS / 1000000000,
                (TARGET_BPS % 1000000000) / 1000000);
            $display("effective_configured_rate_bps=%0d", TARGET_BPS);
            $display("service_cycles=%0d", STEADY_SERVICE_TIME);
            $display("warmup_cycles=%0d", SUSTAINED_WARMUP_CYCLES);
            $display("measurement_cycles=%0d", measurement_duration);
            $display("measurement_transaction_packets=%0d",
                sustained_measurement_tx_packets);
            $display("measurement_eligibility_timestamps=%0d",
                eligibility_timestamp_count);
            $display("measurement_root_admissions=%0d",
                sustained_measurement_admission_packets);
            $display("measurement_pop_accepts=%0d",
                sustained_measurement_pop_accepts);
            $display("measurement_shaped_packets=%0d",
                sustained_measurement_shaped_packets);
            $display("measurement_shaped_bytes=%0d",
                sustained_measurement_shaped_bytes);
            $display("transaction_acceptance_window_bps=%0d",
                tx_acceptance_window_bps);
            $display("eligibility_timestamp_window_bps=%0d",
                eligibility_timestamp_window_bps);
            $display("eligibility_timestamp_interval_bps=%0d",
                eligibility_timestamp_interval_bps);
            $display("root_admission_window_bps=%0d",
                root_admission_window_bps);
            $display("root_admission_interval_bps=%0d",
                root_admission_interval_bps);
            $display("packet_output_window_bps=%0d",
                packet_output_window_bps);
            $display("packet_output_envelope_bps=%0d",
                packet_output_envelope_rate);
            $display("packet_output_interval_bps=%0d",
                packet_output_interval_rate);
            $display("transaction_acceptance_cycles_per_packet=%0d.%03d",
                transaction_acceptance_cycles_per_packet_x1000 / 1000,
                transaction_acceptance_cycles_per_packet_x1000 % 1000);
            $display("eligibility_cycles_per_packet=%0d.%03d",
                eligibility_cycles_per_packet_x1000 / 1000,
                eligibility_cycles_per_packet_x1000 % 1000);
            $display("root_admission_cycles_per_packet=%0d.%03d",
                root_admission_cycles_per_packet_x1000 / 1000,
                root_admission_cycles_per_packet_x1000 % 1000);
            $display("packet_output_cycles_per_packet=%0d.%03d",
                packet_output_cycles_per_packet_x1000 / 1000,
                packet_output_cycles_per_packet_x1000 % 1000);
            $display("max_schedule_outstanding=%0d",
                sustained_max_outstanding_count);
            $display("max_schedule_pending=%0d",
                sustained_max_pending_count);
            $display("max_timing_pending=%0d",
                sustained_max_timing_pending_count);
            $display("max_timing_event_table=%0d",
                sustained_max_event_table_count);
            $display("max_timing_release_fifo=%0d",
                sustained_max_release_fifo_count);
            $display("max_schedule_pop_result_fifo=%0d",
                sustained_max_schedule_pop_result_count);
            $display("max_timing_pop_result_fifo=%0d",
                sustained_max_timing_pop_result_count);
            $display("relative_error_percent=%0d.%02d",
                relative_error_percent_x100 / 100,
                relative_error_percent_x100 % 100);
            $display("source_valid_fraction=%0d.%02d",
                source_valid_fraction_percent_x100 / 100,
                source_valid_fraction_percent_x100 % 100);
            $display("source_stalled_fraction=%0d.%02d",
                source_stalled_fraction_percent_x100 / 100,
                source_stalled_fraction_percent_x100 % 100);
            $display("work_backlogged_fraction=%0d.%02d",
                work_backlogged_fraction_percent_x100 / 100,
                work_backlogged_fraction_percent_x100 % 100);
            $display("local_subtree_backlogged_fraction=%0d.%02d",
                local_subtree_backlogged_fraction_percent_x100 / 100,
                local_subtree_backlogged_fraction_percent_x100 % 100);
            $display("timing_backlogged_fraction=%0d.%02d",
                timing_backlogged_fraction_percent_x100 / 100,
                timing_backlogged_fraction_percent_x100 % 100);
            $display("event_table_backlogged_fraction=%0d.%02d",
                event_table_backlogged_fraction_percent_x100 / 100,
                event_table_backlogged_fraction_percent_x100 % 100);
            $display("eligible_release_backlogged_fraction=%0d.%02d",
                eligible_release_backlogged_fraction_percent_x100 / 100,
                eligible_release_backlogged_fraction_percent_x100 % 100);
            $display("deferred_cycles=%0d", shaping_deferred_cycles);
            $display("max_release_delay=%0d", release_delay_max);
            $display("total_accepted_packets=%0d", sustained_accepted_total);
            $display("total_output_packets=%0d", sustained_output_total);
            $display("shaped_accepted_packets=%0d",
                sustained_shaped_accepted_total);
            $display("shaped_output_packets=%0d",
                sustained_shaped_output_total);
            $display("Root_shard_pushes=%0d,%0d,%0d",
                physical_push_count[0], physical_push_count[1],
                physical_push_count[2]);
            $display("X_pushes=%0d", physical_push_count[3]);
            $display("Y_pushes=%0d", physical_push_count[4]);
            $display("Z_pushes=%0d", physical_push_count[5]);
            $display("protocol_error=%0d", protocol_error);
            if (SUSTAINED_RATE_CURVE_MODE != 0)
                $display("PASS: sustained six-flow 3/1/1/1 aggregate Y rate-curve measurement");
            else
                $display("PASS: sustained six-flow 3/1/1/1 aggregate Y shaping");
        end
    endtask

    task automatic check_flow_totals;
        input integer packets_per_flow;
        integer flow_index;
        begin
            for (flow_index = 0; flow_index < 6;
                 flow_index = flow_index + 1) begin
                if (accepted_count[flow_index] != packets_per_flow)
                    $fatal(1,
                        "phase %0d flow %0d accepted %0d expected %0d",
                        active_phase, flow_index,
                        accepted_count[flow_index], packets_per_flow);
                if (output_count[flow_index] != packets_per_flow)
                    $fatal(1,
                        "phase %0d flow %0d output %0d expected %0d",
                        active_phase, flow_index,
                        output_count[flow_index], packets_per_flow);
            end
        end
    endtask

    task automatic check_shard_mapping_and_drain;
        integer shard_index;
        begin
            for (shard_index = 0; shard_index < PHYSICAL_TREE_NUM;
                 shard_index = shard_index + 1) begin
                if (physical_push_count[shard_index] == 0)
                    $fatal(1, "phase %0d did not exercise shard %0d",
                        active_phase, shard_index);
                if (schedule_shard_count[shard_index] != 0)
                    $fatal(1, "phase %0d shard %0d did not drain: %0d",
                        active_phase, shard_index,
                        schedule_shard_count[shard_index]);
            end
        end
    endtask

    always @(posedge clk or negedge arst_n) begin
        if (SUSTAINED_MODE == 0) begin
        if (!arst_n) begin
            shaped_tx_count <= 0;
            shaping_release_count <= 0;
            shaped_output_count <= 0;
            for (monitor_index = 0; monitor_index < 6;
                 monitor_index = monitor_index + 1) begin
                accepted_count[monitor_index] <= 0;
                output_count[monitor_index] <= 0;
            end
            for (monitor_index = 0;
                 monitor_index < PHYSICAL_TREE_NUM;
                 monitor_index = monitor_index + 1)
                physical_push_count[monitor_index] <= 0;
            for (monitor_class = 0; monitor_class < 6;
                 monitor_class = monitor_class + 1)
                for (monitor_sequence = 0;
                     monitor_sequence < PHASE2_PACKETS_PER_FLOW;
                     monitor_sequence = monitor_sequence + 1)
                    packet_seen[monitor_class][monitor_sequence] <= 1'b0;
        end else begin
            if (d_transaction_fire) begin
                monitor_class = int'(d_data[30:28]);
                if ((monitor_class < int'(FLOW_C)) ||
                    (monitor_class > int'(FLOW_B)))
                    $fatal(1, "non-Y flow used shaped ingress: %0d",
                        monitor_class);
                if (shaped_tx_count >= PHASE2_SHAPED_PACKETS)
                    $fatal(1, "shaped transaction log overflow");
                accepted_count[monitor_class] <=
                    accepted_count[monitor_class] + 1;
                eligibility_log[shaped_tx_count] <= d_eligibility_time;
                shaped_tx_count <= shaped_tx_count + 1;
            end

            if (direct_fire) begin
                monitor_class = int'(direct_data[30:28]);
                if ((monitor_class < int'(FLOW_F)) ||
                    (monitor_class > int'(FLOW_E)))
                    $fatal(1, "Y flow bypassed shaping ingress: %0d",
                        monitor_class);
                accepted_count[monitor_class] <=
                    accepted_count[monitor_class] + 1;
            end

            if (shaping_fire) begin
                if (shaping_release_count >= PHASE2_SHAPED_PACKETS)
                    $fatal(1, "root admission log overflow");
                if (wall_time < shaping_release_time)
                    $fatal(1, "Y reference admitted before eligibility");
                root_admission_log[shaping_release_count] <= wall_time;
                shaping_release_count <= shaping_release_count + 1;
            end

            if (packet_out_valid) begin
                monitor_class = int'(packet_out_data[30:28]);
                monitor_sequence = int'(packet_out_data[27:16]);
                if ((monitor_class < 0) || (monitor_class >= 6) ||
                    (monitor_sequence < 0) ||
                    (monitor_sequence >= expected_packets_per_flow))
                    $fatal(1, "bad packet metadata class=%0d sequence=%0d",
                        monitor_class, monitor_sequence);
                if (packet_seen[monitor_class][monitor_sequence])
                    $fatal(1, "duplicate packet class=%0d sequence=%0d",
                        monitor_class, monitor_sequence);
                packet_seen[monitor_class][monitor_sequence] <= 1'b1;
                output_count[monitor_class] <=
                    output_count[monitor_class] + 1;

                case (monitor_class)
                    int'(FLOW_F):
                        if (packet_out_node != NODE_ROOT)
                            $fatal(1, "F exited from node %0d",
                                packet_out_node);
                    int'(FLOW_D), int'(FLOW_E):
                        if (packet_out_node != NODE_X)
                            $fatal(1, "D/E exited from node %0d",
                                packet_out_node);
                    int'(FLOW_C):
                        if (packet_out_node != NODE_Y)
                            $fatal(1, "C exited from node %0d",
                                packet_out_node);
                    int'(FLOW_A), int'(FLOW_B):
                        if (packet_out_node != NODE_Z)
                            $fatal(1, "A/B exited from node %0d",
                                packet_out_node);
                    default:
                        $fatal(1, "unknown output traffic class");
                endcase

                if (monitor_class >= int'(FLOW_C)) begin
                    if (shaped_output_count >= PHASE2_SHAPED_PACKETS)
                        $fatal(1, "shaped output log overflow");
                    if ((monitor_sequence != shaped_output_count / 3) ||
                        (monitor_class != int'(FLOW_C) +
                                          (shaped_output_count % 3)))
                        $fatal(1,
                            "Y output order mismatch at %0d: class=%0d seq=%0d",
                            shaped_output_count, monitor_class,
                            monitor_sequence);
                    shaped_output_log[shaped_output_count] <= wall_time;
                    shaped_output_count <= shaped_output_count + 1;
                end
            end

            for (monitor_index = 0;
                 monitor_index < LOGICAL_TREE_NUM;
                 monitor_index = monitor_index + 1) begin
                if (schedule_dispatch_fire[monitor_index] &&
                    schedule_dispatch_push[monitor_index]) begin
                    monitor_physical = int'(
                        schedule_selected_physical[monitor_index]);
                    if ((monitor_physical < 0) ||
                        (monitor_physical >= PHYSICAL_TREE_NUM))
                        $fatal(1, "invalid physical shard %0d",
                            monitor_physical);
                    case (monitor_index)
                        0:
                            if (monitor_physical > 2)
                                $fatal(1, "Root dispatched to shard %0d",
                                    monitor_physical);
                        1:
                            if (monitor_physical != 3)
                                $fatal(1, "X dispatched to shard %0d",
                                    monitor_physical);
                        2:
                            if (monitor_physical != 4)
                                $fatal(1, "Y dispatched to shard %0d",
                                    monitor_physical);
                        3:
                            if (monitor_physical != 5)
                                $fatal(1, "Z dispatched to shard %0d",
                                    monitor_physical);
                        default:
                            $fatal(1, "invalid logical dispatch index");
                    endcase
                    physical_push_count[monitor_physical] <=
                        physical_push_count[monitor_physical] + 1;
                end
            end
        end
        end
    end

    always @(posedge clk or negedge arst_n) begin
        if (SUSTAINED_MODE == 0) begin
        end else if (!arst_n) begin
            sustained_accepted_total <= 0;
            sustained_shaped_accepted_total <= 0;
            sustained_output_total <= 0;
            sustained_shaped_output_total <= 0;
            sustained_measurement_shaped_packets <= 0;
            sustained_measurement_tx_packets <= 0;
            sustained_measurement_admission_packets <= 0;
            sustained_measurement_pop_accepts <= 0;
            sustained_pop_accept_total <= 0;
            sustained_max_outstanding_count <= 0;
            sustained_max_pending_count <= 0;
            sustained_max_timing_pending_count <= 0;
            sustained_max_event_table_count <= 0;
            sustained_max_release_fifo_count <= 0;
            sustained_max_schedule_pop_result_count <= 0;
            sustained_max_timing_pop_result_count <= 0;
            sustained_measurement_shaped_bytes <= 0;
            sustained_measurement_tx_bytes <= 0;
            sustained_measurement_admission_bytes <= 0;
            sustained_source_valid_cycles <= 0;
            sustained_source_stalled_cycles <= 0;
            sustained_work_backlogged_cycles <= 0;
            sustained_local_subtree_backlogged_cycles <= 0;
            sustained_timing_backlogged_cycles <= 0;
            sustained_event_table_backlogged_cycles <= 0;
            sustained_eligible_release_backlogged_cycles <= 0;
            sustained_eligibility_log_count <= 0;
            sustained_have_first_eligibility <= 1'b0;
            sustained_have_shaped_output <= 1'b0;
            sustained_have_window_admission <= 1'b0;
            sustained_have_window_shaped_output <= 1'b0;
            sustained_first_eligibility_time <= 0;
            sustained_last_shaped_output_time <= 0;
            sustained_first_window_admission_time <= 0;
            sustained_last_window_admission_time <= 0;
            sustained_first_window_shaped_output_time <= 0;
            sustained_last_window_shaped_output_time <= 0;
            for (sustained_flow_index = 0;
                 sustained_flow_index < 6;
                 sustained_flow_index = sustained_flow_index + 1) begin
                sustained_next_sequence[sustained_flow_index] <= 0;
                accepted_count[sustained_flow_index] <= 0;
                output_count[sustained_flow_index] <= 0;
                for (sustained_id_index = 0;
                     sustained_id_index < SUSTAINED_ID_SPACE;
                     sustained_id_index = sustained_id_index + 1) begin
                    sustained_accepted_id_count[sustained_flow_index]
                        [sustained_id_index] <= 0;
                    sustained_output_id_count[sustained_flow_index]
                        [sustained_id_index] <= 0;
                end
            end
            for (sustained_shard_index = 0;
                 sustained_shard_index < PHYSICAL_TREE_NUM;
                 sustained_shard_index = sustained_shard_index + 1)
                physical_push_count[sustained_shard_index] <= 0;
            for (sustained_flow_index = 0;
                 sustained_flow_index < LOGICAL_TREE_NUM;
                 sustained_flow_index = sustained_flow_index + 1)
                sustained_next_sequence[sustained_flow_index] <= 0;
        end else begin
            if (int'(schedule_outstanding_count) >
                sustained_max_outstanding_count)
                sustained_max_outstanding_count <=
                    int'(schedule_outstanding_count);
            if (int'(schedule_pending_count) >
                sustained_max_pending_count)
                sustained_max_pending_count <= int'(schedule_pending_count);
            if (int'(dut.timing_domain.core_pending_count) >
                sustained_max_timing_pending_count)
                sustained_max_timing_pending_count <=
                    int'(dut.timing_domain.core_pending_count);
            if (int'(timing_event_count) >
                sustained_max_event_table_count)
                sustained_max_event_table_count <=
                    int'(timing_event_count);
            if (int'(timing_release_count) >
                sustained_max_release_fifo_count)
                sustained_max_release_fifo_count <=
                    int'(timing_release_count);
            if (int'(dut.schedule_domain.core.GEN_GENERIC_POP_RETURN
                     .pop_result_count) >
                sustained_max_schedule_pop_result_count)
                sustained_max_schedule_pop_result_count <=
                    int'(dut.schedule_domain.core.GEN_GENERIC_POP_RETURN
                         .pop_result_count);
            if (int'(dut.timing_domain.shaping_core.GEN_GENERIC_POP_RETURN
                     .pop_result_count) >
                sustained_max_timing_pop_result_count)
                sustained_max_timing_pop_result_count <=
                    int'(dut.timing_domain.shaping_core
                         .GEN_GENERIC_POP_RETURN.pop_result_count);
            if (pop_valid && pop_ready) begin
                sustained_pop_accept_total <=
                    sustained_pop_accept_total + 1;
                if (sustained_measurement_active)
                    sustained_measurement_pop_accepts <=
                        sustained_measurement_pop_accepts + 1;
            end

            if (d_transaction_fire) begin
                monitor_class = int'(d_data[30:28]);
                sustained_id = int'(d_data[27:16]);
                if ((monitor_class < int'(FLOW_C)) ||
                    (monitor_class > int'(FLOW_B)))
                    $fatal(1,
                        "sustained non-Y flow used shaped ingress: %0d",
                        monitor_class);
                sustained_shaped_accepted_total <=
                    sustained_shaped_accepted_total + 1;
                accepted_count[monitor_class] <=
                    accepted_count[monitor_class] + 1;
                sustained_accepted_id_count[monitor_class][sustained_id] <=
                    sustained_accepted_id_count[monitor_class][sustained_id] +
                    1;
                if (sustained_eligibility_log_count >=
                    SUSTAINED_ELIGIBILITY_LOG_DEPTH)
                    $fatal(1, "sustained eligibility log overflow");
                else begin
                    sustained_eligibility_log[
                        sustained_eligibility_log_count] <=
                            d_eligibility_time;
                    sustained_eligibility_log_count <=
                        sustained_eligibility_log_count + 1;
                end
                if (!sustained_have_first_eligibility) begin
                    sustained_have_first_eligibility <= 1'b1;
                    sustained_first_eligibility_time <=
                        longint'(d_eligibility_time);
                end
                if (sustained_measurement_active) begin
                    sustained_measurement_tx_packets <=
                        sustained_measurement_tx_packets + 1;
                    sustained_measurement_tx_bytes <=
                        sustained_measurement_tx_bytes +
                        PACKET_BYTES;
                end
            end

            if (direct_fire) begin
                monitor_class = int'(direct_data[30:28]);
                sustained_id = int'(direct_data[27:16]);
                if ((monitor_class < int'(FLOW_F)) ||
                    (monitor_class > int'(FLOW_E)))
                    $fatal(1,
                        "sustained Y flow bypassed shaping ingress: %0d",
                        monitor_class);
                accepted_count[monitor_class] <=
                    accepted_count[monitor_class] + 1;
                sustained_accepted_id_count[monitor_class][sustained_id] <=
                    sustained_accepted_id_count[monitor_class][sustained_id] +
                    1;
            end

            if (shaping_fire) begin
                if (wall_time < shaping_release_time)
                    $fatal(1, "sustained Y reference admitted before eligibility");
                if (sustained_measurement_active) begin
                    if (!sustained_have_window_admission) begin
                        sustained_have_window_admission <= 1'b1;
                        sustained_first_window_admission_time <=
                            longint'(wall_time);
                    end
                    sustained_last_window_admission_time <=
                        longint'(wall_time);
                    sustained_measurement_admission_packets <=
                        sustained_measurement_admission_packets + 1;
                    sustained_measurement_admission_bytes <=
                        sustained_measurement_admission_bytes + PACKET_BYTES;
                end
            end

            if (packet_out_valid) begin
                monitor_class = int'(packet_out_data[30:28]);
                sustained_id = int'(packet_out_data[27:16]);
                if ((monitor_class < 0) || (monitor_class >= 6))
                    $fatal(1, "sustained bad packet class=%0d",
                        monitor_class);
                if (sustained_output_id_count[monitor_class][sustained_id] >=
                    sustained_accepted_id_count[monitor_class][sustained_id])
                    $fatal(1,
                        "sustained duplicate or unaccepted packet class=%0d id=%0d",
                        monitor_class, sustained_id);
                sustained_output_id_count[monitor_class][sustained_id] <=
                    sustained_output_id_count[monitor_class][sustained_id] + 1;
                sustained_output_total <= sustained_output_total + 1;
                output_count[monitor_class] <=
                    output_count[monitor_class] + 1;

                case (monitor_class)
                    int'(FLOW_F):
                        if (packet_out_node != NODE_ROOT)
                            $fatal(1, "sustained F exited from node %0d",
                                packet_out_node);
                    int'(FLOW_D), int'(FLOW_E):
                        if (packet_out_node != NODE_X)
                            $fatal(1, "sustained D/E exited from node %0d",
                                packet_out_node);
                    int'(FLOW_C):
                        if (packet_out_node != NODE_Y)
                            $fatal(1, "sustained C exited from node %0d",
                                packet_out_node);
                    int'(FLOW_A), int'(FLOW_B):
                        if (packet_out_node != NODE_Z)
                            $fatal(1, "sustained A/B exited from node %0d",
                                packet_out_node);
                    default:
                        $fatal(1, "sustained unknown output traffic class");
                endcase

                if (monitor_class >= int'(FLOW_C)) begin
                    if (sustained_shaped_output_total >=
                        sustained_shaped_accepted_total)
                        $fatal(1,
                            "sustained shaped output has no accepted packet");
                    sustained_shaped_output_total <=
                        sustained_shaped_output_total + 1;
                    sustained_have_shaped_output <= 1'b1;
                    sustained_last_shaped_output_time <=
                        longint'(wall_time);
                    if (sustained_measurement_active) begin
                        if (!sustained_have_window_shaped_output) begin
                            sustained_have_window_shaped_output <= 1'b1;
                            sustained_first_window_shaped_output_time <=
                                longint'(wall_time);
                        end
                        sustained_last_window_shaped_output_time <=
                            longint'(wall_time);
                        sustained_measurement_shaped_packets <=
                            sustained_measurement_shaped_packets + 1;
                        sustained_measurement_shaped_bytes <=
                            sustained_measurement_shaped_bytes + PACKET_BYTES;
                    end
                end
            end

            case ({d_transaction_fire, direct_fire})
                2'b10, 2'b01:
                    sustained_accepted_total <=
                        sustained_accepted_total + 1;
                2'b11:
                    sustained_accepted_total <=
                        sustained_accepted_total + 2;
                default:
                    sustained_accepted_total <= sustained_accepted_total;
            endcase

            if (sustained_measurement_active) begin
                if (d_valid)
                    sustained_source_valid_cycles <=
                        sustained_source_valid_cycles + 1;
                if (d_valid && !d_ready)
                    sustained_source_stalled_cycles <=
                        sustained_source_stalled_cycles + 1;
                if ((sustained_shaped_accepted_total >
                     sustained_shaped_output_total) || d_valid)
                    sustained_work_backlogged_cycles <=
                        sustained_work_backlogged_cycles + 1;
                if ((schedule_logical_count[NODE_Y] != 0) ||
                    (schedule_logical_count[NODE_Z] != 0))
                    sustained_local_subtree_backlogged_cycles <=
                        sustained_local_subtree_backlogged_cycles + 1;
                if ((timing_event_count != 0) ||
                    (timing_release_count != 0) || shaping_pending)
                    sustained_timing_backlogged_cycles <=
                        sustained_timing_backlogged_cycles + 1;
                if (timing_event_count != 0)
                    sustained_event_table_backlogged_cycles <=
                        sustained_event_table_backlogged_cycles + 1;
                if ((timing_release_count != 0) || shaping_pending)
                    sustained_eligible_release_backlogged_cycles <=
                        sustained_eligible_release_backlogged_cycles + 1;
            end

            for (monitor_index = 0;
                 monitor_index < LOGICAL_TREE_NUM;
                 monitor_index = monitor_index + 1) begin
                if (schedule_dispatch_fire[monitor_index] &&
                    schedule_dispatch_push[monitor_index]) begin
                    monitor_physical = int'(
                        schedule_selected_physical[monitor_index]);
                    if ((monitor_physical < 0) ||
                        (monitor_physical >= PHYSICAL_TREE_NUM))
                        $fatal(1, "sustained invalid physical shard %0d",
                            monitor_physical);
                    case (monitor_index)
                        0:
                            if (monitor_physical > 2)
                                $fatal(1,
                                    "sustained Root dispatched to shard %0d",
                                    monitor_physical);
                        1:
                            if (monitor_physical != 3)
                                $fatal(1,
                                    "sustained X dispatched to shard %0d",
                                    monitor_physical);
                        2:
                            if (monitor_physical != 4)
                                $fatal(1,
                                    "sustained Y dispatched to shard %0d",
                                    monitor_physical);
                        3:
                            if (monitor_physical != 5)
                                $fatal(1,
                                    "sustained Z dispatched to shard %0d",
                                    monitor_physical);
                        default:
                            $fatal(1, "sustained invalid logical dispatch");
                    endcase
                    physical_push_count[monitor_physical] <=
                        physical_push_count[monitor_physical] + 1;
                end
            end
        end
    end

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
        d_service_time = STEADY_SERVICE_TIME;
        d_data = 0;
        direct_valid = 1'b0;
        direct_target = NODE_ROOT;
        direct_data = 0;
        pop_valid = 1'b0;
        active_phase = 0;
        expected_packets_per_flow = PHASE1_PACKETS_PER_FLOW;
        for (check_index = 0; check_index < LOGICAL_TREE_NUM;
             check_index = check_index + 1) begin
            d_rank[check_index] = 16'hffff;
            direct_rank[check_index] = 16'hffff;
        end

        if (SUSTAINED_MODE != 0) begin
            if ((SUSTAINED_POP_WINDOW < 1) ||
                (SUSTAINED_POP_WINDOW > 16))
                $fatal(1, "invalid sustained Pop window %0d",
                    SUSTAINED_POP_WINDOW);
            run_sustained_experiment();
            $finish;
        end else begin

        // Phase 1: fill all six traffic classes, prove pre-release Root
        // invisibility for Y, exercise every configured shard, then drain.
        active_phase = 1;
        expected_packets_per_flow = PHASE1_PACKETS_PER_FLOW;
        repeat (8) @(negedge clk);
        arst_n = 1'b1;
        repeat (4) @(negedge clk);
        configure_empty_bucket();

        fork
            generate_direct_traffic(PHASE1_PACKETS_PER_FLOW);
            generate_shaped_traffic(PHASE1_PACKETS_PER_FLOW,
                                    VISIBILITY_SERVICE_TIME);
        join

        watchdog = 0;
        while (((schedule_logical_count[NODE_ROOT] != 24) ||
                (schedule_logical_count[NODE_X] != 16) ||
                (schedule_logical_count[NODE_Y] != 24) ||
                (schedule_logical_count[NODE_Z] != 16) ||
                schedule_busy) &&
               (shaping_release_count == 0) && (watchdog < 100000)) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if ((watchdog == 100000) || (shaping_release_count != 0))
            $fatal(1,
                "phase 1 did not settle before first Y release: Root=%0d X=%0d Y=%0d Z=%0d releases=%0d timing=%0d schedule_busy=%0d",
                schedule_logical_count[NODE_ROOT],
                schedule_logical_count[NODE_X],
                schedule_logical_count[NODE_Y],
                schedule_logical_count[NODE_Z], shaping_release_count,
                timing_event_count, schedule_busy);
        if ((timing_event_count != PHASE1_SHAPED_PACKETS) ||
            (schedule_shard_count[0] != 8) ||
            (schedule_shard_count[1] != 8) ||
            (schedule_shard_count[2] != 8) ||
            (schedule_shard_count[3] != 16) ||
            (schedule_shard_count[4] != 24) ||
            (schedule_shard_count[5] != 16))
            $fatal(1,
                "phase 1 pre-release shard occupancy mismatch: %0d,%0d,%0d,%0d,%0d,%0d timing=%0d",
                schedule_shard_count[0], schedule_shard_count[1],
                schedule_shard_count[2], schedule_shard_count[3],
                schedule_shard_count[4], schedule_shard_count[5],
                timing_event_count);

        watchdog = 0;
        while (((shaping_release_count != PHASE1_SHAPED_PACKETS) ||
                schedule_busy || timing_busy) && (watchdog < 200000)) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (watchdog == 200000)
            $fatal(1, "phase 1 timed out waiting for aggregate Y releases");
        if ((schedule_logical_count[NODE_ROOT] != 48) ||
            (schedule_shard_count[0] != 16) ||
            (schedule_shard_count[1] != 16) ||
            (schedule_shard_count[2] != 16))
            $fatal(1,
                "phase 1 Root 3-shard occupancy mismatch: logical=%0d shards=%0d,%0d,%0d",
                schedule_logical_count[NODE_ROOT],
                schedule_shard_count[0], schedule_shard_count[1],
                schedule_shard_count[2]);

        consume_packets(PHASE1_TOTAL_PACKETS);
        watchdog = 0;
        while ((busy || (timing_event_count != 0) ||
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
                "phase 1 domains did not drain: busy=%0d timing=%0d/%0d pending=%0d outstanding=%0d logical=%0d,%0d,%0d,%0d shards=%0d,%0d,%0d,%0d,%0d,%0d protocol=%0d",
                busy, timing_event_count, timing_release_count,
                schedule_pending_count, schedule_outstanding_count,
                schedule_logical_count[NODE_ROOT],
                schedule_logical_count[NODE_X],
                schedule_logical_count[NODE_Y],
                schedule_logical_count[NODE_Z],
                schedule_shard_count[0], schedule_shard_count[1],
                schedule_shard_count[2], schedule_shard_count[3],
                schedule_shard_count[4], schedule_shard_count[5],
                protocol_error);
        check_flow_totals(PHASE1_PACKETS_PER_FLOW);
        if ((shaped_tx_count != PHASE1_SHAPED_PACKETS) ||
            (shaping_release_count != PHASE1_SHAPED_PACKETS) ||
            (shaped_output_count != PHASE1_SHAPED_PACKETS))
            $fatal(1, "phase 1 shaped exactly-once mismatch");
        for (check_index = 0; check_index < PHASE1_SHAPED_PACKETS;
             check_index = check_index + 1)
            if (shaped_output_log[check_index] <
                eligibility_log[check_index])
                $fatal(1, "phase 1 Y packet %0d exited before eligibility",
                    check_index);
        check_shard_mapping_and_drain();
        min_root_pushes = physical_push_count[0];
        max_root_pushes = physical_push_count[0];
        for (check_index = 1; check_index < 3;
             check_index = check_index + 1) begin
            if (physical_push_count[check_index] < min_root_pushes)
                min_root_pushes = physical_push_count[check_index];
            if (physical_push_count[check_index] > max_root_pushes)
                max_root_pushes = physical_push_count[check_index];
        end
        if ((max_root_pushes - min_root_pushes) > 1)
            $fatal(1, "phase 1 Root shards were not balanced: %0d,%0d,%0d",
                physical_push_count[0], physical_push_count[1],
                physical_push_count[2]);
        $display("MULTISTREAM_PHASE1,per_flow=%0d,root_shard_pushes=%0d,%0d,%0d,x=%0d,y=%0d,z=%0d",
            PHASE1_PACKETS_PER_FLOW,
            physical_push_count[0], physical_push_count[1],
            physical_push_count[2], physical_push_count[3],
            physical_push_count[4], physical_push_count[5]);

        // Phase 2: reset and run sustained mixed backlog.  The output-rate
        // envelope is measured at packet-out; interval rate is reported but
        // not constrained because deferred releases may catch up in bursts.
        @(negedge clk);
        arst_n = 1'b0;
        d_valid = 1'b0;
        direct_valid = 1'b0;
        pop_valid = 1'b0;
        active_phase = 2;
        expected_packets_per_flow = PHASE2_PACKETS_PER_FLOW;
        repeat (8) @(negedge clk);
        arst_n = 1'b1;
        repeat (4) @(negedge clk);
        configure_empty_bucket();

        fork
            generate_direct_traffic(PHASE2_PACKETS_PER_FLOW);
            generate_shaped_traffic(PHASE2_PACKETS_PER_FLOW,
                                    STEADY_SERVICE_TIME);
            consume_packets(PHASE2_TOTAL_PACKETS);
        join

        watchdog = 0;
        while (((total_outputs() != PHASE2_TOTAL_PACKETS) ||
                (shaping_release_count != PHASE2_SHAPED_PACKETS) ||
                busy) && (watchdog < PHASE2_WATCHDOG_CYCLES)) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (watchdog == PHASE2_WATCHDOG_CYCLES)
            $fatal(1,
                "phase 2 timeout outputs=%0d releases=%0d busy=%0d",
                total_outputs(), shaping_release_count, busy);
        repeat (4) @(negedge clk);
        check_flow_totals(PHASE2_PACKETS_PER_FLOW);
        if ((shaped_tx_count != PHASE2_SHAPED_PACKETS) ||
            (shaping_release_count != PHASE2_SHAPED_PACKETS) ||
            (shaped_output_count != PHASE2_SHAPED_PACKETS))
            $fatal(1, "phase 2 shaped exactly-once mismatch tx=%0d release=%0d output=%0d",
                shaped_tx_count, shaping_release_count, shaped_output_count);
        for (check_index = 0; check_index < PHASE2_SHAPED_PACKETS;
             check_index = check_index + 1) begin
            if (root_admission_log[check_index] <
                eligibility_log[check_index])
                $fatal(1, "phase 2 Y reference %0d admitted early",
                    check_index);
            if (shaped_output_log[check_index] <
                eligibility_log[check_index])
                $fatal(1, "phase 2 Y packet %0d exited early",
                    check_index);
            if ((check_index != 0) &&
                ((eligibility_log[check_index] -
                  eligibility_log[check_index - 1]) !=
                 STEADY_SERVICE_TIME))
                $fatal(1, "phase 2 eligibility gap mismatch at %0d",
                    check_index);
        end
        check_shard_mapping_and_drain();
        min_root_pushes = physical_push_count[0];
        max_root_pushes = physical_push_count[0];
        for (check_index = 1; check_index < 3;
             check_index = check_index + 1) begin
            if (physical_push_count[check_index] < min_root_pushes)
                min_root_pushes = physical_push_count[check_index];
            if (physical_push_count[check_index] > max_root_pushes)
                max_root_pushes = physical_push_count[check_index];
        end
        if ((max_root_pushes - min_root_pushes) >
            (PHASE2_TOTAL_PACKETS / 20))
            $fatal(1, "phase 2 Root shards were not balanced: %0d,%0d,%0d",
                physical_push_count[0], physical_push_count[1],
                physical_push_count[2]);

        rate_numerator = PHASE2_SHAPED_PACKETS - 1;
        rate_numerator = rate_numerator * PACKET_BITS * CLOCK_HZ;
        rate_duration =
            longint'(eligibility_log[PHASE2_SHAPED_PACKETS - 1]) -
            longint'(eligibility_log[0]);
        eligibility_rate_bps = rate_numerator / rate_duration;
        rate_duration =
            longint'(root_admission_log[PHASE2_SHAPED_PACKETS - 1]) -
            longint'(root_admission_log[0]);
        root_admission_rate_bps = rate_numerator / rate_duration;
        rate_duration =
            longint'(shaped_output_log[PHASE2_SHAPED_PACKETS - 1]) -
            longint'(shaped_output_log[0]);
        packet_output_interval_bps = rate_numerator / rate_duration;
        rate_numerator = PHASE2_SHAPED_PACKETS;
        rate_numerator = rate_numerator * PACKET_BITS * CLOCK_HZ;
        rate_duration =
            longint'(shaped_output_log[PHASE2_SHAPED_PACKETS - 1]) -
            longint'(eligibility_log[0]) +
            longint'(STEADY_SERVICE_TIME);
        packet_output_end_to_end_bps = rate_numerator / rate_duration;

        if (eligibility_rate_bps != TARGET_BPS)
            $fatal(1, "phase 2 aggregate eligibility rate %0d expected %0d",
                eligibility_rate_bps, TARGET_BPS);
        if (packet_output_end_to_end_bps > TARGET_BPS)
            $fatal(1, "phase 2 packet-out envelope exceeded target: %0d",
                packet_output_end_to_end_bps);
        if (protocol_error)
            $fatal(1, "phase 2 protocol_error");

        $display("MULTISTREAM_PHASE2,per_flow=%0d,total_packets=%0d,shaped_packets=%0d",
            PHASE2_PACKETS_PER_FLOW, PHASE2_TOTAL_PACKETS,
            PHASE2_SHAPED_PACKETS);
        $display("MULTISTREAM_RATE,target_bps=%0d,eligibility_bps=%0d,root_admission_interval_bps=%0d,packet_output_interval_bps=%0d,packet_output_envelope_bps=%0d",
            TARGET_BPS, eligibility_rate_bps, root_admission_rate_bps,
            packet_output_interval_bps, packet_output_end_to_end_bps);
        $display("MULTISTREAM_SHARDS,root=%0d,%0d,%0d,x=%0d,y=%0d,z=%0d",
            physical_push_count[0], physical_push_count[1],
            physical_push_count[2], physical_push_count[3],
            physical_push_count[4], physical_push_count[5]);
        $display("MULTISTREAM_ARBITRATION,deferred_cycles=%0d,last_delay=%0d,max_delay=%0d,direct=%0d,pop=%0d,backpressure=%0d",
            shaping_deferred_cycles, release_delay_last,
            release_delay_max, deferred_by_direct_push,
            deferred_by_scheduling_pop,
            deferred_by_schedule_backpressure);
        $display("PASS: 3/1/1/1 aggregate Y multi-stream shaping, packet-out rate, and shard coverage");
        $finish;
        end
    end

    initial begin
        repeat (RUN_WATCHDOG_CYCLES) @(posedge clk);
        $fatal(1,
            "3/1/1/1 multi-stream timeout phase=%0d accepted=%0d,%0d,%0d,%0d,%0d,%0d output=%0d,%0d,%0d,%0d,%0d,%0d shaped=%0d/%0d/%0d root=%0d pending=%0d outstanding=%0d timing=%0d/%0d busy=%0d d=%0d/%0d direct=%0d/%0d pop=%0d/%0d protocol=%0d",
            active_phase,
            accepted_count[0], accepted_count[1], accepted_count[2],
            accepted_count[3], accepted_count[4], accepted_count[5],
            output_count[0], output_count[1], output_count[2],
            output_count[3], output_count[4], output_count[5],
            shaped_tx_count, shaping_release_count, shaped_output_count,
            schedule_logical_count[NODE_ROOT], schedule_pending_count,
            schedule_outstanding_count, timing_event_count,
            timing_release_count, busy, d_valid, d_ready,
            direct_valid, direct_ready, pop_valid, pop_ready,
            protocol_error);
    end
endmodule
