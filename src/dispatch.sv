`default_nettype none
`timescale 1ns/1ns

// BLOCK DISPATCH
// > Top-level unit that converts one kernel-wide thread_count into a sequence of per-core blocks.
// > Keeps all cores busy by handing them a new block whenever they finish the previous one.
// > Announces kernel completion once every block has been dispatched and then finished.
// > Beginner mental model:
//   software says "launch N total threads"; dispatch groups them into chunks of
//   THREADS_PER_BLOCK threads and assigns those chunks to the available cores.
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
    // Round up so partially full final blocks still count as one block.
    wire [7:0] total_blocks;
    assign total_blocks = (thread_count + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;

    // Global launch bookkeeping.
    reg [7:0] blocks_dispatched; // Number of blocks already handed to some core.
    reg [7:0] blocks_done;       // Number of blocks that have fully completed.

    // Small helper flag used to emulate a one-time launch edge from the level-sensitive start signal.
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
            // Treat the first observed cycle of start=1 as the launch event.
            // This avoids building separate logic driven directly by the start signal edge.
            if (!start_execution) begin 
                start_execution <= 1;
                for (int i = 0; i < NUM_CORES; i++) begin
                    core_reset[i] <= 1;
                end
            end

            // Kernel is complete only after every block has reported completion.
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

                        // Most blocks are full-sized. Only the final block may be partially full.
                        core_thread_count[i] <= (blocks_dispatched == total_blocks - 1) 
                            ? thread_count - (blocks_dispatched * THREADS_PER_BLOCK)
                            : THREADS_PER_BLOCK;

                        blocks_dispatched = blocks_dispatched + 1;
                    end
                end
            end

            for (int i = 0; i < NUM_CORES; i++) begin
                if (core_start[i] && core_done[i]) begin
                    // Once a core finishes its current block, reset it so the next loop iteration
                    // can either assign a new block or leave it idle if all work is done.
                    core_reset[i] <= 1;
                    core_start[i] <= 0;
                    blocks_done = blocks_done + 1;
                end
            end
        end
    end
endmodule
