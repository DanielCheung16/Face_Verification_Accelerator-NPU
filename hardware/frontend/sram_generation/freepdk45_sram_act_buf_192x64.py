# ============================================================
# OpenRAM Config — mfn_act_buf SRAM (v3+, opt④ wide-fetch version)
#
# Replaces the 512×16-bit FF array (post-opt④: 168 K cells / 260 K um²)
# with a single wide-word SRAM macro.
#
# Why 192-bit word (not 16-bit):
#   opt④ made act_buf load/read 12 channels per cycle.  A 16-bit SRAM
#   would need a 12-cycle prefetch wrapper → cancels opt④'s 1.75× speedup.
#   So the word IS one 12-channel tile: 12 × 16-bit = 192-bit.
#
# Organization:
#   act_mem channel C  →  row = C / 12 , sub-word lane = C % 12
#   512 channels / 12  =  43 rows  →  round up to 64 (6-bit address)
#
# Interface (1RW, write-masked):
#   Wide  write : whole 192-bit word (wmask = 12'hFFF)   — PW / DW12 fetch
#   Narrow write: one 16-bit lane    (wmask = one-hot)   — std / globalDW
#   Read        : whole 192-bit word, registered (1-cycle latency)
#
# write_size = 16  →  192 / 16 = 12 mask bits (one per channel lane)
# ============================================================

word_size  = 192          # 12 channels × 16-bit
num_words  = 64           # ceil(512/12)=43 → 64 (6-bit addr)
write_size = 16           # per-channel-lane write mask (12 bits)

num_rw_ports = 1
num_r_ports  = 0
num_w_ports  = 0

tech_name            = "freepdk45"
nominal_corner_only  = True

route_supplies  = False
check_lvsdrc    = False
perimeter_pins  = False

output_name = "sram_act_buf_1rw0r0w_192_64_freepdk45"
output_path = "macro/{}".format(output_name)
