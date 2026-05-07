module wr_controller #(
    parameter int ROW = 14,
    parameter int COL = 16,
    parameter int DATA_OUT_W = 128,
    parameter int DIM_W = 16,
    // 1 MB activation/output buffer with 128-bit words:
    // 1 MB / 16 B = 64 K words, so GB_ADDR_W=16 addresses the whole buffer.
    // The MSB selects the output half when asserted.
    parameter int GB_ADDR_W = 16,

    localparam int ADDR_W = (ROW <= 1) ? 1 : $clog2(ROW)
) (
    input  logic                         aclk,
    input  logic                         aresetn,

    // Output matrix dimensions. n_size_i is packed in groups of COL int8s.
    input  logic [DIM_W-1:0]             n_size_i,
    input  logic [DIM_W-1:0]             m_size_i,

    // Face to wb_buffer.
    input  logic                         tile_process_done,
    input  logic signed [DATA_OUT_W-1:0] data_i,
    output logic [ADDR_W-1:0]            rd_addr_o,

    // Face to global activation/output buffer.
    output logic [GB_ADDR_W-1:0]         ao_addr_o,
    output logic                         ao_wr_en_o,
    output logic signed [DATA_OUT_W-1:0] ao_data_o,

    output logic                         busy_o,
    output logic                         done_o
);
    localparam int COUNT_W = (ROW <= 1) ? 1 : $clog2(ROW + 1);

    typedef enum logic [1:0] {IDLE, PRIME, WRITE} state_t;

    state_t state_r, state_w;
    logic [COUNT_W-1:0] row_idx_r, row_idx_w;
    logic [DIM_W-1:0] tile_r_r, tile_r_w;
    logic [DIM_W-1:0] tile_c_r, tile_c_w;

    logic [GB_ADDR_W-1:0] n_tiles_w;
    logic [GB_ADDR_W-1:0] m_tiles_w;
    logic [GB_ADDR_W-1:0] global_row_w;
    logic [GB_ADDR_W-1:0] lower_addr_w;
    logic                 row_in_range_w;
    logic [COUNT_W-1:0]   next_row_idx_w;

    logic [GB_ADDR_W-1:0] ao_addr_w;
    logic                 ao_wr_en_w;
    logic signed [DATA_OUT_W-1:0] ao_data_w;
    logic                         done_w;

    // Pseudo-code mapping:
    //   nt = ceil(n_size_i / COL)
    //   mt = ceil(m_size_i / ROW)
    //   tile_r_r = current M tile index
    //   tile_c_r = current N tile index
    //   r        = row_idx_r, the row read from wb_buffer inside one tile
    //
    // Tile walk order for weight reuse:
    //   for tile_c in N tiles:
    //     keep the weight tile fixed
    //     for tile_r in M tiles:
    //       write this output tile
    //
    // One wb_buffer row is COL int8 values. For the normal COL=16 case,
    // this is exactly 16 * 8 = 128 bits, so one global-buffer word stores
    // one output row and one output-channel tile.
    assign n_tiles_w = (GB_ADDR_W'(n_size_i) + GB_ADDR_W'(COL - 1)) / GB_ADDR_W'(COL);
    assign m_tiles_w = (GB_ADDR_W'(m_size_i) + GB_ADDR_W'(ROW - 1)) / GB_ADDR_W'(ROW);

    // global_row = tile_r * ROW + r
    assign global_row_w = (GB_ADDR_W'(tile_r_r) * GB_ADDR_W'(ROW)) + GB_ADDR_W'(row_idx_r);

    // Row-major packed output address:
    //   ao_addr = output_half_base + global_row * nt + tile_c
    //
    // This is the pseudo-code form:
    //   ao_addr_o = tile_c + r*nt + tile_r*(ROW*nt)
    //
    // Use ROW here, not COL. ROW is the number of rows covered by a tile in
    // the M direction; COL is only the number of int8 channels packed into
    // one 128-bit word.
    assign lower_addr_w = (global_row_w * n_tiles_w) + GB_ADDR_W'(tile_c_r);
    assign row_in_range_w = (global_row_w < GB_ADDR_W'(m_size_i));
    assign next_row_idx_w = row_idx_r + COUNT_W'(1);

    assign busy_o = (state_r != IDLE);

    always_comb begin
        rd_addr_o = row_idx_r[ADDR_W-1:0];
        if ((state_r == WRITE) && (row_idx_r < COUNT_W'(ROW - 1))) begin
            rd_addr_o = next_row_idx_w[ADDR_W-1:0];
        end
    end

    always_comb begin
        state_w    = state_r;
        row_idx_w  = row_idx_r;
        tile_r_w   = tile_r_r;
        tile_c_w   = tile_c_r;
        ao_addr_w  = ao_addr_o;
        ao_wr_en_w = 1'b0;
        ao_data_w  = data_i;
        done_w     = 1'b0;

        case (state_r)
            IDLE: begin
                row_idx_w = '0;
                if (tile_process_done) begin
                    state_w = PRIME;
                end
            end

            // wb_buffer registers rd_addr_i, so one extra cycle is needed
            // before data_i contains row 0 of the captured tile.
            PRIME: begin
                row_idx_w = '0;
                state_w   = WRITE;
            end

            WRITE: begin
                ao_addr_w  = {1'b1, lower_addr_w[GB_ADDR_W-2:0]};
                ao_wr_en_w = row_in_range_w;
                ao_data_w  = data_i;

                if (row_idx_r == COUNT_W'(ROW - 1)) begin
                    row_idx_w = '0;
                    done_w    = 1'b1;
                    state_w   = IDLE;

                    // M tile is the fast-moving loop. This lets the scheduler
                    // keep one weight tile while walking over the image rows.
                    if (tile_r_r + DIM_W'(1) < DIM_W'(m_tiles_w)) begin
                        tile_r_w = tile_r_r + DIM_W'(1);
                    end else begin
                        tile_r_w = '0;
                        if (tile_c_r + DIM_W'(1) < DIM_W'(n_tiles_w)) begin
                            tile_c_w = tile_c_r + DIM_W'(1);
                        end else begin
                            tile_r_w = '0;
                            tile_c_w = '0;
                        end
                    end
                end else begin
                    row_idx_w = row_idx_r + COUNT_W'(1);
                end
            end

            default: begin
                state_w = IDLE;
            end
        endcase
    end

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state_r    <= IDLE;
            row_idx_r  <= '0;
            tile_r_r   <= '0;
            tile_c_r   <= '0;
            ao_addr_o  <= '0;
            ao_wr_en_o <= 1'b0;
            ao_data_o  <= '0;
            done_o     <= 1'b0;
        end else begin
            state_r    <= state_w;
            row_idx_r  <= row_idx_w;
            tile_r_r   <= tile_r_w;
            tile_c_r   <= tile_c_w;
            ao_addr_o  <= ao_addr_w;
            ao_wr_en_o <= ao_wr_en_w;
            ao_data_o  <= ao_data_w;
            done_o     <= done_w;
        end
    end

endmodule
