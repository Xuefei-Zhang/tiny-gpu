`default_nettype none
`timescale 1ns/1ns

// ARITHMETIC-LOGIC UNIT
// > Executes computations on register values for ONE thread slot inside ONE core.
// > In this minimal implementation, the ALU supports the 4 basic arithmetic operations
//   plus the compare path used by the CMP instruction.
// > Important mental model for beginners:
//   - This module is synchronous: it updates its output on the clock edge.
//   - It only does useful work when the scheduler has moved the core into EXECUTE.
//   - Every enabled thread has its own private ALU instance.
module alu (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has fewer active threads than capacity, some ALUs stay idle.

    // Shared core stage. The ALU only computes during the EXECUTE stage.
    input reg [2:0] core_state,

    // Decoder control signals:
    // - arithmetic_mux selects ADD/SUB/MUL/DIV
    // - output_mux selects arithmetic result vs comparison result
    input reg [1:0] decoded_alu_arithmetic_mux,
    input reg decoded_alu_output_mux,

    // Source operands read from this thread's register file.
    input reg [7:0] rs,
    input reg [7:0] rt,

    // Final ALU result visible to other units (register file / PC unit).
    output wire [7:0] alu_out
);
    // Small local encoding table for the arithmetic sub-operations.
    localparam ADD = 2'b00,
        SUB = 2'b01,
        MUL = 2'b10,
        DIV = 2'b11;

    // Registered output: this ALU writes its result on the rising edge of clk.
    reg [7:0] alu_out_reg;
    assign alu_out = alu_out_reg;

    always @(posedge clk) begin 
        if (reset) begin 
            // Reset clears the stored ALU output.
            alu_out_reg <= 8'b0;
        end else if (enable) begin
            // Only perform ALU work during the EXECUTE stage of the core pipeline.
            if (core_state == 3'b101) begin 
                if (decoded_alu_output_mux == 1) begin 
                    // CMP uses the ALU comparison path instead of normal arithmetic.
                    // The low 3 bits are packed as condition flags for the PC/NZP logic:
                    //   alu_out[2] = (rs > rt)
                    //   alu_out[1] = (rs == rt)
                    //   alu_out[0] = (rs < rt)
                    // The upper 5 bits are padded with zeros because alu_out is 8 bits wide.
                    alu_out_reg <= {5'b0, (rs - rt > 0), (rs - rt == 0), (rs - rt < 0)};
                end else begin 
                    // Normal arithmetic path selected by the decoder.
                    case (decoded_alu_arithmetic_mux)
                        ADD: begin 
                            // R[rd] = rs + rt
                            alu_out_reg <= rs + rt;
                        end
                        SUB: begin 
                            // R[rd] = rs - rt
                            alu_out_reg <= rs - rt;
                        end
                        MUL: begin 
                            // R[rd] = rs * rt
                            alu_out_reg <= rs * rt;
                        end
                        DIV: begin 
                            // R[rd] = rs / rt
                            // This toy design assumes the program avoids divide-by-zero.
                            alu_out_reg <= rs / rt;
                        end
                    endcase
                end
            end
        end
    end
endmodule
