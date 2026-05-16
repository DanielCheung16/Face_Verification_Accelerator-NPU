#!/usr/bin/env python3.8
"""
strip_stubs.py <input.v> <output.v>

Removes empty black-box module definitions from a Genus-generated netlist so
that the GL testbench can supply its own behavioral models without triggering
a "module redefinition" error in Xcelium.

A module is considered an empty stub if it contains no cell instantiations
(i.e. no lines that end with ');' after removing port/wire/input/output decls).
"""

import re
import sys

STUBS = [
    # v2 new-syn: real OpenRAM macro stubs (replaced behavioral mfn_psum_sram wrapper)
    "sram_psum_a_1rw1r0w_40_512_freepdk45",
    "sram_psum_b_1rw0r0w_40_512_freepdk45",
    # ROM/config stubs (unchanged)
    "mfn_weight_rom_DWIDTH16",
    "mfn_bias_rom_DWIDTH32",
    "mfn_prelu_rom_DWIDTH16",
    "mfn_layer_config_rom",
]

if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <input.v> <output.v>")
    sys.exit(1)

with open(sys.argv[1]) as f:
    content = f.read()

for stub in STUBS:
    pattern = r'\bmodule\s+' + re.escape(stub) + r'\b.*?\bendmodule\b'
    before = len(re.findall(pattern, content, flags=re.DOTALL))
    content = re.sub(pattern, f'// [stripped] {stub}', content, flags=re.DOTALL)
    print(f"  Stripped: {stub} ({before} occurrence(s))")

with open(sys.argv[2], 'w') as f:
    f.write(content)

print(f"Written: {sys.argv[2]}")
