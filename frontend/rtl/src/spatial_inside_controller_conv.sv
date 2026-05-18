// Inside controller for traditional Conv3x3.
//
// Loop order:
//   for out_x
//     for out_y
//       for output-channel tile
//         for input channel
//           load one 3x3 activation window + one 3x3x16 weight slice
//           read 16 output-channel lanes
//
// This first Conv3x3 controller keeps the local-buffer protocol simple:
// each input-channel slice is loaded, swapped, read, then the next slice is
// loaded. The IC accumulator below the PE array keeps the partial sums.
module spatial_inside_controller_conv #(
    parameter int ADDR_W = 16,
    parameter int FILTER_CNT_W = 10,
    parameter int LANES = 16
) (
    input  logic clk,
    input  logic rst_n,
    input  logic run_en_i,
    input  logic start_i,

    output logic busy_o,
    output logic done_o,

    // current_num_filter_i is the output-channel count.
    input  logic [FILTER_CNT_W-1:0] current_num_filter_i,
    input  logic [FILTER_CNT_W-1:0] input_channel_count_i,
    input  logic [3:0] input_channel_words_shift_i,
    input  logic [2:0] ifmap_size_code_i,
    input  logic stride_i,

    input  logic load_busy_i,
    input  logic load_done_i,
    input  logic read_busy_i,
    input  logic read_done_i,

    output logic              clear_o,
    output logic              swap_o,
    output logic [ADDR_W-1:0] tile_offset_o,
    output logic [ADDR_W-1:0] out_x_o,
    output logic [ADDR_W-1:0] out_y_o,
    output logic              conv_mode_o,
    output logic [ADDR_W-1:0] ic_offset_o,
    output logic [3:0]        input_channel_words_shift_o,
    output logic              load_start_o,
    output logic              read_start_o
);
    typedef enum logic [2:0] {
        IDLE,
        CLEAR_SLICE,
        START_LOAD,
        WAIT_LOAD,
        START_READ,
        WAIT_READ,
        DONE
    } state_t;

    state_t state, state_nxt;

    logic [FILTER_CNT_W-1:0] current_num_filter, current_num_filter_nxt;
    logic [FILTER_CNT_W-1:0] input_channel_count, input_channel_count_nxt;
    logic [3:0] input_channel_words_shift, input_channel_words_shift_nxt;
    logic [ADDR_W-1:0] outmap_size, outmap_size_nxt;
    logic [ADDR_W-1:0] ifmap_size_decoded;
    logic [ADDR_W-1:0] outmap_size_decoded;

    logic [ADDR_W-1:0] x_cnt, x_cnt_nxt;
    logic [ADDR_W-1:0] y_cnt, y_cnt_nxt;
    logic [ADDR_W-1:0] tile_cnt, tile_cnt_nxt;
    logic [ADDR_W-1:0] ic_cnt, ic_cnt_nxt;

    logic clear_nxt;
    logic swap_nxt;
    logic load_start_nxt;
    logic read_start_nxt;
    logic done_nxt;

    logic tile_last;
    logic ic_last;
    logic y_last;
    logic x_last;
    logic layer_last;
    logic advance_coord;

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

    assign tile_last = ({1'b0, tile_cnt} + (ADDR_W+1)'(LANES)) >=
                       (ADDR_W+1)'(current_num_filter);
    assign ic_last = ({1'b0, ic_cnt} + (ADDR_W+1)'(1)) >=
                     (ADDR_W+1)'(input_channel_count);
    assign y_last = (y_cnt + ADDR_W'(1)) >= outmap_size;
    assign x_last = (x_cnt + ADDR_W'(1)) >= outmap_size;
    assign layer_last = tile_last && ic_last && y_last && x_last;

    assign tile_offset_o = tile_cnt;
    assign out_x_o = x_cnt;
    assign out_y_o = y_cnt;
    assign conv_mode_o = 1'b1;
    assign ic_offset_o = ic_cnt;
    assign input_channel_words_shift_o = input_channel_words_shift;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            current_num_filter <= '0;
            input_channel_count <= '0;
            input_channel_words_shift <= '0;
            outmap_size <= '0;
            x_cnt <= '0;
            y_cnt <= '0;
            tile_cnt <= '0;
            ic_cnt <= '0;
            clear_o <= 1'b0;
            swap_o <= 1'b0;
            load_start_o <= 1'b0;
            read_start_o <= 1'b0;
            done_o <= 1'b0;
        end else begin
            state <= state_nxt;
            current_num_filter <= current_num_filter_nxt;
            input_channel_count <= input_channel_count_nxt;
            input_channel_words_shift <= input_channel_words_shift_nxt;
            outmap_size <= outmap_size_nxt;
            x_cnt <= x_cnt_nxt;
            y_cnt <= y_cnt_nxt;
            tile_cnt <= tile_cnt_nxt;
            ic_cnt <= ic_cnt_nxt;
            clear_o <= clear_nxt;
            swap_o <= swap_nxt;
            load_start_o <= load_start_nxt;
            read_start_o <= read_start_nxt;
            done_o <= done_nxt;
        end
    end

    always_comb begin
        state_nxt = state;
        current_num_filter_nxt = current_num_filter;
        input_channel_count_nxt = input_channel_count;
        input_channel_words_shift_nxt = input_channel_words_shift;
        outmap_size_nxt = outmap_size;
        x_cnt_nxt = x_cnt;
        y_cnt_nxt = y_cnt;
        tile_cnt_nxt = tile_cnt;
        ic_cnt_nxt = ic_cnt;

        clear_nxt = 1'b0;
        swap_nxt = 1'b0;
        load_start_nxt = 1'b0;
        read_start_nxt = 1'b0;
        done_nxt = 1'b0;
        advance_coord = 1'b0;

        case (state)
            IDLE: begin
                if (start_i && run_en_i) begin
                    current_num_filter_nxt = current_num_filter_i;
                    input_channel_count_nxt = input_channel_count_i;
                    input_channel_words_shift_nxt = input_channel_words_shift_i;
                    outmap_size_nxt = outmap_size_decoded;
                    x_cnt_nxt = '0;
                    y_cnt_nxt = '0;
                    tile_cnt_nxt = '0;
                    ic_cnt_nxt = '0;
                    state_nxt = CLEAR_SLICE;
                end
            end

            CLEAR_SLICE: begin
                clear_nxt = 1'b1;
                if (run_en_i && !load_busy_i && !read_busy_i) begin
                    state_nxt = START_LOAD;
                end
            end

            START_LOAD: begin
                load_start_nxt = run_en_i;
                if (run_en_i) begin
                    state_nxt = WAIT_LOAD;
                end
            end

            WAIT_LOAD: begin
                if (load_done_i) begin
                    swap_nxt = 1'b1;
                    state_nxt = START_READ;
                end
            end

            START_READ: begin
                read_start_nxt = run_en_i;
                if (run_en_i) begin
                    state_nxt = WAIT_READ;
                end
            end

            WAIT_READ: begin
                if (read_done_i) begin
                    if (layer_last) begin
                        state_nxt = DONE;
                    end else begin
                        advance_coord = 1'b1;
                        state_nxt = CLEAR_SLICE;
                    end
                end
            end

            DONE: begin
                done_nxt = 1'b1;
                clear_nxt = 1'b1;
                state_nxt = IDLE;
            end

            default: begin
                state_nxt = IDLE;
            end
        endcase

        if (advance_coord) begin
            if (!ic_last) begin
                ic_cnt_nxt = ic_cnt + ADDR_W'(1);
            end else begin
                ic_cnt_nxt = '0;
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
                        end
                    end
                end
            end
        end
    end

    assign busy_o = (state != IDLE);

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && start_i) begin
            if (current_num_filter_i == '0) begin
                $fatal(1, "spatial_inside_controller_conv current_num_filter_i must be non-zero");
            end
            if (input_channel_count_i == '0) begin
                $fatal(1, "spatial_inside_controller_conv input_channel_count_i must be non-zero");
            end
        end
    end
`endif
endmodule
