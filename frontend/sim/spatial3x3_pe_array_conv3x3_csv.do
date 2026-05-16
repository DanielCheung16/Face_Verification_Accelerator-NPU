vlib work
vmap work work

vlog -sv -work work "../rtl/src/spatial3x3_pe_array.sv"
vlog -sv -work work "../rtl/tb/tb_spatial3x3_pe_array_conv3x3_csv.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_spatial3x3_pe_array_conv3x3_csv -wlf tb_spatial3x3_pe_array_conv3x3_csv.wlf
run -all
quit
