setenv LMC_TIMEUNIT -9

vlib work
vmap work work

vlog -sv -work work "../rtl/src/layer_switcher.sv"
vlog -sv -work work "../rtl/tb/tb_layer_switcher.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_layer_switcher -wlf tb_layer_switcher.wlf

onfinish stop
run -all

quit -f
