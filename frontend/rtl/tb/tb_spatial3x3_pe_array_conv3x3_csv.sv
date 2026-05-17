`timescale 1ns/1ps

module tb_spatial3x3_pe_array_conv3x3_csv;
    parameter int DATA_W = 8;
    parameter int ACC_W = 32;
    parameter int HALF_CYCLE_TIME = 5;

    // CSV layer shape reference:
    //   conv1.conv: conv3x3, in=112x112x3, out=56x56x64, stride=2, pad=1.
    // This test checks the reusable 3x3 PE array as the arithmetic unit for a
    // traditional conv3x3. The outer IC/OC scheduler and psum accumulator are
    // not part of spatial3x3_dev yet, so the TB performs the IC accumulation.
    localparam int IN_SIZE = 112;
    localparam int IN_C = 3;
    localparam int OUT_C_CHECK = 8;
    localparam int SAMPLE_X = 5;
    localparam int SAMPLE_Y = 7;
    localparam int PIPE_LAT = 5;

    logic clk;
    logic rst_n;
    logic enable_i;
    logic signed [DATA_W-1:0] activation_i [9];
    logic signed [DATA_W-1:0] weight_i [9];
    logic signed [ACC_W-1:0] psum_o;
    logic valid_o;

    int signed expected_partial_q[$];
    int signed accum [OUT_C_CHECK];
    int signed golden [OUT_C_CHECK];
    int out_idx_q[$];
    int fail_cnt;
    int valid_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    spatial3x3_pe_array #(
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .enable_i(enable_i),
        .activation_i(activation_i),
        .weight_i(weight_i),
        .psum_o(psum_o),
        .valid_o(valid_o)
    );

    function automatic int signed act_value(input int x, input int y, input int ic);
        begin
            act_value = ((x * 3 + y * 5 + ic * 11) % 23) - 11;
        end
    endfunction

    function automatic int signed wgt_value(input int oc, input int ic, input int pos);
        begin
            wgt_value = ((oc * 5 + ic * 7 + pos * 3) % 29) - 14;
        end
    endfunction

    function automatic int signed partial_dot(input int oc, input int ic);
        int signed acc;
        int ix;
        int iy;
        int pos;
        begin
            acc = 0;
            pos = 0;
            for (int kx = 0; kx < 3; kx++) begin
                for (int ky = 0; ky < 3; ky++) begin
                    ix = (SAMPLE_X << 1) + kx - 1;
                    iy = (SAMPLE_Y << 1) + ky - 1;
                    if ((ix >= 0) && (ix < IN_SIZE) &&
                        (iy >= 0) && (iy < IN_SIZE)) begin
                        acc += act_value(ix, iy, ic) * wgt_value(oc, ic, pos);
                    end
                    pos++;
                end
            end
            partial_dot = acc;
        end
    endfunction

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic drive_partial(input int oc, input int ic);
        int ix;
        int iy;
        int pos;
        begin
            pos = 0;
            for (int kx = 0; kx < 3; kx++) begin
                for (int ky = 0; ky < 3; ky++) begin
                    ix = (SAMPLE_X << 1) + kx - 1;
                    iy = (SAMPLE_Y << 1) + ky - 1;
                    if ((ix >= 0) && (ix < IN_SIZE) &&
                        (iy >= 0) && (iy < IN_SIZE)) begin
                        activation_i[pos] = DATA_W'(act_value(ix, iy, ic));
                    end else begin
                        activation_i[pos] = '0;
                    end
                    weight_i[pos] = DATA_W'(wgt_value(oc, ic, pos));
                    pos++;
                end
            end
            expected_partial_q.push_back(partial_dot(oc, ic));
            out_idx_q.push_back(oc);
            @(negedge clk);
            enable_i = 1'b1;
            @(negedge clk);
            enable_i = 1'b0;
        end
    endtask

    initial begin
        fail_cnt = 0;
        valid_cnt = 0;
        rst_n = 1'b0;
        enable_i = 1'b0;
        for (int pos = 0; pos < 9; pos++) begin
            activation_i[pos] = '0;
            weight_i[pos] = '0;
        end
        for (int oc = 0; oc < OUT_C_CHECK; oc++) begin
            accum[oc] = 0;
            golden[oc] = 0;
            for (int ic = 0; ic < IN_C; ic++) begin
                golden[oc] += partial_dot(oc, ic);
            end
        end

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (int oc = 0; oc < OUT_C_CHECK; oc++) begin
            for (int ic = 0; ic < IN_C; ic++) begin
                drive_partial(oc, ic);
            end
        end

        repeat (PIPE_LAT + 4) @(posedge clk);
        check(valid_cnt == OUT_C_CHECK * IN_C,
              $sformatf("valid count expected=%0d got=%0d", OUT_C_CHECK * IN_C, valid_cnt));

        for (int oc = 0; oc < OUT_C_CHECK; oc++) begin
            check(accum[oc] == golden[oc],
                  $sformatf("oc %0d accumulated conv3x3 expected=%0d got=%0d",
                            oc, golden[oc], accum[oc]));
        end

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] spatial3x3 PE conv3x3 CSV FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] spatial3x3 PE conv3x3 CSV PASSED oc_checked=%0d ic=%0d",
                 OUT_C_CHECK, IN_C);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n && valid_o) begin
            int signed exp;
            int oc;
            check(expected_partial_q.size() > 0, "unexpected extra valid_o");
            check(out_idx_q.size() > 0, "missing oc index for PE output");
            if ((expected_partial_q.size() > 0) && (out_idx_q.size() > 0)) begin
                exp = expected_partial_q.pop_front();
                oc = out_idx_q.pop_front();
                check(psum_o === ACC_W'(exp),
                      $sformatf("partial mismatch oc=%0d expected=%0d got=%0d",
                                oc, exp, psum_o));
                accum[oc] += psum_o;
            end
            valid_cnt++;
        end
    end
endmodule
