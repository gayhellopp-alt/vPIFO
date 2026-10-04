`timescale 1ns / 10ps

module ThreeTierTokenBucketRateSweep_tb #(
    parameter integer SPLIT_SHAPING = 0,
    parameter integer SHAPED_TARGET_NODE = 1,
    parameter integer INGRESS_TARGET_NODE = 1,
    parameter integer STREAM_OUTPUT = 0,
    parameter integer RUN_CATCHUP = 1,
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
    localparam CLOCK_MHZ = 125;
    localparam CLOCK_HZ = 125000000;
    localparam PACKET_BYTES = 1500;
    localparam PACKET_BITS = PACKET_BYTES * 8;
    localparam RATE_CASES = 7;
    localparam PACKETS_PER_RATE = 12;
    localparam CATCHUP_PACKETS = 4;
    localparam LOG_DEPTH = RATE_CASES * PACKETS_PER_RATE +
                           CATCHUP_PACKETS;
    localparam [1:0] NODE_ROOT = 2'd0;
    localparam [1:0] NODE_X = 2'd1;
    localparam [1:0] SHAPED_NODE = SHAPED_TARGET_NODE[1:0];
    localparam [1:0] INGRESS_NODE = INGRESS_TARGET_NODE[1:0];
    localparam EXPECTED_TX_COUNT = RATE_CASES * PACKETS_PER_RATE +
        ((RUN_CATCHUP != 0) ? CATCHUP_PACKETS : 0);
    localparam [14:0] BLOCKER_PACKET_ID = 15'd30000;

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
    wire direct_fire;

    reg pop_valid;
    wire pop_ready;
    wire packet_out_valid;
    wire [1:0] packet_out_node;
    wire [DATA_WIDTH-1:0] packet_out_data;

    wire shaping_fire;
    wire shaping_pending;
    wire [TIME_WIDTH-1:0] shaping_release_time;
    wire shaping_deferred;
    wire deferred_by_direct;
    wire deferred_by_pop;
    wire deferred_by_backpressure;
    wire [31:0] shaping_deferred_cycles;
    wire [TIME_WIDTH-1:0] release_delay_last;
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

    integer tx_total;
    integer release_total;
    integer output_total;
    integer shaped_output_total;
    integer direct_total;
    integer init_node;
    integer rate_index;
    integer watchdog;
    reg [TIME_WIDTH-1:0] eligibility_log [0:LOG_DEPTH-1];
    reg [TIME_WIDTH-1:0] actual_release_log [0:LOG_DEPTH-1];
    reg [TIME_WIDTH-1:0] packet_output_log [0:LOG_DEPTH-1];

    // A full period is 8 ns, so one wall-time tick is one 125 MHz cycle.
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
        .SCHEDULE_PENDING_DEPTH(SCHEDULE_PENDING_DEPTH),
        .SCHEDULE_POP_TRACK_DEPTH(SCHEDULE_POP_TRACK_DEPTH),
        .TIMING_EVENT_TABLE_DEPTH(32),
        .TIMING_RELEASE_FIFO_DEPTH(16),
        .SPLIT_SHAPING(SPLIT_SHAPING),
        .SHAPED_TARGET_NODE(SHAPED_TARGET_NODE)
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
        .i_d_target_node_id(INGRESS_NODE),
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
        .o_deferred_by_schedule_backpressure(
            deferred_by_backpressure),
        .o_shaping_deferred_cycles(shaping_deferred_cycles),
        .o_release_delay_last(release_delay_last),
        .o_release_delay_max(release_delay_max),
        .o_timing_event_table_count(timing_event_count),
        .o_timing_release_fifo_count(timing_release_count),
        .o_schedule_logical_count(schedule_logical_count),
        .o_schedule_pending_count(schedule_pending_count),
        .o_schedule_outstanding_pop_count(
            schedule_outstanding_count),
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
            tx_total <= 0;
            release_total <= 0;
            output_total <= 0;
            shaped_output_total <= 0;
            direct_total <= 0;
        end else begin
            if (d_transaction_fire) begin
                if (tx_total >= LOG_DEPTH)
                    $fatal(1, "eligibility log overflow");
                eligibility_log[tx_total] <= d_eligibility_time;
                tx_total <= tx_total + 1;
            end
            if (shaping_fire) begin
                if (release_total >= LOG_DEPTH)
                    $fatal(1, "release log overflow");
                if (wall_time < shaping_release_time)
                    $fatal(1,
                        "D admitted early: now=%0d eligibility=%0d",
                        wall_time, shaping_release_time);
                actual_release_log[release_total] <= wall_time;
                release_total <= release_total + 1;
            end
            if (direct_fire)
                direct_total <= direct_total + 1;
            if (packet_out_valid) begin
                output_total <= output_total + 1;
                if (packet_out_node == SHAPED_NODE) begin
                    if (shaped_output_total >= LOG_DEPTH)
                        $fatal(1, "packet-output log overflow");
                    packet_output_log[shaped_output_total] <= wall_time;
                    shaped_output_total <= shaped_output_total + 1;
                end
            end
        end
    end

    function automatic integer target_mbps;
        input integer index;
        begin
            case (index)
                0: target_mbps = 100;
                1: target_mbps = 200;
                2: target_mbps = 500;
                3: target_mbps = 1000;
                4: target_mbps = 2000;
                5: target_mbps = 5000;
                default: target_mbps = 10000;
            endcase
        end
    endfunction

    task automatic configure_empty_pacer;
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

    task automatic send_d;
        input [14:0] packet_id;
        integer rank_node;
        begin
            for (rank_node = 0; rank_node < LOGICAL_TREE_NUM;
                 rank_node = rank_node + 1)
                d_rank[rank_node] = 16'hffff;
            d_rank[0] = {1'b0, packet_id};
            d_rank[INGRESS_NODE] = {1'b0, packet_id};
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
            while (!packet_out_valid && (watchdog < 100000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (!packet_out_valid)
                $fatal(1, "timeout waiting for packet output");
            if ((packet_out_node !== expected_node) ||
                (packet_out_data[30:16] !== expected_packet_id))
                $fatal(1,
                    "packet mismatch node=%0d/%0d id=%0d/%0d",
                    packet_out_node, expected_node,
                    packet_out_data[30:16], expected_packet_id);
        end
    endtask

    task automatic wait_for_release_total;
        input integer expected_total;
        begin
            watchdog = 0;
            while ((release_total < expected_total) &&
                   (watchdog < 2000000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (release_total != expected_total)
                $fatal(1,
                    "release timeout expected=%0d actual=%0d",
                    expected_total, release_total);
        end
    endtask

    task automatic wait_for_domains_idle;
        begin
            watchdog = 0;
            while ((timing_event_count != 0 ||
                    timing_release_count != 0 || timing_busy ||
                    schedule_pending_count != 0 ||
                    schedule_outstanding_count != 0 || schedule_busy) &&
                   (watchdog < 200000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (watchdog == 200000)
                $fatal(1, "timeout waiting for both domains to idle");
        end
    endtask

    task automatic run_rate_case;
        input integer index;
        integer mbps;
        integer service_cycles;
        integer tx_base;
        integer release_base;
        integer output_base;
        integer packet_index;
        integer log_index;
        integer eligibility_gap;
        integer actual_gap;
        integer min_eligibility_gap;
        integer max_eligibility_gap;
        integer min_actual_gap;
        integer max_actual_gap;
        integer max_admission_delay;
        longint eligibility_duration;
        longint actual_duration;
        longint rate_numerator;
        longint eligibility_rate_bps;
        longint actual_rate_bps;
        longint packet_output_duration;
        longint packet_output_rate_bps;
        longint packet_output_rate_error;
        integer packet_output_gap;
        integer min_packet_output_gap;
        integer max_packet_output_gap;
        integer first_packet_id;
        begin
            mbps = target_mbps(index);
            service_cycles =
                (PACKET_BITS * CLOCK_MHZ + mbps - 1) / mbps;
            d_service_time = service_cycles;
            configure_empty_pacer();

            tx_base = tx_total;
            release_base = release_total;
            output_base = shaped_output_total;
            first_packet_id = index * PACKETS_PER_RATE + 1;
            for (packet_index = 0;
                 packet_index < PACKETS_PER_RATE;
                 packet_index = packet_index + 1)
                send_d(15'(first_packet_id + packet_index));

            if (tx_total != tx_base + PACKETS_PER_RATE)
                $fatal(1, "not all D transactions were accepted");

            if (SPLIT_SHAPING != 0) begin
                watchdog = 0;
                while ((schedule_logical_count[SHAPED_NODE] !=
                        PACKETS_PER_RATE) &&
                       (release_total == release_base) &&
                       (watchdog < 100000)) begin
                    @(negedge clk);
                    watchdog = watchdog + 1;
                end
                if (release_total != release_base)
                    $fatal(1,
                        "Y became eligible before LOCAL visibility check");
                if ((schedule_logical_count[SHAPED_NODE] !=
                     PACKETS_PER_RATE) ||
                    (schedule_logical_count[NODE_ROOT] != 0))
                    $fatal(1,
                        "wrong pre-release split state rate=%0d Root=%0d Y=%0d",
                        mbps, schedule_logical_count[NODE_ROOT],
                        schedule_logical_count[SHAPED_NODE]);
            end

            if (STREAM_OUTPUT != 0) begin
                for (packet_index = 0;
                     packet_index < PACKETS_PER_RATE;
                     packet_index = packet_index + 1) begin
                    wait_for_release_total(release_base + packet_index + 1);
                    pop_and_expect(
                        SHAPED_NODE,
                        15'(first_packet_id + packet_index));
                end
                // packet_out_valid is produced on a clock edge; allow the
                // monitor one following edge to record the final packet.
                @(posedge clk);
                @(negedge clk);
                wait_for_domains_idle();
            end else begin
                wait_for_release_total(release_base + PACKETS_PER_RATE);
                wait_for_domains_idle();
            end

            min_eligibility_gap = 32'h7fffffff;
            max_eligibility_gap = 0;
            min_actual_gap = 32'h7fffffff;
            max_actual_gap = 0;
            max_admission_delay = 0;
            for (log_index = 0;
                 log_index < PACKETS_PER_RATE;
                 log_index = log_index + 1) begin
                if (actual_release_log[release_base + log_index] <
                    eligibility_log[tx_base + log_index])
                    $fatal(1, "actual admission preceded eligibility");
                if ((actual_release_log[release_base + log_index] -
                     eligibility_log[tx_base + log_index]) >
                    max_admission_delay)
                    max_admission_delay =
                        actual_release_log[release_base + log_index] -
                        eligibility_log[tx_base + log_index];
                if (log_index != 0) begin
                    eligibility_gap =
                        eligibility_log[tx_base + log_index] -
                        eligibility_log[tx_base + log_index - 1];
                    actual_gap =
                        actual_release_log[release_base + log_index] -
                        actual_release_log[release_base + log_index - 1];
                    if (eligibility_gap != service_cycles)
                        $fatal(1,
                            "wrong eligibility gap rate=%0d gap=%0d/%0d",
                            mbps, eligibility_gap, service_cycles);
                    if (actual_gap < service_cycles)
                        $fatal(1,
                            "uncontended admission exceeded rate=%0d gap=%0d/%0d",
                            mbps, actual_gap, service_cycles);
                    if (eligibility_gap < min_eligibility_gap)
                        min_eligibility_gap = eligibility_gap;
                    if (eligibility_gap > max_eligibility_gap)
                        max_eligibility_gap = eligibility_gap;
                    if (actual_gap < min_actual_gap)
                        min_actual_gap = actual_gap;
                    if (actual_gap > max_actual_gap)
                        max_actual_gap = actual_gap;
                end
            end

            eligibility_duration =
                eligibility_log[tx_base + PACKETS_PER_RATE - 1] -
                eligibility_log[tx_base];
            actual_duration =
                actual_release_log[release_base + PACKETS_PER_RATE - 1] -
                actual_release_log[release_base];
            rate_numerator = PACKETS_PER_RATE - 1;
            rate_numerator = rate_numerator * PACKET_BITS * CLOCK_HZ;
            eligibility_rate_bps = rate_numerator /
                eligibility_duration;
            actual_rate_bps = rate_numerator / actual_duration;

            packet_output_rate_bps = 0;
            min_packet_output_gap = 32'h7fffffff;
            max_packet_output_gap = 0;
            if (STREAM_OUTPUT != 0) begin
                if (shaped_output_total != output_base + PACKETS_PER_RATE)
                    $fatal(1,
                        "not all shaped packets reached packet-out");
                for (log_index = 0;
                     log_index < PACKETS_PER_RATE;
                     log_index = log_index + 1) begin
                    if (packet_output_log[output_base + log_index] <
                        actual_release_log[release_base + log_index])
                        $fatal(1, "packet output preceded Root admission");
                    if (log_index != 0) begin
                        packet_output_gap =
                            packet_output_log[output_base + log_index] -
                            packet_output_log[output_base + log_index - 1];
                        if (packet_output_gap < min_packet_output_gap)
                            min_packet_output_gap = packet_output_gap;
                        if (packet_output_gap > max_packet_output_gap)
                            max_packet_output_gap = packet_output_gap;
                    end
                end
                packet_output_duration =
                    packet_output_log[output_base + PACKETS_PER_RATE - 1] -
                    packet_output_log[output_base];
                packet_output_rate_bps = rate_numerator /
                    packet_output_duration;
                packet_output_rate_error =
                    (packet_output_rate_bps > eligibility_rate_bps) ?
                    packet_output_rate_bps - eligibility_rate_bps :
                    eligibility_rate_bps - packet_output_rate_bps;
                if ((packet_output_rate_error * 100) >
                    (eligibility_rate_bps * 2))
                    $fatal(1,
                        "Y packet-output rate differs by more than 2 percent target=%0d output=%0d",
                        eligibility_rate_bps, packet_output_rate_bps);
            end else begin
                if ((schedule_logical_count[NODE_ROOT] !=
                     PACKETS_PER_RATE) ||
                    (schedule_logical_count[SHAPED_NODE] !=
                     PACKETS_PER_RATE))
                    $fatal(1,
                        "wrong schedule counts after rate %0d: root=%0d node=%0d",
                        mbps, schedule_logical_count[NODE_ROOT],
                        schedule_logical_count[SHAPED_NODE]);

                for (packet_index = 0;
                     packet_index < PACKETS_PER_RATE;
                     packet_index = packet_index + 1)
                    pop_and_expect(
                        SHAPED_NODE,
                        15'(first_packet_id + packet_index));
                wait_for_domains_idle();
            end
            if ((schedule_logical_count[NODE_ROOT] != 0) ||
                (schedule_logical_count[SHAPED_NODE] != 0))
                $fatal(1, "schedule tree did not drain after rate case");

            $display("RATE_RESULT,target_mbps=%0d,service_cycles=%0d,eligibility_gap_min=%0d,eligibility_gap_max=%0d,actual_gap_min=%0d,actual_gap_max=%0d,packet_output_gap_min=%0d,packet_output_gap_max=%0d,eligibility_bps=%0d,actual_bps=%0d,packet_output_bps=%0d,max_admission_delay=%0d",
                mbps, service_cycles,
                min_eligibility_gap, max_eligibility_gap,
                min_actual_gap, max_actual_gap,
                min_packet_output_gap, max_packet_output_gap,
                eligibility_rate_bps, actual_rate_bps,
                packet_output_rate_bps,
                max_admission_delay);
        end
    endtask

    task automatic run_catchup_case;
        integer service_cycles;
        integer tx_base;
        integer release_base;
        integer direct_base;
        integer accepted_blockers;
        integer packet_index;
        integer log_index;
        integer actual_gap;
        integer min_actual_gap;
        integer max_actual_gap;
        longint actual_duration;
        longint rate_numerator;
        longint actual_rate_bps;
        integer first_packet_id;
        begin
            service_cycles = 150;
            d_service_time = service_cycles;
            configure_empty_pacer();
            tx_base = tx_total;
            release_base = release_total;
            first_packet_id = RATE_CASES * PACKETS_PER_RATE + 1;
            for (packet_index = 0;
                 packet_index < CATCHUP_PACKETS;
                 packet_index = packet_index + 1)
                send_d(15'(first_packet_id + packet_index));

            // Continuous direct scheduling work has priority over shaping.
            direct_target = NODE_ROOT;
            direct_rank[0] = 16'hf000;
            direct_rank[1] = 16'hffff;
            direct_rank[2] = 16'hffff;
            direct_rank[3] = 16'hffff;
            direct_data = {1'b0, BLOCKER_PACKET_ID, 16'b0};
            direct_base = direct_total;
            direct_valid = 1'b1;
            watchdog = 0;
            while ((timing_release_count < CATCHUP_PACKETS) &&
                   (watchdog < 200000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (timing_release_count < CATCHUP_PACKETS)
                $fatal(1, "timeout accumulating catch-up releases");
            if (release_total != release_base)
                $fatal(1, "shaping release bypassed direct priority");
            @(negedge clk);
            direct_valid = 1'b0;
            accepted_blockers = direct_total - direct_base;
            if (accepted_blockers == 0)
                $fatal(1, "catch-up blocker generated no direct work");

            wait_for_release_total(release_base + CATCHUP_PACKETS);
            wait_for_domains_idle();
            min_actual_gap = 32'h7fffffff;
            max_actual_gap = 0;
            for (log_index = 0;
                 log_index < CATCHUP_PACKETS;
                 log_index = log_index + 1) begin
                if (actual_release_log[release_base + log_index] <
                    eligibility_log[tx_base + log_index])
                    $fatal(1, "catch-up release preceded eligibility");
                if (log_index != 0) begin
                    actual_gap =
                        actual_release_log[release_base + log_index] -
                        actual_release_log[release_base + log_index - 1];
                    if (actual_gap < min_actual_gap)
                        min_actual_gap = actual_gap;
                    if (actual_gap > max_actual_gap)
                        max_actual_gap = actual_gap;
                end
            end
            if (min_actual_gap >= service_cycles)
                $fatal(1,
                    "catch-up burst was not observed gap=%0d service=%0d",
                    min_actual_gap, service_cycles);
            actual_duration =
                actual_release_log[release_base + CATCHUP_PACKETS - 1] -
                actual_release_log[release_base];
            rate_numerator = CATCHUP_PACKETS - 1;
            rate_numerator = rate_numerator * PACKET_BITS * CLOCK_HZ;
            actual_rate_bps = rate_numerator / actual_duration;

            for (packet_index = 0;
                 packet_index < CATCHUP_PACKETS;
                 packet_index = packet_index + 1)
                pop_and_expect(
                    SHAPED_NODE, 15'(first_packet_id + packet_index));
            for (packet_index = 0;
                 packet_index < accepted_blockers;
                 packet_index = packet_index + 1)
                pop_and_expect(NODE_ROOT, BLOCKER_PACKET_ID);
            wait_for_domains_idle();

            $display("CATCHUP_RESULT,target_mbps=10000,service_cycles=%0d,queued_releases=%0d,direct_blockers=%0d,actual_gap_min=%0d,actual_gap_max=%0d,catchup_bps=%0d,deferred_cycles=%0d",
                service_cycles, CATCHUP_PACKETS, accepted_blockers,
                min_actual_gap, max_actual_gap, actual_rate_bps,
                shaping_deferred_cycles);
        end
    endtask

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        wall_time = 0;
        token_cfg_valid = 1'b0;
        token_cfg_state_valid = 1'b1;
        token_cfg_capacity = 0;
        token_cfg_credit = 0;
        token_cfg_state_time = 0;
        d_valid = 1'b0;
        d_service_time = 0;
        d_data = 0;
        direct_valid = 1'b0;
        direct_target = NODE_ROOT;
        direct_data = 0;
        pop_valid = 1'b0;
        for (init_node = 0; init_node < LOGICAL_TREE_NUM;
             init_node = init_node + 1) begin
            d_rank[init_node] = 16'hffff;
            direct_rank[init_node] = 16'hffff;
        end

        repeat (8) @(negedge clk);
        arst_n = 1'b1;
        repeat (4) @(negedge clk);

        for (rate_index = 0; rate_index < RATE_CASES;
             rate_index = rate_index + 1)
            run_rate_case(rate_index);
        if (RUN_CATCHUP != 0)
            run_catchup_case();

        if (protocol_error)
            $fatal(1, "protocol error after Token Bucket rate sweep");
        if ((timing_event_count != 0) ||
            (timing_release_count != 0) ||
            (schedule_pending_count != 0) ||
            (schedule_outstanding_count != 0) ||
            (schedule_logical_count[0] != 0) ||
            (schedule_logical_count[1] != 0) ||
            (schedule_logical_count[2] != 0) ||
            (schedule_logical_count[3] != 0))
            $fatal(1, "nonzero final occupancy after rate sweep");
        if ((tx_total != EXPECTED_TX_COUNT) ||
            (release_total != EXPECTED_TX_COUNT) ||
            (shaped_output_total != EXPECTED_TX_COUNT))
            $fatal(1,
                "exactly-once mismatch tx=%0d release=%0d output=%0d expected=%0d",
                tx_total, release_total, shaped_output_total,
                EXPECTED_TX_COUNT);

        if (SPLIT_SHAPING != 0)
            $display("PASS: Y split 1500B Token Bucket seven-rate packet-output sweep");
        else
            $display("PASS: 1500B Token Bucket seven-rate sweep and catch-up characterization");
        $finish;
    end

endmodule
