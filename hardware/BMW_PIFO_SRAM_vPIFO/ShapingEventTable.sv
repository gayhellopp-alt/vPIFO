`timescale 1ns / 10ps

// Side table for shaping events.  The BMW tree stores only event_id and the
// release rank; the packet/reference payload remains here until the release
// has actually left ShapingReleaseFIFO.
module ShapingEventTable #(
    parameter EVENT_DATA_WIDTH = 64,
    parameter TIME_WIDTH = 32,
    parameter DEPTH = 16,
    localparam EVENT_ID_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    localparam COUNT_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH + 1)
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,

    input  wire                         i_allocate_fire,
    input  wire [EVENT_DATA_WIDTH-1:0]  i_allocate_data,
    input  wire [TIME_WIDTH-1:0]        i_allocate_release_time,
    output reg                          o_allocate_ready,
    output reg  [EVENT_ID_WIDTH-1:0]    o_allocate_id,

    input  wire [EVENT_ID_WIDTH-1:0]    i_read_id,
    output reg                          o_read_valid,
    output reg  [EVENT_DATA_WIDTH-1:0]  o_read_data,
    output reg  [TIME_WIDTH-1:0]        o_read_release_time,

    input  wire                         i_free_fire,
    input  wire [EVENT_ID_WIDTH-1:0]    i_free_id,

    output reg  [COUNT_WIDTH-1:0]       o_count,
    output wire [DEPTH-1:0]             o_valid_entries,
    output reg                          o_protocol_error
);

    reg [DEPTH-1:0] valid_entries;
    // Payload storage intentionally has no reset or free-time clear.  The
    // valid bitmap is the ownership boundary and gates all externally visible
    // reads, allowing synthesis to implement these arrays as memory.
    reg [EVENT_DATA_WIDTH-1:0] event_data [0:DEPTH-1];
    reg [TIME_WIDTH-1:0] event_release_time [0:DEPTH-1];

    integer allocate_scan;
    integer read_index;
    wire allocate_accepted = i_allocate_fire && o_allocate_ready;
    wire free_id_in_range = int'(i_free_id) < DEPTH;
    wire free_accepted = i_free_fire && free_id_in_range &&
                         valid_entries[i_free_id];

    assign o_valid_entries = valid_entries;

    always @* begin
        o_allocate_ready = 1'b0;
        o_allocate_id = {EVENT_ID_WIDTH{1'b0}};
        for (allocate_scan = 0; allocate_scan < DEPTH;
             allocate_scan = allocate_scan + 1) begin
            if (!o_allocate_ready && !valid_entries[allocate_scan]) begin
                o_allocate_ready = 1'b1;
                o_allocate_id = allocate_scan[EVENT_ID_WIDTH-1:0];
            end
        end
    end

    always @* begin
        read_index = int'(i_read_id);
        o_read_valid = 1'b0;
        o_read_data = {EVENT_DATA_WIDTH{1'b0}};
        o_read_release_time = {TIME_WIDTH{1'b0}};
        if ((read_index >= 0) && (read_index < DEPTH) &&
            valid_entries[read_index]) begin
            o_read_valid = valid_entries[read_index];
            o_read_data = event_data[read_index];
            o_read_release_time = event_release_time[read_index];
        end
    end

    initial begin
        if ((EVENT_DATA_WIDTH < 1) || (TIME_WIDTH < 1) || (DEPTH < 1))
            $fatal(1, "ShapingEventTable parameters must be positive");
    end

    // Keep payload writes out of the asynchronous-reset process below.  This
    // is required for LUTRAM inference; reset-time writes remain invisible
    // because valid_entries is cleared and gates every read.
    always @(posedge i_clk) begin
        if (i_arst_n && allocate_accepted) begin
            event_data[o_allocate_id] <= i_allocate_data;
            event_release_time[o_allocate_id] <= i_allocate_release_time;
        end
    end

    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            valid_entries <= {DEPTH{1'b0}};
            o_count <= {COUNT_WIDTH{1'b0}};
            o_protocol_error <= 1'b0;
        end else begin
            if (i_allocate_fire && !o_allocate_ready)
                o_protocol_error <= 1'b1;
            if (i_free_fire && !free_accepted)
                o_protocol_error <= 1'b1;

            if (allocate_accepted) begin
                valid_entries[o_allocate_id] <= 1'b1;
            end
            if (free_accepted)
                valid_entries[i_free_id] <= 1'b0;

            case ({allocate_accepted, free_accepted})
                2'b10: o_count <= o_count + 1'b1;
                2'b01: o_count <= o_count - 1'b1;
                default: o_count <= o_count;
            endcase
        end
    end

endmodule
