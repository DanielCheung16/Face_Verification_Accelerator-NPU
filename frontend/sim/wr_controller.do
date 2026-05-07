setenv LMC_TIMEUNIT -9

if {![info exists ROW]} {set ROW 14}
if {![info exists COL]} {set COL 16}

vlib work
vmap work work

vlog -sv -work work "../rtl/src/wb_buffer.sv"
vlog -sv -work work "../rtl/src/wr_controller.sv"
vlog -sv -work work "../rtl/tb/tb_wr_controller.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_wr_controller -GROW=$ROW -GCOL=$COL -wlf tb_wr_controller.wlf

onfinish stop
run -all

quit -f
