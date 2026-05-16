vlib work
vmap work work

vlog -sv -work work "../rtl/src/spatial_inside_controller.sv"
vlog -sv -work work "../rtl/tb/tb_spatial_inside_controller.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_spatial_inside_controller -wlf tb_spatial_inside_controller.wlf
run -all
quit
