vlib work
vmap work work

vlog -sv -work work "../rtl/src/spatial_param_scheduler.sv"
vlog -sv -work work "../rtl/tb/tb_spatial_param_scheduler.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_spatial_param_scheduler -wlf tb_spatial_param_scheduler.wlf
run -all
quit
