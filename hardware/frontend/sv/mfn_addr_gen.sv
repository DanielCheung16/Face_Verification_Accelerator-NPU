// ==============================================================================
// Module: mfn_addr_gen
// Description: Address generator with HWC layout and ping-pong support.
// ==============================================================================

module mfn_addr_gen #(
    parameter int AWIDTH = 32,
    parameter int M_ADDR_WIDTH = 20
)(
    input  logic                    clk,
    input  logic                    rst_n,
    
    input  logic                    reset_ptr,
    input  logic                    inc_write,
    input  logic [1:0]              rd_buf,
    input  logic [1:0]              wr_buf,
    input  logic                    read_res,
    
    // Coordinates from Controller
    input  logic signed [8:0]       x_in,
    input  logic signed [8:0]       y_in,
    input  logic [9:0]              c_in,
    
    // Layer Params
    input  logic [6:0]              width_in,
    input  logic [6:0]              height_in,
    input  logic [9:0]              in_ch_in,
    input  logic [9:0]              out_ch_in,
    
    output logic [M_ADDR_WIDTH-1:0] sram_rd_addr,
    output logic [M_ADDR_WIDTH-1:0] sram_wr_addr,
    output logic                    is_pad
);

    logic [M_ADDR_WIDTH-1:0] wr_ptr_reg;
    logic [M_ADDR_WIDTH-1:0]       calc_rd_addr;
    logic                    is_pad_comb;
    logic                    is_pad_reg;

    // Read/Write base addresses
    logic [M_ADDR_WIDTH-1:0] rd_base, wr_base;
    logic [1:0] res_buf;
    logic [1:0] active_rd_buf;
    
    assign res_buf = 2'd3 - rd_buf - wr_buf;
    assign active_rd_buf = read_res ? res_buf : rd_buf;

    always_comb begin
        case(active_rd_buf)
            2'd0: rd_base = 20'h00000;
            2'd1: rd_base = 20'h54000;
            2'd2: rd_base = 20'hA8000;
            default: rd_base = 20'h00000;
        endcase
        case(wr_buf)
            2'd0: wr_base = 20'h00000;
            2'd1: wr_base = 20'h54000;
            2'd2: wr_base = 20'hA8000;
            default: wr_base = 20'h00000;
        endcase
    end

    // 1. Padding Check
    always_comb begin
        if (x_in < 0 || x_in >= $signed({1'b0, width_in}) || 
            y_in < 0 || y_in >= $signed({1'b0, height_in}) ||
            {1'b0, c_in} >= {1'b0, in_ch_in}) begin
            is_pad_comb = 1'b1;
        end else begin
            is_pad_comb = 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) is_pad_reg <= 1'b0;
        else        is_pad_reg <= is_pad_comb;
    end

    assign is_pad = is_pad_reg;

    // 2. Read Address (HWC Layout): Addr = rd_base + (y * W + x) * InCh + c
    always_comb begin
        automatic logic signed [M_ADDR_WIDTH-1:0] row_offset;
        automatic logic signed [M_ADDR_WIDTH-1:0] pixel_offset;
        
        row_offset   = y_in * $signed({1'b0, width_in});
        pixel_offset = row_offset + x_in;
        // Use out_ch_in for residual buffer, in_ch_in for normal read
        if (read_res)
            calc_rd_addr = M_ADDR_WIDTH'(pixel_offset * $signed({1'b0, out_ch_in}) + $signed({1'b0, c_in}));
        else
            calc_rd_addr = M_ADDR_WIDTH'(pixel_offset * $signed({1'b0, in_ch_in}) + $signed({1'b0, c_in}));
    end

    assign sram_rd_addr = rd_base + calc_rd_addr[M_ADDR_WIDTH-1:0];

    // 3. Write Address (Sequential with ping-pong base)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr_reg <= '0;
        end else if (reset_ptr) begin
            wr_ptr_reg <= '0;
        end else if (inc_write) begin
            wr_ptr_reg <= wr_ptr_reg + 1'b1;
        end
    end

    assign sram_wr_addr = wr_base + wr_ptr_reg;

endmodule
