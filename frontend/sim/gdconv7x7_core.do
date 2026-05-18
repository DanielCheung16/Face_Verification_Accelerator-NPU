setenv LMC_TIMEUNIT -9

vlib work
vmap work work

vlog -sv -work work "../rtl/src/gdconv7x7_core.sv"
vlog -sv -work work "../rtl/tb/tb_gdconv7x7_core.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_gdconv7x7_core -wlf tb_gdconv7x7_core.wlf

onfinish stop
run -all

quit -f
