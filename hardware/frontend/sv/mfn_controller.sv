// ==============================================================================
// Module: mfn_controller
// Description: Main Finite State Machine (FSM) for MobileFaceNet Frontend.
//              Coordinates datapath, sliding window, and SRAM addressing.
//              Implements nested loops for: Layers -> OutChannels -> Spatial -> InChannels.
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
    output logic inc_write,

    // Layer Config Interface (Inputs from ROM)
    input  logic [9:0] layer_in_ch,
    input  logic [9:0] layer_out_ch,
    input  logic [7:0] layer_width,
    input  logic [7:0] layer_height,
    input  logic [1:0] layer_stride,
    
    // Layer Index (Output to ROM)
    output logic [5:0] layer_idx,
    
    // Weight ROM Interface
    output logic [9:0] wgt_rom_addr
);

    // --------------------------------------------------------------------------
    // FSM State Encoding
    // --------------------------------------------------------------------------
    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_NEXT_LAYER,
        STATE_LOAD_WINDOW,
        STATE_CONV_CALC,
        STATE_SHIFT_POS,
        STATE_DONE
    } state_t;

    // --------------------------------------------------------------------------
    // Registers & Next-State Signals
    // --------------------------------------------------------------------------
    state_t state_reg, state_next;
    
    logic [5:0] layer_idx_reg, layer_idx_next;
    logic [9:0] c_in_reg, c_in_next;
    logic [9:0] c_out_reg, c_out_next;
    logic [7:0] x_reg, x_next;
    logic [7:0] y_reg, y_next;
    logic [9:0] wgt_addr_reg, wgt_addr_next;

    // --------------------------------------------------------------------------
    // Process 1: Combinational Logic (Next State & Outputs)
    // --------------------------------------------------------------------------
    always_comb begin
        // Default assignments to prevent latches
        state_next     = state_reg;
        layer_idx_next = layer_idx_reg;
        c_in_next      = c_in_reg;
        c_out_next     = c_out_reg;
        x_next         = x_reg;
        y_next         = y_reg;
        wgt_addr_next  = wgt_addr_reg;
        
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
                    layer_idx_next = '0;
                    state_next     = STATE_NEXT_LAYER;
                end
            end

            STATE_NEXT_LAYER: begin
                // Reset counters for new layer
                c_out_next = '0;
                y_next     = '0;
                x_next     = '0;
                c_in_next  = '0;
                wgt_addr_next = '0;
                reset_ptr  = 1'b1;
                state_next = STATE_LOAD_WINDOW;
            end

            STATE_LOAD_WINDOW: begin
                // Pre-load logic: In a real design, we'd wait for the line buffer to fill.
                // For this refinement, we assume it fills in one cycle or managed by addr_gen.
                enable_shift = 1'b1;
                inc_read     = 1'b1;
                state_next   = STATE_CONV_CALC;
            end

            STATE_CONV_CALC: begin
                enable_mac = 1'b1;
                
                // Clear accumulator at the start of input channel loop
                if (c_in_reg == 0) clear_acc = 1'b1;

                // Loop through input channels
                if (c_in_reg == layer_in_ch - 1) begin
                    c_in_next = '0;
                    inc_write = 1'b1; // Finished one output pixel for one out_ch
                    state_next = STATE_SHIFT_POS;
                end else begin
                    c_in_next = c_in_reg + 1'b1;
                    wgt_addr_next = wgt_addr_reg + 1'b1;
                    state_next = STATE_CONV_CALC;
                end
            end

            STATE_SHIFT_POS: begin
                // Move to next spatial position
                if (x_reg == layer_width - 1) begin
                    x_next = '0;
                    if (y_reg == layer_height - 1) begin
                        y_next = '0;
                        // Finished all spatial positions for this out_ch
                        if (c_out_reg == layer_out_ch - 1) begin
                            // Finished all output channels for this layer
                            if (layer_idx_reg == 57) begin
                                state_next = STATE_DONE;
                            end else begin
                                layer_idx_next = layer_idx_reg + 1'b1;
                                state_next     = STATE_NEXT_LAYER;
                            end
                        end else begin
                            c_out_next = c_out_reg + 1'b1;
                            state_next = STATE_LOAD_WINDOW; // Start next out_ch
                        end
                    end else begin
                        y_next = y_reg + 1'b1;
                        state_next = STATE_LOAD_WINDOW;
                    end
                end else begin
                    x_next = x_reg + 1'b1;
                    enable_shift = 1'b1; // Shift window to next pixel
                    inc_read     = 1'b1;
                    state_next   = STATE_CONV_CALC;
                end
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
            state_reg        <= STATE_IDLE;
            layer_idx_reg    <= '0;
            c_in_reg         <= '0;
            c_out_reg        <= '0;
            x_reg            <= '0;
            y_reg            <= '0;
            wgt_addr_reg     <= '0;
        end else begin
            state_reg        <= state_next;
            layer_idx_reg    <= layer_idx_next;
            c_in_reg         <= c_in_next;
            c_out_reg        <= c_out_next;
            x_reg            <= x_next;
            y_reg            <= y_next;
            wgt_addr_reg     <= wgt_addr_next;
        end
    end

    // Outputs
    assign layer_idx    = layer_idx_reg;
    assign wgt_rom_addr = wgt_addr_reg;

endmodule
