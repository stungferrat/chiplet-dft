#!/bin/sh
# Model-checked regression on Cadence Xcelium.
# Run from the phase3/verif folder:   sh run_xcelium_verify.sh
# The test vectors are already generated in ./vectors (no Python needed).
# Every run should end with:  ALL TESTS PASSED

RTL="../rtl/riscv_pipeline_top.v ../rtl/chiplet_interconnect.v ../rtl/mem_io_chiplet.v ../rtl/chiplet_soc_top.v"
TB="../tb/tb_core_verify.v"
OPTS="-sv -define SIM -access +rwc -timescale 1ns/1ps"

# 1) Link latency 1
xrun $OPTS $RTL $TB -l verify_lat1.log

# 2) Link latency 3
xrun $OPTS -defparam tb_core_verify.LINK_LATENCY=3 $RTL $TB -l verify_lat3.log

# 3) Code coverage on the full model-checked run
xrun $OPTS -coverage all -covoverwrite -covtest verify $RTL $TB -l verify_cov.log

echo
echo "Results:"
grep -H -E "CPU tests:|ALL TESTS PASSED|FAILURE" verify_lat1.log verify_lat3.log verify_cov.log
echo
echo "Coverage: open it with   imc -load cov_work/scope/verify"
