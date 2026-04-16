`default_nettype none
`timescale 1ns/1ns

// =============================================================================
// MEMORY CONTROLLER ARCHITECTURE MAP (Beginner-Friendly)
// =============================================================================
// This module arbitrates multiple internal requesters ("consumers") onto a smaller
// number of external memory channels. It is used for both data and program memory.
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  Consumers (LSUs, Fetchers, etc.)                                       │
//  │    ┌─────────────┐   ┌─────────────┐   ...   ┌─────────────┐            │
//  │    │ consumer 0  │   │ consumer 1  │   ...   │ consumer N  │            │
//  │    └─────┬───────┘   └─────┬───────┘         └─────┬───────┘            │
//  │          │                │                        │                    │
//  └──────────┼────────────────┼────────────────────────┼────────────────────┘
//             │                │                        │
//        [Arbitration & Channel Assignment Logic] <─────┐
//             │                │                        │
//  ┌──────────┴────────────────┴────────────────────────┴───────────────┐
//  │  External Memory Channels (NUM_CHANNELS, each with its own FSM)    │
//  │    ┌─────────────┐   ┌─────────────┐   ...   ┌─────────────┐       │
//  │    │ channel 0   │   │ channel 1   │   ...   │ channel M   │       │
//  │    └─────────────┘   └─────────────┘         └─────────────┘       │
//  └─────────────────────────────────────────────────────────────────────┘
//
// KEY CONCEPTS:
// - Each external channel has its own small FSM (finite state machine).
// - Arbitration logic assigns unclaimed consumer requests to available channels.
// - channel_serving_consumer prevents two channels from serving the same consumer.
// - current_consumer[i] tracks which consumer is being served by channel i.
// - READY stays asserted in the relaying states until the original requester drops VALID.
//
// READING GUIDE:
// - Section: Parameterization & Ports — defines consumer/channel interface.
// - Section: FSM State & Bookkeeping — per-channel state, consumer/channel mapping.
// - Section: Arbitration & Channel Assignment — how requests are matched to channels.
// - Section: Per-Channel FSM — how each channel processes requests and relays responses.
// =============================================================================
module controller #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 16,
    parameter NUM_CONSUMERS = 4, // The number of consumers accessing memory through this controller
    parameter NUM_CHANNELS = 1,  // The number of concurrent channels available to send requests to global memory
    parameter WRITE_ENABLE = 1   // Whether this memory controller can write to memory (program memory is read-only)
) (
    input wire clk,
    input wire reset,

    // Consumer-facing handshake ports (fetchers or LSUs, depending on instantiation).
    input reg [NUM_CONSUMERS-1:0] consumer_read_valid,
    input reg [ADDR_BITS-1:0] consumer_read_address [NUM_CONSUMERS-1:0],
    output reg [NUM_CONSUMERS-1:0] consumer_read_ready,
    output reg [DATA_BITS-1:0] consumer_read_data [NUM_CONSUMERS-1:0],
    input reg [NUM_CONSUMERS-1:0] consumer_write_valid,
    input reg [ADDR_BITS-1:0] consumer_write_address [NUM_CONSUMERS-1:0],
    input reg [DATA_BITS-1:0] consumer_write_data [NUM_CONSUMERS-1:0],
    output reg [NUM_CONSUMERS-1:0] consumer_write_ready,

    // External memory-facing channels.
    output reg [NUM_CHANNELS-1:0] mem_read_valid,
    output reg [ADDR_BITS-1:0] mem_read_address [NUM_CHANNELS-1:0],
    input reg [NUM_CHANNELS-1:0] mem_read_ready,
    input reg [DATA_BITS-1:0] mem_read_data [NUM_CHANNELS-1:0],
    output reg [NUM_CHANNELS-1:0] mem_write_valid,
    output reg [ADDR_BITS-1:0] mem_write_address [NUM_CHANNELS-1:0],
    output reg [DATA_BITS-1:0] mem_write_data [NUM_CHANNELS-1:0],
    input reg [NUM_CHANNELS-1:0] mem_write_ready
);
    // =============================
    // FSM State & Bookkeeping
    // =============================
    // Per-channel FSM states
    localparam IDLE = 3'b000, 
        READ_WAITING = 3'b010, 
        WRITE_WAITING = 3'b011,
        READ_RELAYING = 3'b100,
        WRITE_RELAYING = 3'b101;

    // Each channel behaves like a small independent worker.
    reg [2:0] controller_state [NUM_CHANNELS-1:0];
    reg [$clog2(NUM_CONSUMERS)-1:0] current_consumer [NUM_CHANNELS-1:0];

    // Bitmask showing which consumers are already claimed by some channel.
    reg [NUM_CONSUMERS-1:0] channel_serving_consumer;


    // =============================
    // Arbitration & Channel Assignment
    // =============================
    // - Each idle channel scans all consumers for a pending request not already claimed.
    // - Once a request is claimed, it is assigned to that channel and marked as busy.
    // - Prevents two channels from serving the same consumer simultaneously.
    always @(posedge clk) begin
        if (reset) begin 
            // Reset clears both sides of the handshake and returns every channel to IDLE.
            mem_read_valid <= 0;
            mem_read_address <= 0;

            mem_write_valid <= 0;
            mem_write_address <= 0;
            mem_write_data <= 0;

            consumer_read_ready <= 0;
            consumer_read_data <= 0;
            consumer_write_ready <= 0;

            current_consumer <= 0;
            controller_state <= 0;

            channel_serving_consumer = 0;
        end else begin 
            // =============================
            // Per-Channel FSM
            // =============================
            // Each channel independently processes requests and relays responses.
            for (int i = 0; i < NUM_CHANNELS; i = i + 1) begin 
                case (controller_state[i])
                    IDLE: begin
                        // Scan consumers to find one unclaimed pending request for this idle channel.
                        for (int j = 0; j < NUM_CONSUMERS; j = j + 1) begin 
                        if (consumer_read_valid[j] && !channel_serving_consumer[j]) begin 
                            // Claim this requester so no other channel grabs it in the same cycle.
                            channel_serving_consumer[j] = 1;
                            current_consumer[i] <= j;

                            // Forward the read request out to memory on this channel.
                            mem_read_valid[i] <= 1;
                            mem_read_address[i] <= consumer_read_address[j];
                            controller_state[i] <= READ_WAITING;

                            // A channel serves at most one consumer at a time.
                            break;
                        end else if (consumer_write_valid[j] && !channel_serving_consumer[j]) begin 
                            // Same arbitration rule for writes.
                            channel_serving_consumer[j] = 1;
                            current_consumer[i] <= j;

                            // Forward the write request out to memory on this channel.
                            mem_write_valid[i] <= 1;
                            mem_write_address[i] <= consumer_write_address[j];
                            mem_write_data[i] <= consumer_write_data[j];
                            controller_state[i] <= WRITE_WAITING;

                            // Stop scanning once this channel adopts one request.
                            break;
                        end
                        end
                    end
                    READ_WAITING: begin
                    // Wait until the external memory side returns read data.
                    if (mem_read_ready[i]) begin 
                        mem_read_valid[i] <= 0;

                        // Relay the returned data back to the original consumer.
                        // (This keeps the handshake protocol consistent for async memory.)
                        consumer_read_ready[current_consumer[i]] <= 1;
                        consumer_read_data[current_consumer[i]] <= mem_read_data[i];
                        controller_state[i] <= READ_RELAYING;
                    end
                    end
                    WRITE_WAITING: begin 
                    // Wait until external memory acknowledges the write.
                    if (mem_write_ready[i]) begin 
                        mem_write_valid[i] <= 0;
                        // Relay the write completion back to the original consumer.
                        consumer_write_ready[current_consumer[i]] <= 1;
                        controller_state[i] <= WRITE_RELAYING;
                    end
                    end
                    // Keep ready asserted until the original requester drops VALID.
                    READ_RELAYING: begin
                    if (!consumer_read_valid[current_consumer[i]]) begin 
                        // VALID low means the requester has consumed the response.
                        // Release the claimed consumer so a future request can be serviced.
                        channel_serving_consumer[current_consumer[i]] = 0;
                        consumer_read_ready[current_consumer[i]] <= 0;
                        controller_state[i] <= IDLE;
                    end
                    end
                    WRITE_RELAYING: begin 
                    if (!consumer_write_valid[current_consumer[i]]) begin 
                        // VALID low means the requester has consumed the write completion.
                        // Release the claimed consumer so a future request can be serviced.
                        channel_serving_consumer[current_consumer[i]] = 0;
                        consumer_write_ready[current_consumer[i]] <= 0;
                        controller_state[i] <= IDLE;
                    end
                    end
                endcase
            end
        end
    end
endmodule
