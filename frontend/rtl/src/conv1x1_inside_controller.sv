import layer_defs_pkg::*;

module conv1x1_inside_controller #(
    parameter int ROW = 14,
    parameter int COL = 16,
    parameter int DIM_W = 16,
    parameter int GB_ADDR_W = 32,
    parameter int WB_ADDR_W = (ROW <= 1) ? 1 : $clog2(ROW)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic run_en_i,

    input  logic start_i,
    output logic busy_o,
    output logic done_o,
    output logic load_layer_cfg_o,
    output logic config_tile_o,

    input  logic preload_done_i,
    input  logic compute_done_i,
    input  logic post_tile_valid_i,
    input  logic wb_done_i,

    input  logic residual_en_i,
    input  logic [1:0] mode_i,
    input  logic [DIM_W-1:0] row_base_i,
    input  logic [DIM_W-1:0] m_size_i,
    input  logic [GB_ADDR_W-1:0] n_tiles_i,
    input  logic [GB_ADDR_W-1:0] m_tiles_i,
    input  logic [GB_ADDR_W-1:0] residual_base_addr_i,

    output logic [DIM_W-1:0] tile_r_o,
    output logic [DIM_W-1:0] tile_c_o,

    output logic preload_start_o,
    output logic compute_start_o,
    output logic post_start_o,
    output logic wb_capture_en_o,

    output logic residual_clear_o,
    output logic residual_rd_en_o,
    output logic [GB_ADDR_W-1:0] residual_rd_addr_o,
    output logic residual_capture_en_o,
    output logic [WB_ADDR_W-1:0] residual_capture_row_o
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
        POSTPROCESS_START,
        POSTPROCESS_WAIT,
        WRITEBACK_WAIT,
        DONE
    } state_t;

    state_t state_r, state_w;
    logic [DIM_W-1:0] tile_r_r, tile_r_w;
    logic [DIM_W-1:0] tile_c_r, tile_c_w;
    logic [GB_ADDR_W-1:0] residual_addr_r, residual_addr_w;
    logic [WB_ADDR_W:0] residual_row_r, residual_row_w;
    logic residual_pending_r, residual_pending_w;
    logic [WB_ADDR_W-1:0] residual_pending_row_r, residual_pending_row_w;

    assign busy_o = (state_r != IDLE);
    assign tile_r_o = tile_r_r;
    assign tile_c_o = tile_c_r;
    assign residual_capture_en_o = residual_pending_r;
    assign residual_capture_row_o = residual_pending_row_r;

    always_comb begin
        state_w = state_r;
        tile_r_w = tile_r_r;
        tile_c_w = tile_c_r;
        residual_addr_w = residual_addr_r;
        residual_row_w = residual_row_r;
        residual_pending_w = residual_pending_r;
        residual_pending_row_w = residual_pending_row_r;

        load_layer_cfg_o = 1'b0;
        config_tile_o = 1'b0;
        preload_start_o = 1'b0;
        compute_start_o = 1'b0;
        post_start_o = 1'b0;
        wb_capture_en_o = 1'b0;
        residual_clear_o = 1'b0;
        residual_rd_en_o = 1'b0;
        residual_rd_addr_o = '0;
        done_o = 1'b0;

        case (state_r)
            IDLE: begin
                tile_r_w = '0;
                tile_c_w = '0;
                if (start_i && run_en_i) begin
                    load_layer_cfg_o = 1'b1;
                    state_w = CONFIG_TILE;
                end
            end

            // Compute tile-local control constants once before the active datapath phases.
            CONFIG_TILE: begin
                residual_addr_w = residual_base_addr_i +
                                  (GB_ADDR_W'(row_base_i) * n_tiles_i) +
                                  GB_ADDR_W'(tile_c_r);
                residual_pending_w = 1'b0;
                residual_pending_row_w = '0;
                residual_row_w = '0;
                config_tile_o = run_en_i;
                if (run_en_i) begin
                    state_w = PRELOAD_START;
                end
            end

            PRELOAD_START: begin
                preload_start_o = run_en_i;
                if (run_en_i) begin
                    state_w = PRELOAD_WAIT;
                end
            end

            PRELOAD_WAIT: begin
                if (preload_done_i) begin
                    state_w = COMPUTE_START;
                end
            end

            COMPUTE_START: begin
                compute_start_o = run_en_i;
                if (run_en_i) begin
                    state_w = COMPUTE_WAIT;
                end
            end

            COMPUTE_WAIT: begin
                residual_clear_o = 1'b1;
                if (compute_done_i) begin
                    if (residual_en_i && (mode_i == MODE_RESIDUAL)) begin
                        residual_row_w = '0;
                        residual_pending_w = 1'b0;
                        residual_pending_row_w = '0;
                        state_w = RESIDUAL_READ;
                    end else begin
                        state_w = POSTPROCESS_START;
                    end
                end
            end

            RESIDUAL_READ: begin
                if (residual_row_r < WB_ADDR_W'(ROW)) begin
                    residual_rd_en_o = run_en_i &&
                                       ((row_base_i + DIM_W'(residual_row_r)) < m_size_i);
                    residual_rd_addr_o = residual_addr_r;
                    residual_pending_w = residual_rd_en_o;
                    residual_pending_row_w = residual_row_r[WB_ADDR_W-1:0];
                    residual_row_w = residual_row_r + WB_ADDR_W'(1);
                    residual_addr_w = residual_addr_r + n_tiles_i;
                end else begin
                    residual_pending_w = 1'b0;
                    state_w = residual_pending_r ? RESIDUAL_CAPTURE : POSTPROCESS_START;
                end
            end

            RESIDUAL_CAPTURE: begin
                residual_pending_w = 1'b0;
                state_w = POSTPROCESS_START;
            end

            POSTPROCESS_START: begin
                post_start_o = run_en_i;
                if (run_en_i) begin
                    state_w = POSTPROCESS_WAIT;
                end
            end

            POSTPROCESS_WAIT: begin
                if (post_tile_valid_i) begin
                    wb_capture_en_o = 1'b1;
                    state_w = WRITEBACK_WAIT;
                end
            end

            WRITEBACK_WAIT: begin
                if (wb_done_i) begin
                    if ((tile_r_r + DIM_W'(1) >= DIM_W'(m_tiles_i)) &&
                        (tile_c_r + DIM_W'(1) >= DIM_W'(n_tiles_i))) begin
                        state_w = DONE;
                    end else if (tile_r_r + DIM_W'(1) < DIM_W'(m_tiles_i)) begin
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
            residual_addr_r <= '0;
            residual_row_r <= '0;
            residual_pending_r <= 1'b0;
            residual_pending_row_r <= '0;
        end else begin
            state_r <= state_w;
            tile_r_r <= tile_r_w;
            tile_c_r <= tile_c_w;
            residual_addr_r <= residual_addr_w;
            residual_row_r <= residual_row_w;
            residual_pending_r <= residual_pending_w;
            residual_pending_row_r <= residual_pending_row_w;
        end
    end
endmodule
