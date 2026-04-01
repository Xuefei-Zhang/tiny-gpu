`default_nettype none
`timescale 1ns/1ns

// LOAD-STORE UNIT
// > Handles asynchronous memory load and store operations for ONE thread slot.
// > Each thread in each core has its own LSU instance.
// > This is where LDR and STR turn into memory handshake signals.
// > Beginner mental model:
//   - The decoder says whether the current instruction is a load or store.
//   - The LSU starts a request during REQUEST/WAIT stages.
//   - It waits for memory to answer, then reports completion back to the core.
module lsu (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has fewer active threads than capacity, some LSUs stay idle.

    // Shared core stage from the scheduler.
    input reg [2:0] core_state,

    // Decoder control signals telling us whether the current instruction is LDR or STR.
    input reg decoded_mem_read_enable,
    input reg decoded_mem_write_enable,

    // Register values from this thread's register file.
    // Convention in this design:
    //   rs = memory address
    //   rt = store data (for STR)
    input reg [7:0] rs,
    input reg [7:0] rt,

    // External data-memory handshake interface for this thread.
    output reg mem_read_valid,
    output reg [7:0] mem_read_address,
    input reg mem_read_ready,
    input reg [7:0] mem_read_data,
    output reg mem_write_valid,
    output reg [7:0] mem_write_address,
    output reg [7:0] mem_write_data,
    input reg mem_write_ready,

    // LSU outputs back into the core.
    output reg [1:0] lsu_state,
    output reg [7:0] lsu_out
);
    // Small per-thread LSU FSM:
    // IDLE       -> nothing pending
    // REQUESTING -> request is being issued
    // WAITING    -> waiting for memory ready/response
    // DONE       -> request completed, waiting for core UPDATE to reset state
    localparam IDLE = 2'b00, REQUESTING = 2'b01, WAITING = 2'b10, DONE = 2'b11;

    always @(posedge clk) begin
        if (reset) begin
            // Reset clears all pending memory activity.
            lsu_state <= IDLE;
            lsu_out <= 0;
            mem_read_valid <= 0;
            mem_read_address <= 0;
            mem_write_valid <= 0;
            mem_write_address <= 0;
            mem_write_data <= 0;
        end else if (enable) begin
            // Handle LDR instruction flow.
            if (decoded_mem_read_enable) begin 
                case (lsu_state)
                    IDLE: begin
                        // The scheduler has a dedicated REQUEST stage where the LSU is allowed
                        // to start a new memory operation.
                        if (core_state == 3'b011) begin 
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin 
                        // Raise the read request and present the address from rs.
                        mem_read_valid <= 1;
                        mem_read_address <= rs;
                        lsu_state <= WAITING;
                    end
                    WAITING: begin
                        // Hold the request until memory says the read data is ready.
                        if (mem_read_ready == 1) begin
                            mem_read_valid <= 0;
                            // Capture the returned load data so the register file can write it back.
                            lsu_out <= mem_read_data;
                            lsu_state <= DONE;
                        end
                    end
                    DONE: begin 
                        // Reset this LSU once the core reaches UPDATE and has had a chance
                        // to use lsu_out / acknowledge completion.
                        if (core_state == 3'b110) begin 
                            lsu_state <= IDLE;
                        end
                    end
                endcase
            end

            // Handle STR instruction flow.
            if (decoded_mem_write_enable) begin 
                case (lsu_state)
                    IDLE: begin
                        // Just like LDR, stores are launched from the REQUEST stage.
                        if (core_state == 3'b011) begin 
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin 
                        // Present write address/data and raise the write-valid handshake.
                        mem_write_valid <= 1;
                        mem_write_address <= rs;
                        mem_write_data <= rt;
                        lsu_state <= WAITING;
                    end
                    WAITING: begin
                        // Wait for memory/controller to acknowledge the store.
                        if (mem_write_ready) begin
                            mem_write_valid <= 0;
                            lsu_state <= DONE;
                        end
                    end
                    DONE: begin 
                        // Return to IDLE during UPDATE, matching the core's per-instruction rhythm.
                        if (core_state == 3'b110) begin 
                            lsu_state <= IDLE;
                        end
                    end
                endcase
            end
        end
    end
endmodule
