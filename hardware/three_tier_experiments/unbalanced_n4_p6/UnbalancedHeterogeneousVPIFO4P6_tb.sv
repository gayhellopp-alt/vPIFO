`timescale 1ns / 10ps

module UnbalancedHeterogeneousVPIFO4P6_tb;
    localparam PTW = 16;
    localparam MTW = 32;
    localparam INITIAL_PACKETS = 12;
    localparam COMPOUND_PACKETS = 6;
    localparam TOTAL_PACKETS = INITIAL_PACKETS + COMPOUND_PACKETS;

    reg clk;
    reg arst_n;
    reg push_valid;
    wire push_ready;
    reg [1:0] leaf_id;
    reg [PTW-1:0] root_rank;
    reg [PTW-1:0] middle_rank;
    reg [PTW-1:0] leaf_rank;
    reg [MTW-1:0] payload;
    reg pop_valid;
    wire pop_ready;
    wire pop_out_valid;
    wire [1:0] pop_leaf_id;
    wire [MTW-1:0] pop_payload;
    wire busy;
    wire protocol_error;

    integer packet_index;
    integer drain_index;
    integer cycles;
    integer physical_index;
    integer root_count_sum;

    always #1.6665 clk = ~clk;
    always @(posedge clk)
        cycles <= cycles + 1;

    function automatic [1:0] expected_leaf_id;
        input integer index;
        begin
            expected_leaf_id = ((index % 2) == 0) ? 2'd1 : 2'd3;
        end
    endfunction

    function automatic [MTW-1:0] expected_payload;
        input integer index;
        begin
            expected_payload = MTW'(32'h6a4c0000 + index);
        end
    endfunction

    task automatic prepare_packet;
        input integer index;
        begin
            leaf_id = expected_leaf_id(index);
            root_rank = PTW'(index + 1);
            middle_rank = PTW'(index + 1);
            leaf_rank = PTW'(index + 1);
            payload = expected_payload(index);
        end
    endtask

    task automatic send_packet;
        input integer index;
        begin
            prepare_packet(index);
            // Enter on a fresh falling edge so ready is sampled from a stable
            // pre-transfer cycle.  Keep valid through exactly one following
            // rising edge after ready is observed.
            @(negedge clk);
            while (!push_ready)
                @(negedge clk);
            push_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            push_valid = 1'b0;
        end
    endtask

    task automatic check_pop_result;
        input integer expected_index;
        begin
            while (!pop_out_valid)
                @(negedge clk);
            if (pop_leaf_id !== expected_leaf_id(expected_index))
                $fatal(1,
                    "packet %0d leaf mismatch: got %0d expected %0d",
                    expected_index, pop_leaf_id,
                    expected_leaf_id(expected_index));
            if (pop_payload !== expected_payload(expected_index))
                $fatal(1,
                    "packet %0d payload mismatch: got 0x%0h expected 0x%0h",
                    expected_index, pop_payload,
                    expected_payload(expected_index));
        end
    endtask

    task automatic pop_and_check;
        input integer expected_index;
        begin
            @(negedge clk);
            while (!pop_ready)
                @(negedge clk);
            pop_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            pop_valid = 1'b0;
            check_pop_result(expected_index);
        end
    endtask

    task automatic compound_push_pop_and_check;
        input integer push_index;
        input integer expected_pop_index;
        begin
            prepare_packet(push_index);
            @(negedge clk);
            while (!(push_ready && pop_ready))
                @(negedge clk);
            push_valid = 1'b1;
            pop_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            push_valid = 1'b0;
            pop_valid = 1'b0;
            check_pop_result(expected_pop_index);
        end
    endtask

    UnbalancedHeterogeneousVPIFO4P6 #(
        .PTW(PTW),
        .MTW(MTW),
        .CTW(10),
        .FIFO_SIZE(8),
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

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        push_valid = 1'b0;
        leaf_id = 2'd1;
        root_rank = {PTW{1'b0}};
        middle_rank = {PTW{1'b0}};
        leaf_rank = {PTW{1'b0}};
        payload = {MTW{1'b0}};
        pop_valid = 1'b0;
        cycles = 0;

        repeat (8) @(negedge clk);
        arst_n = 1'b1;
        repeat (4) @(negedge clk);

        // Alternate the direct two-level and deep three-level paths.
        for (packet_index = 0; packet_index < INITIAL_PACKETS;
             packet_index = packet_index + 1)
            send_packet(packet_index);

        while (busy)
            @(negedge clk);
        // Match the established three-tier regression's Engine settle guard.
        // o_busy covers buffered/directory work; final BMW summary updates can
        // still be visible a few cycles later at this observation boundary.
        repeat (20) @(negedge clk);

        // Root round-robin must use all three physical shards.
        root_count_sum = 0;
        for (physical_index = 0; physical_index < 3;
             physical_index = physical_index + 1) begin
            $display("root shard %0d count=%0d", physical_index,
                     dut.core.directory.o_shard_count[physical_index]);
            if (dut.core.directory.o_shard_count[physical_index] == 0)
                $fatal(1, "root shard %0d was never used", physical_index);
            root_count_sum = root_count_sum +
                dut.core.directory.o_shard_count[physical_index];
        end
        if (root_count_sum != INITIAL_PACKETS)
            $fatal(1, "root count mismatch: got %0d expected %0d",
                   root_count_sum, INITIAL_PACKETS);

        // Exercise native root P/P while alternating both hierarchy depths.
        for (packet_index = 0; packet_index < COMPOUND_PACKETS;
             packet_index = packet_index + 1)
            compound_push_pop_and_check(
                INITIAL_PACKETS + packet_index, packet_index);

        for (drain_index = COMPOUND_PACKETS;
             drain_index < TOTAL_PACKETS;
             drain_index = drain_index + 1)
            pop_and_check(drain_index);

        while (busy)
            @(negedge clk);
        repeat (10) @(negedge clk);

        for (physical_index = 0; physical_index < 6;
             physical_index = physical_index + 1)
            if (dut.core.directory.o_shard_count[physical_index] != 0)
                $fatal(1, "physical shard %0d did not drain", physical_index);
        if (protocol_error)
            $fatal(1, "protocol_error asserted");

        $display(
            "PASS: unbalanced M2/L6 N4/P6 [3,1,1,1] packets=%0d compound=%0d cycles=%0d",
            TOTAL_PACKETS, COMPOUND_PACKETS, cycles);
        $finish;
    end

    initial begin
        repeat (1000000) @(posedge clk);
        $fatal(1, "timeout after %0d cycles", cycles);
    end

endmodule
