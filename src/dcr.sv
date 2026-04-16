`default_nettype none
`timescale 1ns/1ns

// DEVICE CONTROL REGISTER (DCR)
//
// This is the GPU's small configuration register block. In this toy design it
// stores only one launch parameter: the total number of threads for the next
// kernel launch.
//
// Reading guide:
// - There is one internal 8-bit register.
// - reset clears it.
// - device_control_write_enable lets software/testbench replace it.
// - thread_count is just a wire view of the stored value.
//
// Logic is unchanged; this rewrite only improves comments.
module dcr (
    input wire clk,
    input wire reset,

    // Write port used before a kernel launch.
    input wire device_control_write_enable, // High for one clock when new launch metadata should be stored.
    input wire [7:0] device_control_data,   // New thread-count value.

    // Current launch metadata seen by the rest of the GPU.
    output wire [7:0] thread_count,
);
    // Physical storage for the launch configuration.
    reg [7:0] device_conrol_register;

    // Continuous assignment: thread_count always mirrors the stored register value.
    assign thread_count = device_conrol_register[7:0];

    // Synchronous register update.
    always @(posedge clk) begin
        if (reset) begin
            // Forget any previous launch configuration.
            device_conrol_register <= 8'b0;
        end else begin
            if (device_control_write_enable) begin 
                // Latch the next kernel's thread count.
                device_conrol_register <= device_control_data;
            end
        end
    end
endmodule
