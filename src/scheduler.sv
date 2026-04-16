`default_nettype none
`timescale 1ns/1ns

// SCHEDULER
//
// The scheduler is the core-wide control FSM. It walks the whole core through a
// simple six-stage instruction rhythm:
//   FETCH -> DECODE -> REQUEST -> WAIT -> EXECUTE -> UPDATE
//
// Reading guide:
// - FETCH waits for the fetcher.
// - REQUEST/WAIT cover memory-side work.
// - EXECUTE lets ALUs and PC logic produce results.
// - UPDATE commits the results and advances to the next instruction.
//
// This toy GPU assumes all active lanes stay converged on one shared PC.

module scheduler #(
    parameter THREADS_PER_BLOCK = 4,
) (
    input wire clk,
    input wire reset,
    input wire start,
    
    // Decoded instruction properties that affect stage transitions.
    input reg decoded_mem_read_enable,
    input reg decoded_mem_write_enable,
    input reg decoded_ret,

    // Progress signals from the fetcher and each thread lane's LSU.
    input reg [2:0] fetcher_state,
    input reg [1:0] lsu_state [THREADS_PER_BLOCK-1:0],

    // Shared current PC plus each lane's proposed next PC.
    output reg [7:0] current_pc,
    input reg [7:0] next_pc [THREADS_PER_BLOCK-1:0],

    // Shared stage broadcast to the rest of the core.
    output reg [2:0] core_state,
    output reg done
);
    // Core-wide stage encodings.
    localparam         IDLE = 3'b000, // Waiting to start (core is idle)
        FETCH = 3'b001,       // Fetch instructions from program memory
        DECODE = 3'b010,      // Decode instructions into control signals
        REQUEST = 3'b011,     // Request data from registers or memory
        WAIT = 3'b100,        // Wait for response from memory if necessary
        EXECUTE = 3'b101,     // Execute ALU and PC calculations
        UPDATE = 3'b110,      // Update registers, NZP, and PC
        DONE = 3'b111;        // Done executing this block (waiting for new work)
    
    always @(posedge clk) begin 
        if (reset) begin
            // Reset the core-level control state.
            current_pc <= 0;
            core_state <= IDLE;
            done <= 0;
        end else begin 
            // Main FSM transition logic.
            case (core_state)
                IDLE: begin
                    // Wait here until the dispatcher starts a new block.
                    if (start) begin 
                        // New blocks begin at PC 0.
                        core_state <= FETCH;
                    end
                end
                FETCH: begin 
                    // Stay in FETCH until the fetcher has latched the instruction.
                    if (fetcher_state == 3'b010) begin 
                        core_state <= DECODE;
                    end
                end
                DECODE: begin
                    // Let the decoder translate the fetched instruction.
                    core_state <= REQUEST;
                end
                REQUEST: begin 
                    // Operand reads and any memory requests begin from here.
                    core_state <= WAIT;
                end
                WAIT: begin
                    // Wait until all in-flight LSU operations have finished.
                    reg any_lsu_waiting = 1'b0;
                    for (int i = 0; i < THREADS_PER_BLOCK; i++) begin
                        // REQUESTING or WAITING means this lane still has work outstanding.
                        if (lsu_state[i] == 2'b01 || lsu_state[i] == 2'b10) begin
                            any_lsu_waiting = 1'b1;
                            break;
                        end
                    end

                    // Once memory is settled, computation can proceed.
                    if (!any_lsu_waiting) begin
                        core_state <= EXECUTE;
                    end
                end
                EXECUTE: begin
                    // ALUs and PC logic compute their outputs here.
                    core_state <= UPDATE;
                end
                UPDATE: begin 
                    // Commit write-back state and choose the next shared PC.
                    if (decoded_ret) begin 
                        // In this simplified model, RET ends the whole block.
                        done <= 1;
                        core_state <= DONE;
                    end else begin 
                        // Assume all active lanes produced the same next PC and pick one copy.
                        current_pc <= next_pc[THREADS_PER_BLOCK-1];

                        // Start the next instruction.
                        core_state <= FETCH;
                    end
                end
                DONE: begin 
                    // Terminal state until the dispatcher resets/restarts the core.
                end
            endcase
        end
    end
endmodule
