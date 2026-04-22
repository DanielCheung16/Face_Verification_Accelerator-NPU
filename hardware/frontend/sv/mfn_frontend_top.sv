// ==============================================================================
// Module: mfn_frontend_top
// Description: Top-level wrapper for the MobileFaceNet Frontend.
//              Instantiates Datapath (Window, MAC, Act) and Control Path 
//              (FSM, Addr Gen) using strict Two-Process methodology.
// ==============================================================================

module mfn_frontend_top #(
    parameter int DWIDTH = 16,
    parameter int AWIDTH = 32,
    parameter int M_ADDR_WIDTH = 18
)(
    input  logic clk,
    input  logic rst_n,
    
    // Global Control
    input  logic start_inference,
    output logic inference_done,
    
    // Input Stream (From SRAM A or External)
    input  logic valid_in,
    input  logic signed [DWIDTH-1:0] pixel_in,
    
    // Weight Stream (From ROM)
    input  logic signed [DWIDTH-1:0] wgt_in [0:8],
    input  logic signed [AWIDTH-1:0] bias_in,
    input  logic do_prelu,
    input  logic signed [DWIDTH-1:0] prelu_weight,
    
    // Output Stream (To SRAM B)
    output logic valid_out,
    output logic signed [DWIDTH-1:0] pixel_out,
    
    // SRAM Address Control
    output logic [M_ADDR_WIDTH-1:0] sram_rd_addr,
    output logic [M_ADDR_WIDTH-1:0] sram_wr_addr
);

    // Internal Control Signals from FSM
    logic clear_acc, enable_mac, enable_shift;
    logic reset_ptr, inc_read, inc_write;
    
    // Datapath Interconnects
    logic signed [DWIDTH-1:0] window [0:8];
    logic valid_window;
    
    logic signed [AWIDTH-1:0] mac_result;
    logic valid_mac;

    // --------------------------------------------------------------------------
    // 1. Controller (FSM)
    // --------------------------------------------------------------------------
    mfn_controller u_ctrl (
        .clk             (clk),
        .rst_n           (rst_n),
        .start_inference (start_inference),
        .inference_done  (inference_done),
        .clear_acc       (clear_acc),
        .enable_mac      (enable_mac),
        .enable_shift    (enable_shift),
        .reset_ptr       (reset_ptr),
        .inc_read        (inc_read),
        .inc_write       (inc_write)
    );

    // --------------------------------------------------------------------------
    // 2. Address Generator
    // --------------------------------------------------------------------------
    mfn_addr_gen #(
        .AWIDTH(M_ADDR_WIDTH)
    ) u_addr_gen (
        .clk          (clk),
        .rst_n        (rst_n),
        .reset_ptr    (reset_ptr),
        .inc_read     (inc_read),
        .inc_write    (inc_write),
        .sram_rd_addr (sram_rd_addr),
        .sram_wr_addr (sram_wr_addr)
    );

    // --------------------------------------------------------------------------
    // 3. Sliding Window (Line Buffer)
    // --------------------------------------------------------------------------
    mfn_sliding_window #(
        .DWIDTH(DWIDTH),
        .MAX_WIDTH(96)
    ) u_sliding_window (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (valid_in && enable_shift),
        .pixel_in   (pixel_in),
        .valid_out  (valid_window),
        .window_out (window)
    );

    // --------------------------------------------------------------------------
    // 4. Multiplier-Accumulator (MAC) Array
    // --------------------------------------------------------------------------
    mfn_mac_array #(
        .NUM_MACS(9),
        .DWIDTH(DWIDTH),
        .AWIDTH(AWIDTH)
    ) u_mac_array (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_window && enable_mac),
        .act_in    (window),
        .wgt_in    (wgt_in),
        .bias_in   (bias_in),
        .clear_acc (clear_acc),
        .valid_out (valid_mac),
        .mac_out   (mac_result)
    );

    // --------------------------------------------------------------------------
    // 5. Activation (PReLU & Quantization)
    // --------------------------------------------------------------------------
    mfn_activation #(
        .DWIDTH(DWIDTH),
        .AWIDTH(AWIDTH),
        .F_BITS(10) // Fixed to Q5.10 scaling factor
    ) u_activation (
        .clk          (clk),
        .rst_n        (rst_n),
        .valid_in     (valid_mac),
        .mac_in       (mac_result),
        .do_prelu     (do_prelu),
        .prelu_weight (prelu_weight),
        .valid_out    (valid_out),
        .act_out      (pixel_out)
    );

endmodule
