vlib work
vmap work work

vlog -sv -work work "../rtl/src/local_byte_buffer.sv"
vlog -sv -work work "../rtl/src/tb_pingpong_act_unit.sv"
vlog -sv -work work "../rtl/tb/tb_pingpong_act_unit.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_pingpong_act_unit -wlf tb_pingpong_act_unit.wlf
run -all
quit
