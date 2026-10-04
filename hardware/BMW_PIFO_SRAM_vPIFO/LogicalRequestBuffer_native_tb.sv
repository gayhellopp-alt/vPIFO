`timescale 1ns / 1ps

module LogicalRequestBuffer_native_tb;
    localparam DATA_WIDTH = 16;
    localparam LOGICAL_TREE_NUM = 2;
    localparam REQUEST_PORTS = 4;
    localparam ORDER_WIDTH = 8;
    localparam DEPTH = 8;
    localparam LOGICAL_ID_WIDTH = 1;
    localparam SOURCE_PORT_WIDTH = 2;
    localparam SLOT_ID_WIDTH = 3;
    localparam COUNT_WIDTH = 4;
    localparam HEAD_PAIR_STORAGE_WIDTH = 1;

    reg clk;
    reg arst_n;
    reg [REQUEST_PORTS-1:0] req_valid;
    reg [REQUEST_PORTS-1:0] req_push;
    reg [REQUEST_PORTS-1:0] req_pop;
    reg [LOGICAL_ID_WIDTH-1:0]
        logical_id [0:REQUEST_PORTS-1];
    reg [DATA_WIDTH-1:0] push_data [0:REQUEST_PORTS-1];
    reg [ORDER_WIDTH-1:0] req_order [0:REQUEST_PORTS-1];
    reg [REQUEST_PORTS-1:0]
        req_merge_mask [0:REQUEST_PORTS-1];
    reg [LOGICAL_TREE_NUM-1:0] retire_valid;
    reg [SLOT_ID_WIDTH-1:0]
        retire_primary_slot [0:LOGICAL_TREE_NUM-1];

    wire [REQUEST_PORTS-1:0] req_ready;
    wire [REQUEST_PORTS-1:0] capture_fire;
    wire [REQUEST_PORTS-1:0] bad_id;
    wire [LOGICAL_TREE_NUM-1:0] head_valid;
    wire [LOGICAL_TREE_NUM-1:0] head_push;
    wire [LOGICAL_TREE_NUM-1:0] head_pop;
    wire [DATA_WIDTH-1:0] head_push_data [0:LOGICAL_TREE_NUM-1];
    wire [ORDER_WIDTH-1:0] head_order [0:LOGICAL_TREE_NUM-1];
    wire [SOURCE_PORT_WIDTH-1:0]
        head_source_port [0:LOGICAL_TREE_NUM-1];
    wire [SLOT_ID_WIDTH-1:0]
        head_slot_id [0:LOGICAL_TREE_NUM-1];
    wire [DEPTH-1:0] head_merge_slots [0:LOGICAL_TREE_NUM-1];
    wire [LOGICAL_TREE_NUM-1:0]
        head_pair_older [0:LOGICAL_TREE_NUM-1];
    wire [LOGICAL_TREE_NUM-1:0]
        head_pair_same_event [0:LOGICAL_TREE_NUM-1];
    wire [HEAD_PAIR_STORAGE_WIDTH-1:0] head_first_older;
    wire [HEAD_PAIR_STORAGE_WIDTH-1:0] head_same_event_state;
    wire [LOGICAL_TREE_NUM-1:0] partner_result_valid;
    wire [SLOT_ID_WIDTH-1:0]
        partner_result_slot [0:LOGICAL_TREE_NUM-1];
    wire [COUNT_WIDTH-1:0]
        logical_pending_count [0:LOGICAL_TREE_NUM-1];
    wire [COUNT_WIDTH-1:0] pending_count;
    wire [COUNT_WIDTH-1:0] effective_free_count;
    wire full;
    wire [DEPTH-1:0] slot_older [0:DEPTH-1];
    wire protocol_error;

    integer lane;

    LogicalRequestBuffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .REQUEST_PORTS(REQUEST_PORTS),
        .ORDER_WIDTH(ORDER_WIDTH),
        .DEPTH(DEPTH),
        .NATIVE_COMPOUND_REQUESTS(1)
    ) dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_req_valid(req_valid),
        .i_req_push(req_push),
        .i_req_pop(req_pop),
        .i_logical_tree_id(logical_id),
        .i_push_data(push_data),
        .i_req_order(req_order),
        .i_req_merge_mask(req_merge_mask),
        .o_req_ready(req_ready),
        .o_req_capture_fire(capture_fire),
        .o_req_bad_id(bad_id),
        .i_retire_valid(retire_valid),
        .i_retire_primary_slot_id(retire_primary_slot),
        .i_retire_partner_valid({LOGICAL_TREE_NUM{1'b0}}),
        .i_retire_partner_slot_id(retire_primary_slot),
        .o_head_valid(head_valid),
        .o_head_push(head_push),
        .o_head_pop(head_pop),
        .o_head_push_data(head_push_data),
        .o_head_order(head_order),
        .o_head_source_port(head_source_port),
        .o_head_slot_id(head_slot_id),
        .o_head_merge_slots(head_merge_slots),
        .o_head_pair_older(head_pair_older),
        .o_head_pair_same_event(head_pair_same_event),
        .o_head_first_older(head_first_older),
        .o_head_pair_same_event_state(head_same_event_state),
        .i_partner_resolve_valid({LOGICAL_TREE_NUM{1'b0}}),
        .i_partner_resolve_primary_push({LOGICAL_TREE_NUM{1'b0}}),
        .i_partner_resolve_primary_slot_id(retire_primary_slot),
        .i_partner_resolve_primary_merge_slots(head_merge_slots),
        .o_partner_resolve_valid(partner_result_valid),
        .o_partner_resolve_slot_id(partner_result_slot),
        .o_logical_pending_count(logical_pending_count),
        .o_pending_count(pending_count),
        .o_effective_free_count(effective_free_count),
        .o_full(full),
        .o_slot_older(slot_older),
        .o_protocol_error(protocol_error)
    );

    always #5 clk = ~clk;

    task automatic clear_inputs;
        integer clear_lane;
        begin
            req_valid = 0;
            req_push = 0;
            req_pop = 0;
            retire_valid = 0;
            for (clear_lane = 0; clear_lane < REQUEST_PORTS;
                 clear_lane = clear_lane + 1) begin
                logical_id[clear_lane] = 0;
                push_data[clear_lane] = 0;
                req_order[clear_lane] = 0;
                req_merge_mask[clear_lane] = 0;
            end
        end
    endtask

    task automatic check;
        input condition;
        input [8*96-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                $fatal(1);
            end
        end
    endtask

    task automatic commit_capture;
        input [REQUEST_PORTS-1:0] expected_fire;
        begin
            #1;
            check(capture_fire == expected_fire,
                  "unexpected native capture fire mask");
            @(posedge clk);
            @(negedge clk);
            clear_inputs();
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    initial begin
        clk = 0;
        arst_n = 0;
        clear_inputs();
        for (lane = 0; lane < LOGICAL_TREE_NUM; lane = lane + 1)
            retire_primary_slot[lane] = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        arst_n = 1;

        // Lanes 0 and 1 append to logical 0 in lane order; lane 2 creates an
        // independent logical-1 queue in the same capture batch.
        req_valid = 4'b0111;
        req_push = 4'b0101;
        req_pop = 4'b0010;
        logical_id[0] = 0;
        logical_id[1] = 0;
        logical_id[2] = 1;
        push_data[0] = 16'h1000;
        push_data[1] = 16'h1001;
        push_data[2] = 16'h2000;
        commit_capture(4'b0111);
        check(head_valid == 2'b11, "both native queues must be valid");
        check((head_push_data[0] == 16'h1000) && head_push[0] &&
              !head_pop[0], "logical 0 did not expose lane-0 head");
        check((head_push_data[1] == 16'h2000) && head_push[1],
              "logical 1 did not expose its independent head");
        check((logical_pending_count[0] == 2) &&
              (logical_pending_count[1] == 1),
              "initial per-logical counts are wrong");

        // Retire the first logical-0 descriptor.  The second descriptor must
        // become visible only after the original registered retire delay.
        retire_primary_slot[0] = head_slot_id[0];
        retire_valid = 2'b01;
        @(posedge clk);
        @(negedge clk);
        retire_valid = 0;
        @(posedge clk);
        @(negedge clk);
        check((head_push_data[0] == 16'h1001) && !head_push[0] &&
              head_pop[0], "logical 0 linked successor was not exposed");
        check(logical_pending_count[0] == 1,
              "logical 0 retire count is wrong");

        // Queue 1 is a singleton.  Arrange its retirement and a new capture
        // so removal and commit occur on the same edge; the new descriptor
        // must become a fresh singleton rather than link through dead state.
        retire_primary_slot[1] = head_slot_id[1];
        retire_valid = 2'b10;
        req_valid = 4'b0001;
        req_push = 4'b0001;
        logical_id[0] = 1;
        push_data[0] = 16'h2001;
        #1;
        check(capture_fire == 4'b0001,
              "replacement singleton was not captured");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        @(posedge clk);
        @(negedge clk);
        check(head_valid[1] && (head_push_data[1] == 16'h2001) &&
              (logical_pending_count[1] == 1),
              "retire-plus-append singleton transition failed");

        // Append two more logical-0 descriptors to a non-empty queue using
        // non-adjacent lanes.  They must remain lane ordered behind 0x1001.
        req_valid = 4'b0101;
        req_push = 4'b0101;
        logical_id[0] = 0;
        logical_id[2] = 0;
        push_data[0] = 16'h1002;
        push_data[2] = 16'h1003;
        commit_capture(4'b0101);
        check((head_push_data[0] == 16'h1001) &&
              (logical_pending_count[0] == 3),
              "append changed a non-empty queue head");

        retire_primary_slot[0] = head_slot_id[0];
        retire_valid = 2'b01;
        @(posedge clk);
        @(negedge clk);
        retire_valid = 0;
        @(posedge clk);
        @(negedge clk);
        check(head_push_data[0] == 16'h1002,
              "first appended descriptor order mismatch");

        retire_primary_slot[0] = head_slot_id[0];
        retire_valid = 2'b01;
        @(posedge clk);
        @(negedge clk);
        retire_valid = 0;
        @(posedge clk);
        @(negedge clk);
        check((head_push_data[0] == 16'h1003) &&
              (logical_pending_count[0] == 1),
              "second appended descriptor order mismatch");

        check(!protocol_error, "native LRB raised protocol_error");
        check(!(|bad_id), "native LRB raised bad_id");
        $display("PASS: native linked logical request queues");
        $finish;
    end
endmodule
