setenv LMC_TIMEUNIT -9

exec make -C gold_models/qface_c dump_system_2_2
exec sh -c "cd gold_models/qface_c && ./dump_system_2_2 generated/system_2_2_seq1 6"

vlib work
vmap work work

vlog -sv -work work "../rtl/src/sram_simple_dual_port_model.sv"
vlog -sv -work work "../rtl/src/sram_true_dual_port_model.sv"
vlog -sv -work work "../rtl/src/layer_defs_pkg.sv"
vlog -sv -work work "../rtl/src/activation_output_global_buffer.sv"
vlog -sv -work work "../rtl/src/weight_global_buffer.sv"
vlog -sv -work work "../rtl/src/sync_rom.sv"
vlog -sv -work work "../rtl/src/quant_param_mem.sv"
vlog -sv -work work "../rtl/src/pe_os.sv"
vlog -sv -work work "../rtl/src/systolic_array.sv"
vlog -sv -work work "../rtl/src/banked_input_buffer.sv"
vlog -sv -work work "../rtl/src/skew_addr_gen.sv"
vlog -sv -work work "../rtl/src/array_controller.sv"
vlog -sv -work work "../rtl/src/gemm_preload.sv"
vlog -sv -work work "../rtl/src/array_level2_top.sv"
vlog -sv +incdir+../rtl/src -work work "../rtl/src/conv1x1_output_postprocess.sv"
vlog -sv -work work "../rtl/src/wb_buffer.sv"
vlog -sv -work work "../rtl/src/wr_controller.sv"
vlog -sv -work work "../rtl/src/conv1x1_param_scheduler.sv"
vlog -sv -work work "../rtl/src/conv1x1_inside_controller.sv"
vlog -sv -work work "../rtl/src/conv1x1_level3_top.sv"
vlog -sv -work work "../rtl/src/conv1x1_wb.sv"
vlog -sv -work work "../rtl/src/conv1x1_top.sv"
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
vlog -sv -work work "../rtl/src/small_output_process.sv"
vlog -sv -work work "../rtl/src/spatial_pack_writeback.sv"
vlog -sv -work work "../rtl/src/spatial_wb.sv"
vlog -sv -work work "../rtl/src/spatial_param_scheduler.sv"
vlog -sv -work work "../rtl/src/spatial_top.sv"
vlog -sv -work work "../rtl/src/gdconv7x7_core.sv"
vlog -sv -work work "../rtl/src/gdconv7x7_param_scheduler.sv"
vlog -sv -work work "../rtl/src/gdconv7x7_wb.sv"
vlog -sv -work work "../rtl/src/gdconv7x7_top.sv"
vlog -sv +incdir+../rtl/src -work work "../rtl/src/layer_config_mem.sv"
vlog -sv +incdir+../rtl/src -work work "../rtl/src/layer_switcher.sv"
vlog -sv -work work "../rtl/src/top.sv"
vlog -sv -work work "../rtl/tb/tb_top_system_2_2_c_ref.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_top_system_2_2_c_ref -gPROFILE=6 -wlf tb_top_system_2_2_seq1_c_ref.wlf

onfinish stop
run -all

quit -f
