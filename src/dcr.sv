`default_nettype none
`timescale 1ns/1ns

// DEVICE CONTROL REGISTER
// > Used to configure high-level GPU launch settings.
// > In this minimal example, the DCR only stores one thing: the total number of threads
//   that should be launched for the next kernel.
// > Beginner mental model:
//   software/testbench writes one 8-bit value here, and the dispatcher later reads it.
module dcr (
    input wire clk,
    input wire reset,

    // Simple write interface from the outside world / testbench.
    input wire device_control_write_enable,
    input wire [7:0] device_control_data,

    // Current configured total thread count for the kernel launch.
    output wire [7:0] thread_count,
);
    // Internal storage register for the device control data.
    reg [7:0] device_conrol_register;

    // In this design, the low 8 bits directly represent the kernel's total thread count.
    assign thread_count = device_conrol_register[7:0];

    always @(posedge clk) begin
        if (reset) begin
            // Reset clears the launch configuration.
            device_conrol_register <= 8'b0;
        end else begin
            if (device_control_write_enable) begin 
                // Latch the new launch configuration when write_enable is high.
                device_conrol_register <= device_control_data;
            end
        end
    end
endmodule
