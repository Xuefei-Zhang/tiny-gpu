`default_nettype none
`timescale 1ns/1ns

// REGISTER FILE
//
// Each thread lane owns a private 16-entry register file.
// - R0-R12 are normal read/write architectural registers.
// - R13-R15 are read-only metadata registers used for SIMD-style indexing:
//     R13 = %blockIdx, R14 = %blockDim, R15 = %threadIdx
//
// Reading guide:
// - REQUEST snapshots rs and rt from the addressed registers.
// - UPDATE writes one chosen value back into rd.
// - The special metadata registers are protected from normal write-back.
module registers #(
    parameter THREADS_PER_BLOCK = 4,
    parameter THREAD_ID = 0,
    parameter DATA_BITS = 8
) (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has less threads then block size, some registers will be inactive

    // Block metadata currently assigned to this core.
    input reg [7:0] block_id,

    // Shared pipeline stage from the scheduler.
    input reg [2:0] core_state,

    // Register addresses extracted by the decoder.
    input reg [3:0] decoded_rd_address,
    input reg [3:0] decoded_rs_address,
    input reg [3:0] decoded_rt_address,

    // Write-back control from the decoder.
    input reg decoded_reg_write_enable,
    input reg [1:0] decoded_reg_input_mux,
    input reg [DATA_BITS-1:0] decoded_immediate,

    // Candidate write-back values produced by this lane's execution units.
    input reg [DATA_BITS-1:0] alu_out,
    input reg [DATA_BITS-1:0] lsu_out,

    // Source operands exposed to the ALU / LSU.
    output reg [7:0] rs,
    output reg [7:0] rt
);
    // Selects which producer writes back into rd during UPDATE.
    localparam ARITHMETIC = 2'b00,
        MEMORY = 2'b01,
        CONSTANT = 2'b10;

    // Physical storage for this lane's 16 architectural registers.
    reg [7:0] registers[15:0];

    always @(posedge clk) begin
        if (reset) begin
            // Clear the currently presented source operands.
            rs <= 0;
            rt <= 0;
            // Initialize all general-purpose registers.
            registers[0] <= 8'b0;
            registers[1] <= 8'b0;
            registers[2] <= 8'b0;
            registers[3] <= 8'b0;
            registers[4] <= 8'b0;
            registers[5] <= 8'b0;
            registers[6] <= 8'b0;
            registers[7] <= 8'b0;
            registers[8] <= 8'b0;
            registers[9] <= 8'b0;
            registers[10] <= 8'b0;
            registers[11] <= 8'b0;
            registers[12] <= 8'b0;
            // Initialize the special metadata registers.
            registers[13] <= 8'b0;              // %blockIdx
            registers[14] <= THREADS_PER_BLOCK; // %blockDim
            registers[15] <= THREAD_ID;         // %threadIdx
        end else if (enable) begin 
            // Keep %blockIdx aligned with the block currently assigned to this core.
            // This simple implementation rewrites it every active cycle.
            registers[13] <= block_id;
            
            // Snapshot the requested source operands during REQUEST.
            if (core_state == 3'b011) begin 
                rs <= registers[decoded_rs_address];
                rt <= registers[decoded_rt_address];
            end

            // Commit write-back during UPDATE.
            if (core_state == 3'b110) begin 
                // Protect the metadata registers by allowing writes only into R0-R12.
                if (decoded_reg_write_enable && decoded_rd_address < 13) begin
                    case (decoded_reg_input_mux)
                        ARITHMETIC: begin 
                            // Arithmetic result from this lane's ALU.
                            registers[decoded_rd_address] <= alu_out;
                        end
                        MEMORY: begin 
                            // Loaded value returned by this lane's LSU.
                            registers[decoded_rd_address] <= lsu_out;
                        end
                        CONSTANT: begin 
                            // Immediate constant embedded in the instruction.
                            registers[decoded_rd_address] <= decoded_immediate;
                        end
                    endcase
                end
            end
        end
    end
endmodule
