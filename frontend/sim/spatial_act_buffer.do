vlib work
vmap work work

vlog -sv -work work "../rtl/src/local_byte_buffer.sv"
vlog -sv -work work "../rtl/src/pingpong_act_unit.sv"
vlog -sv -work work "../rtl/src/spatial_act_buffer.sv"
vlog -sv -work work "../rtl/tb/tb_spatial_act_buffer.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_spatial_act_buffer -wlf tb_spatial_act_buffer.wlf
run -all
quit
