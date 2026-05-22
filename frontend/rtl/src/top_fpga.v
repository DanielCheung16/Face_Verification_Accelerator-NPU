module top_fpga #(
    parameter integer ROW = 14,
    parameter integer COL = 16,
    parameter integer K_MAX = 512,
    parameter integer DATA_W = 8,
    parameter integer GB_DATA_W = 128,
    parameter integer AO_DEPTH = 65536,
    parameter integer WGT_DEPTH = 65536,
    parameter integer SPATIAL_WGT_DEPTH = 32,
    parameter integer PARAM_DEPTH = 9792,

    parameter RAM_ROM_DIR = "ram_rom_inputs",
    parameter AO_INIT_FILE = "system_2_2_ao_init.mem",
    parameter WGT_INIT_FILE = "system_2_2_wgt_init.mem"
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire         ao_rd_en,
    input  wire [15:0]  ao_rd_addr,
    output wire [127:0] ao_rd_data,

    output wire         done,
    output wire         led_done
);
    localparam integer AO_ADDR_W = (AO_DEPTH <= 1) ? 1 : $clog2(AO_DEPTH);
    localparam integer WGT_ADDR_W = (WGT_DEPTH <= 1) ? 1 : $clog2(WGT_DEPTH);
    localparam integer AO_MASK_W = GB_DATA_W / DATA_W;
    localparam integer WGT_MASK_W = GB_DATA_W / DATA_W;

    (* ASYNC_REG = "TRUE" *) reg [1:0] rst_sync_r;
    (* ASYNC_REG = "TRUE" *) reg [1:0] start_sync_r;

    wire rst_sync_n;
    wire start_sync;

    reg sys_start_r;
    reg sys_done_seen_r;

    wire sys_done;
    wire final_valid_w;
    wire [127:0] final_vec_w;
    wire [GB_DATA_W-1:0] host_ao_rd_data;

    wire host_ao_wr_en;
    wire [AO_ADDR_W-1:0] host_ao_addr;
    wire [GB_DATA_W-1:0] host_ao_wr_data;
    wire [AO_MASK_W-1:0] host_ao_wr_mask;

    wire host_wgt_en;
    wire host_wgt_wr_en;
    wire [WGT_ADDR_W-1:0] host_wgt_addr;
    wire [GB_DATA_W-1:0] host_wgt_wr_data;
    wire [WGT_MASK_W-1:0] host_wgt_wr_mask;

    assign host_ao_rd_en = ao_rd_en && sys_done_seen_r;
    assign host_ao_wr_en = 1'b0;
    assign host_ao_addr = ao_rd_addr[AO_ADDR_W-1:0];
    assign host_ao_wr_data = {GB_DATA_W{1'b0}};
    assign host_ao_wr_mask = {AO_MASK_W{1'b0}};

    assign host_wgt_en = 1'b0;
    assign host_wgt_wr_en = 1'b0;
    assign host_wgt_addr = {WGT_ADDR_W{1'b0}};
    assign host_wgt_wr_data = {GB_DATA_W{1'b0}};
    assign host_wgt_wr_mask = {WGT_MASK_W{1'b0}};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_sync_r <= 2'b00;
        end else begin
            rst_sync_r <= {rst_sync_r[0], 1'b1};
        end
    end

    assign rst_sync_n = rst_sync_r[1];

    always @(posedge clk) begin
        if (!rst_sync_n) begin
            start_sync_r <= 2'b00;
            sys_start_r <= 1'b0;
            sys_done_seen_r <= 1'b0;
        end else begin
            start_sync_r <= {start_sync_r[0], start};

            if (!start_sync) begin
                sys_start_r <= 1'b0;
                sys_done_seen_r <= 1'b0;
            end else if (!sys_done_seen_r) begin
                sys_start_r <= 1'b1;
            end

            if (sys_done) begin
                sys_done_seen_r <= 1'b1;
            end
        end
    end

    assign start_sync = start_sync_r[1];

    top #(
        .ROW(ROW),
        .COL(COL),
        .K_MAX(K_MAX),
        .DATA_W(DATA_W),
        .GB_DATA_W(GB_DATA_W),
        .AO_DEPTH(AO_DEPTH),
        .WGT_DEPTH(WGT_DEPTH),
        .NUM_DEV(3),
        .MAX_LAYER(8),
        .LAYER_CONFIG_DEPTH(128),
        .AO_TRUE_DUAL_PORT(1'b0),
        .WGT_TRUE_DUAL_PORT(1'b0),
        .COMMON_PARAM_DEPTH(PARAM_DEPTH),
        .PRELU_PARAM_DEPTH(PARAM_DEPTH),
        .RESIDUAL_PARAM_DEPTH(PARAM_DEPTH),
        .SPATIAL_WGT_DEPTH(SPATIAL_WGT_DEPTH),
        .QUANT_BIAS_INIT_FILE({RAM_ROM_DIR, "/quant_param_bias.hex"}),
        .QUANT_REQUANT_MULT_INIT_FILE({RAM_ROM_DIR, "/quant_param_requant_mult.hex"}),
        .QUANT_REQUANT_SHIFT_INIT_FILE({RAM_ROM_DIR, "/quant_param_requant_shift.hex"}),
        .QUANT_PRELU_MULT_INIT_FILE({RAM_ROM_DIR, "/quant_param_prelu_mult.hex"}),
        .QUANT_PRELU_SHIFT_INIT_FILE({RAM_ROM_DIR, "/quant_param_prelu_shift.hex"}),
        .QUANT_RESIDUAL_MULT_INIT_FILE({RAM_ROM_DIR, "/quant_param_residual_mult.hex"}),
        .QUANT_RESIDUAL_SHIFT_INIT_FILE({RAM_ROM_DIR, "/quant_param_residual_shift.hex"}),
        .QUANT_RESIDUAL_ZERO_POINT_INIT_FILE({RAM_ROM_DIR, "/quant_param_residual_zero_point.hex"}),
        .LAYER_CONFIG_INIT_FILE({RAM_ROM_DIR, "/layer_config.hex"}),
        .AO_INIT_FILE({RAM_ROM_DIR, "/", AO_INIT_FILE}),
        .WGT_INIT_FILE({RAM_ROM_DIR, "/", WGT_INIT_FILE})
    ) u_top (
        .aclk(clk),
        .aresetn(rst_sync_n),
        .sys_start(sys_start_r),
        .sys_done(sys_done),
        .final_valid_o(final_valid_w),
        .final_vec_o(final_vec_w),
        .host_ao_rd_en_i(host_ao_rd_en),
        .host_ao_wr_en_i(host_ao_wr_en),
        .host_ao_addr_i(host_ao_addr),
        .host_ao_wr_data_i(host_ao_wr_data),
        .host_ao_wr_mask_i(host_ao_wr_mask),
        .host_ao_rd_data_o(host_ao_rd_data),
        .host_wgt_en_i(host_wgt_en),
        .host_wgt_wr_en_i(host_wgt_wr_en),
        .host_wgt_addr_i(host_wgt_addr),
        .host_wgt_wr_data_i(host_wgt_wr_data),
        .host_wgt_wr_mask_i(host_wgt_wr_mask),
        .host_wgt_rd_data_o()
    );

    assign done = sys_done_seen_r;
    assign ao_rd_data = host_ao_rd_data;
    assign led_done = sys_done_seen_r;

endmodule
