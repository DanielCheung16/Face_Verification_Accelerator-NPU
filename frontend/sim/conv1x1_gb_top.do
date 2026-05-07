setenv LMC_TIMEUNIT -9

if {![info exists ROW]} {set ROW 14}
if {![info exists COL]} {set COL 16}
if {![info exists K_MAX]} {set K_MAX 512}
if {![info exists SINGLE_CASE]} {set SINGLE_CASE 0}
if {![info exists POST_MODE]} {set POST_MODE 0}
if {![info exists M]} {set M 3}
if {![info exists K]} {set K 5}
if {![info exists N]} {set N 4}
if {![info exists M_MAX]} {
    if {$SINGLE_CASE} {set M_MAX $M} else {set M_MAX 32}
}
if {![info exists N_MAX]} {
    if {$SINGLE_CASE} {set N_MAX $N} else {set N_MAX 64}
}

vlib work
vmap work work

vlog -sv -work work "../rtl/src/pe_os.sv"
vlog -sv -work work "../rtl/src/systolic_array.sv"
vlog -sv -work work "../rtl/src/banked_input_buffer.sv"
vlog -sv -work work "../rtl/src/skew_addr_gen.sv"
vlog -sv -work work "../rtl/src/array_controller.sv"
vlog -sv -work work "../rtl/src/gemm_preload.sv"
vlog -sv -work work "../rtl/src/array_level2_top.sv"
vlog -sv -work work "../rtl/src/array_level2_gb_top.sv"
vlog -sv -work work "../rtl/src/conv1x1_output_postprocess.sv"
vlog -sv -work work "../rtl/src/conv1x1_gb_top.sv"
vlog -sv -work work "../rtl/tb/tb_conv1x1_gb_top.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_conv1x1_gb_top -GROW=$ROW -GCOL=$COL -GK_MAX=$K_MAX -GSINGLE_CASE=$SINGLE_CASE -GPOST_MODE=$POST_MODE -GM_SIZE=$M -GK_SIZE=$K -GN_SIZE=$N -GM_MAX=$M_MAX -GN_MAX=$N_MAX -GSTALL_MODE=0 -wlf tb_conv1x1_gb_top_nostall.wlf

onfinish stop
run -all

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_conv1x1_gb_top -GROW=$ROW -GCOL=$COL -GK_MAX=$K_MAX -GSINGLE_CASE=$SINGLE_CASE -GPOST_MODE=$POST_MODE -GM_SIZE=$M -GK_SIZE=$K -GN_SIZE=$N -GM_MAX=$M_MAX -GN_MAX=$N_MAX -GSTALL_MODE=1 -wlf tb_conv1x1_gb_top_stall.wlf

onfinish stop
run -all

quit -f
