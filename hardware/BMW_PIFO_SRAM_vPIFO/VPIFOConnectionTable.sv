`timescale 1ns / 1ps

// Static type and connection lookup generated from schema-version-2 VPIFO IR.
//
// This is the hardware equivalent of resolving the two VPIFO subclasses at
// compile time.  No packet-carried parent ID is trusted: a timing node selects
// both its timing-domain local ID and its schedule-domain release target here.
module VPIFOConnectionTable #(
    parameter GLOBAL_NODE_NUM =
        GeneralizedVpifoConfigPkg::GLOBAL_NODE_NUM,
    parameter SCHEDULE_NODE_NUM =
        GeneralizedVpifoConfigPkg::SCHEDULE_LOGICAL_TREE_NUM,
    parameter SCHEDULE_SEMANTIC_TREE_NUM =
        GeneralizedVpifoConfigPkg::SCHEDULE_SEMANTIC_TREE_NUM,
    parameter TIMING_NODE_NUM =
        GeneralizedVpifoConfigPkg::TIMING_LOGICAL_TREE_NUM,
    parameter integer VPIFO_KIND_SCHEDULE =
        GeneralizedVpifoConfigPkg::VPIFO_KIND_SCHEDULE,
    parameter integer VPIFO_KIND_TIMING =
        GeneralizedVpifoConfigPkg::VPIFO_KIND_TIMING,
    parameter integer GLOBAL_NODE_KIND [0:GLOBAL_NODE_NUM-1] =
        GeneralizedVpifoConfigPkg::GLOBAL_NODE_KIND,
    parameter integer GLOBAL_TO_SCHEDULE [0:GLOBAL_NODE_NUM-1] =
        GeneralizedVpifoConfigPkg::GLOBAL_TO_SCHEDULE,
    parameter integer GLOBAL_TO_TIMING [0:GLOBAL_NODE_NUM-1] =
        GeneralizedVpifoConfigPkg::GLOBAL_TO_TIMING,
    parameter integer SCHEDULE_TO_GLOBAL [0:SCHEDULE_NODE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_TO_GLOBAL,
    parameter integer SCHEDULE_NODE_TREE_ID [0:SCHEDULE_NODE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_NODE_TREE_ID,
    parameter integer SCHEDULE_NODE_IS_ROOT [0:SCHEDULE_NODE_NUM-1] =
        GeneralizedVpifoConfigPkg::SCHEDULE_NODE_IS_ROOT,
    parameter integer TIMING_RELEASE_TO_SCHEDULE [0:TIMING_NODE_NUM-1] =
        GeneralizedVpifoConfigPkg::TIMING_RELEASE_TO_SCHEDULE,
    parameter integer TIMING_PROGRAM_MODE [0:TIMING_NODE_NUM-1] =
        GeneralizedVpifoConfigPkg::TIMING_PROGRAM_MODE,

    localparam GLOBAL_ID_WIDTH = (GLOBAL_NODE_NUM <= 1) ? 1 :
                                 $clog2(GLOBAL_NODE_NUM),
    localparam SCHEDULE_ID_WIDTH = (SCHEDULE_NODE_NUM <= 1) ? 1 :
                                   $clog2(SCHEDULE_NODE_NUM),
    localparam SCHEDULE_SEMANTIC_TREE_ID_WIDTH =
        (SCHEDULE_SEMANTIC_TREE_NUM <= 1) ? 1 :
        $clog2(SCHEDULE_SEMANTIC_TREE_NUM),
    localparam TIMING_ID_WIDTH = (TIMING_NODE_NUM <= 1) ? 1 :
                                 $clog2(TIMING_NODE_NUM)
)(
    input  wire [GLOBAL_ID_WIDTH-1:0]   i_timing_global_id,
    output reg                          o_timing_valid,
    output reg [TIMING_ID_WIDTH-1:0]    o_timing_local_id,
    output reg [SCHEDULE_ID_WIDTH-1:0]  o_release_schedule_local_id,
    output reg [2:0]                    o_timing_program_mode,

    input  wire [GLOBAL_ID_WIDTH-1:0]   i_schedule_global_id,
    output reg                          o_schedule_leaf_valid,
    output reg [SCHEDULE_ID_WIDTH-1:0]  o_schedule_local_id,

    input  wire [GLOBAL_ID_WIDTH-1:0]   i_schedule_root_global_id,
    output reg                          o_schedule_root_valid,
    output reg [SCHEDULE_SEMANTIC_TREE_ID_WIDTH-1:0]
                                        o_schedule_semantic_tree_id,

    input  wire [SCHEDULE_ID_WIDTH-1:0] i_schedule_local_id,
    output reg                          o_schedule_local_valid,
    output reg [GLOBAL_ID_WIDTH-1:0]    o_schedule_global_id
);

    integer timing_global_integer;
    integer timing_local_integer;
    integer schedule_global_integer;
    integer schedule_local_integer;
    integer reverse_local_integer;
    integer root_global_integer;
    integer root_local_integer;

    always @(*) begin
        timing_global_integer = int'(i_timing_global_id);
        timing_local_integer = 0;
        o_timing_valid = 1'b0;
        o_timing_local_id = {TIMING_ID_WIDTH{1'b0}};
        o_release_schedule_local_id =
            {SCHEDULE_ID_WIDTH{1'b0}};
        o_timing_program_mode = 3'd0;
        if ((timing_global_integer >= 0) &&
            (timing_global_integer < GLOBAL_NODE_NUM) &&
            (GLOBAL_NODE_KIND[timing_global_integer] ==
             VPIFO_KIND_TIMING)) begin
            timing_local_integer =
                GLOBAL_TO_TIMING[timing_global_integer];
            if ((timing_local_integer >= 0) &&
                (timing_local_integer < TIMING_NODE_NUM)) begin
                o_timing_valid = 1'b1;
                o_timing_local_id =
                    timing_local_integer[TIMING_ID_WIDTH-1:0];
                o_release_schedule_local_id =
                    TIMING_RELEASE_TO_SCHEDULE[timing_local_integer]
                        [SCHEDULE_ID_WIDTH-1:0];
                o_timing_program_mode =
                    TIMING_PROGRAM_MODE[timing_local_integer][2:0];
            end
        end

        schedule_global_integer = int'(i_schedule_global_id);
        schedule_local_integer = 0;
        o_schedule_leaf_valid = 1'b0;
        o_schedule_local_id = {SCHEDULE_ID_WIDTH{1'b0}};
        if ((schedule_global_integer >= 0) &&
            (schedule_global_integer < GLOBAL_NODE_NUM) &&
            (GLOBAL_NODE_KIND[schedule_global_integer] ==
             VPIFO_KIND_SCHEDULE)) begin
            schedule_local_integer =
                GLOBAL_TO_SCHEDULE[schedule_global_integer];
            if ((schedule_local_integer >= 0) &&
                (schedule_local_integer < SCHEDULE_NODE_NUM) &&
                (SCHEDULE_NODE_IS_ROOT[schedule_local_integer] == 0)) begin
                o_schedule_leaf_valid = 1'b1;
                o_schedule_local_id =
                    schedule_local_integer[SCHEDULE_ID_WIDTH-1:0];
            end
        end

        root_global_integer = int'(i_schedule_root_global_id);
        root_local_integer = 0;
        o_schedule_root_valid = 1'b0;
        o_schedule_semantic_tree_id =
            {SCHEDULE_SEMANTIC_TREE_ID_WIDTH{1'b0}};
        if ((root_global_integer >= 0) &&
            (root_global_integer < GLOBAL_NODE_NUM) &&
            (GLOBAL_NODE_KIND[root_global_integer] ==
             VPIFO_KIND_SCHEDULE)) begin
            root_local_integer = GLOBAL_TO_SCHEDULE[root_global_integer];
            if ((root_local_integer >= 0) &&
                (root_local_integer < SCHEDULE_NODE_NUM) &&
                (SCHEDULE_NODE_IS_ROOT[root_local_integer] != 0) &&
                (SCHEDULE_NODE_TREE_ID[root_local_integer] >= 0) &&
                (SCHEDULE_NODE_TREE_ID[root_local_integer] <
                 SCHEDULE_SEMANTIC_TREE_NUM)) begin
                o_schedule_root_valid = 1'b1;
                o_schedule_semantic_tree_id =
                    SCHEDULE_NODE_TREE_ID[root_local_integer]
                        [SCHEDULE_SEMANTIC_TREE_ID_WIDTH-1:0];
            end
        end

        reverse_local_integer = int'(i_schedule_local_id);
        o_schedule_local_valid = 1'b0;
        o_schedule_global_id = {GLOBAL_ID_WIDTH{1'b0}};
        if ((reverse_local_integer >= 0) &&
            (reverse_local_integer < SCHEDULE_NODE_NUM)) begin
            o_schedule_local_valid = 1'b1;
            o_schedule_global_id =
                SCHEDULE_TO_GLOBAL[reverse_local_integer]
                    [GLOBAL_ID_WIDTH-1:0];
        end
    end

    initial begin
        if ((GLOBAL_NODE_NUM < 3) || (SCHEDULE_NODE_NUM < 2) ||
            (SCHEDULE_SEMANTIC_TREE_NUM < 1) ||
            (TIMING_NODE_NUM < 1))
            $fatal(1, "VPIFOConnectionTable parameters invalid");
    end

endmodule
