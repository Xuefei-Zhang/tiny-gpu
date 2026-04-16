`default_nettype none
`timescale 1ns/1ns

// ARITHMETIC-LOGIC UNIT (ALU)
//
// One ALU exists per thread lane inside a core. It performs the arithmetic part
// of the current instruction, or the CMP comparison that later feeds the PC
// unit's NZP branch logic.
//
// Reading guide:
// - The scheduler broadcasts core_state to every lane.
// - The decoder selects either arithmetic mode or comparison mode.
// - The result is registered, so alu_out updates on the next clock edge.
//
// Logic is unchanged; only comments are being rewritten.

module alu (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has fewer active threads than capacity, some ALUs stay idle.

    // Shared pipeline stage from the scheduler. The ALU acts only in EXECUTE.
    input reg [2:0] core_state,

    // Decoder control:
    // - arithmetic_mux chooses ADD/SUB/MUL/DIV.
    // - output_mux chooses arithmetic-result path vs comparison-result path.
    input reg [1:0] decoded_alu_arithmetic_mux,
    input reg decoded_alu_output_mux,

    // Source operands for this thread lane.
    input reg [7:0] rs,
    input reg [7:0] rt,

    // Registered result seen by the register file or PC unit.
    output wire [7:0] alu_out
);
    // Local names for the 2-bit arithmetic selector.
    localparam ADD = 2'b00,
        SUB = 2'b01,
        MUL = 2'b10,
        DIV = 2'b11;

    // Registered output storage.
    reg [7:0] alu_out_reg;
    // Continuous assignment from the internal register to the module output.
    assign alu_out = alu_out_reg;

    always @(posedge clk) begin 
        if (reset) begin 
            // Clear the remembered result.
            alu_out_reg <= 8'b0;
        end else if (enable) begin
            // Active lanes compute only during EXECUTE.
            if (core_state == 3'b101) begin 
                if (decoded_alu_output_mux == 1) begin 
                    // CMP path: pack comparison flags into alu_out[2:0] for NZP logic.
                    // Bit meaning is {positive, equal, negative}; upper bits are zero.
                    alu_out_reg <= {5'b0, (rs - rt > 0), (rs - rt == 0), (rs - rt < 0)};
                end else begin 
                    // Arithmetic path: decoder chooses which operation this lane performs.
                    case (decoded_alu_arithmetic_mux)
                        ADD: begin 
                            // ADD result.
                            alu_out_reg <= rs + rt;
                        end
                        SUB: begin 
                            // SUB result.
                            alu_out_reg <= rs - rt;
                        end
                        MUL: begin 
                            // MUL result.
                            alu_out_reg <= rs * rt;
                        end
                        DIV: begin 
                            // DIV result. This toy design does not add divide-by-zero protection.
                            alu_out_reg <= rs / rt;
                        end
                    endcase
                end
            end
        end
    end
endmodule
