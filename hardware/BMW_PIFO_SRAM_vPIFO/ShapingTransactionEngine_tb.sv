`timescale 1ns / 10ps

module ShapingTransactionEngine_tb;

    localparam TIME_WIDTH = 8;
    localparam FLOW_NUM = 4;
    localparam FLOW_ID_WIDTH = 2;
    localparam PAYLOAD_WIDTH = 32;

    reg clk;
    reg arst_n;
    reg [TIME_WIDTH-1:0] wall_time;

    reg cfg_valid;
    wire cfg_ready;
    reg [FLOW_ID_WIDTH-1:0] cfg_flow_id;
    reg cfg_enable;
    reg [2:0] cfg_mode;
    reg [TIME_WIDTH-1:0] cfg_default_service_time;
    reg cfg_state_valid;
    reg [TIME_WIDTH-1:0] cfg_next_release_time;
    reg [TIME_WIDTH-1:0] cfg_bucket_capacity_time;
    reg cfg_bucket_state_valid;
    reg [TIME_WIDTH-1:0] cfg_bucket_credit_time;
    reg [TIME_WIDTH-1:0] cfg_bucket_state_time;
    wire cfg_reject_bad_flow_id;

    reg tx_valid;
    wire tx_ready;
    reg [FLOW_ID_WIDTH-1:0] tx_flow_id;
    reg tx_context_valid;
    reg [TIME_WIDTH-1:0] tx_packet_service_time;
    reg [TIME_WIDTH-1:0] tx_absolute_release_time;
    reg [PAYLOAD_WIDTH-1:0] tx_payload;
    wire tx_reject_bad_flow_id;
    wire tx_reject_unconfigured;
    wire tx_reject_bad_context;
    wire transaction_fire;
    wire [TIME_WIDTH-1:0] transaction_release_time;
    wire [TIME_WIDTH-1:0] transaction_next_release_time;
    wire [TIME_WIDTH-1:0] transaction_bucket_credit_time;
    wire [TIME_WIDTH-1:0] transaction_bucket_state_time;

    wire event_valid;
    reg event_ready;
    wire [TIME_WIDTH-1:0] event_release_time;
    wire [PAYLOAD_WIDTH-1:0] event_payload;

    reg [FLOW_ID_WIDTH-1:0] state_read_flow_id;
    wire state_read_configured;
    wire [2:0] state_read_mode;
    wire [TIME_WIDTH-1:0] state_read_default_service_time;
    wire state_read_valid;
    wire [TIME_WIDTH-1:0] state_read_next_release_time;
    wire state_read_bucket_valid;
    wire [TIME_WIDTH-1:0] state_read_bucket_capacity_time;
    wire [TIME_WIDTH-1:0] state_read_bucket_credit_time;
    wire [TIME_WIDTH-1:0] state_read_bucket_state_time;
    wire [31:0] transaction_count;
    wire [31:0] rejected_transaction_count;
    wire [31:0] late_absolute_count;
    wire [31:0] saturated_time_count;
    wire [2:0] configured_flow_count;
    wire protocol_error;

    ShapingTransactionEngine #(
        .TIME_WIDTH(TIME_WIDTH),
        .FLOW_NUM(FLOW_NUM),
        .PAYLOAD_WIDTH(PAYLOAD_WIDTH)
    ) dut (
        .i_clk(clk),
        .i_arst_n(arst_n),
        .i_time(wall_time),
        .i_cfg_valid(cfg_valid),
        .o_cfg_ready(cfg_ready),
        .i_cfg_flow_id(cfg_flow_id),
        .i_cfg_enable(cfg_enable),
        .i_cfg_mode(cfg_mode),
        .i_cfg_default_service_time(cfg_default_service_time),
        .i_cfg_state_valid(cfg_state_valid),
        .i_cfg_next_release_time(cfg_next_release_time),
        .i_cfg_bucket_capacity_time(cfg_bucket_capacity_time),
        .i_cfg_bucket_state_valid(cfg_bucket_state_valid),
        .i_cfg_bucket_credit_time(cfg_bucket_credit_time),
        .i_cfg_bucket_state_time(cfg_bucket_state_time),
        .o_cfg_reject_bad_flow_id(cfg_reject_bad_flow_id),
        .i_tx_valid(tx_valid),
        .o_tx_ready(tx_ready),
        .i_tx_flow_id(tx_flow_id),
        .i_tx_context_valid(tx_context_valid),
        .i_tx_packet_service_time(tx_packet_service_time),
        .i_tx_absolute_release_time(tx_absolute_release_time),
        .i_tx_payload(tx_payload),
        .o_tx_reject_bad_flow_id(tx_reject_bad_flow_id),
        .o_tx_reject_unconfigured(tx_reject_unconfigured),
        .o_tx_reject_bad_context(tx_reject_bad_context),
        .o_transaction_fire(transaction_fire),
        .o_transaction_release_time(transaction_release_time),
        .o_transaction_next_release_time(
            transaction_next_release_time),
        .o_transaction_bucket_credit_time(
            transaction_bucket_credit_time),
        .o_transaction_bucket_state_time(
            transaction_bucket_state_time),
        .o_event_valid(event_valid),
        .i_event_ready(event_ready),
        .o_event_release_time(event_release_time),
        .o_event_payload(event_payload),
        .i_state_read_flow_id(state_read_flow_id),
        .o_state_read_configured(state_read_configured),
        .o_state_read_mode(state_read_mode),
        .o_state_read_default_service_time(
            state_read_default_service_time),
        .o_state_read_valid(state_read_valid),
        .o_state_read_next_release_time(state_read_next_release_time),
        .o_state_read_bucket_valid(state_read_bucket_valid),
        .o_state_read_bucket_capacity_time(
            state_read_bucket_capacity_time),
        .o_state_read_bucket_credit_time(
            state_read_bucket_credit_time),
        .o_state_read_bucket_state_time(state_read_bucket_state_time),
        .o_transaction_count(transaction_count),
        .o_rejected_transaction_count(rejected_transaction_count),
        .o_late_absolute_count(late_absolute_count),
        .o_saturated_time_count(saturated_time_count),
        .o_configured_flow_count(configured_flow_count),
        .o_protocol_error(protocol_error)
    );

    always #5 clk = ~clk;

    task automatic configure_flow(
        input [FLOW_ID_WIDTH-1:0] flow_id,
        input enable,
        input [2:0] mode,
        input [TIME_WIDTH-1:0] default_service_time,
        input state_valid,
        input [TIME_WIDTH-1:0] next_release_time
    );
        begin
            @(negedge clk);
            cfg_flow_id = flow_id;
            cfg_enable = enable;
            cfg_mode = mode;
            cfg_default_service_time = default_service_time;
            cfg_state_valid = state_valid;
            cfg_next_release_time = next_release_time;
            cfg_bucket_capacity_time = {TIME_WIDTH{1'b0}};
            cfg_bucket_state_valid = 1'b0;
            cfg_bucket_credit_time = {TIME_WIDTH{1'b0}};
            cfg_bucket_state_time = {TIME_WIDTH{1'b0}};
            cfg_valid = 1'b1;
            while (!cfg_ready)
                @(negedge clk);
            @(posedge clk);
            #1;
            cfg_valid = 1'b0;
        end
    endtask

    task automatic configure_token_bucket(
        input [FLOW_ID_WIDTH-1:0] flow_id,
        input [TIME_WIDTH-1:0] capacity_time,
        input bucket_state_valid,
        input [TIME_WIDTH-1:0] credit_time,
        input [TIME_WIDTH-1:0] state_time
    );
        begin
            @(negedge clk);
            cfg_flow_id = flow_id;
            cfg_enable = 1'b1;
            cfg_mode = 3'd4;
            cfg_default_service_time = {TIME_WIDTH{1'b0}};
            cfg_state_valid = 1'b0;
            cfg_next_release_time = {TIME_WIDTH{1'b0}};
            cfg_bucket_capacity_time = capacity_time;
            cfg_bucket_state_valid = bucket_state_valid;
            cfg_bucket_credit_time = credit_time;
            cfg_bucket_state_time = state_time;
            cfg_valid = 1'b1;
            while (!cfg_ready)
                @(negedge clk);
            @(posedge clk);
            #1;
            cfg_valid = 1'b0;
        end
    endtask

    task automatic send_transaction(
        input [FLOW_ID_WIDTH-1:0] flow_id,
        input [TIME_WIDTH-1:0] packet_service_time,
        input [TIME_WIDTH-1:0] absolute_release_time,
        input [PAYLOAD_WIDTH-1:0] payload,
        input [TIME_WIDTH-1:0] expected_release_time,
        input [TIME_WIDTH-1:0] expected_next_release_time,
        input integer stall_cycles
    );
        integer cycle;
        begin
            @(negedge clk);
            tx_flow_id = flow_id;
            tx_packet_service_time = packet_service_time;
            tx_absolute_release_time = absolute_release_time;
            tx_payload = payload;
            tx_valid = 1'b1;
            event_ready = (stall_cycles == 0);
            #1;
            if (!event_valid ||
                (event_release_time !== expected_release_time) ||
                (transaction_release_time !== expected_release_time) ||
                (transaction_next_release_time !==
                 expected_next_release_time) ||
                (event_payload !== payload))
                $fatal(1, "computed transaction mismatch flow=%0d", flow_id);

            for (cycle = 0; cycle < stall_cycles; cycle = cycle + 1) begin
                @(posedge clk);
                #1;
                if (transaction_fire || !event_valid ||
                    (event_release_time !== expected_release_time) ||
                    (event_payload !== payload))
                    $fatal(1, "transaction changed under backpressure");
            end

            event_ready = 1'b1;
            if (!tx_ready)
                @(negedge clk);
            @(posedge clk);
            #1;
            if (!transaction_fire)
                $fatal(1, "transaction did not fire");
            tx_valid = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        wall_time = 8'd0;
        cfg_valid = 1'b0;
        cfg_flow_id = 2'b0;
        cfg_enable = 1'b0;
        cfg_mode = 3'b0;
        cfg_default_service_time = 8'b0;
        cfg_state_valid = 1'b0;
        cfg_next_release_time = 8'b0;
        cfg_bucket_capacity_time = 8'b0;
        cfg_bucket_state_valid = 1'b0;
        cfg_bucket_credit_time = 8'b0;
        cfg_bucket_state_time = 8'b0;
        tx_valid = 1'b0;
        tx_flow_id = 2'b0;
        tx_context_valid = 1'b1;
        tx_packet_service_time = 8'b0;
        tx_absolute_release_time = 8'b0;
        tx_payload = 32'b0;
        event_ready = 1'b1;
        state_read_flow_id = 2'b0;

        repeat (3) @(posedge clk);
        arst_n = 1'b1;

        // Flow 0: default-gap virtual clock, initialized to release at t=10.
        configure_flow(2'd0, 1'b1, 3'd1, 8'd5,
                       1'b1, 8'd10);
        #1;
        if (!state_read_configured || !state_read_valid ||
            (state_read_mode != 3'd1) ||
            (state_read_default_service_time != 8'd5) ||
            (state_read_next_release_time != 8'd10))
            $fatal(1, "flow-0 configuration readback mismatch");

        send_transaction(2'd0, 8'd99, 8'd0, 32'h0000_0001,
                         8'd10, 8'd15, 0);
        #1;
        if (state_read_next_release_time != 8'd15)
            $fatal(1, "first virtual-clock state update missing");
        send_transaction(2'd0, 8'd99, 8'd0, 32'h0000_0002,
                         8'd15, 8'd20, 0);
        send_transaction(2'd0, 8'd99, 8'd0, 32'h0000_0003,
                         8'd20, 8'd25, 3);
        if (state_read_next_release_time != 8'd25)
            $fatal(1, "stalled transaction updated state incorrectly");

        // Flow 1: per-packet service times and independent state.
        configure_flow(2'd1, 1'b1, 3'd2, 8'd0,
                       1'b0, 8'd0);
        wall_time = 8'd12;
        send_transaction(2'd1, 8'd3, 8'd0, 32'h1000_0001,
                         8'd12, 8'd15, 0);
        send_transaction(2'd1, 8'd7, 8'd0, 32'h1000_0002,
                         8'd15, 8'd22, 0);

        // Flow 2: absolute-time compatibility mode clamps a past request to
        // now, records it as late, and does not mutate virtual-clock state.
        configure_flow(2'd2, 1'b1, 3'd3, 8'd0,
                       1'b0, 8'd0);
        state_read_flow_id = 2'd2;
        send_transaction(2'd2, 8'd0, 8'd8, 32'h2000_0001,
                         8'd12, 8'd0, 0);
        if ((late_absolute_count != 1) || state_read_valid)
            $fatal(1, "absolute-time clamp/state semantics mismatch");

        // Routing/context rejection must not advance an otherwise configured
        // flow's state.  Stage 5 uses this for bad shaping/parent IDs.
        state_read_flow_id = 2'd0;
        @(negedge clk);
        tx_valid = 1'b1;
        tx_flow_id = 2'd0;
        tx_context_valid = 1'b0;
        tx_payload = 32'hDEAD_0001;
        #1;
        if (!tx_ready || event_valid || !tx_reject_bad_context)
            $fatal(1, "bad-context transaction was not rejected");
        @(posedge clk);
        #1;
        tx_valid = 1'b0;
        tx_context_valid = 1'b1;
        if ((rejected_transaction_count != 1) ||
            (state_read_next_release_time != 8'd25))
            $fatal(1, "bad-context rejection mutated flow state");

        // A same-flow configuration write is held off while a transaction is
        // stalled, so release time and payload remain stable.
        state_read_flow_id = 2'd0;
        @(negedge clk);
        tx_valid = 1'b1;
        tx_flow_id = 2'd0;
        tx_packet_service_time = 8'd0;
        tx_absolute_release_time = 8'd0;
        tx_payload = 32'h0000_0004;
        event_ready = 1'b0;
        cfg_valid = 1'b1;
        cfg_flow_id = 2'd0;
        cfg_enable = 1'b1;
        cfg_mode = 3'd1;
        cfg_default_service_time = 8'd9;
        cfg_state_valid = 1'b1;
        cfg_next_release_time = 8'd25;
        #1;
        if (cfg_ready || !event_valid || (event_release_time != 8'd25))
            $fatal(1, "same-flow configuration exclusion failed");
        repeat (2) begin
            @(posedge clk);
            #1;
            if (cfg_ready || transaction_fire ||
                (event_release_time != 8'd25))
                $fatal(1, "same-flow stalled transaction was not stable");
        end
        cfg_valid = 1'b0;
        event_ready = 1'b1;
        @(posedge clk);
        #1;
        if (!transaction_fire)
            $fatal(1, "same-flow transaction did not resume");
        tx_valid = 1'b0;
        if (state_read_next_release_time != 8'd30)
            $fatal(1, "same-flow resumed state mismatch");

        // Flow 2 is reconfigured as a time-credit token bucket.  Default
        // initialization is full: capacity=10 at wall_time=12.
        state_read_flow_id = 2'd2;
        configure_token_bucket(2'd2, 8'd10, 1'b0, 8'd0, 8'd0);
        #1;
        if (!state_read_bucket_valid ||
            (state_read_mode != 3'd4) ||
            (state_read_bucket_capacity_time != 8'd10) ||
            (state_read_bucket_credit_time != 8'd10) ||
            (state_read_bucket_state_time != 8'd12))
            $fatal(1, "default full-bucket initialization mismatch");

        send_transaction(2'd2, 8'd6, 8'd0, 32'h2000_0010,
                         8'd12, 8'd0, 0);
        if ((state_read_bucket_credit_time != 8'd4) ||
            (state_read_bucket_state_time != 8'd12))
            $fatal(1, "token-bucket immediate debit mismatch");

        // Only four credits remain, so a seven-credit packet reserves three
        // future cycles.  Backpressure must not debit the bucket twice.
        send_transaction(2'd2, 8'd7, 8'd0, 32'h2000_0011,
                         8'd15, 8'd0, 3);
        if ((state_read_bucket_credit_time != 8'd0) ||
            (state_read_bucket_state_time != 8'd15))
            $fatal(1, "token-bucket future reservation mismatch");

        // From state_time=15 to wall_time=20 five credits accrue.
        wall_time = 8'd20;
        send_transaction(2'd2, 8'd3, 8'd0, 32'h2000_0012,
                         8'd20, 8'd0, 0);
        if ((state_read_bucket_credit_time != 8'd2) ||
            (state_read_bucket_state_time != 8'd20))
            $fatal(1, "token-bucket wall-time refill mismatch");

        // Explicit state restoration supports software checkpoint/restore and
        // a future reservation.  Credit is not refilled before state_time=30.
        configure_token_bucket(2'd2, 8'd12, 1'b1, 8'd4, 8'd30);
        send_transaction(2'd2, 8'd6, 8'd0, 32'h2000_0013,
                         8'd32, 8'd0, 0);
        if ((state_read_bucket_credit_time != 8'd0) ||
            (state_read_bucket_state_time != 8'd32))
            $fatal(1, "token-bucket restored-state mismatch");

        // A second token-bucket flow owns independent credit/state even when
        // transactions from the two flows are interleaved.
        configure_token_bucket(2'd1, 8'd8, 1'b0, 8'd0, 8'd0);
        state_read_flow_id = 2'd1;
        send_transaction(2'd1, 8'd3, 8'd0, 32'h1000_0010,
                         8'd20, 8'd0, 0);
        if ((state_read_bucket_credit_time != 8'd5) ||
            (state_read_bucket_state_time != 8'd20))
            $fatal(1, "second token-bucket flow state mismatch");
        state_read_flow_id = 2'd2;
        #1;
        if ((state_read_bucket_credit_time != 8'd0) ||
            (state_read_bucket_state_time != 8'd32))
            $fatal(1, "token-bucket flows did not remain independent");

        // Overflow saturates instead of wrapping to an early release time.
        configure_flow(2'd3, 1'b1, 3'd1, 8'd10,
                       1'b1, 8'd250);
        state_read_flow_id = 2'd3;
        wall_time = 8'd20;
        send_transaction(2'd3, 8'd0, 8'd0, 32'h3000_0001,
                         8'd250, 8'd255, 0);
        if ((state_read_next_release_time != 8'd255) ||
            (saturated_time_count != 1) || !protocol_error)
            $fatal(1, "time saturation behavior mismatch");

        // Token-bucket deficit addition uses the same no-wrap saturation
        // rule, so an overflowing eligibility time cannot become early.
        configure_token_bucket(2'd3, 8'd10, 1'b1, 8'd0, 8'd250);
        send_transaction(2'd3, 8'd10, 8'd0, 32'h3000_0002,
                         8'd255, 8'd0, 0);
        if ((state_read_bucket_state_time != 8'd255) ||
            (state_read_bucket_credit_time != 8'd0) ||
            (saturated_time_count != 2))
            $fatal(1, "token-bucket saturation behavior mismatch");

        if ((transaction_count != 14) ||
            (rejected_transaction_count != 1) ||
            (configured_flow_count != 4) ||
            cfg_reject_bad_flow_id || tx_reject_bad_flow_id ||
            tx_reject_unconfigured || tx_reject_bad_context)
            $fatal(1, "transaction accounting mismatch");

        $display("PASS: Stage-5 shaping transaction/state semantics");
        $finish;
    end

endmodule
