setenv LMC_TIMEUNIT -9

if {[catch {exec python3 ./gold_models/golden_ref.py} result]} {
    puts $result
    quit -code 1 -f
}

vlib work
vmap work work

vlog -sv -work work "../rtl/src/pe_os.sv"
vlog -sv -work work "../rtl/src/systolic_array.sv"
vlog -sv -work work "../rtl/tb/tb_systolic_NxN.sv"

vsim -c -t 1ns -classdebug -voptargs=+acc +notimingchecks -L work work.tb_systolic_NxN -wlf tb_systolic_NxN.wlf

# do hash_wrap_wave.do

run -all

quit -f
