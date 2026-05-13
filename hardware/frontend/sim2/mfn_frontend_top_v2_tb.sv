// ==============================================================================
// Testbench: mfn_frontend_top_v2_tb
// v2 changes vs. v1 TB:
//   - SRAM wide read interface: sram_rd_addr_wide[0:8] → pixel_in_wide[0:8]
//     (used by std/DW conv FETCH; single sram_rd_addr still used for PW/residual)
//   - Cycle counter lets you compare v1 vs v2 speedup in simulation log
//   - Verification: output should match v1 hex exactly (same functional result,
//     just fewer cycles). Use diff layer_hex/ against sim/layer_hex/ to confirm.
// ==============================================================================

module mfn_frontend_top_v2_tb;

    parameter int DWIDTH       = 16;
    parameter int AWIDTH       = 40;
    parameter int M_ADDR_WIDTH = 20;

    logic clk;
    logic rst_n;
    logic start_inference;
    logic inference_done;

    logic valid_out;
    logic signed [DWIDTH-1:0] pixel_out;

    // Single-pixel SRAM interface (PW conv, global-DW, residual reads)
    logic [M_ADDR_WIDTH-1:0]  sram_rd_addr;
    logic signed [DWIDTH-1:0] pixel_in;

    // Wide-mode SRAM interface (std conv / DW conv — 9 simultaneous reads)
    logic [M_ADDR_WIDTH-1:0]  sram_rd_addr_wide [0:8];
    logic signed [DWIDTH-1:0] pixel_in_wide      [0:8];

    logic [M_ADDR_WIDTH-1:0]  sram_wr_addr;

    // Shared SRAM model (both interfaces read/write same array)
    logic signed [DWIDTH-1:0] sram_mem [0:(1<<M_ADDR_WIDTH)-1];

    // DUT
    mfn_frontend_top #(
        .DWIDTH(DWIDTH),
        .AWIDTH(AWIDTH),
        .M_ADDR_WIDTH(M_ADDR_WIDTH)
    ) dut (.*);

    // ── Clock ────────────────────────────────────────────────────────────────
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ── SRAM write-back ──────────────────────────────────────────────────────
    always @(posedge clk) begin
        if (valid_out)
            sram_mem[sram_wr_addr] <= pixel_out;
    end

    // ── SRAM read responses (both interfaces, 1-cycle registered read) ────────
    always_ff @(posedge clk) begin
        // Single-pixel path (PW / global-DW / residual)
        pixel_in <= sram_mem[sram_rd_addr];
        // Wide-mode path (std / DW conv)
        for (int i = 0; i < 9; i++)
            pixel_in_wide[i] <= sram_mem[sram_rd_addr_wide[i]];
    end

    // ── Cycle counter ────────────────────────────────────────────────────────
    integer cycle_count;
    logic   counting;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count <= 0;
            counting    <= 1'b0;
        end else begin
            if (start_inference) counting <= 1'b1;
            if (inference_done)  counting <= 1'b0;
            if (counting)        cycle_count <= cycle_count + 1;
        end
    end

    // ── Layer snapshot on STATE_NEXT_LAYER ──────────────────────────────────
    initial begin
        @(posedge rst_n);
        forever begin
            @(dut.u_ctrl.state_reg);
            if (dut.u_ctrl.state_reg == dut.u_ctrl.STATE_NEXT_LAYER) begin
                $display(">>> Time=%0t | Finished Layer %0d | Cycles so far: %0d",
                         $time, dut.u_ctrl.layer_idx, cycle_count);
                case (dut.u_ctrl.layer_idx)
                     6'd0:  $writememh("layer_hex/rtl_out_layer0.hex",  sram_mem);
                     6'd1:  $writememh("layer_hex/rtl_out_layer1.hex",  sram_mem);
                     6'd2:  $writememh("layer_hex/rtl_out_layer2.hex",  sram_mem);
                     6'd3:  $writememh("layer_hex/rtl_out_layer3.hex",  sram_mem);
                     6'd4:  $writememh("layer_hex/rtl_out_layer4.hex",  sram_mem);
                     6'd5:  $writememh("layer_hex/rtl_out_layer5.hex",  sram_mem);
                     6'd6:  $writememh("layer_hex/rtl_out_layer6.hex",  sram_mem);
                     6'd7:  $writememh("layer_hex/rtl_out_layer7.hex",  sram_mem);
                     6'd8:  $writememh("layer_hex/rtl_out_layer8.hex",  sram_mem);
                     6'd9:  $writememh("layer_hex/rtl_out_layer9.hex",  sram_mem);
                    6'd10:  $writememh("layer_hex/rtl_out_layer10.hex", sram_mem);
                    6'd11:  $writememh("layer_hex/rtl_out_layer11.hex", sram_mem);
                    6'd12:  $writememh("layer_hex/rtl_out_layer12.hex", sram_mem);
                    6'd13:  $writememh("layer_hex/rtl_out_layer13.hex", sram_mem);
                    6'd14:  $writememh("layer_hex/rtl_out_layer14.hex", sram_mem);
                    6'd15:  $writememh("layer_hex/rtl_out_layer15.hex", sram_mem);
                    6'd16:  $writememh("layer_hex/rtl_out_layer16.hex", sram_mem);
                    6'd17:  $writememh("layer_hex/rtl_out_layer17.hex", sram_mem);
                    6'd18:  $writememh("layer_hex/rtl_out_layer18.hex", sram_mem);
                    6'd19:  $writememh("layer_hex/rtl_out_layer19.hex", sram_mem);
                    6'd20:  $writememh("layer_hex/rtl_out_layer20.hex", sram_mem);
                    6'd21:  $writememh("layer_hex/rtl_out_layer21.hex", sram_mem);
                    6'd22:  $writememh("layer_hex/rtl_out_layer22.hex", sram_mem);
                    6'd23:  $writememh("layer_hex/rtl_out_layer23.hex", sram_mem);
                    6'd24:  $writememh("layer_hex/rtl_out_layer24.hex", sram_mem);
                    6'd25:  $writememh("layer_hex/rtl_out_layer25.hex", sram_mem);
                    6'd26:  $writememh("layer_hex/rtl_out_layer26.hex", sram_mem);
                    6'd27:  $writememh("layer_hex/rtl_out_layer27.hex", sram_mem);
                    6'd28:  $writememh("layer_hex/rtl_out_layer28.hex", sram_mem);
                    6'd29:  $writememh("layer_hex/rtl_out_layer29.hex", sram_mem);
                    6'd30:  $writememh("layer_hex/rtl_out_layer30.hex", sram_mem);
                    6'd31:  $writememh("layer_hex/rtl_out_layer31.hex", sram_mem);
                    6'd32:  $writememh("layer_hex/rtl_out_layer32.hex", sram_mem);
                    6'd33:  $writememh("layer_hex/rtl_out_layer33.hex", sram_mem);
                    6'd34:  $writememh("layer_hex/rtl_out_layer34.hex", sram_mem);
                    6'd35:  $writememh("layer_hex/rtl_out_layer35.hex", sram_mem);
                    6'd36:  $writememh("layer_hex/rtl_out_layer36.hex", sram_mem);
                    6'd37:  $writememh("layer_hex/rtl_out_layer37.hex", sram_mem);
                    6'd38:  $writememh("layer_hex/rtl_out_layer38.hex", sram_mem);
                    6'd39:  $writememh("layer_hex/rtl_out_layer39.hex", sram_mem);
                    6'd40:  $writememh("layer_hex/rtl_out_layer40.hex", sram_mem);
                    6'd41:  $writememh("layer_hex/rtl_out_layer41.hex", sram_mem);
                    6'd42:  $writememh("layer_hex/rtl_out_layer42.hex", sram_mem);
                    6'd43:  $writememh("layer_hex/rtl_out_layer43.hex", sram_mem);
                    6'd44:  $writememh("layer_hex/rtl_out_layer44.hex", sram_mem);
                    6'd45:  $writememh("layer_hex/rtl_out_layer45.hex", sram_mem);
                    6'd46:  $writememh("layer_hex/rtl_out_layer46.hex", sram_mem);
                    6'd47:  $writememh("layer_hex/rtl_out_layer47.hex", sram_mem);
                    6'd48:  $writememh("layer_hex/rtl_out_layer48.hex", sram_mem);
                    6'd49:  $writememh("layer_hex/rtl_out_layer49.hex", sram_mem);
                endcase

                if (dut.u_ctrl.layer_idx == 6'd49) begin
                    $display("========================================");
                    $display("All 50 layers complete (L0-L49). [v2]");
                    $display("========================================");
                    #100;
                    $finish;
                end
            end
        end
    end

    // ── Test Sequence ────────────────────────────────────────────────────────
    initial begin
        rst_n           = 0;
        start_inference = 0;

        for (int i=0; i<(1<<M_ADDR_WIDTH); i++) sram_mem[i] = '0;
        // Share the same hex input as sim/ (generated by gen_hex.py)
        $readmemh("hex/input.hex", sram_mem);

        $display("[v2] Starting MobileFaceNet Full Inference (L0-L49)...");
        $display("[v2] Wide SRAM fetch: std/DW conv 11->3 cycles | Dual MAC | CLA adder");

        #50 rst_n = 1;
        #50 start_inference = 1;
        #10 start_inference = 0;

        wait(inference_done);
        $display("========================================");
        $display("[v2] Inference Done at %0t", $time);
        $display("[v2] Total Cycles: %0d", cycle_count);
        $display("========================================");
        $display("[v2] To compare with v1: diff layer_hex/ ../sim/layer_hex/");

        $writememh("hex/rtl_out.hex", sram_mem);
        #100;
        $finish;
    end

endmodule
