`include "layer_defs.svh"

// Synthesis-only timing wrapper for conv1x1_output_postprocess.
//
// Keep top-level I/O tiny, but preserve the real postprocess timing arc:
//   input stimulus regs -> conv1x1_output_postprocess -> output capture regs
//
// Use this module as the Synplify top when you want to check whether the
// postprocess arithmetic itself can synthesize and what its standalone timing
// roughly looks like.
module synth_conv1x1_postprocess_wrapper #(
    parameter int ROW = 14,
    parameter int COL = 16,
    parameter int ACC_W = 32,
    parameter int BIAS_W = 64,
    parameter int OUT_W = 8,
    parameter int MULT_W = 32,
    parameter int SHIFT_W = 6,
    parameter int DIM_W = 16
) (
    input  logic clk,
    input  logic rst_n,
    input  logic en_i,
    output logic [31:0] checksum_o
);
    logic [DIM_W-1:0] row_base_r;
    logic [DIM_W-1:0] col_base_r;
    logic [DIM_W-1:0] m_size_r;
    logic [DIM_W-1:0] n_size_r;
    postprocess_mode_t mode_r;

    logic valid_r [ROW][COL];
    logic signed [ACC_W-1:0] acc_r [ROW][COL];
    logic signed [ACC_W-1:0] residual_r [ROW][COL];

    logic signed [BIAS_W-1:0] bias_r [COL];
    logic signed [MULT_W-1:0] multiplier_r [COL];
    logic [SHIFT_W-1:0] shift_r [COL];
    logic signed [OUT_W-1:0] zero_point_r [COL];
    logic signed [MULT_W-1:0] prelu_multiplier_r [COL];
    logic [SHIFT_W-1:0] prelu_shift_r [COL];
    logic signed [MULT_W-1:0] residual_multiplier_r [COL];
    logic [SHIFT_W-1:0] residual_shift_r [COL];
    logic signed [ACC_W-1:0] residual_zero_point_r [COL];

    logic valid_tile_w;
    logic valid_w [ROW][COL];
    logic signed [OUT_W-1:0] data_w [ROW][COL];
    (* syn_preserve = 1 *) logic valid_capture_r [ROW][COL];
    (* syn_preserve = 1 *) logic signed [OUT_W-1:0] data_capture_r [ROW][COL];

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
        .run_en_i(en_i),
        .valid_tile_i(en_i),
        .row_base_i(row_base_r),
        .col_base_i(col_base_r),
        .m_size_i(m_size_r),
        .n_size_i(n_size_r),
        .valid_i(valid_r),
        .acc_i(acc_r),
        .mode_i(mode_r),
        .bias_i(bias_r),
        .multiplier_i(multiplier_r),
        .shift_i(shift_r),
        .zero_point_i(zero_point_r),
        .prelu_multiplier_i(prelu_multiplier_r),
        .prelu_shift_i(prelu_shift_r),
        .residual_i(residual_r),
        .residual_multiplier_i(residual_multiplier_r),
        .residual_shift_i(residual_shift_r),
        .residual_zero_point_i(residual_zero_point_r),
        .valid_o(valid_w),
        .valid_tile_o(valid_tile_w),
        .data_o(data_w)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_base_r <= '0;
            col_base_r <= '0;
            m_size_r <= DIM_W'(ROW);
            n_size_r <= DIM_W'(COL);
            mode_r <= MODE_REQUANT;
            checksum_o <= '0;

            for (int c = 0; c < COL; c++) begin
                bias_r[c] <= BIAS_W'(c * 17 - 73);
                multiplier_r[c] <= MULT_W'(32'sd123456 + c * 31);
                shift_r[c] <= SHIFT_W'(19);
                zero_point_r[c] <= OUT_W'(-8'sd3 + c[OUT_W-1:0]);
                prelu_multiplier_r[c] <= MULT_W'(32'sd32768 + c * 7);
                prelu_shift_r[c] <= SHIFT_W'(16);
                residual_multiplier_r[c] <= MULT_W'(32'sd65536 - c * 13);
                residual_shift_r[c] <= SHIFT_W'(16);
                residual_zero_point_r[c] <= ACC_W'(32'sd2);
            end

            for (int r = 0; r < ROW; r++) begin
                for (int c = 0; c < COL; c++) begin
                    valid_r[r][c] <= 1'b0;
                    acc_r[r][c] <= '0;
                    residual_r[r][c] <= '0;
                    valid_capture_r[r][c] <= 1'b0;
                    data_capture_r[r][c] <= '0;
                end
            end
        end else if (en_i) begin
            row_base_r <= row_base_r + DIM_W'(1);
            col_base_r <= col_base_r + DIM_W'(1);
            m_size_r <= DIM_W'(ROW * 2);
            n_size_r <= DIM_W'(COL * 2);
            checksum_o <= checksum_o ^ {22'd0, valid_tile_w, valid_capture_r[0][0], data_capture_r[0][0]};

            case (mode_r)
                MODE_REQUANT:  mode_r <= MODE_RESIDUAL;
                MODE_RESIDUAL: mode_r <= MODE_PRELU;
                default:       mode_r <= MODE_REQUANT;
            endcase

            for (int c = 0; c < COL; c++) begin
                bias_r[c] <= bias_r[c] + BIAS_W'(101 + c);
                multiplier_r[c] <= multiplier_r[c] + MULT_W'(3 + c);
                shift_r[c] <= SHIFT_W'(19);
                zero_point_r[c] <= zero_point_r[c] + OUT_W'(1);
                prelu_multiplier_r[c] <= prelu_multiplier_r[c] + MULT_W'(1);
                prelu_shift_r[c] <= SHIFT_W'(16);
                residual_multiplier_r[c] <= residual_multiplier_r[c] + MULT_W'(5);
                residual_shift_r[c] <= SHIFT_W'(16);
                residual_zero_point_r[c] <= residual_zero_point_r[c] + ACC_W'(1);
            end

            for (int r = 0; r < ROW; r++) begin
                for (int c = 0; c < COL; c++) begin
                    valid_r[r][c] <= 1'b1;
                    acc_r[r][c] <= acc_r[r][c] + ACC_W'(r * COL + c + 1);
                    residual_r[r][c] <= residual_r[r][c] - ACC_W'(r + c + 1);
                    valid_capture_r[r][c] <= valid_w[r][c];
                    data_capture_r[r][c] <= data_w[r][c];
                end
            end
        end
    end
endmodule
