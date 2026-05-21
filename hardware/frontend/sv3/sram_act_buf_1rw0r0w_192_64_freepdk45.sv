// =============================================================================
// sram_act_buf_1rw0r0w_192_64_freepdk45.sv
//
// Behavioural model of the act_buf SRAM macro (simulation only).
//   - 1RW port, word_size = 192 bit (12 channels × 16-bit), num_words = 64
//   - write_size = 16  →  12-bit write mask (one bit per channel lane)
//   - Single-edge functional model: input latch + write/read all on posedge.
//     (Functionally cycle-accurate vs the controller's 1-cycle read scheme;
//      the OpenRAM macro is 2-edge — see .lib — which only affects STA, not
//      the functional value.)
//
// Synthesis / P&R: black box (LEF + .lib from OpenRAM); synth stub in
// syn/v3_rom_stubs.sv.
// =============================================================================

module sram_act_buf_1rw0r0w_192_64_freepdk45 (
    input  logic         clk0,
    input  logic         csb0,           // chip select (active low)
    input  logic         web0,           // write enable (active low)
    input  logic [11:0]  wmask0,         // per-16-bit-lane write mask
    input  logic [5:0]   addr0,          // 64-word address
    input  logic [191:0] din0,
    output logic [191:0] dout0
);
    logic [191:0] mem [0:63];

    always_ff @(posedge clk0) begin
        if (!csb0) begin
            if (!web0) begin                         // masked write
                for (int i = 0; i < 12; i++)
                    if (wmask0[i]) mem[addr0][i*16 +: 16] <= din0[i*16 +: 16];
            end else begin                           // registered read
                dout0 <= mem[addr0];
            end
        end
    end
endmodule
