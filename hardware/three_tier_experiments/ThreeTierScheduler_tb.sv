`timescale 1ns / 10ps

module ThreeTierScheduler_tb #(
    parameter BMW_LEVEL = 6,
    parameter PTW = 16,
    parameter MTW = 16,
    parameter MIDDLE_COUNT = 2,
    parameter LEAF_COUNT = 11,
    parameter PACKETS_PER_LEAF = 2,
    parameter HETERO_PENDING_DEPTH = 16,
    parameter ORIGINAL_SETTLE_CYCLES = 4000
);
    localparam LOGICAL_TREE_NUM = 1 + MIDDLE_COUNT + LEAF_COUNT;
    localparam TREE_ID_WIDTH =
        (LOGICAL_TREE_NUM <= 1) ? 1 : $clog2(LOGICAL_TREE_NUM);
    localparam FIRST_LEAF_ID = 1 + MIDDLE_COUNT;
    localparam PACKET_COUNT = PACKETS_PER_LEAF * LEAF_COUNT;

`ifdef HETERO_DUT
    localparam IS_HETEROGENEOUS = 1;
`elsif HETERO21_DUT
    localparam IS_HETEROGENEOUS = 1;
`else
    localparam IS_HETEROGENEOUS = 0;
`endif

    reg clk;
    reg arst_n;
    reg push_valid;
    wire push_ready;
    reg [TREE_ID_WIDTH-1:0] leaf_id;
    reg [PTW-1:0] root_rank;
    reg [PTW-1:0] middle_rank;
    reg [PTW-1:0] leaf_rank;
    reg [MTW-1:0] payload;
    reg pop_valid;
    wire pop_ready;
    wire pop_out_valid;
    wire [TREE_ID_WIDTH-1:0] pop_leaf_id;
    wire [MTW-1:0] pop_payload;
    wire busy;
    wire protocol_error;

    integer packet_index;
    integer cycles;
    integer expected_leaf;
    integer expected_payload;

    always #1.6665 clk = ~clk;
    always @(posedge clk)
        cycles <= cycles + 1;

`ifdef HETERO_DUT
    ThreeTierHeterogeneousVPIFO #(
        .PTW(PTW),
        .MTW(MTW),
        .CTW(10),
        .FIFO_SIZE(8),
        .LOGICAL_PENDING_DEPTH(HETERO_PENDING_DEPTH)
    ) dut (
`elsif HETERO21_DUT
    ThreeTierHeterogeneousVPIFO21 #(
        .PTW(PTW),
        .MTW(MTW),
        .CTW(10),
        .FIFO_SIZE(8),
        .LOGICAL_PENDING_DEPTH(HETERO_PENDING_DEPTH)
    ) dut (
`else
    ThreeTierOriginalVPIFO #(
        .PTW(PTW),
        .MTW(MTW),
        .CTW(10),
        .LEVEL(BMW_LEVEL),
        .TREE_NUM(LOGICAL_TREE_NUM),
        .MIDDLE_COUNT(MIDDLE_COUNT),
        .LEAF_COUNT(LEAF_COUNT),
        .FIFO_SIZE(8)
    ) dut (
`endif
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

    task automatic send_packet;
        input integer index;
        begin
            while (!push_ready)
                @(negedge clk);
            leaf_id = TREE_ID_WIDTH'(
                FIRST_LEAF_ID + (index % LEAF_COUNT));
            root_rank = PTW'(index + 1);
            middle_rank = PTW'(index + 1);
            leaf_rank = PTW'(index + 1);
            // Exercise the upper metadata half when running the paper's
            // MTW=32 configuration; a zero-extended 16-bit payload would not
            // detect accidental truncation inside the hierarchy.
            if (MTW >= 32)
                payload = MTW'(32'h5ac30000 + index);
            else
                payload = MTW'(16'h4000 + index);
            push_valid = 1'b1;
            @(negedge clk);
            push_valid = 1'b0;
        end
    endtask

    task automatic pop_and_check;
        input integer index;
        begin
            while (!pop_ready)
                @(negedge clk);
            pop_valid = 1'b1;
            @(negedge clk);
            pop_valid = 1'b0;

            while (!pop_out_valid)
                @(negedge clk);
            expected_leaf = FIRST_LEAF_ID + (index % LEAF_COUNT);
            if (MTW >= 32)
                expected_payload = 32'h5ac30000 + index;
            else
                expected_payload = 16'h4000 + index;
            if (pop_leaf_id !== TREE_ID_WIDTH'(expected_leaf))
                $fatal(1,
                    "packet %0d leaf mismatch: got %0d expected %0d",
                    index, pop_leaf_id, expected_leaf);
            if (pop_payload !== MTW'(expected_payload))
                $fatal(1,
                    "packet %0d payload mismatch: got 0x%0h expected 0x%0h",
                    index, pop_payload, expected_payload);
        end
    endtask

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        push_valid = 1'b0;
        leaf_id = {TREE_ID_WIDTH{1'b0}};
        root_rank = {PTW{1'b0}};
        middle_rank = {PTW{1'b0}};
        leaf_rank = {PTW{1'b0}};
        payload = {MTW{1'b0}};
        pop_valid = 1'b0;
        cycles = 0;

        repeat (8) @(negedge clk);
        arst_n = 1'b1;
        repeat (4) @(negedge clk);

        for (packet_index = 0; packet_index < PACKET_COUNT;
             packet_index = packet_index + 1)
            send_packet(packet_index);

        // Original engines expose only TaskFIFO-full, not a global completion
        // indication.  This guard interval lets all three Push streams settle.
        if (!IS_HETEROGENEOUS)
            repeat (ORIGINAL_SETTLE_CYCLES) @(negedge clk);
        else begin
            while (busy)
                @(negedge clk);
            repeat (20) @(negedge clk);
        end

        for (packet_index = 0; packet_index < PACKET_COUNT;
             packet_index = packet_index + 1)
            pop_and_check(packet_index);

        repeat (20) @(negedge clk);
        if (protocol_error)
            $fatal(1, "protocol_error asserted");
        if (busy)
            $fatal(1, "DUT remained busy after all packets retired");

        $display(
            "PASS: three-tier sample hetero=%0d BMW_LEVEL=%0d PTW=%0d MTW=%0d packets=%0d cycles=%0d",
            IS_HETEROGENEOUS, BMW_LEVEL, PTW, MTW,
            PACKET_COUNT, cycles);
        $finish;
    end

    initial begin
        repeat (20000000) @(posedge clk);
        $fatal(1, "timeout after %0d cycles", cycles);
    end

endmodule
