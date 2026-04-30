// ==============================================================================
// Module: mfn_frontend_top_tb
// Description: Integration testbench for MobileFaceNet Frontend.
//              Runs all 48 layers (L0-L47) and saves SRAM snapshots.
// ==============================================================================

module mfn_frontend_top_tb;

    parameter int DWIDTH = 16;
    parameter int AWIDTH = 40;
    parameter int M_ADDR_WIDTH = 20;

    logic clk;
    logic rst_n;
    logic start_inference;
    logic inference_done;

    logic valid_in;
    logic signed [DWIDTH-1:0] pixel_in;

    logic valid_out;
    logic signed [DWIDTH-1:0] pixel_out;

    logic [M_ADDR_WIDTH-1:0] sram_rd_addr;
    logic [M_ADDR_WIDTH-1:0] sram_wr_addr;

    // SRAM Model
    logic signed [DWIDTH-1:0] sram_mem [0:(1<<M_ADDR_WIDTH)-1];

    // DUT
    mfn_frontend_top #(
        .DWIDTH(DWIDTH),
        .AWIDTH(AWIDTH),
        .M_ADDR_WIDTH(M_ADDR_WIDTH)
    ) dut (.*);

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // SRAM write-back
    always @(posedge clk) begin
        if (valid_out)
            sram_mem[sram_wr_addr] <= pixel_out;
    end

    // Save SRAM snapshot and stop at layer 47
    initial begin
        @(posedge rst_n);
        forever begin
            @(dut.u_ctrl.state_reg);
            if (dut.u_ctrl.state_reg == dut.u_ctrl.STATE_NEXT_LAYER) begin
                $display(">>> Time=%0t | Finished Layer %0d", $time, dut.u_ctrl.layer_idx);
                case (dut.u_ctrl.layer_idx)
                     6'd0:  $writememh("hex/rtl_out_layer0.hex",  sram_mem);
                     6'd1:  $writememh("hex/rtl_out_layer1.hex",  sram_mem);
                     6'd2:  $writememh("hex/rtl_out_layer2.hex",  sram_mem);
                     6'd3:  $writememh("hex/rtl_out_layer3.hex",  sram_mem);
                     6'd4:  $writememh("hex/rtl_out_layer4.hex",  sram_mem);
                     6'd5:  $writememh("hex/rtl_out_layer5.hex",  sram_mem);
                     6'd6:  $writememh("hex/rtl_out_layer6.hex",  sram_mem);
                     6'd7:  $writememh("hex/rtl_out_layer7.hex",  sram_mem);
                     6'd8:  $writememh("hex/rtl_out_layer8.hex",  sram_mem);
                     6'd9:  $writememh("hex/rtl_out_layer9.hex",  sram_mem);
                    6'd10:  $writememh("hex/rtl_out_layer10.hex", sram_mem);
                    6'd11:  $writememh("hex/rtl_out_layer11.hex", sram_mem);
                    6'd12:  $writememh("hex/rtl_out_layer12.hex", sram_mem);
                    6'd13:  $writememh("hex/rtl_out_layer13.hex", sram_mem);
                    6'd14:  $writememh("hex/rtl_out_layer14.hex", sram_mem);
                    6'd15:  $writememh("hex/rtl_out_layer15.hex", sram_mem);
                    6'd16:  $writememh("hex/rtl_out_layer16.hex", sram_mem);
                    6'd17:  $writememh("hex/rtl_out_layer17.hex", sram_mem);
                    6'd18:  $writememh("hex/rtl_out_layer18.hex", sram_mem);
                    6'd19:  $writememh("hex/rtl_out_layer19.hex", sram_mem);
                    6'd20:  $writememh("hex/rtl_out_layer20.hex", sram_mem);
                    6'd21:  $writememh("hex/rtl_out_layer21.hex", sram_mem);
                    6'd22:  $writememh("hex/rtl_out_layer22.hex", sram_mem);
                    6'd23:  $writememh("hex/rtl_out_layer23.hex", sram_mem);
                    6'd24:  $writememh("hex/rtl_out_layer24.hex", sram_mem);
                    6'd25:  $writememh("hex/rtl_out_layer25.hex", sram_mem);
                    6'd26:  $writememh("hex/rtl_out_layer26.hex", sram_mem);
                    6'd27:  $writememh("hex/rtl_out_layer27.hex", sram_mem);
                    6'd28:  $writememh("hex/rtl_out_layer28.hex", sram_mem);
                    6'd29:  $writememh("hex/rtl_out_layer29.hex", sram_mem);
                    6'd30:  $writememh("hex/rtl_out_layer30.hex", sram_mem);
                    6'd31:  $writememh("hex/rtl_out_layer31.hex", sram_mem);
                    6'd32:  $writememh("hex/rtl_out_layer32.hex", sram_mem);
                    6'd33:  $writememh("hex/rtl_out_layer33.hex", sram_mem);
                    6'd34:  $writememh("hex/rtl_out_layer34.hex", sram_mem);
                    6'd35:  $writememh("hex/rtl_out_layer35.hex", sram_mem);
                    6'd36:  $writememh("hex/rtl_out_layer36.hex", sram_mem);
                    6'd37:  $writememh("hex/rtl_out_layer37.hex", sram_mem);
                    6'd38:  $writememh("hex/rtl_out_layer38.hex", sram_mem);
                    6'd39:  $writememh("hex/rtl_out_layer39.hex", sram_mem);
                    6'd40:  $writememh("hex/rtl_out_layer40.hex", sram_mem);
                    6'd41:  $writememh("hex/rtl_out_layer41.hex", sram_mem);
                    6'd42:  $writememh("hex/rtl_out_layer42.hex", sram_mem);
                    6'd43:  $writememh("hex/rtl_out_layer43.hex", sram_mem);
                    6'd44:  $writememh("hex/rtl_out_layer44.hex", sram_mem);
                    6'd45:  $writememh("hex/rtl_out_layer45.hex", sram_mem);
                    6'd46:  $writememh("hex/rtl_out_layer46.hex", sram_mem);
                    6'd47:  $writememh("hex/rtl_out_layer47.hex", sram_mem);
                    6'd48:  $writememh("hex/rtl_out_layer48.hex", sram_mem);
                    6'd49:  $writememh("hex/rtl_out_layer49.hex", sram_mem);
                endcase

                if (dut.u_ctrl.layer_idx == 6'd49) begin
                    $display("========================================");
                    $display("All 50 layers complete (L0-L49).");
                    $display("========================================");
                    #100;
                    $finish;
                end
            end
        end
    end

    // --- Cycle Counter ---
    integer cycle_count;
    logic   counting;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count <= 0;
            counting    <= 1'b0;
        end else begin
            if (start_inference)
                counting <= 1'b1;
            if (inference_done)
                counting <= 1'b0;
            if (counting)
                cycle_count <= cycle_count + 1;
        end
    end

    // Test Sequence
    initial begin
        rst_n = 0;
        start_inference = 0;

        for (int i=0; i<(1<<M_ADDR_WIDTH); i++) sram_mem[i] = '0;
        $readmemh("hex/input.hex", sram_mem);

        $display("Starting MobileFaceNet Full Inference (Layers 0-47)...");

        #50 rst_n = 1;
        #50 start_inference = 1;
        #10 start_inference = 0;

        wait(inference_done);
        $display("========================================");
        $display("Inference Done at %0t", $time);
        $display("Total Cycles: %0d", cycle_count);
        $display("========================================");

        $writememh("hex/rtl_out.hex", sram_mem);
        #100;
        $finish;
    end

    // SRAM Read Response
    always_ff @(posedge clk) begin
        pixel_in <= sram_mem[sram_rd_addr];
        valid_in <= 1'b1;
    end

endmodule
