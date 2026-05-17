import layer_defs_pkg::*;

// Conv1x1 postprocess consumes one full output-channel tile at a time.
// quant_param_mem only returns one channel per cycle, so this scheduler issues
// COL consecutive reads and stores the returned per-channel parameters in local
// registers. params_valid_o pulses when the whole COL-wide parameter tile is
// ready and aligned for conv1x1_output_postprocess.
module conv1x1_param_scheduler #(
    parameter int COL = 16,
    parameter int BIAS_W = 64,
    parameter int OUT_W = 8,
    parameter int MULT_W = 32,
    parameter int SHIFT_W = 6,
    parameter int PARAM_ADDR_W = 16,
    parameter int DIM_W = 16,
    parameter int ACC_W = 32,

    localparam int CNT_W = (COL <= 1) ? 1 : $clog2(COL + 1),
    localparam int IDX_W = (COL <= 1) ? 1 : $clog2(COL)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic start_i,
    output logic busy_o,
    output logic params_valid_o,

    input  logic [DIM_W-1:0]           col_base_i,
    input  postprocess_mode_t          post_mode_i,
    input  logic signed [OUT_W-1:0]    output_zero_point_i,
    input  logic [PARAM_ADDR_W-1:0]    common_param_base_i,
    input  logic [PARAM_ADDR_W-1:0]    prelu_param_base_i,
    input  logic [PARAM_ADDR_W-1:0]    residual_param_base_i,

    // Global quant_param_mem bank read ports. Each bank has one-cycle latency.
    output logic                       common_rd_en_o,
    output logic [PARAM_ADDR_W-1:0]    common_rd_addr_o,
    input  logic                       common_rd_valid_i,
    output logic                       prelu_rd_en_o,
    output logic [PARAM_ADDR_W-1:0]    prelu_rd_addr_o,
    input  logic                       prelu_rd_valid_i,
    output logic                       residual_rd_en_o,
    output logic [PARAM_ADDR_W-1:0]    residual_rd_addr_o,
    input  logic                       residual_rd_valid_i,
    input  logic signed [BIAS_W-1:0]   param_bias_i,
    input  logic signed [MULT_W-1:0]   param_requant_multiplier_i,
    input  logic [SHIFT_W-1:0]         param_requant_shift_i,
    input  logic signed [MULT_W-1:0]   param_prelu_multiplier_i,
    input  logic [SHIFT_W-1:0]         param_prelu_shift_i,
    input  logic signed [MULT_W-1:0]   param_residual_multiplier_i,
    input  logic [SHIFT_W-1:0]         param_residual_shift_i,
    input  logic signed [BIAS_W-1:0]   param_residual_zero_point_i,

    output logic signed [BIAS_W-1:0]   bias_o [COL],
    output logic signed [MULT_W-1:0]   multiplier_o [COL],
    output logic [SHIFT_W-1:0]         shift_o [COL],
    output logic signed [OUT_W-1:0]    zero_point_o [COL],
    output logic signed [MULT_W-1:0]   prelu_multiplier_o [COL],
    output logic [SHIFT_W-1:0]         prelu_shift_o [COL],
    output logic signed [MULT_W-1:0]   residual_multiplier_o [COL],
    output logic [SHIFT_W-1:0]         residual_shift_o [COL],
    output logic signed [ACC_W-1:0]    residual_zero_point_o [COL]
);
    typedef enum logic [1:0] {
        IDLE,
        LOAD,
        DONE
    } state_t;

    state_t state, state_nxt;

    logic [CNT_W-1:0] cnt, cnt_nxt;
    logic [CNT_W-1:0] cap_cnt, cap_cnt_nxt;
    logic [IDX_W-1:0] cap_idx, cap_idx_nxt;
    logic             cap_valid, cap_valid_nxt;
    logic             cap_prelu_needed, cap_prelu_needed_nxt;
    logic             cap_residual_needed, cap_residual_needed_nxt;

    logic [PARAM_ADDR_W-1:0] common_param_base_r;
    logic [PARAM_ADDR_W-1:0] prelu_param_base_r;
    logic [PARAM_ADDR_W-1:0] residual_param_base_r;
    logic [DIM_W-1:0]        col_base_r;
    postprocess_mode_t       post_mode_r;
    logic signed [OUT_W-1:0] output_zero_point_r;

    logic issue_w;
    logic capture_ready_w;
    logic prelu_needed_w;
    logic residual_needed_w;
    logic [PARAM_ADDR_W-1:0] channel_offset_w;

    assign prelu_needed_w = (post_mode_r == MODE_PRELU);
    assign residual_needed_w = (post_mode_r == MODE_RESIDUAL);
    assign issue_w = (state == LOAD) && (cnt < CNT_W'(COL));
    assign channel_offset_w = PARAM_ADDR_W'(col_base_r) + PARAM_ADDR_W'(cnt);
    assign capture_ready_w = cap_valid && common_rd_valid_i &&
                             (!cap_prelu_needed || prelu_rd_valid_i) &&
                             (!cap_residual_needed || residual_rd_valid_i);

    assign common_rd_en_o = issue_w;
    assign common_rd_addr_o = common_param_base_r + channel_offset_w;
    assign prelu_rd_en_o = issue_w && prelu_needed_w;
    assign prelu_rd_addr_o = prelu_param_base_r + channel_offset_w;
    assign residual_rd_en_o = issue_w && residual_needed_w;
    assign residual_rd_addr_o = residual_param_base_r + channel_offset_w;

    assign busy_o = (state != IDLE);

    always_comb begin
        state_nxt = state;
        cnt_nxt = cnt;
        cap_cnt_nxt = cap_cnt;
        cap_idx_nxt = cap_idx;
        cap_valid_nxt = issue_w;
        cap_prelu_needed_nxt = prelu_needed_w;
        cap_residual_needed_nxt = residual_needed_w;
        params_valid_o = 1'b0;

        case (state)
            IDLE: begin
                cnt_nxt = '0;
                cap_cnt_nxt = '0;
                cap_idx_nxt = '0;
                cap_valid_nxt = 1'b0;
                cap_prelu_needed_nxt = 1'b0;
                cap_residual_needed_nxt = 1'b0;
                if (start_i) begin
                    state_nxt = LOAD;
                end
            end

            LOAD: begin
                if (issue_w) begin
                    cnt_nxt = cnt + CNT_W'(1);
                    cap_idx_nxt = cnt[IDX_W-1:0];
                end

                if (capture_ready_w) begin
                    cap_cnt_nxt = cap_cnt + CNT_W'(1);
                end

                if ((cnt_nxt == CNT_W'(COL)) && (cap_cnt_nxt == CNT_W'(COL))) begin
                    state_nxt = DONE;
                end
            end

            DONE: begin
                params_valid_o = 1'b1;
                state_nxt = IDLE;
            end

            default: begin
                state_nxt = IDLE;
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            cnt <= '0;
            cap_cnt <= '0;
            cap_idx <= '0;
            cap_valid <= 1'b0;
            cap_prelu_needed <= 1'b0;
            cap_residual_needed <= 1'b0;
            common_param_base_r <= '0;
            prelu_param_base_r <= '0;
            residual_param_base_r <= '0;
            col_base_r <= '0;
            post_mode_r <= MODE_REQUANT;
            output_zero_point_r <= '0;
            for (int c = 0; c < COL; c++) begin
                bias_o[c] <= '0;
                multiplier_o[c] <= MULT_W'(1);
                shift_o[c] <= '0;
                zero_point_o[c] <= '0;
                prelu_multiplier_o[c] <= MULT_W'(1);
                prelu_shift_o[c] <= '0;
                residual_multiplier_o[c] <= MULT_W'(1);
                residual_shift_o[c] <= '0;
                residual_zero_point_o[c] <= '0;
            end
        end else begin
            state <= state_nxt;
            cnt <= cnt_nxt;
            cap_cnt <= cap_cnt_nxt;
            cap_idx <= cap_idx_nxt;
            cap_valid <= cap_valid_nxt;
            cap_prelu_needed <= cap_prelu_needed_nxt;
            cap_residual_needed <= cap_residual_needed_nxt;

            if (start_i) begin
                common_param_base_r <= common_param_base_i;
                prelu_param_base_r <= prelu_param_base_i;
                residual_param_base_r <= residual_param_base_i;
                col_base_r <= col_base_i;
                post_mode_r <= post_mode_i;
                output_zero_point_r <= output_zero_point_i;
                for (int c = 0; c < COL; c++) begin
                    prelu_multiplier_o[c] <= MULT_W'(1);
                    prelu_shift_o[c] <= '0;
                    residual_multiplier_o[c] <= MULT_W'(1);
                    residual_shift_o[c] <= '0;
                    residual_zero_point_o[c] <= '0;
                end
            end

            if (capture_ready_w) begin
                bias_o[cap_idx] <= param_bias_i;
                multiplier_o[cap_idx] <= param_requant_multiplier_i;
                shift_o[cap_idx] <= param_requant_shift_i;
                zero_point_o[cap_idx] <= output_zero_point_r;
                if (cap_prelu_needed) begin
                    prelu_multiplier_o[cap_idx] <= param_prelu_multiplier_i;
                    prelu_shift_o[cap_idx] <= param_prelu_shift_i;
                end
                if (cap_residual_needed) begin
                    residual_multiplier_o[cap_idx] <= param_residual_multiplier_i;
                    residual_shift_o[cap_idx] <= param_residual_shift_i;
                    residual_zero_point_o[cap_idx] <= ACC_W'(param_residual_zero_point_i);
                end
            end
        end
    end

endmodule
