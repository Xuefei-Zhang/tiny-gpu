`default_nettype none
`timescale 1ns/1ns

// BLOCK DISPATCH
//
// The dispatcher converts one kernel-wide thread_count into a sequence of blocks
// and hands those blocks to whichever cores are free.
//
// Reading guide:
// - total_blocks is the rounded-up number of blocks needed for this launch.
// - core_start/core_reset/core_done form a very simple per-core handshake.
// - blocks_dispatched counts work handed out; blocks_done counts work finished.
// - done goes high only after every required block has completed.
module dispatch #(
    parameter NUM_CORES = 2,
    parameter THREADS_PER_BLOCK = 4
) (
    input wire clk,
    input wire reset,
    input wire start,

    // Launch metadata from the device control register.
    input wire [7:0] thread_count,

    // Per-core control/status handshake.
    input reg [NUM_CORES-1:0] core_done,
    output reg [NUM_CORES-1:0] core_start,
    output reg [NUM_CORES-1:0] core_reset,
    output reg [7:0] core_block_id [NUM_CORES-1:0],
    output reg [$clog2(THREADS_PER_BLOCK):0] core_thread_count [NUM_CORES-1:0],

    // Global kernel-complete signal.
    output reg done
);
    // Round up so a partially filled final block still counts as one block.
    wire [7:0] total_blocks;
    // This is the standard integer round-up formula.
    assign total_blocks = (thread_count + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;

    // Kernel-wide bookkeeping.
    reg [7:0] blocks_dispatched; // Number of blocks already handed to some core.
    reg [7:0] blocks_done;       // Number of blocks that have fully completed.

    // Converts the level-sensitive start input into one logical launch event.
    reg start_execution;

    always @(posedge clk) begin
        if (reset) begin
            done <= 0;
            blocks_dispatched = 0;
            blocks_done = 0;
            start_execution <= 0;

            for (int i = 0; i < NUM_CORES; i++) begin
                core_start[i] <= 0;
                core_reset[i] <= 1;
                core_block_id[i] <= 0;
                core_thread_count[i] <= THREADS_PER_BLOCK;
            end
        end else if (start) begin    
            // Treat only the first cycle of start=1 as the launch event.
            if (!start_execution) begin 
                start_execution <= 1;
                for (int i = 0; i < NUM_CORES; i++) begin
                    core_reset[i] <= 1;
                end
            end

            // Kernel completion means every dispatched block has also finished.
            if (blocks_done == total_blocks) begin 
                done <= 1;
            end

            for (int i = 0; i < NUM_CORES; i++) begin
                if (core_reset[i]) begin 
                    core_reset[i] <= 0;

                    // A core leaving reset is ready to accept fresh work.
                    if (blocks_dispatched < total_blocks) begin 
                        core_start[i] <= 1;
                        core_block_id[i] <= blocks_dispatched;

                        // All non-final blocks are full-sized; only the tail block may be partial.
                        core_thread_count[i] <= (blocks_dispatched == total_blocks - 1) 
                            ? thread_count - (blocks_dispatched * THREADS_PER_BLOCK)
                            : THREADS_PER_BLOCK;

                        blocks_dispatched = blocks_dispatched + 1;
                    end
                end
            end

            for (int i = 0; i < NUM_CORES; i++) begin
                if (core_start[i] && core_done[i]) begin
                    // Finished cores are reset so they can either take a new block or remain idle.
                    core_reset[i] <= 1;
                    core_start[i] <= 0;
                    blocks_done = blocks_done + 1;
                end
            end
        end
    end
endmodule
