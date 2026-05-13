# ============================================================
# Makefile for Innovus P&R — MobileFaceNet Frontend
# ============================================================
# Usage:
#   make pg     — Add VDD/VSS pins to synthesized netlist
#   make pnr    — Run Innovus place-and-route (runs pg first)
#   make clean  — Remove all P&R artifacts
# ============================================================

INNOVUS   := innovus
ENV       := /vol/ece303/genus_tutorial/cadence.env

# v1: original synthesis netlist
SYN_V     := ../frontend/syn/mfn_frontend_top_syn.v
PG_V      := mfn_frontend_top_syn_pg.v

# v2: CLA + hierarchy synthesis netlist
SYN_V2    := ../frontend/syn/mfn_frontend_top_v2_syn.v
PG_V2     := mfn_frontend_top_v2_syn_pg.v

.PHONY: pg pg_v2 pnr pnr_v2 clean

pg: $(PG_V)
$(PG_V): $(SYN_V)
	python3 add_pin.py $(SYN_V) $(PG_V)
	@echo "PG netlist written: $(PG_V)"

pg_v2: $(PG_V2)
$(PG_V2): $(SYN_V2)
	python3 add_pin.py $(SYN_V2) $(PG_V2)
	@echo "PG netlist written: $(PG_V2)"

pnr: $(PG_V)
	tcsh -c "source $(ENV) && $(INNOVUS) -files run_innovus.tcl"

pnr_v2: $(PG_V2)
	tcsh -c "source $(ENV) && $(INNOVUS) -files run_innovus_2.tcl"

clean:
	rm -rf fv innovus.cmd* innovus.log* innovus.rpt* \
	       $(PG_V) \
	       mfn_frontend_top_final.enc mfn_frontend_top_final_nophy.v \
	       mfn_frontend_top_final.sdf \
	       mfn_frontend_top.drc.rpt mfn_frontend_top.conn.rpt \
	       mfn_frontend_top.antenna.rpt \
	       pnr_timing.rep pnr_power.rep
	@echo "P&R artifacts cleaned."
