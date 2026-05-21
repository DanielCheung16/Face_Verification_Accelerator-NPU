#!/usr/bin/env python3.8
"""
strip_stubs.py <input.v> <output.v>

Removes empty black-box module definitions from the Genus-generated v3 netlist
so the GL testbench can supply behavioral models without a "module
redefinition" error in Xcelium.

v3 netlist black-box module defs (no .lib → Genus writes empty stubs):
  mfn_bias_rom
  mfn_prelu_rom
  mfn_layer_config_rom
  mfn_weight_rom_v3_SA_ROWS12_SA_COLS12   (parameter-mangled name)

NOT stripped — the SRAM macros (sram_psum_a / sram_act_buf) have .lib files,
so Genus treats them as library cells and writes NO module def in the netlist.
Their behavioral models are simply compiled alongside (no conflict).
"""

import re
import sys

STUBS = [
    "mfn_bias_rom",
    "mfn_prelu_rom",
    "mfn_layer_config_rom",
    "mfn_weight_rom_v3_SA_ROWS12_SA_COLS12",
]

if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <input.v> <output.v>")
    sys.exit(1)

with open(sys.argv[1]) as f:
    content = f.read()

for stub in STUBS:
    # Match "module <stub> ... endmodule" — \b after the name keeps
    # mfn_bias_rom from also eating a longer "mfn_bias_rom_xxx".
    pattern = r'\bmodule\s+' + re.escape(stub) + r'\b.*?\bendmodule\b'
    n = len(re.findall(pattern, content, flags=re.DOTALL))
    content = re.sub(pattern, f'// [stripped stub] {stub}', content,
                     flags=re.DOTALL)
    print(f"  Stripped: {stub} ({n} occurrence(s))")

with open(sys.argv[2], 'w') as f:
    f.write(content)

print(f"Written: {sys.argv[2]}")
