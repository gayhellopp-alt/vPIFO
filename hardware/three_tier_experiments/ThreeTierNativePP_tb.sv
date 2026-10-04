`timescale 1ns / 10ps

// Directed check for the complete-operation boundary used by the fixed
// three-tier heterogeneous scheduler.  The second Packet In is accepted with
// a Packet Out, so its root operation must occupy one pending descriptor and
// reach one BMW TaskFIFO as a native Push/Pop word.
module ThreeTierNativePP_tb;
    localparam PTW = 16;
    localparam MTW = 32;
    localparam LOGICAL_ID_WIDTH = 5;

    reg clk;
    reg arst_n;
    reg push_valid;
    wire push_ready;
    reg [LOGICAL_ID_WIDTH-1:0] leaf_id;
    reg [PTW-1:0] root_rank;
    reg [PTW-1:0] middle_rank;
    reg [PTW-1:0] leaf_rank;
    reg [MTW-1:0] payload;
    reg pop_valid;
    wire pop_ready;
    wire pop_out_valid;
    wire [LOGICAL_ID_WIDTH-1:0] pop_leaf_id;
    wire [MTW-1:0] pop_payload;
    wire busy;
    wire protocol_error;

    integer watchdog;
    integer engine_pp_count;

    always #1.6665 clk = ~clk;

    ThreeTierHeterogeneousVPIFO21 #(
        .PTW(PTW),
        .MTW(MTW),
        .LOGICAL_PENDING_DEPTH(8)
    ) dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_push_valid(push_valid),
        .o_push_ready(push_ready),
        .i_leaf_id(leaf_id),
        .i_root_rank(root_rank),
        .i_middle_rank(middle_rank),
        .i_leaf_rank(leaf_rank),
        .i_payload(payload),
        .i_pop_valid(pop_valid),
        .o_pop_ready(pop_ready),
        .o_pop_valid(pop_out_valid),
        .o_pop_leaf_id(pop_leaf_id),
        .o_pop_payload(pop_payload),
        .o_busy(busy),
        .o_protocol_error(protocol_error)
    );

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n)
            engine_pp_count <= 0;
        else begin
            if (|(dut.impl.core.o_task_write &
                  dut.impl.core.o_task_push &
                  dut.impl.core.o_task_pop))
                engine_pp_count <= engine_pp_count + 1;
        end
    end

    task automatic send_packet;
        input [LOGICAL_ID_WIDTH-1:0] packet_leaf;
        input [PTW-1:0] packet_rank;
        input [MTW-1:0] packet_payload;
        begin
            while (!push_ready)
                @(negedge clk);
            leaf_id = packet_leaf;
            root_rank = packet_rank;
            middle_rank = packet_rank;
            leaf_rank = packet_rank;
            payload = packet_payload;
            push_valid = 1'b1;
            @(negedge clk);
            push_valid = 1'b0;
        end
    endtask

    task automatic pop_and_check;
        input [LOGICAL_ID_WIDTH-1:0] expected_leaf;
        input [MTW-1:0] expected_payload;
        begin
            while (!pop_ready)
                @(negedge clk);
            pop_valid = 1'b1;
            @(negedge clk);
            pop_valid = 1'b0;
            watchdog = 0;
            while (!pop_out_valid && (watchdog < 5000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (!pop_out_valid)
                $fatal(1, "timed out waiting for Pop result");
            if ((pop_leaf_id !== expected_leaf) ||
                (pop_payload !== expected_payload))
                $fatal(1,
                    "Pop mismatch leaf=%0d/%0d payload=%h/%h",
                    pop_leaf_id, expected_leaf,
                    pop_payload, expected_payload);
        end
    endtask

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        push_valid = 1'b0;
        pop_valid = 1'b0;
        leaf_id = '0;
        root_rank = '0;
        middle_rank = '0;
        leaf_rank = '0;
        payload = '0;

        repeat (8) @(negedge clk);
        arst_n = 1'b1;
        repeat (4) @(negedge clk);

        send_packet(5'd5, 16'd10, 32'h1111_0001);
        while (busy)
            @(negedge clk);

        // Insert the younger packet and start removal of the older packet on
        // the same edge.  Root rank 10 must be popped after rank 20 is pushed.
        while (!(push_ready && pop_ready))
            @(negedge clk);
        leaf_id = 5'd6;
        root_rank = 16'd20;
        middle_rank = 16'd20;
        leaf_rank = 16'd20;
        payload = 32'h2222_0002;
        push_valid = 1'b1;
        pop_valid = 1'b1;
        #1;
        if (!(dut.impl.core_req_capture_fire[2] &&
              dut.impl.core_req_push[2] &&
              dut.impl.core_req_pop[2]) ||
            (dut.impl.core_req_capture_fire !== 4'b0111))
            $fatal(1,
                "root P/P was not one native descriptor: capture=%b op=%b%b",
                dut.impl.core_req_capture_fire,
                dut.impl.core_req_push[2],
                dut.impl.core_req_pop[2]);
        @(posedge clk);
        @(negedge clk);
        push_valid = 1'b0;
        pop_valid = 1'b0;

        watchdog = 0;
        while (!pop_out_valid && (watchdog < 5000)) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (!pop_out_valid || (pop_leaf_id !== 5'd5) ||
            (pop_payload !== 32'h1111_0001))
            $fatal(1, "simultaneous Packet In/Out returned wrong packet");

        while (busy)
            @(negedge clk);
        pop_and_check(5'd6, 32'h2222_0002);
        while (busy)
            @(negedge clk);

        if (engine_pp_count != 1)
            $fatal(1,
                "expected exactly one native Engine P/P, observed %0d",
                engine_pp_count);
        if (protocol_error)
            $fatal(1, "protocol_error asserted");

        $display("PASS: native root P/P and single-return path");
        $finish;
    end

    initial begin
        repeat (20000) @(posedge clk);
        $fatal(1, "timeout");
    end
endmodule
