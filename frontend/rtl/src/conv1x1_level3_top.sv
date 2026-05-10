import quantface_conv1x1_params_pkg::*;
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
    parameter bit USE_INTERNAL_QUANT_PARAMS = 1'b0,
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
    input  logic signed [BIAS_W-1:0] bias_i       [COL],
    input  logic signed [MULT_W-1:0] multiplier_i [COL],
    input  logic [SHIFT_W-1:0]       shift_i      [COL],
    input  logic signed [OUT_W-1:0]  zero_point_i [COL],
    input  logic signed [MULT_W-1:0] prelu_multiplier_i [COL],
    input  logic [SHIFT_W-1:0]       prelu_shift_i      [COL],
    input  logic signed [MULT_W-1:0] residual_multiplier_i [COL],
    input  logic [SHIFT_W-1:0]       residual_shift_i      [COL],
    input  logic signed [ACC_W-1:0]  residual_zero_point_i [COL],

    // Shared activation/output global buffer interface. A higher-level
    // scheduler/switch owns the SRAM and muxes these ports with other layers.
    output logic                     gb_act_rd_valid_o,
    output logic [GB_ADDR_W-1:0]     gb_act_rd_addr_o,
    input  logic [GB_DATA_W-1:0]     gb_act_rd_data_i,
    output logic                     gb_ao_wr_valid_o,
    output logic [GB_ADDR_W-1:0]     gb_ao_wr_addr_o,
    output logic [GB_DATA_W-1:0]     gb_ao_wr_data_o,
    output logic [AO_MASK_W-1:0]     gb_ao_wr_mask_o,

    // Shared weight global buffer read interface.
    output logic                     gb_wgt_rd_valid_o,
    output logic [GB_ADDR_W-1:0]     gb_wgt_rd_addr_o,
    input  logic [GB_DATA_W-1:0]     gb_wgt_rd_data_i
);
    typedef enum logic [3:0] {
        IDLE,
        CONFIG_TILE,
        PRELOAD_START,
        PRELOAD_WAIT,
        COMPUTE_START,
        COMPUTE_WAIT,
        RESIDUAL_READ,
        RESIDUAL_CAPTURE,
        WRITEBACK_WAIT,
        DONE
    } state_t;

    state_t state_r, state_w;
    logic [DIM_W-1:0] tile_r_r, tile_r_w;
    logic [DIM_W-1:0] tile_c_r, tile_c_w;
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
    logic last_tile_r;
    logic [GB_ADDR_W-1:0] residual_addr_r, residual_addr_w;

    logic [GB_DATA_W-1:0] ao_rd_data;

    logic wgt_rd_en;
    logic [GB_DATA_W-1:0] wgt_rd_data;

    logic preload_start;
    logic preload_busy;
    logic preload_done;
    logic compute_start;
    logic compute_done;
    logic wb_capture_en;
    logic wb_done;

    logic [DIM_W-1:0] row_base_w;
    logic [DIM_W-1:0] col_base_w;
    logic ao_preload_rd_en;
    logic [GB_ADDR_W-1:0] ao_preload_addr;
    logic [GB_ADDR_W-1:0] wgt_preload_addr;
    logic [GB_ADDR_W-1:0] wb_addr;
    logic [GB_DATA_W-1:0] wb_data;
    logic [GB_DATA_W-1:0] wb_wr_data;
    logic wb_wr_en_internal;
    logic [WB_ADDR_W-1:0] wb_rd_addr;
    logic residual_rd_en;
    logic [GB_ADDR_W-1:0] residual_rd_addr;
    logic [WB_ADDR_W:0] residual_row_r, residual_row_w;
    logic residual_pending_r, residual_pending_w;
    logic [WB_ADDR_W-1:0] residual_pending_row_r, residual_pending_row_w;

    logic                     preload_wr_en   [BUF_NUM];
    logic [BANK_ADDR_W-1:0]   preload_wr_bank [BUF_NUM];
    logic [K_ADDR_W-1:0]      preload_wr_idx  [BUF_NUM];
    logic signed [DATA_W-1:0] preload_wr_data [BUF_NUM];

    logic                    mac_valid [ROW][COL];
    logic signed [ACC_W-1:0] mac_data  [ROW][COL];
    logic                    post_valid [ROW][COL];
    logic signed [OUT_W-1:0] post_data [ROW][COL];
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

    logic [GB_ADDR_W-1:0] n_tiles_w;
    logic [GB_ADDR_W-1:0] m_tiles_w;

    assign busy_o = (state_r != IDLE);
    assign n_tiles_w = (GB_ADDR_W'(n_size_i) + GB_ADDR_W'(COL - 1)) / GB_ADDR_W'(COL);
    assign m_tiles_w = (GB_ADDR_W'(m_size_i) + GB_ADDR_W'(ROW - 1)) / GB_ADDR_W'(ROW);
    assign row_base_w = tile_r_r * DIM_W'(ROW);
    assign col_base_w = tile_c_r * DIM_W'(COL);

    always_comb begin
        residual_data_w = residual_data;
        for (int r = 0; r < ROW; r++) begin
            for (int c = 0; c < COL; c++) begin
                if (state_r == COMPUTE_WAIT) begin
                    residual_data_w[r][c] = '0;
                end
            end
        end
        if (residual_pending_r) begin
            for (int c = 0; c < COL; c++) begin
                residual_data_w[residual_pending_row_r][c] =
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

    assign gb_ao_wr_valid_o = wb_wr_en_internal;
    assign gb_ao_wr_addr_o  = GB_ADDR_W'(wb_addr);
    assign gb_ao_wr_data_o  = wb_wr_data;
    assign gb_ao_wr_mask_o  = {AO_MASK_W{1'b1}};

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
        .row_base_i(row_base_r),
        .col_base_i(col_base_r),
        .m_size_i(m_size_r),
        .n_size_i(n_size_r),
        .valid_i(mac_valid),
        .acc_i(mac_data),
        .mode_i(mode_r),
        .bias_i(post_bias),
        .multiplier_i(post_multiplier),
        .shift_i(post_shift),
        .zero_point_i(post_zero_point),
        .prelu_multiplier_i(post_prelu_multiplier),
        .prelu_shift_i(post_prelu_shift),
        .residual_i(residual_data),
        .residual_multiplier_i(post_residual_multiplier),
        .residual_shift_i(post_residual_shift),
        .residual_zero_point_i(post_residual_zero_point),
        .valid_o(post_valid),
        .data_o(post_data)
    );

    wb_buffer #(
        .ROW(ROW),
        .COL(COL),
        .DATA_IN_W(OUT_W),
        .DATA_OUT_W(GB_DATA_W)
    ) u_wb_buffer (
        .aclk(clk),
        .aresetn(rst_n),
        .wr_en_i(wb_capture_en),
        .data_i(post_data),
        .rd_addr_i(wb_rd_addr),
        .data_o(wb_data)
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
        .n_size_i(n_size_r),
        .m_size_i(m_size_r),
        .out_base_addr_i(out_base_addr_r),
        .tile_process_done(wb_capture_en),
        .data_i(wb_data),
        .rd_addr_o(wb_rd_addr),
        .ao_addr_o(wb_addr),
        .ao_wr_en_o(wb_wr_en_internal),
        .ao_data_o(wb_wr_data),
        .busy_o(),
        .done_o(wb_done)
    );

    always_comb begin
        state_w = state_r;
        tile_r_w = tile_r_r;
        tile_c_w = tile_c_r;
        residual_row_w = residual_row_r;
        residual_addr_w = residual_addr_r;
        residual_pending_w = residual_pending_r;
        residual_pending_row_w = residual_pending_row_r;
        preload_start = 1'b0;
        compute_start = 1'b0;
        wb_capture_en = 1'b0;
        residual_rd_en = 1'b0;
        residual_rd_addr = '0;
        done_o = 1'b0;

        case (state_r)
            IDLE: begin
                tile_r_w = '0;
                tile_c_w = '0;
                if (start_i && run_en_i) begin
                    state_w = CONFIG_TILE;
                end
            end

            // Register all values that are constant for the current tile. This
            // keeps preload/writeback/postprocess from seeing the layer ROM and
            // tile-base arithmetic in their active-cycle timing paths.
            CONFIG_TILE: begin
                state_w = PRELOAD_START;
                residual_addr_w = residual_base_addr_r +
                                  (GB_ADDR_W'(row_base_w) * n_tiles_r) +
                                  GB_ADDR_W'(tile_c_r);
                residual_pending_w = 1'b0;
                residual_pending_row_w = '0;
                residual_row_w = '0;
                if (!run_en_i) begin
                    state_w = CONFIG_TILE;
                end
            end

            PRELOAD_START: begin
                preload_start = run_en_i;
                if (run_en_i) begin
                    state_w = PRELOAD_WAIT;
                end
            end

            PRELOAD_WAIT: begin
                if (preload_done) begin
                    state_w = COMPUTE_START;
                end
            end

            COMPUTE_START: begin
                compute_start = run_en_i;
                if (run_en_i) begin
                    state_w = COMPUTE_WAIT;
                end
            end

            COMPUTE_WAIT: begin
                if (compute_done) begin
                    if (residual_en_r && (mode_r == MODE_RESIDUAL)) begin
                        residual_row_w = '0;
                        residual_pending_w = 1'b0;
                        residual_pending_row_w = '0;
                        state_w = RESIDUAL_READ;
                    end else begin
                        wb_capture_en = 1'b1;
                        state_w = WRITEBACK_WAIT;
                    end
                end
            end

            RESIDUAL_READ: begin
                if (residual_row_r < WB_ADDR_W'(ROW)) begin
                    residual_rd_en = run_en_i &&
                                     ((row_base_r + DIM_W'(residual_row_r)) < m_size_r);
                    residual_rd_addr = residual_addr_r;
                    residual_pending_w = residual_rd_en;
                    residual_pending_row_w = residual_row_r[WB_ADDR_W-1:0];
                    residual_row_w = residual_row_r + WB_ADDR_W'(1);
                    residual_addr_w = residual_addr_r + n_tiles_r;
                end else begin
                    residual_pending_w = 1'b0;
                    state_w = residual_pending_r ? RESIDUAL_CAPTURE : WRITEBACK_WAIT;
                    wb_capture_en = !residual_pending_r;
                end
            end

            RESIDUAL_CAPTURE: begin
                residual_pending_w = 1'b0;
                wb_capture_en = 1'b1;
                state_w = WRITEBACK_WAIT;
            end

            WRITEBACK_WAIT: begin
                if (state_r == WRITEBACK_WAIT && wb_done) begin
                    if (last_tile_r) begin
                        state_w = DONE;
                    end else if (tile_r_r + DIM_W'(1) < DIM_W'(m_tiles_r)) begin
                        tile_r_w = tile_r_r + DIM_W'(1);
                        state_w = CONFIG_TILE;
                    end else begin
                        tile_r_w = '0;
                        tile_c_w = tile_c_r + DIM_W'(1);
                        state_w = CONFIG_TILE;
                    end
                end
            end

            DONE: begin
                done_o = 1'b1;
                if (run_en_i) begin
                    state_w = IDLE;
                end
            end

            default: begin
                state_w = IDLE;
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_r <= IDLE;
            tile_r_r <= '0;
            tile_c_r <= '0;
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
            last_tile_r <= 1'b0;
            residual_addr_r <= '0;
            residual_row_r <= '0;
            residual_pending_r <= 1'b0;
            residual_pending_row_r <= '0;
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
            state_r <= state_w;
            tile_r_r <= tile_r_w;
            tile_c_r <= tile_c_w;
            residual_addr_r <= residual_addr_w;
            residual_row_r <= residual_row_w;
            residual_pending_r <= residual_pending_w;
            residual_pending_row_r <= residual_pending_row_w;
            residual_data <= residual_data_w;

            if (state_r == IDLE && start_i && run_en_i) begin
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
            end

            if (state_r == CONFIG_TILE && run_en_i) begin
                row_base_r <= row_base_w;
                col_base_r <= col_base_w;
                last_tile_r <= (tile_r_r + DIM_W'(1) >= DIM_W'(m_tiles_r)) &&
                               (tile_c_r + DIM_W'(1) >= DIM_W'(n_tiles_r));

                for (int c = 0; c < COL; c++) begin
                    if (USE_INTERNAL_QUANT_PARAMS) begin
                        post_bias[c] <= BIAS_W'(qf_bias(int'(layer_idx_r), int'(col_base_w) + c));
                        post_multiplier[c] <= qf_multiplier(int'(layer_idx_r), int'(col_base_w) + c);
                        post_shift[c] <= qf_shift(int'(layer_idx_r), int'(col_base_w) + c);
                        post_zero_point[c] <= qf_zero_point(int'(layer_idx_r), int'(col_base_w) + c);
                        post_prelu_multiplier[c] <= qf_prelu_multiplier(int'(layer_idx_r), int'(col_base_w) + c);
                        post_prelu_shift[c] <= qf_prelu_shift(int'(layer_idx_r), int'(col_base_w) + c);
                        post_residual_multiplier[c] <= qf_residual_multiplier(int'(layer_idx_r), int'(col_base_w) + c);
                        post_residual_shift[c] <= qf_residual_shift(int'(layer_idx_r), int'(col_base_w) + c);
                        post_residual_zero_point[c] <= qf_residual_zero_point(int'(layer_idx_r), int'(col_base_w) + c);
                    end else begin
                        post_bias[c] <= bias_i[c];
                        post_multiplier[c] <= multiplier_i[c];
                        post_shift[c] <= shift_i[c];
                        post_zero_point[c] <= zero_point_i[c];
                        post_prelu_multiplier[c] <= prelu_multiplier_i[c];
                        post_prelu_shift[c] <= prelu_shift_i[c];
                        post_residual_multiplier[c] <= residual_multiplier_i[c];
                        post_residual_shift[c] <= residual_shift_i[c];
                        post_residual_zero_point[c] <= residual_zero_point_i[c];
                    end
                end
            end
        end
    end
endmodule
