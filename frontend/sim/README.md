## systolic version 1 (NxN)
The verifications of 2x2 -> NxN arrays passed  

**steps**:
- change the number N of matmul(N,N) in `./sim/golden_ref.py`
- execute `./sim/golden_ref.py`
- change parameters ROW and COL to the same numver as N in `../rtl/tb/tb_systolic_NxN.sv`
- run `vsim -c -do systolic_NxN.do`

## systolic version 2 (NxM)
**Add new functions**: Can directly use `vsim -c -do "set ROW 2; set COL 5; set CIN 3; do systolic_NxM.do"` in command line to parametize the RTL and golden reference. 
**steps**:
- run `vsim -c -do "set ROW 2; set COL 5; set CIN 3; do systolic_NxM.do"`  
ps: change the number to what you want 

## Level2 array top
**Add new functions**:
- Use `gemm_tile_loader.sv` to preload one GEMM output tile into local buffers.
- Verify both normal run and deterministic `run_en_i` stall mode in one `.do` flow.
- Golden reference is generated from full matrices `A[M][K]`, `B[K][N]`, and `C[M][N]`.

Default case:
- `ROW = 14`
- `COL = 16`
- `K_MAX = 512`
- `M = 7`
- `K = 512`
- `N = 128`

This means:
- `A` is `7 x 512`
- `B` is `512 x 128`
- `C` is `7 x 128`
- compare `896` valid outputs

**steps**:
- run `vsim -c -do array_level2_top.do`

**Parameterize**:
- run `vsim -c -do "set ROW 14; set COL 16; set K_MAX 512; set M 7; set K 512; set N 128; do array_level2_top.do"`

ps:
- The `.do` file runs `STALL_MODE=0` first, then `STALL_MODE=1`.
- Temporary local-buffer preload from TB is no longer used in this Level2 test; TB provides a fake 1-cycle global-buffer memory model.
