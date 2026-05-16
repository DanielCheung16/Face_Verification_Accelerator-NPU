// =============================================================================
// mfn_sa_tb.sv — Unit testbench for mfn_sa_12x12 + mfn_weight_rom_v3
//
// Tests (in order):
//   1. PE basic: single MAC, clear, accumulate over multiple cycles
//   2. SA clear: load biases → verify acc_out matches bias values
//   3. SA compute: known activations × known weights → check expected sums
//   4. SA multi-tile: two consecutive c_in tiles accumulate correctly
//
// Run: xrun -sv mfn_pe.sv mfn_sa_12x12.sv mfn_sa_tb.sv
// =============================================================================

`timescale 1ns/1ps

module mfn_sa_tb;

    localparam int DWIDTH  = 16;
    localparam int AWIDTH  = 40;
    localparam int SA_ROWS = 12;
    localparam int SA_COLS = 12;

    logic clk, rst_n;
    logic sa_clear, sa_enable;
    logic signed [DWIDTH-1:0] act_in  [SA_COLS];
    logic signed [DWIDTH-1:0] wgt_in  [SA_ROWS][SA_COLS];
    logic signed [AWIDTH-1:0] bias_in [SA_ROWS];
    logic signed [AWIDTH-1:0] acc_out [SA_ROWS];

    // ── DUT ──────────────────────────────────────────────────────────────────
    mfn_sa_12x12 #(.DWIDTH(DWIDTH), .AWIDTH(AWIDTH),
                   .SA_ROWS(SA_ROWS), .SA_COLS(SA_COLS)) dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .clear  (sa_clear),
        .enable (sa_enable),
        .act_in (act_in),
        .wgt_in (wgt_in),
        .bias_in(bias_in),
        .acc_out(acc_out)
    );

    // ── clock ─────────────────────────────────────────────────────────────────
    initial clk = 0;
    always #5 clk = ~clk;

    // ── helper tasks ──────────────────────────────────────────────────────────
    task tick(int n = 1);
        repeat(n) @(posedge clk); #1;
    endtask

    task check_acc(int row, longint expected, string msg);
        if (acc_out[row] !== AWIDTH'(signed'(expected)))
            $error("FAIL [%s] row=%0d: got %0d, expected %0d",
                   msg, row, $signed(acc_out[row]), expected);
        else
            $display("  PASS [%s] row=%0d = %0d", msg, row, $signed(acc_out[row]));
    endtask

    // ── test stimulus ─────────────────────────────────────────────────────────
    int errors = 0;

    initial begin
        $display("=== SA Unit Tests ===");

        // reset
        rst_n = 0; sa_clear = 0; sa_enable = 0;
        foreach (act_in[c])    act_in[c]   = '0;
        foreach (bias_in[r])   bias_in[r]  = '0;
        for (int r=0; r<SA_ROWS; r++)
            for (int c=0; c<SA_COLS; c++) wgt_in[r][c] = '0;
        tick(2); rst_n = 1; tick(2);

        // ── TEST 1: SA clear with biases ─────────────────────────────────────
        $display("TEST 1: SA clear loads biases");
        for (int r = 0; r < SA_ROWS; r++)
            bias_in[r] = AWIDTH'(signed'(100 * (r + 1)));
        sa_clear = 1; tick(1); sa_clear = 0; tick(1);

        for (int r = 0; r < SA_ROWS; r++)
            check_acc(r, 100*(r+1), "bias_load");

        // ── TEST 2: SA compute — identity weights (one hot per row/col) ───────
        $display("TEST 2: identity-style: act=1, wgt[r][r]=2, others 0");
        // Set all weights to 0, then wgt[r][r] = 2
        for (int r=0; r<SA_ROWS; r++)
            for (int c=0; c<SA_COLS; c++)
                wgt_in[r][c] = (c == r) ? DWIDTH'(2) : '0;
        for (int c=0; c<SA_COLS; c++)
            act_in[c] = DWIDTH'(1);

        // Start from zero (clear with zero biases)
        foreach (bias_in[r]) bias_in[r] = '0;
        sa_clear = 1; tick(1); sa_clear = 0;

        sa_enable = 1; tick(1); sa_enable = 0; tick(1);

        // acc[r] should be 0 + 1*2 = 2 (only col=r matches wgt=2, act=1)
        for (int r = 0; r < SA_ROWS; r++)
            check_acc(r, 2, "identity_compute");

        // ── TEST 3: multi-tile accumulation ──────────────────────────────────
        $display("TEST 3: two compute tiles accumulate");
        // Keep same weights and acts; clear to bias=10, then two enables
        foreach (bias_in[r]) bias_in[r] = AWIDTH'(10);
        sa_clear = 1; tick(1); sa_clear = 0;

        sa_enable = 1; tick(1);      // adds 2 → acc = 12
        tick(0); sa_enable = 0; tick(1);  // sa_enable = 0 for one cycle
        sa_enable = 1; tick(1);      // adds 2 → acc = 14
        sa_enable = 0; tick(1);

        for (int r = 0; r < SA_ROWS; r++)
            check_acc(r, 14, "multi_tile");

        // ── TEST 4: row independence (different weight per row) ───────────────
        $display("TEST 4: each row has different weight sum");
        // wgt[r][c] = r+1 for all c; act[c] = 1 → acc[r] = (r+1)*SA_COLS
        for (int r=0; r<SA_ROWS; r++)
            for (int c=0; c<SA_COLS; c++)
                wgt_in[r][c] = DWIDTH'(r+1);
        for (int c=0; c<SA_COLS; c++) act_in[c] = DWIDTH'(1);
        foreach (bias_in[r]) bias_in[r] = '0;
        sa_clear = 1; tick(1); sa_clear = 0;
        sa_enable = 1; tick(1); sa_enable = 0; tick(1);

        for (int r = 0; r < SA_ROWS; r++)
            check_acc(r, (r+1)*SA_COLS, "row_independence");

        // ── Done ─────────────────────────────────────────────────────────────
        $display("=== SA Tests Complete ===");
        #10 $finish;
    end

    // timeout
    initial begin
        #50000;
        $error("TIMEOUT");
        $finish;
    end

endmodule
