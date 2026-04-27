// ==============================================================================
// Module: mfn_sliding_window
// Description: Random access 3x3 pixel buffer for CNN.
//              Controller loads 9 pixels sequentially to fill this buffer.
// ==============================================================================

module mfn_sliding_window #(
    parameter int DWIDTH = 16
)(
    input  logic                            clk,
    input  logic                            rst_n,
    
    input  logic                            clear,    // Clear all registers
    input  logic                            load_en,  // Load a single pixel
    input  logic [3:0]                      load_idx, // Which index to load (0-8)
    input  logic signed [DWIDTH-1:0]        pixel_in,
    
    output logic signed [DWIDTH-1:0]        window_out [0:8]
);

    logic signed [DWIDTH-1:0] win_reg [0:8];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 9; i++) win_reg[i] <= '0;
        end else if (clear) begin
            for (int i = 0; i < 9; i++) win_reg[i] <= '0;
        end else if (load_en) begin
            if (load_idx < 9) begin
                win_reg[load_idx] <= pixel_in;
            end
        end
    end

    assign window_out = win_reg;

endmodule
