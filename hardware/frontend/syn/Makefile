# ============================================================
# Makefile for Genus Synthesis — MobileFaceNet Frontend
# ============================================================
# Usage:
#   make syn    — Run Genus synthesis
#   make clean  — Remove all synthesis artifacts
# ============================================================

GENUS     := genus
# TCL       := synthesis.tcl
TCL       := synthesis_v2.tcl

.PHONY: syn clean

syn:
	tcsh -c "source /vol/ece303/genus_tutorial/cadence.env && $(GENUS) -files $(TCL)"

clean:
	rm -rf fv genus.cmd* genus.log* genus.rpt* \
	       timing.rep area.rep gates.rep power.rep \
	       mfn_frontend_top_syn.v *.db
	@echo "Synthesis artifacts cleaned."
