`timescale 1ns / 1ps

// Simulation-only cycle accounting for the heterogeneous front end.
// This testbench deliberately keeps all counters outside synthesizable RTL.
module HeterogeneousPIFO_perf_tb #(
    parameter LOGICAL_PENDING_DEPTH = 12,
    parameter PTW = 16,
    parameter MTW = 16
);
    localparam DATA_WIDTH = PTW + MTW;
    localparam LOGICAL_TREE_NUM = 4;
    localparam PHYSICAL_TREE_NUM = 7;
    localparam LEVEL = 4;
    localparam REQUEST_PORTS = 4;
    localparam TASK_ORDER_WIDTH = 32;
    localparam integer BASELINE_SHARD_COUNTS [0:LOGICAL_TREE_NUM-1] =
        '{4, 1, 1, 1};
    localparam integer BASELINE_SHARD_OFFSETS [0:LOGICAL_TREE_NUM-1] =
        '{0, 4, 5, 6};
    localparam PENDING_COUNT_WIDTH =
        $clog2(LOGICAL_PENDING_DEPTH + 1);

    reg clk;
    reg arst_n;
    reg [REQUEST_PORTS-1:0] req_valid;
    reg [REQUEST_PORTS-1:0] req_push;
    reg [1:0] logical_tree_id [0:REQUEST_PORTS-1];
    reg [DATA_WIDTH-1:0] push_data [0:REQUEST_PORTS-1];
    reg [TASK_ORDER_WIDTH-1:0] req_order [0:REQUEST_PORTS-1];
    reg [REQUEST_PORTS-1:0]
        req_merge_mask [0:REQUEST_PORTS-1];

    wire [REQUEST_PORTS-1:0] req_capture_ready;
    wire [REQUEST_PORTS-1:0] req_capture_fire;
    wire [LOGICAL_TREE_NUM-1:0] dispatch_fire;
    wire [LOGICAL_TREE_NUM-1:0] dispatch_push;
    wire [2:0]
        selected_physical_tree_id [0:LOGICAL_TREE_NUM-1];
    wire [PENDING_COUNT_WIDTH-1:0]
        logical_pending_count [0:LOGICAL_TREE_NUM-1];
    wire [PENDING_COUNT_WIDTH-1:0] pending_count;
    wire [PENDING_COUNT_WIDTH-1:0]
        pending_effective_free_count;
    wire busy;
    wire pop_valid;
    wire [1:0] pop_logical_tree_id;
    wire [DATA_WIDTH-1:0] pop_data;
    wire protocol_error;
    wire [LEVEL-1:0] task_fifo_full;
    wire [LEVEL-1:0] task_write;
    wire [LEVEL-1:0] task_push;
    wire [LEVEL-1:0] task_pop;
    wire [7:0] logical_count [0:LOGICAL_TREE_NUM-1];
    wire [1:0] push_rr_ptr [0:LOGICAL_TREE_NUM-1];
    wire [4:0] shard_count [0:PHYSICAL_TREE_NUM-1];
    wire [PTW-1:0]
        shard_head_rank [0:PHYSICAL_TREE_NUM-1];
    wire shard_empty [0:PHYSICAL_TREE_NUM-1];
    wire shard_full [0:PHYSICAL_TREE_NUM-1];
    wire update_pending [0:PHYSICAL_TREE_NUM-1];
    wire logical_busy [0:LOGICAL_TREE_NUM-1];
    wire [1:0]
        pending_logical_tree_id [0:PHYSICAL_TREE_NUM-1];
    wire pending_push [0:PHYSICAL_TREE_NUM-1];
    wire [PHYSICAL_TREE_NUM-1:0] update_pending_vector;

    integer failures;
    integer global_cycle;
    integer phase_id;
    reg phase_active;
    integer phase_cycles;
    integer phase_transactions;
    integer phase_primitives;
    integer phase_completions;
    integer phase_retired_primitives;
    integer phase_taskfifo_words;
    integer phase_pp_transactions;
    integer phase_oneword_pp;
    integer phase_fallback_pp;
    integer phase_pp_completed;
    integer phase_pp_push_completions;
    integer phase_pp_pop_completions;
    integer phase_busy_blocked_cycles;
    integer phase_boundary_unfilled_cycles;
    integer phase_datapath_idle_cycles;
    integer phase_datapath_idle_with_pending_cycles;
    integer phase_empty_engine_with_pending_cycles;
    integer phase_boundary_datapath_idle_cycles;
    integer phase_other_logical_dispatches;
    integer phase_oneword_latency_sum;
    integer phase_oneword_latency_count;
    integer phase_fallback_latency_sum;
    integer phase_fallback_latency_count;
    integer phase_pp_physical_switches;
    integer phase_last_pp_physical;
    integer phase_dispatch_events;
    integer phase_multi_lane_cycles;
    integer phase_capture_backpressure_cycles;
    integer phase_candidate_stall_logical_cycles;
    integer phase_partner_resolution_logical_cycles;
    integer phase_partner_resolution_active_cycles;
    integer phase_max_parallel_partner_resolutions;
    integer phase_max_parallel_primary_candidates;
    integer phase_resolution_ready_overlap_cycles;
    integer phase_committed_primitives;
    integer phase_plan_fill_cycles;
    integer phase_plan_commit_cycles;
    integer phase_plan_stall_cycles;
    integer phase_reservation_stall_cycles;
    integer phase_allocation_unavailable_cycles;
    integer phase_retire_commit_conflict_cycles;
    integer phase_stage_a_b_overlap_cycles;
    integer phase_candidate_commit_overlap_cycles;
    integer phase_partner_commit_overlap_cycles;
    // Mutually exclusive cycle attribution.  Every active phase cycle is
    // assigned to exactly one bucket, in the priority order used by the
    // monitor below.  This avoids interpreting overlapping activity counters
    // as independent causes of the same bubble.
    integer phase_class_dispatch_cycles;
    integer phase_class_completion_cycles;
    integer phase_class_busy_successor_cycles;
    integer phase_class_completion_drain_cycles;
    integer phase_class_partner_resolution_cycles;
    integer phase_class_candidate_not_ready_cycles;
    integer phase_class_directory_shard_cycles;
    integer phase_class_taskfifo_rpu_cycles;
    integer phase_class_lane_arbitration_cycles;
    integer phase_class_allocation_reservation_cycles;
    integer phase_class_other_cycles;
    integer phase_successor_prepared_events;
    integer phase_successor_ready_busy_logical_cycles;
    integer baseline_oneword_latency_x1000;

    reg pp_active [0:LOGICAL_TREE_NUM-1];
    reg pp_fallback [0:LOGICAL_TREE_NUM-1];
    reg pp_push_seen [0:LOGICAL_TREE_NUM-1];
    integer pp_first_dispatch_cycle [0:LOGICAL_TREE_NUM-1];
    reg unlock_waiting [0:LOGICAL_TREE_NUM-1];
    integer unlock_cycle [0:LOGICAL_TREE_NUM-1];
    reg successor_ready_while_busy_seen [0:LOGICAL_TREE_NUM-1];

    integer i;
    integer j;
    integer lane;
    integer logical_id;
    integer physical_id;
    integer pair_count;
    integer capture_count;
    integer word_count;
    integer resolving_count;
    integer primary_candidate_count;
    integer ready_candidate_count;
    integer plan_lane_count;
    integer pending_valid_count;
    integer pending_reserved_count;
    integer setup_index;
    integer workload_index;
    integer rank_value;
    integer tag_value;
    integer order_value;
    integer watchdog;
    reg saw_blocked;
    reg saw_other_busy;
    reg saw_busy_logical;
    reg saw_busy_ready_successor;
    reg saw_nonbusy_ready_candidate;
    reg saw_directory_selection;
    reg saw_selected_fifo_full;
    reg saw_lane_arbitration_loss;
    reg [DATA_WIDTH-1:0] last_pop_data;
    reg [1:0] last_pop_logical;
    integer pop_result_count;

    wire engine_datapath_active =
        (|dut.engine.push_up) || (|dut.engine.pop_up);
    wire engine_has_queued_or_inflight_work =
        !( &dut.engine.TaskFIFO_empty) ||
        (|dut.engine.rpu_push) || (|dut.engine.rpu_pop) ||
        (|update_pending_vector) || (|task_write) ||
        (|dut.engine_root_update_valid);

    genvar pending_vector_index;
    generate
        for (pending_vector_index = 0;
             pending_vector_index < PHYSICAL_TREE_NUM;
             pending_vector_index = pending_vector_index + 1) begin :
             pending_vector_wiring
            assign update_pending_vector[pending_vector_index] =
                update_pending[pending_vector_index];
        end
    endgenerate

    HeterogeneousPIFO #(
        .PTW(PTW),
        .MTW(MTW),
        .LEVEL(LEVEL),
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(PHYSICAL_TREE_NUM),
        .SHARD_CAPACITY(30),
        .MAX_SHARDS_PER_LOGICAL(4),
        .REQUEST_PORTS(REQUEST_PORTS),
        .TASK_ORDER_WIDTH(TASK_ORDER_WIDTH),
        .LOGICAL_PENDING_DEPTH(LOGICAL_PENDING_DEPTH),
        .SHARD_COUNTS(BASELINE_SHARD_COUNTS),
        .SHARD_OFFSETS(BASELINE_SHARD_OFFSETS)
    ) dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_req_valid(req_valid),
        .i_req_push(req_push),
        .i_req_pop(~req_push),
        .i_logical_tree_id(logical_tree_id),
        .i_push_data(push_data),
        .i_req_order(req_order),
        .i_req_merge_mask(req_merge_mask),
        .o_req_capture_ready(req_capture_ready),
        .o_req_capture_fire(req_capture_fire),
        .o_req_capture_bad_id(),
        .o_dispatch_fire(dispatch_fire),
        .o_dispatch_push(dispatch_push),
        .o_dispatch_logical_tree_id(),
        .o_selected_physical_tree_id(
            selected_physical_tree_id),
        .o_dispatch_data(),
        .o_dispatch_source_port(),
        .o_dispatch_reject_empty(),
        .o_dispatch_reject_full(),
        .o_logical_pending_count(logical_pending_count),
        .o_pending_count(pending_count),
        .o_pending_effective_free_count(
            pending_effective_free_count),
        .o_busy(busy),
        .o_pop_valid(pop_valid),
        .o_pop_logical_tree_id(pop_logical_tree_id),
        .o_pop_data(pop_data),
        .o_internal_root_pop_valid(),
        .o_internal_root_pop_data(),
        .o_protocol_error(protocol_error),
        .o_task_fifo_full(task_fifo_full),
        .o_task_write(task_write),
        .o_task_push(task_push),
        .o_task_pop(task_pop),
        .o_shard_list(),
        .o_logical_shard_count(),
        .o_logical_count(logical_count),
        .o_push_rr_ptr(push_rr_ptr),
        .o_shard_count(shard_count),
        .o_shard_head_rank(shard_head_rank),
        .o_shard_empty(shard_empty),
        .o_shard_full(shard_full),
        .o_shard_head_valid(),
        .o_update_pending(update_pending),
        .o_logical_busy(logical_busy),
        .o_pending_logical_tree_id(
            pending_logical_tree_id),
        .o_pending_push(pending_push)
    );

    always #5 clk = ~clk;

    task check;
        input condition;
        input [8*160-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s at time %0t",
                         message, $time);
                failures = failures + 1;
            end
        end
    endtask

    task clear_requests;
        integer port;
        begin
            req_valid = 0;
            req_push = 0;
            for (port = 0; port < REQUEST_PORTS;
                 port = port + 1) begin
                logical_tree_id[port] = 0;
                push_data[port] = {DATA_WIDTH{1'b1}};
                req_order[port] = 0;
                req_merge_mask[port] = 0;
            end
        end
    endtask

    task reset_dut;
        begin
            @(negedge clk);
            clear_requests();
            arst_n = 1'b0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            arst_n = 1'b1;
            repeat (2) @(posedge clk);
            #1;
            check(!busy && pending_count == 0,
                  "reset did not quiesce the DUT");
        end
    endtask

    task capture_simple;
        input integer requested_logical;
        input requested_push;
        input integer requested_rank;
        input integer requested_tag;
        input integer requested_order;
        reg captured;
        integer capture_watchdog;
        begin
            captured = 1'b0;
            capture_watchdog = 0;
            while (!captured && (capture_watchdog < 5000)) begin
                @(negedge clk);
                clear_requests();
                req_valid[0] = 1'b1;
                req_push[0] = requested_push;
                logical_tree_id[0] =
                    requested_logical[1:0];
                push_data[0] = {
                    requested_tag[MTW-1:0],
                    requested_rank[PTW-1:0]};
                req_order[0] = requested_order;
                #1;
                captured = req_capture_fire[0];
                @(posedge clk);
                #1;
                capture_watchdog = capture_watchdog + 1;
            end
            check(captured,
                  "simple request capture timeout");
        end
    endtask

    task capture_same_logical_pp;
        input integer requested_logical;
        input integer requested_rank;
        input integer requested_tag;
        input integer requested_order;
        reg captured;
        integer capture_watchdog;
        begin
            captured = 1'b0;
            capture_watchdog = 0;
            while (!captured && (capture_watchdog < 5000)) begin
                @(negedge clk);
                clear_requests();
                if (pending_effective_free_count >= 2) begin
                    req_valid = 4'b0011;
                    req_push = 4'b0001;
                    logical_tree_id[0] =
                        requested_logical[1:0];
                    logical_tree_id[1] =
                        requested_logical[1:0];
                    push_data[0] = {
                        requested_tag[MTW-1:0],
                        requested_rank[PTW-1:0]};
                    req_order[0] = requested_order;
                    req_order[1] = requested_order;
                    req_merge_mask[0][1] = 1'b1;
                    req_merge_mask[1][0] = 1'b1;
                end
                #1;
                check(req_capture_fire[1:0] == 2'b00 ||
                      req_capture_fire[1:0] == 2'b11,
                      "P/P pair was only partially captured");
                captured =
                    (req_capture_fire[1:0] == 2'b11);
                @(posedge clk);
                #1;
                capture_watchdog = capture_watchdog + 1;
            end
            check(captured,
                  "same-logical P/P capture timeout");
        end
    endtask

    task wait_quiescent;
        begin
            @(negedge clk);
            clear_requests();
            #1;
            watchdog = 0;
            while (busy && (watchdog < 20000)) begin
                @(posedge clk);
                #1;
                watchdog = watchdog + 1;
            end
            check(!busy, "timeout waiting for quiescence");
        end
    endtask

    task wait_for_pop_results;
        input integer expected_count;
        begin
            watchdog = 0;
            while ((pop_result_count < expected_count) &&
                   (watchdog < 100)) begin
                @(posedge clk);
                #1;
                watchdog = watchdog + 1;
            end
            check(pop_result_count >= expected_count,
                  "timeout waiting for Pop result FIFO");
        end
    endtask

    task begin_phase;
        input integer requested_phase;
        begin
            check(!busy,
                  "performance phase began before quiescence");
            phase_id = requested_phase;
            phase_cycles = 0;
            phase_transactions = 0;
            phase_primitives = 0;
            phase_completions = 0;
            phase_retired_primitives = 0;
            phase_taskfifo_words = 0;
            phase_pp_transactions = 0;
            phase_oneword_pp = 0;
            phase_fallback_pp = 0;
            phase_pp_completed = 0;
            phase_pp_push_completions = 0;
            phase_pp_pop_completions = 0;
            phase_busy_blocked_cycles = 0;
            phase_boundary_unfilled_cycles = 0;
            phase_datapath_idle_cycles = 0;
            phase_datapath_idle_with_pending_cycles = 0;
            phase_empty_engine_with_pending_cycles = 0;
            phase_boundary_datapath_idle_cycles = 0;
            phase_other_logical_dispatches = 0;
            phase_oneword_latency_sum = 0;
            phase_oneword_latency_count = 0;
            phase_fallback_latency_sum = 0;
            phase_fallback_latency_count = 0;
            phase_pp_physical_switches = 0;
            phase_last_pp_physical = -1;
            phase_dispatch_events = 0;
            phase_multi_lane_cycles = 0;
            phase_capture_backpressure_cycles = 0;
            phase_candidate_stall_logical_cycles = 0;
            phase_partner_resolution_logical_cycles = 0;
            phase_partner_resolution_active_cycles = 0;
            phase_max_parallel_partner_resolutions = 0;
            phase_max_parallel_primary_candidates = 0;
            phase_resolution_ready_overlap_cycles = 0;
            phase_committed_primitives = 0;
            phase_plan_fill_cycles = 0;
            phase_plan_commit_cycles = 0;
            phase_plan_stall_cycles = 0;
            phase_reservation_stall_cycles = 0;
            phase_allocation_unavailable_cycles = 0;
            phase_retire_commit_conflict_cycles = 0;
            phase_stage_a_b_overlap_cycles = 0;
            phase_candidate_commit_overlap_cycles = 0;
            phase_partner_commit_overlap_cycles = 0;
            phase_class_dispatch_cycles = 0;
            phase_class_completion_cycles = 0;
            phase_class_busy_successor_cycles = 0;
            phase_class_completion_drain_cycles = 0;
            phase_class_partner_resolution_cycles = 0;
            phase_class_candidate_not_ready_cycles = 0;
            phase_class_directory_shard_cycles = 0;
            phase_class_taskfifo_rpu_cycles = 0;
            phase_class_lane_arbitration_cycles = 0;
            phase_class_allocation_reservation_cycles = 0;
            phase_class_other_cycles = 0;
            phase_successor_prepared_events = 0;
            phase_successor_ready_busy_logical_cycles = 0;
            for (j = 0; j < LOGICAL_TREE_NUM;
                 j = j + 1) begin
                pp_active[j] = 1'b0;
                pp_fallback[j] = 1'b0;
                pp_push_seen[j] = 1'b0;
                unlock_waiting[j] = 1'b0;
                unlock_cycle[j] = -1;
                successor_ready_while_busy_seen[j] = 1'b0;
            end
            phase_active = 1'b1;
            $display("PERF START phase=%0d time=%0t",
                     phase_id, $time);
        end
    endtask

    task finish_phase;
        input integer expected_transactions;
        input integer expected_primitives;
        integer cycles_per_transaction_x1000;
        integer completions_per_cycle_x1000;
        integer fallback_ratio_x1000;
        integer pp_words_x1000;
        integer oneword_latency_x1000;
        integer fallback_latency_x1000;
        integer fallback_extra_x1000;
        begin
            wait_quiescent();
            phase_active = 1'b0;
            check(phase_transactions == expected_transactions,
                  "phase transaction capture count mismatch");
            check(phase_primitives == expected_primitives,
                  "phase primitive capture count mismatch");
            check(phase_completions == expected_primitives,
                  "phase completion count mismatch");
            check(phase_retired_primitives ==
                      expected_primitives,
                  "pending entry retired more or less than once");
            check(phase_committed_primitives ==
                      expected_primitives,
                  "allocation plan committed more or less than once");
            check(phase_pp_completed ==
                      phase_pp_transactions,
                  "P/P transaction did not complete exactly once");
            check(phase_pp_push_completions ==
                      phase_pp_transactions &&
                  phase_pp_pop_completions ==
                      phase_pp_transactions,
                  "P/P Push/Pop phase completion mismatch");
            check(phase_class_dispatch_cycles +
                      phase_class_completion_cycles +
                      phase_class_busy_successor_cycles +
                      phase_class_completion_drain_cycles +
                      phase_class_partner_resolution_cycles +
                      phase_class_candidate_not_ready_cycles +
                      phase_class_directory_shard_cycles +
                      phase_class_taskfifo_rpu_cycles +
                      phase_class_lane_arbitration_cycles +
                      phase_class_allocation_reservation_cycles +
                      phase_class_other_cycles == phase_cycles,
                  "exclusive phase-cycle attribution did not sum to phase cycles");

            cycles_per_transaction_x1000 =
                (phase_cycles * 1000) /
                expected_transactions;
            completions_per_cycle_x1000 =
                (phase_completions * 1000) /
                phase_cycles;
            fallback_ratio_x1000 =
                (phase_pp_transactions == 0) ? 0 :
                (phase_fallback_pp * 1000) /
                phase_pp_transactions;
            pp_words_x1000 =
                (phase_pp_transactions == 0) ? 0 :
                ((phase_taskfifo_words -
                  (phase_transactions -
                   phase_pp_transactions)) * 1000) /
                phase_pp_transactions;
            oneword_latency_x1000 =
                (phase_oneword_latency_count == 0) ? 0 :
                (phase_oneword_latency_sum * 1000) /
                phase_oneword_latency_count;
            fallback_latency_x1000 =
                (phase_fallback_latency_count == 0) ? 0 :
                (phase_fallback_latency_sum * 1000) /
                phase_fallback_latency_count;
            fallback_extra_x1000 =
                (phase_fallback_latency_count == 0) ? 0 :
                fallback_latency_x1000 -
                baseline_oneword_latency_x1000;

            if (phase_id == 1)
                baseline_oneword_latency_x1000 =
                    oneword_latency_x1000;

            $display("PERF phase=%0d transactions=%0d primitives=%0d cycles=%0d cycles_per_transaction_x1000=%0d completions=%0d completions_per_cycle_x1000=%0d dispatched=%0d retired=%0d committed=%0d oneword_pp=%0d fallback_pp=%0d fallback_ratio_x1000=%0d taskfifo_words=%0d pp_words_x1000=%0d multi_lane_cycles=%0d capture_backpressure_cycles=%0d plan_fill_cycles=%0d plan_commit_cycles=%0d plan_stall_cycles=%0d reservation_stall_cycles=%0d allocation_unavailable_cycles=%0d retire_commit_conflict_cycles=%0d stage_a_b_overlap_cycles=%0d candidate_commit_overlap_cycles=%0d partner_commit_overlap_cycles=%0d candidate_stall_logical_cycles=%0d partner_resolution_logical_cycles=%0d partner_resolution_active_cycles=%0d max_parallel_partner_resolutions=%0d max_parallel_primary_candidates=%0d resolution_ready_overlap_cycles=%0d busy_blocked_cycles=%0d boundary_unfilled_cycles=%0d datapath_idle_cycles=%0d datapath_idle_with_pending=%0d empty_engine_with_pending=%0d boundary_datapath_idle=%0d other_logical_dispatches=%0d pp_physical_switches=%0d oneword_latency_x1000=%0d fallback_latency_x1000=%0d fallback_extra_vs_phase1_x1000=%0d",
                     phase_id, phase_transactions,
                     phase_primitives, phase_cycles,
                     cycles_per_transaction_x1000,
                     phase_completions,
                     completions_per_cycle_x1000,
                     phase_dispatch_events,
                     phase_retired_primitives,
                     phase_committed_primitives,
                     phase_oneword_pp, phase_fallback_pp,
                     fallback_ratio_x1000,
                     phase_taskfifo_words, pp_words_x1000,
                     phase_multi_lane_cycles,
                     phase_capture_backpressure_cycles,
                     phase_plan_fill_cycles,
                     phase_plan_commit_cycles,
                     phase_plan_stall_cycles,
                     phase_reservation_stall_cycles,
                     phase_allocation_unavailable_cycles,
                     phase_retire_commit_conflict_cycles,
                     phase_stage_a_b_overlap_cycles,
                     phase_candidate_commit_overlap_cycles,
                     phase_partner_commit_overlap_cycles,
                     phase_candidate_stall_logical_cycles,
                     phase_partner_resolution_logical_cycles,
                     phase_partner_resolution_active_cycles,
                     phase_max_parallel_partner_resolutions,
                     phase_max_parallel_primary_candidates,
                     phase_resolution_ready_overlap_cycles,
                     phase_busy_blocked_cycles,
                     phase_boundary_unfilled_cycles,
                     phase_datapath_idle_cycles,
                     phase_datapath_idle_with_pending_cycles,
                     phase_empty_engine_with_pending_cycles,
                     phase_boundary_datapath_idle_cycles,
                     phase_other_logical_dispatches,
                     phase_pp_physical_switches,
                     oneword_latency_x1000,
                     fallback_latency_x1000,
                     fallback_extra_x1000);
            $display("PERF_STALL phase=%0d classified=%0d dispatch=%0d completion_progress=%0d logical_busy_successor=%0d completion_drain=%0d partner_resolution=%0d candidate_not_ready=%0d directory_shard=%0d taskfifo_rpu=%0d lane_arbitration=%0d allocation_reservation=%0d other=%0d successor_prepared_events=%0d successor_ready_busy_logical_cycles=%0d",
                     phase_id,
                     phase_class_dispatch_cycles +
                         phase_class_completion_cycles +
                         phase_class_busy_successor_cycles +
                         phase_class_completion_drain_cycles +
                         phase_class_partner_resolution_cycles +
                         phase_class_candidate_not_ready_cycles +
                         phase_class_directory_shard_cycles +
                         phase_class_taskfifo_rpu_cycles +
                         phase_class_lane_arbitration_cycles +
                         phase_class_allocation_reservation_cycles +
                         phase_class_other_cycles,
                     phase_class_dispatch_cycles,
                     phase_class_completion_cycles,
                     phase_class_busy_successor_cycles,
                     phase_class_completion_drain_cycles,
                     phase_class_partner_resolution_cycles,
                     phase_class_candidate_not_ready_cycles,
                     phase_class_directory_shard_cycles,
                     phase_class_taskfifo_rpu_cycles,
                     phase_class_lane_arbitration_cycles,
                     phase_class_allocation_reservation_cycles,
                     phase_class_other_cycles,
                     phase_successor_prepared_events,
                     phase_successor_ready_busy_logical_cycles);
        end
    endtask

    task preload_low_occupancy_root;
        begin
            capture_simple(0, 1'b1, 40, 16'h7000, 1);
            capture_simple(0, 1'b1, 10, 16'h7001, 2);
            capture_simple(0, 1'b1, 30, 16'h7002, 3);
            capture_simple(0, 1'b1, 20, 16'h7003, 4);
            wait_quiescent();
            check(shard_count[0] == 1 &&
                  shard_count[1] == 1 &&
                  shard_count[2] == 1 &&
                  shard_count[3] == 1 &&
                  shard_head_rank[1] == 10,
                  "low-occupancy root setup");
        end
    endtask

    task align_empty_root_rr;
        integer align_count;
        begin
            check(logical_count[0] == 0,
                  "RR alignment requires an empty root");
            align_count = 0;
            while ((push_rr_ptr[0] != 0) &&
                   (align_count < 4)) begin
                capture_same_logical_pp(
                    0, 16'hff00 + align_count,
                    16'h6f00 + align_count,
                    9500 + align_count);
                wait_quiescent();
                align_count = align_count + 1;
            end
            check(push_rr_ptr[0] == 0 &&
                  logical_count[0] == 0,
                  "root RR pointer did not align");
        end
    endtask

    task preload_near_full_root;
        begin
            for (setup_index = 0; setup_index < 117;
                 setup_index = setup_index + 1) begin
                if ((setup_index % 4) == 0)
                    rank_value = 100 + setup_index / 4;
                else
                    rank_value = 1000 + setup_index;
                capture_simple(
                    0, 1'b1, rank_value,
                    16'h8000 + setup_index,
                    1000 + setup_index);
            end
            wait_quiescent();
            check(shard_count[0] == 30 &&
                  shard_full[0] &&
                  shard_head_rank[0] == 100 &&
                  shard_count[1] == 29 &&
                  shard_count[2] == 29 &&
                  shard_count[3] == 29 &&
                  shard_head_rank[1] == 1001 &&
                  shard_head_rank[2] == 1002 &&
                  shard_head_rank[3] == 1003,
                  "near-full root setup");
        end
    endtask

    task drain_logical;
        input integer requested_logical;
        integer drain_count;
        integer drain_index;
        begin
            drain_count = logical_count[requested_logical];
            for (drain_index = 0;
                 drain_index < drain_count;
                 drain_index = drain_index + 1)
                capture_simple(
                    requested_logical, 1'b0, 0, 0,
                    9000 + requested_logical * 256 +
                        drain_index);
            wait_quiescent();
            check(logical_count[requested_logical] == 0,
                  "logical PIFO did not drain");
        end
    endtask

    task check_top_level_fallback_relations;
        begin
            pop_result_count = 0;

            capture_same_logical_pp(
                0, 1, 16'h9001, 2001);
            wait_quiescent();
            wait_for_pop_results(1);
            $display("Fallback better: pop=%h counts=%0d,%0d,%0d,%0d heads=%0d,%0d,%0d,%0d",
                     last_pop_data, shard_count[0],
                     shard_count[1], shard_count[2],
                     shard_count[3], shard_head_rank[0],
                     shard_head_rank[1], shard_head_rank[2],
                     shard_head_rank[3]);
            check(last_pop_logical == 0 &&
                  last_pop_data == {MTW'(16'h9001), PTW'(16'd1)},
                  "better-rank fallback returned wrong element");
            check(shard_count[0] == 30 &&
                  shard_count[1] == 29,
                  "better-rank fallback changed wrong shard count");

            capture_same_logical_pp(
                0, 100, 16'h9002, 2002);
            wait_quiescent();
            wait_for_pop_results(2);
            $display("Fallback equal: pop=%h counts=%0d,%0d,%0d,%0d heads=%0d,%0d,%0d,%0d",
                     last_pop_data, shard_count[0],
                     shard_count[1], shard_count[2],
                     shard_count[3], shard_head_rank[0],
                     shard_head_rank[1], shard_head_rank[2],
                     shard_head_rank[3]);
            check(last_pop_logical == 0 &&
                  last_pop_data == {MTW'(16'h8000), PTW'(16'd100)},
                  "equal-rank fallback tie result mismatch");
            check(shard_count[0] == 29 &&
                  shard_count[2] == 30 &&
                  shard_head_rank[2] == 100,
                  "equal-rank fallback final state mismatch");

            capture_same_logical_pp(
                0, 200, 16'h9003, 2003);
            wait_quiescent();
            wait_for_pop_results(3);
            $display("Fallback worse: pop=%h counts=%0d,%0d,%0d,%0d heads=%0d,%0d,%0d,%0d",
                     last_pop_data, shard_count[0],
                     shard_count[1], shard_count[2],
                     shard_count[3], shard_head_rank[0],
                     shard_head_rank[1], shard_head_rank[2],
                     shard_head_rank[3]);
            check(last_pop_logical == 0 &&
                  last_pop_data == {MTW'(16'h9002), PTW'(16'd100)},
                  "worse-rank fallback returned wrong old Head");
            check(logical_count[0] == 117 &&
                  shard_count[2] == 29 &&
                  shard_count[3] == 30 &&
                  shard_head_rank[3] == 200,
                  "worse-rank fallback final state mismatch");
            check(pop_result_count == 3,
                  "top-level fallback Pop result count");
            $display("Fallback top-level cases: better/equal/worse PASS");
        end
    endtask

    always @(posedge clk) begin
        if (!arst_n) begin
            global_cycle = 0;
            last_pop_data = 0;
            last_pop_logical = 0;
            pop_result_count = 0;
            for (i = 0; i < LOGICAL_TREE_NUM;
                 i = i + 1) begin
                pp_active[i] = 1'b0;
                pp_fallback[i] = 1'b0;
                pp_push_seen[i] = 1'b0;
                unlock_waiting[i] = 1'b0;
                unlock_cycle[i] = -1;
            end
        end else begin
            global_cycle = global_cycle + 1;

            if (pop_valid) begin
                last_pop_data = pop_data;
                last_pop_logical = pop_logical_tree_id;
                pop_result_count = pop_result_count + 1;
            end
            if (protocol_error)
                $fatal(1,
                       "HeterogeneousPIFO protocol error");

            if (phase_active) begin
                phase_cycles = phase_cycles + 1;

                capture_count = 0;
                pair_count = 0;
                for (i = 0; i < REQUEST_PORTS;
                     i = i + 1)
                    if (req_capture_fire[i])
                        capture_count = capture_count + 1;
                for (i = 0; i < REQUEST_PORTS;
                     i = i + 1)
                    for (j = i + 1; j < REQUEST_PORTS;
                         j = j + 1)
                        if (req_capture_fire[i] &&
                            req_capture_fire[j] &&
                            (req_push[i] != req_push[j]) &&
                            (logical_tree_id[i] ==
                             logical_tree_id[j]) &&
                            req_merge_mask[i][j] &&
                            req_merge_mask[j][i])
                            pair_count = pair_count + 1;
                phase_primitives =
                    phase_primitives + capture_count;
                phase_transactions =
                    phase_transactions +
                    capture_count - pair_count;
                phase_pp_transactions =
                    phase_pp_transactions + pair_count;

                word_count = 0;
                for (lane = 0; lane < LEVEL;
                     lane = lane + 1)
                    if (task_write[lane])
                        word_count = word_count + 1;
                phase_taskfifo_words =
                    phase_taskfifo_words + word_count;
                if (word_count >= 2)
                    phase_multi_lane_cycles =
                        phase_multi_lane_cycles + 1;
                if (|(req_valid & ~req_capture_ready))
                    phase_capture_backpressure_cycles =
                        phase_capture_backpressure_cycles + 1;
                if (|req_capture_fire)
                    phase_plan_fill_cycles =
                        phase_plan_fill_cycles + 1;

                plan_lane_count = 0;
                for (i = 0; i < REQUEST_PORTS;
                     i = i + 1)
                    if (dut.logical_pending.
                            allocation_plan_lane_valid[i])
                        plan_lane_count =
                            plan_lane_count + 1;
                if (dut.logical_pending.
                        allocation_plan_commit) begin
                    phase_plan_commit_cycles =
                        phase_plan_commit_cycles + 1;
                    phase_committed_primitives =
                        phase_committed_primitives +
                        plan_lane_count;
                    if (|req_capture_fire)
                        phase_stage_a_b_overlap_cycles =
                            phase_stage_a_b_overlap_cycles + 1;
                    if (|(dut.logical_pending.
                              allocation_plan_slot_mask &
                          dut.logical_pending.
                              retire_slot_mask)) begin
                        phase_retire_commit_conflict_cycles =
                            phase_retire_commit_conflict_cycles + 1;
                        check(1'b0,
                              "allocation commit overlapped a retire slot");
                    end
                end
                if (dut.logical_pending.allocation_plan_valid &&
                    !dut.logical_pending.
                        allocation_plan_commit)
                    phase_plan_stall_cycles =
                        phase_plan_stall_cycles + 1;
                if (|(req_valid & ~req_capture_ready)) begin
                    phase_allocation_unavailable_cycles =
                        phase_allocation_unavailable_cycles + 1;
                    if (|dut.logical_pending.slot_reserved)
                        phase_reservation_stall_cycles =
                            phase_reservation_stall_cycles + 1;
                end

                pending_valid_count = 0;
                pending_reserved_count = 0;
                for (i = 0; i < LOGICAL_PENDING_DEPTH;
                     i = i + 1) begin
                    if (dut.logical_pending.slot_valid[i])
                        pending_valid_count =
                            pending_valid_count + 1;
                    if (dut.logical_pending.slot_reserved[i])
                        pending_reserved_count =
                            pending_reserved_count + 1;
                end
                check((dut.logical_pending.slot_valid &
                       dut.logical_pending.slot_reserved) == 0,
                      "pending slot was valid and reserved");
                check(pending_count ==
                          pending_valid_count +
                          pending_reserved_count,
                      "pending occupancy omitted valid or reserved slots");
                check(dut.logical_pending.
                          allocation_plan_valid ==
                          (|dut.logical_pending.slot_reserved),
                      "plan-valid and reservation state diverged");
                check((dut.logical_pending.
                           retire_request_slot_mask &
                       dut.logical_pending.slot_reserved) == 0,
                      "reserved slot entered dispatch retirement");

                saw_blocked = 1'b0;
                saw_other_busy = 1'b0;
                saw_busy_logical = 1'b0;
                saw_busy_ready_successor = 1'b0;
                saw_nonbusy_ready_candidate = 1'b0;
                saw_directory_selection = 1'b0;
                saw_selected_fifo_full = 1'b0;
                saw_lane_arbitration_loss = 1'b0;
                resolving_count = 0;
                primary_candidate_count = 0;
                ready_candidate_count = 0;
                for (i = 0; i < LOGICAL_TREE_NUM;
                     i = i + 1) begin
                    if (dut.candidate_primary_valid[i])
                        primary_candidate_count =
                            primary_candidate_count + 1;
                    if (dut.candidate_partner_resolving[i])
                        resolving_count = resolving_count + 1;
                    if (dut.candidate_dispatch_ready[i])
                        ready_candidate_count =
                            ready_candidate_count + 1;
                    if (dut.candidate_dispatch_ready[i] &&
                        !dispatch_fire[i])
                        phase_candidate_stall_logical_cycles =
                            phase_candidate_stall_logical_cycles + 1;
                    if (dut.pending_head_valid[i] &&
                        logical_busy[i])
                        saw_blocked = 1'b1;
                    if (logical_busy[i])
                        saw_busy_logical = 1'b1;
                    if (dut.candidate_dispatch_ready[i] &&
                        logical_busy[i]) begin
                        saw_busy_ready_successor = 1'b1;
                        phase_successor_ready_busy_logical_cycles =
                            phase_successor_ready_busy_logical_cycles + 1;
                        if (!successor_ready_while_busy_seen[i]) begin
                            phase_successor_prepared_events =
                                phase_successor_prepared_events + 1;
                            successor_ready_while_busy_seen[i] = 1'b1;
                        end
                    end else begin
                        successor_ready_while_busy_seen[i] = 1'b0;
                    end
                    if (dut.candidate_dispatch_ready[i] &&
                        !logical_busy[i])
                        saw_nonbusy_ready_candidate = 1'b1;
                    if (dut.directory_select_valid[i]) begin
                        saw_directory_selection = 1'b1;
                        if (task_fifo_full[
                                selected_physical_tree_id[i] % LEVEL])
                            saw_selected_fifo_full = 1'b1;
                        else if (!dispatch_fire[i])
                            saw_lane_arbitration_loss = 1'b1;
                    end
                    if (unlock_waiting[i] &&
                        !engine_datapath_active)
                        phase_boundary_datapath_idle_cycles =
                            phase_boundary_datapath_idle_cycles + 1;
                    if (dispatch_fire[i]) begin
                        phase_dispatch_events =
                            phase_dispatch_events + 1;
                        for (j = 0; j < LOGICAL_TREE_NUM;
                             j = j + 1)
                            if ((j != i) && logical_busy[j])
                                saw_other_busy = 1'b1;

                        if (unlock_waiting[i]) begin
                            check(global_cycle -
                                  unlock_cycle[i] >= 1,
                                  "same-logical re-dispatched on completion edge");
                            unlock_waiting[i] = 1'b0;
                        end

                        if (dut.directory_select_pp[i]) begin
                            check(task_push[
                                      selected_physical_tree_id[i] %
                                      LEVEL] &&
                                  task_pop[
                                      selected_physical_tree_id[i] %
                                      LEVEL],
                                  "one-word P/P bits were not both set");
                            check(!pp_active[i],
                                  "overlapping same-logical P/P");
                            pp_active[i] = 1'b1;
                            pp_fallback[i] = 1'b0;
                            pp_push_seen[i] = 1'b0;
                            pp_first_dispatch_cycle[i] =
                                global_cycle;
                            phase_oneword_pp =
                                phase_oneword_pp + 1;
                            phase_retired_primitives =
                                phase_retired_primitives + 2;
                            if (phase_last_pp_physical >= 0 &&
                                phase_last_pp_physical !=
                                    selected_physical_tree_id[i])
                                phase_pp_physical_switches =
                                    phase_pp_physical_switches + 1;
                            phase_last_pp_physical =
                                selected_physical_tree_id[i];
                        end else if (
                            dut.candidate_partner_valid[i] &&
                            dispatch_push[i]) begin
                            check(task_push[
                                      selected_physical_tree_id[i] %
                                      LEVEL] &&
                                  !task_pop[
                                      selected_physical_tree_id[i] %
                                      LEVEL],
                                  "fallback did not start with Push-only word");
                            check(!pp_active[i],
                                  "overlapping fallback P/P");
                            pp_active[i] = 1'b1;
                            pp_fallback[i] = 1'b1;
                            pp_push_seen[i] = 1'b0;
                            pp_first_dispatch_cycle[i] =
                                global_cycle;
                            phase_fallback_pp =
                                phase_fallback_pp + 1;
                            phase_retired_primitives =
                                phase_retired_primitives + 1;
                        end else begin
                            phase_retired_primitives =
                                phase_retired_primitives + 1;
                            if (pp_active[i] &&
                                pp_fallback[i]) begin
                                check(!dispatch_push[i] &&
                                      task_pop[
                                          selected_physical_tree_id[i] %
                                          LEVEL],
                                      "fallback second phase was not Pop");
                            end
                        end
                    end
                end
                phase_partner_resolution_logical_cycles =
                    phase_partner_resolution_logical_cycles +
                    resolving_count;
                if (resolving_count != 0)
                    phase_partner_resolution_active_cycles =
                        phase_partner_resolution_active_cycles + 1;
                if (resolving_count >
                    phase_max_parallel_partner_resolutions)
                    phase_max_parallel_partner_resolutions =
                        resolving_count;
                if (primary_candidate_count >
                    phase_max_parallel_primary_candidates)
                    phase_max_parallel_primary_candidates =
                        primary_candidate_count;
                if ((resolving_count != 0) &&
                    (ready_candidate_count != 0))
                    phase_resolution_ready_overlap_cycles =
                        phase_resolution_ready_overlap_cycles + 1;
                if (dut.logical_pending.
                        allocation_plan_commit &&
                    (primary_candidate_count != 0))
                    phase_candidate_commit_overlap_cycles =
                        phase_candidate_commit_overlap_cycles + 1;
                if (dut.logical_pending.
                        allocation_plan_commit &&
                    (resolving_count != 0))
                    phase_partner_commit_overlap_cycles =
                        phase_partner_commit_overlap_cycles + 1;
                if (saw_blocked)
                    phase_busy_blocked_cycles =
                        phase_busy_blocked_cycles + 1;
                if (saw_other_busy)
                    phase_other_logical_dispatches =
                        phase_other_logical_dispatches + 1;

                // Exclusive phase-cycle attribution.  A TaskFIFO write is the
                // primary throughput event.  A completion is counted next;
                // the remaining buckets explain cycles with neither event.
                if (word_count != 0) begin
                    phase_class_dispatch_cycles =
                        phase_class_dispatch_cycles + 1;
                end else if (|dut.engine_root_update_valid) begin
                    phase_class_completion_cycles =
                        phase_class_completion_cycles + 1;
                end else if (saw_busy_ready_successor) begin
                    phase_class_busy_successor_cycles =
                        phase_class_busy_successor_cycles + 1;
                end else if (resolving_count != 0) begin
                    phase_class_partner_resolution_cycles =
                        phase_class_partner_resolution_cycles + 1;
                end else if ((pending_count != 0) &&
                             (ready_candidate_count == 0)) begin
                    phase_class_candidate_not_ready_cycles =
                        phase_class_candidate_not_ready_cycles + 1;
                end else if (saw_selected_fifo_full) begin
                    phase_class_taskfifo_rpu_cycles =
                        phase_class_taskfifo_rpu_cycles + 1;
                end else if (saw_lane_arbitration_loss) begin
                    phase_class_lane_arbitration_cycles =
                        phase_class_lane_arbitration_cycles + 1;
                end else if (saw_nonbusy_ready_candidate &&
                             !saw_directory_selection) begin
                    phase_class_directory_shard_cycles =
                        phase_class_directory_shard_cycles + 1;
                end else if (|(req_valid & ~req_capture_ready)) begin
                    phase_class_allocation_reservation_cycles =
                        phase_class_allocation_reservation_cycles + 1;
                end else if (saw_busy_logical) begin
                    phase_class_completion_drain_cycles =
                        phase_class_completion_drain_cycles + 1;
                end else begin
                    phase_class_other_cycles =
                        phase_class_other_cycles + 1;
                end

                if (!engine_datapath_active) begin
                    phase_datapath_idle_cycles =
                        phase_datapath_idle_cycles + 1;
                    if (pending_count != 0)
                        phase_datapath_idle_with_pending_cycles =
                            phase_datapath_idle_with_pending_cycles + 1;
                end
                if (!engine_has_queued_or_inflight_work &&
                    (pending_count != 0))
                    phase_empty_engine_with_pending_cycles =
                        phase_empty_engine_with_pending_cycles + 1;

                for (lane = 0; lane < LEVEL;
                     lane = lane + 1) begin
                    if (dut.engine_root_update_valid[lane]) begin
                        phase_completions =
                            phase_completions + 1;
                        physical_id =
                            dut.engine_tree_id[lane];
                        logical_id =
                            pending_logical_tree_id[physical_id];

                        if (!(dut.directory.o_pending_pp[
                                  physical_id] &&
                              pending_push[physical_id])) begin
                            if (dut.pending_head_valid[
                                    logical_id]) begin
                                unlock_waiting[logical_id] =
                                    1'b1;
                                unlock_cycle[logical_id] =
                                    global_cycle;
                                if (word_count == 0)
                                    phase_boundary_unfilled_cycles =
                                        phase_boundary_unfilled_cycles + 1;
                            end
                        end

                        if (pp_active[logical_id]) begin
                            if (pending_push[physical_id]) begin
                                check(!pp_push_seen[logical_id],
                                      "P/P Push completion repeated");
                                pp_push_seen[logical_id] = 1'b1;
                                phase_pp_push_completions =
                                    phase_pp_push_completions + 1;
                            end else begin
                                check(pp_push_seen[logical_id],
                                      "P/P Pop completed before Push");
                                phase_pp_pop_completions =
                                    phase_pp_pop_completions + 1;
                                phase_pp_completed =
                                    phase_pp_completed + 1;
                                if (pp_fallback[logical_id]) begin
                                    phase_fallback_latency_sum =
                                        phase_fallback_latency_sum +
                                        global_cycle -
                                        pp_first_dispatch_cycle[
                                            logical_id];
                                    phase_fallback_latency_count =
                                        phase_fallback_latency_count + 1;
                                end else begin
                                    phase_oneword_latency_sum =
                                        phase_oneword_latency_sum +
                                        global_cycle -
                                        pp_first_dispatch_cycle[
                                            logical_id];
                                    phase_oneword_latency_count =
                                        phase_oneword_latency_count + 1;
                                end
                                pp_active[logical_id] = 1'b0;
                                pp_push_seen[logical_id] = 1'b0;
                            end
                        end
                    end
                end
            end
        end
    end

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        failures = 0;
        phase_active = 1'b0;
        phase_id = 0;
        baseline_oneword_latency_x1000 = 0;
        clear_requests();

        repeat (4) @(posedge clk);
        arst_n = 1'b1;
        repeat (2) @(posedge clk);
        #1;

        // Phase 1: one logical continuously queues same-logical P/P.
        begin_phase(1);
        for (workload_index = 0; workload_index < 20;
             workload_index = workload_index + 1)
            capture_same_logical_pp(
                1, 100 + workload_index,
                16'ha000 + workload_index,
                3000 + workload_index);
        finish_phase(20, 40);

        // Phase 2: four logical PIFOs interleave the same P/P load.
        begin_phase(2);
        for (workload_index = 0; workload_index < 40;
             workload_index = workload_index + 1)
            capture_same_logical_pp(
                workload_index % LOGICAL_TREE_NUM,
                200 + workload_index,
                16'hb000 + workload_index,
                4000 + workload_index);
        finish_phase(40, 80);
        check(phase_max_parallel_primary_candidates ==
                  LOGICAL_TREE_NUM,
              "four logical candidate pipelines were never occupied");
        check(phase_resolution_ready_overlap_cycles > 0,
              "different logical partner/dispatch stages never overlapped");

        // Phase 3: all four root shards remain lightly occupied while the
        // global best Head rotates through physical shards.
        align_empty_root_rr();
        preload_low_occupancy_root();
        begin_phase(3);
        for (workload_index = 0; workload_index < 16;
             workload_index = workload_index + 1)
            capture_same_logical_pp(
                0, 50 + workload_index * 10,
                16'hc000 + workload_index,
                5000 + workload_index);
        finish_phase(16, 32);
        check(phase_pp_physical_switches >= 12,
              "low-occupancy P/P did not rotate global Head shards");
        drain_logical(0);
        align_empty_root_rr();

        // Full-minimum fallback is checked end-to-end for all three rank
        // relationships before the throughput-oriented near-full phase.
        preload_near_full_root();
        check_top_level_fallback_relations();
        drain_logical(0);
        align_empty_root_rr();

        // Phase 4: keep physical 0 full and globally minimal.  Every better
        // Push is placed on another shard and immediately selected by the
        // re-evaluated Pop, so all P/P transactions take the fallback path.
        preload_near_full_root();
        begin_phase(4);
        for (workload_index = 0; workload_index < 12;
             workload_index = workload_index + 1)
            capture_same_logical_pp(
                0, 1 + workload_index,
                16'hd000 + workload_index,
                6000 + workload_index);
        finish_phase(12, 24);
        check(phase_fallback_pp == 12 &&
              phase_oneword_pp == 0 &&
              logical_count[0] == 117 &&
              shard_count[0] == 30,
              "near-full fallback phase coverage/state");
        drain_logical(0);

        // Phase 5: balanced Push/Pop/P/P traffic across all logical PIFOs.
        for (logical_id = 0;
             logical_id < LOGICAL_TREE_NUM;
             logical_id = logical_id + 1)
            for (setup_index = 0; setup_index < 8;
                 setup_index = setup_index + 1)
                capture_simple(
                    logical_id, 1'b1,
                    500 + logical_id * 100 + setup_index,
                    16'he000 + logical_id * 16 +
                        setup_index,
                    7000 + logical_id * 16 +
                        setup_index);
        wait_quiescent();
        begin_phase(5);
        for (workload_index = 0; workload_index < 64;
             workload_index = workload_index + 1) begin
            logical_id = workload_index % LOGICAL_TREE_NUM;
            case ((workload_index / LOGICAL_TREE_NUM) % 4)
                0, 3:
                    capture_same_logical_pp(
                        logical_id,
                        50 + workload_index,
                        16'hf000 + workload_index,
                        8000 + workload_index);
                1:
                    capture_simple(
                        logical_id, 1'b1,
                        50 + workload_index,
                        16'hf000 + workload_index,
                        8000 + workload_index);
                default:
                    capture_simple(
                        logical_id, 1'b0, 0, 0,
                        8000 + workload_index);
            endcase
        end
        finish_phase(64, 96);
        for (logical_id = 0;
             logical_id < LOGICAL_TREE_NUM;
             logical_id = logical_id + 1)
            check(logical_count[logical_id] == 8,
                  "mixed phase changed balanced logical count");

        check(!protocol_error, "final protocol error");
        if (failures == 0)
            $display("PASS: HeterogeneousPIFO_perf_tb");
        else
            $fatal(1,
                   "HeterogeneousPIFO_perf_tb failures=%0d",
                   failures);
        $finish;
    end
endmodule
