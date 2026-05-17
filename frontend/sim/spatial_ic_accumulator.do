vlib work
vmap work work

vlog -sv -work work "../rtl/src/spatial_ic_accumulator.sv"
vlog -sv -work work "../rtl/tb/tb_spatial_ic_accumulator.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_spatial_ic_accumulator -wlf tb_spatial_ic_accumulator.wlf
run -all
quit
