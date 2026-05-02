## systolic version 1 (NxN)
The verifications of 2x2 -> NxN arrays passed  

**steps**:
- change the number N of matmul(N,N) in `./sim/golden_ref.py`
- execute `./sim/golden_ref.py`
- change parameters ROW and COL to the same numver as N in `../rtl/tb/tb_systolic_NxN.sv`
- run `vsim -c -do systolic_NxN.do`