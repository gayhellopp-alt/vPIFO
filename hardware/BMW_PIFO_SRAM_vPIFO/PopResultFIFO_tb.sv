`timescale 1ns / 1ps

module PopResultFIFO_tb;
    localparam DATA_WIDTH = 32;
    localparam LOGICAL_ID_WIDTH = 2;
    localparam ENQUEUE_PORTS = 4;
    localparam DEPTH = 8;
    localparam PTR_WIDTH = $clog2(DEPTH);
    localparam COUNT_WIDTH = $clog2(DEPTH + 1);
    localparam ENQUEUE_COUNT_WIDTH = $clog2(ENQUEUE_PORTS + 1);

    reg clk;
    reg arst_n;
    reg [ENQUEUE_PORTS-1:0] enqueue_valid;
    reg [DATA_WIDTH-1:0] enqueue_data [0:ENQUEUE_PORTS-1];
    reg [LOGICAL_ID_WIDTH-1:0] enqueue_logical_id [0:ENQUEUE_PORTS-1];
    reg dequeue_ready;

    wire dequeue_valid;
    wire [DATA_WIDTH-1:0] dequeue_data;
    wire [LOGICAL_ID_WIDTH-1:0] dequeue_logical_id;
    wire overflow;
    wire [COUNT_WIDTH-1:0] fifo_count;
    wire [PTR_WIDTH-1:0] head_ptr;
    wire [PTR_WIDTH-1:0] tail_ptr;
    wire [ENQUEUE_COUNT_WIDTH-1:0] enqueued_count;
    wire dequeued;
    wire head_wrapped;
    wire tail_wrapped;

    reg [DATA_WIDTH-1:0] model_data [0:DEPTH-1];
    reg [LOGICAL_ID_WIDTH-1:0] model_logical_id [0:DEPTH-1];
    integer model_head;
    integer model_tail;
    integer model_count;
    integer item_sequence;
    integer failures;
    integer cycle_count;
    integer max_occupancy;
    reg [PTR_WIDTH-1:0] overflow_tail;
    reg [DATA_WIDTH-1:0] near_full_expected_data;
    reg [LOGICAL_ID_WIDTH-1:0] near_full_expected_logical_id;
    integer near_full_expected_tail;
    reg saw_head_wrap;
    reg saw_tail_wrap;
    reg saw_full_read_write;
    reg saw_depth_minus_one;
    reg saw_near_full_partial_accept;
    reg saw_read_write [1:ENQUEUE_PORTS];
    reg saw_enqueue_width [1:ENQUEUE_PORTS];
    integer lane;

    PopResultFIFO #(
        .DATA_WIDTH(DATA_WIDTH),
        .LOGICAL_ID_WIDTH(LOGICAL_ID_WIDTH),
        .ENQUEUE_PORTS(ENQUEUE_PORTS),
        .DEPTH(DEPTH)
    ) dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_enqueue_valid(enqueue_valid),
        .i_enqueue_data(enqueue_data),
        .i_enqueue_logical_id(enqueue_logical_id),
        .i_dequeue_ready(dequeue_ready),
        .o_dequeue_valid(dequeue_valid),
        .o_dequeue_data(dequeue_data),
        .o_dequeue_logical_id(dequeue_logical_id),
        .o_overflow(overflow),
        .o_count(fifo_count),
        .o_head_ptr(head_ptr),
        .o_tail_ptr(tail_ptr),
        .o_enqueued_count(enqueued_count),
        .o_dequeued(dequeued),
        .o_head_wrapped(head_wrapped),
        .o_tail_wrapped(tail_wrapped)
    );

    always #5 clk = ~clk;

    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s at time %0t", message, $time);
                failures = failures + 1;
            end
        end
    endtask

    task run_cycle;
        input [ENQUEUE_PORTS-1:0] valid_mask;
        input ready_value;
        integer accepted_count;
        integer expected_dequeue;
        integer expected_head_wrap;
        integer expected_tail_wrap;
        integer old_model_count;
        reg [DATA_WIDTH-1:0] expected_data;
        reg [LOGICAL_ID_WIDTH-1:0] expected_logical_id;
        begin
            @(negedge clk);
            enqueue_valid = valid_mask;
            dequeue_ready = ready_value;
            for (lane = 0; lane < ENQUEUE_PORTS; lane = lane + 1) begin
                enqueue_data[lane] = {16'ha000 | item_sequence[15:0],
                                      item_sequence[15:0]};
                enqueue_logical_id[lane] = lane[LOGICAL_ID_WIDTH-1:0];
                if (valid_mask[lane])
                    item_sequence = item_sequence + 1;
            end

            old_model_count = model_count;
            expected_dequeue = ready_value && (model_count != 0);
            expected_head_wrap = 0;
            expected_tail_wrap = 0;
            expected_data = {DATA_WIDTH{1'b1}};
            expected_logical_id = {LOGICAL_ID_WIDTH{1'b0}};
            if (expected_dequeue) begin
                expected_data = model_data[model_head];
                expected_logical_id = model_logical_id[model_head];
                if (model_head == DEPTH - 1) begin
                    model_head = 0;
                    expected_head_wrap = 1;
                end else begin
                    model_head = model_head + 1;
                end
                model_count = model_count - 1;
            end

            accepted_count = 0;
            for (lane = 0; lane < ENQUEUE_PORTS; lane = lane + 1) begin
                if (valid_mask[lane]) begin
                    check(model_count < DEPTH,
                          "directed FIFO cycle attempted an unexpected overflow");
                    if (model_count < DEPTH) begin
                        model_data[model_tail] = enqueue_data[lane];
                        model_logical_id[model_tail] = enqueue_logical_id[lane];
                        if (model_tail == DEPTH - 1) begin
                            model_tail = 0;
                            expected_tail_wrap = 1;
                        end else begin
                            model_tail = model_tail + 1;
                        end
                        model_count = model_count + 1;
                        accepted_count = accepted_count + 1;
                    end
                end
            end

            @(posedge clk);
            #1;
            cycle_count = cycle_count + 1;
            check(dequeue_valid == expected_dequeue,
                  "dequeue valid differs from pre-cycle occupancy/ready");
            check(dequeued == expected_dequeue,
                  "dequeue observability pulse mismatch");
            if (expected_dequeue) begin
                check(dequeue_data == expected_data,
                      "dequeue data order/content mismatch");
                check(dequeue_logical_id == expected_logical_id,
                      "dequeue logical ID order mismatch");
            end
            check(enqueued_count == accepted_count,
                  "actual enqueue count differs from valid lane count");
            check(fifo_count == model_count, "FIFO count differs from model");
            check(head_ptr == model_head, "FIFO head pointer differs from model");
            check(tail_ptr == model_tail, "FIFO tail pointer differs from model");
            check(head_wrapped == expected_head_wrap, "head wrap pulse mismatch");
            check(tail_wrapped == expected_tail_wrap, "tail wrap pulse mismatch");
            check(!overflow, "FIFO overflow must be unreachable in legal directed cycles");

            if (accepted_count >= 1 && accepted_count <= ENQUEUE_PORTS)
                saw_enqueue_width[accepted_count] = 1'b1;
            if (expected_dequeue && accepted_count >= 1 &&
                accepted_count <= ENQUEUE_PORTS)
                saw_read_write[accepted_count] = 1'b1;
            if ((old_model_count == DEPTH) && expected_dequeue &&
                (accepted_count == 1) && (model_count == DEPTH))
                saw_full_read_write = 1'b1;
            if (head_wrapped)
                saw_head_wrap = 1'b1;
            if (tail_wrapped)
                saw_tail_wrap = 1'b1;
            if (model_count > max_occupancy)
                max_occupancy = model_count;
            if (model_count == DEPTH - 1)
                saw_depth_minus_one = 1'b1;
        end
    endtask

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        enqueue_valid = {ENQUEUE_PORTS{1'b0}};
        dequeue_ready = 1'b0;
        failures = 0;
        model_head = 0;
        model_tail = 0;
        model_count = 0;
        item_sequence = 1;
        cycle_count = 0;
        max_occupancy = 0;
        saw_head_wrap = 1'b0;
        saw_tail_wrap = 1'b0;
        saw_full_read_write = 1'b0;
        saw_depth_minus_one = 1'b0;
        saw_near_full_partial_accept = 1'b0;
        for (lane = 0; lane < ENQUEUE_PORTS; lane = lane + 1) begin
            enqueue_data[lane] = {DATA_WIDTH{1'b0}};
            enqueue_logical_id[lane] = {LOGICAL_ID_WIDTH{1'b0}};
        end
        for (lane = 1; lane <= ENQUEUE_PORTS; lane = lane + 1) begin
            saw_read_write[lane] = 1'b0;
            saw_enqueue_width[lane] = 1'b0;
        end

        repeat (4) @(posedge clk);
        arst_n = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        check(fifo_count == 0 && !dequeue_valid && !overflow,
              "reset/empty state incorrect");

        // Empty, enqueue-only widths 1 and 2, then read+write widths 3 and 4.
        run_cycle(4'b0000, 1'b1);
        run_cycle(4'b0001, 1'b0);
        run_cycle(4'b0011, 1'b0);
        run_cycle(4'b0111, 1'b1);
        run_cycle(4'b1111, 1'b1);
        check(fifo_count == DEPTH, "four-way read/write did not reach full");

        // Hold full, then prove the just-freed slot is usable in the same
        // cycle without changing occupancy or overwriting older entries.
        run_cycle(4'b0000, 1'b0);
        run_cycle(4'b0001, 1'b1);
        check(fifo_count == DEPTH, "full read/write did not preserve full count");

        // Drain to one, explicitly crossing DEPTH-1 and wrapping the head.
        repeat (7)
            run_cycle(4'b0000, 1'b1);
        check(fifo_count == 1, "drain did not reach count one");

        // Complete read+write width 2 coverage, then drain to count zero.
        run_cycle(4'b0011, 1'b1);
        repeat (2)
            run_cycle(4'b0000, 1'b1);
        run_cycle(4'b0000, 1'b1);
        check(fifo_count == 0 && model_count == 0,
              "FIFO/model did not return to empty");

        for (lane = 1; lane <= ENQUEUE_PORTS; lane = lane + 1) begin
            check(saw_enqueue_width[lane], "missing enqueue width 1..4 coverage");
            check(saw_read_write[lane], "missing simultaneous read/write width 1..4 coverage");
        end
        check(max_occupancy == DEPTH, "test never reached full occupancy");
        check(saw_depth_minus_one, "test never observed DEPTH-1 occupancy");
        check(saw_full_read_write, "full simultaneous read/write not covered");
        check(saw_head_wrap && saw_tail_wrap, "head/tail pointer wrap not covered");
        check(!overflow, "unexpected sticky overflow at end of test");

        // Refill to DEPTH-1, then combine a dequeue with four real return
        // lanes.  Only two slots are available after the dequeue, so the FIFO
        // accepts the lane-order prefix and drops the remaining two returns.
        run_cycle(4'b1111, 1'b0);
        run_cycle(4'b0111, 1'b0);
        check(fifo_count == DEPTH - 1 && model_count == DEPTH - 1,
              "near-full multi-return setup did not reach DEPTH-1");
        near_full_expected_data = model_data[model_head];
        near_full_expected_logical_id = model_logical_id[model_head];
        near_full_expected_tail = (model_tail + 2) % DEPTH;
        @(negedge clk);
        enqueue_valid = 4'b1111;
        dequeue_ready = 1'b1;
        for (lane = 0; lane < ENQUEUE_PORTS; lane = lane + 1) begin
            enqueue_data[lane] = {16'hb000 | item_sequence[15:0],
                                  item_sequence[15:0]};
            enqueue_logical_id[lane] = lane[LOGICAL_ID_WIDTH-1:0];
            item_sequence = item_sequence + 1;
        end
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
        check(dequeue_valid && dequeued,
              "near-full multi-return cycle did not dequeue old head");
        check(dequeue_data == near_full_expected_data &&
              dequeue_logical_id == near_full_expected_logical_id,
              "near-full multi-return dequeue data/order mismatch");
        check(enqueued_count == 2,
              "near-full four-lane return did not accept exactly two entries");
        check(fifo_count == DEPTH,
              "near-full four-lane return did not finish full");
        check(tail_ptr == near_full_expected_tail[PTR_WIDTH-1:0],
              "near-full partial acceptance advanced tail incorrectly");
        check(overflow,
              "near-full four-lane return did not flag dropped suffix");
        saw_near_full_partial_accept = 1'b1;

        // While full, every additional lane must be rejected and no
        // pointer/count state may advance.  Overflow is already sticky from
        // the near-full partial-acceptance cycle above.
        overflow_tail = tail_ptr;
        @(negedge clk);
        enqueue_valid = 4'b1010;
        dequeue_ready = 1'b0;
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
        check(overflow, "full multi-lane request did not set sticky overflow");
        check(enqueued_count == 0,
              "full multi-lane request accepted an entry");
        check(fifo_count == DEPTH && !dequeue_valid,
              "overflow request changed occupancy or dequeued data");
        check(tail_ptr == overflow_tail,
              "overflow request advanced the tail pointer");

        check(saw_near_full_partial_accept,
              "near-full partial multi-return acceptance not covered");

        $display("PopResultFIFO stats: cycles=%0d max_occupancy=%0d head_wrap=%0d tail_wrap=%0d full_read_write=%0d near_full_partial_accept=%0d overflow_checked=%0d",
                 cycle_count, max_occupancy, saw_head_wrap, saw_tail_wrap,
                 saw_full_read_write, saw_near_full_partial_accept,
                 overflow);
        if (failures == 0)
            $display("PASS: PopResultFIFO_tb");
        else
            $display("FAIL: PopResultFIFO_tb failures=%0d", failures);
        $finish(failures != 0);
    end

endmodule
