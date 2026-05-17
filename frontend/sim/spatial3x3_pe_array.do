vlib work
vmap work work

vlog -sv -work work "../rtl/src/spatial3x3_pe_array.sv"
vlog -sv -work work "../rtl/tb/tb_spatial3x3_pe_array.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_spatial3x3_pe_array -wlf tb_spatial3x3_pe_array.wlf
run -all
quit
