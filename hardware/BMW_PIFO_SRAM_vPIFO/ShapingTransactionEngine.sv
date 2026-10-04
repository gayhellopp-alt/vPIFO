`timescale 1ns / 10ps

// Stage-5 shaping transaction frontend.
//
// A configured flow selects one of five small transaction programs.  The
// virtual-clock programs atomically compute
//
//   release_time = max(wall_time, flow.next_release_time)
//   flow.next_release_time = saturating_add(release_time, service_time)
//
// when, and only when, the resulting event is accepted downstream.  This
// The token-bucket program represents both tokens and packet cost in time
// units.  One cycle of idle wall time replenishes one unit of credit, capped by
// bucket_capacity_time.  A packet consumes i_tx_packet_service_time units.  If
// credit is insufficient, bucket_state_time advances into the future and is
// the packet eligibility time.  No divider or multiplier is required here;
// software is responsible for converting bytes/rate to time-credit units.
//
// All algorithm state is committed only when the resulting event is accepted.
// This makes a stalled transaction retry-safe and keeps flow state aligned with
// events that really entered the shaping PIFO.
module ShapingTransactionEngine #(
    parameter TIME_WIDTH = 16,
    parameter FLOW_NUM = 16,
    parameter PAYLOAD_WIDTH = 64,
    localparam FLOW_ID_WIDTH =
        (FLOW_NUM <= 1) ? 1 : $clog2(FLOW_NUM),
    localparam CONFIGURED_COUNT_WIDTH =
        (FLOW_NUM <= 1) ? 1 : $clog2(FLOW_NUM + 1)
)(
    input  wire                         i_clk,
    input  wire                         i_arst_n,
    input  wire [TIME_WIDTH-1:0]        i_time,

    // Per-flow program and state initialization.  A same-flow transaction has
    // priority over configuration so an event already under backpressure can
    // never change underneath ready/valid.
    input  wire                         i_cfg_valid,
    output wire                         o_cfg_ready,
    input  wire [FLOW_ID_WIDTH-1:0]     i_cfg_flow_id,
    input  wire                         i_cfg_enable,
    input  wire [2:0]                   i_cfg_mode,
    input  wire [TIME_WIDTH-1:0]        i_cfg_default_service_time,
    input  wire                         i_cfg_state_valid,
    input  wire [TIME_WIDTH-1:0]        i_cfg_next_release_time,
    input  wire [TIME_WIDTH-1:0]        i_cfg_bucket_capacity_time,
    input  wire                         i_cfg_bucket_state_valid,
    input  wire [TIME_WIDTH-1:0]        i_cfg_bucket_credit_time,
    input  wire [TIME_WIDTH-1:0]        i_cfg_bucket_state_time,
    output wire                         o_cfg_reject_bad_flow_id,

    // One packet/reference transaction per cycle. Packet service time is used
    // by MODE_VCLOCK_PACKET and MODE_TOKEN_BUCKET_PACKET; absolute time only
    // by MODE_ABSOLUTE.
    input  wire                         i_tx_valid,
    output wire                         o_tx_ready,
    input  wire [FLOW_ID_WIDTH-1:0]     i_tx_flow_id,
    input  wire                         i_tx_context_valid,
    input  wire [TIME_WIDTH-1:0]        i_tx_packet_service_time,
    input  wire [TIME_WIDTH-1:0]        i_tx_absolute_release_time,
    input  wire [PAYLOAD_WIDTH-1:0]     i_tx_payload,
    output wire                         o_tx_reject_bad_flow_id,
    output wire                         o_tx_reject_unconfigured,
    output wire                         o_tx_reject_bad_context,
    output wire                         o_transaction_fire,
    output wire [TIME_WIDTH-1:0]        o_transaction_release_time,
    output wire [TIME_WIDTH-1:0]        o_transaction_next_release_time,
    output wire [TIME_WIDTH-1:0]        o_transaction_bucket_credit_time,
    output wire [TIME_WIDTH-1:0]        o_transaction_bucket_state_time,

    // Computed shaping event.  Payload is deliberately opaque to the
    // transaction engine and is interpreted by the Stage-5 integration top.
    output wire                         o_event_valid,
    input  wire                         i_event_ready,
    output wire [TIME_WIDTH-1:0]        o_event_release_time,
    output wire [PAYLOAD_WIDTH-1:0]     o_event_payload,

    // Asynchronous debug/config readback.
    input  wire [FLOW_ID_WIDTH-1:0]     i_state_read_flow_id,
    output wire                         o_state_read_configured,
    output wire [2:0]                   o_state_read_mode,
    output wire [TIME_WIDTH-1:0]        o_state_read_default_service_time,
    output wire                         o_state_read_valid,
    output wire [TIME_WIDTH-1:0]        o_state_read_next_release_time,
    output wire                         o_state_read_bucket_valid,
    output wire [TIME_WIDTH-1:0]        o_state_read_bucket_capacity_time,
    output wire [TIME_WIDTH-1:0]        o_state_read_bucket_credit_time,
    output wire [TIME_WIDTH-1:0]        o_state_read_bucket_state_time,

    output reg  [31:0]                  o_transaction_count,
    output reg  [31:0]                  o_rejected_transaction_count,
    output reg  [31:0]                  o_late_absolute_count,
    output reg  [31:0]                  o_saturated_time_count,
    output reg  [CONFIGURED_COUNT_WIDTH-1:0]
                                        o_configured_flow_count,
    output reg                          o_protocol_error
);

    localparam [2:0] MODE_NOW = 3'd0;
    localparam [2:0] MODE_VCLOCK_DEFAULT = 3'd1;
    localparam [2:0] MODE_VCLOCK_PACKET = 3'd2;
    localparam [2:0] MODE_ABSOLUTE = 3'd3;
    localparam [2:0] MODE_TOKEN_BUCKET_PACKET = 3'd4;

    reg flow_configured [0:FLOW_NUM-1];
    reg [2:0] flow_mode [0:FLOW_NUM-1];
    reg [TIME_WIDTH-1:0] flow_default_service_time [0:FLOW_NUM-1];
    reg flow_state_valid [0:FLOW_NUM-1];
    reg [TIME_WIDTH-1:0] flow_next_release_time [0:FLOW_NUM-1];
    reg flow_bucket_state_valid [0:FLOW_NUM-1];
    reg [TIME_WIDTH-1:0] flow_bucket_capacity_time [0:FLOW_NUM-1];
    reg [TIME_WIDTH-1:0] flow_bucket_credit_time [0:FLOW_NUM-1];
    reg [TIME_WIDTH-1:0] flow_bucket_state_time [0:FLOW_NUM-1];

    wire cfg_flow_id_valid = int'(i_cfg_flow_id) < FLOW_NUM;
    wire tx_flow_id_valid = int'(i_tx_flow_id) < FLOW_NUM;
    wire read_flow_id_valid = int'(i_state_read_flow_id) < FLOW_NUM;

    wire [FLOW_ID_WIDTH-1:0] sanitized_tx_flow_id =
        tx_flow_id_valid ? i_tx_flow_id : {FLOW_ID_WIDTH{1'b0}};
    wire [FLOW_ID_WIDTH-1:0] sanitized_read_flow_id =
        read_flow_id_valid ? i_state_read_flow_id :
        {FLOW_ID_WIDTH{1'b0}};

    wire same_flow_cfg_conflict = i_cfg_valid && i_tx_valid &&
        cfg_flow_id_valid && tx_flow_id_valid &&
        (i_cfg_flow_id == i_tx_flow_id);
    assign o_cfg_ready = i_arst_n && !same_flow_cfg_conflict;
    wire cfg_fire = i_cfg_valid && o_cfg_ready;
    assign o_cfg_reject_bad_flow_id = cfg_fire && !cfg_flow_id_valid;

    wire selected_configured = tx_flow_id_valid &&
        flow_configured[sanitized_tx_flow_id];
    wire [2:0] selected_mode = flow_mode[sanitized_tx_flow_id];
    wire selected_state_valid = flow_state_valid[sanitized_tx_flow_id];
    wire [TIME_WIDTH-1:0] selected_next_release_time =
        flow_next_release_time[sanitized_tx_flow_id];
    wire [TIME_WIDTH-1:0] selected_default_service_time =
        flow_default_service_time[sanitized_tx_flow_id];
    wire selected_bucket_state_valid =
        flow_bucket_state_valid[sanitized_tx_flow_id];
    wire [TIME_WIDTH-1:0] selected_bucket_capacity_time =
        flow_bucket_capacity_time[sanitized_tx_flow_id];
    wire [TIME_WIDTH-1:0] selected_bucket_credit_time =
        flow_bucket_credit_time[sanitized_tx_flow_id];
    wire [TIME_WIDTH-1:0] selected_bucket_state_time =
        flow_bucket_state_time[sanitized_tx_flow_id];

    wire [TIME_WIDTH-1:0] virtual_clock_base =
        selected_state_valid && (selected_next_release_time > i_time) ?
        selected_next_release_time : i_time;
    wire [TIME_WIDTH-1:0] selected_service_time =
        (selected_mode == MODE_VCLOCK_PACKET) ?
        i_tx_packet_service_time : selected_default_service_time;
    wire [TIME_WIDTH:0] next_release_sum =
        {1'b0, virtual_clock_base} + {1'b0, selected_service_time};
    wire next_release_overflow = next_release_sum[TIME_WIDTH];
    wire [TIME_WIDTH-1:0] saturated_next_release_time =
        next_release_overflow ? {TIME_WIDTH{1'b1}} :
        next_release_sum[TIME_WIDTH-1:0];
    wire absolute_is_late =
        i_tx_absolute_release_time < i_time;

    // Time-credit token bucket.  bucket_state_time may be in the future when
    // earlier accepted packets already reserved future credit.  In that case
    // no wall-time refill is available to this transaction yet.
    wire [TIME_WIDTH-1:0] bucket_base_time =
        selected_bucket_state_valid &&
        (selected_bucket_state_time > i_time) ?
        selected_bucket_state_time : i_time;
    wire [TIME_WIDTH-1:0] bucket_elapsed_time =
        selected_bucket_state_valid &&
        (selected_bucket_state_time < i_time) ?
        i_time - selected_bucket_state_time : {TIME_WIDTH{1'b0}};
    wire [TIME_WIDTH-1:0] bucket_initial_credit =
        selected_bucket_state_valid ? selected_bucket_credit_time :
        selected_bucket_capacity_time;
    wire [TIME_WIDTH:0] bucket_refill_sum =
        {1'b0, bucket_initial_credit} + {1'b0, bucket_elapsed_time};
    wire [TIME_WIDTH-1:0] bucket_refilled_credit =
        bucket_refill_sum[TIME_WIDTH] ||
        (bucket_refill_sum[TIME_WIDTH-1:0] >
         selected_bucket_capacity_time) ?
        selected_bucket_capacity_time :
        bucket_refill_sum[TIME_WIDTH-1:0];
    wire bucket_has_credit =
        bucket_refilled_credit >= i_tx_packet_service_time;
    wire [TIME_WIDTH-1:0] bucket_deficit_time =
        i_tx_packet_service_time - bucket_refilled_credit;
    wire [TIME_WIDTH:0] bucket_release_sum =
        {1'b0, bucket_base_time} + {1'b0, bucket_deficit_time};
    wire bucket_release_overflow = !bucket_has_credit &&
        bucket_release_sum[TIME_WIDTH];
    wire [TIME_WIDTH-1:0] bucket_release_time =
        bucket_has_credit ? bucket_base_time :
        (bucket_release_overflow ? {TIME_WIDTH{1'b1}} :
         bucket_release_sum[TIME_WIDTH-1:0]);
    wire [TIME_WIDTH-1:0] bucket_next_credit_time =
        bucket_has_credit ?
        bucket_refilled_credit - i_tx_packet_service_time :
        {TIME_WIDTH{1'b0}};

    reg [TIME_WIDTH-1:0] computed_release_time;
    reg [TIME_WIDTH-1:0] computed_next_release_time;
    reg [TIME_WIDTH-1:0] computed_bucket_credit_time;
    reg [TIME_WIDTH-1:0] computed_bucket_state_time;
    reg computed_vclock_state_update;
    reg computed_bucket_state_update;
    always @(*) begin
        computed_release_time = i_time;
        computed_next_release_time = selected_next_release_time;
        computed_bucket_credit_time = selected_bucket_credit_time;
        computed_bucket_state_time = selected_bucket_state_time;
        computed_vclock_state_update = 1'b0;
        computed_bucket_state_update = 1'b0;
        case (selected_mode)
            MODE_NOW: begin
                computed_release_time = i_time;
            end
            MODE_VCLOCK_DEFAULT,
            MODE_VCLOCK_PACKET: begin
                computed_release_time = virtual_clock_base;
                computed_next_release_time = saturated_next_release_time;
                computed_vclock_state_update = 1'b1;
            end
            MODE_ABSOLUTE: begin
                computed_release_time = absolute_is_late ?
                    i_time : i_tx_absolute_release_time;
            end
            MODE_TOKEN_BUCKET_PACKET: begin
                computed_release_time = bucket_release_time;
                computed_bucket_credit_time = bucket_next_credit_time;
                computed_bucket_state_time = bucket_release_time;
                computed_bucket_state_update = 1'b1;
            end
            default: begin
                computed_release_time = i_time;
            end
        endcase
    end

    // Invalid or unconfigured requests are consumed as explicit rejections so
    // they cannot wedge an ingress queue.  A configured request inherits the
    // shaping-PIFO backpressure and updates state on exactly the same fire.
    wire selected_request_valid = selected_configured &&
        i_tx_context_valid;
    assign o_event_valid = i_arst_n && i_tx_valid &&
        selected_request_valid;
    assign o_event_release_time = computed_release_time;
    assign o_event_payload = i_tx_payload;
    assign o_tx_ready = i_arst_n &&
        (selected_request_valid ? i_event_ready : 1'b1);
    assign o_transaction_fire = o_event_valid && i_event_ready;
    wire rejected_transaction_fire = i_tx_valid && o_tx_ready &&
        !selected_request_valid;
    assign o_tx_reject_bad_flow_id = rejected_transaction_fire &&
        !tx_flow_id_valid;
    assign o_tx_reject_unconfigured = rejected_transaction_fire &&
        tx_flow_id_valid && !selected_configured;
    assign o_tx_reject_bad_context = rejected_transaction_fire &&
        selected_configured && !i_tx_context_valid;
    assign o_transaction_release_time = computed_release_time;
    assign o_transaction_next_release_time = computed_next_release_time;
    assign o_transaction_bucket_credit_time =
        computed_bucket_credit_time;
    assign o_transaction_bucket_state_time =
        computed_bucket_state_time;

    assign o_state_read_configured = read_flow_id_valid &&
        flow_configured[sanitized_read_flow_id];
    assign o_state_read_mode = read_flow_id_valid ?
        flow_mode[sanitized_read_flow_id] : MODE_NOW;
    assign o_state_read_default_service_time = read_flow_id_valid ?
        flow_default_service_time[sanitized_read_flow_id] :
        {TIME_WIDTH{1'b0}};
    assign o_state_read_valid = read_flow_id_valid &&
        flow_state_valid[sanitized_read_flow_id];
    assign o_state_read_next_release_time = read_flow_id_valid ?
        flow_next_release_time[sanitized_read_flow_id] :
        {TIME_WIDTH{1'b0}};
    assign o_state_read_bucket_valid = read_flow_id_valid &&
        flow_bucket_state_valid[sanitized_read_flow_id];
    assign o_state_read_bucket_capacity_time = read_flow_id_valid ?
        flow_bucket_capacity_time[sanitized_read_flow_id] :
        {TIME_WIDTH{1'b0}};
    assign o_state_read_bucket_credit_time = read_flow_id_valid ?
        flow_bucket_credit_time[sanitized_read_flow_id] :
        {TIME_WIDTH{1'b0}};
    assign o_state_read_bucket_state_time = read_flow_id_valid ?
        flow_bucket_state_time[sanitized_read_flow_id] :
        {TIME_WIDTH{1'b0}};

    integer flow_index;
    always @(posedge i_clk or negedge i_arst_n) begin
        if (!i_arst_n) begin
            for (flow_index = 0; flow_index < FLOW_NUM;
                 flow_index = flow_index + 1) begin
                flow_configured[flow_index] <= 1'b0;
                flow_mode[flow_index] <= MODE_NOW;
                flow_default_service_time[flow_index] <=
                    {TIME_WIDTH{1'b0}};
                flow_state_valid[flow_index] <= 1'b0;
                flow_next_release_time[flow_index] <=
                    {TIME_WIDTH{1'b0}};
                flow_bucket_state_valid[flow_index] <= 1'b0;
                flow_bucket_capacity_time[flow_index] <=
                    {TIME_WIDTH{1'b0}};
                flow_bucket_credit_time[flow_index] <=
                    {TIME_WIDTH{1'b0}};
                flow_bucket_state_time[flow_index] <=
                    {TIME_WIDTH{1'b0}};
            end
            o_transaction_count <= 32'b0;
            o_rejected_transaction_count <= 32'b0;
            o_late_absolute_count <= 32'b0;
            o_saturated_time_count <= 32'b0;
            o_configured_flow_count <=
                {CONFIGURED_COUNT_WIDTH{1'b0}};
            o_protocol_error <= 1'b0;
        end else begin
            if (cfg_fire) begin
                if (!cfg_flow_id_valid) begin
                    o_protocol_error <= 1'b1;
                end else begin
                    if (i_cfg_enable &&
                        !flow_configured[i_cfg_flow_id])
                        o_configured_flow_count <=
                            o_configured_flow_count + 1'b1;
                    else if (!i_cfg_enable &&
                             flow_configured[i_cfg_flow_id])
                        o_configured_flow_count <=
                            o_configured_flow_count - 1'b1;

                    flow_configured[i_cfg_flow_id] <= i_cfg_enable;
                    flow_mode[i_cfg_flow_id] <= i_cfg_mode;
                    flow_default_service_time[i_cfg_flow_id] <=
                        i_cfg_default_service_time;
                    flow_state_valid[i_cfg_flow_id] <=
                        i_cfg_enable && i_cfg_state_valid;
                    flow_next_release_time[i_cfg_flow_id] <=
                        i_cfg_next_release_time;
                    flow_bucket_capacity_time[i_cfg_flow_id] <=
                        i_cfg_bucket_capacity_time;
                    if (i_cfg_enable &&
                        (i_cfg_mode == MODE_TOKEN_BUCKET_PACKET)) begin
                        flow_bucket_state_valid[i_cfg_flow_id] <= 1'b1;
                        if (i_cfg_bucket_state_valid) begin
                            flow_bucket_credit_time[i_cfg_flow_id] <=
                                (i_cfg_bucket_credit_time >
                                 i_cfg_bucket_capacity_time) ?
                                i_cfg_bucket_capacity_time :
                                i_cfg_bucket_credit_time;
                            flow_bucket_state_time[i_cfg_flow_id] <=
                                i_cfg_bucket_state_time;
                        end else begin
                            // Default token-bucket initialization is a full
                            // bucket at the configuration wall time.
                            flow_bucket_credit_time[i_cfg_flow_id] <=
                                i_cfg_bucket_capacity_time;
                            flow_bucket_state_time[i_cfg_flow_id] <= i_time;
                        end
                    end else begin
                        flow_bucket_state_valid[i_cfg_flow_id] <= 1'b0;
                        flow_bucket_credit_time[i_cfg_flow_id] <=
                            {TIME_WIDTH{1'b0}};
                        flow_bucket_state_time[i_cfg_flow_id] <=
                            {TIME_WIDTH{1'b0}};
                    end
                end
            end

            if (o_transaction_fire) begin
                o_transaction_count <= o_transaction_count + 1'b1;
                if (computed_vclock_state_update) begin
                    flow_state_valid[sanitized_tx_flow_id] <= 1'b1;
                    flow_next_release_time[sanitized_tx_flow_id] <=
                        computed_next_release_time;
                    if (next_release_overflow) begin
                        o_saturated_time_count <=
                            o_saturated_time_count + 1'b1;
                        o_protocol_error <= 1'b1;
                    end
                end
                if (computed_bucket_state_update) begin
                    flow_bucket_state_valid[sanitized_tx_flow_id] <=
                        1'b1;
                    flow_bucket_credit_time[sanitized_tx_flow_id] <=
                        computed_bucket_credit_time;
                    flow_bucket_state_time[sanitized_tx_flow_id] <=
                        computed_bucket_state_time;
                    if (bucket_release_overflow) begin
                        o_saturated_time_count <=
                            o_saturated_time_count + 1'b1;
                        o_protocol_error <= 1'b1;
                    end
                end
                if ((selected_mode == MODE_ABSOLUTE) &&
                    absolute_is_late)
                    o_late_absolute_count <=
                        o_late_absolute_count + 1'b1;
            end

            if (rejected_transaction_fire) begin
                o_rejected_transaction_count <=
                    o_rejected_transaction_count + 1'b1;
                o_protocol_error <= 1'b1;
            end
        end
    end

    initial begin
        if ((TIME_WIDTH < 1) || (FLOW_NUM < 1) ||
            (PAYLOAD_WIDTH < 1))
            $fatal(1, "ShapingTransactionEngine parameters invalid");
    end

endmodule
