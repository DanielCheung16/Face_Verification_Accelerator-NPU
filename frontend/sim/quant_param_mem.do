vlib work
vmap work work

vlog -sv -work work "../rtl/src/sync_rom.sv"
vlog -sv -work work "../rtl/src/quant_param_mem.sv"
vlog -sv -work work "../rtl/tb/tb_quant_param_mem.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_quant_param_mem -wlf tb_quant_param_mem.wlf
run -all
quit
