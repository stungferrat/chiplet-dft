#!/bin/sh
# Run the Phase 3 regression on Cadence Xcelium.
# Run from the phase3/sim folder:   sh run_xcelium.sh
# Every run should end with:  ALL TESTS PASSED  (16 checks)

RTL="../rtl/riscv_pipeline_top.v ../rtl/chiplet_interconnect.v ../rtl/mem_io_chiplet.v ../rtl/chiplet_soc_top.v"
TB="../tb/tb_chiplet_soc.v"

# 1) Default link latency (1)
xrun -sv -define SIM -access +rwc -timescale 1ns/1ps $RTL $TB -l run_lat1.log

# 2) Slower link (latency 3) -- same results, more mem_wait cycles
xrun -sv -define SIM -access +rwc -timescale 1ns/1ps \
     -defparam tb_chiplet_soc_top.LINK_LATENCY=3 \
     $RTL $TB -l run_lat3.log

# 3) Code coverage (line / branch / FSM / toggle)
xrun -sv -define SIM -access +rwc -timescale 1ns/1ps \
     -coverage all -covoverwrite \
     $RTL $TB -l run_cov.log

echo "Results:"
grep -H -E "ALL TESTS PASSED|CHECK\(S\) FAILED|TIMEOUT" run_lat1.log run_lat3.log run_cov.log
echo
echo "Coverage: open it with   imc -load cov_work/scope/test"
