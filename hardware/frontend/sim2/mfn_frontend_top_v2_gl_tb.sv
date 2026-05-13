// ==============================================================================
// Testbench: mfn_frontend_top_v2_gl_tb  (Gate-Level Simulation)
//
// Drives the synthesised netlist mfn_frontend_top_v2_syn.v and verifies that
// the output SRAM state matches the RTL simulation reference.
//
// Key differences vs. RTL testbench (mfn_frontend_top_v2_tb.sv):
//   - Uses stripped_netlist.v (no VDD/VSS ports; stdcell lib handles power)
//   - Wide-mode ports are escaped identifiers, connected via plain arrays
//   - No DUT parameters (netlist is already elaborated)
//   - Layer snapshots use dut.u_ctrl.layer_idx change detection
//     (state_reg encoding unknown, so we watch the output wire directly)
//   - Watchdog timeout: 150 M cycles (~1.5 ms sim-time at 10 ns/cycle)
// ==============================================================================

`timescale 1ns/1ps

module mfn_frontend_top_v2_gl_tb;

    // -- Clocks & resets -------------------------------------------------------
    logic clk           = 0;
    logic rst_n         = 0;
    logic start_inference = 0;
    logic inference_done;
    logic valid_out;

    // -- DUT I/O ---------------------------------------------------------------
    logic [15:0] pixel_out;
    logic [15:0] pixel_in;
    logic [19:0] sram_rd_addr;
    logic [19:0] sram_wr_addr;

    // Wide-mode: escaped-identifier ports connect to plain arrays in the TB
    logic [19:0] rd_addr_w [0:8];
    logic [15:0] pix_in_w  [0:8];

    // -- SRAM model ------------------------------------------------------------
    logic signed [15:0] sram_mem [0:(1<<20)-1];

    // -- DUT instantiation -----------------------------------------------------
    // syn.v (stripped) does NOT have VDD/VSS ports; NangateOpenCellLibrary.v
    // declares supply1/supply0 globals that feed the standard cells implicitly.
    mfn_frontend_top dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start_inference(start_inference),
        .inference_done (inference_done),
        .valid_out      (valid_out),
        .pixel_out      (pixel_out),
        .sram_wr_addr   (sram_wr_addr),
        .sram_rd_addr   (sram_rd_addr),
        .pixel_in       (pixel_in),
        .\sram_rd_addr_wide[0] (rd_addr_w[0]),
        .\sram_rd_addr_wide[1] (rd_addr_w[1]),
        .\sram_rd_addr_wide[2] (rd_addr_w[2]),
        .\sram_rd_addr_wide[3] (rd_addr_w[3]),
        .\sram_rd_addr_wide[4] (rd_addr_w[4]),
        .\sram_rd_addr_wide[5] (rd_addr_w[5]),
        .\sram_rd_addr_wide[6] (rd_addr_w[6]),
        .\sram_rd_addr_wide[7] (rd_addr_w[7]),
        .\sram_rd_addr_wide[8] (rd_addr_w[8]),
        .\pixel_in_wide[0]     (pix_in_w[0]),
        .\pixel_in_wide[1]     (pix_in_w[1]),
        .\pixel_in_wide[2]     (pix_in_w[2]),
        .\pixel_in_wide[3]     (pix_in_w[3]),
        .\pixel_in_wide[4]     (pix_in_w[4]),
        .\pixel_in_wide[5]     (pix_in_w[5]),
        .\pixel_in_wide[6]     (pix_in_w[6]),
        .\pixel_in_wide[7]     (pix_in_w[7]),
        .\pixel_in_wide[8]     (pix_in_w[8])
    );

    // -- Clock -----------------------------------------------------------------
    always #5 clk = ~clk;

    // -- SRAM write-back -------------------------------------------------------
    always @(posedge clk)
        if (valid_out) sram_mem[sram_wr_addr] <= pixel_out;

    // -- SRAM read responses (1-cycle registered) ------------------------------
    always_ff @(posedge clk) begin
        pixel_in <= sram_mem[sram_rd_addr];
        for (int i = 0; i < 9; i++)
            pix_in_w[i] <= sram_mem[rd_addr_w[i]];
    end

    // -- Cycle counter ---------------------------------------------------------
    integer cycle_count;
    logic   counting;

    initial begin
        cycle_count = 0;
        counting    = 0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count <= 0;
            counting    <= 0;
        end else begin
            if (start_inference) counting <= 1;
            if (inference_done)  counting <= 0;
            if (counting)        cycle_count <= cycle_count + 1;
        end
    end

    // -- Per-layer snapshot via layer_idx wire preserved in netlist ------------
    // dut.u_ctrl.layer_idx is a 6-bit wire in mfn_controller_DWIDTH16_AWIDTH40.
    // When it changes value, the previous layer just completed STATE_NEXT_LAYER.
    // We wait 2 extra clock edges for the SRAM NBA writes to fully settle.
    logic       layer_idx_init;
    logic [5:0] prev_layer_idx;

    initial begin
        layer_idx_init = 0;
        prev_layer_idx = '0;
    end

    always @(dut.u_ctrl.layer_idx) begin
        if (!$isunknown(dut.u_ctrl.layer_idx)) begin
            // Snapshot guard: only write when rst_n is high AND we have a valid prev
            // prev_layer_idx / layer_idx_init updates are OUTSIDE the rst_n check so
            // that the X->0 transition during reset still seeds prev_layer_idx = 0.
            // This lets the 0->1 transition correctly snapshot layer 0.
            if (rst_n && layer_idx_init) begin
                @(posedge clk); @(posedge clk);
                $display(">>> Time=%0t | Layer %0d done | Cycles: %0d",
                          $time, prev_layer_idx, cycle_count);
                case (prev_layer_idx)
                     6'd0:  $writememh("layer_hex_gl/rtl_out_layer0.hex",  sram_mem);
                     6'd1:  $writememh("layer_hex_gl/rtl_out_layer1.hex",  sram_mem);
                     6'd2:  $writememh("layer_hex_gl/rtl_out_layer2.hex",  sram_mem);
                     6'd3:  $writememh("layer_hex_gl/rtl_out_layer3.hex",  sram_mem);
                     6'd4:  $writememh("layer_hex_gl/rtl_out_layer4.hex",  sram_mem);
                     6'd5:  $writememh("layer_hex_gl/rtl_out_layer5.hex",  sram_mem);
                     6'd6:  $writememh("layer_hex_gl/rtl_out_layer6.hex",  sram_mem);
                     6'd7:  $writememh("layer_hex_gl/rtl_out_layer7.hex",  sram_mem);
                     6'd8:  $writememh("layer_hex_gl/rtl_out_layer8.hex",  sram_mem);
                     6'd9:  $writememh("layer_hex_gl/rtl_out_layer9.hex",  sram_mem);
                     6'd10: $writememh("layer_hex_gl/rtl_out_layer10.hex", sram_mem);
                     6'd11: $writememh("layer_hex_gl/rtl_out_layer11.hex", sram_mem);
                     6'd12: $writememh("layer_hex_gl/rtl_out_layer12.hex", sram_mem);
                     6'd13: $writememh("layer_hex_gl/rtl_out_layer13.hex", sram_mem);
                     6'd14: $writememh("layer_hex_gl/rtl_out_layer14.hex", sram_mem);
                     6'd15: $writememh("layer_hex_gl/rtl_out_layer15.hex", sram_mem);
                     6'd16: $writememh("layer_hex_gl/rtl_out_layer16.hex", sram_mem);
                     6'd17: $writememh("layer_hex_gl/rtl_out_layer17.hex", sram_mem);
                     6'd18: $writememh("layer_hex_gl/rtl_out_layer18.hex", sram_mem);
                     6'd19: $writememh("layer_hex_gl/rtl_out_layer19.hex", sram_mem);
                     6'd20: $writememh("layer_hex_gl/rtl_out_layer20.hex", sram_mem);
                     6'd21: $writememh("layer_hex_gl/rtl_out_layer21.hex", sram_mem);
                     6'd22: $writememh("layer_hex_gl/rtl_out_layer22.hex", sram_mem);
                     6'd23: $writememh("layer_hex_gl/rtl_out_layer23.hex", sram_mem);
                     6'd24: $writememh("layer_hex_gl/rtl_out_layer24.hex", sram_mem);
                     6'd25: $writememh("layer_hex_gl/rtl_out_layer25.hex", sram_mem);
                     6'd26: $writememh("layer_hex_gl/rtl_out_layer26.hex", sram_mem);
                     6'd27: $writememh("layer_hex_gl/rtl_out_layer27.hex", sram_mem);
                     6'd28: $writememh("layer_hex_gl/rtl_out_layer28.hex", sram_mem);
                     6'd29: $writememh("layer_hex_gl/rtl_out_layer29.hex", sram_mem);
                     6'd30: $writememh("layer_hex_gl/rtl_out_layer30.hex", sram_mem);
                     6'd31: $writememh("layer_hex_gl/rtl_out_layer31.hex", sram_mem);
                     6'd32: $writememh("layer_hex_gl/rtl_out_layer32.hex", sram_mem);
                     6'd33: $writememh("layer_hex_gl/rtl_out_layer33.hex", sram_mem);
                     6'd34: $writememh("layer_hex_gl/rtl_out_layer34.hex", sram_mem);
                     6'd35: $writememh("layer_hex_gl/rtl_out_layer35.hex", sram_mem);
                     6'd36: $writememh("layer_hex_gl/rtl_out_layer36.hex", sram_mem);
                     6'd37: $writememh("layer_hex_gl/rtl_out_layer37.hex", sram_mem);
                     6'd38: $writememh("layer_hex_gl/rtl_out_layer38.hex", sram_mem);
                     6'd39: $writememh("layer_hex_gl/rtl_out_layer39.hex", sram_mem);
                     6'd40: $writememh("layer_hex_gl/rtl_out_layer40.hex", sram_mem);
                     6'd41: $writememh("layer_hex_gl/rtl_out_layer41.hex", sram_mem);
                     6'd42: $writememh("layer_hex_gl/rtl_out_layer42.hex", sram_mem);
                     6'd43: $writememh("layer_hex_gl/rtl_out_layer43.hex", sram_mem);
                     6'd44: $writememh("layer_hex_gl/rtl_out_layer44.hex", sram_mem);
                     6'd45: $writememh("layer_hex_gl/rtl_out_layer45.hex", sram_mem);
                     6'd46: $writememh("layer_hex_gl/rtl_out_layer46.hex", sram_mem);
                     6'd47: $writememh("layer_hex_gl/rtl_out_layer47.hex", sram_mem);
                     6'd48: $writememh("layer_hex_gl/rtl_out_layer48.hex", sram_mem);
                     // layer 49 is the last: layer_idx never changes away from 49,
                     // so its snapshot is taken directly in the main initial block
                     // after wait(inference_done).
                endcase
            end
            // Update prev/init even during reset so prev_layer_idx = 0 is
            // already set when layer 0 finishes (0->1 transition).
            prev_layer_idx <= dut.u_ctrl.layer_idx;
            layer_idx_init <= 1;
        end
    end

    // -- Watchdog --------------------------------------------------------------
    initial begin
        #1_500_000_000;
        $display("ERROR: Watchdog timeout — inference_done never asserted");
        $finish;
    end

    // -- Main test sequence ----------------------------------------------------
    initial begin
        $display("[GL] Gate-Level Simulation -- mfn_frontend_top v2 netlist");
        $display("[GL] Netlist: mfn_frontend_top_v2_syn.v (stripped stubs)");

        foreach (sram_mem[i]) sram_mem[i] = '0;
        $readmemh("hex/input.hex", sram_mem);

        #50  rst_n = 1;
        #50  start_inference = 1;
        #10  start_inference = 0;

        wait (inference_done);
        // Layer 49 snapshot: layer_idx never changes after the last layer,
        // so always@(layer_idx) never fires for it. Capture it here directly.
        @(posedge clk); @(posedge clk);
        $writememh("layer_hex_gl/rtl_out_layer49.hex", sram_mem);
        $display(">>> Time=%0t | Layer 49 done (final) | Cycles: %0d", $time, cycle_count);

        repeat (10) @(posedge clk);

        $display("========================================");
        $display("[GL] Inference Done at %0t", $time);
        $display("[GL] Total Cycles: %0d", cycle_count);
        $display("========================================");

        $writememh("hex/rtl_out_gl.hex", sram_mem);
        $display("[GL] Final SRAM -> hex/rtl_out_gl.hex");
        $display("[GL] Run 'make diff_gl' to compare GL vs RTL per-layer output.");

        #100;
        $finish;
    end

endmodule
