`timescale 1ns / 1ps

module HeterogeneousPIFO_tb #(
    parameter LOGICAL_PENDING_DEPTH = 12,
    parameter DIRECTORY_DERIVE_LOGICAL_COUNT = 0
);
    localparam PTW = 16;
    localparam MTW = 16;
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
    localparam PENDING_SLOT_WIDTH =
        $clog2(LOGICAL_PENDING_DEPTH);
    localparam PENDING_COUNT_WIDTH =
        $clog2(LOGICAL_PENDING_DEPTH + 1);
    localparam MODEL_DEPTH = 64;

    reg clk;
    reg arst_n;
    reg [REQUEST_PORTS-1:0] req_valid;
    reg [REQUEST_PORTS-1:0] req_push;
    reg [1:0] logical_tree_id [0:REQUEST_PORTS-1];
    reg [DATA_WIDTH-1:0] push_data [0:REQUEST_PORTS-1];
    reg [TASK_ORDER_WIDTH-1:0] req_order [0:REQUEST_PORTS-1];
    reg [REQUEST_PORTS-1:0] req_merge_mask [0:REQUEST_PORTS-1];

    wire [REQUEST_PORTS-1:0] req_capture_ready;
    wire [REQUEST_PORTS-1:0] req_capture_fire;
    wire [REQUEST_PORTS-1:0] req_capture_bad_id;
    wire [LOGICAL_TREE_NUM-1:0] dispatch_fire;
    wire [LOGICAL_TREE_NUM-1:0] dispatch_push;
    wire [1:0] dispatch_logical_tree_id [0:LOGICAL_TREE_NUM-1];
    wire [2:0] selected_physical_tree_id [0:LOGICAL_TREE_NUM-1];
    wire [DATA_WIDTH-1:0] dispatch_data [0:LOGICAL_TREE_NUM-1];
    wire [1:0] dispatch_source_port [0:LOGICAL_TREE_NUM-1];
    wire [LOGICAL_TREE_NUM-1:0] dispatch_reject_empty;
    wire [LOGICAL_TREE_NUM-1:0] dispatch_reject_full;
    wire [PENDING_COUNT_WIDTH-1:0]
        logical_pending_count [0:LOGICAL_TREE_NUM-1];
    wire [PENDING_COUNT_WIDTH-1:0] pending_count;
    wire [PENDING_COUNT_WIDTH-1:0] pending_effective_free_count;
    wire busy;
    wire pop_valid;
    wire [1:0] pop_logical_tree_id;
    wire [DATA_WIDTH-1:0] pop_data;
    wire internal_root_pop_valid;
    wire [DATA_WIDTH-1:0] internal_root_pop_data;
    wire protocol_error;
    wire [LEVEL-1:0] task_fifo_full;
    wire [LEVEL-1:0] task_write;
    wire [LEVEL-1:0] task_push;
    wire [LEVEL-1:0] task_pop;

    wire [2:0] shard_list [0:LOGICAL_TREE_NUM-1][0:3];
    wire [2:0] logical_shard_count [0:LOGICAL_TREE_NUM-1];
    wire [7:0] logical_count [0:LOGICAL_TREE_NUM-1];
    wire [1:0] push_rr_ptr [0:LOGICAL_TREE_NUM-1];
    wire [4:0] shard_count [0:PHYSICAL_TREE_NUM-1];
    wire [PTW-1:0] shard_head_rank [0:PHYSICAL_TREE_NUM-1];
    wire shard_empty [0:PHYSICAL_TREE_NUM-1];
    wire shard_full [0:PHYSICAL_TREE_NUM-1];
    wire shard_head_valid [0:PHYSICAL_TREE_NUM-1];
    wire update_pending [0:PHYSICAL_TREE_NUM-1];
    wire logical_busy [0:LOGICAL_TREE_NUM-1];
    wire [1:0] pending_logical_tree_id [0:PHYSICAL_TREE_NUM-1];
    wire pending_push [0:PHYSICAL_TREE_NUM-1];

    reg [PTW-1:0]
        model_rank [0:LOGICAL_TREE_NUM-1][0:MODEL_DEPTH-1];
    reg [DATA_WIDTH-1:0]
        model_data [0:LOGICAL_TREE_NUM-1][0:MODEL_DEPTH-1];
    integer model_count [0:LOGICAL_TREE_NUM-1];
    reg [DATA_WIDTH-1:0]
        pop_expected_mem [0:LOGICAL_TREE_NUM-1][0:MODEL_DEPTH-1];
    integer pop_expected_head [0:LOGICAL_TREE_NUM-1];
    integer pop_expected_tail [0:LOGICAL_TREE_NUM-1];
    integer pop_expected_count [0:LOGICAL_TREE_NUM-1];

    integer failures;
    integer captured_requests;
    integer retired_pending_requests;
    integer dispatched_requests;
    integer expected_engine_completions;
    integer engine_completions;
    integer same_logical_pp_dispatches;
    integer same_logical_pp_push_completions;
    integer same_logical_pp_pop_completions;
    integer max_lane_writes_same_cycle;
    integer multi_lane_cycles;
    integer dispatch_physical_log [0:255];
    integer dispatch_logical_log [0:255];
    reg dispatch_push_log [0:255];
    integer completion_physical_log [0:255];
    reg completion_push_log [0:255];
    integer i;
    integer j;
    integer lane_count;
    integer watchdog;
    integer log_start;
    integer completion_start;
    integer actual_retire_slots;
    integer expected_retire_slots;
    integer retire_slot_scan;
    integer candidate_hold_cycles;
    integer partner_resolution_cycles;
    integer parallel_partner_resolutions;
    integer max_parallel_partner_resolutions;
    integer committed_requests;
    integer allocation_plan_fill_cycles;
    integer allocation_plan_commit_cycles;
    integer allocation_stage_overlap_cycles;
    integer allocation_candidate_overlap_cycles;
    integer allocation_partner_overlap_cycles;
    integer plan_lane_count;
    integer pp_winner_count;
    integer push_winner_count;
    integer pop_winner_count;
    integer pending_valid_count;
    integer pending_reserved_count;
    integer relation_check_source;
    integer relation_check_target;
    integer partner_expected_slot;
    integer partner_scan_slot;
    integer partner_oldest_count;
    reg saw_capture_while_busy;
    reg saw_same_event_pp;
    reg saw_old_pop_new_push_separate;
    reg saw_old_push_new_pop_separate;
    reg saw_equal_tag_separate;
    reg saw_other_logical_dispatch_while_busy;
    reg saw_reset_during_partner_resolution;
    reg saw_capture_during_partner_resolution;
    reg [LOGICAL_TREE_NUM-1:0] same_logical_pp_inflight;
    reg [PHYSICAL_TREE_NUM-1:0] same_logical_pp_physical_inflight;
    reg [LOGICAL_TREE_NUM-1:0] previous_candidate_valid;
    reg [PENDING_SLOT_WIDTH-1:0]
        previous_candidate_slot_id [0:LOGICAL_TREE_NUM-1];
    reg [LOGICAL_TREE_NUM-1:0] previous_candidate_partner_valid;
    reg [PENDING_SLOT_WIDTH-1:0]
        previous_candidate_partner_slot_id [0:LOGICAL_TREE_NUM-1];
    reg [LOGICAL_PENDING_DEPTH-1:0]
        expected_registered_retire_mask;

    HeterogeneousPIFO #(
        .LEVEL(LEVEL),
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(PHYSICAL_TREE_NUM),
        .SHARD_CAPACITY(30),
        .MAX_SHARDS_PER_LOGICAL(4),
        .REQUEST_PORTS(REQUEST_PORTS),
        .TASK_ORDER_WIDTH(TASK_ORDER_WIDTH),
        .LOGICAL_PENDING_DEPTH(LOGICAL_PENDING_DEPTH),
        .DIRECTORY_DERIVE_LOGICAL_COUNT(
            DIRECTORY_DERIVE_LOGICAL_COUNT),
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
        .o_req_capture_bad_id(req_capture_bad_id),
        .o_dispatch_fire(dispatch_fire),
        .o_dispatch_push(dispatch_push),
        .o_dispatch_logical_tree_id(dispatch_logical_tree_id),
        .o_selected_physical_tree_id(selected_physical_tree_id),
        .o_dispatch_data(dispatch_data),
        .o_dispatch_source_port(dispatch_source_port),
        .o_dispatch_reject_empty(dispatch_reject_empty),
        .o_dispatch_reject_full(dispatch_reject_full),
        .o_logical_pending_count(logical_pending_count),
        .o_pending_count(pending_count),
        .o_pending_effective_free_count(
            pending_effective_free_count),
        .o_busy(busy),
        .o_pop_valid(pop_valid),
        .o_pop_logical_tree_id(pop_logical_tree_id),
        .o_pop_data(pop_data),
        .o_internal_root_pop_valid(internal_root_pop_valid),
        .o_internal_root_pop_data(internal_root_pop_data),
        .o_protocol_error(protocol_error),
        .o_task_fifo_full(task_fifo_full),
        .o_task_write(task_write),
        .o_task_push(task_push),
        .o_task_pop(task_pop),
        .o_shard_list(shard_list),
        .o_logical_shard_count(logical_shard_count),
        .o_logical_count(logical_count),
        .o_push_rr_ptr(push_rr_ptr),
        .o_shard_count(shard_count),
        .o_shard_head_rank(shard_head_rank),
        .o_shard_empty(shard_empty),
        .o_shard_full(shard_full),
        .o_shard_head_valid(shard_head_valid),
        .o_update_pending(update_pending),
        .o_logical_busy(logical_busy),
        .o_pending_logical_tree_id(pending_logical_tree_id),
        .o_pending_push(pending_push)
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

    // A dispatch-ready candidate must use the cached relation for exactly
    // the same registered primary slots.  This checks both oldest ordering
    // and the reciprocal same-capture provenance used for cross-logical
    // Push/Pop co-issue.
    always @(negedge clk) begin
        if (arst_n) begin
            for (relation_check_source = 0;
                 relation_check_source < LOGICAL_TREE_NUM;
                 relation_check_source = relation_check_source + 1) begin
                for (relation_check_target = 0;
                     relation_check_target < LOGICAL_TREE_NUM;
                     relation_check_target =
                         relation_check_target + 1) begin
                    if (dut.candidate_valid[relation_check_source] &&
                        dut.candidate_valid[relation_check_target]) begin
                        check(dut.candidate_pair_older[
                                  relation_check_source]
                                  [relation_check_target] ==
                               dut.logical_pending.slot_older[
                                  dut.candidate_slot_id[
                                      relation_check_source]]
                                  [dut.candidate_slot_id[
                                      relation_check_target]],
                              "cached candidate age relation is stale");
                        check(dut.candidate_pair_same_event[
                                  relation_check_source]
                                  [relation_check_target] ==
                              (dut.candidate_merge_slots[
                                   relation_check_source]
                                   [dut.candidate_slot_id[
                                       relation_check_target]] &&
                               dut.candidate_merge_slots[
                                   relation_check_target]
                                   [dut.candidate_slot_id[
                                       relation_check_source]]),
                              "cached candidate provenance relation is stale");
                    end
                end
            end
        end
    end

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

    task drive_one_capture;
        input integer port;
        input integer logical_id;
        input push_operation;
        input integer rank;
        input integer tag;
        input integer order_value;
        begin
            @(negedge clk);
            clear_requests();
            req_valid[port] = 1'b1;
            req_push[port] = push_operation;
            logical_tree_id[port] = logical_id[1:0];
            push_data[port] =
                {tag[MTW-1:0], rank[PTW-1:0]};
            req_order[port] = order_value;
            #1;
            check(req_capture_fire[port],
                  "logical request was not captured");
            if (logical_busy[logical_id])
                saw_capture_while_busy = 1'b1;
            @(posedge clk);
            @(negedge clk);
            clear_requests();
        end
    endtask

    task drive_same_logical_pp;
        input integer logical_id;
        input integer rank;
        input integer tag;
        input integer order_value;
        begin
            @(negedge clk);
            clear_requests();
            req_valid = 4'b0011;
            req_push = 4'b0001;
            logical_tree_id[0] = logical_id[1:0];
            logical_tree_id[1] = logical_id[1:0];
            push_data[0] =
                {tag[MTW-1:0], rank[PTW-1:0]};
            req_order[0] = order_value;
            req_order[1] = order_value;
            req_merge_mask[0][1] = 1'b1;
            req_merge_mask[1][0] = 1'b1;
            #1;
            check(req_capture_fire[1:0] == 2'b11,
                  "same-logical P/P pair was not captured");
            @(posedge clk);
            @(negedge clk);
            clear_requests();
        end
    endtask

    task wait_quiescent;
        integer wait_count;
        reg expectations_live;
        begin
            wait_count = 0;
            expectations_live = 1'b1;
            while ((busy || expectations_live) &&
                   (wait_count < 5000)) begin
                @(posedge clk);
                expectations_live = 1'b0;
                for (j = 0; j < LOGICAL_TREE_NUM; j = j + 1)
                    expectations_live =
                        expectations_live |
                        (pop_expected_count[j] != 0);
                wait_count = wait_count + 1;
            end
            check(!busy, "timeout waiting for core quiescence");
            check(!expectations_live,
                  "timeout waiting for Pop results");
        end
    endtask

    task model_add;
        input integer logical_id;
        input [DATA_WIDTH-1:0] data_value;
        begin
            check(model_count[logical_id] < MODEL_DEPTH,
                  "model overflow");
            model_rank[logical_id][model_count[logical_id]] =
                data_value[PTW-1:0];
            model_data[logical_id][model_count[logical_id]] =
                data_value;
            model_count[logical_id] =
                model_count[logical_id] + 1;
        end
    endtask

    task model_pop_dispatch;
        input integer logical_id;
        input prefer_newest_equal;
        integer min_index;
        integer scan;
        begin
            check(model_count[logical_id] > 0,
                  "model Pop underflow at dispatch");
            if (model_count[logical_id] > 0) begin
                min_index = 0;
                for (scan = 1; scan < model_count[logical_id];
                     scan = scan + 1) begin
                    if (model_rank[logical_id][scan] <
                        model_rank[logical_id][min_index] ||
                        (prefer_newest_equal &&
                         (model_rank[logical_id][scan] ==
                          model_rank[logical_id][min_index])))
                        min_index = scan;
                end
                check(pop_expected_count[logical_id] < MODEL_DEPTH,
                      "Pop expectation queue overflow");
                pop_expected_mem[logical_id]
                    [pop_expected_tail[logical_id]] =
                    model_data[logical_id][min_index];
                pop_expected_tail[logical_id] =
                    (pop_expected_tail[logical_id] + 1) %
                    MODEL_DEPTH;
                pop_expected_count[logical_id] =
                    pop_expected_count[logical_id] + 1;
                for (scan = min_index;
                     scan < model_count[logical_id] - 1;
                     scan = scan + 1) begin
                    model_rank[logical_id][scan] =
                        model_rank[logical_id][scan+1];
                    model_data[logical_id][scan] =
                        model_data[logical_id][scan+1];
                end
                model_count[logical_id] =
                    model_count[logical_id] - 1;
            end
        end
    endtask

    task drain_logical;
        input integer logical_id;
        integer drain_order;
        begin
            drain_order = 10000 + logical_id * 100;
            while (model_count[logical_id] != 0) begin
                drive_one_capture(0, logical_id, 1'b0,
                                  0, 0, drain_order);
                drain_order = drain_order + 1;
                wait_quiescent();
            end
        end
    endtask

    always @(posedge clk) begin
        if (!arst_n) begin
            captured_requests = 0;
            retired_pending_requests = 0;
            dispatched_requests = 0;
            expected_engine_completions = 0;
            engine_completions = 0;
            same_logical_pp_dispatches = 0;
            same_logical_pp_push_completions = 0;
            same_logical_pp_pop_completions = 0;
            max_lane_writes_same_cycle = 0;
            multi_lane_cycles = 0;
            same_logical_pp_inflight = 0;
            same_logical_pp_physical_inflight = 0;
            candidate_hold_cycles = 0;
            partner_resolution_cycles = 0;
            max_parallel_partner_resolutions = 0;
            committed_requests = 0;
            allocation_plan_fill_cycles = 0;
            allocation_plan_commit_cycles = 0;
            allocation_stage_overlap_cycles = 0;
            allocation_candidate_overlap_cycles = 0;
            allocation_partner_overlap_cycles = 0;
            previous_candidate_valid = 0;
            previous_candidate_partner_valid = 0;
            expected_registered_retire_mask = 0;
            for (i = 0; i < LOGICAL_TREE_NUM; i = i + 1) begin
                previous_candidate_slot_id[i] = 0;
                previous_candidate_partner_slot_id[i] = 0;
            end
        end else begin
            check(dut.logical_pending.retire_slot_mask ==
                  expected_registered_retire_mask,
                  "retire request was not registered for exactly one cycle");
            actual_retire_slots = 0;
            expected_retire_slots = 0;
            parallel_partner_resolutions = 0;
            for (retire_slot_scan = 0;
                 retire_slot_scan < LOGICAL_PENDING_DEPTH;
                 retire_slot_scan = retire_slot_scan + 1)
                if (dut.logical_pending.retire_request_slot_mask[
                    retire_slot_scan])
                    actual_retire_slots = actual_retire_slots + 1;

            for (i = 0; i < REQUEST_PORTS; i = i + 1)
                if (req_capture_fire[i])
                    captured_requests = captured_requests + 1;
            if (|req_capture_fire)
                allocation_plan_fill_cycles =
                    allocation_plan_fill_cycles + 1;

            plan_lane_count = 0;
            for (i = 0; i < REQUEST_PORTS; i = i + 1)
                if (dut.logical_pending.
                        allocation_plan_lane_valid[i])
                    plan_lane_count = plan_lane_count + 1;
            if (dut.logical_pending.allocation_plan_commit) begin
                allocation_plan_commit_cycles =
                    allocation_plan_commit_cycles + 1;
                committed_requests =
                    committed_requests + plan_lane_count;
                if (|req_capture_fire)
                    allocation_stage_overlap_cycles =
                        allocation_stage_overlap_cycles + 1;
                check((dut.logical_pending.
                           allocation_plan_slot_mask &
                       dut.logical_pending.retire_slot_mask) == 0,
                      "allocation commit overlapped a retire slot");
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
            check(dut.logical_pending.allocation_plan_valid ==
                      (|dut.logical_pending.slot_reserved),
                  "plan-valid and reservation state diverged");
            check((dut.logical_pending.retire_request_slot_mask &
                   dut.logical_pending.slot_reserved) == 0,
                  "reserved slot entered dispatch retirement");

            for (i = 0; i < LOGICAL_TREE_NUM; i = i + 1) begin
                check(!(dut.candidate_partner_resolving[i] &&
                        dut.candidate_dispatch_ready[i]),
                      "candidate is resolving and dispatch-ready together");
                check(!dut.candidate_dispatch_ready[i] ||
                      dut.candidate_primary_valid[i],
                      "dispatch-ready candidate lacks registered primary");
                if (dut.candidate_partner_resolving[i]) begin
                    parallel_partner_resolutions =
                        parallel_partner_resolutions + 1;
                    partner_resolution_cycles =
                        partner_resolution_cycles + 1;
                    check(dut.candidate_primary_valid[i] &&
                          !dispatch_fire[i],
                          "unresolved partner candidate dispatched");
                    check(|dut.candidate_merge_slots[i],
                          "partner resolution started without provenance");
                    check(!dut.candidate_partner_valid[i],
                          "stale partner was visible while resolving");

                    // Independently reproduce the former serial oldest
                    // partner rule.  This checks that the RTL's parallel
                    // eligible/oldest mask is functionally identical across
                    // different slot IDs, capture cycles and live age rows.
                    partner_expected_slot = -1;
                    partner_oldest_count = 0;
                    for (partner_scan_slot = 0;
                         partner_scan_slot < LOGICAL_PENDING_DEPTH;
                         partner_scan_slot = partner_scan_slot + 1) begin
                        if (dut.logical_pending.partner_oldest_slot_mask[i]
                                                                        [partner_scan_slot])
                            partner_oldest_count =
                                partner_oldest_count + 1;
                        if (dut.candidate_merge_slots[i]
                                                       [partner_scan_slot] &&
                            dut.logical_pending.slot_valid[
                                partner_scan_slot] &&
                            !dut.logical_pending.slot_push[
                                partner_scan_slot] &&
                            (dut.logical_pending.slot_logical_id[
                                partner_scan_slot] == i) &&
                            dut.logical_pending.slot_merge_slots[
                                partner_scan_slot]
                                [dut.candidate_slot_id[i]]) begin
                            if (partner_expected_slot < 0)
                                partner_expected_slot =
                                    partner_scan_slot;
                            else if (dut.logical_pending.slot_older[
                                         partner_scan_slot]
                                         [partner_expected_slot])
                                partner_expected_slot =
                                    partner_scan_slot;
                        end
                    end
                    check(partner_oldest_count <= 1,
                          "parallel partner oldest mask is not one-hot");
                    check(dut.pending_partner_resolve_valid[i] ==
                              (partner_expected_slot >= 0),
                          "parallel partner valid differs from serial model");
                    if (partner_expected_slot >= 0)
                        check(dut.pending_partner_resolve_slot_id[i] ==
                                  partner_expected_slot,
                              "parallel partner slot differs from serial model");
                end
                if (previous_candidate_valid[i] &&
                    dut.candidate_valid[i] &&
                    !dispatch_fire[i]) begin
                    check(dut.candidate_slot_id[i] ==
                          previous_candidate_slot_id[i],
                          "waiting candidate primary slot changed");
                    check(dut.candidate_partner_valid[i] ==
                          previous_candidate_partner_valid[i],
                          "waiting candidate partner validity changed");
                    check(dut.candidate_partner_slot_id[i] ==
                          previous_candidate_partner_slot_id[i],
                          "waiting candidate partner slot changed");
                    check(!dut.logical_pending.
                              retire_request_slot_mask[
                                  dut.candidate_slot_id[i]],
                          "stalled candidate primary was retired");
                    if (dut.candidate_partner_valid[i])
                        check(!dut.logical_pending.
                                  retire_request_slot_mask[
                                      dut.candidate_partner_slot_id[
                                          i]],
                              "stalled candidate partner was retired");
                    candidate_hold_cycles = candidate_hold_cycles + 1;
                end

                if (dispatch_fire[i]) begin
                    expected_retire_slots =
                        expected_retire_slots + 1;
                    check(dut.logical_pending.
                              retire_request_slot_mask[
                                  dut.candidate_slot_id[i]],
                          "dispatch did not retire candidate primary slot");
                    dispatch_physical_log[dispatched_requests] =
                        selected_physical_tree_id[i];
                    dispatch_logical_log[dispatched_requests] = i;
                    dispatch_push_log[dispatched_requests] =
                        dispatch_push[i];
                    dispatched_requests = dispatched_requests + 1;
                    if (dut.directory_select_pp[i]) begin
                        expected_retire_slots =
                            expected_retire_slots + 1;
                        check(dut.candidate_partner_valid[i],
                              "P/P dispatch has no registered partner");
                        check(dut.candidate_partner_slot_id[i] !=
                              dut.candidate_slot_id[i],
                              "P/P primary and partner slots are equal");
                        check(dut.logical_pending.
                                  retire_request_slot_mask[
                                      dut.candidate_partner_slot_id[
                                          i]],
                              "P/P dispatch did not retire partner slot");
                        check(dispatch_push[i],
                              "same-logical P/P head is not Push");
                        check(task_push[
                                  selected_physical_tree_id[i] %
                                  LEVEL] &&
                              task_pop[
                                  selected_physical_tree_id[i] %
                                  LEVEL],
                              "same-logical P/P did not form one FIFO word");
                        check(dut.engine_push_tree_id[
                                  selected_physical_tree_id[i] %
                                  LEVEL] ==
                              selected_physical_tree_id[i] &&
                              dut.engine_pop_tree_id[
                                  selected_physical_tree_id[i] %
                                  LEVEL] ==
                              selected_physical_tree_id[i],
                              "same-logical P/P used different physical shards");
                        check(!same_logical_pp_inflight[i],
                              "same logical dispatched overlapping P/P");
                        same_logical_pp_inflight[i] = 1'b1;
                        same_logical_pp_physical_inflight[
                            selected_physical_tree_id[i]] = 1'b1;
                        same_logical_pp_dispatches =
                            same_logical_pp_dispatches + 1;
                        retired_pending_requests =
                            retired_pending_requests + 2;
                        expected_engine_completions =
                            expected_engine_completions + 2;
                        model_add(i, dispatch_data[i]);
                        model_pop_dispatch(i, 1'b1);
                    end else if (dispatch_push[i]) begin
                        if (dut.candidate_partner_valid[i])
                            check(!dut.logical_pending.
                                      retire_request_slot_mask[
                                          dut.candidate_partner_slot_id[
                                              i]],
                                  "fallback Push retired deferred partner");
                        check(!same_logical_pp_inflight[i],
                              "Push penetrated an in-flight P/P");
                        retired_pending_requests =
                            retired_pending_requests + 1;
                        expected_engine_completions =
                            expected_engine_completions + 1;
                        model_add(i, dispatch_data[i]);
                    end else begin
                        check(!same_logical_pp_inflight[i],
                              "Pop penetrated an in-flight P/P");
                        retired_pending_requests =
                            retired_pending_requests + 1;
                        expected_engine_completions =
                            expected_engine_completions + 1;
                        model_pop_dispatch(i, 1'b0);
                    end
                end
                if ((logical_busy[0] ||
                     dut.directory.grant_valid_reg[0]) &&
                    dispatch_fire[i] &&
                    (i != 0))
                    saw_other_logical_dispatch_while_busy = 1'b1;

                previous_candidate_valid[i] =
                    dut.candidate_valid[i];
                previous_candidate_slot_id[i] =
                    dut.candidate_slot_id[i];
                previous_candidate_partner_valid[i] =
                    dut.candidate_partner_valid[i];
                previous_candidate_partner_slot_id[i] =
                    dut.candidate_partner_slot_id[i];
            end

            // The parallel lane arbiter must preserve the former single
            // oldest winner per request class.  A P/P winner is exclusive;
            // otherwise at most one Push and one reciprocal same-event Pop
            // may be selected together on a lane.
            for (i = 0; i < LEVEL; i = i + 1) begin
                pp_winner_count = 0;
                push_winner_count = 0;
                pop_winner_count = 0;
                for (j = 0; j < LOGICAL_TREE_NUM; j = j + 1) begin
                    if (dut.lane_pp_winner[i][j])
                        pp_winner_count = pp_winner_count + 1;
                    if (dut.lane_push_winner[i][j])
                        push_winner_count = push_winner_count + 1;
                    if (dut.lane_pop_winner[i][j])
                        pop_winner_count = pop_winner_count + 1;
                    if (dut.lane_pp_select[i][j] ||
                        dut.lane_push_select[i][j] ||
                        dut.lane_pop_select[i][j]) begin
                        check(dut.directory_select_valid[j],
                              "lane selected an invalid Directory grant");
                        check((dut.directory_physical_tree_id[j] %
                               LEVEL) == i,
                              "lane selected a grant for another lane");
                    end
                end
                check(pp_winner_count <= 1,
                      "parallel arbiter produced multiple P/P winners");
                check(push_winner_count <= 1,
                      "parallel arbiter produced multiple Push winners");
                check(pop_winner_count <= 1,
                      "parallel arbiter produced multiple Pop winners");
                check(!(|dut.lane_pp_select[i]) ||
                      (!(|dut.lane_push_select[i]) &&
                       !(|dut.lane_pop_select[i])),
                      "P/P selection overlapped an ordinary selection");
            end
            if (parallel_partner_resolutions >
                max_parallel_partner_resolutions)
                max_parallel_partner_resolutions =
                    parallel_partner_resolutions;
            if (dut.logical_pending.allocation_plan_commit &&
                (|dut.candidate_primary_valid))
                allocation_candidate_overlap_cycles =
                    allocation_candidate_overlap_cycles + 1;
            if (dut.logical_pending.allocation_plan_commit &&
                (|dut.candidate_partner_resolving))
                allocation_partner_overlap_cycles =
                    allocation_partner_overlap_cycles + 1;
            check(actual_retire_slots == expected_retire_slots,
                  "retire-mask popcount differs from dispatched descriptors");
            if (dispatch_fire == 0)
                check(dut.logical_pending.
                          retire_request_slot_mask == 0,
                      "retire request generated without dispatch");
            expected_registered_retire_mask =
                dut.logical_pending.retire_request_slot_mask;

            lane_count = 0;
            for (i = 0; i < LEVEL; i = i + 1) begin
                if (task_write[i])
                    lane_count = lane_count + 1;
                if (dut.engine_root_update_valid[i]) begin
                    completion_physical_log[engine_completions] =
                        dut.engine_tree_id[i];
                    completion_push_log[engine_completions] =
                        pending_push[dut.engine_tree_id[i]];
                    if (same_logical_pp_physical_inflight[
                            dut.engine_tree_id[i]]) begin
                        if (pending_push[dut.engine_tree_id[i]]) begin
                            same_logical_pp_push_completions =
                                same_logical_pp_push_completions + 1;
                            check(logical_busy[
                                      pending_logical_tree_id[
                                          dut.engine_tree_id[i]]],
                                  "P/P lock was not held at Push completion");
                        end else begin
                            same_logical_pp_pop_completions =
                                same_logical_pp_pop_completions + 1;
                            same_logical_pp_physical_inflight[
                                dut.engine_tree_id[i]] = 1'b0;
                            same_logical_pp_inflight[
                                pending_logical_tree_id[
                                    dut.engine_tree_id[i]]] = 1'b0;
                        end
                    end
                    engine_completions =
                        engine_completions + 1;
                end
            end
            if (lane_count > max_lane_writes_same_cycle)
                max_lane_writes_same_cycle = lane_count;
            if (lane_count >= 2)
                multi_lane_cycles = multi_lane_cycles + 1;

            if (pop_valid) begin
                check(pop_expected_count[pop_logical_tree_id] != 0,
                      "Pop output without expectation");
                if (pop_expected_count[pop_logical_tree_id] != 0) begin
                    if (pop_data !=
                        pop_expected_mem[pop_logical_tree_id]
                            [pop_expected_head[pop_logical_tree_id]])
                        $display("PIFO model mismatch logical=%0d actual=%h expected=%h model_count=%0d at time %0t",
                                 pop_logical_tree_id, pop_data,
                                 pop_expected_mem[pop_logical_tree_id]
                                     [pop_expected_head[
                                         pop_logical_tree_id]],
                                 model_count[pop_logical_tree_id],
                                 $time);
                    check(pop_data ==
                          pop_expected_mem[pop_logical_tree_id]
                              [pop_expected_head[
                                  pop_logical_tree_id]],
                          "Pop output differs from model");
                    pop_expected_head[pop_logical_tree_id] =
                        (pop_expected_head[pop_logical_tree_id] + 1) %
                        MODEL_DEPTH;
                    pop_expected_count[pop_logical_tree_id] =
                        pop_expected_count[pop_logical_tree_id] - 1;
                end
            end

            if (internal_root_pop_valid)
                $fatal(1, "flat core classified logical 0 as internal root");
            if (protocol_error)
                $fatal(1, "HeterogeneousPIFO protocol error");
            if (|task_fifo_full)
                $fatal(1, "controlled test filled TaskFIFO");
        end
    end

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        failures = 0;
        saw_capture_while_busy = 1'b0;
        saw_same_event_pp = 1'b0;
        saw_old_pop_new_push_separate = 1'b0;
        saw_old_push_new_pop_separate = 1'b0;
        saw_equal_tag_separate = 1'b0;
        saw_other_logical_dispatch_while_busy = 1'b0;
        saw_reset_during_partner_resolution = 1'b0;
        saw_capture_during_partner_resolution = 1'b0;
        clear_requests();
        for (i = 0; i < LOGICAL_TREE_NUM; i = i + 1) begin
            model_count[i] = 0;
            pop_expected_head[i] = 0;
            pop_expected_tail[i] = 0;
            pop_expected_count[i] = 0;
            for (j = 0; j < MODEL_DEPTH; j = j + 1) begin
                model_rank[i][j] = 0;
                model_data[i][j] = 0;
                pop_expected_mem[i][j] = 0;
            end
        end

        repeat (5) @(posedge clk);
        arst_n = 1'b1;
        repeat (2) @(posedge clk);
        #1;

        check(shard_list[0][0] == 0 &&
              shard_list[0][1] == 1 &&
              shard_list[0][2] == 2 &&
              shard_list[0][3] == 3 &&
              shard_list[1][0] == 4 &&
              shard_list[2][0] == 5 &&
              shard_list[3][0] == 6,
              "default {4,1,1,1} mapping changed");

        // Reset is allowed to cancel a primary that has entered the dedicated
        // partner-resolution stage.  No unresolved candidate may leak into
        // directory arbitration after reset.
        drive_same_logical_pp(1, 17, 16'h0f00, 0);
        watchdog = 0;
        while (!dut.candidate_partner_resolving[1] &&
               watchdog < 8) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(dut.candidate_partner_resolving[1],
              "reset test never entered partner resolution");
        arst_n = 1'b0;
        clear_requests();
        repeat (2) @(posedge clk);
        #1;
        check(dut.candidate_primary_valid == 0 &&
              dut.candidate_partner_resolving == 0 &&
              dut.candidate_dispatch_ready == 0 &&
              pending_count == 0,
              "reset did not cancel resolving candidate and pending slots");
        saw_reset_during_partner_resolution = 1'b1;
        arst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Capture a younger request for the same logical after stage A has
        // fixed the P/P primary.  The younger request must remain separate and
        // cannot change the registered primary/partner identity.
        drive_same_logical_pp(1, 18, 16'h0f01, 1);
        watchdog = 0;
        while (!dut.candidate_partner_resolving[1] &&
               watchdog < 8) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        check(dut.candidate_partner_resolving[1],
              "capture-during-resolve test never entered stage B");
        @(negedge clk);
        clear_requests();
        req_valid[0] = 1'b1;
        req_push[0] = 1'b1;
        logical_tree_id[0] = 1;
        push_data[0] = {16'h0f02, 16'd19};
        req_order[0] = 2;
        #1;
        check(req_capture_fire[0],
              "same-logical capture was blocked during partner resolution");
        saw_capture_during_partner_resolution = req_capture_fire[0];
        @(posedge clk);
        @(negedge clk);
        clear_requests();
        wait_quiescent();
        drain_logical(1);
        wait_quiescent();

        // Continuous same-logical capture: only the first root Push may
        // dispatch before completion, but all four requests enter the shared
        // pending pool on consecutive cycles.
        drive_one_capture(0, 0, 1'b1, 40, 16'h1000, 1);
        while (!(logical_busy[0] ||
                 dut.directory.grant_valid_reg[0]))
            @(posedge clk);
        @(negedge clk);
        clear_requests();
        req_valid = 4'b0011;
        req_push = 4'b0011;
        logical_tree_id[0] = 0;
        logical_tree_id[1] = 2;
        push_data[0] = {16'h1001, 16'd20};
        push_data[1] = {16'h2000, 16'd7};
        req_order[0] = 2;
        req_order[1] = 2;
        #1;
        check((logical_busy[0] ||
               dut.directory.grant_valid_reg[0]) &&
              req_capture_fire[1:0] == 2'b11,
              "busy root and unrelated leaf were not captured together");
        saw_capture_while_busy = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear_requests();
        watchdog = 0;
        while (!((logical_busy[0] ||
                  dut.directory.grant_valid_reg[0]) &&
                 dispatch_fire[2]) &&
               watchdog < 8) begin
            @(posedge clk);
            @(negedge clk);
            #1;
            watchdog = watchdog + 1;
        end
        check((logical_busy[0] ||
               dut.directory.grant_valid_reg[0]) &&
              dispatch_fire[2],
              "unrelated logical did not dispatch while root was busy");
        if ((logical_busy[0] ||
             dut.directory.grant_valid_reg[0]) &&
            dispatch_fire[2])
            saw_other_logical_dispatch_while_busy = 1'b1;
        drive_one_capture(0, 0, 1'b1, 20, 16'h1002, 3);
        drive_one_capture(0, 0, 1'b1, 50, 16'h1003, 4);
        check(saw_capture_while_busy,
              "logical_busy incorrectly blocked logical capture");

        // A request for another logical is captured and dispatched while root
        // logical 0 still has an operation in flight.
        drive_one_capture(1, 2, 1'b1, 3, 16'h2001, 6);
        wait_quiescent();
        check(saw_other_logical_dispatch_while_busy,
              "busy logical blocked an unrelated logical dispatch");
        check(shard_count[0] == 1 && shard_count[1] == 1 &&
              shard_count[2] == 1 && shard_count[3] == 1,
              "root Pushes did not rotate across four shards");

        // Explicit multi-lane capture and dispatch.
        @(negedge clk);
        clear_requests();
        req_valid = 4'b0011;
        req_push = 4'b0011;
        logical_tree_id[0] = 1; // physical 4 -> lane 0
        logical_tree_id[1] = 2; // physical 5 -> lane 1
        push_data[0] = {16'h4100, 16'd13};
        push_data[1] = {16'h2200, 16'd11};
        req_order[0] = 20;
        req_order[1] = 20;
        #1;
        check(req_capture_fire[1:0] == 2'b11,
              "two logical requests were not captured together");
        @(posedge clk);
        @(negedge clk);
        clear_requests();
        watchdog = 0;
        while (task_write[1:0] != 2'b11 &&
               watchdog < 8) begin
            @(posedge clk);
            @(negedge clk);
            #1;
            watchdog = watchdog + 1;
        end
        check(task_write[1:0] == 2'b11,
              "different lanes did not receive two TaskFIFO words");
        @(posedge clk);
        wait_quiescent();

        // Two same-logical Pops are captured back-to-back.  The second remains
        // pending until completion updates Head/count, then must select the
        // other equal-rank shard by physical-ID tie-break.
        log_start = dispatched_requests;
        drive_one_capture(0, 0, 1'b0, 0, 0, 30);
        drive_one_capture(0, 0, 1'b0, 0, 0, 31);
        wait_quiescent();
        check(dispatched_requests >= log_start + 2,
              "two queued root Pops did not dispatch");
        if (dispatched_requests >= log_start + 2) begin
            $display("Queued root Pop physical sequence: %0d, %0d",
                     dispatch_physical_log[log_start],
                     dispatch_physical_log[log_start+1]);
            check(dispatch_physical_log[log_start] == 1,
                  "first equal-rank Pop tie-break was not physical 1");
            check(dispatch_physical_log[log_start+1] == 2,
                  "second Pop reused stale Head instead of physical 2");
        end

        // Same-generation Push/Pop to one lane may form one original P/P word.
        // logical 1 -> physical 4/lane 0, root Pop -> physical 0/lane 0.
        completion_start = engine_completions;
        @(negedge clk);
        clear_requests();
        req_valid = 4'b0011;
        req_push = 4'b0001;
        logical_tree_id[0] = 1;
        logical_tree_id[1] = 0;
        push_data[0] = {16'h4101, 16'd9};
        req_order[0] = 40;
        req_order[1] = 40;
        req_merge_mask[0][1] = 1'b1;
        req_merge_mask[1][0] = 1'b1;
        #1;
        check(req_capture_fire[1:0] == 2'b11,
              "same-event P/P pair was not captured");
        @(posedge clk);
        @(negedge clk);
        clear_requests();
        watchdog = 0;
        while (!(task_write == 4'b0001 &&
                 task_push[0] && task_pop[0]) &&
               watchdog < 8) begin
            @(posedge clk);
            @(negedge clk);
            #1;
            watchdog = watchdog + 1;
        end
        check(task_write == 4'b0001 &&
              task_push[0] && task_pop[0],
              "same-event same-lane requests did not form P/P");
        saw_same_event_pp = 1'b1;
        @(posedge clk);
        wait_quiescent();
        check(engine_completions >= completion_start + 2,
              "P/P word did not produce two completions");
        if (engine_completions >= completion_start + 2) begin
            check(completion_push_log[completion_start],
                  "P/P did not execute Push first");
            check(!completion_push_log[completion_start+1],
                  "P/P did not execute Pop second");
        end

        // Older Pop, younger Push, same lane: different capture edges must
        // produce separate TaskFIFO words, Pop first.
        log_start = dispatched_requests;
        drive_one_capture(0, 1, 1'b0, 0, 0, 50);
        drive_one_capture(1, 0, 1'b1, 61, 16'h5000, 51);
        wait_quiescent();
        check(dispatched_requests >= log_start + 2,
              "older Pop / younger Push did not both dispatch");
        if (dispatched_requests >= log_start + 2) begin
            check(!dispatch_push_log[log_start] &&
                  dispatch_logical_log[log_start] == 1,
                  "older Pop did not dispatch first");
            check(dispatch_push_log[log_start+1] &&
                  dispatch_logical_log[log_start+1] == 0,
                  "younger Push did not remain separate");
        end
        saw_old_pop_new_push_separate = 1'b1;

        // Older root Push (next RR physical 1/lane 1), younger logical-2 Pop
        // (physical 5/lane 1): again preserve capture age.
        log_start = dispatched_requests;
        drive_one_capture(0, 0, 1'b1, 62, 16'h5001, 60);
        drive_one_capture(1, 2, 1'b0, 0, 0, 61);
        wait_quiescent();
        check(dispatched_requests >= log_start + 2,
              "older Push / younger Pop did not both dispatch");
        if (dispatched_requests >= log_start + 2) begin
            check(dispatch_push_log[log_start] &&
                  dispatch_logical_log[log_start] == 0,
                  "older Push did not dispatch first");
            check(!dispatch_push_log[log_start+1] &&
                  dispatch_logical_log[log_start+1] == 2,
                  "younger Pop did not remain separate");
        end
        saw_old_push_new_pop_separate = 1'b1;

        // Preload logical 3, then present unrelated equal-tag Pop/Push on the
        // same lane without a merge relation.  Concrete slot provenance keeps
        // them as two FIFO words.
        drive_one_capture(0, 3, 1'b1, 8, 16'h3000, 70);
        wait_quiescent();
        log_start = dispatched_requests;
        @(negedge clk);
        clear_requests();
        req_valid = 4'b0011;
        req_push = 4'b0010;
        logical_tree_id[0] = 3; // Pop, physical 6/lane 2
        logical_tree_id[1] = 0; // Push, next RR physical 2/lane 2
        push_data[1] = {16'h5002, 16'd63};
        req_order[0] = 32'hffff_fffe;
        req_order[1] = 32'hffff_fffe;
        #1;
        check(req_capture_fire[1:0] == 2'b11,
              "equal-tag unrelated requests were not captured");
        @(posedge clk);
        @(negedge clk);
        clear_requests();
        watchdog = 0;
        while (!(task_pop[2] && !task_push[2]) &&
               watchdog < 8) begin
            @(posedge clk);
            @(negedge clk);
            #1;
            watchdog = watchdog + 1;
        end
        check(task_pop[2] && !task_push[2],
              "unrelated equal-tag operations were incorrectly merged");
        @(posedge clk);
        wait_quiescent();
        check(dispatched_requests >= log_start + 2 &&
              !dispatch_push_log[log_start] &&
              dispatch_push_log[log_start+1],
              "equal-tag operations did not remain separate and ordered");
        saw_equal_tag_separate = 1'b1;

        // Directed same-logical P/P coverage uses logical 1, which has one
        // physical shard (physical 4 / lane 0).  Start from an empty tree.
        drain_logical(1);
        wait_quiescent();
        check(logical_count[1] == 0 && shard_empty[4],
              "logical 1 did not reach empty before P/P tests");

        // Empty P/P must return the just-pushed element and leave both the
        // logical and physical counts at zero.
        drive_same_logical_pp(1, 11, 16'h6100, 80);
        watchdog = 0;
        while (!(task_write[0] && task_push[0] && task_pop[0]) &&
               watchdog < 8) begin
            @(posedge clk);
            @(negedge clk);
            #1;
            watchdog = watchdog + 1;
        end
        check(task_write[0] && task_push[0] && task_pop[0],
              "empty same-logical P/P was not one TaskFIFO word");
        wait_quiescent();
        check(logical_count[1] == 0 &&
              shard_count[4] == 0 &&
              shard_empty[4] &&
              !shard_head_valid[4],
              "empty P/P did not leave the shard empty");

        // Less-than-current-Head: the new element is pushed first and is the
        // element popped by the second phase.  Existing Head remains.
        drive_one_capture(0, 1, 1'b1, 20, 16'h6200, 81);
        wait_quiescent();
        drive_same_logical_pp(1, 10, 16'h6201, 82);
        watchdog = 0;
        while (!(task_write[0] && task_push[0] && task_pop[0]) &&
               watchdog < 8) begin
            @(posedge clk);
            @(negedge clk);
            #1;
            watchdog = watchdog + 1;
        end
        check(task_write[0] && task_push[0] && task_pop[0],
              "rank-less same-logical P/P was not one word");
        wait_quiescent();
        check(logical_count[1] == 1 &&
              shard_count[4] == 1 &&
              shard_head_rank[4] == 20,
              "rank-less P/P changed the surviving Head/count");

        // Greater-than-current-Head: the old Head is popped and the pushed
        // element becomes the new Head.
        drive_same_logical_pp(1, 30, 16'h6202, 83);
        wait_quiescent();
        check(logical_count[1] == 1 &&
              shard_count[4] == 1 &&
              shard_head_rank[4] == 30,
              "rank-greater P/P did not install the pushed Head");

        // Equal rank follows the original strict-less BMW comparison: the
        // previously resident element is popped and the new equal-rank item
        // remains, while the directory rank/count stay unchanged.
        drive_same_logical_pp(1, 30, 16'h6203, 84);
        wait_quiescent();
        check(logical_count[1] == 1 &&
              shard_count[4] == 1 &&
              shard_head_rank[4] == 30,
              "equal-rank P/P changed Head/count");

        // Capture the next request for the same logical while its compound
        // word is in flight, together with an unrelated logical.  The former
        // remains pending until final Pop completion; the latter may dispatch.
        drive_same_logical_pp(1, 25, 16'h6204, 85);
        while (!logical_busy[1])
            @(posedge clk);
        @(negedge clk);
        clear_requests();
        req_valid = 4'b0011;
        req_push = 4'b0011;
        logical_tree_id[0] = 1;
        logical_tree_id[1] = 2;
        push_data[0] = {16'h6205, 16'd40};
        push_data[1] = {16'h2201, 16'd6};
        req_order[0] = 86;
        req_order[1] = 86;
        #1;
        check((logical_busy[1] ||
               dut.directory.grant_valid_reg[1]) &&
              req_capture_fire[1:0] == 2'b11,
              "requests were not captured during same-logical P/P");
        @(posedge clk);
        @(negedge clk);
        clear_requests();
        watchdog = 0;
        while (!((logical_busy[1] ||
                  dut.directory.grant_valid_reg[1]) &&
                 dispatch_fire[2]) &&
               watchdog < 8) begin
            @(posedge clk);
            @(negedge clk);
            #1;
            watchdog = watchdog + 1;
        end
        check((logical_busy[1] ||
               dut.directory.grant_valid_reg[1]) &&
              dispatch_fire[2],
              "busy P/P logical blocked an unrelated logical");
        @(posedge clk);
        wait_quiescent();
        check(logical_count[1] == 2 &&
              shard_count[4] == 2 &&
              shard_head_rank[4] == 30,
              "request after P/P observed intermediate directory state");

        drain_logical(0);
        drain_logical(1);
        drain_logical(2);
        drain_logical(3);
        wait_quiescent();

        check(max_lane_writes_same_cycle >= 2 &&
              multi_lane_cycles > 0,
              "no multi-lane physical TaskFIFO injection observed");
        check(saw_same_event_pp,
              "same-event P/P behavior not covered");
        check(saw_old_pop_new_push_separate,
              "older Pop / younger Push separation not covered");
        check(saw_old_push_new_pop_separate,
              "older Push / younger Pop separation not covered");
        check(saw_equal_tag_separate,
              "slot-provenance merge guard not covered");
        check(same_logical_pp_dispatches >= 5,
              "directed same-logical P/P dispatches not covered");
        check(same_logical_pp_push_completions ==
              same_logical_pp_dispatches &&
              same_logical_pp_pop_completions ==
              same_logical_pp_dispatches,
              "same-logical P/P phase completion counts differ");
        check(candidate_hold_cycles > 0,
              "no candidate retirement descriptor was held under stall");
        check(partner_resolution_cycles > 0,
              "partner resolution stage was not exercised");
        check(saw_reset_during_partner_resolution,
              "reset during partner resolution was not covered");
        check(saw_capture_during_partner_resolution,
              "same-logical capture during partner resolution not covered");
        check(captured_requests == retired_pending_requests,
              "capture/pending-retirement counts differ after drain");
        check(captured_requests == committed_requests,
              "capture/allocation-commit counts differ after drain");
        check(expected_engine_completions == engine_completions,
              "expected/actual engine completion counts differ");
        check(pending_count == 0,
              "logical pending pool did not drain");
        for (i = 0; i < LOGICAL_TREE_NUM; i = i + 1)
            check(model_count[i] == 0 &&
                  pop_expected_count[i] == 0 &&
                  logical_count[i] == 0 &&
                  logical_pending_count[i] == 0 &&
                  !logical_busy[i],
                  "logical state did not drain");
        for (i = 0; i < PHYSICAL_TREE_NUM; i = i + 1)
            check(shard_count[i] == 0 &&
                  !update_pending[i],
                  "physical state did not drain");
        check(!protocol_error, "final protocol error");

        $display("Pending/vector stats: captured=%0d committed=%0d retired=%0d dispatched=%0d expected_completions=%0d completions=%0d same_logical_pp=%0d pp_push_completions=%0d pp_pop_completions=%0d max_lane_writes=%0d multi_lane_cycles=%0d capture_while_busy=%0d plan_fill_cycles=%0d plan_commit_cycles=%0d stage_a_b_overlap_cycles=%0d candidate_commit_overlap_cycles=%0d partner_commit_overlap_cycles=%0d partner_resolution_cycles=%0d max_parallel_partner_resolutions=%0d",
                 captured_requests, committed_requests,
                 retired_pending_requests,
                 dispatched_requests, expected_engine_completions,
                 engine_completions, same_logical_pp_dispatches,
                 same_logical_pp_push_completions,
                 same_logical_pp_pop_completions,
                 max_lane_writes_same_cycle, multi_lane_cycles,
                 saw_capture_while_busy,
                 allocation_plan_fill_cycles,
                 allocation_plan_commit_cycles,
                 allocation_stage_overlap_cycles,
                 allocation_candidate_overlap_cycles,
                 allocation_partner_overlap_cycles,
                 partner_resolution_cycles,
                 max_parallel_partner_resolutions);
        if (failures == 0)
            $display("PASS: HeterogeneousPIFO_tb");
        else
            $fatal(1, "HeterogeneousPIFO_tb failures=%0d",
                   failures);
        $finish;
    end
endmodule
