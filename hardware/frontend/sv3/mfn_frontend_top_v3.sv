// =============================================================================
// mfn_frontend_top_v3.sv — Top-level: 12×12 Systolic Array MobileFaceNet
//
// Architecture:
//   - mfn_sa_12x12     : 12 output-ch × 12 input-ch PE array
//   - mfn_weight_rom_v3: 12-port weight memory (academic wide model)
//   - mfn_act_buf      : activation buffer (holds in_ch values, 12-wide read)
//   - mfn_psum_sram    : partial sum SRAM (same as v2)
//   - mfn_controller_v3: tiled FSM
//   - mfn_activation   : PReLU / BN activation (unchanged from v1)
//   - ROM modules       : bias, prelu, layer_config (unchanged from v1)
// =============================================================================

module mfn_frontend_top_v3 #(
    parameter int DWIDTH  = 16,
    parameter int AWIDTH  = 40,
    parameter int SA_ROWS = 12,
    parameter int SA_COLS = 12
)(
    input  logic              clk,
    input  logic              rst_n,
    input  logic              start_inference,
    output logic              inference_done,

    // Input activation bus: 12 lanes — external memory returns 12 consecutive
    // channels (c_in_out .. c_in_out+11) per cycle (opt ④).
    input  logic signed [DWIDTH-1:0] pixel_in [SA_COLS],

    // External SRAM address outputs (for input activation fetch)
    output logic              reset_ptr,
    output logic              inc_write,
    output logic              read_res,
    output logic signed [8:0] x_out,
    output logic signed [8:0] y_out,
    output logic [9:0]        c_in_out,

    // Output (same interface as v2 for tb compatibility)
    output logic [AWIDTH-1:0] pixel_out,
    output logic              valid_out
);

    // ── layer config ROM ──────────────────────────────────────────────────────
    logic [5:0]  layer_idx;
    logic [63:0] layer_config;
    logic        layer_is_pw_decoded, layer_is_res_decoded;

    mfn_layer_config_rom u_cfg_rom (
        .clk     (clk),
        .addr    (layer_idx),
        .data_out(layer_config)
    );

    assign layer_is_pw_decoded  = layer_config[38];
    assign layer_is_res_decoded = layer_config[37];

    // ── bias ROM ─────────────────────────────────────────────────────────────
    logic [13:0]       bias_addr;
    logic signed [31:0] bias_out_raw;   // bias ROM has DWIDTH=32

    mfn_bias_rom u_bias_rom (
        .addr    (bias_addr),
        .bias_out(bias_out_raw)
    );

    // ── PReLU ROM ─────────────────────────────────────────────────────────────
    logic [13:0]           prelu_addr;
    logic signed [DWIDTH-1:0] prelu_out;

    mfn_prelu_rom u_prelu_rom (
        .addr     (prelu_addr),
        .prelu_out(prelu_out)
    );

    // ── weight ROM v3 (12-port) ───────────────────────────────────────────────
    logic [19:0]             wgt_addr [SA_ROWS];
    logic signed [DWIDTH-1:0] wgt_out  [SA_ROWS][SA_COLS];

    mfn_weight_rom_v3 #(.SA_ROWS(SA_ROWS), .SA_COLS(SA_COLS)) u_wgt_rom (
        .addr   (wgt_addr),
        .wgt_out(wgt_out)
    );

    // ── activation buffer ────────────────────────────────────────────────────
    logic                        act_load_en;
    logic                        act_load_wide;
    logic [$clog2(512)-1:0]      act_load_ch;
    logic [$clog2(512)-1:0]      act_base_ch;
    logic [9:0]                  act_max_ch;
    logic signed [DWIDTH-1:0]    act_out [SA_COLS];

    mfn_act_buf #(.SA_COLS(SA_COLS)) u_act_buf (
        .clk      (clk),
        .rst_n    (rst_n),
        .load_en  (act_load_en),
        .load_wide(act_load_wide),
        .load_ch  (act_load_ch),
        .pixel_in (pixel_in),
        .max_ch   (act_max_ch),
        .base_ch  (act_base_ch),
        .act_out  (act_out)
    );

    // ── 12×12 SA ─────────────────────────────────────────────────────────────
    logic                        sa_clear;
    logic                        sa_enable;
    logic                        sa_dw_mode;
    logic signed [AWIDTH-1:0]    sa_bias_in [SA_ROWS];
    logic signed [AWIDTH-1:0]    sa_acc     [SA_ROWS];

    mfn_sa_12x12 #(.DWIDTH(DWIDTH), .AWIDTH(AWIDTH),
                   .SA_ROWS(SA_ROWS), .SA_COLS(SA_COLS)) u_sa (
        .clk     (clk),
        .rst_n   (rst_n),
        .clear   (sa_clear),
        .enable  (sa_enable),
        .dw_mode (sa_dw_mode),
        .act_in  (act_out),
        .wgt_in  (wgt_out),
        .bias_in (sa_bias_in),
        .acc_out (sa_acc)
    );

    // ── PSUM SRAM (reused from v2) ────────────────────────────────────────────
    logic              psum_we_a, psum_we_b;
    logic [8:0]        psum_waddr_a, psum_waddr_b;
    logic [AWIDTH-1:0] psum_wdata_a, psum_wdata_b;
    logic [AWIDTH-1:0] psum_rdata_a, psum_rdata_b, psum_rdata_c;
    logic [8:0]        psum_raddr_c;

    mfn_psum_sram #(.AWIDTH(AWIDTH)) u_psum_mem (
        .clk    (clk),
        .we_a   (psum_we_a),    .waddr_a(psum_waddr_a), .wdata_a(psum_wdata_a),
        .we_b   (psum_we_b),    .waddr_b(psum_waddr_b), .wdata_b(psum_wdata_b),
        .raddr_a(psum_waddr_a), .rdata_a(psum_rdata_a),
        .raddr_b(psum_waddr_b), .rdata_b(psum_rdata_b),
        .raddr_c(psum_raddr_c), .rdata_c(psum_rdata_c)
    );

    // ── activation module ─────────────────────────────────────────────────────
    logic [AWIDTH-1:0]        psum_to_act;
    logic signed [DWIDTH-1:0] act_pixel_out;
    logic                     act_valid_out;

    mfn_activation u_act (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_in    (inc_write),
        .p_out       (psum_to_act),
        .has_prelu   (layer_config[36]),   // per-layer flag from config
        .prelu_w     (prelu_out),
        .layer_is_res(layer_is_res_decoded),
        .residual_in (pixel_in[0]),
        .valid_out   (act_valid_out),
        .pixel_out   (act_pixel_out)
    );

    // Sign-extend 16-bit activation output to top-level AWIDTH-bit port
    assign pixel_out  = {{(AWIDTH-DWIDTH){act_pixel_out[DWIDTH-1]}}, act_pixel_out};
    assign valid_out  = act_valid_out;
    // PReLU ROM uses same per-channel address as bias ROM (matching v2)
    assign prelu_addr = bias_addr;

    // ── controller v3 ────────────────────────────────────────────────────────
    logic signed [AWIDTH-1:0] mac_bias_in;
    assign mac_bias_in = {{(AWIDTH-32){bias_out_raw[31]}}, bias_out_raw};

    mfn_controller_v3 #(.DWIDTH(DWIDTH), .AWIDTH(AWIDTH),
                        .SA_ROWS(SA_ROWS), .SA_COLS(SA_COLS)) u_ctrl (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start_inference),
        .done         (inference_done),

        .layer_idx    (layer_idx),
        .layer_config (layer_config),
        .layer_is_pw  (layer_is_pw_decoded),
        .layer_is_res (layer_is_res_decoded),

        .reset_ptr    (reset_ptr),
        .inc_write    (inc_write),
        .read_res     (read_res),
        .x_out        (x_out),
        .y_out        (y_out),
        .c_in_out     (c_in_out),

        .act_load_en  (act_load_en),
        .act_load_wide(act_load_wide),
        .act_load_ch  (act_load_ch),
        .act_base_ch  (act_base_ch),
        .act_max_ch   (act_max_ch),

        .sa_clear     (sa_clear),
        .sa_enable    (sa_enable),
        .sa_dw_mode   (sa_dw_mode),
        .sa_bias_in   (sa_bias_in),

        .wgt_addr     (wgt_addr),

        .bias_addr    (bias_addr),

        .psum_we_a    (psum_we_a),
        .psum_waddr_a (psum_waddr_a),
        .psum_wdata_a (psum_wdata_a),
        .psum_we_b    (psum_we_b),
        .psum_waddr_b (psum_waddr_b),
        .psum_wdata_b (psum_wdata_b),
        .psum_raddr_c (psum_raddr_c),
        .psum_rdata_a (psum_rdata_a),
        .psum_rdata_c (psum_rdata_c),

        .sa_acc       (sa_acc),
        .psum_to_act  (psum_to_act),
        .mac_bias_in  (mac_bias_in)
    );

endmodule
