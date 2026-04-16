`default_nettype none
`timescale 1ns/1ns

// INSTRUCTION FETCHER
//
// Each core has one fetcher shared by all of its thread lanes, because the core
// assumes every active lane is executing the same instruction at the same PC.
//
// Reading guide:
// - In FETCH, request instruction memory at current_pc.
// - Wait for the memory controller handshake to complete.
// - Latch the returned instruction so decode sees a stable value.
// - Return to IDLE once the core advances into DECODE.

module fetcher #(
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16
) (
    input wire clk,
    input wire reset,
    
    // Shared core state and the core's converged current PC.
    input reg [2:0] core_state,
    input reg [7:0] current_pc,

    // Program-memory handshake interface.
    output reg mem_read_valid,
    output reg [PROGRAM_MEM_ADDR_BITS-1:0] mem_read_address,
    input reg mem_read_ready,
    input reg [PROGRAM_MEM_DATA_BITS-1:0] mem_read_data,

    // Outputs back into the rest of the core.
    output reg [2:0] fetcher_state,
    output reg [PROGRAM_MEM_DATA_BITS-1:0] instruction,
);
    // Small fetch FSM:
    //   IDLE     -> waiting for the scheduler to enter FETCH
    //   FETCHING -> request is in flight
    //   FETCHED  -> instruction is latched, waiting for DECODE to consume it
    localparam IDLE = 3'b000, 
        FETCHING = 3'b001, 
        FETCHED = 3'b010;
    
    always @(posedge clk) begin
        if (reset) begin
            // Reset the fetcher and clear any remembered request/result.
            fetcher_state <= IDLE;
            mem_read_valid <= 0;
            mem_read_address <= 0;
            instruction <= {PROGRAM_MEM_DATA_BITS{1'b0}};
        end else begin
            // FSM transition logic.
            case (fetcher_state)
                IDLE: begin
                    // Start a new fetch when the scheduler enters FETCH.
                    if (core_state == 3'b001) begin
                        fetcher_state <= FETCHING;
                        mem_read_valid <= 1;
                        mem_read_address <= current_pc;
                    end
                end
                FETCHING: begin
                    // Hold the request until instruction memory responds.
                    if (mem_read_ready) begin
                        fetcher_state <= FETCHED;
                        // Register the instruction before handing it to decode.
                        instruction <= mem_read_data;
                        mem_read_valid <= 0;
                    end
                end
                FETCHED: begin
                    // Once DECODE begins, this fetch cycle is complete.
                    if (core_state == 3'b010) begin 
                        fetcher_state <= IDLE;
                    end
                end
            endcase
        end
    end
endmodule
