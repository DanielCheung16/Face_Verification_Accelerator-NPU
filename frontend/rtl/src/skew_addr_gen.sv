module skew_addr_gen #(
    parameter int ROW      = 14,
    parameter int COL      = 16,
    parameter int K_MAX    = 512,
    parameter int COUNT_W  = 16,
    parameter int K_ADDR_W = (K_MAX <= 1) ? 1 : $clog2(K_MAX)
)(
    // Runtime Channel dimension.
    // Valid range: 1 ... K_MAX.
    input  logic [K_ADDR_W:0]  k_size_i,
    // Current feeding cycle from controller.
    input  logic [COUNT_W-1:0] feed_cycle_i,

    // Optional global enable from controller.
    // If 0, all valid/first outputs are suppressed.
    input  logic               feed_valid_i,

    // Activation side: one request per array row.
    output logic [K_ADDR_W-1:0] act_rd_idx_o   [ROW],
    output logic                act_rd_valid_o [ROW],
    output logic                act_first_o    [ROW],

    // Weight side: one request per array column.
    output logic [K_ADDR_W-1:0] wgt_rd_idx_o   [COL],
    output logic                wgt_rd_valid_o [COL],
    output logic                wgt_first_o    [COL]
);

    always_comb begin
        for (int r = 0; r < ROW; r = r+1) begin
            act_rd_idx_o[r]   = '0;
            act_rd_valid_o[r] = 1'b0;
            act_first_o[r]    = 1'b0;

            if (feed_valid_i) begin
                if ((feed_cycle_i >= r) && ((feed_cycle_i - r) < k_size_i)) begin
                    act_rd_idx_o[r]   = feed_cycle_i - r;
                    act_rd_valid_o[r] = 1'b1;
                    act_first_o[r]    = ((feed_cycle_i - r) == 0);
                end
            end
        end

        for (int c = 0; c < COL; c = c+1) begin
            wgt_rd_idx_o[c]   = '0;
            wgt_rd_valid_o[c] = 1'b0;
            wgt_first_o[c]    = 1'b0;

            if (feed_valid_i) begin
                if ((feed_cycle_i >= c) && ((feed_cycle_i - c) < k_size_i)) begin

                    wgt_rd_idx_o[c]   = feed_cycle_i - c;
                    wgt_rd_valid_o[c] = 1'b1;
                    wgt_first_o[c]    = ((feed_cycle_i - c) == 0);
                end
            end
        end
    end

endmodule
