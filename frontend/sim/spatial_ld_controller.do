vlib work
vmap work work

vlog -sv -work work "../rtl/src/spatial_addr_gen.sv"
vlog -sv -work work "../rtl/src/spatial_ld_controller.sv"
vlog -sv -work work "../rtl/tb/tb_spatial_ld_controller.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_spatial_ld_controller -wlf tb_spatial_ld_controller.wlf
run -all
quit
