module pe_os #(
    parameter int ACT_W = 8,
    parameter int WGT_W = 8,
    parameter int ACC_W = 32
)(
    input  logic clk,
    input  logic rst_n,
    // Global PE enable. When en=0, the PE holds all registers.
    input  logic en,

    // Activation stream from west side.
    input  logic signed [ACT_W-1:0] act_in,
    input  logic                    act_valid_in,
    input  logic                    act_first_in,

    // Weight stream from north side.
    input  logic signed [WGT_W-1:0] wgt_in,
    input  logic                    wgt_valid_in,
    input  logic                    wgt_first_in,

    // Activation forwarded to east side.
    output logic signed [ACT_W-1:0] act_out,
    output logic                    act_valid_out,
    output logic                    act_first_out,

    // Weight forwarded to south side.
    output logic signed [WGT_W-1:0] wgt_out,
    output logic                    wgt_valid_out,
    output logic                    wgt_first_out,

    // Local accumulated partial sum.
    output logic signed [ACC_W-1:0] psum_out,
    output logic                    mac_valid_out
);

    localparam int MUL_W = ACT_W + WGT_W;

    logic signed [MUL_W-1:0] product;
    logic signed [ACC_W-1:0] product_ext;
    logic                    mac_valid;
    logic                    mac_first;         //initialization for different slices of the whole array

    //calculate the MUL
    assign product     = act_in * wgt_in;
    assign product_ext = {{(ACC_W-MUL_W){product[MUL_W-1]}}, product};

    assign mac_valid = act_valid_in && wgt_valid_in;
    assign mac_first = mac_valid && act_first_in && wgt_first_in;


    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_out        <= '0;
            act_valid_out  <= 1'b0;
            act_first_out  <= 1'b0;

            wgt_out        <= '0;
            wgt_valid_out  <= 1'b0;
            wgt_first_out  <= 1'b0;

            psum_out       <= '0;
            mac_valid_out  <= 1'b0;
        end else if (en) begin
            // Systolic data movement.
            act_out        <= act_in;
            act_valid_out  <= act_valid_in;
            act_first_out  <= act_first_in;

            wgt_out        <= wgt_in;
            wgt_valid_out  <= wgt_valid_in;
            wgt_first_out  <= wgt_first_in;

            mac_valid_out  <= mac_valid;
            
            // Output-stationary accumulation.
            if (mac_first) begin
                psum_out <= product_ext;
            end else if (mac_valid) begin
                psum_out <= psum_out + product_ext;
            end
        end
    end
endmodule
