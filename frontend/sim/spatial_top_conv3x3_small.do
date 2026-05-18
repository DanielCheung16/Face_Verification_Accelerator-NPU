vlib work
vmap work work

vlog -sv -work work "../rtl/src/sync_rom.sv"
vlog -sv -work work "../rtl/src/quant_param_mem.sv"
vlog -sv -work work "../rtl/src/local_byte_buffer.sv"
vlog -sv -work work "../rtl/src/pingpong_act_unit.sv"
vlog -sv -work work "../rtl/src/spatial_act_buffer.sv"
vlog -sv -work work "../rtl/src/spatial_wgt_buffer.sv"
vlog -sv -work work "../rtl/src/spatial_addr_gen.sv"
vlog -sv -work work "../rtl/src/spatial_ld_controller.sv"
vlog -sv -work work "../rtl/src/spatial_rd_controller.sv"
vlog -sv -work work "../rtl/src/window_generator.sv"
vlog -sv -work work "../rtl/src/spatial_inside_controller_dw.sv"
vlog -sv -work work "../rtl/src/spatial_inside_controller_conv.sv"
vlog -sv -work work "../rtl/src/spatial_inside_controller.sv"
vlog -sv -work work "../rtl/src/spatial3x3_pe_array.sv"
vlog -sv -work work "../rtl/src/spatial_ic_accumulator.sv"
vlog -sv -work work "../rtl/src/spatial3x3_dev.sv"
vlog -sv -work work "../rtl/src/spatial_param_scheduler.sv"
vlog -sv -work work "../rtl/src/small_output_process.sv"
vlog -sv -work work "../rtl/src/spatial_pack_writeback.sv"
vlog -sv -work work "../rtl/src/spatial_wb.sv"
vlog -sv -work work "../rtl/src/spatial_top.sv"
vlog -sv -work work "../rtl/tb/tb_spatial_top_conv3x3_small.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_spatial_top_conv3x3_small -wlf tb_spatial_top_conv3x3_small.wlf
run -all
quit
