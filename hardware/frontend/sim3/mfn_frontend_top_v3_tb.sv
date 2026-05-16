// =============================================================================
// mfn_frontend_top_v3_tb.sv — Full-inference testbench for v3 (12x12 SA)
//
// SRAM model: single unified SRAM (1M entries) with 3 buffer regions,
// matching v2's 3-buffer scheme (rd_buf/wr_buf/res_buf from layer config).
//   BUF_BASE[0]=0, BUF_BASE[1]=344064, BUF_BASE[2]=688128
//
// Normal read:   sram[BUF_BASE[rd_buf] + y*W*C + x*C + c_in_out]
// Residual read: sram[BUF_BASE[res_buf] + y*W*out_ch + x*out_ch + c_in_out]
// Write:         sram[BUF_BASE[wr_buf] + wr_ptr]   (wr_ptr reset each layer)
//
// Layer outputs dumped to layer_hex_v3/rtl_out_layerN.hex (full SRAM, same
// format as v2 so compare_layers.py can use BUF_BASE offset for comparison).
//
// Usage:  make top
// =============================================================================

`timescale 1ns/1ps

module mfn_frontend_top_v3_tb;

    localparam int DWIDTH    = 16;
    localparam int AWIDTH    = 40;
    localparam int MEM_DEPTH = 1 << 20;  // 1M entries — fits all 3 buffer regions

    // Buffer base offsets matching v2's BUF_BASE
    localparam int BUF_BASE [3] = '{0, 344064, 688128};

    logic clk, rst_n;
    logic start_inference, inference_done;
    logic signed [DWIDTH-1:0] pixel_in;
    logic reset_ptr, inc_write, read_res;
    logic signed [8:0] x_out, y_out;
    logic [9:0]        c_in_out;
    logic [AWIDTH-1:0] pixel_out;
    logic              valid_out;

    // ── DUT ──────────────────────────────────────────────────────────────────
    mfn_frontend_top_v3 #(.DWIDTH(DWIDTH), .AWIDTH(AWIDTH)) dut (.*);

    // ── Clock ────────────────────────────────────────────────────────────────
    initial clk = 0;
    always #5 clk = ~clk;

    // ── Unified SRAM (3 buffer regions) ──────────────────────────────────────
    logic signed [DWIDTH-1:0] sram [0:MEM_DEPTH-1];
    integer wr_ptr = 0;

    // ── Pixel read logic ─────────────────────────────────────────────────────
    // Normal:   sram[BUF_BASE[rd_buf] + y*W*C + x*C + c_in_out]
    // Residual: sram[BUF_BASE[res_buf] + y*W*out_ch + x*out_ch + c_in_out]
    // OOB for normal reads → 0 (zero-padding)
    always @(posedge clk) begin
        automatic int rd, wr, rs, W, H, C, C_out, ix, iy, addr;
        rd    = int'(dut.u_ctrl.layer_rd_buf);
        wr    = int'(dut.u_ctrl.layer_wr_buf);
        rs    = 3 - rd - wr;  // residual buffer = the third one
        W     = int'(dut.u_ctrl.layer_w);
        H     = int'(dut.u_ctrl.layer_h);
        C     = int'(dut.u_ctrl.layer_in_ch);
        C_out = int'(dut.u_ctrl.layer_out_ch);
        ix    = int'($signed(x_out));
        iy    = int'($signed(y_out));

        if (read_res) begin
            // Residual read at same (x,y) but from res_buf with out_ch channels
            addr = BUF_BASE[rs] + iy * W * C_out + ix * C_out + int'(c_in_out);
            if (addr >= 0 && addr < MEM_DEPTH)
                pixel_in = sram[addr];
            else
                pixel_in = '0;
        end else if (ix < 0 || iy < 0 || ix >= W || iy >= H) begin
            pixel_in = '0;  // zero-padding for border pixels
        end else begin
            addr = BUF_BASE[rd] + iy * W * C + ix * C + int'(c_in_out);
            if (addr >= 0 && addr < MEM_DEPTH)
                pixel_in = sram[addr];
            else
                pixel_in = '0;
        end
    end

    // ── Cycle counter ────────────────────────────────────────────────────────
    integer total_cycles  = 0;
    integer layer_start_cycle = 0;
    logic   counting      = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            total_cycles      = 0;
            layer_start_cycle = 0;
            counting          = 0;
        end else begin
            if (start_inference) counting = 1;
            if (inference_done)  counting = 0;
            if (counting)        total_cycles = total_cycles + 1;
        end
    end

    // ── Write: use wr_buf base + wr_ptr ─────────────────────────────────────
    // triggered by valid_out (2 cycles after inc_write, activation pipeline done)
    initial begin
        forever begin
            @(posedge clk);
            if (valid_out) begin
                automatic int w_buf, addr;
                w_buf = int'(dut.u_ctrl.layer_wr_buf);
                addr  = BUF_BASE[w_buf] + wr_ptr;
                if (addr >= 0 && addr < MEM_DEPTH)
                    sram[addr] = pixel_out[DWIDTH-1:0];
                wr_ptr = wr_ptr + 1;
            end
        end
    end

    // ── Layer boundary: dump + reset wr_ptr ──────────────────────────────────
    // No buffer swap needed — unified SRAM persists across layers.
    initial begin
        @(posedge rst_n);
        forever begin
            @(dut.u_ctrl.state_reg);
            if (dut.u_ctrl.state_reg == dut.u_ctrl.S_NEXT_LAYER) begin
                automatic int lidx = int'(dut.u_ctrl.layer_idx_reg);
                automatic int layer_cyc = total_cycles - layer_start_cycle;
                $display(">>> Layer %0d done | cycles: %0d | total: %0d",
                         lidx, layer_cyc, total_cycles);
                layer_start_cycle = total_cycles;

                // Dump full SRAM (compare_layers.py reads at BUF_BASE[wr_buf] offset)
                case (lidx)
                     0: $writememh("layer_hex_v3/rtl_out_layer0.hex",  sram);
                     1: $writememh("layer_hex_v3/rtl_out_layer1.hex",  sram);
                     2: $writememh("layer_hex_v3/rtl_out_layer2.hex",  sram);
                     3: $writememh("layer_hex_v3/rtl_out_layer3.hex",  sram);
                     4: $writememh("layer_hex_v3/rtl_out_layer4.hex",  sram);
                     5: $writememh("layer_hex_v3/rtl_out_layer5.hex",  sram);
                     6: $writememh("layer_hex_v3/rtl_out_layer6.hex",  sram);
                     7: $writememh("layer_hex_v3/rtl_out_layer7.hex",  sram);
                     8: $writememh("layer_hex_v3/rtl_out_layer8.hex",  sram);
                     9: $writememh("layer_hex_v3/rtl_out_layer9.hex",  sram);
                    10: $writememh("layer_hex_v3/rtl_out_layer10.hex", sram);
                    11: $writememh("layer_hex_v3/rtl_out_layer11.hex", sram);
                    12: $writememh("layer_hex_v3/rtl_out_layer12.hex", sram);
                    13: $writememh("layer_hex_v3/rtl_out_layer13.hex", sram);
                    14: $writememh("layer_hex_v3/rtl_out_layer14.hex", sram);
                    15: $writememh("layer_hex_v3/rtl_out_layer15.hex", sram);
                    16: $writememh("layer_hex_v3/rtl_out_layer16.hex", sram);
                    17: $writememh("layer_hex_v3/rtl_out_layer17.hex", sram);
                    18: $writememh("layer_hex_v3/rtl_out_layer18.hex", sram);
                    19: $writememh("layer_hex_v3/rtl_out_layer19.hex", sram);
                    20: $writememh("layer_hex_v3/rtl_out_layer20.hex", sram);
                    21: $writememh("layer_hex_v3/rtl_out_layer21.hex", sram);
                    22: $writememh("layer_hex_v3/rtl_out_layer22.hex", sram);
                    23: $writememh("layer_hex_v3/rtl_out_layer23.hex", sram);
                    24: $writememh("layer_hex_v3/rtl_out_layer24.hex", sram);
                    25: $writememh("layer_hex_v3/rtl_out_layer25.hex", sram);
                    26: $writememh("layer_hex_v3/rtl_out_layer26.hex", sram);
                    27: $writememh("layer_hex_v3/rtl_out_layer27.hex", sram);
                    28: $writememh("layer_hex_v3/rtl_out_layer28.hex", sram);
                    29: $writememh("layer_hex_v3/rtl_out_layer29.hex", sram);
                    30: $writememh("layer_hex_v3/rtl_out_layer30.hex", sram);
                    31: $writememh("layer_hex_v3/rtl_out_layer31.hex", sram);
                    32: $writememh("layer_hex_v3/rtl_out_layer32.hex", sram);
                    33: $writememh("layer_hex_v3/rtl_out_layer33.hex", sram);
                    34: $writememh("layer_hex_v3/rtl_out_layer34.hex", sram);
                    35: $writememh("layer_hex_v3/rtl_out_layer35.hex", sram);
                    36: $writememh("layer_hex_v3/rtl_out_layer36.hex", sram);
                    37: $writememh("layer_hex_v3/rtl_out_layer37.hex", sram);
                    38: $writememh("layer_hex_v3/rtl_out_layer38.hex", sram);
                    39: $writememh("layer_hex_v3/rtl_out_layer39.hex", sram);
                    40: $writememh("layer_hex_v3/rtl_out_layer40.hex", sram);
                    41: $writememh("layer_hex_v3/rtl_out_layer41.hex", sram);
                    42: $writememh("layer_hex_v3/rtl_out_layer42.hex", sram);
                    43: $writememh("layer_hex_v3/rtl_out_layer43.hex", sram);
                    44: $writememh("layer_hex_v3/rtl_out_layer44.hex", sram);
                    45: $writememh("layer_hex_v3/rtl_out_layer45.hex", sram);
                    46: $writememh("layer_hex_v3/rtl_out_layer46.hex", sram);
                    47: $writememh("layer_hex_v3/rtl_out_layer47.hex", sram);
                    48: $writememh("layer_hex_v3/rtl_out_layer48.hex", sram);
                    49: $writememh("layer_hex_v3/rtl_out_layer49.hex", sram);
                endcase

                wr_ptr = 0;

                if (lidx == 49) begin
                    $display("=========================================");
                    $display(" All 50 layers done [v3]. Total: %0d cy", total_cycles);
                    $display("=========================================");
                    #100 $finish;
                end
            end
        end
    end

    // ── Stimulus ─────────────────────────────────────────────────────────────
    initial begin
        rst_n           = 0;
        start_inference = 0;

        // Initialize entire SRAM to 0
        for (int i = 0; i < MEM_DEPTH; i++) sram[i] = '0;

        // Load input image at offset 0 (BUF_BASE[0]=0 for layer 0 rd_buf)
        $readmemh("hex/input.hex", sram);
        $system("mkdir -p layer_hex_v3");

        $display("[v3] MobileFaceNet Full Inference — 12x12 SA (3-buffer SRAM)");
        $display("[v3] Input loaded: hex/input.hex at offset 0");

        #50  rst_n = 1;
        #50  start_inference = 1;
        #10  start_inference = 0;

        wait(inference_done);
        $display("[v3] inference_done asserted at %0t", $time);
        $display("[v3] Total cycles: %0d", total_cycles);
        #200 $finish;
    end

    // ── Timeout ──────────────────────────────────────────────────────────────
    initial begin
        #800_000_000;
        $error("[v3] TIMEOUT after 800ms sim time");
        $finish;
    end

endmodule
