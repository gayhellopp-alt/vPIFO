`timescale 1ns / 10ps

// Multi-enqueue/single-dequeue FIFO used by HeterogeneousPIFO to serialize
// per-lane Pop returns.  The production wrapper always keeps dequeue ready
// asserted; the explicit ready input exists so the real FIFO implementation
// can also be exercised at full and near-full occupancy in its unit test.
module PopResultFIFO #(
    parameter DATA_WIDTH = 32,
    parameter LOGICAL_ID_WIDTH = 2,
    parameter ENQUEUE_PORTS = 4,
    parameter DEPTH = 8,

    localparam PTR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    localparam COUNT_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH + 1),
    localparam ENQUEUE_COUNT_WIDTH = (ENQUEUE_PORTS <= 1) ? 1 :
                                     $clog2(ENQUEUE_PORTS + 1),
    localparam CALC_COUNT_WIDTH =
        (COUNT_WIDTH > ENQUEUE_COUNT_WIDTH) ?
        COUNT_WIDTH : ENQUEUE_COUNT_WIDTH,
    localparam TAIL_CALC_WIDTH =
        ((PTR_WIDTH > CALC_COUNT_WIDTH) ?
         PTR_WIDTH : CALC_COUNT_WIDTH) + 1
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,

    input  wire [ENQUEUE_PORTS-1:0]     i_enqueue_valid,
    input  wire [DATA_WIDTH-1:0]        i_enqueue_data [0:ENQUEUE_PORTS-1],
    input  wire [LOGICAL_ID_WIDTH-1:0]  i_enqueue_logical_id [0:ENQUEUE_PORTS-1],

    input  wire                         i_dequeue_ready,
    output reg                          o_dequeue_valid,
    output reg [DATA_WIDTH-1:0]         o_dequeue_data,
    output reg [LOGICAL_ID_WIDTH-1:0]   o_dequeue_logical_id,

    // Sticky overflow is a protocol failure in the current system: Engine
    // Pop returns cannot be backpressured and therefore must never be dropped.
    output reg                          o_overflow,

    // Verification/observability only.  These reflect the real production
    // state and do not participate in request or result control.
    output reg [COUNT_WIDTH-1:0]        o_count,
    output reg [PTR_WIDTH-1:0]          o_head_ptr,
    output reg [PTR_WIDTH-1:0]          o_tail_ptr,
    output reg [ENQUEUE_COUNT_WIDTH-1:0] o_enqueued_count,
    output reg                          o_dequeued,
    output reg                          o_head_wrapped,
    output reg                          o_tail_wrapped
);

    // The surrounding fixed configuration requires positive widths/depths.
    // Constant-false generate branches disappear for all legal builds.
    generate
        if ((DATA_WIDTH < 1) || (LOGICAL_ID_WIDTH < 1) ||
            (ENQUEUE_PORTS < 1) || (DEPTH < 1) ||
            (PTR_WIDTH < 1) || (COUNT_WIDTH < 1) ||
            (ENQUEUE_COUNT_WIDTH < 1)) begin : invalid_fifo_parameters
            initial begin
                $fatal(1, "PopResultFIFO parameters must produce positive widths and depth");
            end
        end
    endgenerate

    reg [DATA_WIDTH-1:0] storage_data [0:DEPTH-1];
    reg [LOGICAL_ID_WIDTH-1:0] storage_logical_id [0:DEPTH-1];

    // Count valid lanes below a constant lane number.  The production
    // four-lane configuration uses the explicitly balanced network below;
    // this function keeps the parameterized fallback behavior well-defined.
    function [ENQUEUE_COUNT_WIDTH-1:0] count_valid_prefix;
        input [ENQUEUE_PORTS-1:0] valid_mask;
        input integer limit;
        integer prefix_lane;
        begin
            count_valid_prefix = {ENQUEUE_COUNT_WIDTH{1'b0}};
            for (prefix_lane = 0; prefix_lane < ENQUEUE_PORTS;
                 prefix_lane = prefix_lane + 1) begin
                if (prefix_lane < limit)
                    count_valid_prefix = count_valid_prefix +
                        {{(ENQUEUE_COUNT_WIDTH-1){1'b0}},
                          valid_mask[prefix_lane]};
            end
        end
    endfunction

    wire [ENQUEUE_COUNT_WIDTH-1:0]
        enqueue_prefix_count [0:ENQUEUE_PORTS-1];
    wire [ENQUEUE_COUNT_WIDTH-1:0] enqueue_requested_count;

    genvar prefix_output_lane;
    generate
        if (ENQUEUE_PORTS == 4) begin : GEN_FOUR_LANE_PREFIX
            wire [ENQUEUE_COUNT_WIDTH-1:0] lower_pair_count;
            wire [ENQUEUE_COUNT_WIDTH-1:0] upper_pair_count;

            assign lower_pair_count =
                {{(ENQUEUE_COUNT_WIDTH-1){1'b0}},
                  i_enqueue_valid[0]} +
                {{(ENQUEUE_COUNT_WIDTH-1){1'b0}},
                  i_enqueue_valid[1]};
            assign upper_pair_count =
                {{(ENQUEUE_COUNT_WIDTH-1){1'b0}},
                  i_enqueue_valid[2]} +
                {{(ENQUEUE_COUNT_WIDTH-1){1'b0}},
                  i_enqueue_valid[3]};
            assign enqueue_prefix_count[0] =
                {ENQUEUE_COUNT_WIDTH{1'b0}};
            assign enqueue_prefix_count[1] =
                {{(ENQUEUE_COUNT_WIDTH-1){1'b0}},
                  i_enqueue_valid[0]};
            assign enqueue_prefix_count[2] = lower_pair_count;
            assign enqueue_prefix_count[3] = lower_pair_count +
                {{(ENQUEUE_COUNT_WIDTH-1){1'b0}},
                  i_enqueue_valid[2]};
            assign enqueue_requested_count =
                lower_pair_count + upper_pair_count;
        end else begin : GEN_GENERIC_PREFIX
            for (prefix_output_lane = 0;
                 prefix_output_lane < ENQUEUE_PORTS;
                 prefix_output_lane = prefix_output_lane + 1) begin :
                 GEN_PREFIX_OUTPUT
                assign enqueue_prefix_count[prefix_output_lane] =
                    count_valid_prefix(
                        i_enqueue_valid, prefix_output_lane);
            end
            assign enqueue_requested_count =
                count_valid_prefix(i_enqueue_valid, ENQUEUE_PORTS);
        end
    endgenerate

    wire dequeue_fire;
    wire [CALC_COUNT_WIDTH-1:0] fifo_count_calc;
    wire [CALC_COUNT_WIDTH-1:0] occupancy_after_dequeue_calc;
    wire [CALC_COUNT_WIDTH-1:0] free_slot_count_calc;
    wire [CALC_COUNT_WIDTH-1:0] enqueue_requested_count_calc;
    wire [CALC_COUNT_WIDTH-1:0] enqueue_accepted_count_calc;
    wire [CALC_COUNT_WIDTH-1:0] occupancy_next_calc;
    wire [ENQUEUE_PORTS-1:0] enqueue_accept;
    wire enqueue_overflow;
    wire [CALC_COUNT_WIDTH-1:0]
        enqueue_prefix_count_calc [0:ENQUEUE_PORTS-1];
    wire [TAIL_CALC_WIDTH-1:0]
        enqueue_write_sum [0:ENQUEUE_PORTS-1];
    wire [TAIL_CALC_WIDTH-1:0]
        enqueue_write_normalized [0:ENQUEUE_PORTS-1];
    wire [PTR_WIDTH-1:0]
        enqueue_write_ptr [0:ENQUEUE_PORTS-1];
    wire [TAIL_CALC_WIDTH-1:0] enqueue_tail_sum;
    wire [TAIL_CALC_WIDTH-1:0] enqueue_tail_normalized;
    wire [PTR_WIDTH-1:0] enqueue_tail_next;
    wire enqueue_tail_wrap;

    assign dequeue_fire = i_dequeue_ready &&
        (o_count != {COUNT_WIDTH{1'b0}});
    assign fifo_count_calc =
        {{(CALC_COUNT_WIDTH-COUNT_WIDTH){1'b0}}, o_count};
    assign occupancy_after_dequeue_calc = dequeue_fire ?
        (fifo_count_calc -
         {{(CALC_COUNT_WIDTH-1){1'b0}}, 1'b1}) :
        fifo_count_calc;
    assign free_slot_count_calc =
        DEPTH[CALC_COUNT_WIDTH-1:0] -
        occupancy_after_dequeue_calc;
    assign enqueue_requested_count_calc =
        {{(CALC_COUNT_WIDTH-ENQUEUE_COUNT_WIDTH){1'b0}},
          enqueue_requested_count};
    assign enqueue_accepted_count_calc =
        (enqueue_requested_count_calc <= free_slot_count_calc) ?
        enqueue_requested_count_calc : free_slot_count_calc;
    assign enqueue_overflow =
        enqueue_requested_count_calc > free_slot_count_calc;
    assign occupancy_next_calc = occupancy_after_dequeue_calc +
        enqueue_accepted_count_calc;

    genvar enqueue_plan_lane;
    generate
        for (enqueue_plan_lane = 0;
             enqueue_plan_lane < ENQUEUE_PORTS;
             enqueue_plan_lane = enqueue_plan_lane + 1) begin :
             GEN_ENQUEUE_PLAN
            assign enqueue_prefix_count_calc[enqueue_plan_lane] =
                {{(CALC_COUNT_WIDTH-ENQUEUE_COUNT_WIDTH){1'b0}},
                  enqueue_prefix_count[enqueue_plan_lane]};
            assign enqueue_accept[enqueue_plan_lane] =
                i_enqueue_valid[enqueue_plan_lane] &&
                (enqueue_prefix_count_calc[enqueue_plan_lane] <
                 free_slot_count_calc);
            assign enqueue_write_sum[enqueue_plan_lane] =
                {{(TAIL_CALC_WIDTH-PTR_WIDTH){1'b0}}, o_tail_ptr} +
                {{(TAIL_CALC_WIDTH-CALC_COUNT_WIDTH){1'b0}},
                  enqueue_prefix_count_calc[enqueue_plan_lane]};
            assign enqueue_write_normalized[enqueue_plan_lane] =
                (enqueue_write_sum[enqueue_plan_lane] >= DEPTH) ?
                (enqueue_write_sum[enqueue_plan_lane] -
                 DEPTH[TAIL_CALC_WIDTH-1:0]) :
                enqueue_write_sum[enqueue_plan_lane];
            assign enqueue_write_ptr[enqueue_plan_lane] =
                enqueue_write_normalized[enqueue_plan_lane]
                    [PTR_WIDTH-1:0];
        end
    endgenerate

    assign enqueue_tail_sum =
        {{(TAIL_CALC_WIDTH-PTR_WIDTH){1'b0}}, o_tail_ptr} +
        {{(TAIL_CALC_WIDTH-CALC_COUNT_WIDTH){1'b0}},
          enqueue_accepted_count_calc};
    assign enqueue_tail_wrap =
        (enqueue_accepted_count_calc !=
         {CALC_COUNT_WIDTH{1'b0}}) &&
        (enqueue_tail_sum >= DEPTH);
    assign enqueue_tail_normalized = enqueue_tail_wrap ?
        (enqueue_tail_sum - DEPTH[TAIL_CALC_WIDTH-1:0]) :
        enqueue_tail_sum;
    assign enqueue_tail_next =
        enqueue_tail_normalized[PTR_WIDTH-1:0];

    integer reset_index;
    integer enqueue_lane;
    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            o_dequeue_valid <= 1'b0;
            o_dequeue_data <= {DATA_WIDTH{1'b1}};
            o_dequeue_logical_id <= {LOGICAL_ID_WIDTH{1'b0}};
            o_overflow <= 1'b0;
            o_count <= {COUNT_WIDTH{1'b0}};
            o_head_ptr <= {PTR_WIDTH{1'b0}};
            o_tail_ptr <= {PTR_WIDTH{1'b0}};
            o_enqueued_count <= {ENQUEUE_COUNT_WIDTH{1'b0}};
            o_dequeued <= 1'b0;
            o_head_wrapped <= 1'b0;
            o_tail_wrapped <= 1'b0;
            for (reset_index = 0; reset_index < DEPTH; reset_index = reset_index + 1) begin
                storage_data[reset_index] <= {DATA_WIDTH{1'b0}};
                storage_logical_id[reset_index] <= {LOGICAL_ID_WIDTH{1'b0}};
            end
        end else begin
            o_dequeue_valid <= 1'b0;
            o_enqueued_count <= {ENQUEUE_COUNT_WIDTH{1'b0}};
            o_dequeued <= 1'b0;
            o_head_wrapped <= 1'b0;
            o_tail_wrapped <= 1'b0;

            // No fall-through bypass: an item enqueued into an empty FIFO is
            // intentionally reported no earlier than the following cycle.
            if (dequeue_fire) begin
                o_dequeue_valid <= 1'b1;
                o_dequeue_data <= storage_data[o_head_ptr];
                o_dequeue_logical_id <= storage_logical_id[o_head_ptr];
                o_dequeued <= 1'b1;
                if (int'(o_head_ptr) == (DEPTH - 1)) begin
                    o_head_ptr <= {PTR_WIDTH{1'b0}};
                    o_head_wrapped <= 1'b1;
                end else begin
                    o_head_ptr <= o_head_ptr + 1'b1;
                end
            end

            // Lane number remains the deterministic order for same-cycle
            // returns.  Prefix counts give every accepted lane a unique
            // address without carrying a 32-bit integer tail through the
            // procedural loop.
            for (enqueue_lane = 0; enqueue_lane < ENQUEUE_PORTS;
                 enqueue_lane = enqueue_lane + 1) begin
                if (enqueue_accept[enqueue_lane]) begin
                    storage_data[enqueue_write_ptr[enqueue_lane]] <=
                        i_enqueue_data[enqueue_lane];
                    storage_logical_id[
                        enqueue_write_ptr[enqueue_lane]] <=
                        i_enqueue_logical_id[enqueue_lane];
                end
            end

            if (enqueue_overflow)
                o_overflow <= 1'b1;
            if (enqueue_accepted_count_calc !=
                {CALC_COUNT_WIDTH{1'b0}})
                o_tail_ptr <= enqueue_tail_next;
            if (enqueue_tail_wrap)
                o_tail_wrapped <= 1'b1;
            o_enqueued_count <= enqueue_accepted_count_calc
                [ENQUEUE_COUNT_WIDTH-1:0];
            o_count <= occupancy_next_calc[COUNT_WIDTH-1:0];
        end
    end

endmodule
