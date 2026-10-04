`timescale 1ns / 10ps

// Backpressurable, single-enqueue/single-dequeue identity FIFO at the shaping
// to scheduling boundary.  Payload remains owned by ShapingEventTable until
// this FIFO dequeues its event ID.  Tree Pop completions are not
// backpressurable, so the producer must reserve FIFO credit before issuing the
// corresponding Pop.
module ShapingReleaseFIFO #(
    parameter EVENT_ID_WIDTH = 4,
    parameter LOGICAL_ID_WIDTH = 2,
    parameter DEPTH = 8,
    localparam PTR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    localparam COUNT_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH + 1)
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,

    input  wire                         i_enqueue_valid,
    output wire                         o_enqueue_ready,
    input  wire [EVENT_ID_WIDTH-1:0]    i_enqueue_event_id,
    input  wire [LOGICAL_ID_WIDTH-1:0]  i_enqueue_logical_id,

    output wire                         o_dequeue_valid,
    input  wire                         i_dequeue_ready,
    output wire [EVENT_ID_WIDTH-1:0]    o_dequeue_event_id,
    output wire [LOGICAL_ID_WIDTH-1:0]  o_dequeue_logical_id,

    output reg [COUNT_WIDTH-1:0]        o_count,
    output reg                          o_overflow
);

    reg [EVENT_ID_WIDTH-1:0] event_id_mem [0:DEPTH-1];
    reg [LOGICAL_ID_WIDTH-1:0] logical_id_mem [0:DEPTH-1];
    reg [PTR_WIDTH-1:0] head_ptr;
    reg [PTR_WIDTH-1:0] tail_ptr;

    wire dequeue_fire = o_dequeue_valid && i_dequeue_ready;
    wire enqueue_fire = i_enqueue_valid && o_enqueue_ready;

    assign o_dequeue_valid =
        o_count != {COUNT_WIDTH{1'b0}};
    assign o_enqueue_ready =
        (o_count < DEPTH[COUNT_WIDTH-1:0]) || dequeue_fire;
    assign o_dequeue_event_id = o_dequeue_valid ?
        event_id_mem[head_ptr] : {EVENT_ID_WIDTH{1'b0}};
    assign o_dequeue_logical_id = o_dequeue_valid ?
        logical_id_mem[head_ptr] : {LOGICAL_ID_WIDTH{1'b0}};

    initial begin
        if ((EVENT_ID_WIDTH < 1) || (LOGICAL_ID_WIDTH < 1) ||
            (DEPTH < 1))
            $fatal(1, "ShapingReleaseFIFO parameters must be positive");
    end

    // Keep identity storage out of the asynchronous-reset process so it may
    // be implemented as distributed memory.  Empty-state outputs are gated
    // by o_dequeue_valid, so the memory contents never require reset.
    always @(posedge i_clk) begin
        if (i_arst_n && enqueue_fire) begin
            event_id_mem[tail_ptr] <= i_enqueue_event_id;
            logical_id_mem[tail_ptr] <= i_enqueue_logical_id;
        end
    end

    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            head_ptr <= {PTR_WIDTH{1'b0}};
            tail_ptr <= {PTR_WIDTH{1'b0}};
            o_count <= {COUNT_WIDTH{1'b0}};
            o_overflow <= 1'b0;
        end else begin
            if (i_enqueue_valid && !o_enqueue_ready)
                o_overflow <= 1'b1;

            if (enqueue_fire) begin
                if (tail_ptr == PTR_WIDTH'(DEPTH-1))
                    tail_ptr <= {PTR_WIDTH{1'b0}};
                else
                    tail_ptr <= tail_ptr + 1'b1;
            end

            if (dequeue_fire) begin
                if (head_ptr == PTR_WIDTH'(DEPTH-1))
                    head_ptr <= {PTR_WIDTH{1'b0}};
                else
                    head_ptr <= head_ptr + 1'b1;
            end

            case ({enqueue_fire, dequeue_fire})
                2'b10: o_count <= o_count + 1'b1;
                2'b01: o_count <= o_count - 1'b1;
                default: o_count <= o_count;
            endcase
        end
    end

endmodule
