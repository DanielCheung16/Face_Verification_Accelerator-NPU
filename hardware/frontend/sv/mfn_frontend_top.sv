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
    
    // ROM interfaces
    logic [5:0] layer_idx;
    logic [9:0] wgt_rom_addr;
    
    // Layer Config
    logic [9:0] in_ch, out_ch;
    logic [7:0] img_width, img_height;
    logic [1:0] stride;
    logic has_prelu, ping_pong;

    // Weight and Bias from ROM
    logic signed [DWIDTH-1:0] wgt_in [0:8];
    logic signed [AWIDTH-1:0] bias_in;
    logic signed [DWIDTH-1:0] prelu_weight;

    // Datapath Interconnects
    logic is_pad;
    logic signed [DWIDTH-1:0] actual_pixel;
    logic signed [DWIDTH-1:0] window [0:8];
    logic valid_window;
    
    logic signed [AWIDTH-1:0] mac_result;
    logic valid_mac;

    // --------------------------------------------------------------------------
    // Padding Multiplexer (MUX)
    // --------------------------------------------------------------------------
    assign actual_pixel = is_pad ? 16'h0000 : pixel_in;

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
        .inc_write       (inc_write),
        .layer_in_ch     (in_ch),
        .layer_out_ch    (out_ch),
        .layer_width     (img_width),
        .layer_height    (img_height),
        .layer_stride    (stride),
        .layer_idx       (layer_idx),
        .wgt_rom_addr    (wgt_rom_addr)
    );

    // --------------------------------------------------------------------------
    // 1.5 Configuration ROM
    // --------------------------------------------------------------------------
    mfn_layer_config_rom #(
        .ADDR_WIDTH(6)
    ) u_config_rom (
        .clk                (clk),
        .addr               (layer_idx),
        .out_in_ch          (in_ch),
        .out_out_ch         (out_ch),
        .out_width          (img_width),
        .out_height         (img_height),
        .out_stride         (stride),
        .out_has_prelu      (has_prelu),
        .out_ping_pong_flag (ping_pong)
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
        .img_width    (img_width),
        .img_height   (img_height),
        .sram_rd_addr (sram_rd_addr),
        .sram_wr_addr (sram_wr_addr),
        .is_pad       (is_pad)
    );

    // --------------------------------------------------------------------------
    // 2.5 Weight ROM
    // --------------------------------------------------------------------------
    mfn_weight_rom #(
        .ADDR_WIDTH(10),
        .DWIDTH(DWIDTH),
        .BWIDTH(AWIDTH)
    ) u_weight_rom (
        .clk              (clk),
        .addr             (wgt_rom_addr),
        .wgt_out          (wgt_in),
        .bias_out         (bias_in),
        .prelu_weight_out (prelu_weight)
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
        .pixel_in   (actual_pixel), // Feed MUXed pixel
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
        .wgt_in    (wgt_in),     // From ROM
        .bias_in   (bias_in),    // From ROM
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
        .do_prelu     (has_prelu),   // From Config ROM
        .prelu_weight (prelu_weight),// From Weight ROM
        .valid_out    (valid_out),
        .act_out      (pixel_out)
    );

endmodule
