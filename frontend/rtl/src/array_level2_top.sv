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
    // write buf: Simple preload/write interface
    input  logic                        wr_en_i     [BUF_NUM],
    input  logic [BANK_ADDR_W-1:0]      wr_bank_i   [BUF_NUM],
    input  logic [K_ADDR_W-1:0]         wr_idx_i    [BUF_NUM],
    input  logic signed [DATA_W-1:0]    wr_data_i   [BUF_NUM],
    // To config this layer's Channel Length:
    input  logic [K_ADDR_W : 0]         k_size_i,

    input  logic                        start_i,
    output logic                        done_o,
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

    assign done_o = done_r;
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
        .wr_en_i    	(wr_en_i[0]),
        .wr_bank_i  	(wr_bank_i[0]),
        .wr_idx_i   	(wr_idx_i[0]),
        .wr_data_i  	(wr_data_i[0])
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
        .wr_en_i    	(wr_en_i[1]),
        .wr_bank_i  	(wr_bank_i[1]),
        .wr_idx_i   	(wr_idx_i[1]),
        .wr_data_i  	(wr_data_i[1])
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
        .en_i        	(array_en_r),
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
        act_rd_valid_r  <= act_rd_valid;
        wgt_rd_valid_r  <= wgt_rd_valid;
        act_first_r     <= act_first_w;
        wgt_first_r     <= wgt_first_w;
        array_en_r      <= array_en_w;
        done_r          <= done_w;
    end
end

//Extra control logic: （For Decoupling so we can implement outside the 'array_level2_top') 
//  1.Guarantee Receive the done signal then store/push them into output buffer/LeRu
//  2.Then can begin next tile calculation (assert start signal)

endmodule
