// ==============================================================================
// Module: mfn_addr_gen
// Description: Address Generator for SRAM buffers.
//              Uses coordinate accumulators to avoid expensive multipliers.
//              Follows Two-Process Methodology. Now includes padding logic.
// ==============================================================================

module mfn_addr_gen #(
    parameter int AWIDTH = 18 // Maximum SRAM Depth: 256K (sufficient for 172K words)
)(
    input  logic              clk,
    input  logic              rst_n,
    
    // Control signals from FSM
    input  logic              reset_ptr,    // Resets pointers to 0 at start of layer
    input  logic              inc_read,     // Increment SRAM Read Address
    input  logic              inc_write,    // Increment SRAM Write Address
    
    // Image dimensions from Config ROM
    input  logic [7:0]        img_width,
    input  logic [7:0]        img_height,

    // Output Addresses & Flags
    output logic [AWIDTH-1:0] sram_rd_addr,
    output logic [AWIDTH-1:0] sram_wr_addr,
    output logic              is_pad
);

    // --------------------------------------------------------------------------
    // Registers & Next-State Signals
    // --------------------------------------------------------------------------
    logic [AWIDTH-1:0] rd_reg, rd_next;
    logic [AWIDTH-1:0] wr_reg, wr_next;
    
    logic [7:0] x_reg, x_next;
    logic [7:0] y_reg, y_next;

    // --------------------------------------------------------------------------
    // Process 1: Combinational Logic
    // --------------------------------------------------------------------------
    always_comb begin
        if (reset_ptr) begin
            rd_next = '0;
            wr_next = '0;
            x_next  = '0;
            y_next  = '0;
            is_pad  = 1'b0;
        end else begin
            rd_next = rd_reg;
            wr_next = wr_reg;
            x_next  = x_reg;
            y_next  = y_reg;
            
            // If virtual coordinate is on the boundary (assuming 1-pixel padding)
            if (x_reg == 0 || x_reg == img_width + 1 || y_reg == 0 || y_reg == img_height + 1) begin
                is_pad = 1'b1;
            end else begin
                is_pad = 1'b0;
            end
            
            if (inc_read) begin
                // Only increment real SRAM read address if we are NOT reading a pad
                if (!is_pad) begin
                    rd_next = rd_reg + 1'b1;
                end
                
                // Advance virtual coordinates
                if (x_reg == img_width + 1) begin
                    x_next = '0;
                    y_next = y_reg + 1'b1;
                end else begin
                    x_next = x_reg + 1'b1;
                end
            end
            
            if (inc_write) begin
                wr_next = wr_reg + 1'b1;
            end
        end
    end

    // --------------------------------------------------------------------------
    // Process 2: Sequential Logic
    // --------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_reg <= '0;
            wr_reg <= '0;
            x_reg  <= '0;
            y_reg  <= '0;
        end else begin
            rd_reg <= rd_next;
            wr_reg <= wr_next;
            x_reg  <= x_next;
            y_reg  <= y_next;
        end
    end

    // --------------------------------------------------------------------------
    // Output Assignment
    // --------------------------------------------------------------------------
    assign sram_rd_addr = rd_reg;
    assign sram_wr_addr = wr_reg;

endmodule
