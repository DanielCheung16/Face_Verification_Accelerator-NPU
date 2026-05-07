setenv LMC_TIMEUNIT -9

vlib work
vmap work work

vlog -sv -work work "../rtl/src/conv1x1_output_postprocess.sv"
vlog -sv -work work "../rtl/tb/tb_conv1x1_output_postprocess.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_conv1x1_output_postprocess -wlf tb_conv1x1_output_postprocess.wlf

onfinish stop
run -all

quit -f
