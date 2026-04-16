`default_nettype none
`timescale 1ns/1ns

// GPU ARCHITECTURE MAP
// =====================
// Top-level integration module for tiny-gpu.
//
// **Role:**
//   - Wires together all major GPU subsystems: device control, dispatcher, compute cores, and memory controllers.
//   - Does not implement computation itself, but connects and coordinates the submodules.
//
// **Beginner's Guide:**
//   1. This file is the "plumbing" of the GPU. It connects the building blocks, but doesn't add new execution logic.
//   2. Start by reading the port/interface section below to see how the GPU connects to the outside world.
//   3. Next, look at the internal signal section, which defines how the submodules talk to each other.
//   4. The submodule instantiation section shows how each subsystem is included and connected.
//   5. Pay special attention to the generate/flattening logic at the end—this is where per-core and per-thread signals are mapped into global arrays for arbitration.
//
// **Dataflow Overview:**
//   - The dispatcher splits a kernel launch into blocks and assigns them to available cores.
//   - Each core executes one block at a time, with its own set of thread lanes.
//   - All memory requests from all threads are flattened and arbitrated by the memory controllers.
//   - The memory controllers relay requests/responses between the many internal clients and the limited external memory channels.
//
// **Key Concepts for Beginners:**
//   - Array ports and generate blocks are used to scale up the design for multiple cores and threads.
//   - Flattening logic bridges the gap between hierarchical (core/thread) and flat (controller-facing) signal structures.
//   - Arbitration ensures that many internal requests can share a few external memory ports without conflict.

module gpu #(
    parameter DATA_MEM_ADDR_BITS = 8,        // Number of bits in data memory address (256 rows)
    parameter DATA_MEM_DATA_BITS = 8,        // Number of bits in data memory value (8 bit data)
    parameter DATA_MEM_NUM_CHANNELS = 4,     // Number of concurrent channels for sending requests to data memory
    parameter PROGRAM_MEM_ADDR_BITS = 8,     // Number of bits in program memory address (256 rows)
    parameter PROGRAM_MEM_DATA_BITS = 16,    // Number of bits in program memory value (16 bit instruction)
    parameter PROGRAM_MEM_NUM_CHANNELS = 1,  // Number of concurrent channels for sending requests to program memory
    parameter NUM_CORES = 2,                 // Number of cores to include in this GPU
    parameter THREADS_PER_BLOCK = 4          // Number of threads to handle per block (determines the compute resources of each core)
) (
    input wire clk,
    input wire reset,

    // External kernel launch handshake.
    input wire start,
    output wire done,

    // Software-visible launch configuration write port.
    input wire device_control_write_enable,
    input wire [7:0] device_control_data,

    // External program-memory interface.
    output wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_valid,
    output wire [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address [PROGRAM_MEM_NUM_CHANNELS-1:0],
    input wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_ready,
    input wire [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data [PROGRAM_MEM_NUM_CHANNELS-1:0],

    // External data-memory interface.
    output wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [DATA_MEM_NUM_CHANNELS-1:0],
    input wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready,
    input wire [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [DATA_MEM_NUM_CHANNELS-1:0],
    output wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [DATA_MEM_NUM_CHANNELS-1:0],
    output wire [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [DATA_MEM_NUM_CHANNELS-1:0],
    input wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_ready
);
    // Launch metadata produced by the device control register.
    wire [7:0] thread_count;

    // Dispatcher-managed per-core launch/status signals.
    reg [NUM_CORES-1:0] core_start;
    reg [NUM_CORES-1:0] core_reset;
    reg [NUM_CORES-1:0] core_done;
    reg [7:0] core_block_id [NUM_CORES-1:0];
    reg [$clog2(THREADS_PER_BLOCK):0] core_thread_count [NUM_CORES-1:0];

    // SECTION: LSU <-> Data Memory Controller (Flattened Wiring)
    // ---------------------------------------------------------
    // Each thread lane in each core has its own LSU (load/store unit).
    // To arbitrate memory access, all LSUs are "flattened" into a single global array.
    // This lets the controller treat all memory requests uniformly, regardless of which core/lane they came from.
    // NUM_LSUS = NUM_CORES * THREADS_PER_BLOCK
    localparam NUM_LSUS = NUM_CORES * THREADS_PER_BLOCK;
    reg [NUM_LSUS-1:0] lsu_read_valid;
    reg [DATA_MEM_ADDR_BITS-1:0] lsu_read_address [NUM_LSUS-1:0];
    reg [NUM_LSUS-1:0] lsu_read_ready;
    reg [DATA_MEM_DATA_BITS-1:0] lsu_read_data [NUM_LSUS-1:0];
    reg [NUM_LSUS-1:0] lsu_write_valid;
    reg [DATA_MEM_ADDR_BITS-1:0] lsu_write_address [NUM_LSUS-1:0];
    reg [DATA_MEM_DATA_BITS-1:0] lsu_write_data [NUM_LSUS-1:0];
    reg [NUM_LSUS-1:0] lsu_write_ready;

    // SECTION: Fetcher <-> Program Memory Controller (Flattened Wiring)
    // ---------------------------------------------------------------
    // Each core has one fetcher for instruction memory.
    // These are also flattened into a global array for arbitration by the program memory controller.
    localparam NUM_FETCHERS = NUM_CORES;
    reg [NUM_FETCHERS-1:0] fetcher_read_valid;
    reg [PROGRAM_MEM_ADDR_BITS-1:0] fetcher_read_address [NUM_FETCHERS-1:0];
    reg [NUM_FETCHERS-1:0] fetcher_read_ready;
    reg [PROGRAM_MEM_DATA_BITS-1:0] fetcher_read_data [NUM_FETCHERS-1:0];
    
    // Stores the total thread_count for the next launch.
    dcr dcr_instance (
        .clk(clk),
        .reset(reset),

        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),
        .thread_count(thread_count)
    );

    // Arbitrates all LSU traffic onto the external data-memory channels.
    controller #(
        .ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_BITS(DATA_MEM_DATA_BITS),
        .NUM_CONSUMERS(NUM_LSUS),
        .NUM_CHANNELS(DATA_MEM_NUM_CHANNELS)
    ) data_memory_controller (
        .clk(clk),
        .reset(reset),

        .consumer_read_valid(lsu_read_valid),
        .consumer_read_address(lsu_read_address),
        .consumer_read_ready(lsu_read_ready),
        .consumer_read_data(lsu_read_data),
        .consumer_write_valid(lsu_write_valid),
        .consumer_write_address(lsu_write_address),
        .consumer_write_data(lsu_write_data),
        .consumer_write_ready(lsu_write_ready),

        .mem_read_valid(data_mem_read_valid),
        .mem_read_address(data_mem_read_address),
        .mem_read_ready(data_mem_read_ready),
        .mem_read_data(data_mem_read_data),
        .mem_write_valid(data_mem_write_valid),
        .mem_write_address(data_mem_write_address),
        .mem_write_data(data_mem_write_data),
        .mem_write_ready(data_mem_write_ready)
    );

    // Arbitrates per-core fetch traffic onto the external program-memory channels.
    controller #(
        .ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .NUM_CONSUMERS(NUM_FETCHERS),
        .NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .WRITE_ENABLE(0)
    ) program_memory_controller (
        .clk(clk),
        .reset(reset),

        .consumer_read_valid(fetcher_read_valid),
        .consumer_read_address(fetcher_read_address),
        .consumer_read_ready(fetcher_read_ready),
        .consumer_read_data(fetcher_read_data),

        .mem_read_valid(program_mem_read_valid),
        .mem_read_address(program_mem_read_address),
        .mem_read_ready(program_mem_read_ready),
        .mem_read_data(program_mem_read_data),
    );

    // Splits total thread_count into blocks and assigns them to free cores.
    dispatch #(
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) dispatch_instance (
        .clk(clk),
        .reset(reset),
        .start(start),
        .thread_count(thread_count),
        .core_done(core_done),
        .core_start(core_start),
        .core_reset(core_reset),
        .core_block_id(core_block_id),
        .core_thread_count(core_thread_count),
        .done(done)
    );

    // SECTION: Core Instantiation and LSU/Signal Flattening
    // -----------------------------------------------------
    // This generate block creates NUM_CORES compute cores.
    // For each core, it:
    //   - Declares local arrays for that core's per-thread LSU signals.
    //   - Bridges each core's local LSU signals into the global flattened LSU arrays.
    //     (This is done by mapping (core, lane) -> global LSU index.)
    //   - Instantiates the core, wiring up all control and memory signals.
    //
    // The inner generate-for block is the key to understanding how hierarchical (core/lane) signals
    // are mapped to flat controller-facing arrays for arbitration.
    genvar i;
    generate
        for (i = 0; i < NUM_CORES; i = i + 1) begin : cores
            // Local LSU arrays for this core (one per thread lane)
            reg [THREADS_PER_BLOCK-1:0] core_lsu_read_valid;
            reg [DATA_MEM_ADDR_BITS-1:0] core_lsu_read_address [THREADS_PER_BLOCK-1:0];
            reg [THREADS_PER_BLOCK-1:0] core_lsu_read_ready;
            reg [DATA_MEM_DATA_BITS-1:0] core_lsu_read_data [THREADS_PER_BLOCK-1:0];
            reg [THREADS_PER_BLOCK-1:0] core_lsu_write_valid;
            reg [DATA_MEM_ADDR_BITS-1:0] core_lsu_write_address [THREADS_PER_BLOCK-1:0];
            reg [DATA_MEM_DATA_BITS-1:0] core_lsu_write_data [THREADS_PER_BLOCK-1:0];
            reg [THREADS_PER_BLOCK-1:0] core_lsu_write_ready;

            // Bridge this core's per-lane LSU ports into the flattened global LSU arrays.
            // lsu_index maps the 2-D coordinate (core, lane) into one global LSU slot.
            genvar j;
            for (j = 0; j < THREADS_PER_BLOCK; j = j + 1) begin
                localparam lsu_index = i * THREADS_PER_BLOCK + j;
                always @(posedge clk) begin 
                    // Core -> controller direction: move each lane's LSU signals into the global slot.
                    lsu_read_valid[lsu_index] <= core_lsu_read_valid[j];
                    lsu_read_address[lsu_index] <= core_lsu_read_address[j];

                    lsu_write_valid[lsu_index] <= core_lsu_write_valid[j];
                    lsu_write_address[lsu_index] <= core_lsu_write_address[j];
                    lsu_write_data[lsu_index] <= core_lsu_write_data[j];
                    
                    // Controller -> core direction: relay controller responses back to the correct lane.
                    core_lsu_read_ready[j] <= lsu_read_ready[lsu_index];
                    core_lsu_read_data[j] <= lsu_read_data[lsu_index];
                    core_lsu_write_ready[j] <= lsu_write_ready[lsu_index];
                end
            end

            // Instantiate one compute core.
            core #(
                .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
                .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
                .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS),
                .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
            ) core_instance (
                .clk(clk),
                .reset(core_reset[i]),
                .start(core_start[i]),
                .done(core_done[i]),
                .block_id(core_block_id[i]),
                .thread_count(core_thread_count[i]),
                
                .program_mem_read_valid(fetcher_read_valid[i]),
                .program_mem_read_address(fetcher_read_address[i]),
                .program_mem_read_ready(fetcher_read_ready[i]),
                .program_mem_read_data(fetcher_read_data[i]),

                .data_mem_read_valid(core_lsu_read_valid),
                .data_mem_read_address(core_lsu_read_address),
                .data_mem_read_ready(core_lsu_read_ready),
                .data_mem_read_data(core_lsu_read_data),
                .data_mem_write_valid(core_lsu_write_valid),
                .data_mem_write_address(core_lsu_write_address),
                .data_mem_write_data(core_lsu_write_data),
                .data_mem_write_ready(core_lsu_write_ready)
            );
        end
    endgenerate
endmodule
