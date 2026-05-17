module spatial_inside_controller_dw #(
    parameter int ADDR_W = 16,       // Current address fields are small, but keep this aligned with window_generator.
    parameter int FILTER_CNT_W = 10, // Enough for 512 channels/bytes.
    parameter int LANES = 16
) (
    input  logic clk,
    input  logic rst_n,
    input  logic run_en_i,
    input  logic start_i,

    output logic busy_o,
    output logic done_o,

    // Current layer config. These values are captured at layer start, then
    // treated as constants until DONE. This avoids a long live config path.
    input  logic [FILTER_CNT_W-1:0] current_num_filter_i,
    input  logic [2:0] ifmap_size_code_i,
    input  logic stride_i,

    // Status from window_generator.
    input  logic load_busy_i,
    input  logic load_done_i,
    input  logic read_busy_i,
    input  logic read_done_i,

    // Output to the window generator.
    output logic              clear_o,
    output logic              swap_o,
    output logic [ADDR_W-1:0] tile_offset_o,
    output logic [ADDR_W-1:0] out_x_o,
    output logic [ADDR_W-1:0] out_y_o,
    output logic              load_start_o, // trigger spatial_ld_controller
    output logic              read_start_o  // trigger spatial_rd_controller
);
    typedef enum logic [2:0] {
        IDLE,
        CLEAR_LOCAL,
        WAIT_INIT_LOAD,
        START_READ,
        COMP,
        DONE
    } state_t;

    state_t state, state_nxt;

    logic [FILTER_CNT_W-1:0] current_num_filter_r, current_num_filter_nxt;
    logic [ADDR_W-1:0] outmap_size_r, outmap_size_nxt;
    logic [ADDR_W-1:0] ifmap_size_decoded;
    logic [ADDR_W-1:0] outmap_size_decoded;

    logic clear_nxt;
    logic swap_nxt;
    logic load_start_nxt;
    logic read_start_nxt;
    logic done_nxt;

    logic prefetch_valid_r, prefetch_valid_nxt;
    logic prefetch_done_r, prefetch_done_nxt;
    logic read_done_seen_r, read_done_seen_nxt;
    logic read_last_r, read_last_nxt;

    logic coord_clear;
    logic coord_update_en;
    logic coord_last;

    // Decoder: ifmap_size_code_i is stored as a real size because coordinate
    // update uses comparisons on x/y every output point.
    always_comb begin
        unique case (ifmap_size_code_i)
            3'd0: ifmap_size_decoded = ADDR_W'(7);
            3'd1: ifmap_size_decoded = ADDR_W'(14);
            3'd2: ifmap_size_decoded = ADDR_W'(28);
            3'd3: ifmap_size_decoded = ADDR_W'(56);
            3'd4: ifmap_size_decoded = ADDR_W'(112);
            default: ifmap_size_decoded = ADDR_W'(7);
        endcase
        outmap_size_decoded = stride_i ? (ifmap_size_decoded >> 1) : ifmap_size_decoded;
    end

    // Coordinate FSM:
    //   x/y describe the output pixel.
    //   tile_cnt is a byte offset: 0, 16, 32, ...
    // The dispatcher decides when one loaded window/filter tile is consumed;
    // the coordinate FSM only advances to the next load coordinate.
    typedef enum logic [1:0] {
        IDLE_COORD,
        ACTIVE_COORD
    } coord_state_t;

    coord_state_t coord_state, coord_state_nxt;

    logic [ADDR_W-1:0] x_cnt, x_cnt_nxt;
    logic [ADDR_W-1:0] y_cnt, y_cnt_nxt;
    logic [ADDR_W-1:0] tile_cnt, tile_cnt_nxt;

    logic tile_last;
    logic y_last;
    logic x_last;

    assign tile_last = ({1'b0, tile_cnt} + (ADDR_W+1)'(LANES)) >=
                       (ADDR_W+1)'(current_num_filter_r);
    assign y_last = (y_cnt + ADDR_W'(1)) >= outmap_size_r;
    assign x_last = (x_cnt + ADDR_W'(1)) >= outmap_size_r;
    assign coord_last = tile_last && y_last && x_last;

    assign tile_offset_o = tile_cnt;
    assign out_x_o = x_cnt;
    assign out_y_o = y_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt <= '0;
            y_cnt <= '0;
            tile_cnt <= '0;
            coord_state <= IDLE_COORD;
        end else begin
            x_cnt <= x_cnt_nxt;
            y_cnt <= y_cnt_nxt;
            tile_cnt <= tile_cnt_nxt;
            coord_state <= coord_state_nxt;
        end
    end

    always_comb begin
        x_cnt_nxt = x_cnt;
        y_cnt_nxt = y_cnt;
        tile_cnt_nxt = tile_cnt;
        coord_state_nxt = coord_state;

        if (coord_clear) begin
            x_cnt_nxt = '0;
            y_cnt_nxt = '0;
            tile_cnt_nxt = '0;
            coord_state_nxt = ACTIVE_COORD;
        end else begin
            case (coord_state)
                IDLE_COORD: begin
                    if (coord_update_en) begin
                        coord_state_nxt = ACTIVE_COORD;
                    end
                end

                ACTIVE_COORD: begin
                    if (coord_update_en) begin
                        // Traverse all channel tiles first for the same output
                        // coordinate. This reuses the activation window while
                        // the weight buffer streams forward.
                        if (!tile_last) begin
                            tile_cnt_nxt = tile_cnt + ADDR_W'(LANES);
                        end else begin
                            tile_cnt_nxt = '0;
                            if (!y_last) begin
                                y_cnt_nxt = y_cnt + ADDR_W'(1);
                            end else begin
                                y_cnt_nxt = '0;
                                if (!x_last) begin
                                    x_cnt_nxt = x_cnt + ADDR_W'(1);
                                end else begin
                                    x_cnt_nxt = '0;
                                    coord_state_nxt = IDLE_COORD;
                                end
                            end
                        end
                    end
                end

                default: begin
                    coord_state_nxt = IDLE_COORD;
                end
            endcase
        end
    end

    // Dispatcher controller:
    //   1. Clear local state.
    //   2. Load the first activation window/weight tile.
    //   3. Swap activation ping-pong, read the current tile, and prefetch the
    //      next tile into the write-side activation buffer and next weight slot.
    //
    // load_start_o/read_start_o/swap_o are registered pulses. A pulse becomes
    // visible to window_generator one cycle after this FSM chooses it, while
    // coordinate registers have already been updated. swap_o and read_start_o
    // are separated by START_READ because the ping-pong read bank updates on
    // the swap clock edge.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            current_num_filter_r <= '0;
            outmap_size_r <= '0;
            prefetch_valid_r <= 1'b0;
            prefetch_done_r <= 1'b0;
            read_done_seen_r <= 1'b0;
            read_last_r <= 1'b0;

            clear_o <= 1'b0;
            swap_o <= 1'b0;
            load_start_o <= 1'b0;
            read_start_o <= 1'b0;
            done_o <= 1'b0;
        end else begin
            state <= state_nxt;
            current_num_filter_r <= current_num_filter_nxt;
            outmap_size_r <= outmap_size_nxt;
            prefetch_valid_r <= prefetch_valid_nxt;
            prefetch_done_r <= prefetch_done_nxt;
            read_done_seen_r <= read_done_seen_nxt;
            read_last_r <= read_last_nxt;

            clear_o <= clear_nxt;
            swap_o <= swap_nxt;
            load_start_o <= load_start_nxt;
            read_start_o <= read_start_nxt;
            done_o <= done_nxt;
        end
    end

    always_comb begin
        state_nxt = state;
        current_num_filter_nxt = current_num_filter_r;
        outmap_size_nxt = outmap_size_r;
        prefetch_valid_nxt = prefetch_valid_r;
        prefetch_done_nxt = prefetch_done_r;
        read_done_seen_nxt = read_done_seen_r;
        read_last_nxt = read_last_r;

        clear_nxt = 1'b0;
        swap_nxt = 1'b0;
        load_start_nxt = 1'b0;
        read_start_nxt = 1'b0;
        done_nxt = 1'b0;

        coord_clear = 1'b0;
        coord_update_en = 1'b0;

        case (state)
            IDLE: begin
                prefetch_valid_nxt = 1'b0;
                prefetch_done_nxt = 1'b0;
                read_done_seen_nxt = 1'b0;
                read_last_nxt = 1'b0;
                if (start_i && run_en_i) begin
                    current_num_filter_nxt = current_num_filter_i;
                    outmap_size_nxt = outmap_size_decoded;
                    coord_clear = 1'b1;
                    clear_nxt = 1'b1;
                    state_nxt = CLEAR_LOCAL;
                end
            end

            CLEAR_LOCAL: begin
                if (run_en_i && !load_busy_i && !read_busy_i) begin
                    load_start_nxt = 1'b1;
                    state_nxt = WAIT_INIT_LOAD;
                end
            end

            WAIT_INIT_LOAD: begin
                if (load_done_i) begin
                    // The first load filled activation write bank 0. Swap it
                    // into the read side. If another coordinate exists,
                    // immediately prefetch it into the other activation bank
                    // and the next weight addresses.
                    swap_nxt = 1'b1;
                    read_last_nxt = coord_last;
                    read_done_seen_nxt = 1'b0;
                    prefetch_done_nxt = 1'b0;

                    if (!coord_last && run_en_i) begin
                        coord_update_en = 1'b1;
                        load_start_nxt = 1'b1;
                        prefetch_valid_nxt = 1'b1;
                    end else begin
                        prefetch_valid_nxt = 1'b0;
                    end
                    state_nxt = START_READ;
                end
            end

            START_READ: begin
                read_start_nxt = run_en_i;
                if (run_en_i) begin
                    state_nxt = COMP;
                end
            end

            COMP: begin
                if (prefetch_valid_r && load_done_i) begin
                    prefetch_done_nxt = 1'b1;
                end
                if (read_done_i) begin
                    read_done_seen_nxt = 1'b1;
                end

                if (read_last_r && (read_done_i || read_done_seen_r)) begin
                    state_nxt = DONE;
                    prefetch_valid_nxt = 1'b0;
                    prefetch_done_nxt = 1'b0;
                    read_done_seen_nxt = 1'b0;
                end else if (!read_last_r &&
                             (read_done_i || read_done_seen_r) &&
                             (load_done_i || prefetch_done_r)) begin
                    // Safe point: current read-side activation window has been
                    // consumed and the next write-side window is fully loaded.
                    swap_nxt = 1'b1;
                    read_last_nxt = coord_last;
                    read_done_seen_nxt = 1'b0;
                    prefetch_done_nxt = 1'b0;

                    if (!coord_last && run_en_i) begin
                        coord_update_en = 1'b1;
                        load_start_nxt = 1'b1;
                        prefetch_valid_nxt = 1'b1;
                    end else begin
                        prefetch_valid_nxt = 1'b0;
                    end
                    state_nxt = START_READ;
                end
            end

            DONE: begin
                done_nxt = 1'b1;
                clear_nxt = 1'b1;
                if (run_en_i) begin
                    state_nxt = IDLE;
                end
            end

            default: begin
                state_nxt = IDLE;
            end
        endcase
    end

    assign busy_o = (state != IDLE);

endmodule
