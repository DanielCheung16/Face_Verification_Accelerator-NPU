module spatial_ld_controller #(
    parameter int ADDR_W = 16,
    parameter int WORD_W = 128,

    localparam int NUM_POS = 9,
    localparam int POS_W = 4
) (
    input  logic clk,
    input  logic rst_n,

    //system control signals
    input  logic load_start_i,          //should be one pulse
    input  logic [ADDR_W-1:0] act_base_addr_i,
    input  logic [ADDR_W-1:0] wgt_base_addr_i,
    input  logic [1:0] num_filter_code_i,  //0:64, 1:128, 2:256, 3:512
    input  logic [2:0] ifmap_size_code_i,  //0:7, 1:14, 2:28, 3:56, 4:112
    input  logic [ADDR_W-1:0] tile_offset_i, //0, 16, 32...
    input  logic [ADDR_W-1:0] out_x_i,
    input  logic [ADDR_W-1:0] out_y_i,
    input  logic stride_i,              //0: stride=1, 1: stride=2
    input  logic pad_i,                 //0: no padding, 1: 3x3 same padding
    input  logic conv_mode_i,           //0: DW, 1: traditional conv3x3
    input  logic [ADDR_W-1:0] ic_offset_i,
    input  logic [3:0] input_channel_words_shift_i,
    input  logic all_weights_loaded_i,

    //global A/O SRAM read
    output logic gb_act_rd_en_o,
    output logic [ADDR_W-1:0] gb_act_rd_addr_o,
    input  logic [WORD_W-1:0] gb_act_rd_data_i,

    //global Weight SRAM read
    output logic gb_wgt_rd_en_o,
    output logic [ADDR_W-1:0] gb_wgt_rd_addr_o,
    input  logic [WORD_W-1:0] gb_wgt_rd_data_i,

    //local activation window buffer write
    output logic act_wr_en_o,
    output logic [POS_W-1:0] act_wr_pos_o,
    output logic [WORD_W-1:0] act_wr_data_o,

    //local weight buffer write
    output logic wgt_wr_en_o,
    output logic [POS_W-1:0] wgt_wr_pos_o,
    output logic [WORD_W-1:0] wgt_wr_data_o,

    output logic load_busy_o,
    output logic load_done_o
);
    typedef enum logic [2:0] {
        IDLE,
        SETUP_CFG,
        SETUP_ADDR,
        ISSUE_READ,
        WAIT_LAST
    } state_t;

    state_t state, state_nxt;

    logic [POS_W-1:0] issue_pos_cnt, issue_pos_cnt_nxt;

    logic [ADDR_W-1:0] row_stride, row_stride_nxt;
    logic [ADDR_W-1:0] pixel_stride, pixel_stride_nxt;
    logic [ADDR_W-1:0] tile_offset, tile_offset_nxt;
    logic [ADDR_W-1:0] center_x, center_x_nxt;
    logic [ADDR_W-1:0] center_y, center_y_nxt;
    logic [3:0] num_filter_shift, num_filter_shift_nxt;
    logic [2:0] ifmap_size_code, ifmap_size_code_nxt;
    logic conv_mode, conv_mode_nxt;
    logic [ADDR_W-1:0] ic_offset, ic_offset_nxt;
    logic [3:0] input_channel_words_shift, input_channel_words_shift_nxt;
    logic [ADDR_W-1:0] act_addr [NUM_POS];
    logic [ADDR_W-1:0] act_addr_nxt [NUM_POS];
    logic [ADDR_W-1:0] wgt_addr [NUM_POS];
    logic [ADDR_W-1:0] wgt_addr_nxt [NUM_POS];
    logic [NUM_POS-1:0] act_zero, act_zero_nxt;

    logic [POS_W-1:0] act_wr_pos_pipe, act_wr_pos_pipe_nxt;
    logic [POS_W-1:0] wgt_wr_pos_pipe, wgt_wr_pos_pipe_nxt;
    logic [POS_W-1:0] act_wr_pos_pipe2, act_wr_pos_pipe2_nxt;
    logic [POS_W-1:0] wgt_wr_pos_pipe2, wgt_wr_pos_pipe2_nxt;
    logic act_rd_valid_pipe, act_rd_valid_pipe_nxt;
    logic wgt_rd_valid_pipe, wgt_rd_valid_pipe_nxt;
    logic act_rd_valid_pipe2, act_rd_valid_pipe2_nxt;
    logic wgt_rd_valid_pipe2, wgt_rd_valid_pipe2_nxt;
    logic act_zero_pipe, act_zero_pipe_nxt;
    logic act_zero_pipe2, act_zero_pipe2_nxt;
    logic last_issue_pipe, last_issue_pipe_nxt;
    logic last_issue_pipe2, last_issue_pipe2_nxt;

    logic gb_act_rd_en_nxt;
    logic [ADDR_W-1:0] gb_act_rd_addr_nxt;
    logic gb_wgt_rd_en_nxt;
    logic [ADDR_W-1:0] gb_wgt_rd_addr_nxt;
    logic act_wr_en_nxt;
    logic [POS_W-1:0] act_wr_pos_nxt;
    logic [WORD_W-1:0] act_wr_data_nxt;
    logic wgt_wr_en_nxt;
    logic [POS_W-1:0] wgt_wr_pos_nxt;
    logic [WORD_W-1:0] wgt_wr_data_nxt;
    logic load_done_nxt;

    logic [ADDR_W-1:0] cfg_row_stride;
    logic [ADDR_W-1:0] cfg_pixel_stride;
    logic [ADDR_W-1:0] cfg_tile_offset;
    logic [ADDR_W-1:0] cfg_center_x;
    logic [ADDR_W-1:0] cfg_center_y;
    logic [3:0] cfg_num_filter_shift;
    logic [2:0] cfg_ifmap_size_code;
    logic cfg_conv_mode;
    logic [ADDR_W-1:0] cfg_ic_offset;
    logic [3:0] cfg_input_channel_words_shift;
    logic [ADDR_W-1:0] addr_gen_act_addr [NUM_POS];
    logic [ADDR_W-1:0] addr_gen_wgt_addr [NUM_POS];
    logic [NUM_POS-1:0] addr_gen_act_zero;

    spatial_addr_gen #(
        .ADDR_W(ADDR_W)
    ) u_spatial_addr_gen (
        .act_base_addr_i(act_base_addr_i),
        .wgt_base_addr_i(wgt_base_addr_i),
        .num_filter_code_i(num_filter_code_i),
        .ifmap_size_code_i(ifmap_size_code_i),
        .tile_offset_i(tile_offset_i),
        .out_x_i(out_x_i),
        .out_y_i(out_y_i),
        .stride_i(stride_i),
        .pad_i(pad_i),
        .conv_mode_i(conv_mode_i),
        .ic_offset_i(ic_offset_i),
        .input_channel_words_shift_i(input_channel_words_shift_i),
        .row_stride_i(row_stride),
        .pixel_stride_i(pixel_stride),
        .tile_offset_r_i(tile_offset),
        .center_x_i(center_x),
        .center_y_i(center_y),
        .num_filter_shift_i(num_filter_shift),
        .ifmap_size_code_r_i(ifmap_size_code),
        .conv_mode_r_i(conv_mode),
        .ic_offset_r_i(ic_offset),
        .input_channel_words_shift_r_i(input_channel_words_shift),
        .cfg_row_stride_o(cfg_row_stride),
        .cfg_pixel_stride_o(cfg_pixel_stride),
        .cfg_tile_offset_o(cfg_tile_offset),
        .cfg_center_x_o(cfg_center_x),
        .cfg_center_y_o(cfg_center_y),
        .cfg_num_filter_shift_o(cfg_num_filter_shift),
        .cfg_ifmap_size_code_o(cfg_ifmap_size_code),
        .cfg_conv_mode_o(cfg_conv_mode),
        .cfg_ic_offset_o(cfg_ic_offset),
        .cfg_input_channel_words_shift_o(cfg_input_channel_words_shift),
        .act_addr_o(addr_gen_act_addr),
        .wgt_addr_o(addr_gen_wgt_addr),
        .act_zero_o(addr_gen_act_zero)
    );

    // Address setup is intentionally isolated in SETUP_ADDR. ISSUE_READ only
    // muxes one of the registered 9 addresses, keeping the SRAM address path short.
    always_comb begin
        row_stride_nxt = row_stride;
        pixel_stride_nxt = pixel_stride;
        tile_offset_nxt = tile_offset;
        center_x_nxt = center_x;
        center_y_nxt = center_y;
        num_filter_shift_nxt = num_filter_shift;
        ifmap_size_code_nxt = ifmap_size_code;
        conv_mode_nxt = conv_mode;
        ic_offset_nxt = ic_offset;
        input_channel_words_shift_nxt = input_channel_words_shift;
        for (int pos = 0; pos < NUM_POS; pos++) begin
            act_addr_nxt[pos] = act_addr[pos];
            wgt_addr_nxt[pos] = wgt_addr[pos];
            act_zero_nxt[pos] = act_zero[pos];
        end

        if (state == SETUP_CFG) begin
            pixel_stride_nxt = cfg_pixel_stride;
            row_stride_nxt = cfg_row_stride;
            tile_offset_nxt = cfg_tile_offset;
            center_x_nxt = cfg_center_x;
            center_y_nxt = cfg_center_y;
            num_filter_shift_nxt = cfg_num_filter_shift;
            ifmap_size_code_nxt = cfg_ifmap_size_code;
            conv_mode_nxt = cfg_conv_mode;
            ic_offset_nxt = cfg_ic_offset;
            input_channel_words_shift_nxt = cfg_input_channel_words_shift;
        end

        if (state == SETUP_ADDR) begin
            for (int pos = 0; pos < NUM_POS; pos++) begin
                act_addr_nxt[pos] = addr_gen_act_addr[pos];
                wgt_addr_nxt[pos] = addr_gen_wgt_addr[pos];
                act_zero_nxt[pos] = addr_gen_act_zero[pos];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            issue_pos_cnt <= '0;
            row_stride <= '0;
            pixel_stride <= '0;
            tile_offset <= '0;
            center_x <= '0;
            center_y <= '0;
            num_filter_shift <= '0;
            ifmap_size_code <= '0;
            conv_mode <= 1'b0;
            ic_offset <= '0;
            input_channel_words_shift <= '0;
            act_wr_pos_pipe <= '0;
            wgt_wr_pos_pipe <= '0;
            act_wr_pos_pipe2 <= '0;
            wgt_wr_pos_pipe2 <= '0;
            act_rd_valid_pipe <= 1'b0;
            wgt_rd_valid_pipe <= 1'b0;
            act_rd_valid_pipe2 <= 1'b0;
            wgt_rd_valid_pipe2 <= 1'b0;
            act_zero_pipe <= 1'b0;
            act_zero_pipe2 <= 1'b0;
            last_issue_pipe <= 1'b0;
            last_issue_pipe2 <= 1'b0;
            gb_act_rd_en_o <= 1'b0;
            gb_act_rd_addr_o <= '0;
            gb_wgt_rd_en_o <= 1'b0;
            gb_wgt_rd_addr_o <= '0;
            act_wr_en_o <= 1'b0;
            act_wr_pos_o <= '0;
            act_wr_data_o <= '0;
            wgt_wr_en_o <= 1'b0;
            wgt_wr_pos_o <= '0;
            wgt_wr_data_o <= '0;
            load_busy_o <= 1'b0;
            load_done_o <= 1'b0;
            for (int pos = 0; pos < NUM_POS; pos++) begin
                act_addr[pos] <= '0;
                wgt_addr[pos] <= '0;
                act_zero[pos] <= 1'b0;
            end
        end else begin
            state <= state_nxt;
            issue_pos_cnt <= issue_pos_cnt_nxt;
            row_stride <= row_stride_nxt;
            pixel_stride <= pixel_stride_nxt;
            tile_offset <= tile_offset_nxt;
            center_x <= center_x_nxt;
            center_y <= center_y_nxt;
            num_filter_shift <= num_filter_shift_nxt;
            ifmap_size_code <= ifmap_size_code_nxt;
            conv_mode <= conv_mode_nxt;
            ic_offset <= ic_offset_nxt;
            input_channel_words_shift <= input_channel_words_shift_nxt;
            act_wr_pos_pipe <= act_wr_pos_pipe_nxt;
            wgt_wr_pos_pipe <= wgt_wr_pos_pipe_nxt;
            act_wr_pos_pipe2 <= act_wr_pos_pipe2_nxt;
            wgt_wr_pos_pipe2 <= wgt_wr_pos_pipe2_nxt;
            act_rd_valid_pipe <= act_rd_valid_pipe_nxt;
            wgt_rd_valid_pipe <= wgt_rd_valid_pipe_nxt;
            act_rd_valid_pipe2 <= act_rd_valid_pipe2_nxt;
            wgt_rd_valid_pipe2 <= wgt_rd_valid_pipe2_nxt;
            act_zero_pipe <= act_zero_pipe_nxt;
            act_zero_pipe2 <= act_zero_pipe2_nxt;
            last_issue_pipe <= last_issue_pipe_nxt;
            last_issue_pipe2 <= last_issue_pipe2_nxt;
            gb_act_rd_en_o <= gb_act_rd_en_nxt;
            gb_act_rd_addr_o <= gb_act_rd_addr_nxt;
            gb_wgt_rd_en_o <= gb_wgt_rd_en_nxt;
            gb_wgt_rd_addr_o <= gb_wgt_rd_addr_nxt;
            act_wr_en_o <= act_wr_en_nxt;
            act_wr_pos_o <= act_wr_pos_nxt;
            act_wr_data_o <= act_wr_data_nxt;
            wgt_wr_en_o <= wgt_wr_en_nxt;
            wgt_wr_pos_o <= wgt_wr_pos_nxt;
            wgt_wr_data_o <= wgt_wr_data_nxt;
            load_busy_o <= (state_nxt != IDLE);
            load_done_o <= load_done_nxt;
            for (int pos = 0; pos < NUM_POS; pos++) begin
                act_addr[pos] <= act_addr_nxt[pos];
                wgt_addr[pos] <= wgt_addr_nxt[pos];
                act_zero[pos] <= act_zero_nxt[pos];
            end
        end
    end

    always_comb begin
        state_nxt = state;
        issue_pos_cnt_nxt = issue_pos_cnt;
        act_wr_pos_pipe_nxt = issue_pos_cnt;
        wgt_wr_pos_pipe_nxt = issue_pos_cnt;
        act_wr_pos_pipe2_nxt = act_wr_pos_pipe;
        wgt_wr_pos_pipe2_nxt = wgt_wr_pos_pipe;
        act_rd_valid_pipe_nxt = 1'b0;
        wgt_rd_valid_pipe_nxt = 1'b0;
        act_rd_valid_pipe2_nxt = act_rd_valid_pipe;
        wgt_rd_valid_pipe2_nxt = wgt_rd_valid_pipe;
        act_zero_pipe_nxt = 1'b0;
        act_zero_pipe2_nxt = act_zero_pipe;
        last_issue_pipe_nxt = 1'b0;
        last_issue_pipe2_nxt = last_issue_pipe;
        gb_act_rd_en_nxt = 1'b0;
        gb_act_rd_addr_nxt = gb_act_rd_addr_o;
        gb_wgt_rd_en_nxt = 1'b0;
        gb_wgt_rd_addr_nxt = gb_wgt_rd_addr_o;
        // gb_*_rd_en_o/addr_o are registered outputs and the SRAM is a
        // one-cycle synchronous read. This second pipe aligns the returned
        // SRAM word with the local-buffer write position.
        act_wr_en_nxt = act_rd_valid_pipe2;
        act_wr_pos_nxt = act_wr_pos_pipe2;
        act_wr_data_nxt = act_zero_pipe2 ? '0 : gb_act_rd_data_i;
        wgt_wr_en_nxt = wgt_rd_valid_pipe2;
        wgt_wr_pos_nxt = wgt_wr_pos_pipe2;
        wgt_wr_data_nxt = gb_wgt_rd_data_i;
        load_done_nxt = last_issue_pipe2;

        case (state)
            IDLE: begin
                issue_pos_cnt_nxt = '0;
                if (load_start_i) begin
                    state_nxt = SETUP_CFG;
                end
            end

            SETUP_CFG: begin
                issue_pos_cnt_nxt = '0;
                state_nxt = SETUP_ADDR;
            end

            SETUP_ADDR: begin
                issue_pos_cnt_nxt = '0;
                state_nxt = ISSUE_READ;
            end

            ISSUE_READ: begin
                act_wr_pos_pipe_nxt = issue_pos_cnt;
                wgt_wr_pos_pipe_nxt = issue_pos_cnt;
                act_zero_pipe_nxt = act_zero[issue_pos_cnt];
                last_issue_pipe_nxt = (issue_pos_cnt == POS_W'(NUM_POS - 1));

                if (act_zero[issue_pos_cnt]) begin
                    act_rd_valid_pipe_nxt = 1'b1;
                end else begin
                    gb_act_rd_en_nxt = 1'b1;
                    gb_act_rd_addr_nxt = act_addr[issue_pos_cnt];
                    act_rd_valid_pipe_nxt = 1'b1;
                end

                // DW can keep the local weight buffer after it is fully loaded.
                // Conv3x3 reloads weights for each input-channel slice.
                if (conv_mode || !all_weights_loaded_i) begin
                    gb_wgt_rd_en_nxt = 1'b1;
                    gb_wgt_rd_addr_nxt = wgt_addr[issue_pos_cnt];
                    wgt_rd_valid_pipe_nxt = 1'b1;
                end

                if (issue_pos_cnt == POS_W'(NUM_POS - 1)) begin
                    issue_pos_cnt_nxt = '0;
                    state_nxt = WAIT_LAST;
                end else begin
                    issue_pos_cnt_nxt = issue_pos_cnt + POS_W'(1);
                end
            end

            WAIT_LAST: begin
                if (last_issue_pipe2) begin
                    state_nxt = IDLE;
                end
            end

            default: begin
                state_nxt = IDLE;
            end
        endcase
    end

`ifndef SYNTHESIS
    initial begin
        if (NUM_POS != 9) begin
            $fatal(1, "spatial_ld_controller assumes 9 positions for a 3x3 window");
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n && load_start_i) begin
            if (ifmap_size_code_i > 3'd4) begin
                $fatal(1, "spatial_ld_controller ifmap_size_code_i must be 0..4 for 7/14/28/56/112");
            end
        end
    end
`endif
endmodule
