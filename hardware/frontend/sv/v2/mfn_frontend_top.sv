// ==============================================================================
// Module: mfn_frontend_top (v2)
// v2 changes:
//   Item 3 — Wide SRAM interface: adds sram_rd_addr_wide[0:8] / pixel_in_wide[0:8]
//   Item 4 — CLA psum adder (instantiated inside controller)
//   Item 5 — Dual MAC: adds second mfn_mac_array and dual-port weight ROM
// ==============================================================================

module mfn_frontend_top #(
    parameter int DWIDTH       = 16,
    parameter int AWIDTH       = 40,
    parameter int M_ADDR_WIDTH = 20
)(
    input  logic                      clk,
    input  logic                      rst_n,

    input  logic                      start_inference,
    output logic                      inference_done,

    // ── SRAM Interface ──────────────────────────────────────────────────────
    // Single-pixel path (PW / global-DW and residual reads)
    output logic [M_ADDR_WIDTH-1:0]   sram_rd_addr,
    input  logic signed [DWIDTH-1:0]  pixel_in,

    // Wide-mode path (standard conv / DW conv): 9 simultaneous reads
    output logic [M_ADDR_WIDTH-1:0]   sram_rd_addr_wide [0:8],
    input  logic signed [DWIDTH-1:0]  pixel_in_wide     [0:8],

    output logic [M_ADDR_WIDTH-1:0]   sram_wr_addr,
    output logic                      valid_out,
    output logic signed [DWIDTH-1:0]  pixel_out
);

    // ── Internal wires ──────────────────────────────────────────────────────
    logic [63:0] layer_config;
    logic [5:0]  layer_idx;
    logic [9:0]  in_ch, out_ch;
    logic [6:0]  img_w, img_h;
    logic [1:0]  layer_stride;
    logic        layer_is_pw, layer_is_dw, layer_is_res;
    logic [1:0]  layer_rd_buf, layer_wr_buf;

    logic        reset_ptr, inc_write, read_res;
    logic signed [8:0] x_ctrl, y_ctrl;
    logic [9:0]        c_in_ctrl;
    logic              is_pad;

    logic              load_pixel;
    logic [3:0]        pixel_idx;
    logic              wide_mode, wide_load_en;

    logic [19:0]       weight_addr,   weight_addr_b;
    logic              enable_mac,    enable_mac_b;
    logic [AWIDTH-1:0] mac_bias_in;
    logic [AWIDTH-1:0] mac_res_a,     mac_res_b;
    logic [AWIDTH-1:0] psum_val;
    logic [13:0]       bias_addr;

    logic signed [DWIDTH-1:0] win_data  [0:8];
    logic signed [DWIDTH-1:0] wgt_a     [0:8];
    logic signed [DWIDTH-1:0] wgt_b     [0:8];

    // Wide-mode: per-pixel padding mask applied before window
    logic              is_pad_wide [0:8];
    logic signed [DWIDTH-1:0] pixels_wide_masked [0:8];

    genvar pix;
    generate
        for (pix = 0; pix < 9; pix++) begin : PIX_MASK
            assign pixels_wide_masked[pix] =
                is_pad_wide[pix] ? {DWIDTH{1'b0}} : pixel_in_wide[pix];
        end
    endgenerate

    // ── 1. Controller ───────────────────────────────────────────────────────
    mfn_controller #(
        .DWIDTH(DWIDTH), .AWIDTH(AWIDTH)
    ) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .start(start_inference), .done(inference_done),
        .layer_idx(layer_idx),
        .layer_config(layer_config),
        .layer_is_pw(layer_is_pw),
        .layer_is_res(layer_is_res),
        .reset_ptr(reset_ptr), .inc_write(inc_write), .read_res(read_res),
        .x_out(x_ctrl), .y_out(y_ctrl), .c_in_out(c_in_ctrl),
        .load_pixel(load_pixel), .pixel_idx(pixel_idx),
        .wide_mode(wide_mode), .wide_load_en(wide_load_en),
        .weight_addr(weight_addr), .weight_addr_b(weight_addr_b),
        .enable_mac(enable_mac), .enable_mac_b(enable_mac_b),
        .clear_mac_acc(),
        .mac_bias_in(mac_bias_in), .bias_addr(bias_addr),
        .mac_data_in(mac_res_a), .mac_data_in_b(mac_res_b),
        .psum_to_act(psum_val)
    );

    // ── 2. Config ROM ───────────────────────────────────────────────────────
    mfn_layer_config_rom u_cfg_rom (
        .clk(clk), .addr(layer_idx), .data_out(layer_config)
    );

    assign in_ch         = layer_config[9:0];
    assign out_ch        = layer_config[19:10];
    assign img_w         = layer_config[26:20];
    assign img_h         = layer_config[33:27];
    assign layer_stride  = layer_config[35:34];
    assign layer_is_res  = layer_config[37];
    assign layer_is_pw   = layer_config[38];
    assign layer_is_dw   = layer_config[39];
    assign layer_rd_buf  = layer_config[61:60];
    assign layer_wr_buf  = layer_config[63:62];

    // ── 3. Address Generator ────────────────────────────────────────────────
    logic [M_ADDR_WIDTH-1:0] sram_wr_addr_raw, sram_wr_addr_r1;

    mfn_addr_gen #(
        .AWIDTH(AWIDTH), .M_ADDR_WIDTH(M_ADDR_WIDTH)
    ) u_addr_gen (
        .clk(clk), .rst_n(rst_n),
        .reset_ptr(reset_ptr), .inc_write(inc_write),
        .rd_buf(layer_rd_buf), .wr_buf(layer_wr_buf), .read_res(read_res),
        .x_in(x_ctrl), .y_in(y_ctrl), .c_in(c_in_ctrl),
        .width_in(img_w), .height_in(img_h),
        .in_ch_in(in_ch), .out_ch_in(out_ch),
        .wide_mode(wide_mode),
        .sram_rd_addr(sram_rd_addr),
        .sram_wr_addr(sram_wr_addr_raw),
        .is_pad(is_pad),
        .sram_rd_addr_wide(sram_rd_addr_wide),
        .is_pad_wide(is_pad_wide)
    );

    // Delay write address 2 cycles to align with 2-stage Activation pipeline
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram_wr_addr_r1 <= '0; sram_wr_addr <= '0;
        end else begin
            sram_wr_addr_r1 <= sram_wr_addr_raw;
            sram_wr_addr    <= sram_wr_addr_r1;
        end
    end

    // ── 4. Sliding Window ───────────────────────────────────────────────────
    mfn_sliding_window #(
        .DWIDTH(DWIDTH)
    ) u_window (
        .clk(clk), .rst_n(rst_n),
        .clear(reset_ptr),
        .load_en(load_pixel),
        .load_idx(pixel_idx),
        .pixel_in(is_pad ? {DWIDTH{1'b0}} : pixel_in),  // single-pixel (PW/residual)
        .load_all(wide_load_en),
        .pixels_all_in(pixels_wide_masked),               // wide-mode (std/DW)
        .window_out(win_data)
    );

    // ── 5a. Weight ROM (dual-port for Item 5) ───────────────────────────────
    mfn_weight_rom #(
        .DWIDTH(DWIDTH)
    ) u_wgt_rom (
        .clk(clk),
        .addr_a(weight_addr),
        .addr_b(weight_addr_b),
        .weights_a(wgt_a),
        .weights_b(wgt_b)
    );

    logic signed [DWIDTH-1:0] prelu_val_rom;
    logic signed [31:0]        bias_32;

    // ── 5b. Bias ROM ────────────────────────────────────────────────────────
    mfn_bias_rom #(.DWIDTH(32)) u_bias_rom (
        .addr(bias_addr), .bias_out(bias_32)
    );
    assign mac_bias_in = $signed(bias_32);

    // ── 5c. PReLU ROM ───────────────────────────────────────────────────────
    mfn_prelu_rom #(.DWIDTH(DWIDTH)) u_prelu_rom (
        .addr(bias_addr), .prelu_out(prelu_val_rom)
    );

    // ── 6. MAC Array A (primary c_out) ──────────────────────────────────────
    mfn_mac_array #(
        .NUM_MACS(9), .DWIDTH(DWIDTH), .AWIDTH(AWIDTH)
    ) u_mac_a (
        .clk(clk), .rst_n(rst_n),
        .act_in(win_data),
        .wgt_in(wgt_a),
        .mac_out(mac_res_a)
    );

    // ── 6b. MAC Array B (Item 5: c_out+1) ───────────────────────────────────
    mfn_mac_array #(
        .NUM_MACS(9), .DWIDTH(DWIDTH), .AWIDTH(AWIDTH)
    ) u_mac_b (
        .clk(clk), .rst_n(rst_n),
        .act_in(win_data),    // same activation window
        .wgt_in(wgt_b),       // different weights (c_out+1)
        .mac_out(mac_res_b)
    );

    // ── 7. Activation & Quantization ────────────────────────────────────────
    mfn_activation #(
        .DWIDTH(DWIDTH), .AWIDTH(AWIDTH)
    ) u_act (
        .clk(clk), .rst_n(rst_n),
        .valid_in(inc_write),
        .p_out(psum_val),
        .has_prelu(layer_config[36]),
        .prelu_w(prelu_val_rom),
        .layer_is_res(layer_is_res),
        .residual_in(pixel_in),
        .pixel_out(pixel_out),
        .valid_out(valid_out)
    );

endmodule
