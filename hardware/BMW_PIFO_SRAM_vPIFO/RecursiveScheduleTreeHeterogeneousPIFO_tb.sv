`timescale 1ns / 10ps

module RecursiveScheduleTreeHeterogeneousPIFO_tb;
    localparam PTW = 16;
    localparam MTW = 16;
    localparam DATA_WIDTH = PTW + MTW;
    localparam LOGICAL_TREE_NUM = 4;
    localparam LOGICAL_ID_WIDTH = 2;
    localparam integer TREE_ROOTS [0:0] = '{0};
    localparam integer NODE_PARENT [0:3] = '{0, 0, 0, 2};
    localparam integer NODE_DEPTH [0:3] = '{0, 1, 1, 2};
    localparam integer NODE_TREE_ID [0:3] = '{0, 0, 0, 0};
    localparam integer SHARD_COUNTS [0:3] = '{3, 1, 1, 1};
    localparam integer SHARD_OFFSETS [0:3] = '{0, 3, 4, 5};
    localparam integer EXPLICIT_SHARD_MAP [0:5] =
        '{0, 1, 2, 3, 4, 5};

    localparam [1:0] NODE_ROOT = 2'd0;
    localparam [1:0] NODE_X = 2'd1;
    localparam [1:0] NODE_Y = 2'd2;
    localparam [1:0] NODE_Z = 2'd3;

    reg clk;
    reg arst_n;
    reg push;
    reg [1:0] push_mode;
    reg [LOGICAL_ID_WIDTH-1:0] push_target;
    reg [LOGICAL_ID_WIDTH-1:0] push_boundary;
    reg [PTW-1:0] push_rank [0:LOGICAL_TREE_NUM-1];
    reg [DATA_WIDTH-1:0] push_data;
    wire push_ready;
    wire reject_bad_push;
    reg pop;
    wire pop_ready;
    wire pop_out;
    wire [LOGICAL_ID_WIDTH-1:0] pop_node;
    wire [DATA_WIDTH-1:0] pop_data;
    wire busy;
    wire protocol_error;
    wire [5:0] pending_count;
    wire [9:0] logical_count [0:LOGICAL_TREE_NUM-1];

    integer watchdog;
    integer rank_init;

    always #2 clk = ~clk;

    RecursiveScheduleTreeHeterogeneousPIFO #(
        .PTW(PTW),
        .MTW(MTW),
        .CTW(10),
        .LEVEL(6),
        .LOGICAL_TREE_NUM(LOGICAL_TREE_NUM),
        .SEMANTIC_TREE_NUM(1),
        .PHYSICAL_TREE_NUM(6),
        .SHARD_CAPACITY(126),
        .MAX_SHARDS_PER_LOGICAL(3),
        .MAX_TREE_DEPTH(3),
        .LOGICAL_PENDING_DEPTH(32),
        .POP_RESULT_FIFO_DEPTH(12),
        .POP_TRACK_DEPTH(16),
        .TREE_ROOTS(TREE_ROOTS),
        .NODE_PARENT(NODE_PARENT),
        .NODE_DEPTH(NODE_DEPTH),
        .NODE_TREE_ID(NODE_TREE_ID),
        .SHARD_COUNTS(SHARD_COUNTS),
        .SHARD_OFFSETS(SHARD_OFFSETS),
        .EXPLICIT_SHARD_MAP(EXPLICIT_SHARD_MAP)
    ) dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_push(push),
        .i_push_mode(push_mode),
        .i_push_target_node_id(push_target),
        .i_push_boundary_node_id(push_boundary),
        .i_push_rank_by_node(push_rank),
        .i_push_packet_data(push_data),
        .o_push_ready(push_ready),
        .o_reject_bad_push_path(reject_bad_push),
        .i_pop(pop),
        .i_pop_semantic_tree_id(1'b0),
        .o_pop_ready(pop_ready),
        .o_reject_bad_tree_id(),
        .o_pop_out(pop_out),
        .o_pop_semantic_tree_id(),
        .o_pop_packet_node_id(pop_node),
        .o_pop_data(pop_data),
        .o_busy(busy),
        .o_protocol_error(protocol_error),
        .o_outstanding_pop_count(),
        .o_pending_count(pending_count),
        .o_logical_count(logical_count),
        .o_physical_dispatch_fire(),
        .o_physical_dispatch_push(),
        .o_selected_physical_tree_id(),
        .o_physical_shard_count()
    );

    task automatic send_packet;
        input [1:0] target;
        input [14:0] packet_id;
        input [15:0] root_rank;
        input [15:0] x_rank;
        input [15:0] y_rank;
        input [15:0] z_rank;
        begin
            push_mode = 2'd0;
            push_target = target;
            push_boundary = NODE_ROOT;
            push_rank[0] = root_rank;
            push_rank[1] = x_rank;
            push_rank[2] = y_rank;
            push_rank[3] = z_rank;
            push_data = {1'b0, packet_id, 16'b0};
            push = 1'b1;
            @(posedge clk);
            while (!push_ready)
                @(posedge clk);
            @(negedge clk);
            push = 1'b0;
        end
    endtask

    task automatic send_local_packet;
        input [1:0] target;
        input [1:0] boundary;
        input [14:0] packet_id;
        input [15:0] root_rank;
        input [15:0] y_rank;
        input [15:0] z_rank;
        begin
            push_mode = 2'd1;
            push_target = target;
            push_boundary = boundary;
            push_rank[0] = root_rank;
            push_rank[1] = 16'hffff;
            push_rank[2] = y_rank;
            push_rank[3] = z_rank;
            push_data = {1'b0, packet_id, 16'b0};
            push = 1'b1;
            @(posedge clk);
            while (!push_ready)
                @(posedge clk);
            @(negedge clk);
            push = 1'b0;
        end
    endtask

    task automatic send_parent_reference;
        input [1:0] boundary;
        input [15:0] root_rank;
        begin
            push_mode = 2'd2;
            push_target = boundary;
            push_boundary = boundary;
            push_rank[0] = root_rank;
            push_rank[1] = 16'hffff;
            push_rank[2] = 16'hffff;
            push_rank[3] = 16'hffff;
            push_data = {DATA_WIDTH{1'b0}};
            push = 1'b1;
            @(posedge clk);
            while (!push_ready)
                @(posedge clk);
            @(negedge clk);
            push = 1'b0;
        end
    endtask

    task automatic wait_for_idle;
        begin
            watchdog = 0;
            while ((pending_count != 0 || busy) &&
                   (watchdog < 30000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (watchdog == 30000)
                $fatal(1, "timeout draining recursive operations");
        end
    endtask

    task automatic pop_and_expect;
        input [1:0] expected_node;
        input [14:0] expected_packet_id;
        begin
            while (!pop_ready)
                @(negedge clk);
            pop = 1'b1;
            @(negedge clk);
            pop = 1'b0;
            watchdog = 0;
            while (!pop_out && (watchdog < 20000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (!pop_out)
                $fatal(1, "timeout waiting for recursive Pop result");
            if ((pop_node !== expected_node) ||
                (pop_data[30:16] !== expected_packet_id))
                $fatal(1,
                    "recursive Pop mismatch node=%0d/%0d packet=%0d/%0d",
                    pop_node, expected_node,
                    pop_data[30:16], expected_packet_id);
        end
    endtask

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        push = 1'b0;
        push_mode = 2'd0;
        pop = 1'b0;
        push_target = 0;
        push_boundary = NODE_ROOT;
        push_data = 0;
        for (rank_init = 0; rank_init < LOGICAL_TREE_NUM;
             rank_init = rank_init + 1)
            push_rank[rank_init] = 16'hffff;

        repeat (8) @(negedge clk);
        arst_n = 1'b1;
        repeat (4) @(negedge clk);

        // Root SP: F(0) < X(1) < Y(2).
        // X order: E(5) < D(10).
        // Y order: Z/A(10) < C(20) < Z/B(30).
        // Z SP: A(0) < B(1).
        send_packet(NODE_ROOT, 15'd6, 16'd0,
                    16'hffff, 16'hffff, 16'hffff); // F
        send_packet(NODE_X, 15'd5, 16'd1,
                    16'd5, 16'hffff, 16'hffff);    // E
        send_packet(NODE_Z, 15'd1, 16'd2,
                    16'hffff, 16'd10, 16'd0);      // A
        send_packet(NODE_Y, 15'd3, 16'd2,
                    16'hffff, 16'd20, 16'hffff);   // C
        send_packet(NODE_Z, 15'd2, 16'd2,
                    16'hffff, 16'd30, 16'd1);      // B
        send_packet(NODE_X, 15'd4, 16'd1,
                    16'd10, 16'hffff, 16'hffff);   // D

        wait_for_idle();
        if ((logical_count[0] != 6) || (logical_count[1] != 2) ||
            (logical_count[2] != 3) || (logical_count[3] != 2))
            $fatal(1, "unexpected logical counts %0d %0d %0d %0d",
                logical_count[0], logical_count[1],
                logical_count[2], logical_count[3]);

        pop_and_expect(NODE_ROOT, 15'd6);
        pop_and_expect(NODE_X, 15'd5);
        pop_and_expect(NODE_X, 15'd4);
        pop_and_expect(NODE_Z, 15'd1);
        pop_and_expect(NODE_Y, 15'd3);
        pop_and_expect(NODE_Z, 15'd2);

        watchdog = 0;
        while (busy && (watchdog < 30000)) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (|{logical_count[0], logical_count[1],
              logical_count[2], logical_count[3]})
            $fatal(1, "recursive schedule tree did not drain");

        // Split shaping boundary at Y.  A is locally inserted into Z and Y;
        // C is locally inserted into Y.  Neither operation reaches Root.
        send_local_packet(NODE_Z, NODE_Y, 15'd10,
                          16'd2, 16'd5, 16'd0);
        send_local_packet(NODE_Y, NODE_Y, 15'd11,
                          16'd2, 16'd10, 16'hffff);
        wait_for_idle();
        if ((logical_count[NODE_ROOT] != 0) ||
            (logical_count[NODE_Y] != 2) ||
            (logical_count[NODE_Z] != 1))
            $fatal(1, "split local counts wrong Root=%0d Y=%0d Z=%0d",
                logical_count[NODE_ROOT], logical_count[NODE_Y],
                logical_count[NODE_Z]);

        // Each released shaping opportunity resumes above Y.  Because Y's
        // parent is Root, these operations insert REF(Y) into Root only.
        send_parent_reference(NODE_Y, 16'd2);
        send_parent_reference(NODE_Y, 16'd2);
        wait_for_idle();
        if ((logical_count[NODE_ROOT] != 2) ||
            (logical_count[NODE_Y] != 2) ||
            (logical_count[NODE_Z] != 1))
            $fatal(1, "split resume counts wrong Root=%0d Y=%0d Z=%0d",
                logical_count[NODE_ROOT], logical_count[NODE_Y],
                logical_count[NODE_Z]);

        pop_and_expect(NODE_Z, 15'd10);
        pop_and_expect(NODE_Y, 15'd11);
        wait_for_idle();
        if (|{logical_count[0], logical_count[1],
              logical_count[2], logical_count[3]})
            $fatal(1, "split schedule tree did not drain");
        if (reject_bad_push || protocol_error)
            $fatal(1, "recursive schedule protocol error");

        $display("PASS: variable-depth scheduling and split Y boundary");
        $finish;
    end

    initial begin
        repeat (200000) @(posedge clk);
        $fatal(1, "timeout");
    end
endmodule
