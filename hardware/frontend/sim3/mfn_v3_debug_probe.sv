// =============================================================================
// mfn_v3_debug_probe.sv
//   Bind-based probe to localise an RTL vs GL functional mismatch.
//
// Captures the first 30 occurrences of three key signals in the v3 datapath:
//   inc_write + psum_rdata_c  : data fed INTO mfn_activation (from psum SRAM)
//   psum_we_a + psum_wdata_a  : data going from SA acc INTO psum SRAM
//   valid_out + pixel_out     : final activation output back to TB
//
// Comparing these between an RTL and a GL run pinpoints which stage diverges:
//   * pixel_out diff, sa_acc same, psum_rdata_c same  → activation pipeline
//   * sa_acc (=psum_wdata_a) diff                     → SA (Stage 3 row_dot_reg)
//   * psum_rdata_c diff                               → psum SRAM behavioural
//   * all three diff                                  → act_buf SRAM / weight ROM
//
// Self-terminates after collecting 30 of each event (≈first few thousand cycles
// of layer 0), so a debug run finishes in well under a minute on RTL and a few
// minutes on GL — no SIGTERM risk.
//
// Compile this file alongside any RTL or GL flow that elaborates
// mfn_frontend_top_v3 — no TB modifications required.
// =============================================================================

`timescale 1ns/1ps

module mfn_v3_debug_probe (
    input              clk,
    input              rst_n,
    input              inc_write,
    input      [39:0]  psum_rdata_c,
    input              psum_we_a,
    input      [8:0]   psum_waddr_a,
    input      [39:0]  psum_wdata_a,
    input              valid_out,
    input      [39:0]  pixel_out,
    input      [5:0]   layer_idx
);
    localparam int LIM = 30;

    int inc_cnt = 0;
    int we_cnt  = 0;
    int vo_cnt  = 0;
    int cyc     = 0;

    always @(posedge clk) begin
        if (!rst_n) cyc = 0;
        else        cyc = cyc + 1;
    end

    // ── SA-internal control-signal probe (Stage 3 isolation) ────────────────
    // Trace the SA's scalar control bits for the first ~60 cycles of layer 0:
    //   enable, enable_d, clear, dw_mode
    // If these differ between RTL and GL, Stage 3's enable_d propagation is
    // misbehaving in the netlist.  Scalar signals so escaped-identifier name
    // mangling in the netlist doesn't bite us.
    int sa_cyc = 0;
    localparam int SA_DUMP_LIM = 60;
    always @(posedge clk) if (rst_n) begin
        if (sa_cyc < SA_DUMP_LIM) begin
            $display("PROBE SA  cyc=%6d L%0d en=%b en_d=%b clr=%b dw=%b",
                     cyc, layer_idx,
                     u_sa.enable,
                     u_sa.enable_d,
                     u_sa.clear,
                     u_sa.dw_mode);
            // act_buf load-control signals — if act_load_ch / act_load_wide
            // differ between RTL and GL, the controller netlist is writing
            // the SRAM at a shifted lane/row.
            $display("PROBE LOAD cyc=%6d ld_en=%b ld_wide=%b ld_ch=%0d base_ch=%0d max_ch=%0d x=%0d y=%0d cin=%0d",
                     cyc,
                     u_act_buf.load_en,
                     u_act_buf.load_wide,
                     u_act_buf.load_ch,
                     u_act_buf.base_ch,
                     u_act_buf.max_ch,
                     $signed(x_out), $signed(y_out), c_in_out);
            // When loading, dump the SRAM's din0 input port by lane.  Probe
            // the SRAM instance port (u_sram.din0), NOT the act_buf wrapper's
            // local din0 wire: Genus optimises the wrapper's din0[15:0] away
            // (the SRAM is fed pixel_in[0] directly via {din0[191:16],
            // pixel_in[0]}), so the wrapper wire reads 'zzzz' on lane 0 in GL
            // although the SRAM still receives the correct value.  The SRAM
            // port has the real 192-bit value in both RTL and GL.
            if (u_act_buf.load_en) begin
                $display("PROBE DIN  cyc=%6d din0 L0=%04h L1=%04h L2=%04h L3=%04h L4=%04h L5=%04h L6=%04h",
                         cyc,
                         u_act_buf.u_sram.din0[  0 +: 16], u_act_buf.u_sram.din0[ 16 +: 16],
                         u_act_buf.u_sram.din0[ 32 +: 16], u_act_buf.u_sram.din0[ 48 +: 16],
                         u_act_buf.u_sram.din0[ 64 +: 16], u_act_buf.u_sram.din0[ 80 +: 16],
                         u_act_buf.u_sram.din0[ 96 +: 16]);
            end
            // row_dot_reg[0] and acc[0] — Stage 3 FF outputs.
            // The signal NAMES differ between RTL (unpacked array) and the
            // synth netlist (escaped-identifier wires), so use ifdef to pick
            // the right hierarchical reference syntax.
            `ifdef GL_NETLIST
            $display("PROBE SA_FF cyc=%6d row_dot_reg[0]=%010h acc[0]=%010h",
                     cyc,
                     u_sa.\row_dot_reg[0] ,
                     u_sa.\acc_out[0] );
            `else
            $display("PROBE SA_FF cyc=%6d row_dot_reg[0]=%010h acc[0]=%010h",
                     cyc,
                     u_sa.row_dot_reg[0],
                     u_sa.acc[0]);
            `endif
            // When enable is asserted, also dump the 12 activation lanes and
            // row 0's 12 weights — lets us see whether the MAC inputs (act_buf
            // / weight ROM outputs) match RTL or whether the comb mult+tree is
            // the culprit.
            // dout0 is a packed 192-bit vector — same syntax in RTL and GL,
            // no escaped-id ambiguity.  This lets us tell whether the lane
            // shift seen via u_sa.\act_in[N] is REAL (SRAM-side data shifted)
            // or just a probe-syntax artefact (SRAM correct but \act_in[N]
            // hierarchical ref resolves to the wrong wire).
            if (u_sa.enable) begin
                $display("PROBE DOUT cyc=%6d dout0[15:0]=%04h [31:16]=%04h [47:32]=%04h [63:48]=%04h [79:64]=%04h [95:80]=%04h [111:96]=%04h",
                         cyc,
                         u_act_buf.dout0[ 15: 0],
                         u_act_buf.dout0[ 31:16],
                         u_act_buf.dout0[ 47:32],
                         u_act_buf.dout0[ 63:48],
                         u_act_buf.dout0[ 79:64],
                         u_act_buf.dout0[ 95:80],
                         u_act_buf.dout0[111:96]);
            end
            if (u_sa.enable) begin
                `ifdef GL_NETLIST
                $display("PROBE SA_IN cyc=%6d act=%04h %04h %04h %04h %04h %04h %04h %04h %04h %04h %04h %04h",
                         cyc,
                         u_sa.\act_in[0] , u_sa.\act_in[1] , u_sa.\act_in[2] ,
                         u_sa.\act_in[3] , u_sa.\act_in[4] , u_sa.\act_in[5] ,
                         u_sa.\act_in[6] , u_sa.\act_in[7] , u_sa.\act_in[8] ,
                         u_sa.\act_in[9] , u_sa.\act_in[10] , u_sa.\act_in[11] );
                $display("PROBE SA_W0 cyc=%6d wgt0=%04h %04h %04h %04h %04h %04h %04h %04h %04h %04h %04h %04h",
                         cyc,
                         u_sa.\wgt_in[0][0] , u_sa.\wgt_in[0][1] , u_sa.\wgt_in[0][2] ,
                         u_sa.\wgt_in[0][3] , u_sa.\wgt_in[0][4] , u_sa.\wgt_in[0][5] ,
                         u_sa.\wgt_in[0][6] , u_sa.\wgt_in[0][7] , u_sa.\wgt_in[0][8] ,
                         u_sa.\wgt_in[0][9] , u_sa.\wgt_in[0][10] , u_sa.\wgt_in[0][11] );
                `else
                $display("PROBE SA_IN cyc=%6d act=%04h %04h %04h %04h %04h %04h %04h %04h %04h %04h %04h %04h",
                         cyc,
                         u_sa.act_in[0], u_sa.act_in[1], u_sa.act_in[2],
                         u_sa.act_in[3], u_sa.act_in[4], u_sa.act_in[5],
                         u_sa.act_in[6], u_sa.act_in[7], u_sa.act_in[8],
                         u_sa.act_in[9], u_sa.act_in[10], u_sa.act_in[11]);
                $display("PROBE SA_W0 cyc=%6d wgt0=%04h %04h %04h %04h %04h %04h %04h %04h %04h %04h %04h %04h",
                         cyc,
                         u_sa.wgt_in[0][0], u_sa.wgt_in[0][1], u_sa.wgt_in[0][2],
                         u_sa.wgt_in[0][3], u_sa.wgt_in[0][4], u_sa.wgt_in[0][5],
                         u_sa.wgt_in[0][6], u_sa.wgt_in[0][7], u_sa.wgt_in[0][8],
                         u_sa.wgt_in[0][9], u_sa.wgt_in[0][10], u_sa.wgt_in[0][11]);
                `endif
            end
            sa_cyc = sa_cyc + 1;
        end
    end

    always @(posedge clk) if (rst_n) begin
        if (inc_write && inc_cnt < LIM) begin
            $display("PROBE INC #%2d cyc=%6d L%0d psum_rdata_c=%010h",
                     inc_cnt, cyc, layer_idx, psum_rdata_c);
            inc_cnt = inc_cnt + 1;
        end
        if (psum_we_a && we_cnt < LIM) begin
            $display("PROBE WE  #%2d cyc=%6d L%0d addr=%03h wdata=%010h",
                     we_cnt, cyc, layer_idx, psum_waddr_a, psum_wdata_a);
            we_cnt = we_cnt + 1;
        end
        if (valid_out && vo_cnt < LIM) begin
            $display("PROBE VO  #%2d cyc=%6d L%0d pixel_out=%04h",
                     vo_cnt, cyc, layer_idx, pixel_out[15:0]);
            vo_cnt = vo_cnt + 1;
        end
        if (inc_cnt >= LIM && we_cnt >= LIM && vo_cnt >= LIM
            && sa_cyc >= SA_DUMP_LIM) begin
            $display("PROBE: collected %0d of each (INC/WE/VO) + %0d SA cycles, finishing",
                     LIM, SA_DUMP_LIM);
            #10 $finish;
        end
    end
endmodule

// Attach to every mfn_frontend_top_v3 elaboration (RTL or netlist) without
// touching the TB or DUT source.
bind mfn_frontend_top_v3 mfn_v3_debug_probe probe_i (
    .clk          (clk),
    .rst_n        (rst_n),
    .inc_write    (inc_write),
    .psum_rdata_c (psum_rdata_c),
    .psum_we_a    (psum_we_a),
    .psum_waddr_a (psum_waddr_a),
    .psum_wdata_a (psum_wdata_a),
    .valid_out    (valid_out),
    .pixel_out    (pixel_out),
    .layer_idx    (layer_idx)
);
