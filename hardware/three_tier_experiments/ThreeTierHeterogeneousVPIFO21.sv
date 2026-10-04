`timescale 1ns / 10ps

// Boundary experiment: one root, four middle nodes, and sixteen leaves.
// Sixteen leaf-capacity units are stored at every scheduler tier:
//   root         : 16 shards
//   four middles : 4 shards each
//   sixteen leaf : 1 shard each
// The resulting 21 logical PIFOs occupy exactly 48 M=2/L=6 shards.
module ThreeTierHeterogeneousVPIFO21 #(
    parameter PTW = 16,
    parameter MTW = 32,
    parameter CTW = 10,
    parameter FIFO_SIZE = 8,
    parameter TASK_ORDER_WIDTH = 32,
    parameter LOGICAL_PENDING_DEPTH = 16,
    localparam LOGICAL_ID_WIDTH = 5
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,
    input  wire                         i_push_valid,
    output wire                         o_push_ready,
    input  wire [LOGICAL_ID_WIDTH-1:0]  i_leaf_id,
    input  wire [PTW-1:0]               i_root_rank,
    input  wire [PTW-1:0]               i_middle_rank,
    input  wire [PTW-1:0]               i_leaf_rank,
    input  wire [MTW-1:0]               i_payload,
    input  wire                         i_pop_valid,
    output wire                         o_pop_ready,
    output wire                         o_pop_valid,
    output wire [LOGICAL_ID_WIDTH-1:0]  o_pop_leaf_id,
    output wire [MTW-1:0]               o_pop_payload,
    output wire                         o_busy,
    output wire                         o_protocol_error
);

    localparam integer LOGICAL_TREE_NUM = 21;
    localparam integer PHYSICAL_TREE_NUM = 48;
    localparam integer MIDDLE_COUNT = 4;
    localparam integer LEAF_COUNT = 16;
    localparam integer SHARD_COUNTS [0:LOGICAL_TREE_NUM-1] =
        '{16, 4, 4, 4, 4,
          1, 1, 1, 1, 1, 1, 1, 1,
          1, 1, 1, 1, 1, 1, 1, 1};
    localparam integer SHARD_OFFSETS [0:LOGICAL_TREE_NUM-1] =
        '{0, 16, 20, 24, 28,
          32, 33, 34, 35, 36, 37, 38, 39,
          40, 41, 42, 43, 44, 45, 46, 47};
    localparam integer EXPLICIT_SHARD_MAP [0:PHYSICAL_TREE_NUM-1] =
        '{0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0};

    ThreeTierHeterogeneousVPIFO #(
        .PTW(PTW),
        .MTW(MTW),
        .CTW(CTW),
        .FIFO_SIZE(FIFO_SIZE),
        .TASK_ORDER_WIDTH(TASK_ORDER_WIDTH),
        .LOGICAL_PENDING_DEPTH(LOGICAL_PENDING_DEPTH),
        .MIDDLE_COUNT(MIDDLE_COUNT),
        .LEAF_COUNT(LEAF_COUNT),
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .PHYSICAL_TREE_NUM(PHYSICAL_TREE_NUM),
        .SHARD_CAPACITY(126),
        .MAX_SHARDS_PER_LOGICAL(16),
        .SHARD_COUNTS(SHARD_COUNTS),
        .SHARD_OFFSETS(SHARD_OFFSETS),
        .EXPLICIT_SHARD_MAP(EXPLICIT_SHARD_MAP)
    ) impl (
        .i_clk(i_clk),
        .i_arst_n(i_arst_n),
        .i_push_valid(i_push_valid),
        .o_push_ready(o_push_ready),
        .i_leaf_id(i_leaf_id),
        .i_root_rank(i_root_rank),
        .i_middle_rank(i_middle_rank),
        .i_leaf_rank(i_leaf_rank),
        .i_payload(i_payload),
        .i_pop_valid(i_pop_valid),
        .o_pop_ready(o_pop_ready),
        .o_pop_valid(o_pop_valid),
        .o_pop_leaf_id(o_pop_leaf_id),
        .o_pop_payload(o_pop_payload),
        .o_busy(o_busy),
        .o_protocol_error(o_protocol_error)
    );

endmodule
