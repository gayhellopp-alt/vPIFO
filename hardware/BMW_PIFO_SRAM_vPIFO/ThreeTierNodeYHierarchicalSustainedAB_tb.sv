`timescale 1ns / 10ps

// Multi-node, multi-flow sustained A/B experiment for aggregate-Y shaping.
//
// Twelve continuously backlogged software sources are mapped onto the six
// leaves of the Root/X/Y/Z scheduling tree:
//
//   F0/F1 -> Root
//   D0/D1/E0/E1 -> X -> Root
//   C0/C1 -> Y -> Root
//   A0/A1/B0/B1 -> Z -> Y -> Root
//
// A deterministic arrival-slot trace is replayed after reset in both cases.
// The trace changes the aggregate Y share gradually while F and X continue to
// offer work.  The disabled case sends Y traffic through FULL Scheduling
// Pushes.  The enabled case sends the same Y packets through LOCAL(Y), an
// aggregate eligibility-time Token Bucket, and PARENT_REF(Y).
module ThreeTierNodeYHierarchicalSustainedAB_tb #(
    parameter integer TARGET_SERVICE_TIME = 750,
    parameter integer MEASUREMENT_SERVICE_INTERVALS = 2000,
    // Shift the deterministic Y-share waveform without changing its phase,
    // burst timing, packet sizes, or replay equality between the two modes.
    parameter integer Y_SHARE_OFFSET_PERCENT = 0,
    // Zero retains the historical disabled-rate guard.  A nonzero value
    // turns the guard into a +/-3% check around an experiment-specific rate.
    parameter integer DISABLED_EXPECTED_MBPS = 0,
    parameter integer SCHEDULE_PENDING_DEPTH = 32,
    parameter integer SCHEDULE_POP_TRACK_DEPTH = 32
);
    localparam PTW = 16;
    // The original 16 metadata bits are fully occupied by source + sequence.
    // Use the core's existing MTW parameterization to preserve an additional
    // 16-bit packet length while the low PTW bits remain the PIFO rank.
    localparam MTW = 32;
    localparam DATA_WIDTH = PTW + MTW;
    localparam TIME_WIDTH = 32;
    localparam LOGICAL_TREE_NUM = 4;
    localparam SCHEDULE_PENDING_COUNT_WIDTH =
        (SCHEDULE_PENDING_DEPTH <= 1) ? 1 :
        $clog2(SCHEDULE_PENDING_DEPTH + 1);
    localparam SCHEDULE_TRACK_COUNT_WIDTH =
        (SCHEDULE_POP_TRACK_DEPTH <= 1) ? 1 :
        $clog2(SCHEDULE_POP_TRACK_DEPTH + 1);
    localparam SOURCE_NUM = 12;
    localparam PACKET_ID_SPACE = 2048;
    localparam MAX_MEASUREMENT_EVENTS = 32768;

    localparam REFERENCE_PACKET_BYTES = 1500;
    localparam MIN_PACKET_BYTES = 1200;
    localparam MAX_PACKET_BYTES = 1500;
    localparam CLOCK_HZ = 125000000;
    localparam WARMUP_SERVICE_INTERVALS = 256;
    // A 13 x (2/3 service interval) window is 8.667 reference-packet
    // intervals at the default configuration.  It is deliberately shorter
    // and not an integer multiple of the shaping interval.
    localparam WINDOW_STEPS = 13;
    localparam STEP_CYCLES_RAW = (TARGET_SERVICE_TIME * 2) / 3;
    localparam STEP_CYCLES = (STEP_CYCLES_RAW < 1) ? 1 : STEP_CYCLES_RAW;
    localparam WARMUP_CYCLES =
        WARMUP_SERVICE_INTERVALS * TARGET_SERVICE_TIME;
    localparam REQUESTED_MEASUREMENT_CYCLES =
        MEASUREMENT_SERVICE_INTERVALS * TARGET_SERVICE_TIME;
    localparam SAMPLE_POINTS =
        REQUESTED_MEASUREMENT_CYCLES / STEP_CYCLES;
    localparam MEASUREMENT_CYCLES = SAMPLE_POINTS * STEP_CYCLES;
    localparam WINDOW_CYCLES = WINDOW_STEPS * STEP_CYCLES;
    localparam WINDOW_COUNT = SAMPLE_POINTS - WINDOW_STEPS + 1;
    // Packet sizes average 1350 B.  At the default 2 Gbit/s target this is a
    // 120-cycle slot, or about 11.25 Gbit/s of aggregate offered bytes before
    // source/DUT backpressure.  The Y share averages about 19.4%, keeping its
    // offered load modestly above R while F/X keep competing for Root service.
    localparam TRACE_SLOT_CYCLES_RAW =
        (TARGET_SERVICE_TIME * 20) / 125;
    localparam TRACE_SLOT_CYCLES =
        (TRACE_SLOT_CYCLES_RAW < 8) ? 8 : TRACE_SLOT_CYCLES_RAW;
    // Sixteen-packet application/NIC batches remain small compared with the
    // measurement window.  They create overlapping
    // active subtrees without turning the plotted throughput into a 0/peak
    // square wave.
    localparam TRACE_BURST_SIZE = 16;
    localparam TRACE_INTRA_BURST_CYCLES = 12;
    localparam TRACE_BURST_TAIL_CYCLES =
        TRACE_SLOT_CYCLES * TRACE_BURST_SIZE -
        TRACE_INTRA_BURST_CYCLES * (TRACE_BURST_SIZE - 1);
    localparam MODULATION_PHASE_CYCLES =
        16 * TARGET_SERVICE_TIME;
    localparam longint TARGET_BPS =
        (64'd12000 * 64'd125000000) /
        longint'(TARGET_SERVICE_TIME);
    localparam BURST_CAPACITY_REFERENCE_PACKETS = 3;
    localparam BURST_CAPACITY_TIME =
        BURST_CAPACITY_REFERENCE_PACKETS * TARGET_SERVICE_TIME;

    localparam integer MODE_DISABLED = 0;
    localparam integer MODE_ENABLED = 1;

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
    wire direct_fire;
    wire shaping_pending;
    wire [TIME_WIDTH-1:0] shaping_release_time;
    wire shaping_deferred;
    wire deferred_by_direct;
    wire deferred_by_pop;
    wire deferred_by_backpressure;
    wire [31:0] shaping_deferred_cycles;
    wire [TIME_WIDTH-1:0] release_delay_max;
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
    reg case_running;
    reg trace_enable;
    reg driver_enable;
    reg pop_enable;
    reg measurement_active;
    reg trace_done;
    reg direct_done;
    reg shaped_done;
    reg pop_done;
    longint case_epoch;
    integer measurement_cycle_count;

    integer arrived_count [0:1][0:SOURCE_NUM-1];
    integer accepted_count [0:1][0:SOURCE_NUM-1];
    integer output_count [0:1][0:SOURCE_NUM-1];
    integer accepted_id_count
        [0:1][0:SOURCE_NUM-1][0:PACKET_ID_SPACE-1];
    integer output_id_count
        [0:1][0:SOURCE_NUM-1][0:PACKET_ID_SPACE-1];
    integer root_admission_count [0:1][0:2];
    integer early_release_count [0:1];
    integer case_deferred_cycles [0:1];
    integer case_max_release_delay [0:1];
    integer case_trace_slots [0:1];

    longint cumulative_y_outputs;
    longint cumulative_y_bytes;
    longint cumulative_f_served;
    longint cumulative_x_served;
    longint cumulative_y_served;
    longint cumulative_root_f_active;
    longint cumulative_root_x_active;
    longint cumulative_root_y_active;
    longint cumulative_root_multi_active;
    longint cumulative_root_all_active;
    longint cumulative_x_local_active;
    longint cumulative_y_local_active;
    longint cumulative_z_local_active;
    longint cumulative_f_source_backlog;
    longint cumulative_x_source_backlog;
    longint cumulative_y_source_backlog;

    longint prefix_y_outputs [0:1][0:SAMPLE_POINTS];
    longint prefix_y_bytes [0:1][0:SAMPLE_POINTS];
    longint prefix_f_served [0:1][0:SAMPLE_POINTS];
    longint prefix_x_served [0:1][0:SAMPLE_POINTS];
    longint prefix_y_served [0:1][0:SAMPLE_POINTS];
    longint prefix_root_f_active [0:1][0:SAMPLE_POINTS];
    longint prefix_root_x_active [0:1][0:SAMPLE_POINTS];
    longint prefix_root_y_active [0:1][0:SAMPLE_POINTS];
    longint prefix_root_multi_active [0:1][0:SAMPLE_POINTS];
    longint prefix_root_all_active [0:1][0:SAMPLE_POINTS];
    longint prefix_x_local_active [0:1][0:SAMPLE_POINTS];
    longint prefix_y_local_active [0:1][0:SAMPLE_POINTS];
    longint prefix_z_local_active [0:1][0:SAMPLE_POINTS];
    longint prefix_f_source_backlog [0:1][0:SAMPLE_POINTS];
    longint prefix_x_source_backlog [0:1][0:SAMPLE_POINTS];
    longint prefix_y_source_backlog [0:1][0:SAMPLE_POINTS];

    integer measurement_event_count [0:1];
    integer measurement_event_cycle
        [0:1][0:MAX_MEASUREMENT_EVENTS-1];
    integer measurement_event_source
        [0:1][0:MAX_MEASUREMENT_EVENTS-1];
    integer measurement_event_sequence
        [0:1][0:MAX_MEASUREMENT_EVENTS-1];
    integer measurement_event_node
        [0:1][0:MAX_MEASUREMENT_EVENTS-1];
    integer measurement_event_bytes
        [0:1][0:MAX_MEASUREMENT_EVENTS-1];

    integer monitor_source;
    integer monitor_sequence;
    integer monitor_packet_bytes;
    integer monitor_snapshot;
    integer monitor_f_outstanding;
    integer monitor_x_outstanding;
    integer monitor_y_outstanding;
    integer monitor_x_local_outstanding;
    integer monitor_y_local_outstanding;
    integer monitor_z_local_outstanding;
    integer monitor_f_source_queued;
    integer monitor_x_source_queued;
    integer monitor_y_source_queued;
    integer monitor_active_subtrees;
    integer init_mode;
    integer init_source;
    integer init_sequence;
    integer init_sample;
    integer watchdog;

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
        .o_shaping_deferred(shaping_deferred),
        .o_deferred_by_direct_push(deferred_by_direct),
        .o_deferred_by_scheduling_pop(deferred_by_pop),
        .o_deferred_by_schedule_backpressure(deferred_by_backpressure),
        .o_shaping_deferred_cycles(shaping_deferred_cycles),
        .o_release_delay_last(),
        .o_release_delay_max(release_delay_max),
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

    function automatic integer packet_size_bytes;
        input integer source_id;
        input integer packet_sequence;
        integer size_index;
        begin
            // The sequence is intentionally periodic within the encoded ID
            // space, so the expected size remains checkable after ID wrap.
            size_index = (source_id * 5 +
                          (packet_sequence % PACKET_ID_SPACE) * 3 +
                          (packet_sequence % PACKET_ID_SPACE) / 7) % 7;
            packet_size_bytes = MIN_PACKET_BYTES + size_index * 50;
        end
    endfunction

    function automatic integer packet_service_cycles;
        input integer packet_bytes;
        longint service_numerator;
        begin
            // TARGET_SERVICE_TIME is the cost of a 1500-byte reference packet.
            // Ceil division prevents a variable-size packet from receiving
            // more than the configured byte rate through truncation.
            service_numerator =
                longint'(packet_bytes) * longint'(TARGET_SERVICE_TIME);
            packet_service_cycles = integer'(
                (service_numerator + REFERENCE_PACKET_BYTES - 1) /
                REFERENCE_PACKET_BYTES);
        end
    endfunction

    function automatic [DATA_WIDTH-1:0] make_packet_data;
        input integer source_id;
        input integer packet_sequence;
        input integer packet_bytes;
        begin
            make_packet_data =
                {1'b0, source_id[3:0], packet_sequence[10:0],
                 packet_bytes[15:0], {PTW{1'b0}}};
        end
    endfunction

    function automatic integer source_group;
        input integer source_id;
        begin
            if (source_id < 2)
                source_group = 0;
            else if (source_id < 6)
                source_group = 1;
            else
                source_group = 2;
        end
    endfunction

    function automatic [1:0] expected_output_node;
        input integer source_id;
        begin
            if (source_id < 2)
                expected_output_node = NODE_ROOT;
            else if (source_id < 6)
                expected_output_node = NODE_X;
            else if (source_id < 8)
                expected_output_node = NODE_Y;
            else
                expected_output_node = NODE_Z;
        end
    endfunction

    function automatic string mode_name;
        input integer mode;
        begin
            if (mode == MODE_ENABLED)
                mode_name = "token_bucket_enabled";
            else
                mode_name = "token_bucket_disabled";
        end
    endfunction

    function automatic integer y_share_percent;
        input integer phase;
        begin
            case (phase % 12)
                0: y_share_percent = 16;
                1: y_share_percent = 18;
                2: y_share_percent = 20;
                3: y_share_percent = 22;
                4: y_share_percent = 24;
                5: y_share_percent = 22;
                6: y_share_percent = 20;
                7: y_share_percent = 18;
                8: y_share_percent = 16;
                9: y_share_percent = 17;
                10: y_share_percent = 19;
                default: y_share_percent = 21;
            endcase
            y_share_percent =
                y_share_percent + Y_SHARE_OFFSET_PERCENT;
        end
    endfunction

    function automatic integer total_arrived;
        input integer mode;
        integer source_id;
        begin
            total_arrived = 0;
            for (source_id = 0; source_id < SOURCE_NUM;
                 source_id = source_id + 1)
                total_arrived = total_arrived +
                    arrived_count[mode][source_id];
        end
    endfunction

    function automatic integer total_accepted;
        input integer mode;
        integer source_id;
        begin
            total_accepted = 0;
            for (source_id = 0; source_id < SOURCE_NUM;
                 source_id = source_id + 1)
                total_accepted = total_accepted +
                    accepted_count[mode][source_id];
        end
    endfunction

    function automatic integer total_outputs;
        input integer mode;
        integer source_id;
        begin
            total_outputs = 0;
            for (source_id = 0; source_id < SOURCE_NUM;
                 source_id = source_id + 1)
                total_outputs = total_outputs +
                    output_count[mode][source_id];
        end
    endfunction

    function automatic bit source_pending;
        input integer mode;
        input integer source_id;
        begin
            source_pending =
                arrived_count[mode][source_id] >
                accepted_count[mode][source_id];
        end
    endfunction

    function automatic bit source_capacity_available;
        input integer source_id;
        begin
            source_capacity_available =
                schedule_logical_count[NODE_ROOT] < 300;
            if ((source_id >= 2) && (source_id < 6))
                source_capacity_available =
                    source_capacity_available &&
                    (schedule_logical_count[NODE_X] < 96);
            if (source_id >= 6)
                source_capacity_available =
                    source_capacity_available &&
                    (schedule_logical_count[NODE_Y] < 96);
            if (source_id >= 8)
                source_capacity_available =
                    source_capacity_available &&
                    (schedule_logical_count[NODE_Z] < 96);
        end
    endfunction

    task automatic configure_burst_bucket;
        begin
            @(negedge clk);
            // Start full and permit at most three reference packets worth of
            // accumulated time credit.  Under sustained backlog this converges
            // to byte-rate pacing; after an idle period it permits a bounded,
            // standards-consistent Token Bucket burst.
            token_cfg_capacity = BURST_CAPACITY_TIME[TIME_WIDTH-1:0];
            token_cfg_credit = BURST_CAPACITY_TIME[TIME_WIDTH-1:0];
            token_cfg_state_time = wall_time;
            token_cfg_state_valid = 1'b1;
            token_cfg_valid = 1'b1;
            while (!token_cfg_ready)
                @(negedge clk);
            @(negedge clk);
            token_cfg_valid = 1'b0;
        end
    endtask

    task automatic prepare_direct_packet;
        input integer source_id;
        input integer packet_sequence;
        integer node;
        integer rank_value;
        integer packet_bytes;
        begin
            for (node = 0; node < LOGICAL_TREE_NUM; node = node + 1)
                direct_rank[node] = {PTW{1'b0}};
            rank_value = packet_sequence * SOURCE_NUM + source_id;
            if (source_id < 2) begin
                direct_target = NODE_ROOT;
                direct_rank[NODE_ROOT] = 16'd0;
            end else if (source_id < 6) begin
                direct_target = NODE_X;
                direct_rank[NODE_ROOT] = 16'd1;
                direct_rank[NODE_X] = rank_value[PTW-1:0];
            end else if (source_id < 8) begin
                direct_target = NODE_Y;
                direct_rank[NODE_ROOT] = 16'd2;
                direct_rank[NODE_Y] = rank_value[PTW-1:0];
            end else begin
                direct_target = NODE_Z;
                direct_rank[NODE_ROOT] = 16'd2;
                direct_rank[NODE_Y] = rank_value[PTW-1:0];
                direct_rank[NODE_Z] =
                    (source_id < 10) ? 16'd0 : 16'd1;
            end
            packet_bytes = packet_size_bytes(source_id, packet_sequence);
            direct_data = make_packet_data(
                source_id, packet_sequence, packet_bytes);
        end
    endtask

    task automatic prepare_shaped_packet;
        input integer source_id;
        input integer packet_sequence;
        integer node;
        integer rank_value;
        integer packet_bytes;
        begin
            for (node = 0; node < LOGICAL_TREE_NUM; node = node + 1)
                d_rank[node] = {PTW{1'b0}};
            rank_value = packet_sequence * SOURCE_NUM + source_id;
            d_rank[NODE_ROOT] = 16'd2;
            if (source_id < 8) begin
                d_target = NODE_Y;
                d_rank[NODE_Y] = rank_value[PTW-1:0];
            end else begin
                d_target = NODE_Z;
                d_rank[NODE_Y] = rank_value[PTW-1:0];
                d_rank[NODE_Z] =
                    (source_id < 10) ? 16'd0 : 16'd1;
            end
            packet_bytes = packet_size_bytes(source_id, packet_sequence);
            d_service_time =
                packet_service_cycles(packet_bytes)[TIME_WIDTH-1:0];
            d_data = make_packet_data(
                source_id, packet_sequence, packet_bytes);
        end
    endtask

    task automatic arrival_trace_generator;
        input integer mode;
        integer next_slot_cycle;
        integer slot_index;
        integer phase;
        integer hash_value;
        integer background_hash;
        integer selected_source;
        integer rr_f;
        integer rr_x;
        integer rr_y;
        integer relative_cycle;
        begin
            trace_done = 1'b0;
            next_slot_cycle = 0;
            slot_index = 0;
            rr_f = 0;
            rr_x = 0;
            rr_y = 0;
            while (trace_enable) begin
                @(negedge clk);
                relative_cycle = int'(longint'(wall_time) - case_epoch);
                if (relative_cycle >= next_slot_cycle) begin
                    phase = relative_cycle / MODULATION_PHASE_CYCLES;
                    hash_value = (slot_index * 37 +
                                  (slot_index / 7) * 13 + 17) % 100;
                    background_hash = (slot_index * 29 + 11) % 100;
                    if (hash_value < y_share_percent(phase)) begin
                        selected_source = 6 + (rr_y % 6);
                        rr_y = rr_y + 1;
                    end else if (background_hash < 22) begin
                        selected_source = rr_f % 2;
                        rr_f = rr_f + 1;
                    end else begin
                        selected_source = 2 + (rr_x % 4);
                        rr_x = rr_x + 1;
                    end
                    arrived_count[mode][selected_source] =
                        arrived_count[mode][selected_source] + 1;
                    slot_index = slot_index + 1;
                    if ((slot_index % TRACE_BURST_SIZE) == 0)
                        next_slot_cycle = next_slot_cycle +
                            TRACE_BURST_TAIL_CYCLES;
                    else
                        next_slot_cycle = next_slot_cycle +
                            TRACE_INTRA_BURST_CYCLES;
                end
            end
            case_trace_slots[mode] = slot_index;
            trace_done = 1'b1;
        end
    endtask

    task automatic direct_driver;
        input integer mode;
        integer round_robin;
        integer offset;
        integer candidate;
        integer selected_source;
        integer packet_sequence;
        reg accepted;
        begin
            direct_done = 1'b0;
            round_robin = 0;
            direct_valid = 1'b0;
            while (driver_enable ||
                   (total_arrived(mode) != total_accepted(mode))) begin
                selected_source = -1;
                for (offset = 0; offset < SOURCE_NUM;
                     offset = offset + 1) begin
                    candidate = (round_robin + offset) % SOURCE_NUM;
                    if ((selected_source < 0) &&
                        ((mode == MODE_DISABLED) || (candidate < 6)) &&
                        source_pending(mode, candidate) &&
                        source_capacity_available(candidate))
                        selected_source = candidate;
                end
                if (selected_source >= 0) begin
                    packet_sequence =
                        accepted_count[mode][selected_source];
                    prepare_direct_packet(selected_source, packet_sequence);
                    direct_valid = 1'b1;
                    accepted = 1'b0;
                    while (!accepted) begin
                        @(posedge clk);
                        if (direct_ready)
                            accepted = 1'b1;
                    end
                    @(negedge clk);
                    direct_valid = 1'b0;
                    accepted_id_count[mode][selected_source]
                        [packet_sequence % PACKET_ID_SPACE] =
                            accepted_id_count[mode][selected_source]
                                [packet_sequence % PACKET_ID_SPACE] + 1;
                    accepted_count[mode][selected_source] =
                        accepted_count[mode][selected_source] + 1;
                    round_robin = (selected_source + 1) % SOURCE_NUM;
                end else begin
                    @(negedge clk);
                end
            end
            direct_valid = 1'b0;
            direct_done = 1'b1;
        end
    endtask

    task automatic shaped_driver;
        input integer mode;
        integer round_robin;
        integer offset;
        integer candidate;
        integer selected_source;
        integer packet_sequence;
        reg accepted;
        begin
            shaped_done = 1'b0;
            round_robin = 6;
            d_valid = 1'b0;
            if (mode == MODE_ENABLED) begin
                while (driver_enable ||
                       (total_arrived(mode) != total_accepted(mode))) begin
                    selected_source = -1;
                    for (offset = 0; offset < 6; offset = offset + 1) begin
                        candidate = 6 + ((round_robin - 6 + offset) % 6);
                        if ((selected_source < 0) &&
                            source_pending(mode, candidate) &&
                            source_capacity_available(candidate))
                            selected_source = candidate;
                    end
                    if (selected_source >= 0) begin
                        packet_sequence =
                            accepted_count[mode][selected_source];
                        prepare_shaped_packet(selected_source,
                                              packet_sequence);
                        d_valid = 1'b1;
                        accepted = 1'b0;
                        while (!accepted) begin
                            @(posedge clk);
                            if (d_ready)
                                accepted = 1'b1;
                        end
                        @(negedge clk);
                        d_valid = 1'b0;
                        accepted_id_count[mode][selected_source]
                            [packet_sequence % PACKET_ID_SPACE] =
                                accepted_id_count[mode][selected_source]
                                    [packet_sequence % PACKET_ID_SPACE] + 1;
                        accepted_count[mode][selected_source] =
                            accepted_count[mode][selected_source] + 1;
                        round_robin = 6 + ((selected_source - 5) % 6);
                    end else begin
                        @(negedge clk);
                    end
                end
            end
            d_valid = 1'b0;
            shaped_done = 1'b1;
        end
    endtask

    task automatic pop_consumer;
        input integer mode;
        reg accepted;
        integer output_target;
        begin
            pop_done = 1'b0;
            pop_valid = 1'b0;
            while (pop_enable) begin
                @(negedge clk);
                pop_valid = 1'b0;
                accepted = 1'b0;
                if (schedule_logical_count[NODE_ROOT] != 0) begin
                    output_target = total_outputs(mode) + 1;
                    pop_valid = 1'b1;
                    while (pop_enable && !accepted) begin
                        @(posedge clk);
                        if (pop_ready)
                            accepted = 1'b1;
                    end
                    @(negedge clk);
                    pop_valid = 1'b0;
                    while (pop_enable &&
                           (total_outputs(mode) < output_target))
                        @(negedge clk);
                end
            end
            pop_valid = 1'b0;
            pop_done = 1'b1;
        end
    endtask

    always @(posedge clk) begin
        if (arst_n && case_running) begin
            if (shaping_fire) begin
                if (wall_time < shaping_release_time)
                    early_release_count[case_mode] =
                        early_release_count[case_mode] + 1;
                root_admission_count[case_mode][2] =
                    root_admission_count[case_mode][2] + 1;
            end
            if (direct_fire) begin
                monitor_source = int'(direct_data[DATA_WIDTH-2 -: 4]);
                if ((monitor_source < 0) ||
                    (monitor_source >= SOURCE_NUM))
                    $fatal(1, "bad direct source id %0d", monitor_source);
                case (source_group(monitor_source))
                    0: root_admission_count[case_mode][0] =
                        root_admission_count[case_mode][0] + 1;
                    1: root_admission_count[case_mode][1] =
                        root_admission_count[case_mode][1] + 1;
                    default: root_admission_count[case_mode][2] =
                        root_admission_count[case_mode][2] + 1;
                endcase
            end

            if (packet_out_valid) begin
                monitor_source = int'(packet_out_data[DATA_WIDTH-2 -: 4]);
                monitor_sequence = int'(packet_out_data[DATA_WIDTH-6 -: 11]);
                monitor_packet_bytes = int'(packet_out_data[PTW+15:PTW]);
                if ((monitor_source < 0) ||
                    (monitor_source >= SOURCE_NUM) ||
                    (monitor_sequence < 0) ||
                    (monitor_sequence >= PACKET_ID_SPACE))
                    $fatal(1,
                        "bad output metadata source=%0d sequence=%0d",
                        monitor_source, monitor_sequence);
                if ((monitor_packet_bytes < MIN_PACKET_BYTES) ||
                    (monitor_packet_bytes > MAX_PACKET_BYTES) ||
                    (monitor_packet_bytes !=
                     packet_size_bytes(monitor_source, monitor_sequence)))
                    $fatal(1,
                        "bad output packet size source=%0d sequence=%0d bytes=%0d expected=%0d",
                        monitor_source, monitor_sequence,
                        monitor_packet_bytes,
                        packet_size_bytes(monitor_source, monitor_sequence));
                if (packet_out_node != expected_output_node(monitor_source))
                    $fatal(1,
                        "bad output node source=%0d node=%0d expected=%0d",
                        monitor_source, packet_out_node,
                        expected_output_node(monitor_source));
                if (output_id_count[case_mode][monitor_source]
                    [monitor_sequence] >=
                    accepted_id_count[case_mode][monitor_source]
                        [monitor_sequence]) begin
                    $fatal(1,
                        "duplicate or unaccepted output mode=%0d source=%0d id=%0d accepted_multiplicity=%0d output_multiplicity=%0d",
                        case_mode, monitor_source, monitor_sequence,
                        accepted_id_count[case_mode][monitor_source]
                            [monitor_sequence],
                        output_id_count[case_mode][monitor_source]
                            [monitor_sequence]);
                end
                output_id_count[case_mode][monitor_source]
                    [monitor_sequence] =
                        output_id_count[case_mode][monitor_source]
                            [monitor_sequence] + 1;
                output_count[case_mode][monitor_source] =
                    output_count[case_mode][monitor_source] + 1;

                if (measurement_active) begin
                    if (measurement_event_count[case_mode] >=
                        MAX_MEASUREMENT_EVENTS) begin
                        $fatal(1, "measurement event log overflow");
                    end
                    measurement_event_cycle[case_mode]
                        [measurement_event_count[case_mode]] =
                            measurement_cycle_count;
                    measurement_event_source[case_mode]
                        [measurement_event_count[case_mode]] =
                            monitor_source;
                    measurement_event_sequence[case_mode]
                        [measurement_event_count[case_mode]] =
                            monitor_sequence;
                    measurement_event_node[case_mode]
                        [measurement_event_count[case_mode]] =
                            int'(packet_out_node);
                    measurement_event_bytes[case_mode]
                        [measurement_event_count[case_mode]] =
                            monitor_packet_bytes;
                    measurement_event_count[case_mode] =
                        measurement_event_count[case_mode] + 1;
                end
            end

            if (measurement_active) begin
                monitor_f_outstanding =
                    accepted_count[case_mode][0] +
                    accepted_count[case_mode][1] -
                    output_count[case_mode][0] -
                    output_count[case_mode][1];
                monitor_x_outstanding =
                    root_admission_count[case_mode][1] -
                    output_count[case_mode][2] -
                    output_count[case_mode][3] -
                    output_count[case_mode][4] -
                    output_count[case_mode][5];
                monitor_y_outstanding =
                    root_admission_count[case_mode][2] -
                    output_count[case_mode][6] -
                    output_count[case_mode][7] -
                    output_count[case_mode][8] -
                    output_count[case_mode][9] -
                    output_count[case_mode][10] -
                    output_count[case_mode][11];
                monitor_x_local_outstanding =
                    accepted_count[case_mode][2] +
                    accepted_count[case_mode][3] +
                    accepted_count[case_mode][4] +
                    accepted_count[case_mode][5] -
                    output_count[case_mode][2] -
                    output_count[case_mode][3] -
                    output_count[case_mode][4] -
                    output_count[case_mode][5];
                monitor_y_local_outstanding =
                    accepted_count[case_mode][6] +
                    accepted_count[case_mode][7] +
                    accepted_count[case_mode][8] +
                    accepted_count[case_mode][9] +
                    accepted_count[case_mode][10] +
                    accepted_count[case_mode][11] -
                    output_count[case_mode][6] -
                    output_count[case_mode][7] -
                    output_count[case_mode][8] -
                    output_count[case_mode][9] -
                    output_count[case_mode][10] -
                    output_count[case_mode][11];
                monitor_z_local_outstanding =
                    accepted_count[case_mode][8] +
                    accepted_count[case_mode][9] +
                    accepted_count[case_mode][10] +
                    accepted_count[case_mode][11] -
                    output_count[case_mode][8] -
                    output_count[case_mode][9] -
                    output_count[case_mode][10] -
                    output_count[case_mode][11];
                monitor_f_source_queued =
                    arrived_count[case_mode][0] +
                    arrived_count[case_mode][1] -
                    accepted_count[case_mode][0] -
                    accepted_count[case_mode][1];
                monitor_x_source_queued =
                    arrived_count[case_mode][2] +
                    arrived_count[case_mode][3] +
                    arrived_count[case_mode][4] +
                    arrived_count[case_mode][5] -
                    accepted_count[case_mode][2] -
                    accepted_count[case_mode][3] -
                    accepted_count[case_mode][4] -
                    accepted_count[case_mode][5];
                monitor_y_source_queued =
                    arrived_count[case_mode][6] +
                    arrived_count[case_mode][7] +
                    arrived_count[case_mode][8] +
                    arrived_count[case_mode][9] +
                    arrived_count[case_mode][10] +
                    arrived_count[case_mode][11] -
                    accepted_count[case_mode][6] -
                    accepted_count[case_mode][7] -
                    accepted_count[case_mode][8] -
                    accepted_count[case_mode][9] -
                    accepted_count[case_mode][10] -
                    accepted_count[case_mode][11];
                monitor_active_subtrees =
                    ((monitor_f_outstanding > 0) ? 1 : 0) +
                    ((monitor_x_outstanding > 0) ? 1 : 0) +
                    ((monitor_y_outstanding > 0) ? 1 : 0);

                cumulative_y_outputs <= cumulative_y_outputs +
                    ((packet_out_valid &&
                      (int'(packet_out_data[DATA_WIDTH-2 -: 4]) >= 6)) ? 1 : 0);
                cumulative_y_bytes <= cumulative_y_bytes +
                    ((packet_out_valid &&
                      (int'(packet_out_data[DATA_WIDTH-2 -: 4]) >= 6)) ?
                     longint'(packet_out_data[PTW+15:PTW]) : 0);
                cumulative_f_served <= cumulative_f_served +
                    ((packet_out_valid &&
                      (int'(packet_out_data[DATA_WIDTH-2 -: 4]) < 2)) ? 1 : 0);
                cumulative_x_served <= cumulative_x_served +
                    ((packet_out_valid &&
                      (int'(packet_out_data[DATA_WIDTH-2 -: 4]) >= 2) &&
                      (int'(packet_out_data[DATA_WIDTH-2 -: 4]) < 6)) ? 1 : 0);
                cumulative_y_served <= cumulative_y_served +
                    ((packet_out_valid &&
                      (int'(packet_out_data[DATA_WIDTH-2 -: 4]) >= 6)) ? 1 : 0);
                cumulative_root_f_active <= cumulative_root_f_active +
                    ((monitor_f_outstanding > 0) ? 1 : 0);
                cumulative_root_x_active <= cumulative_root_x_active +
                    ((monitor_x_outstanding > 0) ? 1 : 0);
                cumulative_root_y_active <= cumulative_root_y_active +
                    ((monitor_y_outstanding > 0) ? 1 : 0);
                cumulative_root_multi_active <=
                    cumulative_root_multi_active +
                    ((monitor_active_subtrees >= 2) ? 1 : 0);
                cumulative_root_all_active <= cumulative_root_all_active +
                    ((monitor_active_subtrees == 3) ? 1 : 0);
                cumulative_x_local_active <= cumulative_x_local_active +
                    ((monitor_x_local_outstanding > 0) ? 1 : 0);
                cumulative_y_local_active <= cumulative_y_local_active +
                    ((monitor_y_local_outstanding > 0) ? 1 : 0);
                cumulative_z_local_active <= cumulative_z_local_active +
                    ((monitor_z_local_outstanding > 0) ? 1 : 0);
                cumulative_f_source_backlog <=
                    cumulative_f_source_backlog +
                    ((monitor_f_source_queued > 0) ? 1 : 0);
                cumulative_x_source_backlog <=
                    cumulative_x_source_backlog +
                    ((monitor_x_source_queued > 0) ? 1 : 0);
                cumulative_y_source_backlog <=
                    cumulative_y_source_backlog +
                    ((monitor_y_source_queued > 0) ? 1 : 0);

                measurement_cycle_count <= measurement_cycle_count + 1;
                if (((measurement_cycle_count + 1) % STEP_CYCLES) == 0) begin
                    monitor_snapshot =
                        (measurement_cycle_count + 1) / STEP_CYCLES;
                    prefix_y_outputs[case_mode][monitor_snapshot] <=
                        cumulative_y_outputs +
                        ((packet_out_valid &&
                          (int'(packet_out_data[DATA_WIDTH-2 -: 4]) >= 6)) ? 1 : 0);
                    prefix_y_bytes[case_mode][monitor_snapshot] <=
                        cumulative_y_bytes +
                        ((packet_out_valid &&
                          (int'(packet_out_data[DATA_WIDTH-2 -: 4]) >= 6)) ?
                         longint'(packet_out_data[PTW+15:PTW]) : 0);
                    prefix_f_served[case_mode][monitor_snapshot] <=
                        cumulative_f_served +
                        ((packet_out_valid &&
                          (int'(packet_out_data[DATA_WIDTH-2 -: 4]) < 2)) ? 1 : 0);
                    prefix_x_served[case_mode][monitor_snapshot] <=
                        cumulative_x_served +
                        ((packet_out_valid &&
                          (int'(packet_out_data[DATA_WIDTH-2 -: 4]) >= 2) &&
                          (int'(packet_out_data[DATA_WIDTH-2 -: 4]) < 6)) ? 1 : 0);
                    prefix_y_served[case_mode][monitor_snapshot] <=
                        cumulative_y_served +
                        ((packet_out_valid &&
                          (int'(packet_out_data[DATA_WIDTH-2 -: 4]) >= 6)) ? 1 : 0);
                    prefix_root_f_active[case_mode][monitor_snapshot] <=
                        cumulative_root_f_active +
                        ((monitor_f_outstanding > 0) ? 1 : 0);
                    prefix_root_x_active[case_mode][monitor_snapshot] <=
                        cumulative_root_x_active +
                        ((monitor_x_outstanding > 0) ? 1 : 0);
                    prefix_root_y_active[case_mode][monitor_snapshot] <=
                        cumulative_root_y_active +
                        ((monitor_y_outstanding > 0) ? 1 : 0);
                    prefix_root_multi_active[case_mode][monitor_snapshot] <=
                        cumulative_root_multi_active +
                        ((monitor_active_subtrees >= 2) ? 1 : 0);
                    prefix_root_all_active[case_mode][monitor_snapshot] <=
                        cumulative_root_all_active +
                        ((monitor_active_subtrees == 3) ? 1 : 0);
                    prefix_x_local_active[case_mode][monitor_snapshot] <=
                        cumulative_x_local_active +
                        ((monitor_x_local_outstanding > 0) ? 1 : 0);
                    prefix_y_local_active[case_mode][monitor_snapshot] <=
                        cumulative_y_local_active +
                        ((monitor_y_local_outstanding > 0) ? 1 : 0);
                    prefix_z_local_active[case_mode][monitor_snapshot] <=
                        cumulative_z_local_active +
                        ((monitor_z_local_outstanding > 0) ? 1 : 0);
                    prefix_f_source_backlog[case_mode][monitor_snapshot] <=
                        cumulative_f_source_backlog +
                        ((monitor_f_source_queued > 0) ? 1 : 0);
                    prefix_x_source_backlog[case_mode][monitor_snapshot] <=
                        cumulative_x_source_backlog +
                        ((monitor_x_source_queued > 0) ? 1 : 0);
                    prefix_y_source_backlog[case_mode][monitor_snapshot] <=
                        cumulative_y_source_backlog +
                        ((monitor_y_source_queued > 0) ? 1 : 0);
                end
            end
        end
    end

    task automatic initialize_case_state;
        input integer mode;
        integer source_id;
        integer sequence_index;
        integer sample;
        begin
            for (source_id = 0; source_id < SOURCE_NUM;
                 source_id = source_id + 1) begin
                arrived_count[mode][source_id] = 0;
                accepted_count[mode][source_id] = 0;
                output_count[mode][source_id] = 0;
                for (sequence_index = 0;
                     sequence_index < PACKET_ID_SPACE;
                     sequence_index = sequence_index + 1)
                    begin
                        accepted_id_count[mode][source_id]
                            [sequence_index] = 0;
                        output_id_count[mode][source_id]
                            [sequence_index] = 0;
                    end
            end
            for (sample = 0; sample <= SAMPLE_POINTS;
                 sample = sample + 1) begin
                prefix_y_outputs[mode][sample] = 0;
                prefix_y_bytes[mode][sample] = 0;
                prefix_f_served[mode][sample] = 0;
                prefix_x_served[mode][sample] = 0;
                prefix_y_served[mode][sample] = 0;
                prefix_root_f_active[mode][sample] = 0;
                prefix_root_x_active[mode][sample] = 0;
                prefix_root_y_active[mode][sample] = 0;
                prefix_root_multi_active[mode][sample] = 0;
                prefix_root_all_active[mode][sample] = 0;
                prefix_x_local_active[mode][sample] = 0;
                prefix_y_local_active[mode][sample] = 0;
                prefix_z_local_active[mode][sample] = 0;
                prefix_f_source_backlog[mode][sample] = 0;
                prefix_x_source_backlog[mode][sample] = 0;
                prefix_y_source_backlog[mode][sample] = 0;
            end
            root_admission_count[mode][0] = 0;
            root_admission_count[mode][1] = 0;
            root_admission_count[mode][2] = 0;
            early_release_count[mode] = 0;
            case_deferred_cycles[mode] = 0;
            case_max_release_delay[mode] = 0;
            case_trace_slots[mode] = 0;
            measurement_event_count[mode] = 0;
        end
    endtask

    task automatic reset_measurement_counters;
        input integer mode;
        begin
            measurement_cycle_count = 0;
            cumulative_y_outputs = 0;
            cumulative_y_bytes = 0;
            cumulative_f_served = 0;
            cumulative_x_served = 0;
            cumulative_y_served = 0;
            cumulative_root_f_active = 0;
            cumulative_root_x_active = 0;
            cumulative_root_y_active = 0;
            cumulative_root_multi_active = 0;
            cumulative_root_all_active = 0;
            cumulative_x_local_active = 0;
            cumulative_y_local_active = 0;
            cumulative_z_local_active = 0;
            cumulative_f_source_backlog = 0;
            cumulative_x_source_backlog = 0;
            cumulative_y_source_backlog = 0;
            prefix_y_outputs[mode][0] = 0;
            prefix_y_bytes[mode][0] = 0;
            prefix_f_served[mode][0] = 0;
            prefix_x_served[mode][0] = 0;
            prefix_y_served[mode][0] = 0;
            prefix_root_f_active[mode][0] = 0;
            prefix_root_x_active[mode][0] = 0;
            prefix_root_y_active[mode][0] = 0;
            prefix_root_multi_active[mode][0] = 0;
            prefix_root_all_active[mode][0] = 0;
            prefix_x_local_active[mode][0] = 0;
            prefix_y_local_active[mode][0] = 0;
            prefix_z_local_active[mode][0] = 0;
            prefix_f_source_backlog[mode][0] = 0;
            prefix_x_source_backlog[mode][0] = 0;
            prefix_y_source_backlog[mode][0] = 0;
        end
    endtask

    task automatic check_case_drain;
        input integer mode;
        integer source_id;
        integer sequence_index;
        begin
            if (protocol_error)
                $fatal(1, "protocol_error after mode %0d", mode);
            if (early_release_count[mode] != 0)
                $fatal(1, "early release in mode %0d", mode);
            if ((schedule_logical_count[NODE_ROOT] != 0) ||
                (schedule_logical_count[NODE_X] != 0) ||
                (schedule_logical_count[NODE_Y] != 0) ||
                (schedule_logical_count[NODE_Z] != 0) ||
                (timing_event_count != 0) ||
                (timing_release_count != 0) ||
                (schedule_pending_count != 0) ||
                (schedule_outstanding_count != 0) || busy)
                $fatal(1,
                    "non-empty drain mode=%0d logical=%0d,%0d,%0d,%0d timing=%0d/%0d pending=%0d outstanding=%0d busy=%0d",
                    mode, schedule_logical_count[NODE_ROOT],
                    schedule_logical_count[NODE_X],
                    schedule_logical_count[NODE_Y],
                    schedule_logical_count[NODE_Z], timing_event_count,
                    timing_release_count, schedule_pending_count,
                    schedule_outstanding_count, busy);
            for (source_id = 0; source_id < SOURCE_NUM;
                 source_id = source_id + 1) begin
                if ((arrived_count[mode][source_id] !=
                     accepted_count[mode][source_id]) ||
                    (accepted_count[mode][source_id] !=
                     output_count[mode][source_id]))
                    $fatal(1,
                        "exactly-once mismatch mode=%0d source=%0d arrived=%0d accepted=%0d output=%0d",
                        mode, source_id,
                        arrived_count[mode][source_id],
                        accepted_count[mode][source_id],
                        output_count[mode][source_id]);
                for (sequence_index = 0;
                     sequence_index < PACKET_ID_SPACE;
                     sequence_index = sequence_index + 1)
                    if (accepted_id_count[mode][source_id]
                            [sequence_index] !=
                        output_id_count[mode][source_id]
                            [sequence_index])
                        $fatal(1,
                            "packet-ID multiplicity mismatch mode=%0d source=%0d id=%0d accepted=%0d output=%0d",
                            mode, source_id, sequence_index,
                            accepted_id_count[mode][source_id]
                                [sequence_index],
                            output_id_count[mode][source_id]
                                [sequence_index]);
            end
        end
    endtask

    task automatic run_case;
        input integer mode;
        begin
            case_mode = mode;
            case_running = 1'b0;
            trace_enable = 1'b0;
            driver_enable = 1'b0;
            pop_enable = 1'b0;
            measurement_active = 1'b0;
            direct_valid = 1'b0;
            d_valid = 1'b0;
            pop_valid = 1'b0;
            token_cfg_valid = 1'b0;
            arst_n = 1'b0;
            repeat (8) @(negedge clk);
            arst_n = 1'b1;
            repeat (4) @(negedge clk);
            configure_burst_bucket();

            case_epoch = longint'(wall_time);
            case_running = 1'b1;
            trace_enable = 1'b1;
            driver_enable = 1'b1;
            pop_enable = 1'b1;
            fork
                arrival_trace_generator(mode);
                direct_driver(mode);
                shaped_driver(mode);
                pop_consumer(mode);
            join_none

            repeat (WARMUP_CYCLES) @(posedge clk);
            @(negedge clk);
            reset_measurement_counters(mode);
            measurement_active = 1'b1;
            repeat (MEASUREMENT_CYCLES) @(posedge clk);
            @(negedge clk);
            measurement_active = 1'b0;
            trace_enable = 1'b0;

            watchdog = 0;
            while (!trace_done && (watchdog < 100000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (watchdog == 100000)
                $fatal(1, "trace stop timeout mode=%0d", mode);

            watchdog = 0;
            while ((total_arrived(mode) != total_accepted(mode)) &&
                   (watchdog < 10000000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (watchdog == 10000000)
                $fatal(1,
                    "driver drain timeout mode=%0d arrived=%0d accepted=%0d",
                    mode, total_arrived(mode), total_accepted(mode));
            driver_enable = 1'b0;

            watchdog = 0;
            while ((!direct_done || !shaped_done) &&
                   (watchdog < 100000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (watchdog == 100000)
                $fatal(1, "driver stop timeout mode=%0d", mode);

            watchdog = 0;
            while (((total_outputs(mode) != total_accepted(mode)) ||
                    (schedule_logical_count[NODE_ROOT] != 0) ||
                    (schedule_logical_count[NODE_X] != 0) ||
                    (schedule_logical_count[NODE_Y] != 0) ||
                    (schedule_logical_count[NODE_Z] != 0) ||
                    (timing_event_count != 0) ||
                    (timing_release_count != 0) ||
                    (schedule_pending_count != 0) ||
                    (schedule_outstanding_count != 0) || busy) &&
                   (watchdog < 20000000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (watchdog == 20000000)
                $fatal(1,
                    "DUT drain timeout mode=%0d accepted=%0d output=%0d logical=%0d,%0d,%0d,%0d timing=%0d/%0d pending=%0d outstanding=%0d busy=%0d",
                    mode, total_accepted(mode), total_outputs(mode),
                    schedule_logical_count[NODE_ROOT],
                    schedule_logical_count[NODE_X],
                    schedule_logical_count[NODE_Y],
                    schedule_logical_count[NODE_Z], timing_event_count,
                    timing_release_count, schedule_pending_count,
                    schedule_outstanding_count, busy);

            pop_enable = 1'b0;
            watchdog = 0;
            while (!pop_done && (watchdog < 100000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (watchdog == 100000)
                $fatal(1, "pop stop timeout mode=%0d", mode);

            case_deferred_cycles[mode] = int'(shaping_deferred_cycles);
            case_max_release_delay[mode] = int'(release_delay_max);
            case_running = 1'b0;
            check_case_drain(mode);
        end
    endtask

    task automatic write_results_and_check;
        integer window_file;
        integer event_file;
        integer summary_file;
        integer mode;
        integer end_sample;
        integer start_sample;
        integer window_index;
        integer event_index;
        integer source_id;
        longint packets;
        longint bytes;
        longint rate_bps;
        longint rate_mbps;
        longint target_mbps;
        longint delta_mbps;
        longint rate_sum_mbps [0:1];
        longint mad_sum_mbps [0:1];
        longint min_rate_bps [0:1];
        longint max_rate_bps [0:1];
        longint mean_rate_bps [0:1];
        longint mad_rate_mbps [0:1];
        longint f_served;
        longint x_served;
        longint y_served;
        longint root_f_active;
        longint root_x_active;
        longint root_y_active;
        longint root_multi_active;
        longint root_all_active;
        longint x_local_active;
        longint y_local_active;
        longint z_local_active;
        longint f_source_backlog;
        longint x_source_backlog;
        longint y_source_backlog;
        begin
            target_mbps = TARGET_BPS / 1000000;
            for (mode = 0; mode < 2; mode = mode + 1) begin
                rate_sum_mbps[mode] = 0;
                mad_sum_mbps[mode] = 0;
                min_rate_bps[mode] = 64'h7fffffffffffffff;
                max_rate_bps[mode] = 0;
            end

            window_file = $fopen(
                "hierarchical_sustained_ab_windows.csv", "w");
            if (window_file == 0)
                $fatal(1, "cannot open window CSV");
            $fwrite(window_file,
                "mode,window_index,window_start_cycle,window_end_cycle,target_bps,y_packets,y_bytes,y_bps,f_served,x_served,y_served,root_f_active_fraction,root_x_active_fraction,root_y_active_fraction,root_multi_active_fraction,root_all_active_fraction,x_local_active_fraction,y_local_active_fraction,z_local_active_fraction,f_source_backlog_fraction,x_source_backlog_fraction,y_source_backlog_fraction\n");

            for (mode = 0; mode < 2; mode = mode + 1) begin
                window_index = 0;
                for (end_sample = WINDOW_STEPS;
                     end_sample <= SAMPLE_POINTS;
                     end_sample = end_sample + 1) begin
                    start_sample = end_sample - WINDOW_STEPS;
                    packets = prefix_y_outputs[mode][end_sample] -
                        prefix_y_outputs[mode][start_sample];
                    bytes = prefix_y_bytes[mode][end_sample] -
                        prefix_y_bytes[mode][start_sample];
                    rate_bps = bytes * 8 * CLOCK_HZ /
                        longint'(WINDOW_CYCLES);
                    rate_mbps = rate_bps / 1000000;
                    rate_sum_mbps[mode] =
                        rate_sum_mbps[mode] + rate_mbps;
                    if (rate_bps < min_rate_bps[mode])
                        min_rate_bps[mode] = rate_bps;
                    if (rate_bps > max_rate_bps[mode])
                        max_rate_bps[mode] = rate_bps;
                    if (rate_mbps >= target_mbps)
                        delta_mbps = rate_mbps - target_mbps;
                    else
                        delta_mbps = target_mbps - rate_mbps;
                    mad_sum_mbps[mode] =
                        mad_sum_mbps[mode] + delta_mbps;

                    f_served = prefix_f_served[mode][end_sample] -
                        prefix_f_served[mode][start_sample];
                    x_served = prefix_x_served[mode][end_sample] -
                        prefix_x_served[mode][start_sample];
                    y_served = prefix_y_served[mode][end_sample] -
                        prefix_y_served[mode][start_sample];
                    root_f_active =
                        prefix_root_f_active[mode][end_sample] -
                        prefix_root_f_active[mode][start_sample];
                    root_x_active =
                        prefix_root_x_active[mode][end_sample] -
                        prefix_root_x_active[mode][start_sample];
                    root_y_active =
                        prefix_root_y_active[mode][end_sample] -
                        prefix_root_y_active[mode][start_sample];
                    root_multi_active =
                        prefix_root_multi_active[mode][end_sample] -
                        prefix_root_multi_active[mode][start_sample];
                    root_all_active =
                        prefix_root_all_active[mode][end_sample] -
                        prefix_root_all_active[mode][start_sample];
                    x_local_active =
                        prefix_x_local_active[mode][end_sample] -
                        prefix_x_local_active[mode][start_sample];
                    y_local_active =
                        prefix_y_local_active[mode][end_sample] -
                        prefix_y_local_active[mode][start_sample];
                    z_local_active =
                        prefix_z_local_active[mode][end_sample] -
                        prefix_z_local_active[mode][start_sample];
                    f_source_backlog =
                        prefix_f_source_backlog[mode][end_sample] -
                        prefix_f_source_backlog[mode][start_sample];
                    x_source_backlog =
                        prefix_x_source_backlog[mode][end_sample] -
                        prefix_x_source_backlog[mode][start_sample];
                    y_source_backlog =
                        prefix_y_source_backlog[mode][end_sample] -
                        prefix_y_source_backlog[mode][start_sample];

                    $fwrite(window_file,
                        "%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0.6f,%0.6f,%0.6f,%0.6f,%0.6f,%0.6f,%0.6f,%0.6f,%0.6f,%0.6f,%0.6f\n",
                        mode_name(mode),
                        window_index,
                        start_sample * STEP_CYCLES,
                        end_sample * STEP_CYCLES,
                        TARGET_BPS, packets, bytes, rate_bps,
                        f_served, x_served, y_served,
                        real'(root_f_active) / real'(WINDOW_CYCLES),
                        real'(root_x_active) / real'(WINDOW_CYCLES),
                        real'(root_y_active) / real'(WINDOW_CYCLES),
                        real'(root_multi_active) / real'(WINDOW_CYCLES),
                        real'(root_all_active) / real'(WINDOW_CYCLES),
                        real'(x_local_active) / real'(WINDOW_CYCLES),
                        real'(y_local_active) / real'(WINDOW_CYCLES),
                        real'(z_local_active) / real'(WINDOW_CYCLES),
                        real'(f_source_backlog) / real'(WINDOW_CYCLES),
                        real'(x_source_backlog) / real'(WINDOW_CYCLES),
                        real'(y_source_backlog) / real'(WINDOW_CYCLES));
                    window_index = window_index + 1;
                end
                mean_rate_bps[mode] =
                    rate_sum_mbps[mode] * 1000000 /
                    longint'(WINDOW_COUNT);
                mad_rate_mbps[mode] =
                    mad_sum_mbps[mode] / longint'(WINDOW_COUNT);
            end
            $fclose(window_file);

            event_file = $fopen(
                "hierarchical_sustained_ab_events.csv", "w");
            if (event_file == 0)
                $fatal(1, "cannot open event CSV");
            $fwrite(event_file,
                "mode,event_index,measurement_cycle,source_id,source_sequence,packet_bytes,service_cycles,output_node,subtree\n");
            for (mode = 0; mode < 2; mode = mode + 1)
                for (event_index = 0;
                     event_index < measurement_event_count[mode];
                     event_index = event_index + 1) begin
                    source_id = measurement_event_source[mode][event_index];
                    $fwrite(event_file,
                        "%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%s\n",
                        mode_name(mode),
                        event_index,
                        measurement_event_cycle[mode][event_index],
                        source_id,
                        measurement_event_sequence[mode][event_index],
                        measurement_event_bytes[mode][event_index],
                        packet_service_cycles(
                            measurement_event_bytes[mode][event_index]),
                        measurement_event_node[mode][event_index],
                        (source_id < 2) ? "F" :
                        ((source_id < 6) ? "X" : "Y"));
                end
            $fclose(event_file);

            summary_file = $fopen(
                "hierarchical_sustained_ab_summary.csv", "w");
            if (summary_file == 0)
                $fatal(1, "cannot open summary CSV");
            $fwrite(summary_file,
                "mode,target_bps,mean_y_bps,min_y_bps,max_y_bps,mad_from_target_mbps,measurement_y_packets,measurement_y_bytes,min_packet_bytes,max_packet_bytes,burst_capacity_time,window_cycles,step_cycles,trace_slots,total_packets,deferred_cycles,max_release_delay,root_f_active_fraction,root_x_active_fraction,root_y_active_fraction,root_multi_active_fraction,root_all_active_fraction,x_local_active_fraction,y_local_active_fraction,z_local_active_fraction,f_source_backlog_fraction,x_source_backlog_fraction,y_source_backlog_fraction\n");
            for (mode = 0; mode < 2; mode = mode + 1)
                $fwrite(summary_file,
                    "%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0.6f,%0.6f,%0.6f,%0.6f,%0.6f,%0.6f,%0.6f,%0.6f,%0.6f,%0.6f,%0.6f\n",
                    mode_name(mode),
                    TARGET_BPS, mean_rate_bps[mode],
                    min_rate_bps[mode], max_rate_bps[mode],
                    mad_rate_mbps[mode],
                    prefix_y_outputs[mode][SAMPLE_POINTS],
                    prefix_y_bytes[mode][SAMPLE_POINTS],
                    MIN_PACKET_BYTES, MAX_PACKET_BYTES,
                    BURST_CAPACITY_TIME, WINDOW_CYCLES, STEP_CYCLES,
                    case_trace_slots[mode], total_outputs(mode),
                    case_deferred_cycles[mode],
                    case_max_release_delay[mode],
                    real'(prefix_root_f_active[mode][SAMPLE_POINTS]) /
                        real'(MEASUREMENT_CYCLES),
                    real'(prefix_root_x_active[mode][SAMPLE_POINTS]) /
                        real'(MEASUREMENT_CYCLES),
                    real'(prefix_root_y_active[mode][SAMPLE_POINTS]) /
                        real'(MEASUREMENT_CYCLES),
                    real'(prefix_root_multi_active[mode][SAMPLE_POINTS]) /
                        real'(MEASUREMENT_CYCLES),
                    real'(prefix_root_all_active[mode][SAMPLE_POINTS]) /
                        real'(MEASUREMENT_CYCLES),
                    real'(prefix_x_local_active[mode][SAMPLE_POINTS]) /
                        real'(MEASUREMENT_CYCLES),
                    real'(prefix_y_local_active[mode][SAMPLE_POINTS]) /
                        real'(MEASUREMENT_CYCLES),
                    real'(prefix_z_local_active[mode][SAMPLE_POINTS]) /
                        real'(MEASUREMENT_CYCLES),
                    real'(prefix_f_source_backlog[mode][SAMPLE_POINTS]) /
                        real'(MEASUREMENT_CYCLES),
                    real'(prefix_x_source_backlog[mode][SAMPLE_POINTS]) /
                        real'(MEASUREMENT_CYCLES),
                    real'(prefix_y_source_backlog[mode][SAMPLE_POINTS]) /
                        real'(MEASUREMENT_CYCLES));
            $fclose(summary_file);

            for (source_id = 0; source_id < SOURCE_NUM;
                 source_id = source_id + 1)
                if (arrived_count[MODE_DISABLED][source_id] !=
                    arrived_count[MODE_ENABLED][source_id])
                    $fatal(1,
                        "arrival trace mismatch source=%0d disabled=%0d enabled=%0d",
                        source_id,
                        arrived_count[MODE_DISABLED][source_id],
                        arrived_count[MODE_ENABLED][source_id]);
            if ((mean_rate_bps[MODE_ENABLED] <
                 (TARGET_BPS * 97 / 100)) ||
                (mean_rate_bps[MODE_ENABLED] >
                 (TARGET_BPS * 103 / 100)))
                $fatal(1,
                    "enabled mean rate outside 3%% target mean=%0d target=%0d",
                    mean_rate_bps[MODE_ENABLED], TARGET_BPS);
            if (DISABLED_EXPECTED_MBPS == 0) begin
                if ((mean_rate_bps[MODE_DISABLED] <
                     (TARGET_BPS * 80 / 100)) ||
                    (mean_rate_bps[MODE_DISABLED] >
                     (TARGET_BPS * 120 / 100)))
                    $fatal(1,
                        "disabled mean not near target mean=%0d target=%0d",
                        mean_rate_bps[MODE_DISABLED], TARGET_BPS);
            end else begin
                if ((mean_rate_bps[MODE_DISABLED] <
                     (longint'(DISABLED_EXPECTED_MBPS) *
                      1000000 * 97 / 100)) ||
                    (mean_rate_bps[MODE_DISABLED] >
                     (longint'(DISABLED_EXPECTED_MBPS) *
                      1000000 * 103 / 100)))
                    $fatal(1,
                        "disabled mean outside expected range mean=%0d expected_mbps=%0d",
                        mean_rate_bps[MODE_DISABLED],
                        DISABLED_EXPECTED_MBPS);
            end
            if (mad_rate_mbps[MODE_DISABLED] <=
                (mad_rate_mbps[MODE_ENABLED] * 2))
                $fatal(1,
                    "disabled trace is not materially more variable enabled_mad=%0d disabled_mad=%0d",
                    mad_rate_mbps[MODE_ENABLED],
                    mad_rate_mbps[MODE_DISABLED]);
            if ((max_rate_bps[MODE_DISABLED] -
                 min_rate_bps[MODE_DISABLED]) <
                (TARGET_BPS / 4))
                $fatal(1,
                    "disabled rate range too small min=%0d max=%0d",
                    min_rate_bps[MODE_DISABLED],
                    max_rate_bps[MODE_DISABLED]);
            if (DISABLED_EXPECTED_MBPS == 0) begin
                if ((min_rate_bps[MODE_DISABLED] < TARGET_BPS / 3) ||
                    (max_rate_bps[MODE_DISABLED] > TARGET_BPS * 2))
                    $fatal(1,
                        "disabled rate variation is an extreme pulse min=%0d max=%0d",
                        min_rate_bps[MODE_DISABLED],
                        max_rate_bps[MODE_DISABLED]);
            end else begin
                if ((min_rate_bps[MODE_DISABLED] <
                     (longint'(DISABLED_EXPECTED_MBPS) * 1000000 / 3)) ||
                    (max_rate_bps[MODE_DISABLED] >
                     (longint'(DISABLED_EXPECTED_MBPS) * 1000000 * 2)))
                    $fatal(1,
                        "disabled rate variation is an extreme pulse min=%0d max=%0d expected_mbps=%0d",
                        min_rate_bps[MODE_DISABLED],
                        max_rate_bps[MODE_DISABLED],
                        DISABLED_EXPECTED_MBPS);
            end
            if ((prefix_f_served[MODE_DISABLED][SAMPLE_POINTS] == 0) ||
                (prefix_x_served[MODE_DISABLED][SAMPLE_POINTS] == 0) ||
                (prefix_y_served[MODE_DISABLED][SAMPLE_POINTS] == 0) ||
                (prefix_f_served[MODE_ENABLED][SAMPLE_POINTS] == 0) ||
                (prefix_x_served[MODE_ENABLED][SAMPLE_POINTS] == 0) ||
                (prefix_y_served[MODE_ENABLED][SAMPLE_POINTS] == 0))
                $fatal(1, "not every Root subtree received service");
            if (prefix_root_multi_active[MODE_ENABLED][SAMPLE_POINTS] <
                longint'(MEASUREMENT_CYCLES) / 30)
                $fatal(1,
                    "insufficient enabled multi-subtree Root competition cycles=%0d/%0d",
                    prefix_root_multi_active[MODE_ENABLED][SAMPLE_POINTS],
                    MEASUREMENT_CYCLES);

            $display("HIERARCHICAL_SUSTAINED_AB_RESULT,target_bps=%0d,y_share_offset_percent=%0d,disabled_expected_mbps=%0d,slot_cycles=%0d,window_cycles=%0d,windows=%0d",
                TARGET_BPS, Y_SHARE_OFFSET_PERCENT,
                DISABLED_EXPECTED_MBPS, TRACE_SLOT_CYCLES,
                WINDOW_CYCLES,
                WINDOW_COUNT);
            $display("HIERARCHICAL_SUSTAINED_AB_DISABLED,mean_bps=%0d,min_bps=%0d,max_bps=%0d,mad_mbps=%0d,y_packets=%0d,y_bytes=%0d,multi_active=%0.4f,all_active=%0.4f",
                mean_rate_bps[MODE_DISABLED],
                min_rate_bps[MODE_DISABLED],
                max_rate_bps[MODE_DISABLED],
                mad_rate_mbps[MODE_DISABLED],
                prefix_y_outputs[MODE_DISABLED][SAMPLE_POINTS],
                prefix_y_bytes[MODE_DISABLED][SAMPLE_POINTS],
                real'(prefix_root_multi_active[MODE_DISABLED][SAMPLE_POINTS]) /
                    real'(MEASUREMENT_CYCLES),
                real'(prefix_root_all_active[MODE_DISABLED][SAMPLE_POINTS]) /
                    real'(MEASUREMENT_CYCLES));
            $display("HIERARCHICAL_SUSTAINED_AB_ENABLED,mean_bps=%0d,min_bps=%0d,max_bps=%0d,mad_mbps=%0d,y_packets=%0d,y_bytes=%0d,multi_active=%0.4f,all_active=%0.4f,deferred=%0d,max_delay=%0d",
                mean_rate_bps[MODE_ENABLED],
                min_rate_bps[MODE_ENABLED],
                max_rate_bps[MODE_ENABLED],
                mad_rate_mbps[MODE_ENABLED],
                prefix_y_outputs[MODE_ENABLED][SAMPLE_POINTS],
                prefix_y_bytes[MODE_ENABLED][SAMPLE_POINTS],
                real'(prefix_root_multi_active[MODE_ENABLED][SAMPLE_POINTS]) /
                    real'(MEASUREMENT_CYCLES),
                real'(prefix_root_all_active[MODE_ENABLED][SAMPLE_POINTS]) /
                    real'(MEASUREMENT_CYCLES),
                case_deferred_cycles[MODE_ENABLED],
                case_max_release_delay[MODE_ENABLED]);
            $display("PASS: multi-node multi-flow hierarchical sustained Y shaping A/B");
        end
    endtask

    initial begin
        if ((TARGET_SERVICE_TIME < 3) ||
            (SAMPLE_POINTS < WINDOW_STEPS) ||
            (MEASUREMENT_SERVICE_INTERVALS > 4000) ||
            (Y_SHARE_OFFSET_PERCENT < -16) ||
            (Y_SHARE_OFFSET_PERCENT > 75))
            $fatal(1, "invalid hierarchical sustained A/B parameters");

        clk = 1'b0;
        arst_n = 1'b0;
        wall_time = {TIME_WIDTH{1'b0}};
        token_cfg_valid = 1'b0;
        token_cfg_state_valid = 1'b1;
        token_cfg_capacity = BURST_CAPACITY_TIME[TIME_WIDTH-1:0];
        token_cfg_credit = BURST_CAPACITY_TIME[TIME_WIDTH-1:0];
        token_cfg_state_time = {TIME_WIDTH{1'b0}};
        d_valid = 1'b0;
        d_target = NODE_Y;
        d_service_time = TARGET_SERVICE_TIME[TIME_WIDTH-1:0];
        d_data = {DATA_WIDTH{1'b0}};
        direct_valid = 1'b0;
        direct_target = NODE_ROOT;
        direct_data = {DATA_WIDTH{1'b0}};
        pop_valid = 1'b0;
        case_mode = MODE_DISABLED;
        case_running = 1'b0;
        trace_enable = 1'b0;
        driver_enable = 1'b0;
        pop_enable = 1'b0;
        measurement_active = 1'b0;
        trace_done = 1'b0;
        direct_done = 1'b0;
        shaped_done = 1'b0;
        pop_done = 1'b0;
        case_epoch = 0;
        measurement_cycle_count = 0;
        for (init_source = 0; init_source < LOGICAL_TREE_NUM;
             init_source = init_source + 1) begin
            d_rank[init_source] = {PTW{1'b0}};
            direct_rank[init_source] = {PTW{1'b0}};
        end
        for (init_mode = 0; init_mode < 2;
             init_mode = init_mode + 1)
            initialize_case_state(init_mode);

        run_case(MODE_DISABLED);
        run_case(MODE_ENABLED);
        write_results_and_check();
        $finish;
    end
endmodule
