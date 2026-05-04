setenv LMC_TIMEUNIT -9

if {![info exists ROW]} {set ROW 14}
if {![info exists COL]} {set COL 16}
if {![info exists K_MAX]} {set K_MAX 512}
if {![info exists M]} {set M 7}
if {![info exists K]} {set K 512}
if {![info exists N]} {set N 128}

if {[catch {exec python3 ./gold_models/array_level2_golden_ref.py $M $K $N} result]} {
    puts $result
    quit -code 1 -f
}

vlib work
vmap work work

vlog -sv -work work "../rtl/src/pe_os.sv"
vlog -sv -work work "../rtl/src/systolic_array.sv"
vlog -sv -work work "../rtl/src/banked_input_buffer.sv"
vlog -sv -work work "../rtl/src/skew_addr_gen.sv"
vlog -sv -work work "../rtl/src/array_controller.sv"
vlog -sv -work work "../rtl/src/gemm_tile_loader.sv"
vlog -sv -work work "../rtl/src/array_level2_top.sv"
vlog -sv -work work "../rtl/tb/tb_array_level2_top.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_array_level2_top -GROW=$ROW -GCOL=$COL -GK_MAX=$K_MAX -GM_SIZE=$M -GK_SIZE=$K -GN_SIZE=$N -GSTALL_MODE=0 -wlf tb_array_level2_top_nostall.wlf

onfinish stop
run -all

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_array_level2_top -GROW=$ROW -GCOL=$COL -GK_MAX=$K_MAX -GM_SIZE=$M -GK_SIZE=$K -GN_SIZE=$N -GSTALL_MODE=1 -wlf tb_array_level2_top_stall.wlf

onfinish stop
run -all

quit -f
