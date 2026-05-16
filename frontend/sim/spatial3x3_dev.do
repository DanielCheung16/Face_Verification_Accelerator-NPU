vlib work
vmap work work

vlog -sv -work work "../rtl/src/local_byte_buffer.sv"
vlog -sv -work work "../rtl/src/pingpong_act_unit.sv"
vlog -sv -work work "../rtl/src/spatial_act_buffer.sv"
vlog -sv -work work "../rtl/src/spatial_wgt_buffer.sv"
vlog -sv -work work "../rtl/src/spatial_addr_gen.sv"
vlog -sv -work work "../rtl/src/spatial_ld_controller.sv"
vlog -sv -work work "../rtl/src/spatial_rd_controller.sv"
vlog -sv -work work "../rtl/src/window_generator.sv"
vlog -sv -work work "../rtl/src/spatial_inside_controller.sv"
vlog -sv -work work "../rtl/src/spatial3x3_pe_array.sv"
vlog -sv -work work "../rtl/src/spatial3x3_dev.sv"
vlog -sv -work work "../rtl/tb/tb_spatial3x3_dev.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_spatial3x3_dev -wlf tb_spatial3x3_dev.wlf
run -all
quit
