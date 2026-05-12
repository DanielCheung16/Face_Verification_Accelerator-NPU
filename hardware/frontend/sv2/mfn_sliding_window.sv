// ==============================================================================
// Module: mfn_sliding_window (v2)
// v2 adds load_all / pixels_all_in for parallel 9-pixel wide-mode loading.
// Original sequential load_en / load_idx path unchanged.
// ==============================================================================

module mfn_sliding_window #(
    parameter int DWIDTH = 16
)(
    input  logic                            clk,
    input  logic                            rst_n,

    input  logic                            clear,
    input  logic                            load_en,   // single-pixel load
    input  logic [3:0]                      load_idx,
    input  logic signed [DWIDTH-1:0]        pixel_in,

    // v2: wide-mode parallel load (all 9 simultaneously)
    input  logic                            load_all,
    input  logic signed [DWIDTH-1:0]        pixels_all_in [0:8],

    output logic signed [DWIDTH-1:0]        window_out [0:8]
);

    logic signed [DWIDTH-1:0] win_reg [0:8];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 9; i++) win_reg[i] <= '0;
        end else if (clear) begin
            for (int i = 0; i < 9; i++) win_reg[i] <= '0;
        end else if (load_all) begin
            for (int i = 0; i < 9; i++) win_reg[i] <= pixels_all_in[i];
        end else if (load_en) begin
            if (load_idx < 4'd9)
                win_reg[load_idx] <= pixel_in;
        end
    end

    assign window_out = win_reg;

endmodule
