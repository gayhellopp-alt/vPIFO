`timescale 1ns / 1ps

module LogicalRequestBuffer_tb;
    localparam DATA_WIDTH = 32;
    localparam LOGICAL_TREE_NUM = 2;
    localparam REQUEST_PORTS = 2;
    localparam ORDER_WIDTH = 8;
    localparam DEPTH = 4;
    localparam SLOT_ID_WIDTH = $clog2(DEPTH);
    localparam COUNT_WIDTH = $clog2(DEPTH + 1);

    reg clk;
    reg arst_n;
    reg [REQUEST_PORTS-1:0] req_valid;
    reg [REQUEST_PORTS-1:0] req_push;
    reg logical_tree_id [0:REQUEST_PORTS-1];
    reg [DATA_WIDTH-1:0] push_data [0:REQUEST_PORTS-1];
    reg [ORDER_WIDTH-1:0] req_order [0:REQUEST_PORTS-1];
    reg [REQUEST_PORTS-1:0] req_merge_mask [0:REQUEST_PORTS-1];
    reg [LOGICAL_TREE_NUM-1:0] retire_valid;
    reg [SLOT_ID_WIDTH-1:0]
        retire_primary_slot_id [0:LOGICAL_TREE_NUM-1];
    reg [LOGICAL_TREE_NUM-1:0] retire_partner_valid;
    reg [SLOT_ID_WIDTH-1:0]
        retire_partner_slot_id [0:LOGICAL_TREE_NUM-1];
    reg [LOGICAL_TREE_NUM-1:0] partner_resolve_valid;
    reg [LOGICAL_TREE_NUM-1:0] partner_resolve_primary_push;
    reg [SLOT_ID_WIDTH-1:0]
        partner_resolve_primary_slot_id [0:LOGICAL_TREE_NUM-1];
    reg [DEPTH-1:0]
        partner_resolve_primary_merge_slots [0:LOGICAL_TREE_NUM-1];

    wire [REQUEST_PORTS-1:0] req_ready;
    wire [REQUEST_PORTS-1:0] capture_fire;
    wire [REQUEST_PORTS-1:0] bad_id;
    wire [LOGICAL_TREE_NUM-1:0] head_valid;
    wire [LOGICAL_TREE_NUM-1:0] head_push;
    wire [DATA_WIDTH-1:0] head_push_data [0:LOGICAL_TREE_NUM-1];
    wire [ORDER_WIDTH-1:0] head_order [0:LOGICAL_TREE_NUM-1];
    wire head_source_port [0:LOGICAL_TREE_NUM-1];
    wire [1:0] head_slot_id [0:LOGICAL_TREE_NUM-1];
    wire [DEPTH-1:0] head_merge_slots [0:LOGICAL_TREE_NUM-1];
    wire [LOGICAL_TREE_NUM-1:0]
        head_pair_older [0:LOGICAL_TREE_NUM-1];
    wire [LOGICAL_TREE_NUM-1:0]
        head_pair_same_event [0:LOGICAL_TREE_NUM-1];
    wire [LOGICAL_TREE_NUM-1:0] partner_resolve_result_valid;
    wire [SLOT_ID_WIDTH-1:0]
        partner_resolve_result_slot_id [0:LOGICAL_TREE_NUM-1];
    wire [COUNT_WIDTH-1:0]
        logical_pending_count [0:LOGICAL_TREE_NUM-1];
    wire [COUNT_WIDTH-1:0] pending_count;
    wire [COUNT_WIDTH-1:0] effective_free_count;
    wire full;
    wire [DEPTH-1:0] slot_older [0:DEPTH-1];
    wire protocol_error;

    integer failures;
    integer i;

    LogicalRequestBuffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .REQUEST_PORTS(REQUEST_PORTS),
        .ORDER_WIDTH(ORDER_WIDTH),
        .DEPTH(DEPTH)
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
        .o_req_ready(req_ready),
        .o_req_capture_fire(capture_fire),
        .o_req_bad_id(bad_id),
        .i_retire_valid(retire_valid),
        .i_retire_primary_slot_id(retire_primary_slot_id),
        .i_retire_partner_valid(retire_partner_valid),
        .i_retire_partner_slot_id(retire_partner_slot_id),
        .o_head_valid(head_valid),
        .o_head_push(head_push),
        .o_head_push_data(head_push_data),
        .o_head_order(head_order),
        .o_head_source_port(head_source_port),
        .o_head_slot_id(head_slot_id),
        .o_head_merge_slots(head_merge_slots),
        .o_head_pair_older(head_pair_older),
        .o_head_pair_same_event(head_pair_same_event),
        .o_head_first_older(),
        .o_head_pair_same_event_state(),
        .i_partner_resolve_valid(partner_resolve_valid),
        .i_partner_resolve_primary_push(
            partner_resolve_primary_push),
        .i_partner_resolve_primary_slot_id(
            partner_resolve_primary_slot_id),
        .i_partner_resolve_primary_merge_slots(
            partner_resolve_primary_merge_slots),
        .o_partner_resolve_valid(
            partner_resolve_result_valid),
        .o_partner_resolve_slot_id(
            partner_resolve_result_slot_id),
        .o_logical_pending_count(logical_pending_count),
        .o_pending_count(pending_count),
        .o_effective_free_count(effective_free_count),
        .o_full(full),
        .o_slot_older(slot_older),
        .o_protocol_error(protocol_error)
    );

    always #5 clk = ~clk;

    integer relation_source;
    integer relation_target;
    always @(negedge clk) begin
        if (arst_n) begin
            for (relation_source = 0;
                 relation_source < LOGICAL_TREE_NUM;
                 relation_source = relation_source + 1) begin
                for (relation_target = 0;
                     relation_target < LOGICAL_TREE_NUM;
                     relation_target = relation_target + 1) begin
                    if (head_valid[relation_source] &&
                        head_valid[relation_target]) begin
                        check(head_pair_older[relation_source]
                                  [relation_target] ==
                              slot_older[head_slot_id[relation_source]]
                                  [head_slot_id[relation_target]],
                              "head-to-head age relation mismatch");
                        check(head_pair_same_event[relation_source]
                                  [relation_target] ==
                              (head_merge_slots[relation_source]
                                   [head_slot_id[relation_target]] &&
                               head_merge_slots[relation_target]
                                   [head_slot_id[relation_source]]),
                              "head-to-head provenance relation mismatch");
                    end
                end
            end
        end
    end

    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s at time %0t", message, $time);
                failures = failures + 1;
            end
        end
    endtask

    task clear_inputs;
        begin
            req_valid = 0;
            req_push = 0;
            retire_valid = 0;
            retire_partner_valid = 0;
            partner_resolve_valid = 0;
            partner_resolve_primary_push = 0;
            for (i = 0; i < REQUEST_PORTS; i = i + 1) begin
                logical_tree_id[i] = 0;
                push_data[i] = 0;
                req_order[i] = 0;
                req_merge_mask[i] = 0;
            end
            for (i = 0; i < LOGICAL_TREE_NUM; i = i + 1) begin
                retire_primary_slot_id[i] = 0;
                retire_partner_slot_id[i] = 0;
                partner_resolve_primary_slot_id[i] = 0;
                partner_resolve_primary_merge_slots[i] = 0;
            end
        end
    endtask

    initial begin
        clk = 0;
        arst_n = 0;
        failures = 0;
        clear_inputs();
        repeat (3) @(posedge clk);
        arst_n = 1;

        // Fill all four slots in two cycles.
        @(negedge clk);
        req_valid = 2'b11;
        req_push = 2'b11;
        push_data[0] = 32'h0000_0010;
        push_data[1] = 32'h0000_0011;
        req_order[0] = 8'hfe;
        req_order[1] = 8'hff;
        #1;
        check(capture_fire == 2'b11,
              "first two requests were not captured");
        @(posedge clk);
        @(negedge clk);
        #1;
        check(dut.allocation_plan_valid &&
              dut.allocation_plan_lane_valid == 2'b11 &&
              dut.slot_reserved == 4'b0011 &&
              dut.slot_valid == 4'b0000,
              "first allocation plan/reservation was not registered");
        push_data[0] = 32'h0000_0012;
        push_data[1] = 32'h0000_0013;
        req_order[0] = 8'h00;
        req_order[1] = 8'h01;
        #1;
        check(capture_fire == 2'b11,
              "second two requests were not captured across order wrap");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        #1;
        check(dut.allocation_plan_valid &&
              dut.slot_valid == 4'b0011 &&
              dut.slot_reserved == 4'b1100 &&
              dut.allocation_plan_base_older_mask == 4'b0011 &&
              !(|(dut.slot_valid & dut.slot_reserved)),
              "plan fill did not overlap preceding commit safely");
        check(dut.allocation_plan_slot[0] !=
                  dut.allocation_plan_slot[1] &&
              dut.slot_older[0][1] &&
              !dut.slot_older[1][0] &&
              dut.slot_older[2] == 0 &&
              dut.slot_older[3] == 0,
              "first commit or second-plan uniqueness was incorrect");
        check(full && pending_count == 4 &&
              head_push_data[0] == 32'h0000_0010,
              "exact age order was not preserved across order wrap");

        // Full + dispatch + capture: retirement is staged and the retiring
        // slot is deliberately not exposed to capture in the dispatch cycle.
        retire_valid[0] = 1'b1;
        retire_primary_slot_id[0] = head_slot_id[0];
        req_valid[0] = 1'b1;
        req_push[0] = 1'b0;
        logical_tree_id[0] = 1'b1;
        push_data[0] = 32'hdead_beef;
        req_order[0] = 8'h02;
        #1;
        check(effective_free_count == 0 &&
              !capture_fire[0] && !req_ready[0],
              "dispatch cycle exposed a retiring slot to capture");
        check(dut.retire_request_slot_mask == 4'b0001,
              "ordinary Push did not request exactly slot 0 retirement");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        #1;
        check(pending_count == 4 && full,
              "registered retirement changed occupancy too early");
        check(dut.slot_push_data[2] == 32'h0000_0012 &&
              dut.slot_push_data[3] == 32'h0000_0013 &&
              dut.slot_order[2] == 8'h00 &&
              dut.slot_order[3] == 8'h01 &&
              dut.slot_source_port[2] == 0 &&
              dut.slot_source_port[3] == 1,
              "commit descriptor did not match accepted request");
        check(dut.slot_older[0][2] &&
              dut.slot_older[0][3] &&
              dut.slot_older[1][2] &&
              dut.slot_older[1][3] &&
              dut.slot_older[2][3] &&
              !dut.slot_older[2][0] &&
              !dut.slot_older[3][0] &&
              !dut.slot_older[3][2],
              "registered plan changed the stage4 age matrix semantics");
        @(posedge clk);
        @(negedge clk);
        #1;
        check(pending_count == 3 && !full &&
              effective_free_count == 1,
              "registered retirement did not release exactly one slot");
        check(head_push_data[0] == 32'h0000_0011,
              "oldest surviving request changed");

        req_valid[0] = 1'b1;
        req_push[0] = 1'b0;
        logical_tree_id[0] = 1'b1;
        push_data[0] = 32'hdead_beef;
        req_order[0] = 8'h02;
        #1;
        check(capture_fire[0],
              "request was not captured after retirement committed");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        #1;
        check(pending_count == 4 && full,
              "post-retirement capture did not restore occupancy");
        check(dut.allocation_plan_valid &&
              dut.slot_reserved == 4'b0001 &&
              !dut.slot_valid[0],
              "replacement request did not remain reserved before commit");
        @(posedge clk);
        @(negedge clk);
        #1;
        check(head_valid[1] && !head_push[1] &&
              head_push_data[1] == 32'hdead_beef,
              "replacement request was not captured");

        // Put an ordinary Pop in the highest-numbered slot, hold its
        // retirement descriptor inactive for several cycles, then dispatch
        // it by registered slot ID.  No live-head activity may create a
        // retire request while retire_valid is low.
        arst_n = 0;
        repeat (2) @(posedge clk);
        arst_n = 1;
        @(negedge clk);
        clear_inputs();
        req_valid = 2'b11;
        req_push = 2'b11;
        logical_tree_id[0] = 0;
        logical_tree_id[1] = 0;
        push_data[0] = 32'h0000_0100;
        push_data[1] = 32'h0000_0101;
        #1;
        check(capture_fire == 2'b11,
              "boundary setup did not fill slots 0 and 1");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        req_valid = 2'b11;
        req_push = 2'b01;
        logical_tree_id[0] = 0;
        logical_tree_id[1] = 1;
        push_data[0] = 32'h0000_0102;
        push_data[1] = 32'h0000_01ff;
        #1;
        check(capture_fire == 2'b11,
              "boundary setup did not fill slots 2 and 3");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        #1;
        check(dut.slot_valid == 4'b0011 &&
              dut.slot_reserved == 4'b1100,
              "back-to-back full-lane plans did not overlap");
        @(posedge clk);
        @(negedge clk);
        #1;
        check(full && head_valid[1] && !head_push[1] &&
              head_slot_id[1] == SLOT_ID_WIDTH'(DEPTH - 1),
              "ordinary Pop was not placed at the highest slot");
        repeat (3) begin
            check(dut.retire_request_slot_mask == 0 &&
                  dut.retire_slot_mask == 0 &&
                  pending_count == DEPTH,
                  "inactive descriptor changed pending state");
            @(posedge clk);
            @(negedge clk);
            #1;
        end
        check(head_slot_id[1] == SLOT_ID_WIDTH'(DEPTH - 1),
              "waiting candidate retirement identity changed");
        retire_valid[1] = 1'b1;
        retire_primary_slot_id[1] = head_slot_id[1];
        #1;
        check(dut.retire_request_slot_mask == 4'b1000,
              "ordinary Pop did not request exactly the highest slot");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        #1;
        check(pending_count == DEPTH &&
              dut.retire_slot_mask == 4'b1000,
              "ordinary Pop retirement was not staged");
        @(posedge clk);
        @(negedge clk);
        #1;
        check(pending_count == DEPTH - 1 &&
              logical_pending_count[1] == 0 &&
              logical_pending_count[0] == DEPTH - 1,
              "ordinary Pop did not retire exactly one boundary slot");
        check(!protocol_error,
              "valid delayed ordinary Pop raised protocol error");

        // Drain and reset to test concrete same-generation provenance.
        arst_n = 0;
        repeat (2) @(posedge clk);
        arst_n = 1;
        @(negedge clk);
        clear_inputs();
        req_valid = 2'b11;
        req_push = 2'b01;
        logical_tree_id[0] = 0;
        logical_tree_id[1] = 1;
        req_order[0] = 8'h7f;
        req_order[1] = 8'h7f;
        req_merge_mask[0][1] = 1'b1;
        req_merge_mask[1][0] = 1'b1;
        #1;
        check(capture_fire == 2'b11,
              "same-generation pair was not captured");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        #1;
        check(dut.allocation_plan_valid &&
              dut.slot_reserved == 4'b0011 &&
              dut.slot_valid == 0 &&
              dut.allocation_plan_merge_lane_mask[0] == 2'b10 &&
              dut.allocation_plan_merge_lane_mask[1] == 2'b01 &&
              dut.allocation_plan_base_older_mask == 0,
              "provenance plan was not reserved before commit");
        @(posedge clk);
        @(negedge clk);
        #1;
        check(head_merge_slots[0][head_slot_id[1]] &&
              head_merge_slots[1][head_slot_id[0]],
              "same-generation slot provenance was not reciprocal");

        // Reciprocal same-capture Push/Pop for one logical becomes one
        // compound head.  Even with the Pop on the lower-numbered port, the
        // exposed head is normalized to Push and pair dequeue retires exactly
        // the two related slots.
        arst_n = 0;
        repeat (2) @(posedge clk);
        arst_n = 1;
        @(negedge clk);
        clear_inputs();
        req_valid = 2'b11;
        req_push = 2'b10;
        logical_tree_id[0] = 0;
        logical_tree_id[1] = 0;
        push_data[1] = 32'hcafe_0011;
        req_order[0] = 8'h80;
        req_order[1] = 8'h80;
        req_merge_mask[0][1] = 1'b1;
        req_merge_mask[1][0] = 1'b1;
        #1;
        check(capture_fire == 2'b11,
              "same-logical P/P was not captured");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        #1;
        check(dut.allocation_plan_valid &&
              dut.slot_reserved == 4'b0011 &&
              dut.slot_valid == 0 &&
              dut.allocation_plan_merge_lane_mask[0] == 2'b10 &&
              dut.allocation_plan_merge_lane_mask[1] == 2'b01,
              "same-logical P/P plan was not reserved before commit");
        @(posedge clk);
        @(negedge clk);
        #1;
        check(head_valid[0] && head_push[0] &&
              head_push_data[0] == 32'hcafe_0011,
              "same-logical P/P head was not normalized to Push");
        partner_resolve_valid[0] = 1'b1;
        partner_resolve_primary_push[0] = head_push[0];
        partner_resolve_primary_slot_id[0] = head_slot_id[0];
        partner_resolve_primary_merge_slots[0] =
            head_merge_slots[0];
        #1;
        check(partner_resolve_result_valid[0] &&
              partner_resolve_result_slot_id[0] !=
                  head_slot_id[0],
              "registered primary did not resolve reciprocal partner");
        retire_valid[0] = 1'b1;
        retire_primary_slot_id[0] = head_slot_id[0];
        retire_partner_valid[0] = 1'b1;
        retire_partner_slot_id[0] =
            partner_resolve_result_slot_id[0];
        #1;
        check(dut.retire_request_slot_mask ==
              ((4'b0001 << head_slot_id[0]) |
               (4'b0001 << partner_resolve_result_slot_id[0])),
              "compound descriptor did not request exactly two slots");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        #1;
        check(pending_count == 2 && head_valid[0],
              "compound retirement was not staged for one cycle");
        @(posedge clk);
        @(negedge clk);
        #1;
        check(pending_count == 0 && !head_valid[0],
              "compound dequeue did not retire both pending slots");

        // Same numeric order without provenance is not mergeable.
        arst_n = 0;
        repeat (2) @(posedge clk);
        arst_n = 1;
        @(negedge clk);
        clear_inputs();
        req_valid = 2'b11;
        req_push = 2'b01;
        logical_tree_id[0] = 0;
        logical_tree_id[1] = 1;
        req_order[0] = 8'h00;
        req_order[1] = 8'h00;
        #1;
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        #1;
        @(posedge clk);
        @(negedge clk);
        #1;
        check(!head_merge_slots[0][head_slot_id[1]] &&
              !head_merge_slots[1][head_slot_id[0]],
              "equal order tags created false provenance");
        check(!protocol_error, "pending buffer protocol error");

        // An impossible registered P/P descriptor must be diagnosed after the
        // registered check reaches the pre-retirement state.  Slot 3 is empty,
        // so this must not corrupt or retire any unrelated live request.
        arst_n = 0;
        repeat (2) @(posedge clk);
        arst_n = 1;
        @(negedge clk);
        clear_inputs();
        req_valid[0] = 1'b1;
        req_push[0] = 1'b1;
        logical_tree_id[0] = 0;
        push_data[0] = 32'hbad0_0000;
        #1;
        check(capture_fire[0],
              "invalid-partner setup Push was not captured");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        #1;
        check(dut.allocation_plan_valid &&
              dut.slot_reserved == 4'b0001 &&
              dut.slot_valid == 0,
              "invalid-partner setup plan was not reserved");
        @(posedge clk);
        @(negedge clk);
        retire_valid[0] = 1'b1;
        retire_primary_slot_id[0] = 0;
        retire_partner_valid[0] = 1'b1;
        retire_partner_slot_id[0] =
            SLOT_ID_WIDTH'(DEPTH - 1);
        #1;
        check(dut.retire_request_slot_mask == 4'b1001,
              "invalid descriptor did not preserve explicit slot IDs");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        #1;
        check(!protocol_error && pending_count == 1,
              "invalid partner was checked before registered stage");
        @(posedge clk);
        @(negedge clk);
        #1;
        check(!protocol_error && dut.retire_check_error[0],
              "invalid partner diagnostic was not registered offline");
        check(pending_count == 0,
              "invalid empty partner retired an unrelated live slot");
        @(posedge clk);
        @(negedge clk);
        #1;
        check(protocol_error,
              "missing P/P partner was not diagnosed");
        check(pending_count == 0,
              "invalid empty partner retired an unrelated live slot");

        // Reset cancels an accepted-but-uncommitted plan.  No descriptor may
        // leak into the pending pool after reset is released.
        @(negedge clk);
        clear_inputs();
        req_valid[0] = 1'b1;
        req_push[0] = 1'b1;
        logical_tree_id[0] = 0;
        push_data[0] = 32'hface_0001;
        #1;
        check(capture_fire[0],
              "reset-during-plan request was not accepted");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        #1;
        check(dut.allocation_plan_valid &&
              dut.slot_reserved != 0,
              "reset-during-plan setup did not create reservation");
        arst_n = 0;
        #1;
        check(!dut.allocation_plan_valid &&
              dut.slot_reserved == 0 &&
              dut.slot_valid == 0 &&
              dut.allocation_plan_base_older_mask == 0 &&
              dut.allocation_plan_merge_lane_mask[0] == 0 &&
              dut.allocation_plan_merge_lane_mask[1] == 0 &&
              pending_count == 0,
              "reset did not cancel plan/reservation");
        repeat (2) @(posedge clk);
        arst_n = 1;

        // Build two non-contiguous free holes and verify that parallel
        // k-th-free selection preserves port priority without relying on a
        // destructively updated availability mask.
        @(negedge clk);
        clear_inputs();
        req_valid = 2'b11;
        req_push = 2'b11;
        logical_tree_id[0] = 0;
        logical_tree_id[1] = 0;
        push_data[0] = 32'h7000_0000;
        push_data[1] = 32'h7000_0001;
        #1;
        check(capture_fire == 2'b11,
              "hole-test first plan was not accepted");
        @(posedge clk);
        @(negedge clk);
        logical_tree_id[0] = 1;
        logical_tree_id[1] = 1;
        push_data[0] = 32'h7000_0002;
        push_data[1] = 32'h7000_0003;
        #1;
        check(capture_fire == 2'b11,
              "hole-test second plan was not accepted");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        @(posedge clk);
        @(negedge clk);
        #1;
        check(dut.slot_valid == 4'b1111,
              "hole-test setup did not fill all slots");

        retire_valid = 2'b11;
        retire_primary_slot_id[0] = 0;
        retire_primary_slot_id[1] = 2;
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        @(posedge clk);
        @(negedge clk);
        #1;
        check(dut.slot_valid == 4'b1010 &&
              dut.available_slot_mask == 4'b0101,
              "hole-test did not create slots 0 and 2 as free holes");

        req_valid = 2'b11;
        req_push = 2'b11;
        logical_tree_id[0] = 0;
        logical_tree_id[1] = 1;
        #1;
        check(capture_fire == 2'b11 &&
              dut.allocation_port_slot_mask[0] == 4'b0001 &&
              dut.allocation_port_slot_mask[1] == 4'b0100 &&
              dut.allocation_slot[0] == 0 &&
              dut.allocation_slot[1] == 2,
              "parallel allocator did not map lanes to ordered free holes");

        if (failures == 0)
            $display("PASS: LogicalRequestBuffer_tb");
        else
            $fatal(1, "LogicalRequestBuffer_tb failures=%0d",
                   failures);
        $finish;
    end
endmodule
