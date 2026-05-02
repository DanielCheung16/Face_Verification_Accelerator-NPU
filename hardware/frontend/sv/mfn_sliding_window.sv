// ==============================================================================
// Module: mfn_sliding_window
// Description: Line Buffer for CNN 3x3 Sliding Window.
//              Buffers 2 rows of the image to output a parallel 3x3 window.
//              Follows Two-Process Methodology.
// ==============================================================================

module mfn_sliding_window #(
    parameter int DWIDTH    = 16,
    parameter int MAX_WIDTH = 96 // Max Image Width (MobileFaceNet input is 112x96)
)(
    input  logic                            clk,
    input  logic                            rst_n,
    
    input  logic                            valid_in,
    input  logic signed [DWIDTH-1:0]        pixel_in,
    
    output logic                            valid_out,
    output logic signed [DWIDTH-1:0]        window_out [0:8] // 3x3 Window (0=TopLeft, 8=BottomRight)
);

    // --------------------------------------------------------------------------
    // Registers & Next-State Signals (Two-Process Methodology)
    // --------------------------------------------------------------------------
    // 2 Line Buffers (Shift Registers)
    logic signed [DWIDTH-1:0] line_buf_0_reg [0:MAX_WIDTH-1];
    logic signed [DWIDTH-1:0] line_buf_1_reg [0:MAX_WIDTH-1];
    logic signed [DWIDTH-1:0] line_buf_0_next [0:MAX_WIDTH-1];
    logic signed [DWIDTH-1:0] line_buf_1_next [0:MAX_WIDTH-1];

    // 3x3 Window Shift Register
    logic signed [DWIDTH-1:0] win_reg [0:8];
    logic signed [DWIDTH-1:0] win_next [0:8];
    
    logic valid_reg, valid_next;

    // --------------------------------------------------------------------------
    // Process 1: Combinational Logic (Next State & Datapath)
    // --------------------------------------------------------------------------
    always_comb begin
        // Default assignment: hold state
        for (int i = 0; i < MAX_WIDTH; i++) begin
            line_buf_0_next[i] = line_buf_0_reg[i];
            line_buf_1_next[i] = line_buf_1_reg[i];
        end
        for (int i = 0; i < 9; i++) begin
            win_next[i] = win_reg[i];
        end
        
        valid_next = valid_in;

        if (valid_in) begin
            // 1. Shift Line Buffers
            for (int i = MAX_WIDTH-1; i > 0; i--) begin
                line_buf_0_next[i] = line_buf_0_reg[i-1];
                line_buf_1_next[i] = line_buf_1_reg[i-1];
            end
            
            // New pixel enters line_buf_0
            line_buf_0_next[0] = pixel_in;
            // The pixel falling off line_buf_0 enters line_buf_1
            line_buf_1_next[0] = line_buf_0_reg[MAX_WIDTH-1];
            
            // 2. Update 3x3 Window
            // Row 0 (Top)
            win_next[0] = win_reg[1];
            win_next[1] = win_reg[2];
            win_next[2] = line_buf_1_reg[MAX_WIDTH-1]; // Oldest from buf 1
            
            // Row 1 (Middle)
            win_next[3] = win_reg[4];
            win_next[4] = win_reg[5];
            win_next[5] = line_buf_0_reg[MAX_WIDTH-1]; // Oldest from buf 0
            
            // Row 2 (Bottom)
            win_next[6] = win_reg[7];
            win_next[7] = win_reg[8];
            win_next[8] = pixel_in;                    // Newest incoming pixel
        end
    end

    // --------------------------------------------------------------------------
    // Process 2: Sequential Logic (Update Registers)
    // --------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < MAX_WIDTH; i++) begin
                line_buf_0_reg[i] <= '0;
                line_buf_1_reg[i] <= '0;
            end
            for (int i = 0; i < 9; i++) begin
                win_reg[i] <= '0;
            end
            valid_reg <= 1'b0;
        end else begin
            for (int i = 0; i < MAX_WIDTH; i++) begin
                line_buf_0_reg[i] <= line_buf_0_next[i];
                line_buf_1_reg[i] <= line_buf_1_next[i];
            end
            for (int i = 0; i < 9; i++) begin
                win_reg[i] <= win_next[i];
            end
            valid_reg <= valid_next;
        end
    end

    // --------------------------------------------------------------------------
    // Output Assignment
    // --------------------------------------------------------------------------
    assign window_out = win_reg;
    assign valid_out  = valid_reg;

endmodule
