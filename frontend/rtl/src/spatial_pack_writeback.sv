// Pack a stream of int8 spatial outputs into 128-bit HWC words.
//
// The upstream spatial engine emits data in linear HWC order:
//   for x
//     for y
//       for channel tile
//         lane 0..15
//
// Therefore writeback address generation only needs a linear addr_cnt. No
// x/y/row-base multiplication is required in this module.
module spatial_pack_writeback #(
    parameter int DATA_W = 8,
    parameter int GB_DATA_W = 128,
    parameter int GB_ADDR_W = 20,
    parameter int ELEM_CNT_W = 32,

    localparam int LANES = GB_DATA_W / DATA_W,
    localparam int LANE_CNT_W = (LANES <= 1) ? 1 : $clog2(LANES),
    localparam int MASK_W = LANES
) (
    input  logic clk,
    input  logic rst_n,

    input  logic start_i,
    input  logic [GB_ADDR_W-1:0] out_base_addr_i,
    input  logic [ELEM_CNT_W-1:0] output_elements_i,

    input  logic signed [DATA_W-1:0] data_i,
    input  logic                     valid_i,

    output logic                     gb_ao_wr_valid_o,
    output logic [GB_ADDR_W-1:0]     gb_ao_wr_addr_o,
    output logic [GB_DATA_W-1:0]     gb_ao_wr_data_o,
    output logic [MASK_W-1:0]        gb_ao_wr_mask_o,

    output logic busy_o,
    output logic done_o
);
    typedef enum logic [1:0] {
        IDLE,
        PACK
    } state_t;

    state_t state, state_nxt;

    logic [LANE_CNT_W-1:0] lane_cnt, lane_cnt_nxt;
    logic [ELEM_CNT_W-1:0] elem_cnt, elem_cnt_nxt;
    logic [ELEM_CNT_W-1:0] output_elements_r, output_elements_nxt;
    logic [GB_ADDR_W-1:0] addr_cnt, addr_cnt_nxt;
    logic [GB_DATA_W-1:0] pack_data, pack_data_nxt;
    logic [MASK_W-1:0] pack_mask, pack_mask_nxt;

    logic gb_ao_wr_valid_nxt;
    logic [GB_ADDR_W-1:0] gb_ao_wr_addr_nxt;
    logic [GB_DATA_W-1:0] gb_ao_wr_data_nxt;
    logic [MASK_W-1:0] gb_ao_wr_mask_nxt;
    logic done_nxt;

    logic accept_w;
    logic last_lane_w;
    logic last_elem_w;
    logic flush_w;
    logic [GB_DATA_W-1:0] pack_data_with_new_w;
    logic [MASK_W-1:0] pack_mask_with_new_w;

    assign accept_w = (state == PACK) && valid_i && (elem_cnt < output_elements_r);
    assign last_lane_w = (lane_cnt == LANE_CNT_W'(LANES - 1));
    assign last_elem_w = accept_w && ((elem_cnt + ELEM_CNT_W'(1)) >= output_elements_r);
    assign flush_w = accept_w && (last_lane_w || last_elem_w);

    always_comb begin
        pack_data_with_new_w = pack_data;
        pack_mask_with_new_w = pack_mask;
        pack_data_with_new_w[lane_cnt*DATA_W +: DATA_W] = data_i;
        pack_mask_with_new_w[lane_cnt] = 1'b1;
    end

    always_comb begin
        state_nxt = state;
        lane_cnt_nxt = lane_cnt;
        elem_cnt_nxt = elem_cnt;
        output_elements_nxt = output_elements_r;
        addr_cnt_nxt = addr_cnt;
        pack_data_nxt = pack_data;
        pack_mask_nxt = pack_mask;
        gb_ao_wr_valid_nxt = 1'b0;
        gb_ao_wr_addr_nxt = gb_ao_wr_addr_o;
        gb_ao_wr_data_nxt = gb_ao_wr_data_o;
        gb_ao_wr_mask_nxt = gb_ao_wr_mask_o;
        done_nxt = 1'b0;

        case (state)
            IDLE: begin
                lane_cnt_nxt = '0;
                elem_cnt_nxt = '0;
                pack_data_nxt = '0;
                pack_mask_nxt = '0;
                if (start_i) begin
                    addr_cnt_nxt = out_base_addr_i;
                    output_elements_nxt = output_elements_i;
                    if (output_elements_i == '0) begin
                        done_nxt = 1'b1;
                    end else begin
                        state_nxt = PACK;
                    end
                end
            end

            PACK: begin
                if (accept_w) begin
                    elem_cnt_nxt = elem_cnt + ELEM_CNT_W'(1);
                    if (flush_w) begin
                        gb_ao_wr_valid_nxt = 1'b1;
                        gb_ao_wr_addr_nxt = addr_cnt;
                        gb_ao_wr_data_nxt = pack_data_with_new_w;
                        gb_ao_wr_mask_nxt = pack_mask_with_new_w;
                        addr_cnt_nxt = addr_cnt + GB_ADDR_W'(LANES);
                        lane_cnt_nxt = '0;
                        pack_data_nxt = '0;
                        pack_mask_nxt = '0;

                        if (last_elem_w) begin
                            state_nxt = IDLE;
                            done_nxt = 1'b1;
                        end
                    end else begin
                        lane_cnt_nxt = lane_cnt + LANE_CNT_W'(1);
                        pack_data_nxt = pack_data_with_new_w;
                        pack_mask_nxt = pack_mask_with_new_w;
                    end
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
            lane_cnt <= '0;
            elem_cnt <= '0;
            output_elements_r <= '0;
            addr_cnt <= '0;
            pack_data <= '0;
            pack_mask <= '0;
            gb_ao_wr_valid_o <= 1'b0;
            gb_ao_wr_addr_o <= '0;
            gb_ao_wr_data_o <= '0;
            gb_ao_wr_mask_o <= '0;
            done_o <= 1'b0;
        end else begin
            state <= state_nxt;
            lane_cnt <= lane_cnt_nxt;
            elem_cnt <= elem_cnt_nxt;
            output_elements_r <= output_elements_nxt;
            addr_cnt <= addr_cnt_nxt;
            pack_data <= pack_data_nxt;
            pack_mask <= pack_mask_nxt;
            gb_ao_wr_valid_o <= gb_ao_wr_valid_nxt;
            gb_ao_wr_addr_o <= gb_ao_wr_addr_nxt;
            gb_ao_wr_data_o <= gb_ao_wr_data_nxt;
            gb_ao_wr_mask_o <= gb_ao_wr_mask_nxt;
            done_o <= done_nxt;
        end
    end

    assign busy_o = (state != IDLE);

`ifndef SYNTHESIS
    initial begin
        if (GB_DATA_W % DATA_W != 0) begin
            $fatal(1, "spatial_pack_writeback requires GB_DATA_W to be a multiple of DATA_W");
        end
    end
`endif
endmodule
