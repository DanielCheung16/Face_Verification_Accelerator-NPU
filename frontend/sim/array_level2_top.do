setenv LMC_TIMEUNIT -9

if {![info exists ROW]} {set ROW 3}
if {![info exists COL]} {set COL 4}
if {![info exists CIN]} {set CIN 5}
if {![info exists NUM_TILES]} {set NUM_TILES 3}

if {[catch {exec python3 ./gold_models/array_level2_golden_ref.py $ROW $COL $CIN $NUM_TILES} result]} {
    puts $result
    quit -code 1 -f
}

vlib work
vmap work work

vlog -sv -work work "../rtl/src/pe_os.sv"
vlog -sv -work work "../rtl/src/systolic_array.sv"
vlog -sv -work work "../rtl/src/banked_input_buffer.sv"
vlog -sv -work work "../rtl/src/skew_addr_gen.sv"
vlog -sv -work work "../rtl/src/array_controller.sv"
vlog -sv -work work "../rtl/src/array_level2_top.sv"
vlog -sv -work work "../rtl/tb/tb_array_level2_top.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_array_level2_top -GROW=$ROW -GCOL=$COL -GCIN=$CIN -GNUM_TILES=$NUM_TILES -wlf tb_array_level2_top.wlf

run -all

quit -f
