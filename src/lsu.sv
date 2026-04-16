`default_nettype none
`timescale 1ns/1ns

// LOAD-STORE UNIT (LSU)
//
// Each thread lane owns one LSU. It converts LDR/STR instructions into memory
// handshakes and remembers the result of a completed load until register write-back.
//
// Reading guide:
// - rs always supplies the memory address.
// - rt supplies store data for STR.
// - The LSU has its own small FSM so memory can take multiple cycles.
// - The scheduler watches lsu_state to know when the core may leave WAIT.


module lsu (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has fewer active threads than capacity, some LSUs stay idle.

    // Shared pipeline stage from the scheduler.
    input reg [2:0] core_state,

    // Decoder control for the current instruction.
    input reg decoded_mem_read_enable,
    input reg decoded_mem_write_enable,

    // Operands from this thread lane's register file.
    input reg [7:0] rs,
    input reg [7:0] rt,

    // Memory handshake interface for this thread lane.
    output reg mem_read_valid,
    output reg [7:0] mem_read_address,
    input reg mem_read_ready,
    input reg [7:0] mem_read_data,
    output reg mem_write_valid,
    output reg [7:0] mem_write_address,
    output reg [7:0] mem_write_data,
    input reg mem_write_ready,

    // Outputs back into the core.
    output reg [1:0] lsu_state,
    output reg [7:0] lsu_out
);
    // Per-lane LSU FSM:
    //   IDLE -> REQUESTING -> WAITING -> DONE -> IDLE
    localparam IDLE = 2'b00, REQUESTING = 2'b01, WAITING = 2'b10, DONE = 2'b11;

    always @(posedge clk) begin
        if (reset) begin
            // Clear remembered state and handshake outputs.
            lsu_state <= IDLE;
            lsu_out <= 0;
            mem_read_valid <= 0;
            mem_read_address <= 0;
            mem_write_valid <= 0;
            mem_write_address <= 0;
            mem_write_data <= 0;
        end else if (enable) begin
            // LDR flow.
            if (decoded_mem_read_enable) begin 
                case (lsu_state)
                    IDLE: begin
                        // New memory work begins from the core's REQUEST stage.
                        if (core_state == 3'b011) begin // REQUEST stage
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin 
                        // Present the read request to memory.
                        mem_read_valid <= 1;
                        mem_read_address <= rs;
                        lsu_state <= WAITING;
                    end
                    WAITING: begin
                        // Hold until the memory side returns the requested data.
                        if (mem_read_ready == 1) begin
                            mem_read_valid <= 0;
                            // Remember the load result for the later UPDATE stage.
                            lsu_out <= mem_read_data;
                            lsu_state <= DONE;
                        end
                    end
                    DONE: begin 
                        // Wait for UPDATE so write-back can consume lsu_out first.
                        if (core_state == 3'b110) begin // UPDATE stage
                            lsu_state <= IDLE;
                        end
                    end
                endcase
            end

            // STR flow.
            if (decoded_mem_write_enable) begin 
                // Stores share the same FSM shape, but drive the write handshake instead.
                case (lsu_state)
                    IDLE: begin
                        // Stores also begin from REQUEST.
                        if (core_state == 3'b011) begin // REQUEST stage
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin 
                        // Present the write request to memory.
                        mem_write_valid <= 1;
                        mem_write_address <= rs;
                        mem_write_data <= rt;
                        lsu_state <= WAITING;
                    end
                    WAITING: begin
                        // Hold until the store is acknowledged.
                        if (mem_write_ready) begin
                            mem_write_valid <= 0;
                            lsu_state <= DONE;
                        end
                    end
                    DONE: begin 
                        // Return to IDLE in UPDATE so the core sees a clean end-of-op boundary.
                        if (core_state == 3'b110) begin // UPDATE stage
                            lsu_state <= IDLE;
                        end
                    end
                endcase
            end
        end
    end
endmodule
