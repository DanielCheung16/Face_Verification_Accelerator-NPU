# ============================================================
# Makefile for Innovus P&R — MobileFaceNet Frontend
# ============================================================
# Usage:
#   make pg     — Add VDD/VSS pins to synthesized netlist
#   make pnr    — Run Innovus place-and-route (runs pg first)
#   make clean  — Remove all P&R artifacts
# ============================================================

INNOVUS   := innovus
TCL       := run_innovus.tcl
SYN_V     := ../frontend/syn/mfn_frontend_top_syn.v
PG_V      := mfn_frontend_top_syn_pg.v
ENV       := /vol/ece303/genus_tutorial/cadence.env

.PHONY: pg pnr clean

pg: $(PG_V)

$(PG_V): $(SYN_V)
	python3 add_pin.py $(SYN_V) $(PG_V)
	@echo "PG netlist written: $(PG_V)"

pnr: $(PG_V)
	tcsh -c "source $(ENV) && $(INNOVUS) -files $(TCL)"

clean:
	rm -rf fv innovus.cmd* innovus.log* innovus.rpt* \
	       $(PG_V) \
	       mfn_frontend_top_final.enc mfn_frontend_top_final_nophy.v \
	       mfn_frontend_top_final.sdf \
	       mfn_frontend_top.drc.rpt mfn_frontend_top.conn.rpt \
	       mfn_frontend_top.antenna.rpt \
	       pnr_timing.rep pnr_power.rep
	@echo "P&R artifacts cleaned."
