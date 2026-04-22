// ==============================================================================
// Module: mfn_controller
// Description: Main Finite State Machine (FSM) for MobileFaceNet Frontend.
//              Coordinates datapath, sliding window, and SRAM addressing.
//              Follows strict Two-Process Methodology.
// ==============================================================================

module mfn_controller (
    input  logic clk,
    input  logic rst_n,
    
    input  logic start_inference,
    output logic inference_done,
    
    // Datapath Control
    output logic clear_acc,
    output logic enable_mac,
    output logic enable_shift,
    
    // Address Gen Control
    output logic reset_ptr,
    output logic inc_read,
    output logic inc_write
);

    // --------------------------------------------------------------------------
    // FSM State Encoding
    // --------------------------------------------------------------------------
    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_LOAD_ROW,
        STATE_CONV_CALC,
        STATE_SHIFT,
        STATE_DONE
    } state_t;

    // --------------------------------------------------------------------------
    // Registers & Next-State Signals
    // --------------------------------------------------------------------------
    state_t state_reg, state_next;

    // --------------------------------------------------------------------------
    // Process 1: Combinational Logic (Next State & Outputs)
    // --------------------------------------------------------------------------
    always_comb begin
        // Default assignments to prevent latches
        state_next     = state_reg;
        inference_done = 1'b0;
        clear_acc      = 1'b0;
        enable_mac     = 1'b0;
        enable_shift   = 1'b0;
        reset_ptr      = 1'b0;
        inc_read       = 1'b0;
        inc_write      = 1'b0;

        case (state_reg)
            STATE_IDLE: begin
                if (start_inference) begin
                    reset_ptr  = 1'b1;
                    state_next = STATE_LOAD_ROW;
                end
            end

            STATE_LOAD_ROW: begin
                // Pre-load pixels to fill the sliding window buffer
                // For a 3x3 window, we need 2 full rows + 3 pixels.
                enable_shift = 1'b1;
                inc_read     = 1'b1;
                // Transition condition simplified for skeleton structure
                state_next   = STATE_CONV_CALC;
            end

            STATE_CONV_CALC: begin
                // Perform the 3x3 Dot Product
                enable_mac = 1'b1;
                clear_acc  = 1'b1; // Starting new accumulation
                inc_write  = 1'b1;
                state_next = STATE_SHIFT;
            end

            STATE_SHIFT: begin
                // Shift window by reading 1 new pixel
                enable_shift = 1'b1;
                inc_read     = 1'b1;
                // Check if layer is finished (simplified)
                state_next   = STATE_DONE;
            end

            STATE_DONE: begin
                inference_done = 1'b1;
                state_next     = STATE_IDLE;
            end
            
            default: state_next = STATE_IDLE;
        endcase
    end

    // --------------------------------------------------------------------------
    // Process 2: Sequential Logic (State Update)
    // --------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= STATE_IDLE;
        end else begin
            state_reg <= state_next;
        end
    end

endmodule
