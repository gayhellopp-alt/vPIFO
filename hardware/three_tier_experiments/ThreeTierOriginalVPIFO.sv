`timescale 1ns / 10ps

// Hard-coded 1-root / 2-middle / 11-leaf scheduler around the original vPIFO
// engine.  Logical tree IDs are:
//   root: 0
//   middle: 1 (leaves 3..8), 2 (leaves 9..13)
//   leaves: 3..13
//
// A packet Push is retained as one descriptor and expanded into leaf, middle,
// and root Push tasks.  An external Pop is expanded into root, middle, and leaf
// Pops using the child IDs returned by the preceding level.  The wrapper uses
// one chain at a time so the same source can be synthesized with the M=2, M=4,
// and M=8 original engines without changing their interfaces.
module ThreeTierOriginalVPIFO #(
    parameter PTW = 16,
    parameter MTW = 16,
    parameter CTW = 10,
    parameter LEVEL = 6,
    parameter TREE_NUM = 14,
    parameter MIDDLE_COUNT = 2,
    parameter LEAF_COUNT = 11,
    parameter FIFO_SIZE = 8,
    localparam TREE_ID_WIDTH = (TREE_NUM <= 1) ? 1 : $clog2(TREE_NUM),
    localparam FIRST_LEAF_ID = 1 + MIDDLE_COUNT,
    localparam LAST_LEAF_ID = TREE_NUM - 1
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,

    input  wire                         i_push_valid,
    output wire                         o_push_ready,
    input  wire [TREE_ID_WIDTH-1:0]     i_leaf_id,
    input  wire [PTW-1:0]               i_root_rank,
    input  wire [PTW-1:0]               i_middle_rank,
    input  wire [PTW-1:0]               i_leaf_rank,
    input  wire [MTW-1:0]               i_payload,

    input  wire                         i_pop_valid,
    output wire                         o_pop_ready,
    output reg                          o_pop_valid,
    output reg [TREE_ID_WIDTH-1:0]      o_pop_leaf_id,
    output reg [MTW-1:0]                o_pop_payload,

    output wire                         o_busy,
    output reg                          o_protocol_error
);

    localparam [3:0] ST_IDLE            = 4'd0;
    localparam [3:0] ST_PUSH_LEAF       = 4'd1;
    localparam [3:0] ST_PUSH_MIDDLE     = 4'd2;
    localparam [3:0] ST_PUSH_ROOT       = 4'd3;
    localparam [3:0] ST_POP_ROOT_ISSUE  = 4'd4;
    localparam [3:0] ST_POP_ROOT_WAIT   = 4'd5;
    localparam [3:0] ST_POP_MID_ISSUE   = 4'd6;
    localparam [3:0] ST_POP_MID_WAIT    = 4'd7;
    localparam [3:0] ST_POP_LEAF_ISSUE  = 4'd8;
    localparam [3:0] ST_POP_LEAF_WAIT   = 4'd9;

    reg [3:0] state;
    reg [TREE_ID_WIDTH-1:0] saved_leaf_id;
    reg [TREE_ID_WIDTH-1:0] saved_middle_id;
    reg [PTW-1:0] saved_root_rank;
    reg [PTW-1:0] saved_middle_rank;
    reg [PTW-1:0] saved_leaf_rank;
    reg [MTW-1:0] saved_payload;

    reg [LEVEL-1:0] engine_push;
    reg [TREE_ID_WIDTH-1:0] engine_push_tree_id [0:LEVEL-1];
    reg [(MTW+PTW)-1:0] engine_push_data [0:LEVEL-1];
    reg [LEVEL-1:0] engine_pop;
    reg [TREE_ID_WIDTH-1:0] engine_pop_tree_id [0:LEVEL-1];
    wire [TREE_ID_WIDTH-1:0] engine_tree_id [0:LEVEL-1];
    wire [(MTW+PTW)-1:0] engine_pop_data [0:LEVEL-1];
    wire [LEVEL-1:0] engine_is_level0_pop;
    wire [LEVEL-1:0] engine_task_fifo_full;

    reg return_valid;
    reg return_multiple;
    reg [TREE_ID_WIDTH-1:0] return_tree_id;
    reg [(MTW+PTW)-1:0] return_data;
    integer drive_index;
    integer return_index;
    integer init_index;

    function automatic [TREE_ID_WIDTH-1:0] middle_for_leaf;
        input [TREE_ID_WIDTH-1:0] leaf_id;
        integer leaf_index;
        begin
            leaf_index = int'(leaf_id) - FIRST_LEAF_ID;
            if ((leaf_index < 0) || (leaf_index >= LEAF_COUNT))
                middle_for_leaf = {TREE_ID_WIDTH{1'b0}};
            else
                middle_for_leaf = TREE_ID_WIDTH'(
                    1 + ((leaf_index * MIDDLE_COUNT) / LEAF_COUNT));
        end
    endfunction

    function automatic leaf_id_is_valid;
        input [TREE_ID_WIDTH-1:0] leaf_id;
        begin
            leaf_id_is_valid =
                (leaf_id >= TREE_ID_WIDTH'(FIRST_LEAF_ID)) &&
                (leaf_id <= TREE_ID_WIDTH'(LAST_LEAF_ID));
        end
    endfunction

    assign o_push_ready = i_arst_n && (state == ST_IDLE);
    // Push wins if both inputs are asserted in the same cycle.
    assign o_pop_ready = i_arst_n && (state == ST_IDLE) && !i_push_valid;
    assign o_busy = (state != ST_IDLE);

    always @* begin
        engine_push = {LEVEL{1'b0}};
        engine_pop = {LEVEL{1'b0}};
        for (init_index = 0; init_index < LEVEL;
             init_index = init_index + 1) begin
            engine_push_tree_id[init_index] = {TREE_ID_WIDTH{1'b0}};
            engine_push_data[init_index] = {(MTW+PTW){1'b1}};
            engine_pop_tree_id[init_index] = {TREE_ID_WIDTH{1'b0}};
        end

        case (state)
            ST_PUSH_LEAF: begin
                drive_index = saved_leaf_id % LEVEL;
                engine_push[drive_index] = 1'b1;
                engine_push_tree_id[drive_index] = saved_leaf_id;
                engine_push_data[drive_index] =
                    {saved_payload, saved_leaf_rank};
            end
            ST_PUSH_MIDDLE: begin
                drive_index = saved_middle_id % LEVEL;
                engine_push[drive_index] = 1'b1;
                engine_push_tree_id[drive_index] = saved_middle_id;
                engine_push_data[drive_index] =
                    {saved_leaf_id,
                     {(MTW-TREE_ID_WIDTH){1'b0}},
                     saved_middle_rank};
            end
            ST_PUSH_ROOT: begin
                drive_index = 0;
                engine_push[drive_index] = 1'b1;
                engine_push_tree_id[drive_index] =
                    {TREE_ID_WIDTH{1'b0}};
                engine_push_data[drive_index] =
                    {saved_middle_id,
                     {(MTW-TREE_ID_WIDTH){1'b0}},
                     saved_root_rank};
            end
            ST_POP_ROOT_ISSUE: begin
                drive_index = 0;
                engine_pop[drive_index] = 1'b1;
                engine_pop_tree_id[drive_index] =
                    {TREE_ID_WIDTH{1'b0}};
            end
            ST_POP_MID_ISSUE: begin
                drive_index = saved_middle_id % LEVEL;
                engine_pop[drive_index] = 1'b1;
                engine_pop_tree_id[drive_index] = saved_middle_id;
            end
            ST_POP_LEAF_ISSUE: begin
                drive_index = saved_leaf_id % LEVEL;
                engine_pop[drive_index] = 1'b1;
                engine_pop_tree_id[drive_index] = saved_leaf_id;
            end
            default: drive_index = 0;
        endcase
    end

    always @* begin
        return_valid = 1'b0;
        return_multiple = 1'b0;
        return_tree_id = {TREE_ID_WIDTH{1'b0}};
        return_data = {(MTW+PTW){1'b1}};
        for (return_index = 0; return_index < LEVEL;
             return_index = return_index + 1) begin
            if (engine_is_level0_pop[return_index]) begin
                if (return_valid)
                    return_multiple = 1'b1;
                return_valid = 1'b1;
                return_tree_id = engine_tree_id[return_index];
                return_data = engine_pop_data[return_index];
            end
        end
    end

    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            state <= ST_IDLE;
            saved_leaf_id <= {TREE_ID_WIDTH{1'b0}};
            saved_middle_id <= {TREE_ID_WIDTH{1'b0}};
            saved_root_rank <= {PTW{1'b0}};
            saved_middle_rank <= {PTW{1'b0}};
            saved_leaf_rank <= {PTW{1'b0}};
            saved_payload <= {MTW{1'b0}};
            o_pop_valid <= 1'b0;
            o_pop_leaf_id <= {TREE_ID_WIDTH{1'b0}};
            o_pop_payload <= {MTW{1'b0}};
            o_protocol_error <= 1'b0;
        end else begin
            o_pop_valid <= 1'b0;
            if (return_multiple)
                o_protocol_error <= 1'b1;

            case (state)
                ST_IDLE: begin
                    if (i_push_valid) begin
                        if (!leaf_id_is_valid(i_leaf_id)) begin
                            o_protocol_error <= 1'b1;
                        end else begin
                            saved_leaf_id <= i_leaf_id;
                            saved_middle_id <= middle_for_leaf(i_leaf_id);
                            saved_root_rank <= i_root_rank;
                            saved_middle_rank <= i_middle_rank;
                            saved_leaf_rank <= i_leaf_rank;
                            saved_payload <= i_payload;
                            state <= ST_PUSH_LEAF;
                        end
                    end else if (i_pop_valid) begin
                        state <= ST_POP_ROOT_ISSUE;
                    end
                end
                ST_PUSH_LEAF:
                    if (!engine_task_fifo_full[saved_leaf_id % LEVEL])
                        state <= ST_PUSH_MIDDLE;
                ST_PUSH_MIDDLE:
                    if (!engine_task_fifo_full[saved_middle_id % LEVEL])
                        state <= ST_PUSH_ROOT;
                ST_PUSH_ROOT:
                    if (!engine_task_fifo_full[0])
                        state <= ST_IDLE;
                ST_POP_ROOT_ISSUE:
                    if (!engine_task_fifo_full[0])
                        state <= ST_POP_ROOT_WAIT;
                ST_POP_ROOT_WAIT:
                    if (return_valid) begin
                        saved_middle_id <=
                            return_data[(MTW+PTW)-1 -: TREE_ID_WIDTH];
                        if ((return_tree_id != TREE_ID_WIDTH'(0)) ||
                            !((return_data[(MTW+PTW)-1 -: TREE_ID_WIDTH] >=
                               TREE_ID_WIDTH'(1)) &&
                              (return_data[(MTW+PTW)-1 -: TREE_ID_WIDTH] <=
                               TREE_ID_WIDTH'(MIDDLE_COUNT))))
                            o_protocol_error <= 1'b1;
                        state <= ST_POP_MID_ISSUE;
                    end
                ST_POP_MID_ISSUE:
                    if (!engine_task_fifo_full[saved_middle_id % LEVEL])
                        state <= ST_POP_MID_WAIT;
                ST_POP_MID_WAIT:
                    if (return_valid) begin
                        saved_leaf_id <=
                            return_data[(MTW+PTW)-1 -: TREE_ID_WIDTH];
                        if ((return_tree_id != saved_middle_id) ||
                            !leaf_id_is_valid(
                                return_data[(MTW+PTW)-1 -: TREE_ID_WIDTH]) ||
                            (middle_for_leaf(
                                return_data[(MTW+PTW)-1 -: TREE_ID_WIDTH]) !=
                             saved_middle_id))
                            o_protocol_error <= 1'b1;
                        state <= ST_POP_LEAF_ISSUE;
                    end
                ST_POP_LEAF_ISSUE:
                    if (!engine_task_fifo_full[saved_leaf_id % LEVEL])
                        state <= ST_POP_LEAF_WAIT;
                ST_POP_LEAF_WAIT:
                    if (return_valid) begin
                        if (return_tree_id != saved_leaf_id)
                            o_protocol_error <= 1'b1;
                        o_pop_valid <= 1'b1;
                        o_pop_leaf_id <= saved_leaf_id;
                        o_pop_payload <= return_data[(MTW+PTW)-1 -: MTW];
                        state <= ST_IDLE;
                    end
                default: begin
                    state <= ST_IDLE;
                    o_protocol_error <= 1'b1;
                end
            endcase
        end
    end

    PIFO_SRAM_TOP #(
        .PTW(PTW),
        .MTW(MTW),
        .CTW(CTW),
        .LEVEL(LEVEL),
        .TREE_NUM(TREE_NUM),
        .FIFO_SIZE(FIFO_SIZE)
    ) engine (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_push_tree_id(engine_push_tree_id),
        .i_push(engine_push),
        .i_push_data(engine_push_data),
        .i_pop(engine_pop),
        .i_pop_tree_id(engine_pop_tree_id),
        .o_tree_id(engine_tree_id),
        .o_pop_data(engine_pop_data),
        .o_is_level0_pop(engine_is_level0_pop),
        .o_task_fifo_full(engine_task_fifo_full)
    );

endmodule
