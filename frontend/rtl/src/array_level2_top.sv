//------------------------------------------------------------------
//The parameter: COUNT_W's length depends on k_size_i + COL +ROW
//               but as the k_size varys, the COUNT_W should cover
//               [0,K_MAX + COL + ROW]
//------------------------------------------------------------------
module array_level2_top #(
    parameter int ROW      = 14,
    parameter int COL      = 16,
    parameter int K_MAX    = 512,
    parameter int COUNT_W  = 16,
    parameter int K_ADDR_W = (K_MAX <= 1) ? 1 : $clog2(K_MAX),
    parameter int DATA_W   = 8,
    parameter int ACC_W    = 32,
    parameter int BUF_NUM  = 2,

    localparam int MAX_RC = (ROW > COL) ? ROW : COL,
    localparam int BANK_ADDR_W = (MAX_RC <= 1) ? 1 : $clog2(MAX_RC)
) (
    input logic             clk,
    input logic             rst_n,
    input logic             run_en_i,
    input logic             use_loader_i,
    input logic             loader_start_i,
    // write buf: Simple preload/write interface
    input  logic                        wr_en_i     [BUF_NUM],
    input  logic [BANK_ADDR_W-1:0]      wr_bank_i   [BUF_NUM],
    input  logic [K_ADDR_W-1:0]         wr_idx_i    [BUF_NUM],
    input  logic signed [DATA_W-1:0]    wr_data_i   [BUF_NUM],
    // To config this layer's Channel Length:
    input  logic [K_ADDR_W : 0]         k_size_i,
    input  logic [15:0]                 m_size_i,
    input  logic [15:0]                 n_size_i,
    input  logic [15:0]                 row_base_i,
    input  logic [15:0]                 col_base_i,

    output logic                        gb_act_rd_valid_o,
    output logic [31:0]                 gb_act_rd_addr_o,
    input  logic signed [DATA_W-1:0]    gb_act_rd_data_i,

    output logic                        gb_wgt_rd_valid_o,
    output logic [31:0]                 gb_wgt_rd_addr_o,
    input  logic signed [DATA_W-1:0]    gb_wgt_rd_data_i,

    input  logic                        start_i,
    output logic                        done_o,
    output logic                        loader_busy_o,
    output logic                        loader_done_o,
    // Temperately no output manipulation (directly stream out)
    output      logic                    valid_o [ROW][COL],
    output      logic signed [ACC_W-1:0] mac_o [ROW][COL]
);
//----------------------interconnection wires------------------------
    logic [K_ADDR_W-1:0] act_rd_idx     [ROW];
    logic                act_rd_valid   [ROW];
    logic signed [DATA_W-1:0] act_data  [ROW];
    logic [K_ADDR_W-1:0] wgt_rd_idx     [COL];
    logic                wgt_rd_valid   [COL];
    logic signed [DATA_W-1:0] wgt_data  [COL];

    //counter of Channel:
    logic [COUNT_W-1:0]  feed_cycle;
    logic                feed_valid;

    //Valid and First signals to Systolic Array
    logic                act_rd_valid_r [ROW];
    logic                wgt_rd_valid_r [COL];
    logic                act_first_w    [ROW];
    logic                act_first_r    [ROW];
    logic                wgt_first_w    [COL];
    logic                wgt_first_r    [COL];

    //Timing alignment
    logic                array_en_w, array_en_r;
    logic                done_w;
    logic                done_r;
    logic                sa_valid [ROW][COL];

    logic                        loader_wr_en   [BUF_NUM];
    logic [BANK_ADDR_W-1:0]      loader_wr_bank [BUF_NUM];
    logic [K_ADDR_W-1:0]         loader_wr_idx  [BUF_NUM];
    logic signed [DATA_W-1:0]    loader_wr_data [BUF_NUM];

    logic                        buf_wr_en   [BUF_NUM];
    logic [BANK_ADDR_W-1:0]      buf_wr_bank [BUF_NUM];
    logic [K_ADDR_W-1:0]         buf_wr_idx  [BUF_NUM];
    logic signed [DATA_W-1:0]    buf_wr_data [BUF_NUM];

    assign done_o = done_r;

    always_comb begin
        for (int b = 0; b < BUF_NUM; b++) begin
            if (use_loader_i) begin
                buf_wr_en[b]   = loader_wr_en[b];
                buf_wr_bank[b] = loader_wr_bank[b];
                buf_wr_idx[b]  = loader_wr_idx[b];
                buf_wr_data[b] = loader_wr_data[b];
            end else begin
                buf_wr_en[b]   = wr_en_i[b];
                buf_wr_bank[b] = wr_bank_i[b];
                buf_wr_idx[b]  = wr_idx_i[b];
                buf_wr_data[b] = wr_data_i[b];
            end
        end
    end
//----------------------two input buffers----------------------------
    banked_input_buffer #(
        .BANK_NUM 	(ROW   ),
        .DATA_W   	(DATA_W  ),
        .K_MAX    	(K_MAX  ),
        .K_ADDR_W 	(K_ADDR_W))
    u_act_buf(
        .clk        	(clk            ),
        .rd_idx_i   	(act_rd_idx     ),
        .rd_valid_i 	(act_rd_valid   ),
        .rd_data_o  	(act_data),
        .wr_en_i    	(buf_wr_en[0]),
        .wr_bank_i  	(buf_wr_bank[0]),
        .wr_idx_i   	(buf_wr_idx[0]),
        .wr_data_i  	(buf_wr_data[0])
    );

    banked_input_buffer #(
        .BANK_NUM 	(COL   ),
        .DATA_W   	(DATA_W  ),
        .K_MAX    	(K_MAX  ),
        .K_ADDR_W 	(K_ADDR_W))
    u_wgt_buf(
        .clk        	(clk         ),
        .rd_idx_i   	(wgt_rd_idx ),
        .rd_valid_i 	(wgt_rd_valid),
        .rd_data_o  	(wgt_data),
        .wr_en_i    	(buf_wr_en[1]),
        .wr_bank_i  	(buf_wr_bank[1]),
        .wr_idx_i   	(buf_wr_idx[1]),
        .wr_data_i  	(buf_wr_data[1])
    );
//----------------------GEMM tile loader-----------------------------
    gemm_tile_loader #(
        .ROW      	(ROW),
        .COL      	(COL),
        .K_MAX    	(K_MAX),
        .DATA_W   	(DATA_W),
        .DIM_W    	(16),
        .GB_ADDR_W	(32),
        .BUF_NUM  	(BUF_NUM),
        .K_ADDR_W 	(K_ADDR_W))
    u_gemm_tile_loader(
        .clk                (clk),
        .rst_n              (rst_n),
        .start_i            (loader_start_i && use_loader_i),
        .run_en_i           (run_en_i),
        .busy_o             (loader_busy_o),
        .done_o             (loader_done_o),
        .m_size_i           (m_size_i),
        .k_size_i           (k_size_i),
        .n_size_i           (n_size_i),
        .row_base_i         (row_base_i),
        .col_base_i         (col_base_i),
        .gb_act_rd_valid_o  (gb_act_rd_valid_o),
        .gb_act_rd_addr_o   (gb_act_rd_addr_o),
        .gb_act_rd_data_i   (gb_act_rd_data_i),
        .gb_wgt_rd_valid_o  (gb_wgt_rd_valid_o),
        .gb_wgt_rd_addr_o   (gb_wgt_rd_addr_o),
        .gb_wgt_rd_data_i   (gb_wgt_rd_data_i),
        .wr_en_o            (loader_wr_en),
        .wr_bank_o          (loader_wr_bank),
        .wr_idx_o           (loader_wr_idx),
        .wr_data_o          (loader_wr_data)
    );
//----------------------Read Address generator-----------------------
    skew_addr_gen #(
        .ROW      	(ROW   ),
        .COL      	(COL   ),
        .K_MAX    	(K_MAX ),
        .COUNT_W  	(COUNT_W ),
        .K_ADDR_W 	(K_ADDR_W))
    u_skew_addr_gen(
        .k_size_i       	(k_size_i),
        .feed_cycle_i   	(feed_cycle),
        .feed_valid_i   	(feed_valid),
        .act_rd_idx_o   	(act_rd_idx),
        .act_rd_valid_o 	(act_rd_valid),
        .act_first_o    	(act_first_w),
        .wgt_rd_idx_o   	(wgt_rd_idx),
        .wgt_rd_valid_o 	(wgt_rd_valid),
        .wgt_first_o    	(wgt_first_w)
    );
//----------------Array's Working state Controller------------------- 
    array_controller #(
        .ROW      	(ROW    ),
        .COL      	(COL    ),
        .K_MAX    	(K_MAX  ),
        .COUNT_W  	(COUNT_W  ),
        .K_ADDR_W 	(K_ADDR_W))
    u_array_controller(
        .clk          	(clk           ),
        .rst_n        	(rst_n         ),
        .start_i      	(start_i),
        .run_en_i     	(run_en_i),
        .k_size_i     	(k_size_i),
        .feed_cycle_o 	(feed_cycle),
        .feed_valid_o 	(feed_valid),
        .array_en_o   	(array_en_w),
        .busy_o       	(        ),
        .done_o       	(done_w)
    );
    

//----------------------Systolic Array Tile--------------------------
    systolic_array #(
        .ROW   	(ROW),
        .COL   	(COL   ),
        .INTX  	(DATA_W),
        .ACC_W 	(ACC_W  ))
    u_SA(
        .clk         	(clk          ),
        .rst_n       	(rst_n        ),
        .en_i        	(array_en_r && run_en_i),
        .row_first_i 	(act_first_r),
        .row_i       	(act_data),
        .row_valid_i 	(act_rd_valid_r),
        .col_first_i 	(wgt_first_r),
        .col_i       	(wgt_data),
        .col_valid_i 	(wgt_rd_valid_r),
        .valid_o     	(sa_valid),
        .mac_o       	(mac_o)
    );

    generate
        for (genvar r = 0; r < ROW; r++) begin : GEN_RESULT_VALID_ROW
            for (genvar c = 0; c < COL; c++) begin : GEN_RESULT_VALID_COL
                assign valid_o[r][c] = done_r;
            end
        end
    endgenerate

//Delay the Valid and First signals from 'skew_addr_gen' 
//to compromize the delay of reading Buffer
always_ff @(posedge clk) begin
    if(!rst_n) begin
        for (int r = 0; r < ROW; r++) begin
            act_rd_valid_r[r] <= 1'b0;
            act_first_r[r]    <= 1'b0;
        end
        for (int c = 0; c < COL; c++) begin
            wgt_rd_valid_r[c] <= 1'b0;
            wgt_first_r[c]    <= 1'b0;
        end
        array_en_r      <= '0;
        done_r          <= '0;
    end else begin
        done_r          <= done_w;
        if (run_en_i) begin
        act_rd_valid_r  <= act_rd_valid;
        wgt_rd_valid_r  <= wgt_rd_valid;
        act_first_r     <= act_first_w;
        wgt_first_r     <= wgt_first_w;
        array_en_r      <= array_en_w;
        end
    end
end

//Extra control logic: （For Decoupling so we can implement outside the 'array_level2_top') 
//  1.Guarantee Receive the done signal then store/push them into output buffer/LeRu
//  2.Then can begin next tile calculation (assert start signal)

endmodule
