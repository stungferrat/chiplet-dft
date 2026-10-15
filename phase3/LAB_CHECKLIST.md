# Cadence Lab Checklist

Goal for the session: confirm the Phase 3 RTL runs on Cadence tools, get a
first real synthesis, and collect what's needed for the DFT steps.

## Before you leave home

- Copy the whole `phase3/` folder (rtl, tb, sim, syn) to a pen drive or email
  it to yourself.

## 0. Setup (the lab's usual procedure)

Do the usual mount steps from the lab sheet, then:

```sh
csh
source /home/install/cshrc
cd cadence/Digital2026
mkdir <your USN>          # skip if it already exists
cd <your USN>
```

Copy the `phase3/` folder in here, keeping its `rtl/ tb/ sim/ syn/` layout.
The scripts use relative paths (`../rtl`), so the layout matters.

## 1. Gather information (about 10 minutes, most important)

These answers decide the rest of the project. Write them down.

```sh
which xrun genus modus lec imc joules
ls /home/cadence/Desktop/rcfiles/lib
grep -c "SDFF" /home/cadence/Desktop/rcfiles/lib/slow.lib
```

- [ ] Which tools exist? Especially **Modus** (ATPG, needed for fault coverage)
      and **Joules** (power).
- [ ] What else is in the `lib` folder? (`fast.lib`, `typical.lib`, `.lef`
      files are all useful later.)
- [ ] Does the `grep` print a number greater than 0? That means `slow.lib` has
      **scan flip-flops**, which scan insertion needs. If it prints 0, try
      `grep -i "scan" .../slow.lib | head`.

## 2. Simulation on Xcelium

```sh
cd phase3/sim
sh run_xcelium.sh
```

- [ ] `run_lat1.log` ends in `ALL TESTS PASSED`
- [ ] `run_lat3.log` ends in `ALL TESTS PASSED`
- [ ] Open coverage: `imc -load cov_work/scope/test`. Note the **line,
      branch, FSM and toggle %** per module, or take screenshots.

Waveforms, if you want them: same command as the lab sheet, plus `-define SIM`:

```sh
xrun -sv -define SIM -access +rwc -timescale 1ns/1ps ../rtl/*.v ../tb/tb_chiplet_soc.v -gui
```

If anything fails on Xcelium that passed on Icarus, save the log. That's a
real finding, not something to ignore.

## 3. First synthesis on Genus

```sh
cd phase3/syn
genus -files genus_trial.tcl -log genus_trial
```

The library path is already set in the script, from the lab sheet. When it
finishes, `gui_show` opens the schematic for snapshots; `exit` quits.

Check `reports/area.rep`:

- [ ] **`u_chiplet1` appears** with a real cell count. This is the main thing
      to confirm; it was missing in the old report.
- [ ] **`u_link` appears.**
- [ ] Note the cell count / area of `u_chiplet1`, `u_imem`, `u_rf`,
      `u_chiplet2`, `u_array`, `u_bist`.

Then:

- [ ] `reports/check_design.rep`: note any undriven / unloaded pins (the old
      one had 152).
- [ ] `reports/timing.rep`: note the **slack**. Positive = meets 100 MHz.
- [ ] `reports/power.rep`: note total power.

If Genus errors out, save `genus_trial.log` and bring it back. Do not spend
the session fighting it.

## 4. If there is time left

- [ ] Start `modus` and check that it opens (license OK).

## Bring back

- The `.log` files from sim and synthesis
- Everything in `phase3/syn/reports/`
- `phase3/syn/outputs/chiplet_soc_top_netlist.v`
- Coverage numbers or screenshots
- The answers from step 1
