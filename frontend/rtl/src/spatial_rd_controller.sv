module spatial_rd_controller #(
    parameter int ACT_DEPTH = 1,
    parameter int WGT_DEPTH = 32,   // 32 * 128 bits = 512 bytes per kernel position

    localparam int LANES = 16,
    localparam int LANE_CNT_W = $clog2(LANES),
    localparam int ACT_BYTE_DEPTH = LANES * ACT_DEPTH,
    localparam int ACT_RD_ADDR_W = (ACT_BYTE_DEPTH <= 1) ? 1 : $clog2(ACT_BYTE_DEPTH),
    localparam int WGT_BYTE_DEPTH = LANES * WGT_DEPTH,
    localparam int WGT_RD_ADDR_W = (WGT_BYTE_DEPTH <= 1) ? 1 : $clog2(WGT_BYTE_DEPTH)
) (    
    input  logic clk,
    input  logic rst_n,

    //system control signals
    input  logic layer_start_i,          //should be one pulse
    input  logic [WGT_RD_ADDR_W:0] current_num_filter_i,
        //refers to the number of current layer's filter
        //current_num_filter = ic*oc (for traditional conv3x3)
        //current_num_filter = ic = oc (for DWconv3x3)
        //this is a count, not the last address

    //control signals face to buffer
    input  logic window_loaded_i,      //the ifmap is ready
    input  logic weights_loaded_i,     //one filter tile is ready
    input  logic all_weights_loaded_i, //all weights are stored in the local spatial buffer

    output logic rd_en_o,              //should read the act and wgt buffer simutaniously
    //act buffer
    output logic [ACT_RD_ADDR_W-1:0] rd_addr_act_o,
    //wgt buffer
    output logic [WGT_RD_ADDR_W-1:0] rd_addr_wgt_o,

    //control signals face to outer controller
    output logic read_busy_o,
    output logic read_done_o,          //one pulse when the 16-read command burst finishes
    output logic filter_round_done_o   //one pulse when weight read address wraps to zero
);
    typedef enum logic [1:0] {
        IDLE,
        WAIT_READY,
        READ_TILE
    } state_t;

    state_t state, state_nxt;

    logic [LANE_CNT_W-1:0] lane_cnt, lane_cnt_nxt;
    logic [WGT_RD_ADDR_W-1:0] wgt_rd_cnt, wgt_rd_cnt_nxt;

    logic rd_en_nxt;
    logic [ACT_RD_ADDR_W-1:0] rd_addr_act_nxt;
    logic [WGT_RD_ADDR_W-1:0] rd_addr_wgt_nxt;

    logic last_lane;
    logic weight_ready;
    logic weight_ready_used, weight_ready_used_nxt;
    logic wgt_wrap;

    assign last_lane = (lane_cnt == LANE_CNT_W'(LANES - 1));
    assign weight_ready = all_weights_loaded_i || (weights_loaded_i && !weight_ready_used);

    always_comb begin
        if (current_num_filter_i <= {{WGT_RD_ADDR_W{1'b0}}, 1'b1}) begin
            wgt_wrap = 1'b1;
        end else begin
            wgt_wrap = ({1'b0, wgt_rd_cnt} == (current_num_filter_i - {{WGT_RD_ADDR_W{1'b0}}, 1'b1}));
        end
    end

    // 2-stage FSM:
    //   WAIT_READY checks that the current activation window and weight tile
    //   are safe to read.
    //   READ_TILE issues exactly 16 byte reads. Ready inputs are not re-sampled
    //   during this burst, so preload may start preparing the next tile.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            lane_cnt <= '0;
            wgt_rd_cnt <= '0;
            weight_ready_used <= 1'b0;
            rd_en_o <= 1'b0;
            rd_addr_act_o <= '0;
            rd_addr_wgt_o <= '0;
            read_busy_o <= 1'b0;
            read_done_o <= 1'b0;
            filter_round_done_o <= 1'b0;
        end else begin
            state <= state_nxt;
            lane_cnt <= lane_cnt_nxt;
            wgt_rd_cnt <= wgt_rd_cnt_nxt;
            weight_ready_used <= weight_ready_used_nxt;
            rd_en_o <= rd_en_nxt;
            rd_addr_act_o <= rd_addr_act_nxt;
            rd_addr_wgt_o <= rd_addr_wgt_nxt;

            read_busy_o <= (state_nxt != IDLE);
            read_done_o <= rd_en_o && (rd_addr_act_o == ACT_RD_ADDR_W'(LANES - 1));
            if (current_num_filter_i <= {{WGT_RD_ADDR_W{1'b0}}, 1'b1}) begin
                filter_round_done_o <= rd_en_o;
            end else begin
                filter_round_done_o <= rd_en_o &&
                                       ({1'b0, rd_addr_wgt_o} == (current_num_filter_i - {{WGT_RD_ADDR_W{1'b0}}, 1'b1}));
            end
        end
    end
    
    always_comb begin
        state_nxt = state;
        lane_cnt_nxt = lane_cnt;
        wgt_rd_cnt_nxt = wgt_rd_cnt;
        weight_ready_used_nxt = weight_ready_used;
        rd_en_nxt = 1'b0;
        rd_addr_act_nxt = rd_addr_act_o;
        rd_addr_wgt_nxt = rd_addr_wgt_o;

        if (!weights_loaded_i) begin
            weight_ready_used_nxt = 1'b0;
        end

        case (state)
            IDLE: begin
                lane_cnt_nxt = '0;
                if (layer_start_i) begin
                    wgt_rd_cnt_nxt = '0;
                    weight_ready_used_nxt = 1'b0;
                    state_nxt = WAIT_READY;
                end
            end

            WAIT_READY: begin
                lane_cnt_nxt = '0;
                if (window_loaded_i && weight_ready) begin
                    if (!all_weights_loaded_i) begin
                        weight_ready_used_nxt = 1'b1;
                    end
                    state_nxt = READ_TILE;
                end
            end

            READ_TILE: begin
                rd_en_nxt = 1'b1;
                rd_addr_act_nxt = ACT_RD_ADDR_W'(lane_cnt);
                rd_addr_wgt_nxt = wgt_rd_cnt;

                if (wgt_wrap) begin
                    wgt_rd_cnt_nxt = '0;
                end else begin
                    wgt_rd_cnt_nxt = wgt_rd_cnt + WGT_RD_ADDR_W'(1);
                end

                if (last_lane) begin
                    lane_cnt_nxt = '0;
                    state_nxt = WAIT_READY;
                end else begin
                    lane_cnt_nxt = lane_cnt + LANE_CNT_W'(1);
                end
            end

            default: begin
                state_nxt = IDLE;
            end
        endcase
    end

`ifndef SYNTHESIS
    initial begin
        if (LANES != 16) begin
            $fatal(1, "spatial_rd_controller currently assumes 16 lanes per 128-bit word");
        end
        if (ACT_BYTE_DEPTH < LANES) begin
            $fatal(1, "spatial_rd_controller requires ACT_BYTE_DEPTH >= 16");
        end
        if (WGT_BYTE_DEPTH < LANES) begin
            $fatal(1, "spatial_rd_controller requires WGT_BYTE_DEPTH >= 16");
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n && layer_start_i) begin
            if (current_num_filter_i == '0) begin
                $fatal(1, "spatial_rd_controller current_num_filter_i must be non-zero");
            end
            if (current_num_filter_i > (WGT_RD_ADDR_W+1)'(WGT_BYTE_DEPTH)) begin
                $fatal(1, "spatial_rd_controller current_num_filter_i exceeds WGT_BYTE_DEPTH");
            end
        end
    end
`endif
endmodule
