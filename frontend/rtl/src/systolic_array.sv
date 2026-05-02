module systolic_array #(
    parameter ROW = 2,
    parameter COL = 2,
    parameter INTX = 8,
    parameter int ACC_W = 32
) (
    input       logic clk,
    input       logic rst_n,

    // Global PE enable. When en=0, the PE holds all registers.
    input       logic en_i,
    input       logic row_first_i [ROW],
    input       logic col_first_i [COL],

    input       logic signed [INTX-1:0]  row_i [ROW],
    input       logic                    row_valid_i [ROW],
    input       logic signed [INTX-1:0]  col_i [COL],
    input       logic                    col_valid_i [COL],
    

    output      logic                    valid_o [ROW][COL],
    output      logic signed [ACC_W-1:0] mac_o [ROW][COL]
);
    // the wire to connect each PE
    logic signed [INTX-1:0] act_bus [ROW][COL+1];
    logic signed [INTX-1:0] wgt_bus [ROW+1][COL];

    logic act_valid_bus [ROW][COL+1];
    logic wgt_valid_bus [ROW+1][COL];
    logic act_first_bus [ROW][COL+1];
    logic wgt_first_bus [ROW+1][COL];

    generate
        for (genvar i = 0; i < ROW; i=i+1) begin : GEN_ACT_BOUNDARY
            assign act_bus[i][0]       = row_i[i];
            assign act_valid_bus[i][0] = row_valid_i[i];
            assign act_first_bus[i][0] = row_first_i[i];
        end

        for (genvar j = 0; j < COL; j=j+1) begin : GEN_WGT_BOUNDARY
            assign wgt_bus[0][j]       = col_i[j];
            assign wgt_valid_bus[0][j] = col_valid_i[j];
            assign wgt_first_bus[0][j] = col_first_i[j];
        end
    endgenerate

    // Generate the PE
    generate 
        for (genvar i = 0; i < ROW ; i= i+1 ) begin : GEN_PE_ROW
            for (genvar j = 0; j < COL ; j= j+1 ) begin : GEN_PE_COL

                pe_os #(
                    .ACT_W 	(INTX),
                    .WGT_W 	(INTX),
                    .ACC_W 	(ACC_W))
                u_pe(
                    .clk           	(clk            ),
                    .rst_n         	(rst_n          ),
                    .en            	(en_i            ),
                    .act_in        	(act_bus[i][j]),
                    .act_valid_in  	(act_valid_bus[i][j]),
                    .act_first_in  	(act_first_bus[i][j]   ),
                    .wgt_in        	(wgt_bus[i][j]),
                    .wgt_valid_in  	(wgt_valid_bus[i][j]),
                    .wgt_first_in  	(wgt_first_bus[i][j]   ),
                    .act_out       	(act_bus[i][j+1]),
                    .act_valid_out 	(act_valid_bus[i][j+1]),
                    .act_first_out 	(act_first_bus[i][j+1]  ),
                    .wgt_out       	(wgt_bus[i+1][j]),
                    .wgt_valid_out 	(wgt_valid_bus[i+1][j]),
                    .wgt_first_out 	(wgt_first_bus[i+1][j]  ),
                    .psum_out      	(mac_o[i][j]       ),
                    .mac_valid_out 	(valid_o[i][j]  )
                );
                
            end
        end
    endgenerate
    
    
    
endmodule
