setenv LMC_TIMEUNIT -9

exec python3 gold_models/conv1x1_level3_ref.py

vlib work
vmap work work

vlog -sv -work work "../rtl/src/sram_simple_dual_port_model.sv"
vlog -sv -work work "../rtl/src/layer_defs_pkg.sv"
vlog -sv -work work "../rtl/src/quantface_conv1x1_params_pkg.sv"
vlog -sv -work work "../rtl/src/activation_output_global_buffer.sv"
vlog -sv -work work "../rtl/src/weight_global_buffer.sv"
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
vlog -sv -work work "../rtl/src/conv1x1_level3_top.sv"
vlog -sv -work work "../rtl/tb/tb_conv1x1_level3_top.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_conv1x1_level3_top -wlf tb_conv1x1_level3_top.wlf

onfinish stop
run -all

quit -f
