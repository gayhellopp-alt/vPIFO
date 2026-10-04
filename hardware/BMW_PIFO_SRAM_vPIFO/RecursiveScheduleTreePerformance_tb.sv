`timescale 1ns / 10ps

// Dequeue-only throughput measurement for each semantic path length in the
// Root/X/Y/Z experiment.  Queue fill and final drain are excluded from the
// steady completion window.
module RecursiveScheduleTreePerformance_tb;
    localparam PTW = 16;
    localparam MTW = 16;
    localparam DATA_WIDTH = 32;
    localparam PACKETS = 48;
    localparam CLOCK_MHZ = 125;
    localparam [1:0] NODE_ROOT = 2'd0;
    localparam integer TREE_ROOTS [0:0] = '{0};
    localparam integer NODE_PARENT [0:3] = '{0, 0, 0, 2};
    localparam integer NODE_DEPTH [0:3] = '{0, 1, 1, 2};
    localparam integer NODE_TREE_ID [0:3] = '{0, 0, 0, 0};
    localparam integer SHARD_COUNTS [0:3] = '{3, 1, 1, 1};
    localparam integer SHARD_OFFSETS [0:3] = '{0, 3, 4, 5};
    localparam integer EXPLICIT_SHARD_MAP [0:5] =
        '{0, 1, 2, 3, 4, 5};

    reg clk;
    reg arst_n;
    reg push;
    wire push_ready;
    reg [1:0] push_target;
    reg [PTW-1:0] push_rank [0:3];
    reg [DATA_WIDTH-1:0] push_data;
    reg pop;
    wire pop_ready;
    wire pop_out;
    wire [1:0] pop_node;
    wire [DATA_WIDTH-1:0] pop_data;
    wire busy;
    wire protocol_error;
    wire [5:0] pending_count;
    wire [9:0] logical_count [0:3];

    integer phase;
    integer request_count;
    integer output_count;
    integer request_first_cycle;
    integer request_last_cycle;
    integer output_first_cycle;
    integer output_last_cycle;
    integer cycle_counter;
    integer watchdog;
    integer packet_index;
    integer completion_window;
    integer request_window;
    integer end_to_end_window;
    longint ppc_scaled_1e6;
    longint pps_at_clock;

    always #2 clk = ~clk;

    RecursiveScheduleTreeHeterogeneousPIFO #(
        .PTW(PTW),
        .MTW(MTW),
        .CTW(10),
        .LEVEL(6),
        .LOGICAL_TREE_NUM(4),
        .SEMANTIC_TREE_NUM(1),
        .PHYSICAL_TREE_NUM(6),
        .SHARD_CAPACITY(126),
        .MAX_SHARDS_PER_LOGICAL(3),
        .MAX_TREE_DEPTH(3),
        .LOGICAL_PENDING_DEPTH(32),
        .POP_RESULT_FIFO_DEPTH(16),
        .POP_TRACK_DEPTH(32),
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
        .i_push_mode(2'd0),
        .i_push_target_node_id(push_target),
        .i_push_boundary_node_id(NODE_ROOT),
        .i_push_rank_by_node(push_rank),
        .i_push_packet_data(push_data),
        .o_push_ready(push_ready),
        .o_reject_bad_push_path(),
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

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n)
            cycle_counter <= 0;
        else
            cycle_counter <= cycle_counter + 1;
    end

    task automatic reset_phase;
        begin
            phase = 0;
            push = 1'b0;
            pop = 1'b0;
            arst_n = 1'b0;
            repeat (8) @(negedge clk);
            arst_n = 1'b1;
            repeat (4) @(negedge clk);
        end
    endtask

    task automatic preload_path;
        input [1:0] target;
        integer preload_index;
        begin
            for (preload_index = 0;
                 preload_index < PACKETS;
                 preload_index = preload_index + 1) begin
                push_target = target;
                push_rank[0] = (target == 0) ?
                    preload_index[15:0] :
                    ((target == 1) ? 16'd1 : 16'd2);
                push_rank[1] = preload_index[15:0];
                push_rank[2] = preload_index[15:0];
                push_rank[3] = preload_index[15:0];
                push_data = {1'b0, preload_index[14:0], 16'b0};
                push = 1'b1;
                @(posedge clk);
                while (!push_ready)
                    @(posedge clk);
                @(negedge clk);
                push = 1'b0;
            end
            watchdog = 0;
            while ((pending_count != 0 || busy) &&
                   (watchdog < 100000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (watchdog == 100000)
                $fatal(1, "timeout preloading performance path");
        end
    endtask

    task automatic measure_path;
        input integer phase_id;
        input integer output_node;
        input [8*8-1:0] path_name;
        integer request_index;
        begin
            phase = phase_id;
            request_count = 0;
            output_count = 0;
            request_first_cycle = 0;
            request_last_cycle = 0;
            output_first_cycle = 0;
            output_last_cycle = 0;
            watchdog = 0;
            fork
                begin : issue_requests
                    for (request_index = 0;
                         request_index < PACKETS;
                         request_index = request_index + 1) begin
                        pop = 1'b1;
                        @(posedge clk);
                        while (!pop_ready)
                            @(posedge clk);
                        if (request_count == 0)
                            request_first_cycle = cycle_counter;
                        request_last_cycle = cycle_counter;
                        request_count = request_count + 1;
                        @(negedge clk);
                        pop = 1'b0;
                    end
                end
                begin : collect_outputs
                    while ((output_count < PACKETS) &&
                           (watchdog < 400000)) begin
                        @(negedge clk);
                        watchdog = watchdog + 1;
                        if (pop_out) begin
                            if (output_count == 0)
                                output_first_cycle = cycle_counter;
                            output_last_cycle = cycle_counter;
                            if ((pop_node !== output_node[1:0]) ||
                                (pop_data[30:16] !==
                                 output_count[14:0]))
                                $fatal(1,
                                    "performance output mismatch phase=%0d node=%0d/%0d id=%0d/%0d",
                                    phase, pop_node, output_node,
                                    pop_data[30:16], output_count);
                            output_count = output_count + 1;
                        end
                    end
                end
            join
            if ((request_count != PACKETS) ||
                (output_count != PACKETS))
                $fatal(1,
                    "performance phase timeout req=%0d out=%0d",
                    request_count, output_count);

            request_window = request_last_cycle -
                request_first_cycle + 1;
            completion_window = output_last_cycle -
                output_first_cycle + 1;
            end_to_end_window = output_last_cycle -
                request_first_cycle + 1;
            ppc_scaled_1e6 = (PACKETS * 64'd1000000) /
                completion_window;
            pps_at_clock = (PACKETS * CLOCK_MHZ * 64'd1000000) /
                completion_window;
            $display("PERF,path=%0s,packets=%0d,request_cycles=%0d,completion_cycles=%0d,e2e_cycles=%0d,ppc_x1e6=%0d,pps_at_%0dMHz=%0d",
                path_name, PACKETS, request_window,
                completion_window, end_to_end_window,
                ppc_scaled_1e6, CLOCK_MHZ, pps_at_clock);
            watchdog = 0;
            while (busy && (watchdog < 100000)) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (|{logical_count[0], logical_count[1],
                  logical_count[2], logical_count[3]})
                $fatal(1, "performance phase did not drain");
            if (protocol_error)
                $fatal(1, "performance phase protocol_error");
            phase = 0;
        end
    endtask

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        phase = 0;
        push = 1'b0;
        pop = 1'b0;
        push_target = 0;
        push_data = 0;
        for (packet_index = 0; packet_index < 4;
             packet_index = packet_index + 1)
            push_rank[packet_index] = 0;

        reset_phase();
        preload_path(2'd0);
        measure_path(1, 0, "Root");

        reset_phase();
        preload_path(2'd1);
        measure_path(2, 1, "X_Root");

        reset_phase();
        preload_path(2'd3);
        measure_path(3, 3, "Z_Y_Root");

        $display("PASS: recursive schedule path throughput measurements");
        $finish;
    end

    initial begin
        repeat (1000000) @(posedge clk);
        $fatal(1, "timeout");
    end
endmodule
