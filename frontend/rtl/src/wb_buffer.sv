module wb_buffer #(
        parameter int ROW = 14,
        parameter int COL = 16,
        parameter int DATA_IN_W = 8,
        parameter int DATA_OUT_W = 128,

        localparam ADDR_W = (ROW <= 1)? 1: $clog2(ROW)
    ) (
        input           aclk,
        input           aresetn,

        input           wr_en_i,
        input  logic signed [DATA_IN_W-1:0]  data_i  [ROW][COL],

        input          [ADDR_W-1:0]          rd_addr_i,
        output logic signed [DATA_OUT_W-1:0] data_o

    );
    //If we always set the COL to 16, then the BUFF_D = ROW
    // localparam BUFF_D = COL*ROW*DATA_IN_W/DATA_OUT_W;
    localparam BUFF_D = ROW; //here we assume the COL must be 16

    logic   [DATA_OUT_W-1:0]    out_buff       [BUFF_D];
    logic   [ADDR_W-1:0]        rd_addr_r;

    always_ff @(posedge aclk) begin
        if(!aresetn) begin
            for (int r  = 0; r < BUFF_D ; r++) begin
                out_buff[r] <= '0;
            end
        end
        else begin
            if (wr_en_i) begin
                for (int r = 0;r<BUFF_D ;r++ ) begin
                    for (int c = 0 ; c<COL; c++ ) begin
                        out_buff[r][c*DATA_IN_W +: DATA_IN_W] <= data_i[r][c];
                    end
                end
            end
        end
    end

    always_ff @(posedge aclk) begin
        if(!aresetn) begin
            rd_addr_r <= '0;
        end
        else begin
            rd_addr_r <= rd_addr_i;
        end
    end
    assign data_o = out_buff[rd_addr_r];

endmodule
