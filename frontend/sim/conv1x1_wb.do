set ROW 4
set COL 4

vlib work
vmap work work

vlog -sv -work work "../rtl/src/layer_defs_pkg.sv"
vlog -sv +incdir+../rtl/src -work work "../rtl/src/conv1x1_output_postprocess.sv"
vlog -sv -work work "../rtl/src/conv1x1_wb.sv"
vlog -sv -work work "../rtl/tb/tb_conv1x1_wb.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_conv1x1_wb -GROW=$ROW -GCOL=$COL -wlf tb_conv1x1_wb.wlf
run -all
