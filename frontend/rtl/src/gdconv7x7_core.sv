module gdconv7x7_core #(
    parameter int DATA_W       = 8,
    parameter int ACC_W        = 32,
    parameter int GB_DATA_W    = 128,
    parameter int GB_ADDR_W    = 16,
    parameter int CHANNELS     = 512,
    parameter int KERNEL_ELEMS = 49,

    localparam int LANES = GB_DATA_W / DATA_W,
    localparam int LANE_W = (LANES <= 1) ? 1 : $clog2(LANES),
    localparam int CHANNEL_W = (CHANNELS <= 1) ? 1 : $clog2(CHANNELS),
    localparam int KPOS_W = (KERNEL_ELEMS <= 1) ? 1 : $clog2(KERNEL_ELEMS),
    localparam int WORDS_PER_KPOS = (CHANNELS + LANES - 1) / LANES
) (
    input  logic clk,
    input  logic rst_n,
    input  logic run_en_i,

    input  logic start_i,
    output logic busy_o,
    output logic done_o,

    input  logic [GB_ADDR_W-1:0] act_base_addr_i,
    input  logic [GB_ADDR_W-1:0] wgt_base_addr_i,

    output logic                 gb_act_rd_valid_o,
    output logic [GB_ADDR_W-1:0] gb_act_rd_addr_o,
    input  logic [GB_DATA_W-1:0] gb_act_rd_data_i,

    output logic                 gb_wgt_rd_valid_o,
    output logic [GB_ADDR_W-1:0] gb_wgt_rd_addr_o,
    input  logic [GB_DATA_W-1:0] gb_wgt_rd_data_i,

    output logic                         psum_valid_o,
    output logic [CHANNEL_W-1:0]         psum_channel_o,
    output logic signed [ACC_W-1:0]      psum_o
);
    typedef enum logic [1:0] {
        IDLE,
        RUN,
        DONE
    } state_t;

    state_t state, state_nxt;

    logic [CHANNEL_W-1:0] ch_cnt, ch_cnt_nxt;
    logic [KPOS_W-1:0] kpos_cnt, kpos_cnt_nxt;
    logic [GB_ADDR_W-1:0] act_addr, act_addr_nxt;
    logic [GB_ADDR_W-1:0] wgt_addr, wgt_addr_nxt;
    logic signed [ACC_W-1:0] acc, acc_nxt;

    logic pending_valid, pending_valid_nxt;
    logic pending_last, pending_last_nxt;
    logic [LANE_W-1:0] pending_lane, pending_lane_nxt;

    logic [GB_ADDR_W-1:0] ch_word_offset_w;
    logic [LANE_W-1:0] ch_lane_w;
    logic [CHANNEL_W-1:0] next_ch_w;
    logic [GB_ADDR_W-1:0] next_ch_word_offset_w;
    logic signed [DATA_W-1:0] act_byte_w;
    logic signed [DATA_W-1:0] wgt_byte_w;
    logic signed [(2*DATA_W)-1:0] product_w;
    logic signed [ACC_W-1:0] product_ext_w;
    logic signed [ACC_W-1:0] acc_sum_w;
    logic issue_read_w;
    logic kpos_last_w;
    logic ch_last_w;

    assign busy_o = (state != IDLE);

    assign ch_word_offset_w = GB_ADDR_W'(ch_cnt >> LANE_W);
    assign ch_lane_w = ch_cnt[LANE_W-1:0];
    assign next_ch_w = ch_cnt + CHANNEL_W'(1);
    assign next_ch_word_offset_w = GB_ADDR_W'(next_ch_w >> LANE_W);

    assign act_byte_w = gb_act_rd_data_i[pending_lane*DATA_W +: DATA_W];
    assign wgt_byte_w = gb_wgt_rd_data_i[pending_lane*DATA_W +: DATA_W];
    assign product_w = act_byte_w * wgt_byte_w;
    assign product_ext_w = {{(ACC_W-(2*DATA_W)){product_w[(2*DATA_W)-1]}}, product_w};
    assign acc_sum_w = acc + product_ext_w;

    assign kpos_last_w = (kpos_cnt == KPOS_W'(KERNEL_ELEMS - 1));
    assign ch_last_w = (ch_cnt == CHANNEL_W'(CHANNELS - 1));
    assign issue_read_w = (state == RUN) && run_en_i && !(pending_valid && pending_last);

    always_comb begin
        state_nxt = state;
        ch_cnt_nxt = ch_cnt;
        kpos_cnt_nxt = kpos_cnt;
        act_addr_nxt = act_addr;
        wgt_addr_nxt = wgt_addr;
        acc_nxt = acc;
        pending_valid_nxt = 1'b0;
        pending_last_nxt = 1'b0;
        pending_lane_nxt = pending_lane;

        gb_act_rd_valid_o = 1'b0;
        gb_act_rd_addr_o = act_addr;
        gb_wgt_rd_valid_o = 1'b0;
        gb_wgt_rd_addr_o = wgt_addr;
        psum_valid_o = 1'b0;
        psum_channel_o = ch_cnt;
        psum_o = acc_sum_w;
        done_o = 1'b0;

        case (state)
            IDLE: begin
                ch_cnt_nxt = '0;
                kpos_cnt_nxt = '0;
                act_addr_nxt = act_base_addr_i;
                wgt_addr_nxt = wgt_base_addr_i;
                acc_nxt = '0;
                if (start_i && run_en_i) begin
                    state_nxt = RUN;
                end
            end

            RUN: begin
                if (pending_valid) begin
                    if (pending_last) begin
                        psum_valid_o = 1'b1;
                        psum_channel_o = ch_cnt;
                        psum_o = acc_sum_w;
                        acc_nxt = '0;
                        kpos_cnt_nxt = '0;

                        if (ch_last_w) begin
                            state_nxt = DONE;
                        end else begin
                            ch_cnt_nxt = next_ch_w;
                            act_addr_nxt = act_base_addr_i + next_ch_word_offset_w;
                            wgt_addr_nxt = wgt_base_addr_i + next_ch_word_offset_w;
                        end
                    end else begin
                        acc_nxt = acc_sum_w;
                    end
                end

                // Issue the next 128-bit activation/weight word. The returned
                // word is consumed one cycle later using the saved byte lane.
                if (issue_read_w) begin
                    gb_act_rd_valid_o = 1'b1;
                    gb_act_rd_addr_o = act_addr;
                    gb_wgt_rd_valid_o = 1'b1;
                    gb_wgt_rd_addr_o = wgt_addr;

                    pending_valid_nxt = 1'b1;
                    pending_last_nxt = kpos_last_w;
                    pending_lane_nxt = ch_lane_w;

                    if (!kpos_last_w) begin
                        kpos_cnt_nxt = kpos_cnt + KPOS_W'(1);
                        act_addr_nxt = act_addr + GB_ADDR_W'(WORDS_PER_KPOS);
                        wgt_addr_nxt = wgt_addr + GB_ADDR_W'(WORDS_PER_KPOS);
                    end
                end
            end

            DONE: begin
                done_o = 1'b1;
                if (run_en_i) begin
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
            ch_cnt <= '0;
            kpos_cnt <= '0;
            act_addr <= '0;
            wgt_addr <= '0;
            acc <= '0;
            pending_valid <= 1'b0;
            pending_last <= 1'b0;
            pending_lane <= '0;
        end else begin
            state <= state_nxt;
            ch_cnt <= ch_cnt_nxt;
            kpos_cnt <= kpos_cnt_nxt;
            act_addr <= act_addr_nxt;
            wgt_addr <= wgt_addr_nxt;
            acc <= acc_nxt;
            pending_valid <= pending_valid_nxt;
            pending_last <= pending_last_nxt;
            pending_lane <= pending_lane_nxt;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (GB_DATA_W % DATA_W != 0) begin
            $fatal(1, "gdconv7x7_core requires GB_DATA_W to be a multiple of DATA_W");
        end
        if (CHANNELS % LANES != 0) begin
            $fatal(1, "gdconv7x7_core currently expects CHANNELS to align to GB lanes");
        end
    end
`endif

endmodule
