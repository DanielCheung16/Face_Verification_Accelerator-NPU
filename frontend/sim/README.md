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