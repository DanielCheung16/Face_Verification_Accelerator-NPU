`include "layer_defs.svh"

// Synthesis-only timing wrapper for conv1x1_level3_top.
//
// The real level3 module has wide matrix/config interfaces. If it is used as
// the FPGA top directly, Synplify spends resources on top-level I/O pins instead
// of showing useful datapath timing. This wrapper keeps I/O tiny while preserving
// the internal paths through preload, array_level2, postprocess, wb_buffer, and
// wr_controller.
module synth_conv1x1_level3_wrapper #(
    parameter int ROW       = 4,
    parameter int COL       = 4,
    parameter int K_MAX     = 64,
    parameter int COUNT_W   = 16,
    parameter int K_ADDR_W  = (K_MAX <= 1) ? 1 : $clog2(K_MAX),
    parameter int DATA_W    = 8,
    parameter int ACC_W     = 32,
    parameter int BIAS_W    = 64,
    parameter int OUT_W     = 8,
    parameter int MULT_W    = 32,
    parameter int SHIFT_W   = 6,
    parameter int BUF_NUM   = 2,
    parameter int DIM_W     = 16,
    parameter int GB_DATA_W = 128,
    parameter int AO_DEPTH  = 512,
    parameter int WGT_DEPTH = 512,
    parameter int AO_ADDR_W = (AO_DEPTH <= 1) ? 1 : $clog2(AO_DEPTH),
    parameter int WGT_ADDR_W = (WGT_DEPTH <= 1) ? 1 : $clog2(WGT_DEPTH),
    parameter int LAYER_IDX_W = 4,

    localparam int GB_ADDR_W = (AO_ADDR_W > WGT_ADDR_W) ? AO_ADDR_W : WGT_ADDR_W,
    localparam int AO_MASK_W = GB_DATA_W / DATA_W,
    localparam int WB_ADDR_W = (ROW <= 1) ? 1 : $clog2(ROW)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic en_i,
    output logic done_o,
    output logic [31:0] checksum_o
);
    logic start_r;
    logic run_en_r;
    logic busy_w;
    logic done_w;
    logic [LAYER_IDX_W-1:0] layer_idx_r;

    logic [K_ADDR_W:0] k_size_r;
    logic [DIM_W-1:0] m_size_r;
    logic [DIM_W-1:0] n_size_r;
    logic [GB_ADDR_W-1:0] act_base_addr_r;
    logic [GB_ADDR_W-1:0] wgt_base_addr_r;
    logic [GB_ADDR_W-1:0] out_base_addr_r;
    logic residual_en_r;
    logic [GB_ADDR_W-1:0] residual_base_addr_r;
    postprocess_mode_t mode_r;

    logic signed [BIAS_W-1:0] bias_r [COL];
    logic signed [MULT_W-1:0] multiplier_r [COL];
    logic [SHIFT_W-1:0] shift_r [COL];
    logic signed [OUT_W-1:0] zero_point_r [COL];
    logic signed [MULT_W-1:0] prelu_multiplier_r [COL];
    logic [SHIFT_W-1:0] prelu_shift_r [COL];
    logic signed [MULT_W-1:0] residual_multiplier_r [COL];
    logic [SHIFT_W-1:0] residual_shift_r [COL];
    logic signed [ACC_W-1:0] residual_zero_point_r [COL];

    logic gb_act_rd_valid_w;
    logic [GB_ADDR_W-1:0] gb_act_rd_addr_w;
    logic [GB_DATA_W-1:0] gb_act_rd_data_r;
    logic gb_ao_wr_valid_w;
    logic [GB_ADDR_W-1:0] gb_ao_wr_addr_w;
    logic [GB_DATA_W-1:0] gb_ao_wr_data_w;
    logic [AO_MASK_W-1:0] gb_ao_wr_mask_w;

    logic gb_wgt_rd_valid_w;
    logic [GB_ADDR_W-1:0] gb_wgt_rd_addr_w;
    logic [GB_DATA_W-1:0] gb_wgt_rd_data_r;

    logic                       conv_post_valid_tile_w;
    logic                       post_valid_tile_w;
    logic [DIM_W-1:0]           conv_post_row_base_w;
    logic [DIM_W-1:0]           conv_post_col_base_w;
    logic [DIM_W-1:0]           conv_post_m_size_w;
    logic [DIM_W-1:0]           conv_post_n_size_w;
    postprocess_mode_t          conv_post_mode_w;
    logic                       conv_post_valid_w [ROW][COL];
    logic signed [ACC_W-1:0]    conv_post_acc_w [ROW][COL];
    logic signed [ACC_W-1:0]    conv_post_residual_w [ROW][COL];
    logic signed [BIAS_W-1:0]   conv_post_bias_w [COL];
    logic signed [MULT_W-1:0]   conv_post_multiplier_w [COL];
    logic [SHIFT_W-1:0]         conv_post_shift_w [COL];
    logic signed [OUT_W-1:0]    conv_post_zero_point_w [COL];
    logic signed [MULT_W-1:0]   conv_post_prelu_multiplier_w [COL];
    logic [SHIFT_W-1:0]         conv_post_prelu_shift_w [COL];
    logic signed [MULT_W-1:0]   conv_post_residual_multiplier_w [COL];
    logic [SHIFT_W-1:0]         conv_post_residual_shift_w [COL];
    logic signed [ACC_W-1:0]    conv_post_residual_zero_point_w [COL];
    logic                       conv_wb_capture_en_w;
    logic                       conv_wb_done_w;
    logic [DIM_W-1:0]           conv_wb_m_size_w;
    logic [DIM_W-1:0]           conv_wb_n_size_w;
    logic [GB_ADDR_W-1:0]       conv_wb_out_base_addr_w;
    logic                       post_valid_w [ROW][COL];
    logic signed [OUT_W-1:0]    post_data_w [ROW][COL];
    logic [WB_ADDR_W-1:0]       wb_rd_addr_w;
    logic [GB_DATA_W-1:0]       wb_data_w;

    conv1x1_level3_top #(
        .ROW(ROW),
        .COL(COL),
        .K_MAX(K_MAX),
        .COUNT_W(COUNT_W),
        .K_ADDR_W(K_ADDR_W),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .OUT_W(OUT_W),
        .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W),
        .BUF_NUM(BUF_NUM),
        .DIM_W(DIM_W),
        .GB_DATA_W(GB_DATA_W),
        .AO_DEPTH(AO_DEPTH),
        .WGT_DEPTH(WGT_DEPTH),
        .AO_ADDR_W(AO_ADDR_W),
        .WGT_ADDR_W(WGT_ADDR_W),
        .LAYER_IDX_W(LAYER_IDX_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_r),
        .start_i(start_r),
        .layer_idx_i(layer_idx_r),
        .busy_o(busy_w),
        .done_o(done_w),
        .k_size_i(k_size_r),
        .m_size_i(m_size_r),
        .n_size_i(n_size_r),
        .act_base_addr_i(act_base_addr_r),
        .wgt_base_addr_i(wgt_base_addr_r),
        .out_base_addr_i(out_base_addr_r),
        .residual_en_i(residual_en_r),
        .residual_base_addr_i(residual_base_addr_r),
        .mode_i(mode_r),
        .bias_i(bias_r),
        .multiplier_i(multiplier_r),
        .shift_i(shift_r),
        .zero_point_i(zero_point_r),
        .prelu_multiplier_i(prelu_multiplier_r),
        .prelu_shift_i(prelu_shift_r),
        .residual_multiplier_i(residual_multiplier_r),
        .residual_shift_i(residual_shift_r),
        .residual_zero_point_i(residual_zero_point_r),
        .post_valid_tile_o(conv_post_valid_tile_w),
        .post_valid_tile_i(post_valid_tile_w),
        .post_row_base_o(conv_post_row_base_w),
        .post_col_base_o(conv_post_col_base_w),
        .post_m_size_o(conv_post_m_size_w),
        .post_n_size_o(conv_post_n_size_w),
        .post_mode_o(conv_post_mode_w),
        .post_valid_o(conv_post_valid_w),
        .post_acc_o(conv_post_acc_w),
        .post_residual_o(conv_post_residual_w),
        .post_bias_o(conv_post_bias_w),
        .post_multiplier_o(conv_post_multiplier_w),
        .post_shift_o(conv_post_shift_w),
        .post_zero_point_o(conv_post_zero_point_w),
        .post_prelu_multiplier_o(conv_post_prelu_multiplier_w),
        .post_prelu_shift_o(conv_post_prelu_shift_w),
        .post_residual_multiplier_o(conv_post_residual_multiplier_w),
        .post_residual_shift_o(conv_post_residual_shift_w),
        .post_residual_zero_point_o(conv_post_residual_zero_point_w),
        .wb_capture_en_o(conv_wb_capture_en_w),
        .wb_done_i(conv_wb_done_w),
        .wb_m_size_o(conv_wb_m_size_w),
        .wb_n_size_o(conv_wb_n_size_w),
        .wb_out_base_addr_o(conv_wb_out_base_addr_w),
        .gb_act_rd_valid_o(gb_act_rd_valid_w),
        .gb_act_rd_addr_o(gb_act_rd_addr_w),
        .gb_act_rd_data_i(gb_act_rd_data_r),
        .gb_wgt_rd_valid_o(gb_wgt_rd_valid_w),
        .gb_wgt_rd_addr_o(gb_wgt_rd_addr_w),
        .gb_wgt_rd_data_i(gb_wgt_rd_data_r)
    );

    conv1x1_output_postprocess #(
        .ROW(ROW),
        .COL(COL),
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .OUT_W(OUT_W),
        .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W),
        .DIM_W(DIM_W)
    ) u_postprocess (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_r),
        .valid_tile_i(conv_post_valid_tile_w),
        .row_base_i(conv_post_row_base_w),
        .col_base_i(conv_post_col_base_w),
        .m_size_i(conv_post_m_size_w),
        .n_size_i(conv_post_n_size_w),
        .valid_i(conv_post_valid_w),
        .acc_i(conv_post_acc_w),
        .mode_i(conv_post_mode_w),
        .bias_i(conv_post_bias_w),
        .multiplier_i(conv_post_multiplier_w),
        .shift_i(conv_post_shift_w),
        .zero_point_i(conv_post_zero_point_w),
        .prelu_multiplier_i(conv_post_prelu_multiplier_w),
        .prelu_shift_i(conv_post_prelu_shift_w),
        .residual_i(conv_post_residual_w),
        .residual_multiplier_i(conv_post_residual_multiplier_w),
        .residual_shift_i(conv_post_residual_shift_w),
        .residual_zero_point_i(conv_post_residual_zero_point_w),
        .valid_o(post_valid_w),
        .valid_tile_o(post_valid_tile_w),
        .data_o(post_data_w)
    );

    wb_buffer #(
        .ROW(ROW),
        .COL(COL),
        .DATA_IN_W(OUT_W),
        .DATA_OUT_W(GB_DATA_W)
    ) u_wb_buffer (
        .aclk(clk),
        .aresetn(rst_n),
        .wr_en_i(conv_wb_capture_en_w),
        .data_i(post_data_w),
        .rd_addr_i(wb_rd_addr_w),
        .data_o(wb_data_w)
    );

    wr_controller #(
        .ROW(ROW),
        .COL(COL),
        .DATA_OUT_W(GB_DATA_W),
        .DIM_W(DIM_W),
        .GB_ADDR_W(GB_ADDR_W)
    ) u_wr_controller (
        .aclk(clk),
        .aresetn(rst_n),
        .n_size_i(conv_wb_n_size_w),
        .m_size_i(conv_wb_m_size_w),
        .out_base_addr_i(conv_wb_out_base_addr_w),
        .tile_process_done(conv_wb_capture_en_w),
        .data_i(wb_data_w),
        .rd_addr_o(wb_rd_addr_w),
        .ao_addr_o(gb_ao_wr_addr_w),
        .ao_wr_en_o(gb_ao_wr_valid_w),
        .ao_data_o(gb_ao_wr_data_w),
        .busy_o(),
        .done_o(conv_wb_done_w)
    );

    assign gb_ao_wr_mask_w = {AO_MASK_W{1'b1}};

    function automatic logic [GB_DATA_W-1:0] make_word(
        input logic [GB_ADDR_W-1:0] addr,
        input logic [15:0] salt
    );
        logic [GB_DATA_W-1:0] word;
        begin
            word = '0;
            for (int lane = 0; lane < (GB_DATA_W / DATA_W); lane++) begin
                word[lane*DATA_W +: DATA_W] =
                    DATA_W'(addr[DATA_W-1:0] + DATA_W'(lane) + DATA_W'(salt[7:0]));
            end
            make_word = word;
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_r <= 1'b0;
            run_en_r <= 1'b1;
            done_o <= 1'b0;
            checksum_o <= '0;
            layer_idx_r <= '0;
            k_size_r <= K_ADDR_W'(64);
            m_size_r <= DIM_W'(ROW * 2);
            n_size_r <= DIM_W'(COL * 2);
            act_base_addr_r <= '0;
            wgt_base_addr_r <= '0;
            out_base_addr_r <= GB_ADDR_W'(1024);
            residual_en_r <= 1'b1;
            residual_base_addr_r <= GB_ADDR_W'(2048);
            mode_r <= MODE_RESIDUAL;
            gb_act_rd_data_r <= '0;
            gb_wgt_rd_data_r <= '0;

            for (int c = 0; c < COL; c++) begin
                bias_r[c] <= BIAS_W'(c * 97 - 4096);
                multiplier_r[c] <= MULT_W'(32'sd131072 + c * 29);
                shift_r[c] <= SHIFT_W'(18);
                zero_point_r[c] <= OUT_W'(-8'sd4 + c[OUT_W-1:0]);
                prelu_multiplier_r[c] <= MULT_W'(32'sd32768 + c * 3);
                prelu_shift_r[c] <= SHIFT_W'(16);
                residual_multiplier_r[c] <= MULT_W'(32'sd65536 - c * 11);
                residual_shift_r[c] <= SHIFT_W'(16);
                residual_zero_point_r[c] <= ACC_W'(32'sd3);
            end
        end else if (en_i) begin
            start_r <= !busy_w && !done_w;
            done_o <= done_w;

            if (done_w) begin
                layer_idx_r <= layer_idx_r + LAYER_IDX_W'(1);
                case (mode_r)
                    MODE_RESIDUAL: mode_r <= MODE_PRELU;
                    MODE_PRELU:    mode_r <= MODE_REQUANT;
                    default:       mode_r <= MODE_RESIDUAL;
                endcase
            end

            gb_act_rd_data_r <= make_word(gb_act_rd_addr_w, 16'h1234);
            gb_wgt_rd_data_r <= make_word(gb_wgt_rd_addr_w, 16'h5678);

            checksum_o <= checksum_o ^
                          {31'd0, gb_ao_wr_valid_w} ^
                          gb_ao_wr_addr_w ^
                          gb_ao_wr_data_w[31:0] ^
                          {16'd0, gb_ao_wr_mask_w};

            for (int c = 0; c < COL; c++) begin
                bias_r[c] <= bias_r[c] + BIAS_W'(13 + c);
                multiplier_r[c] <= multiplier_r[c] + MULT_W'(1 + c);
                residual_multiplier_r[c] <= residual_multiplier_r[c] + MULT_W'(3);
                residual_zero_point_r[c] <= residual_zero_point_r[c] + ACC_W'(1);
            end
        end else begin
            start_r <= 1'b0;
        end
    end
endmodule
