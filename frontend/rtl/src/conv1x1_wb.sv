module conv1x1_wb #(
    parameter int ROW       = 14,
    parameter int COL       = 16,
    parameter int ACC_W     = 32,
    parameter int BIAS_W    = 64,
    parameter int OUT_W     = 8,
    parameter int MULT_W    = 32,
    parameter int SHIFT_W   = 6,
    parameter int DIM_W     = 16,
    parameter int GB_DATA_W = 128,
    parameter int GB_ADDR_W = 16,

    localparam int AO_MASK_W = GB_DATA_W / OUT_W,
    localparam int ROW_CNT_W = (ROW <= 1) ? 1 : $clog2(ROW + 1)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic run_en_i,

    // Tile stream from the conv1x1 compute block.
    input  logic                       valid_tile_i,
    output logic                       valid_tile_o,
    input  logic [DIM_W-1:0]           row_base_i,
    input  logic [DIM_W-1:0]           col_base_i,
    input  logic [DIM_W-1:0]           m_size_i,
    input  logic [DIM_W-1:0]           n_size_i,
    input  logic [1:0]                 mode_i,
    input  logic                       valid_i [ROW][COL],
    input  logic signed [ACC_W-1:0]    acc_i [ROW][COL],
    input  logic signed [ACC_W-1:0]    residual_i [ROW][COL],
    input  logic signed [BIAS_W-1:0]   bias_i [COL],
    input  logic signed [MULT_W-1:0]   multiplier_i [COL],
    input  logic [SHIFT_W-1:0]         shift_i [COL],
    input  logic signed [OUT_W-1:0]    zero_point_i [COL],
    input  logic signed [MULT_W-1:0]   prelu_multiplier_i [COL],
    input  logic [SHIFT_W-1:0]         prelu_shift_i [COL],
    input  logic signed [MULT_W-1:0]   residual_multiplier_i [COL],
    input  logic [SHIFT_W-1:0]         residual_shift_i [COL],
    input  logic signed [ACC_W-1:0]    residual_zero_point_i [COL],

    // The inside controller keeps the old two-phase handshake. This module
    // completes direct AO writes first, then presents valid_tile_o and turns
    // wb_capture_en_i into wb_done_o on the following clock.
    input  logic                       wb_capture_en_i,
    output logic                       wb_done_o,
    input  logic [DIM_W-1:0]           wb_m_size_i,
    input  logic [DIM_W-1:0]           wb_n_size_i,
    input  logic [GB_ADDR_W-1:0]       wb_out_base_addr_i,

    // Activation/output global buffer write port.
    output logic                       gb_ao_wr_valid_o,
    output logic [GB_ADDR_W-1:0]       gb_ao_wr_addr_o,
    output logic [GB_DATA_W-1:0]       gb_ao_wr_data_o,
    output logic [AO_MASK_W-1:0]       gb_ao_wr_mask_o
);
    typedef enum logic [1:0] {
        IDLE,
        STREAM,
        DRAIN,
        DONE_READY
    } state_t;

    state_t state, state_nxt;

    logic [ROW_CNT_W-1:0] feed_row_r, feed_row_w;
    logic [ROW_CNT_W-1:0] out_row_r, out_row_w;
    logic [ROW_CNT_W-1:0] rows_done_r, rows_done_w;

    logic [DIM_W-1:0] row_base_r, row_base_w;
    logic [DIM_W-1:0] col_base_r, col_base_w;
    logic [DIM_W-1:0] m_size_r, m_size_w;
    logic [DIM_W-1:0] n_size_r, n_size_w;
    logic [GB_ADDR_W-1:0] out_base_addr_r, out_base_addr_w;
    logic [GB_ADDR_W-1:0] n_tiles_r, n_tiles_w;
    logic [GB_ADDR_W-1:0] tile_c_r, tile_c_w;
    logic [1:0] mode_r, mode_w;

    logic pp_valid_i;
    logic pp_valid_o;
    logic pp_lane_valid_i [COL];
    logic pp_lane_valid_o [COL];
    logic signed [ACC_W-1:0] pp_acc_i [COL];
    logic signed [ACC_W-1:0] pp_residual_i [COL];
    logic signed [OUT_W-1:0] pp_data_o [COL];
    logic [GB_DATA_W-1:0] pp_packed_data_w;

    logic row_in_range_w;
    logic last_feed_row_w;
    logic last_output_row_w;
    logic write_row_w;
    logic [GB_ADDR_W-1:0] global_row_w;
    logic [GB_ADDR_W-1:0] ao_addr_w;

    assign gb_ao_wr_mask_o = {AO_MASK_W{1'b1}};
    assign valid_tile_o = (state == DONE_READY);

    assign last_feed_row_w = (feed_row_r == ROW_CNT_W'(ROW - 1));
    assign last_output_row_w = (rows_done_r == ROW_CNT_W'(ROW - 1));
    assign global_row_w = GB_ADDR_W'(row_base_r) + GB_ADDR_W'(out_row_r);
    assign row_in_range_w = global_row_w < GB_ADDR_W'(m_size_r);
    assign ao_addr_w = out_base_addr_r + (global_row_w * n_tiles_r) + tile_c_r;
    assign write_row_w = pp_valid_o && row_in_range_w;

    always_comb begin
        pp_valid_i = (state == STREAM) && run_en_i;
        for (int c = 0; c < COL; c++) begin
            pp_lane_valid_i[c] = valid_i[feed_row_r][c] &&
                                 ((row_base_r + DIM_W'(feed_row_r)) < m_size_r) &&
                                 ((col_base_r + DIM_W'(c)) < n_size_r);
            pp_acc_i[c] = acc_i[feed_row_r][c];
            pp_residual_i[c] = residual_i[feed_row_r][c];
            pp_packed_data_w[c*OUT_W +: OUT_W] = pp_data_o[c];
        end
    end

    conv1x1_output_postprocess #(
        .LANES(COL),
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .OUT_W(OUT_W),
        .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W)
    ) u_postprocess (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .valid_i(pp_valid_i),
        .lane_valid_i(pp_lane_valid_i),
        .acc_i(pp_acc_i),
        .mode_i(mode_r),
        .bias_i(bias_i),
        .multiplier_i(multiplier_i),
        .shift_i(shift_i),
        .zero_point_i(zero_point_i),
        .prelu_multiplier_i(prelu_multiplier_i),
        .prelu_shift_i(prelu_shift_i),
        .residual_i(pp_residual_i),
        .residual_multiplier_i(residual_multiplier_i),
        .residual_shift_i(residual_shift_i),
        .residual_zero_point_i(residual_zero_point_i),
        .valid_o(pp_valid_o),
        .lane_valid_o(pp_lane_valid_o),
        .data_o(pp_data_o)
    );

    always_comb begin
        state_nxt = state;
        feed_row_w = feed_row_r;
        out_row_w = out_row_r;
        rows_done_w = rows_done_r;
        row_base_w = row_base_r;
        col_base_w = col_base_r;
        m_size_w = m_size_r;
        n_size_w = n_size_r;
        out_base_addr_w = out_base_addr_r;
        n_tiles_w = n_tiles_r;
        tile_c_w = tile_c_r;
        mode_w = mode_r;

        case (state)
            IDLE: begin
                // Wait for one complete compute tile and cache the tile geometry.
                feed_row_w = '0;
                out_row_w = '0;
                rows_done_w = '0;
                if (valid_tile_i && run_en_i) begin
                    row_base_w = row_base_i;
                    col_base_w = col_base_i;
                    m_size_w = wb_m_size_i;
                    n_size_w = wb_n_size_i;
                    out_base_addr_w = wb_out_base_addr_i;
                    n_tiles_w = (GB_ADDR_W'(wb_n_size_i) + GB_ADDR_W'(COL - 1)) / GB_ADDR_W'(COL);
                    tile_c_w = GB_ADDR_W'(col_base_i) / GB_ADDR_W'(COL);
                    mode_w = mode_i;
                    state_nxt = STREAM;
                end
            end

            STREAM: begin
                // Feed one ROW entry per cycle into postprocess while earlier rows drain.
                if (run_en_i) begin
                    if (last_feed_row_w) begin
                        feed_row_w = '0;
                        state_nxt = DRAIN;
                    end else begin
                        feed_row_w = feed_row_r + ROW_CNT_W'(1);
                    end
                end

                // Count postprocessed output rows that have reached the AO write port.
                if (pp_valid_o) begin
                    rows_done_w = rows_done_r + ROW_CNT_W'(1);
                    out_row_w = out_row_r + ROW_CNT_W'(1);
                    if (last_output_row_w) begin
                        rows_done_w = '0;
                        out_row_w = '0;
                        state_nxt = DONE_READY;
                    end
                end
            end

            DRAIN: begin
                // No new rows are fed; wait for the postprocess pipeline to empty.
                if (pp_valid_o) begin
                    rows_done_w = rows_done_r + ROW_CNT_W'(1);
                    out_row_w = out_row_r + ROW_CNT_W'(1);
                    if (last_output_row_w) begin
                        rows_done_w = '0;
                        out_row_w = '0;
                        state_nxt = DONE_READY;
                    end
                end
            end

            DONE_READY: begin
                // Preserve the old wb controller handshake after direct AO writes finish.
                if (wb_capture_en_i) begin
                    state_nxt = IDLE;
                end
            end

            default: begin
                state_nxt = IDLE;
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            feed_row_r <= '0;
            out_row_r <= '0;
            rows_done_r <= '0;
            row_base_r <= '0;
            col_base_r <= '0;
            m_size_r <= '0;
            n_size_r <= '0;
            out_base_addr_r <= '0;
            n_tiles_r <= '0;
            tile_c_r <= '0;
            mode_r <= '0;
            gb_ao_wr_valid_o <= 1'b0;
            gb_ao_wr_addr_o <= '0;
            gb_ao_wr_data_o <= '0;
            wb_done_o <= 1'b0;
        end else begin
            state <= state_nxt;
            feed_row_r <= feed_row_w;
            out_row_r <= out_row_w;
            rows_done_r <= rows_done_w;
            row_base_r <= row_base_w;
            col_base_r <= col_base_w;
            m_size_r <= m_size_w;
            n_size_r <= n_size_w;
            out_base_addr_r <= out_base_addr_w;
            n_tiles_r <= n_tiles_w;
            tile_c_r <= tile_c_w;
            mode_r <= mode_w;

            gb_ao_wr_valid_o <= write_row_w;
            gb_ao_wr_addr_o <= ao_addr_w;
            gb_ao_wr_data_o <= pp_packed_data_w;
            wb_done_o <= (state == DONE_READY) && wb_capture_en_i;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (GB_DATA_W != COL * OUT_W) begin
            $fatal(1, "conv1x1_wb direct row writeback requires GB_DATA_W == COL * OUT_W");
        end
    end
`endif
endmodule
