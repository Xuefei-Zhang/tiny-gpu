`default_nettype none
`timescale 1ns/1ns

// PROGRAM COUNTER (PC)
//
// Each thread lane has its own PC helper. It computes that lane's next_pc during
// EXECUTE and remembers that lane's NZP comparison flags for later branches.
//
// Reading guide:
// - CMP does not write a general register; it writes NZP bits.
// - BRnzp checks those NZP bits to decide whether to branch.
// - The scheduler later assumes every active lane computed the same next_pc.

module pc #(
    parameter DATA_MEM_DATA_BITS = 8,
    parameter PROGRAM_MEM_ADDR_BITS = 8
) (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has less threads then block size, some PCs will be inactive

    // Shared pipeline stage from the scheduler.
    input reg [2:0] core_state,

    // Decoded branch / comparison control for the current instruction.
    input reg [2:0] decoded_nzp,
    input reg [DATA_MEM_DATA_BITS-1:0] decoded_immediate,
    input reg decoded_nzp_write_enable,
    input reg decoded_pc_mux, 

    // ALU output. For CMP, alu_out[2:0] carries the comparison flags.
    input reg [DATA_MEM_DATA_BITS-1:0] alu_out,

    // Shared current PC plus this lane's computed next PC.
    input reg [PROGRAM_MEM_ADDR_BITS-1:0] current_pc,
    output reg [PROGRAM_MEM_ADDR_BITS-1:0] next_pc
);

    // Per-lane NZP storage remembered from the most recent CMP.
    reg [2:0] nzp;

    always @(posedge clk) begin
        if (reset) begin
            // Reset branch history and next-PC output.
            nzp <= 3'b0;
            next_pc <= 0;
        end else if (enable) begin
            // next_pc is produced during EXECUTE.
            if (core_state == 3'b101) begin 
                if (decoded_pc_mux == 1) begin 
                    // Branch when any requested NZP bit matches the stored NZP state.
                    if (((nzp & decoded_nzp) != 3'b0)) begin 
                        // Taken branch.
                        next_pc <= decoded_immediate;
                    end else begin 
                        // Fall through to the next instruction.
                        next_pc <= current_pc + 1;
                    end
                end else begin 
                    // Default sequential execution.
                    next_pc <= current_pc + 1;
                end
            end   

            // NZP is committed during UPDATE after the ALU result is ready.
            if (core_state == 3'b110) begin 
                // Only comparison instructions refresh NZP.
                if (decoded_nzp_write_enable) begin
                    // Copy the ALU comparison result into the stored NZP bits.
                    nzp[2] <= alu_out[2];
                    nzp[1] <= alu_out[1];
                    nzp[0] <= alu_out[0];
                end
            end      
        end
    end

endmodule
