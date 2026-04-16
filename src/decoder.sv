`default_nettype none
`timescale 1ns/1ns

// INSTRUCTION DECODER
//
// The decoder is the core's translator from a 16-bit instruction word into the
// control signals used by the rest of the datapath. A core needs only one
// decoder because all active lanes execute the same instruction together.
//
// Reading guide:
// - First look at the raw fields extracted from instruction bits.
// - Then look at the control outputs that steer later stages.
// - Finally read the opcode case statement, which is the real ISA-to-hardware map.

module decoder (
    input wire clk,
    input wire reset,

    // Decoder acts only during the DECODE stage, then its outputs are held for later stages.
    input reg [2:0] core_state,
    input reg [15:0] instruction,
    
    // Raw fields sliced directly out of the instruction encoding.
    output reg [3:0] decoded_rd_address,
    output reg [3:0] decoded_rs_address,
    output reg [3:0] decoded_rt_address,
    output reg [2:0] decoded_nzp,
    output reg [7:0] decoded_immediate,
    
    // Control signals broadcast to register file, ALU, LSU, and PC logic.
    output reg decoded_reg_write_enable,           // Enable writing to a register
    output reg decoded_mem_read_enable,            // Enable reading from memory
    output reg decoded_mem_write_enable,           // Enable writing to memory
    output reg decoded_nzp_write_enable,           // Enable writing to NZP register
    output reg [1:0] decoded_reg_input_mux,        // Select input to register
    output reg [1:0] decoded_alu_arithmetic_mux,   // Select arithmetic operation
    output reg decoded_alu_output_mux,             // Select operation in ALU
    output reg decoded_pc_mux,                     // Select source of next PC

    // RET marker consumed by the scheduler.
    output reg decoded_ret
);
    // Local opcode names for instruction[15:12].
    localparam NOP = 4'b0000,
        BRnzp = 4'b0001,
        CMP = 4'b0010,
        ADD = 4'b0011,
        SUB = 4'b0100,
        MUL = 4'b0101,
        DIV = 4'b0110,
        LDR = 4'b0111,
        STR = 4'b1000,
        CONST = 4'b1001,
        RET = 4'b1111;

    // Main decode register.
    always @(posedge clk) begin 
        if (reset) begin 
            // Reset clears the remembered fields and control outputs.
            decoded_rd_address <= 0;
            decoded_rs_address <= 0;
            decoded_rt_address <= 0;
            decoded_immediate <= 0;
            decoded_nzp <= 0;
            decoded_reg_write_enable <= 0;
            decoded_mem_read_enable <= 0;
            decoded_mem_write_enable <= 0;
            decoded_nzp_write_enable <= 0;
            decoded_reg_input_mux <= 0;
            decoded_alu_arithmetic_mux <= 0;
            decoded_alu_output_mux <= 0;
            decoded_pc_mux <= 0;
            decoded_ret <= 0;
        end else begin 
            // Decode the current instruction once when the scheduler enters DECODE.
            if (core_state == 3'b010) begin 
                // First split the instruction into raw fields for later stages to use.
                decoded_rd_address <= instruction[11:8];
                decoded_rs_address <= instruction[7:4];
                decoded_rt_address <= instruction[3:0];
                decoded_immediate <= instruction[7:0];
                decoded_nzp <= instruction[11:9];

                // Then clear every control so old instruction state cannot leak forward.
                decoded_reg_write_enable <= 0;
                decoded_mem_read_enable <= 0;
                decoded_mem_write_enable <= 0;
                decoded_nzp_write_enable <= 0;
                decoded_reg_input_mux <= 0;
                decoded_alu_arithmetic_mux <= 0;
                decoded_alu_output_mux <= 0;
                decoded_pc_mux <= 0;
                decoded_ret <= 0;

                // Finally assert only the controls required by the current opcode.
                case (instruction[15:12])
                    NOP: begin 
                        // NOP leaves every control deasserted.
                    end
                    BRnzp: begin 
                        // Route the PC unit through the branch decision path.
                        decoded_pc_mux <= 1;
                    end
                    CMP: begin 
                        // Compare through the ALU and write the result into NZP, not rd.
                        decoded_alu_output_mux <= 1;
                        decoded_nzp_write_enable <= 1;
                    end
                    ADD: begin 
                        // Write back the ALU's ADD result.
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux <= 2'b00;
                        decoded_alu_arithmetic_mux <= 2'b00;
                    end
                    SUB: begin 
                        // Same datapath as ADD, but with SUB selected inside the ALU.
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux <= 2'b00;
                        decoded_alu_arithmetic_mux <= 2'b01;
                    end
                    MUL: begin 
                        // Same arithmetic datapath, using multiply mode.
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux <= 2'b00;
                        decoded_alu_arithmetic_mux <= 2'b10;
                    end
                    DIV: begin 
                        // Same arithmetic datapath, using divide mode.
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux <= 2'b00;
                        decoded_alu_arithmetic_mux <= 2'b11;
                    end
                    LDR: begin 
                        // Start a load and later write the loaded data into rd.
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux <= 2'b01;
                        decoded_mem_read_enable <= 1;
                    end
                    STR: begin 
                        // Start a store. No register write-back happens.
                        decoded_mem_write_enable <= 1;
                    end
                    CONST: begin 
                        // Write the instruction's immediate byte directly into rd.
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux <= 2'b10;
                    end
                    RET: begin 
                        // Tell the scheduler that this block has reached its end instruction.
                        decoded_ret <= 1;
                    end
                endcase
            end
        end
    end
endmodule
