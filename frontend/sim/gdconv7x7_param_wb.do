setenv LMC_TIMEUNIT -9

vlib work
vmap work work

vlog -sv -work work "../rtl/src/spatial_pack_writeback.sv"
vlog -sv -work work "../rtl/src/gdconv7x7_param_scheduler.sv"
vlog -sv -work work "../rtl/src/gdconv7x7_wb.sv"
vlog -sv -work work "../rtl/tb/tb_gdconv7x7_param_wb.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_gdconv7x7_param_wb -wlf tb_gdconv7x7_param_wb.wlf

onfinish stop
run -all

quit -f
