// ==============================================================================
// Module: mfn_frontend_top
// Description: Top-level for MobileFaceNet Frontend (supports DW-Conv).
// ==============================================================================

module mfn_frontend_top #(
    parameter int DWIDTH = 16,
    parameter int AWIDTH = 40,
    parameter int M_ADDR_WIDTH = 20
)(
    input  logic                    clk,
    input  logic                    rst_n,
    
    input  logic                    start_inference,
    output logic                    inference_done,
    
    // SRAM Interface
    output logic [M_ADDR_WIDTH-1:0] sram_rd_addr,
    input  logic signed [DWIDTH-1:0] pixel_in,
    
    output logic [M_ADDR_WIDTH-1:0] sram_wr_addr,
    output logic                    valid_out,
    output logic signed [DWIDTH-1:0] pixel_out
);

    // Layer Configuration Wires
    logic [63:0] layer_config;
    logic [5:0]  layer_idx;
    logic [9:0]  in_ch, out_ch;
    logic [6:0]  img_w, img_h;
    logic [1:0]  layer_stride;
    logic        layer_is_pw, layer_is_dw, layer_is_res;
    logic [1:0]  layer_rd_buf, layer_wr_buf;
    
    // Internal Signals
    logic        reset_ptr;
    logic        inc_write;
    logic        read_res;
    
    logic signed [8:0] x_ctrl, y_ctrl;
    logic [9:0]        c_in_ctrl;
    logic              is_pad;
    
    logic              load_pixel;
    logic [3:0]        pixel_idx;
    logic [19:0]       weight_addr;
    logic              enable_mac;
    logic [AWIDTH-1:0] mac_bias_in;
    logic [AWIDTH-1:0] mac_res;
    logic [AWIDTH-1:0] psum_val;
    logic [13:0]       bias_addr;
    
    logic signed [DWIDTH-1:0] win_data [0:8];
    logic signed [DWIDTH-1:0] wgt_data [0:8];

    // 1. Controller
    mfn_controller #(
        .DWIDTH(DWIDTH),
        .AWIDTH(AWIDTH)
    ) u_ctrl (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_inference),
        .done(inference_done),
        .layer_idx(layer_idx),
        .layer_config(layer_config),
        .layer_is_pw(layer_is_pw),
        .layer_is_res(layer_is_res),
        .reset_ptr(reset_ptr),
        .inc_write(inc_write),
        .read_res(read_res),
        .x_out(x_ctrl),
        .y_out(y_ctrl),
        .c_in_out(c_in_ctrl),
        .load_pixel(load_pixel),
        .pixel_idx(pixel_idx),
        .weight_addr(weight_addr),
        .enable_mac(enable_mac),
        .clear_mac_acc(),
        .mac_bias_in(mac_bias_in),
        .bias_addr(bias_addr),
        .mac_data_in(mac_res),
        .psum_to_act(psum_val)
    );

    // 2. Config ROM (64-bit)
    mfn_layer_config_rom u_cfg_rom (
        .clk(clk),
        .addr(layer_idx),
        .data_out(layer_config)
    );
    
    // Config format: {wr_buf(2),rd_buf(2),wgt_base(20),is_dw(1),is_pw(1),is_res(1),
    //                 prelu(1),stride(2),h(7),w(7),out_ch(10),in_ch(10)}
    assign in_ch  = layer_config[9:0];
    assign out_ch = layer_config[19:10];
    assign img_w  = layer_config[26:20];
    assign img_h  = layer_config[33:27];
    assign layer_stride = layer_config[35:34];
    assign layer_is_res = layer_config[37];
    assign layer_is_pw  = layer_config[38];
    assign layer_is_dw  = layer_config[39];
    assign layer_rd_buf = layer_config[61:60];
    assign layer_wr_buf = layer_config[63:62];

    // Internal write address (before pipeline delay)
    logic [M_ADDR_WIDTH-1:0] sram_wr_addr_raw;
    logic [M_ADDR_WIDTH-1:0] sram_wr_addr_r1;   // extra delay stage for activation 2-cycle pipeline

    // 3. Address Generator (with ping-pong)
    mfn_addr_gen #(
        .AWIDTH(AWIDTH),
        .M_ADDR_WIDTH(M_ADDR_WIDTH)
    ) u_addr_gen (
        .clk(clk),
        .rst_n(rst_n),
        .reset_ptr(reset_ptr),
        .inc_write(inc_write),
        .rd_buf(layer_rd_buf),
        .wr_buf(layer_wr_buf),
        .read_res(read_res),
        .x_in(x_ctrl),
        .y_in(y_ctrl),
        .c_in(c_in_ctrl),
        .width_in(img_w),
        .height_in(img_h),
        .in_ch_in(in_ch),
        .out_ch_in(out_ch),
        .sram_rd_addr(sram_rd_addr),
        .sram_wr_addr(sram_wr_addr_raw),
        .is_pad(is_pad)
    );

    // Delay write address by 2 cycles to align with 2-stage Activation pipeline
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram_wr_addr_r1 <= '0;
            sram_wr_addr    <= '0;
        end else begin
            sram_wr_addr_r1 <= sram_wr_addr_raw;
            sram_wr_addr    <= sram_wr_addr_r1;
        end
    end

    // 4. Sliding Window
    mfn_sliding_window #(
        .DWIDTH(DWIDTH)
    ) u_window (
        .clk(clk),
        .rst_n(rst_n),
        .clear(reset_ptr),
        .load_en(load_pixel),
        .load_idx(pixel_idx),
        .pixel_in(is_pad ? {DWIDTH{1'b0}} : pixel_in),
        .window_out(win_data)
    );

    // 5. Weight ROM
    mfn_weight_rom #(
        .DWIDTH(DWIDTH)
    ) u_wgt_rom (
        .clk(clk),
        .addr(weight_addr),
        .weights_out(wgt_data)
    );

    logic signed [DWIDTH-1:0] prelu_val_rom;
    logic signed [31:0] bias_32;

    // 5b. Bias ROM (uses bias_addr from controller, includes layer base)
    mfn_bias_rom #(
        .DWIDTH(32)
    ) u_bias_rom (
        .addr(bias_addr),
        .bias_out(bias_32)
    );
    assign mac_bias_in = $signed(bias_32);

    // 5c. PReLU ROM (uses same bias_addr for per-channel indexing)
    mfn_prelu_rom #(
        .DWIDTH(DWIDTH)
    ) u_prelu_rom (
        .addr(bias_addr),
        .prelu_out(prelu_val_rom)
    );

    // 6. MAC Array (Pipelined)
    mfn_mac_array #(
        .NUM_MACS(9),
        .DWIDTH(DWIDTH),
        .AWIDTH(AWIDTH)
    ) u_mac (
        .clk(clk),
        .rst_n(rst_n),
        .act_in(win_data),
        .wgt_in(wgt_data),
        .mac_out(mac_res)
    );

    // 7. Activation & Quantization
    mfn_activation #(
        .DWIDTH(DWIDTH),
        .AWIDTH(AWIDTH)
    ) u_act (
        .clk(clk),
        .rst_n(rst_n),
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
