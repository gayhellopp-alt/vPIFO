`timescale 1ns / 1ps

module ShapingEventTable_tb;
    localparam EVENT_DATA_WIDTH = 16;
    localparam TIME_WIDTH = 12;
    localparam DEPTH = 4;
    localparam EVENT_ID_WIDTH = $clog2(DEPTH);
    localparam COUNT_WIDTH = $clog2(DEPTH + 1);

    reg i_clk;
    reg i_arst_n;
    reg i_allocate_fire;
    reg [EVENT_DATA_WIDTH-1:0] i_allocate_data;
    reg [TIME_WIDTH-1:0] i_allocate_release_time;
    wire o_allocate_ready;
    wire [EVENT_ID_WIDTH-1:0] o_allocate_id;
    reg [EVENT_ID_WIDTH-1:0] i_read_id;
    wire o_read_valid;
    wire [EVENT_DATA_WIDTH-1:0] o_read_data;
    wire [TIME_WIDTH-1:0] o_read_release_time;
    reg i_free_fire;
    reg [EVENT_ID_WIDTH-1:0] i_free_id;
    wire [COUNT_WIDTH-1:0] o_count;
    wire [DEPTH-1:0] o_valid_entries;
    wire o_protocol_error;

    integer failures;

    ShapingEventTable #(
        .EVENT_DATA_WIDTH(EVENT_DATA_WIDTH),
        .TIME_WIDTH(TIME_WIDTH),
        .DEPTH(DEPTH)
    ) dut (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_allocate_fire(i_allocate_fire),
        .i_allocate_data(i_allocate_data),
        .i_allocate_release_time(i_allocate_release_time),
        .o_allocate_ready(o_allocate_ready),
        .o_allocate_id(o_allocate_id),
        .i_read_id(i_read_id),
        .o_read_valid(o_read_valid),
        .o_read_data(o_read_data),
        .o_read_release_time(o_read_release_time),
        .i_free_fire(i_free_fire),
        .i_free_id(i_free_id),
        .o_count(o_count),
        .o_valid_entries(o_valid_entries),
        .o_protocol_error(o_protocol_error)
    );

    always #5 i_clk = ~i_clk;

    task check;
        input condition;
        input [8*160-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                failures = failures + 1;
            end
        end
    endtask

    task allocate_event;
        input [EVENT_DATA_WIDTH-1:0] data;
        input [TIME_WIDTH-1:0] release_time;
        input [EVENT_ID_WIDTH-1:0] expected_id;
        begin
            @(negedge i_clk);
            i_allocate_data = data;
            i_allocate_release_time = release_time;
            i_allocate_fire = 1'b1;
            #1;
            check(o_allocate_ready && (o_allocate_id == expected_id),
                  "allocator did not select the expected first free ID");
            @(posedge i_clk);
            #1;
            i_allocate_fire = 1'b0;
            i_read_id = expected_id;
            #1;
            check(o_read_valid && (o_read_data == data) &&
                  (o_read_release_time == release_time),
                  "allocated payload was not visible through a valid read");
        end
    endtask

    initial begin
        failures = 0;
        i_clk = 1'b0;
        i_arst_n = 1'b0;
        i_allocate_fire = 1'b0;
        i_allocate_data = {EVENT_DATA_WIDTH{1'b0}};
        i_allocate_release_time = {TIME_WIDTH{1'b0}};
        i_read_id = {EVENT_ID_WIDTH{1'b0}};
        i_free_fire = 1'b0;
        i_free_id = {EVENT_ID_WIDTH{1'b0}};

        #2;
        check((o_count == 0) && (o_valid_entries == 0) &&
              !o_protocol_error,
              "reset did not clear EventTable control state");
        check(!o_read_valid && (o_read_data == 0) &&
              (o_read_release_time == 0),
              "invalid reset-state read did not return zero");

        i_arst_n = 1'b1;
        allocate_event(16'h1234, 12'h120, 2'd0);
        allocate_event(16'h5678, 12'h240, 2'd1);
        check((o_count == 2) && (o_valid_entries == 4'b0011),
              "two allocations produced incorrect control state");

        // Freeing must hide the old payload even though its storage bits are
        // deliberately not reset or cleared.
        @(negedge i_clk);
        i_free_id = 2'd0;
        i_free_fire = 1'b1;
        @(posedge i_clk);
        #1;
        i_free_fire = 1'b0;
        i_read_id = 2'd0;
        #1;
        check(!o_read_valid && (o_read_data == 0) &&
              (o_read_release_time == 0),
              "freed entry exposed stale payload or release time");
        check((o_count == 1) && (o_valid_entries == 4'b0010),
              "free produced incorrect count or valid bitmap");

        allocate_event(16'h9abc, 12'h360, 2'd0);

        // One allocation and one free in the same cycle must preserve count.
        @(negedge i_clk);
        i_allocate_data = 16'hdef0;
        i_allocate_release_time = 12'h480;
        i_allocate_fire = 1'b1;
        i_free_id = 2'd1;
        i_free_fire = 1'b1;
        #1;
        check(o_allocate_ready && (o_allocate_id == 2'd2),
              "simultaneous operation selected an unexpected free ID");
        @(posedge i_clk);
        #1;
        i_allocate_fire = 1'b0;
        i_free_fire = 1'b0;
        check((o_count == 2) && (o_valid_entries == 4'b0101),
              "simultaneous allocate/free did not preserve count");

        i_read_id = 2'd1;
        #1;
        check(!o_read_valid && (o_read_data == 0) &&
              (o_read_release_time == 0),
              "simultaneously freed entry exposed stale storage");
        i_read_id = 2'd2;
        #1;
        check(o_read_valid && (o_read_data == 16'hdef0) &&
              (o_read_release_time == 12'h480),
              "simultaneous allocation payload was corrupted");

        // Warm reset with live entries must immediately invalidate all IDs,
        // without depending on clearing the payload arrays.
        #1;
        i_arst_n = 1'b0;
        #1;
        check((o_count == 0) && (o_valid_entries == 0) &&
              !o_protocol_error,
              "warm reset did not clear EventTable control state");
        check(!o_read_valid && (o_read_data == 0) &&
              (o_read_release_time == 0),
              "warm-reset invalid read exposed retained payload");

        @(negedge i_clk);
        i_arst_n = 1'b1;
        allocate_event(16'h55aa, 12'h5a0, 2'd0);
        check((o_count == 1) && (o_valid_entries == 4'b0001),
              "post-reset allocation did not restart at ID zero");

        if (failures == 0)
            $display("PASS: EventTable valid-gated payload reset and ID reuse");
        else begin
            $display("FAIL: EventTable failures=%0d", failures);
            $fatal(1);
        end
        $finish;
    end

endmodule
