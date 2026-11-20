# Physical design: rv32i_core on sky130_fd_sc_hd

Tool: OpenLane2 2.3.10 via the `ghcr.io/efabless/openlane2:2.3.10` Docker
image (native arm64, runs on Apple Silicon). PDK: sky130A at open_pdks
`0fe599b2afb6708d281543108caf8310912f54af` (the revision OpenLane2 2.3.10
pins), fetched with volare into `../../tools/pdk`.

```sh
make pd TAG=fix   CFG=config.json        # timing-fixed RTL, default flow settings, 20 ns
make pd TAG=final CFG=config_final.json  # + heuristic diode insertion / more antenna iterations
make metrics TAG=final                   # re-extract runs/<TAG>/summary.md
```

`base` was produced from the RTL before the timing fix (kept in
`results/timing_fix.diff`) with `config.json`. The container runs with
`-m 6g --cpus 4`. One full run takes about 15-25 minutes on this machine.

Saved results (runs/ itself is about 1.2 GB per run and git-ignored):

| dir | contents |
|---|---|
| `results/base/` | summary.md, metrics.json, post-route max.rpt (tt, ss), synthesis stat |
| `results/fix/` | same, plus the ss violator list |
| `results/final/` | same, for the antenna-repaired run |
| `results/pred/` | the ID-predecode RTL (`results/predecode.diff`) with `config_final.json` (`make pd TAG=pred CFG=config_final.json`), plus the final antenna summary |
| `results/signoff23/` | a 23 ns run with `RSZ_CORNERS` including ss: worse, kept for the record |
| `results/timing_fix.diff` | the RTL change behind base -> fix |

Constraints are OpenLane's `base.sdc` defaults: `IO_DELAY_CONSTRAINT` = 20%
of the period on all inputs/outputs (standing in for the external SRAMs),
0.25 ns clock uncertainty, 5% timing derate, 33.4 fF output load.
