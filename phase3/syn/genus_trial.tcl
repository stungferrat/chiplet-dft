# =============================================================
# genus_trial.tcl -- FIRST, PLAIN synthesis of the Phase 3 RTL.
#
# Purpose: prove the design synthesizes and that Chiplet-1 and the
# link SURVIVE (the old Sep 15 report had neither). No scan, no
# clock gating yet -- this is the baseline everything is compared to.
#
# Uses the same commands as the lab's synthesis procedure.
#
# Run from the phase3/syn folder (after csh + source /home/install/cshrc):
#     genus -files genus_trial.tcl -log genus_trial
#
# Genus stays at its prompt when the script finishes, so you can type
#     gui_show
# to look at the schematic and take snapshots, then  exit  to quit.
# =============================================================

set_db init_lib_search_path /home/cadence/Desktop/rcfiles/lib
set_db hdl_search_path      ../rtl
set_db library              slow.lib

# Keep the hierarchy so the area report is broken down per chiplet.
set_db auto_ungroup none

# NOTE: no SIM define here -- the fault-injection ports must NOT be
# synthesized. That is the whole point of the `ifdef SIM.
read_hdl {riscv_pipeline_top.v chiplet_interconnect.v mem_io_chiplet.v chiplet_soc_top.v}
elaborate chiplet_soc_top

check_design -unresolved
read_sdc ./constraints.sdc

set_db syn_generic_effort medium
syn_generic
set_db syn_map_effort medium
syn_map
set_db syn_opt_effort medium
syn_opt

file mkdir reports outputs
report_area   > reports/area.rep
report_gates  > reports/gates.rep
report_timing > reports/timing.rep
report_power  > reports/power.rep
check_design -all > reports/check_design.rep

write_hdl > outputs/chiplet_soc_top_netlist.v
write_sdc > outputs/chiplet_soc_top_out.sdc

puts "=================================================="
puts " Done. Open reports/area.rep FIRST and check that"
puts " u_chiplet1 and u_link both appear in the hierarchy."
puts "=================================================="
