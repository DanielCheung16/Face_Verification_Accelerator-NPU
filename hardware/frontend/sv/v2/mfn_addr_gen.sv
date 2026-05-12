// ==============================================================================
// Module: mfn_addr_gen (v2)
// v2 adds wide_mode: when asserted, Stage2 outputs 9 simultaneous read
// addresses for the 3×3 neighbourhood of the center pixel captured in Stage1.
// Original single-pixel path is unchanged.
//
// Timing (wide mode):
//   Cycle 0 : Controller presents center (x_in, y_in); wide_mode=1
//   Cycle 1 : Stage1 FFs capture center + W/H/ch; Stage2 comb → 9 addrs valid
//   Cycle 2 : SRAM (1-cycle read) → pixel_in_wide[0:8] valid
//             Controller asserts wide_load_en → window loads at rising edge
// ==============================================================================

module mfn_addr_gen #(
    parameter int AWIDTH       = 32,
    parameter int M_ADDR_WIDTH = 20
)(
    input  logic                     clk,
    input  logic                     rst_n,

    input  logic                     reset_ptr,
    input  logic                     inc_write,
    input  logic [1:0]               rd_buf,
    input  logic [1:0]               wr_buf,
    input  logic                     read_res,

    // Coordinates from Controller
    input  logic signed [8:0]        x_in,
    input  logic signed [8:0]        y_in,
    input  logic [9:0]               c_in,

    // Layer Params
    input  logic [6:0]               width_in,
    input  logic [6:0]               height_in,
    input  logic [9:0]               in_ch_in,
    input  logic [9:0]               out_ch_in,

    // v2: wide mode enable
    input  logic                     wide_mode,

    // Existing single-pixel outputs
    output logic [M_ADDR_WIDTH-1:0]  sram_rd_addr,
    output logic [M_ADDR_WIDTH-1:0]  sram_wr_addr,
    output logic                     is_pad,

    // v2: 9-pixel wide outputs (valid when wide_mode_s1=1)
    output logic [M_ADDR_WIDTH-1:0]  sram_rd_addr_wide [0:8],
    output logic                     is_pad_wide [0:8]
);

    // ── Base address selection (ping-pong) ────────────────────────────────────
    logic [M_ADDR_WIDTH-1:0] rd_base, wr_base;
    logic [1:0] res_buf, active_rd_buf;

    assign res_buf       = 2'd3 - rd_buf - wr_buf;
    assign active_rd_buf = read_res ? res_buf : rd_buf;

    always_comb begin
        case (active_rd_buf)
            2'd0: rd_base = 20'h00000;
            2'd1: rd_base = 20'h54000;
            2'd2: rd_base = 20'hA8000;
            default: rd_base = 20'h00000;
        endcase
        case (wr_buf)
            2'd0: wr_base = 20'h00000;
            2'd1: wr_base = 20'h54000;
            2'd2: wr_base = 20'hA8000;
            default: wr_base = 20'h00000;
        endcase
    end

    // ── Padding check (combinational; registered twice for 2-cycle pipeline) ──
    logic is_pad_comb, is_pad_s1, is_pad_reg;

    always_comb begin
        if (x_in < 0 || x_in >= $signed({1'b0, width_in}) ||
            y_in < 0 || y_in >= $signed({1'b0, height_in}) ||
            {1'b0, c_in} >= {1'b0, in_ch_in})
            is_pad_comb = 1'b1;
        else
            is_pad_comb = 1'b0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            is_pad_s1  <= 1'b0;
            is_pad_reg <= 1'b0;
        end else begin
            is_pad_s1  <= is_pad_comb;
            is_pad_reg <= is_pad_s1;
        end
    end
    assign is_pad = is_pad_reg;

    // ── Stage 1 (registered) ─────────────────────────────────────────────────
    logic signed [M_ADDR_WIDTH-1:0] pixel_offset_s1;
    logic [9:0]                      ch_s1;
    logic [9:0]                      c_s1;
    logic [M_ADDR_WIDTH-1:0]         rd_base_s1;
    // v2: extra Stage1 registers for wide mode
    logic signed [8:0]               x_s1, y_s1;
    logic [6:0]                      W_s1, H_s1;
    logic                            wide_mode_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_offset_s1 <= '0;
            ch_s1           <= '0;
            c_s1            <= '0;
            rd_base_s1      <= '0;
            x_s1            <= '0;
            y_s1            <= '0;
            W_s1            <= '0;
            H_s1            <= '0;
            wide_mode_s1    <= 1'b0;
        end else begin
            pixel_offset_s1 <= $signed(y_in) * $signed({1'b0, width_in}) + $signed(x_in);
            ch_s1           <= read_res ? out_ch_in : in_ch_in;
            c_s1            <= c_in;
            rd_base_s1      <= rd_base;
            x_s1            <= x_in;
            y_s1            <= y_in;
            W_s1            <= width_in;
            H_s1            <= height_in;
            wide_mode_s1    <= wide_mode;
        end
    end

    // ── Stage 2 (combinational): single-pixel path ───────────────────────────
    logic [M_ADDR_WIDTH-1:0] calc_rd_addr;

    always_comb begin
        calc_rd_addr = M_ADDR_WIDTH'($signed(pixel_offset_s1) * $signed({1'b0, ch_s1})
                                     + $signed({1'b0, c_s1}));
    end

    assign sram_rd_addr = rd_base_s1 + calc_rd_addr;

    // ── Stage 2 (combinational): wide-mode path ───────────────────────────────
    // center_addr is the same as sram_rd_addr.
    // row_step = W * in_ch  (row stride in address space)
    // col_step = in_ch      (column stride)
    // addr[i] = center + dy[i]*row_step + dx[i]*col_step
    //   (dx,dy) for i=0..8: (-1,-1)(0,-1)(1,-1)(-1,0)(0,0)(1,0)(-1,1)(0,1)(1,1)

    logic [M_ADDR_WIDTH-1:0] wide_row_step, wide_col_step, wide_center;

    assign wide_center   = sram_rd_addr;   // identical to single-pixel center (k=4 pixel)
    assign wide_col_step = M_ADDR_WIDTH'(ch_s1);
    assign wide_row_step = M_ADDR_WIDTH'({1'b0, W_s1} * {1'b0, ch_s1});

    assign sram_rd_addr_wide[0] = wide_center - wide_row_step - wide_col_step;
    assign sram_rd_addr_wide[1] = wide_center - wide_row_step;
    assign sram_rd_addr_wide[2] = wide_center - wide_row_step + wide_col_step;
    assign sram_rd_addr_wide[3] = wide_center - wide_col_step;
    assign sram_rd_addr_wide[4] = wide_center;
    assign sram_rd_addr_wide[5] = wide_center + wide_col_step;
    assign sram_rd_addr_wide[6] = wide_center + wide_row_step - wide_col_step;
    assign sram_rd_addr_wide[7] = wide_center + wide_row_step;
    assign sram_rd_addr_wide[8] = wide_center + wide_row_step + wide_col_step;

    // is_pad_wide: padding check for each 3×3 neighbour
    logic signed [8:0] px [0:8], py [0:8];
    assign px[0]=x_s1-9'sd1; assign py[0]=y_s1-9'sd1;
    assign px[1]=x_s1;        assign py[1]=y_s1-9'sd1;
    assign px[2]=x_s1+9'sd1; assign py[2]=y_s1-9'sd1;
    assign px[3]=x_s1-9'sd1; assign py[3]=y_s1;
    assign px[4]=x_s1;        assign py[4]=y_s1;
    assign px[5]=x_s1+9'sd1; assign py[5]=y_s1;
    assign px[6]=x_s1-9'sd1; assign py[6]=y_s1+9'sd1;
    assign px[7]=x_s1;        assign py[7]=y_s1+9'sd1;
    assign px[8]=x_s1+9'sd1; assign py[8]=y_s1+9'sd1;

    genvar wi;
    generate
        for (wi = 0; wi < 9; wi++) begin : PAD_WIDE
            assign is_pad_wide[wi] =
                (px[wi] < 9'sd0) || (px[wi] >= $signed({1'b0, W_s1})) ||
                (py[wi] < 9'sd0) || (py[wi] >= $signed({1'b0, H_s1}));
        end
    endgenerate

    // ── Write address (sequential, ping-pong) ─────────────────────────────────
    logic [M_ADDR_WIDTH-1:0] wr_ptr_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)       wr_ptr_reg <= '0;
        else if (reset_ptr) wr_ptr_reg <= '0;
        else if (inc_write) wr_ptr_reg <= wr_ptr_reg + 1'b1;
    end

    assign sram_wr_addr = wr_base + wr_ptr_reg;

endmodule
