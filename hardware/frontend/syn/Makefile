# ============================================================
# Makefile for Genus Synthesis — MobileFaceNet Frontend
# ============================================================
# Usage:
#   make syn     — Run Genus synthesis (v2)
#   make syn_v3  — Run Genus synthesis (v3: 12x12 SA)
#   make clean   — Remove all synthesis artifacts
# ============================================================

GENUS     := genus
# TCL       := synthesis.tcl
TCL       := synthesis_v2.tcl
TCL_V3    := synthesis_v3.tcl

.PHONY: syn syn_v3 clean

syn:
	tcsh -c "source /vol/ece303/genus_tutorial/cadence.env && $(GENUS) -files $(TCL)"

syn_v3:
	tcsh -c "source /vol/ece303/genus_tutorial/cadence.env && $(GENUS) -files $(TCL_V3)"

clean:
	rm -rf fv genus.cmd* genus.log* genus.rpt* \
	       timing.rep area.rep gates.rep power.rep \
	       mfn_frontend_top_syn.v *.db
	@echo "Synthesis artifacts cleaned."
