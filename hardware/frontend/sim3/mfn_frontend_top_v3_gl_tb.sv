// =============================================================================
// mfn_frontend_top_v3_gl_tb.sv — Gate-Level testbench for v3
//
// Drives a v3 gate-level netlist (Genus syn OR Innovus post-route final) and
// verifies that the per-layer SRAM output matches the RTL reference
// (layer_hex_v3/).  Dump dir is plusarg-controlled:
//
//   make gl   → +dumpdir=layer_hex_gl_v3   (syn netlist)
//   make pnr  → +dumpdir=layer_hex_pnr_v3  (post-route netlist)
//   default                                  layer_hex_gl_v3
//
// Differences vs the RTL testbench (mfn_frontend_top_v3_tb.sv):
//   - Netlist top has the act_buf bus flattened to 12 escaped-identifier
//     ports  \pixel_in[0]  ..  \pixel_in[11]  (the unpacked array port).
//   - No DUT parameters (the netlist is already elaborated).
//   - Layer params are decoded from the top-level wire dut.layer_config
//     (the controller's internal decode wires may be optimised away).
//   - Layer snapshots watch dut.layer_idx change (FSM state encoding is
//     unknown in the netlist).
//   - Black-box ROMs/SRAM: behavioral models in netlist_beh_v3.sv +
//     sv3/sram_act_buf_1rw0r0w_192_64_freepdk45.sv (compiled before netlist).
// =============================================================================

`timescale 1ns/1ps

module mfn_frontend_top_v3_gl_tb;

    localparam int DWIDTH    = 16;
    localparam int AWIDTH    = 40;
    localparam int MEM_DEPTH = 1 << 20;
    localparam int BUF_BASE [3] = '{0, 344064, 688128};

    logic clk, rst_n;
    logic start_inference, inference_done;
    logic signed [DWIDTH-1:0] pixel_in [12];   // 12-lane activation bus
    logic reset_ptr, inc_write, read_res;
    logic signed [8:0] x_out, y_out;
    logic [9:0]        c_in_out;
    logic [AWIDTH-1:0] pixel_out;
    logic              valid_out;

    // ── DUT: synthesised netlist ─────────────────────────────────────────────
    // POSITIONAL port connection — escape-id named binding (.\pixel_in[N])
    // gave a +1 lane shift in Xcelium 18.09 regardless of connection order.
    // Positional order MUST match the netlist port list exactly:
    //   clk, rst_n, start_inference, inference_done,
    //   \pixel_in[11..0],
    //   reset_ptr, inc_write, read_res, x_out, y_out, c_in_out,
    //   pixel_out, valid_out
    mfn_frontend_top_v3 dut (
        clk, rst_n, start_inference, inference_done,
        pixel_in[11], pixel_in[10], pixel_in[ 9], pixel_in[ 8],
        pixel_in[ 7], pixel_in[ 6], pixel_in[ 5], pixel_in[ 4],
        pixel_in[ 3], pixel_in[ 2], pixel_in[ 1], pixel_in[ 0],
        reset_ptr, inc_write, read_res, x_out, y_out, c_in_out,
        pixel_out, valid_out
    );

    // ── Clock ────────────────────────────────────────────────────────────────
    initial clk = 0;
    always #5 clk = ~clk;

    // ── Unified SRAM (3 buffer regions, same model as RTL tb) ────────────────
    logic signed [DWIDTH-1:0] sram [0:MEM_DEPTH-1];
    integer wr_ptr = 0;

    // ── 12-lane pixel read — layer params decoded from dut.layer_config ──────
    //   in_ch[9:0] out_ch[19:10] w[26:20] h[33:27] rd_buf[61:60] wr_buf[63:62]
    //
    // Driven on negedge clk (was @(posedge clk)) — a posedge-clocked driver
    // raced x_out's port propagation and latched a stale address in GL sim,
    // shifting every narrow act_buf load by one lane.  negedge samples x_out
    // half a cycle after it has settled, so the DUT gets correct data at the
    // next posedge with no race.
    always @(negedge clk) begin
        automatic int rd, wr, rs, W, H, C, C_out, ix, iy, cbase, addr;
        rd    = int'(dut.layer_config[61:60]);
        wr    = int'(dut.layer_config[63:62]);
        rs    = 3 - rd - wr;
        W     = int'(dut.layer_config[26:20]);
        H     = int'(dut.layer_config[33:27]);
        C     = int'(dut.layer_config[9:0]);
        C_out = int'(dut.layer_config[19:10]);
        ix    = int'($signed(x_out));
        iy    = int'($signed(y_out));
        cbase = int'(c_in_out);

        if (read_res) begin
            for (int k = 0; k < 12; k++) begin
                addr = BUF_BASE[rs] + iy * W * C_out + ix * C_out + cbase + k;
                if (cbase + k < C_out && addr >= 0 && addr < MEM_DEPTH)
                    pixel_in[k] = sram[addr];
                else
                    pixel_in[k] = '0;
            end
        end else if (ix < 0 || iy < 0 || ix >= W || iy >= H) begin
            for (int k = 0; k < 12; k++) pixel_in[k] = '0;
        end else begin
            for (int k = 0; k < 12; k++) begin
                addr = BUF_BASE[rd] + iy * W * C + ix * C + cbase + k;
                if (cbase + k < C && addr >= 0 && addr < MEM_DEPTH)
                    pixel_in[k] = sram[addr];
                else
                    pixel_in[k] = '0;
            end
        end
    end

    // ── Cycle counter ────────────────────────────────────────────────────────
    integer total_cycles = 0, layer_start_cycle = 0;
    logic   counting      = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            total_cycles = 0; layer_start_cycle = 0; counting = 0;
        end else begin
            if (start_inference) counting = 1;
            if (inference_done)  counting = 0;
            if (counting)        total_cycles = total_cycles + 1;
        end
    end

    // ── Write-back: valid_out → sram[wr_buf base + wr_ptr] ───────────────────
    initial begin
        forever begin
            @(posedge clk);
            if (valid_out) begin
                automatic int w_buf, addr;
                w_buf = int'(dut.layer_config[63:62]);
                addr  = BUF_BASE[w_buf] + wr_ptr;
                if (addr >= 0 && addr < MEM_DEPTH)
                    sram[addr] = pixel_out[DWIDTH-1:0];
                wr_ptr = wr_ptr + 1;
            end
        end
    end

    // ── Per-layer snapshot: detect dut.layer_idx changes SYNCHRONOUSLY ───────
    // (The earlier @(dut.layer_idx) + inline @posedge waits had a re-entrancy
    //  bug: while the always block was waiting on the 2-cycle settle, further
    //  changes on layer_idx got dropped — symptoms were missing layer hex
    //  dumps.  This version is a posedge-sampled FSM: one rising edge sees
    //  the change, a 2-cycle countdown lets all NBA writes settle, then the
    //  dump fires.)
    logic [5:0] prev_layer_idx   = '0;
    logic [5:0] pending_dump_idx = '0;
    logic [1:0] dump_countdown   = 2'd0;   // 0 = idle, otherwise cycles until dump
    logic       layer_idx_init   = 1'b0;

    // Output directory, settable via +dumpdir=<path>.  Default keeps the
    // legacy syn-netlist GL flow happy.
    string dump_dir = "layer_hex_gl_v3";

    task automatic dump_layer(input int lidx);
        automatic string fn;
        fn = $sformatf("%s/rtl_out_layer%0d.hex", dump_dir, lidx);
        $writememh(fn, sram);
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            prev_layer_idx   = '0;
            pending_dump_idx = '0;
            dump_countdown   = 2'd0;
            layer_idx_init   = 1'b0;
        end else if (!$isunknown(dut.layer_idx)) begin
            // First valid sample after reset → just latch (don't dump the X→0)
            if (!layer_idx_init) begin
                prev_layer_idx = dut.layer_idx;
                layer_idx_init = 1'b1;
            end
            // Detect boundary: schedule a 2-cycle delayed dump
            else if (dut.layer_idx != prev_layer_idx && dump_countdown == 0) begin
                pending_dump_idx = prev_layer_idx;
                dump_countdown   = 2'd2;
                prev_layer_idx   = dut.layer_idx;
            end
            // Fire pending dump after countdown
            if (dump_countdown != 0) begin
                if (dump_countdown == 2'd1) begin
                    $display(">>> Layer %0d done [GL] | cycles: %0d | total: %0d",
                             pending_dump_idx,
                             total_cycles - layer_start_cycle,
                             total_cycles);
                    dump_layer(int'(pending_dump_idx));
                    wr_ptr            = 0;
                    layer_start_cycle = total_cycles;
                end
                dump_countdown = dump_countdown - 2'd1;
            end
        end
    end

    // ── Stimulus ─────────────────────────────────────────────────────────────
    initial begin
        // Resolve dump dir from +dumpdir=<path> (default: layer_hex_gl_v3)
        if (!$value$plusargs("dumpdir=%s", dump_dir))
            dump_dir = "layer_hex_gl_v3";

        rst_n           = 0;
        start_inference = 0;
        for (int i = 0; i < MEM_DEPTH; i++) sram[i] = '0;
        $readmemh("hex/input.hex", sram);
        $system($sformatf("mkdir -p %s", dump_dir));

        $display("[GL] Gate-Level Simulation — mfn_frontend_top_v3 netlist");
        $display("[GL] Dump directory: %s", dump_dir);

        #50  rst_n = 1;
        #50  start_inference = 1;
        #10  start_inference = 0;

        wait (inference_done);
        // Layer 49 never advances layer_idx, so snapshot it here directly.
        @(posedge clk); @(posedge clk);
        dump_layer(49);
        $display(">>> Layer 49 done [GL] (final) | total: %0d", total_cycles);

        $display("=========================================");
        $display(" All 50 layers done [GL]. Total: %0d cy", total_cycles);
        $display("=========================================");
        #200 $finish;
    end

    // ── Watchdog ─────────────────────────────────────────────────────────────
    initial begin
        #1_000_000_000;
        $error("[GL] TIMEOUT — inference_done never asserted");
        $finish;
    end

endmodule
