vlib work
vmap work work

vlog -sv -work work "../rtl/src/small_output_process.sv"
vlog -sv -work work "../rtl/src/spatial_pack_writeback.sv"
vlog -sv -work work "../rtl/src/spatial_wb.sv"
vlog -sv -work work "../rtl/tb/tb_spatial_wb.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_spatial_wb -wlf tb_spatial_wb.wlf
run -all
quit
