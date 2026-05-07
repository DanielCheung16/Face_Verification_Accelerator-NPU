setenv LMC_TIMEUNIT -9

vlib work
vmap work work

vlog -sv -work work "../rtl/src/sram_simple_dual_port_model.sv"
vlog -sv -work work "../rtl/src/sram_true_dual_port_model.sv"
vlog -sv -work work "../rtl/src/weight_global_buffer.sv"
vlog -sv -work work "../rtl/src/activation_output_global_buffer.sv"
vlog -sv -work work "../rtl/tb/tb_global_sram_models.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_global_sram_models -wlf tb_global_sram_models.wlf

onfinish stop
run -all

quit -f
