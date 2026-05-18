module gdconv7x7_top #(
    parameter int DATA_W       = 8,
    parameter int ACC_W        = 32,
    parameter int BIAS_W       = 64,
    parameter int OUT_W        = 8,
    parameter int MULT_W       = 32,
    parameter int SHIFT_W      = 6,
    parameter int GB_DATA_W    = 128,
    parameter int GB_ADDR_W    = 16,
    parameter int PARAM_ADDR_W = 16,
    parameter int CHANNELS     = 512,
    parameter int KERNEL_ELEMS = 49,
    parameter int ELEM_CNT_W   = 10,

    localparam int CHANNEL_W = (CHANNELS <= 1) ? 1 : $clog2(CHANNELS),
    localparam int AO_MASK_W = GB_DATA_W / DATA_W
) (
    input  logic clk,
    input  logic rst_n,
    input  logic run_en_i,

    input  logic start_i,
    output logic busy_o,
    output logic done_o,

    input  logic [GB_ADDR_W-1:0] act_base_addr_i,
    input  logic [GB_ADDR_W-1:0] wgt_base_addr_i,
    input  logic [GB_ADDR_W-1:0] out_base_addr_i,
    input  logic signed [OUT_W-1:0] output_zero_point_i,
    input  logic [PARAM_ADDR_W-1:0] common_param_base_i,

    output logic                 gb_act_rd_valid_o,
    output logic [GB_ADDR_W-1:0] gb_act_rd_addr_o,
    input  logic [GB_DATA_W-1:0] gb_act_rd_data_i,

    output logic                 gb_wgt_rd_valid_o,
    output logic [GB_ADDR_W-1:0] gb_wgt_rd_addr_o,
    input  logic [GB_DATA_W-1:0] gb_wgt_rd_data_i,

    output logic                 gb_ao_wr_valid_o,
    output logic [GB_ADDR_W-1:0] gb_ao_wr_addr_o,
    output logic [GB_DATA_W-1:0] gb_ao_wr_data_o,
    output logic [AO_MASK_W-1:0] gb_ao_wr_mask_o,

    output logic                    quant_common_rd_en_o,
    output logic [PARAM_ADDR_W-1:0] quant_common_rd_addr_o,
    input  logic                    quant_common_rd_valid_i,
    input  logic signed [BIAS_W-1:0] quant_param_bias_i,
    input  logic signed [MULT_W-1:0] quant_param_requant_multiplier_i,
    input  logic [SHIFT_W-1:0]       quant_param_requant_shift_i
);
    logic core_busy;
    logic core_done;
    logic core_psum_valid;
    logic [CHANNEL_W-1:0] core_psum_channel;
    logic signed [ACC_W-1:0] core_psum;

    logic sched_valid;
    logic [CHANNEL_W-1:0] sched_channel;
    logic signed [ACC_W-1:0] sched_psum;
    logic signed [BIAS_W-1:0] sched_bias;
    logic signed [MULT_W-1:0] sched_multiplier;
    logic [SHIFT_W-1:0] sched_shift;

    logic wb_busy;
    logic wb_done;

    assign busy_o = core_busy || wb_busy;
    assign done_o = wb_done;

    // Core reads the 7x7xC activation/weight streams and emits one psum per
    // output channel. It does not own quantization or writeback.
    gdconv7x7_core #(
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .GB_DATA_W(GB_DATA_W),
        .GB_ADDR_W(GB_ADDR_W),
        .CHANNELS(CHANNELS),
        .KERNEL_ELEMS(KERNEL_ELEMS)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .start_i(start_i),
        .busy_o(core_busy),
        .done_o(core_done),
        .act_base_addr_i(act_base_addr_i),
        .wgt_base_addr_i(wgt_base_addr_i),
        .gb_act_rd_valid_o(gb_act_rd_valid_o),
        .gb_act_rd_addr_o(gb_act_rd_addr_o),
        .gb_act_rd_data_i(gb_act_rd_data_i),
        .gb_wgt_rd_valid_o(gb_wgt_rd_valid_o),
        .gb_wgt_rd_addr_o(gb_wgt_rd_addr_o),
        .gb_wgt_rd_data_i(gb_wgt_rd_data_i),
        .psum_valid_o(core_psum_valid),
        .psum_channel_o(core_psum_channel),
        .psum_o(core_psum)
    );

    // One common quant parameter tuple is read per output channel. The global
    // quant_param_mem has one-cycle latency, so the scheduler delays psum data.
    gdconv7x7_param_scheduler #(
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .MUL_W(MULT_W),
        .SHIFT_W(SHIFT_W),
        .PARAM_ADDR_W(PARAM_ADDR_W),
        .CHANNELS(CHANNELS)
    ) u_param_scheduler (
        .clk(clk),
        .rst_n(rst_n),
        .start_i(start_i),
        .common_param_base_i(common_param_base_i),
        .psum_valid_i(core_psum_valid),
        .psum_channel_i(core_psum_channel),
        .psum_i(core_psum),
        .common_rd_en_o(quant_common_rd_en_o),
        .common_rd_addr_o(quant_common_rd_addr_o),
        .common_rd_valid_i(quant_common_rd_valid_i),
        .param_bias_i(quant_param_bias_i),
        .param_requant_multiplier_i(quant_param_requant_multiplier_i),
        .param_requant_shift_i(quant_param_requant_shift_i),
        .valid_o(sched_valid),
        .channel_o(sched_channel),
        .psum_o(sched_psum),
        .bias_o(sched_bias),
        .requant_multiplier_o(sched_multiplier),
        .requant_shift_o(sched_shift)
    );

    // Fixed gdconv7x7 postprocess: bias + requant + int8 clamp, then HWC 128-bit
    // packing. The FC layer reads these words sequentially from out_base_addr_i.
    gdconv7x7_wb #(
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .DATA_W(DATA_W),
        .GB_DATA_W(GB_DATA_W),
        .GB_ADDR_W(GB_ADDR_W),
        .ELEM_CNT_W(ELEM_CNT_W),
        .MUL_W(MULT_W),
        .SHIFT_W(SHIFT_W)
    ) u_wb (
        .clk(clk),
        .rst_n(rst_n),
        .start_i(start_i),
        .out_base_addr_i(out_base_addr_i),
        .output_elements_i(ELEM_CNT_W'(CHANNELS)),
        .output_zero_point_i(ACC_W'($signed(output_zero_point_i))),
        .psum_i(sched_psum),
        .valid_i(sched_valid),
        .bias_i(sched_bias),
        .requant_multiplier_i(sched_multiplier),
        .requant_shift_i(sched_shift),
        .gb_ao_wr_valid_o(gb_ao_wr_valid_o),
        .gb_ao_wr_addr_o(gb_ao_wr_addr_o),
        .gb_ao_wr_data_o(gb_ao_wr_data_o),
        .gb_ao_wr_mask_o(gb_ao_wr_mask_o),
        .busy_o(wb_busy),
        .done_o(wb_done)
    );

endmodule
