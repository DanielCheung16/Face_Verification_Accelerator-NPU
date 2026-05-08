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

## Level3 array top
`array_level2_top.sv` now only contains the local banked buffers, skew read path, controller, and systolic array. `gemm_preload.sv` is the global-buffer-to-local-buffer preload block. `array_level2_gb_top.sv` connects both blocks and is the top used by the global-buffer-facing test.

Default regression:
- `ROW = 14`
- `COL = 16`
- `K_MAX = 512`
- Runs several built-in matrix sizes, including partial tiles and a `K=512` case.
- Runs twice: `STALL_MODE=0`, then `STALL_MODE=1`.

Run the default regression:
- `vsim -c -do array_level2_gb_top.do`

Run one matrix size:
- `vsim -c -do "set SINGLE_CASE 1; set ROW 14; set COL 16; set K_MAX 512; set M 3; set K 5; set N 4; do array_level2_gb_top.do"`

Matrix meaning:
- `C[M][N] = A[M][K] * B[K][N]`
- `ROW` tiles the `M` dimension.
- `COL` tiles the `N` dimension.

`array_level2_top.do` is kept as an alias to the same Level2 global-buffer-facing regression.

## Conv1x1 output postprocess
`conv1x1_output_postprocess.sv` converts the `INT32` accumulator tile from the systolic array to signed int8. The supported postprocess modes are:

- `POST_MODE=0`: requant only
- `POST_MODE=1`: PReLU, then requant
- `POST_MODE=2`: residual add, then requant

`out = saturate_int8((((acc + bias) * multiplier) + rounding) >>> shift + zero_point)`

In `POST_MODE=1`, negative `acc + bias` values are first multiplied by `prelu_multiplier` and shifted by `prelu_shift`.

In `POST_MODE=2`, `residual_i` is added in the accumulator domain before requantization.

Run the standalone 32-bit to 8-bit postprocess test:
- `vsim -c -do conv1x1_output_postprocess.do`

Run the full conv1x1 flow, including preload, systolic GEMM, and output postprocess:
- `vsim -c -do conv1x1_gb_top.do`

Run the full conv1x1 flow with PReLU postprocess:
- `vsim -c -do "set POST_MODE 1; do conv1x1_gb_top.do"`

Run the full conv1x1 flow with residual-add postprocess:
- `vsim -c -do "set POST_MODE 2; do conv1x1_gb_top.do"`

Run one conv1x1 matrix size:
- `vsim -c -do "set SINGLE_CASE 1; set ROW 14; set COL 16; set K_MAX 512; set M 3; set K 5; set N 4; do conv1x1_gb_top.do"`

The current conv1x1 tests use deterministic synthetic int8 activations, weights, bias, and requant parameters. They verify the hardware dataflow and fixed-point requantization, not a bit-exact MobileFaceNet checkpoint layer yet.

## Conv1x1 Level3 closed flow
`conv1x1_level3_top.sv` is the conv1x1 layer engine used below the future global-buffer switch/controller. It does not instantiate the global SRAMs directly; the testbench owns `activation_output_global_buffer.sv` and `weight_global_buffer.sv` and connects them to the layer ports.

In the current Level3 design, one output tile row must fit exactly into one global memory word:
- `COL * 8 bits = one memory word`
- More generally, `COL * DATA_IN_W == DATA_OUT_W` for `wb_buffer.sv`

The default Level3 regression uses `COL=4` and `GB_DATA_W=32` for a small fast test. The target accelerator setting is `COL=16` and `GB_DATA_W=128`.

Run the closed two-layer conv1x1 regression:
- `vsim -c -do conv1x1_level3_top.do`
