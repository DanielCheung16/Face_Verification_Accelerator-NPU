// ==============================================================================
// Module: mfn_cla40
// 40-bit 2-level Carry-Lookahead Adder (5 groups × 8 bits).
// All carries resolved in O(log N) gate depth instead of O(N) ripple.
// Used by mfn_controller_v2 to break the 38-stage FA chain on psum_mem update.
// ==============================================================================

module mfn_cla40 (
    input  logic [39:0] a,
    input  logic [39:0] b,
    output logic [39:0] sum
);

    // Per-bit generate/propagate
    logic [39:0] g, p;
    assign g = a & b;
    assign p = a ^ b;

    // ── Level-1: Group Generate/Propagate (5 × 8-bit groups) ─────────────────
    // GG[k] = group generates carry regardless of carry-in
    // GP[k] = group propagates any carry-in to carry-out
    logic [4:0] GG, GP;

    // Fully expanded CLA equations to avoid any ripple within groups
    function automatic logic grp_gen;
        input logic [7:0] gi, pi;
        return gi[7] | (pi[7]&gi[6]) | (pi[7]&pi[6]&gi[5]) | (pi[7]&pi[6]&pi[5]&gi[4])
             | (pi[7]&pi[6]&pi[5]&pi[4]&gi[3]) | (pi[7]&pi[6]&pi[5]&pi[4]&pi[3]&gi[2])
             | (pi[7]&pi[6]&pi[5]&pi[4]&pi[3]&pi[2]&gi[1])
             | (&pi[7:1] & gi[0]);
    endfunction

    assign GP[0] = &p[7:0];   assign GG[0] = grp_gen(g[7:0],   p[7:0]);
    assign GP[1] = &p[15:8];  assign GG[1] = grp_gen(g[15:8],  p[15:8]);
    assign GP[2] = &p[23:16]; assign GG[2] = grp_gen(g[23:16], p[23:16]);
    assign GP[3] = &p[31:24]; assign GG[3] = grp_gen(g[31:24], p[31:24]);
    assign GP[4] = &p[39:32]; assign GG[4] = grp_gen(g[39:32], p[39:32]);

    // ── Level-2: Group carry-in (no external carry-in) ────────────────────────
    logic [4:0] CG;
    assign CG[0] = 1'b0;
    assign CG[1] = GG[0];
    assign CG[2] = GG[1] | (GP[1] & GG[0]);
    assign CG[3] = GG[2] | (GP[2]&GG[1]) | (GP[2]&GP[1]&GG[0]);
    assign CG[4] = GG[3] | (GP[3]&GG[2]) | (GP[3]&GP[2]&GG[1]) | (GP[3]&GP[2]&GP[1]&GG[0]);

    // ── Within-group CLA sum (all carries parallel) ───────────────────────────
    // For each group, carry into bit i of group is also computed with lookahead
    function automatic logic [7:0] grp_sum;
        input logic [7:0] gi, pi;
        input logic       cin;
        logic [7:0] c;  // carry into each bit position
        c[0] = cin;
        c[1] = gi[0] | (pi[0] & cin);
        c[2] = gi[1] | (pi[1]&gi[0]) | (pi[1]&pi[0]&cin);
        c[3] = gi[2] | (pi[2]&gi[1]) | (pi[2]&pi[1]&gi[0]) | (pi[2]&pi[1]&pi[0]&cin);
        c[4] = gi[3] | (pi[3]&gi[2]) | (pi[3]&pi[2]&gi[1]) | (pi[3]&pi[2]&pi[1]&gi[0])
             | (pi[3]&pi[2]&pi[1]&pi[0]&cin);
        c[5] = gi[4] | (pi[4]&gi[3]) | (pi[4]&pi[3]&gi[2]) | (pi[4]&pi[3]&pi[2]&gi[1])
             | (pi[4]&pi[3]&pi[2]&pi[1]&gi[0]) | (pi[4]&pi[3]&pi[2]&pi[1]&pi[0]&cin);
        c[6] = gi[5] | (pi[5]&gi[4]) | (pi[5]&pi[4]&gi[3]) | (pi[5]&pi[4]&pi[3]&gi[2])
             | (pi[5]&pi[4]&pi[3]&pi[2]&gi[1]) | (pi[5]&pi[4]&pi[3]&pi[2]&pi[1]&gi[0])
             | (pi[5]&pi[4]&pi[3]&pi[2]&pi[1]&pi[0]&cin);
        c[7] = gi[6] | (pi[6]&gi[5]) | (pi[6]&pi[5]&gi[4]) | (pi[6]&pi[5]&pi[4]&gi[3])
             | (pi[6]&pi[5]&pi[4]&pi[3]&gi[2]) | (pi[6]&pi[5]&pi[4]&pi[3]&pi[2]&gi[1])
             | (pi[6]&pi[5]&pi[4]&pi[3]&pi[2]&pi[1]&gi[0])
             | (&pi[6:0] & cin);
        return pi ^ c;
    endfunction

    assign sum[7:0]   = grp_sum(g[7:0],   p[7:0],   CG[0]);
    assign sum[15:8]  = grp_sum(g[15:8],  p[15:8],  CG[1]);
    assign sum[23:16] = grp_sum(g[23:16], p[23:16], CG[2]);
    assign sum[31:24] = grp_sum(g[31:24], p[31:24], CG[3]);
    assign sum[39:32] = grp_sum(g[39:32], p[39:32], CG[4]);

endmodule
