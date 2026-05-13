# ============================================================
# OpenRAM Config — mfn_psum_sram SRAM_B
#
# Serves:
#   RW port : write_b (CLA_b result for c_out+1) + read_b (CLA_b operand)
#
# 40-bit × 512 words = 20 480 bits = 2.5 KB
# ============================================================

word_size  = 40
num_words  = 512
write_size = 8   # byte-writable (5 bytes per word); 40/8 = 5 → valid

num_rw_ports = 1
num_r_ports  = 0
num_w_ports  = 0

tech_name            = "freepdk45"
nominal_corner_only  = True

route_supplies  = False
check_lvsdrc    = False
perimeter_pins  = False

output_name = "sram_psum_b_1rw0r0w_40_512_freepdk45"
output_path = "macro/{}".format(output_name)
