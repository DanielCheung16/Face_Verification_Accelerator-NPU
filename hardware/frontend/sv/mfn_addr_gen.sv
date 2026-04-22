// ==============================================================================
// Module: mfn_addr_gen
// Description: Address Generator for SRAM buffers.
//              Uses coordinate accumulators to avoid expensive multipliers.
//              Follows Two-Process Methodology.
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
    
    // Output Addresses
    output logic [AWIDTH-1:0] sram_rd_addr,
    output logic [AWIDTH-1:0] sram_wr_addr
);

    // --------------------------------------------------------------------------
    // Registers & Next-State Signals
    // --------------------------------------------------------------------------
    logic [AWIDTH-1:0] rd_reg, rd_next;
    logic [AWIDTH-1:0] wr_reg, wr_next;

    // --------------------------------------------------------------------------
    // Process 1: Combinational Logic
    // --------------------------------------------------------------------------
    always_comb begin
        if (reset_ptr) begin
            rd_next = '0;
            wr_next = '0;
        end else begin
            rd_next = inc_read  ? (rd_reg + 1'b1) : rd_reg;
            wr_next = inc_write ? (wr_reg + 1'b1) : wr_reg;
        end
    end

    // --------------------------------------------------------------------------
    // Process 2: Sequential Logic
    // --------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_reg <= '0;
            wr_reg <= '0;
        end else begin
            rd_reg <= rd_next;
            wr_reg <= wr_next;
        end
    end

    // --------------------------------------------------------------------------
    // Output Assignment
    // --------------------------------------------------------------------------
    assign sram_rd_addr = rd_reg;
    assign sram_wr_addr = wr_reg;

endmodule
