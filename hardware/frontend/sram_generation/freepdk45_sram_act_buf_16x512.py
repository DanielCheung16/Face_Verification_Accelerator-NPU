# ============================================================
# OpenRAM Config — mfn_act_buf SRAM
#
# Replaces the 512×16-bit FF array (8192 FFs, ~312 K um2) in mfn_act_buf.sv
# with a single-port SRAM macro.
#
# Interface (1RW):
#   Write : load_en=1, addr=load_ch[8:0], din=pixel_in[15:0]
#   Read  : addr=base_ch[8:0], dout=act_val[15:0]  (registered output)
#
# Trade-off vs FF array:
#   Area : ~13 K um2 (vs 312 K um2) — 24× smaller
#   Read latency: 1 cycle registered (vs 0-cycle combinational in FF RTL)
#   → mfn_act_buf_sram.sv wrapper adds a 12-cycle prefetch buffer (one
#     channel per cycle) to preserve the 12-wide output to the SA.
#
# 16-bit / 8 = 2 → write_size = 8 (2-byte mask, valid)
# ============================================================

word_size  = 16
num_words  = 512
write_size = 8

num_rw_ports = 1
num_r_ports  = 0
num_w_ports  = 0

tech_name            = "freepdk45"
nominal_corner_only  = True

route_supplies  = False
check_lvsdrc    = False
perimeter_pins  = False

output_name = "sram_act_buf_1rw0r0w_16_512_freepdk45"
output_path = "macro/{}".format(output_name)
