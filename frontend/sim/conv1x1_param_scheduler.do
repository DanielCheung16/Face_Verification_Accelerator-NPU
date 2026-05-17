setenv LMC_TIMEUNIT -9

vlib work
vmap work work

vlog -sv -work work "../rtl/src/layer_defs_pkg.sv"
vlog -sv -work work "../rtl/src/conv1x1_param_scheduler.sv"
vlog -sv -work work "../rtl/tb/tb_conv1x1_param_scheduler.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_conv1x1_param_scheduler -wlf tb_conv1x1_param_scheduler.wlf

onfinish stop
run -all

quit -f
