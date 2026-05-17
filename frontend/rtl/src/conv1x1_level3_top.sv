import layer_defs_pkg::*;

module conv1x1_level3_top #(
    parameter int ROW       = 14,
    parameter int COL       = 16,
    parameter int K_MAX     = 512,
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
    parameter int AO_DEPTH  = 8192,
    parameter int WGT_DEPTH = 8192,
    parameter int AO_ADDR_W = (AO_DEPTH <= 1) ? 1 : $clog2(AO_DEPTH),
    parameter int WGT_ADDR_W = (WGT_DEPTH <= 1) ? 1 : $clog2(WGT_DEPTH),
    parameter int PARAM_ADDR_W = 16,
    parameter int LAYER_IDX_W = 4,

    localparam int GB_LANES = GB_DATA_W / DATA_W,
    localparam int AO_MASK_W = GB_DATA_W / DATA_W,
    localparam int WGT_MASK_W = GB_DATA_W / DATA_W,
    localparam int GB_ADDR_W = (AO_ADDR_W > WGT_ADDR_W) ? AO_ADDR_W : WGT_ADDR_W,
    localparam int MAX_RC = (ROW > COL) ? ROW : COL,
    localparam int BANK_ADDR_W = (MAX_RC <= 1) ? 1 : $clog2(MAX_RC),
    localparam int WB_ADDR_W = (ROW <= 1) ? 1 : $clog2(ROW)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic run_en_i,

    input  logic start_i,
    input  logic [LAYER_IDX_W-1:0] layer_idx_i,
    output logic busy_o,
    output logic done_o,

    input  logic [K_ADDR_W:0] k_size_i,
    input  logic [DIM_W-1:0]  m_size_i,
    input  logic [DIM_W-1:0]  n_size_i,
    input  logic [GB_ADDR_W-1:0] act_base_addr_i,
    input  logic [GB_ADDR_W-1:0] wgt_base_addr_i,
    input  logic [GB_ADDR_W-1:0] out_base_addr_i,
    input  logic                 residual_en_i,
    input  logic [GB_ADDR_W-1:0] residual_base_addr_i,

    input  logic [1:0] mode_i,
    input  logic signed [OUT_W-1:0] output_zero_point_i,
    input  logic [PARAM_ADDR_W-1:0] common_param_base_i,
    input  logic [PARAM_ADDR_W-1:0] prelu_param_base_i,
    input  logic [PARAM_ADDR_W-1:0] residual_param_base_i,
    input  logic signed [BIAS_W-1:0] bias_i       [COL],
    input  logic signed [MULT_W-1:0] multiplier_i [COL],
    input  logic [SHIFT_W-1:0]       shift_i      [COL],
    input  logic signed [OUT_W-1:0]  zero_point_i [COL],
    input  logic signed [MULT_W-1:0] prelu_multiplier_i [COL],
    input  logic [SHIFT_W-1:0]       prelu_shift_i      [COL],
    input  logic signed [MULT_W-1:0] residual_multiplier_i [COL],
    input  logic [SHIFT_W-1:0]       residual_shift_i      [COL],
    input  logic signed [ACC_W-1:0]  residual_zero_point_i [COL],

    // Shared postprocess/writeback interface. This conv1x1 block owns GEMM
    // tile scheduling; the postprocess datapath can be shared with other layer
    // engines outside this module.
    output logic                       post_valid_tile_o,
    input  logic                       post_valid_tile_i,
    output logic [DIM_W-1:0]           post_row_base_o,
    output logic [DIM_W-1:0]           post_col_base_o,
    output logic [DIM_W-1:0]           post_m_size_o,
    output logic [DIM_W-1:0]           post_n_size_o,
    output logic [1:0]                 post_mode_o,
    output logic                       post_valid_o [ROW][COL],
    output logic signed [ACC_W-1:0]    post_acc_o [ROW][COL],
    output logic signed [ACC_W-1:0]    post_residual_o [ROW][COL],
    output logic signed [BIAS_W-1:0]   post_bias_o [COL],
    output logic signed [MULT_W-1:0]   post_multiplier_o [COL],
    output logic [SHIFT_W-1:0]         post_shift_o [COL],
    output logic signed [OUT_W-1:0]    post_zero_point_o [COL],
    output logic signed [MULT_W-1:0]   post_prelu_multiplier_o [COL],
    output logic [SHIFT_W-1:0]         post_prelu_shift_o [COL],
    output logic signed [MULT_W-1:0]   post_residual_multiplier_o [COL],
    output logic [SHIFT_W-1:0]         post_residual_shift_o [COL],
    output logic signed [ACC_W-1:0]    post_residual_zero_point_o [COL],
    output logic                       wb_capture_en_o,
    input  logic                       wb_done_i,
    output logic [DIM_W-1:0]           wb_m_size_o,
    output logic [DIM_W-1:0]           wb_n_size_o,
    output logic [GB_ADDR_W-1:0]       wb_out_base_addr_o,

    // Shared activation/output global buffer interface. A higher-level
    // scheduler/switch owns the SRAM and muxes these ports with other layers.
    output logic                     gb_act_rd_valid_o,
    output logic [GB_ADDR_W-1:0]     gb_act_rd_addr_o,
    input  logic [GB_DATA_W-1:0]     gb_act_rd_data_i,

    // Shared weight global buffer read interface.
    output logic                     gb_wgt_rd_valid_o,
    output logic [GB_ADDR_W-1:0]     gb_wgt_rd_addr_o,
    input  logic [GB_DATA_W-1:0]     gb_wgt_rd_data_i,

    // Global quant_param_mem read interface. A new output-channel tile loads
    // COL per-channel parameters once; M tiles under the same N tile reuse
    // the local registers.
    output logic                       quant_common_rd_en_o,
    output logic [PARAM_ADDR_W-1:0]    quant_common_rd_addr_o,
    input  logic                       quant_common_rd_valid_i,
    output logic                       quant_prelu_rd_en_o,
    output logic [PARAM_ADDR_W-1:0]    quant_prelu_rd_addr_o,
    input  logic                       quant_prelu_rd_valid_i,
    output logic                       quant_residual_rd_en_o,
    output logic [PARAM_ADDR_W-1:0]    quant_residual_rd_addr_o,
    input  logic                       quant_residual_rd_valid_i,
    input  logic signed [BIAS_W-1:0]   quant_param_bias_i,
    input  logic signed [MULT_W-1:0]   quant_param_requant_multiplier_i,
    input  logic [SHIFT_W-1:0]         quant_param_requant_shift_i,
    input  logic signed [MULT_W-1:0]   quant_param_prelu_multiplier_i,
    input  logic [SHIFT_W-1:0]         quant_param_prelu_shift_i,
    input  logic signed [MULT_W-1:0]   quant_param_residual_multiplier_i,
    input  logic [SHIFT_W-1:0]         quant_param_residual_shift_i,
    input  logic signed [BIAS_W-1:0]   quant_param_residual_zero_point_i
);
    logic [DIM_W-1:0] tile_r_r;
    logic [DIM_W-1:0] tile_c_r;
    logic [LAYER_IDX_W-1:0] layer_idx_r;
    logic [K_ADDR_W:0] k_size_r;
    logic [DIM_W-1:0] m_size_r;
    logic [DIM_W-1:0] n_size_r;
    logic [GB_ADDR_W-1:0] act_base_addr_r;
    logic [GB_ADDR_W-1:0] wgt_base_addr_r;
    logic [GB_ADDR_W-1:0] out_base_addr_r;
    logic residual_en_r;
    logic [GB_ADDR_W-1:0] residual_base_addr_r;
    logic [1:0] mode_r;
    logic [GB_ADDR_W-1:0] n_tiles_r;
    logic [GB_ADDR_W-1:0] m_tiles_r;
    logic [DIM_W-1:0] row_base_r;
    logic [DIM_W-1:0] col_base_r;

    logic [GB_DATA_W-1:0] ao_rd_data;

    logic wgt_rd_en;
    logic [GB_DATA_W-1:0] wgt_rd_data;

    logic preload_start;
    logic preload_busy;
    logic preload_done;
    logic compute_start;
    logic compute_done;
    logic post_start;
    logic wb_capture_en;
    logic load_layer_cfg;
    logic config_tile;
    logic residual_clear;
    logic residual_capture_en;
    logic [WB_ADDR_W-1:0] residual_capture_row;
    logic param_load_start;
    logic param_load_needed_w;
    logic param_tile_ready_r;
    logic param_ready_w;
    logic param_scheduler_busy;
    logic param_scheduler_valid;

    logic [DIM_W-1:0] row_base_w;
    logic [DIM_W-1:0] col_base_w;
    logic ao_preload_rd_en;
    logic [GB_ADDR_W-1:0] ao_preload_addr;
    logic [GB_ADDR_W-1:0] wgt_preload_addr;
    logic residual_rd_en;
    logic [GB_ADDR_W-1:0] residual_rd_addr;

    logic                     preload_wr_en   [BUF_NUM];
    logic [BANK_ADDR_W-1:0]   preload_wr_bank [BUF_NUM];
    logic [K_ADDR_W-1:0]      preload_wr_idx  [BUF_NUM];
    logic signed [DATA_W-1:0] preload_wr_data [BUF_NUM];

    logic                    mac_valid [ROW][COL];
    logic signed [ACC_W-1:0] mac_data  [ROW][COL];
    logic                    post_input_valid [ROW][COL];
    logic signed [ACC_W-1:0] residual_data [ROW][COL];
    logic signed [ACC_W-1:0] residual_data_w [ROW][COL];
    logic signed [BIAS_W-1:0] post_bias [COL];
    logic signed [MULT_W-1:0] post_multiplier [COL];
    logic [SHIFT_W-1:0] post_shift [COL];
    logic signed [OUT_W-1:0] post_zero_point [COL];
    logic signed [MULT_W-1:0] post_prelu_multiplier [COL];
    logic [SHIFT_W-1:0] post_prelu_shift [COL];
    logic signed [MULT_W-1:0] post_residual_multiplier [COL];
    logic [SHIFT_W-1:0] post_residual_shift [COL];
    logic signed [ACC_W-1:0] post_residual_zero_point [COL];
    logic signed [BIAS_W-1:0] param_bias [COL];
    logic signed [MULT_W-1:0] param_multiplier [COL];
    logic [SHIFT_W-1:0] param_shift [COL];
    logic signed [OUT_W-1:0] param_zero_point [COL];
    logic signed [MULT_W-1:0] param_prelu_multiplier [COL];
    logic [SHIFT_W-1:0] param_prelu_shift [COL];
    logic signed [MULT_W-1:0] param_residual_multiplier [COL];
    logic [SHIFT_W-1:0] param_residual_shift [COL];
    logic signed [ACC_W-1:0] param_residual_zero_point [COL];

    logic [GB_ADDR_W-1:0] n_tiles_w;
    logic [GB_ADDR_W-1:0] m_tiles_w;

    assign n_tiles_w = (GB_ADDR_W'(n_size_i) + GB_ADDR_W'(COL - 1)) / GB_ADDR_W'(COL);
    assign m_tiles_w = (GB_ADDR_W'(m_size_i) + GB_ADDR_W'(ROW - 1)) / GB_ADDR_W'(ROW);
    assign row_base_w = tile_r_r * DIM_W'(ROW);
    assign col_base_w = tile_c_r * DIM_W'(COL);
    assign param_load_needed_w = (tile_r_r == '0);
    assign param_ready_w = param_tile_ready_r || param_scheduler_valid;

    always_comb begin
        residual_data_w = residual_data;
        for (int r = 0; r < ROW; r++) begin
            for (int c = 0; c < COL; c++) begin
                if (residual_clear) begin
                    residual_data_w[r][c] = '0;
                end
            end
        end
        if (residual_capture_en) begin
            for (int c = 0; c < COL; c++) begin
                residual_data_w[residual_capture_row][c] =
                    {{(ACC_W-DATA_W){gb_act_rd_data_i[c*DATA_W + DATA_W - 1]}},
                     gb_act_rd_data_i[c*DATA_W +: DATA_W]};
            end
        end
    end

    assign gb_act_rd_valid_o = residual_rd_en || ao_preload_rd_en;
    assign gb_act_rd_addr_o  = residual_rd_en ? residual_rd_addr : ao_preload_addr;
    assign ao_rd_data        = gb_act_rd_data_i;

    assign gb_wgt_rd_valid_o = wgt_rd_en;
    assign gb_wgt_rd_addr_o  = wgt_preload_addr;
    assign wgt_rd_data       = gb_wgt_rd_data_i;

    assign post_valid_tile_o = post_start;
    assign post_row_base_o = row_base_r;
    assign post_col_base_o = col_base_r;
    assign post_m_size_o = m_size_r;
    assign post_n_size_o = n_size_r;
    assign post_mode_o = mode_r;
    assign wb_capture_en_o = wb_capture_en;
    assign wb_m_size_o = m_size_r;
    assign wb_n_size_o = n_size_r;
    assign wb_out_base_addr_o = out_base_addr_r;

    always_comb begin
        for (int r = 0; r < ROW; r++) begin
            for (int c = 0; c < COL; c++) begin
                post_input_valid[r][c] = post_start;
                post_valid_o[r][c] = post_input_valid[r][c];
                post_acc_o[r][c] = mac_data[r][c];
                post_residual_o[r][c] = residual_data[r][c];
            end
        end

        for (int c = 0; c < COL; c++) begin
            post_bias_o[c] = post_bias[c];
            post_multiplier_o[c] = post_multiplier[c];
            post_shift_o[c] = post_shift[c];
            post_zero_point_o[c] = post_zero_point[c];
            post_prelu_multiplier_o[c] = post_prelu_multiplier[c];
            post_prelu_shift_o[c] = post_prelu_shift[c];
            post_residual_multiplier_o[c] = post_residual_multiplier[c];
            post_residual_shift_o[c] = post_residual_shift[c];
            post_residual_zero_point_o[c] = post_residual_zero_point[c];
        end
    end

    conv1x1_inside_controller #(
        .ROW(ROW),
        .COL(COL),
        .DIM_W(DIM_W),
        .GB_ADDR_W(GB_ADDR_W),
        .WB_ADDR_W(WB_ADDR_W)
    ) u_inside_controller (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .start_i(start_i),
        .busy_o(busy_o),
        .done_o(done_o),
        .load_layer_cfg_o(load_layer_cfg),
        .config_tile_o(config_tile),
        .preload_done_i(preload_done),
        .compute_done_i(compute_done),
        .param_load_needed_i(param_load_needed_w),
        .param_ready_i(param_ready_w),
        .post_tile_valid_i(post_valid_tile_i),
        .wb_done_i(wb_done_i),
        .residual_en_i(residual_en_r),
        .mode_i(mode_r),
        .row_base_i(row_base_w),
        .m_size_i(m_size_r),
        .n_tiles_i(n_tiles_r),
        .m_tiles_i(m_tiles_r),
        .residual_base_addr_i(residual_base_addr_r),
        .tile_r_o(tile_r_r),
        .tile_c_o(tile_c_r),
        .preload_start_o(preload_start),
        .compute_start_o(compute_start),
        .param_load_start_o(param_load_start),
        .post_start_o(post_start),
        .wb_capture_en_o(wb_capture_en),
        .residual_clear_o(residual_clear),
        .residual_rd_en_o(residual_rd_en),
        .residual_rd_addr_o(residual_rd_addr),
        .residual_capture_en_o(residual_capture_en),
        .residual_capture_row_o(residual_capture_row)
    );

    conv1x1_param_scheduler #(
        .COL(COL),
        .BIAS_W(BIAS_W),
        .OUT_W(OUT_W),
        .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W),
        .PARAM_ADDR_W(PARAM_ADDR_W),
        .DIM_W(DIM_W),
        .ACC_W(ACC_W)
    ) u_param_scheduler (
        .clk(clk),
        .rst_n(rst_n),
        .start_i(param_load_start),
        .busy_o(param_scheduler_busy),
        .params_valid_o(param_scheduler_valid),
        .col_base_i(col_base_w),
        .post_mode_i(postprocess_mode_t'(mode_r)),
        .output_zero_point_i(output_zero_point_i),
        .common_param_base_i(common_param_base_i),
        .prelu_param_base_i(prelu_param_base_i),
        .residual_param_base_i(residual_param_base_i),
        .common_rd_en_o(quant_common_rd_en_o),
        .common_rd_addr_o(quant_common_rd_addr_o),
        .common_rd_valid_i(quant_common_rd_valid_i),
        .prelu_rd_en_o(quant_prelu_rd_en_o),
        .prelu_rd_addr_o(quant_prelu_rd_addr_o),
        .prelu_rd_valid_i(quant_prelu_rd_valid_i),
        .residual_rd_en_o(quant_residual_rd_en_o),
        .residual_rd_addr_o(quant_residual_rd_addr_o),
        .residual_rd_valid_i(quant_residual_rd_valid_i),
        .param_bias_i(quant_param_bias_i),
        .param_requant_multiplier_i(quant_param_requant_multiplier_i),
        .param_requant_shift_i(quant_param_requant_shift_i),
        .param_prelu_multiplier_i(quant_param_prelu_multiplier_i),
        .param_prelu_shift_i(quant_param_prelu_shift_i),
        .param_residual_multiplier_i(quant_param_residual_multiplier_i),
        .param_residual_shift_i(quant_param_residual_shift_i),
        .param_residual_zero_point_i(quant_param_residual_zero_point_i),
        .bias_o(param_bias),
        .multiplier_o(param_multiplier),
        .shift_o(param_shift),
        .zero_point_o(param_zero_point),
        .prelu_multiplier_o(param_prelu_multiplier),
        .prelu_shift_o(param_prelu_shift),
        .residual_multiplier_o(param_residual_multiplier),
        .residual_shift_o(param_residual_shift),
        .residual_zero_point_o(param_residual_zero_point)
    );

    gemm_preload #(
        .ROW(ROW),
        .COL(COL),
        .K_MAX(K_MAX),
        .DATA_W(DATA_W),
        .GB_DATA_W(GB_DATA_W),
        .DIM_W(DIM_W),
        .GB_ADDR_W(GB_ADDR_W),
        .BUF_NUM(BUF_NUM),
        .K_ADDR_W(K_ADDR_W)
    ) u_preload (
        .clk(clk),
        .rst_n(rst_n),
        .start_i(preload_start),
        .run_en_i(run_en_i),
        .busy_o(preload_busy),
        .done_o(preload_done),
        .m_size_i(m_size_r),
        .k_size_i(k_size_r),
        .n_size_i(n_size_r),
        .row_base_i(row_base_r),
        .col_base_i(col_base_r),
        .act_base_addr_i(act_base_addr_r),
        .wgt_base_addr_i(wgt_base_addr_r),
        .gb_act_rd_valid_o(ao_preload_rd_en),
        .gb_act_rd_addr_o(ao_preload_addr),
        .gb_act_rd_data_i(ao_rd_data),
        .gb_wgt_rd_valid_o(wgt_rd_en),
        .gb_wgt_rd_addr_o(wgt_preload_addr),
        .gb_wgt_rd_data_i(wgt_rd_data),
        .wr_en_o(preload_wr_en),
        .wr_bank_o(preload_wr_bank),
        .wr_idx_o(preload_wr_idx),
        .wr_data_o(preload_wr_data)
    );

    array_level2_top #(
        .ROW(ROW),
        .COL(COL),
        .K_MAX(K_MAX),
        .COUNT_W(COUNT_W),
        .K_ADDR_W(K_ADDR_W),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .BUF_NUM(BUF_NUM)
    ) u_array (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .wr_en_i(preload_wr_en),
        .wr_bank_i(preload_wr_bank),
        .wr_idx_i(preload_wr_idx),
        .wr_data_i(preload_wr_data),
        .k_size_i(k_size_r),
        .start_i(compute_start),
        .done_o(compute_done),
        .valid_o(mac_valid),
        .mac_o(mac_data)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            layer_idx_r <= '0;
            k_size_r <= '0;
            m_size_r <= '0;
            n_size_r <= '0;
            act_base_addr_r <= '0;
            wgt_base_addr_r <= '0;
            out_base_addr_r <= '0;
            residual_en_r <= 1'b0;
            residual_base_addr_r <= '0;
            mode_r <= MODE_REQUANT;
            n_tiles_r <= '0;
            m_tiles_r <= '0;
            row_base_r <= '0;
            col_base_r <= '0;
            param_tile_ready_r <= 1'b0;
            for (int c = 0; c < COL; c++) begin
                post_bias[c] <= '0;
                post_multiplier[c] <= '0;
                post_shift[c] <= '0;
                post_zero_point[c] <= '0;
                post_prelu_multiplier[c] <= '0;
                post_prelu_shift[c] <= '0;
                post_residual_multiplier[c] <= '0;
                post_residual_shift[c] <= '0;
                post_residual_zero_point[c] <= '0;
            end
            for (int r = 0; r < ROW; r++) begin
                for (int c = 0; c < COL; c++) begin
                    residual_data[r][c] <= '0;
                end
            end
        end else begin
            residual_data <= residual_data_w;

            if (load_layer_cfg) begin
                k_size_r <= k_size_i;
                layer_idx_r <= layer_idx_i;
                m_size_r <= m_size_i;
                n_size_r <= n_size_i;
                act_base_addr_r <= act_base_addr_i;
                wgt_base_addr_r <= wgt_base_addr_i;
                out_base_addr_r <= out_base_addr_i;
                residual_en_r <= residual_en_i;
                residual_base_addr_r <= residual_base_addr_i;
                mode_r <= mode_i;
                n_tiles_r <= n_tiles_w;
                m_tiles_r <= m_tiles_w;
                param_tile_ready_r <= 1'b0;
            end

            if (config_tile) begin
                row_base_r <= row_base_w;
                col_base_r <= col_base_w;
                if (param_load_needed_w) begin
                    param_tile_ready_r <= 1'b0;
                end

            end

            if (param_scheduler_valid) begin
                param_tile_ready_r <= 1'b1;
                for (int c = 0; c < COL; c++) begin
                    post_bias[c] <= param_bias[c];
                    post_multiplier[c] <= param_multiplier[c];
                    post_shift[c] <= param_shift[c];
                    post_zero_point[c] <= param_zero_point[c];
                    post_prelu_multiplier[c] <= param_prelu_multiplier[c];
                    post_prelu_shift[c] <= param_prelu_shift[c];
                    post_residual_multiplier[c] <= param_residual_multiplier[c];
                    post_residual_shift[c] <= param_residual_shift[c];
                    post_residual_zero_point[c] <= param_residual_zero_point[c];
                end
            end
        end
    end
endmodule
