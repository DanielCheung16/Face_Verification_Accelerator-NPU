setenv LMC_TIMEUNIT -9

if {![info exists ROW]} {set ROW 3}
if {![info exists COL]} {set COL 4}
if {![info exists CIN]} {set CIN 5}

if {[catch {exec python3 ./gold_models/golden_ref.py $ROW $COL $CIN} result]} {
    puts $result
    quit -code 1 -f
}

vlib work
vmap work work

vlog -sv -work work "../rtl/src/pe_os.sv"
vlog -sv -work work "../rtl/src/systolic_array.sv"
vlog -sv -work work "../rtl/tb/tb_systolic_NxM.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_systolic_NxM -GROW=$ROW -GCOL=$COL -GCIN=$CIN -wlf tb_systolic_NxM.wlf

# do hash_wrap_wave.do

run -all

quit -f
