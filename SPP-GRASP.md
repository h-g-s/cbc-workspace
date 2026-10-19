# SppGrasp — set partitioning/packing heuristic with slack columns

`CbcHeuristicSppGrasp` (`Cbc/src/CbcHeuristicSppGrasp.{hpp,cpp}`) targets pure
set partitioning/packing models (binary columns, unit coefficients, rows
`Σx = 1` or `Σx ≤ 1`) where **every partitioning row has a singleton "slack"
column** (covers only that row, at a penalty cost), so a trivial solution
always exists. The motivating instances are `rmp01`–`rmp18` in
`/home/haroldo/inst/miplib/2017+spp`. The same structure also appears in
`eil*`, `ds`, `ds-big`, `irp`, `ivu06` and `ivu06-big`. No mip-sanity-data
instance has it.

## Algorithm (class `CbcSppGrasp`)

- **Construction:** pick an uncovered partitioning row, then a column that
  covers it.
  - Row rule: max regret between the best and second-best option.
  - Column rule: "profit", `(c_j − Σ slack costs of covered rows) / k`,
    biased by the LP value (`lpWeight` 20).
  - GRASP restricted candidate lists for both choices (`colAlpha` 0.1,
    `rowAlpha` 0.2). The first construction is deterministic.
- **Local search:** insert a column, eject the columns it conflicts with,
  and greedily repair the rows left open. Worklist-based: a column is only
  re-examined when the owner of one of its rows changes.
- **LNS (most of the gain):**
  - Start from the deterministic construction or the incumbent.
  - Destroy around 5 rows: 80% are rows left to slacks, 20% are any
    partitioning row (`randomRowFraction`). Remove the columns that conflict
    with each row's 2 best options (`seedColumns`).
  - Repair: the construction, but choosing the next row at random
    (`lnsRowRule` = random) rather than by max regret.
  - Local search is restarted only from rows whose covering column changed
    (`lnsFocus`), 2.4–3.2× faster per iteration.
  - Accept solutions within 0.5% of the best (threshold acceptance).
  - After 200 iterations with no new best, the number of destroyed rows
    doubles, up to 40, then it restarts from the best.
  - **Deterministic stopping:** stop after `maxNoImprove` iterations without
    a new best, or after `maxWork` units of work, whichever is first.
    - Work (`CbcSppGrasp::work()`) is a count of basic operations, mostly
      matrix entries visited. It runs at about 450–1000 million units per
      second, roughly constant across rmp instances, so it is a
      machine-independent stand-in for time.
    - The time limit remains only as a safety net.

## Integration

- `CbcSolver::babRunSppGraspOriginal()` runs it on the **original** model,
  after the root LP and **before preprocessing**, with the LP x/dj. The
  solution becomes the incumbent of `model_`/`babModel_` and is mapped
  through preprocessing like any other pre-preprocessing incumbent.
  Preprocessing usually destroys the structure (substitutions create rows
  such as `−x6 + Σ others = 0`), so a run inside B&B alone is not enough.
- If the preprocessed model still has the structure (rmp11, 16, 18), it also
  runs at the B&B root ('L' and 'C' hooks), starting from the incumbent.
- When it applies, the **feasibility pump is switched off** unless the user
  set `-feas` explicitly. FPump defaults are now set with `setModeValAuto`
  in `CbcSolver`, so `isUserSet()` means the user really set it.
- Parameters:
  - `-sppGrasp off|on|both|before` (default `on`).
  - `-sppGraspWork` (default 1500, in millions of work units per call, about
    1.5–3 s).
  - `-sppGraspNoImprove` (default 1000 LNS iterations without a new best).
  - `-sppGraspTime` (default 60 s per call): a safety cap only, because
    reaching it makes results machine-dependent.

## Results (120 s, `-threads 1`, 16 jobs in parallel, `cbc_pdi.py`)

| set | variant | PDI | opt | no sol |
|---|---|---|---|---|
| rmp01–18 | baseline (control run concurrently) | 0.285 | 12 | 1 (rmp18) |
| rmp01–18 | SppGrasp | 0.145 | 12 | 0 |
| rmp01–18 | SppGrasp v2 (tuned LNS, work/no-improve stop) | 0.127 | 12 | 0 |
| eil*/ds/irp/ivu06 (15) | baseline | 0.675 | 5 | 3 |
| eil*/ds/irp/ivu06 (15) | SppGrasp | 0.566 | 5 | 3 |

mip-sanity-data: 511/511 pass, no regressions (`./compare-results`).

Tuning findings (`Cbc/test/spp-grasp-bench`, 3–5 seeds, gap vs BKS):

- One deterministic construction followed by LNS beats many GRASP
  constructions.
- LP guidance is essential: without it, rmp18's gap goes from ~0.7 to ~2.5.
- 2 s vs 5 s per call is within noise for PDI, and 10 s is worse.
- Running FPump alongside SppGrasp (`-feas on`) gains nothing: FPump is
  skipped once there is an incumbent.
- What helped:
  - random non-slack seed rows: near-optimal count 29 → 37 of 85 runs.
  - stagnation growth of the destroy size.
- What did not help:
  - a larger seed-column pool;
  - LP-value fixing (columns with LP value ≥ t) before construction.
- `bks.tsv` is stale for rmp16 and rmp17: SppGrasp+B&B finds better solutions.

## LNS tuning and stopping rule (v2)

- **Method:** sweeps with `spp-grasp-bench --trace`, 5–10 seeds × 18 rmp
  instances, one long run per (config, seed).
  - A stop rule never changes a run's trajectory (deterministic RNG), so
    every fixed budget and every no-improve rule is replayed offline from
    the traces.
  - Gap reference: best of `bks.tsv` and every solution found.
- **One-factor sweep** at 20k iterations (mean gap / gap without rmp18):
  | setting | gap |
  |---|---|
  | base | 2.42 / 1.55 |
  | random LNS row order | 1.07 / 0.87 |
  | `rrows` 0.2 | 1.82 / 1.30 |
  | `dcols` 2 (also about 40% faster) | 1.86 / 1.37 |
  | LAHC, L=100 | 1.92 / 1.48 |
- **Other settings** (`drows`, `stall`, `maxdrows`, `pool`, `dfrac`,
  `scan`, LP weight, threshold 0.002–0.01) were neutral or worse.
  - Threshold 0 (pure descent) is clearly worse.
  - Disabling the local search in the repair is terrible.
- **LAHC (Late Acceptance Hill Climbing):** implemented (`acceptMode` 1/2,
  `lahcLength`) but not adopted.
  - The history length must scale with the budget (L ≈ budget/100).
  - With the random row order it is worse than threshold acceptance at every
    budget up to 20k iterations (e.g. at 5k: 6.8 vs 2.5 mean gap).
  - LAHC-better (history entries replaced only by better values) behaves
    like LAHC.
- **Work budgets** (mean gap / gap without rmp18, 10 seeds):
  | config | 1G | 5G | 10G |
  |---|---|---|---|
  | base | 6.4 / 2.9 | 3.8 / 1.7 | 3.2 / 1.3 |
  | `rrows` 0.2 + `dcols` 2 (adopted) | 4.7 / 2.5 | 2.7 / 1.4 | 1.8 / 1.2 |
- **Stopping rule:** PDI at 120 s with concurrent controls:
  | stop (no-improve iterations, work in millions) | PDI | opt |
  |---|---|---|
  | control (2 s) | 0.155, 0.154 | 12 |
  | 1000, 1500 (adopted) | 0.127 | 12 |
  | 2000, 3000 | 0.126 | 11 |
  | 5000, 8000 | 0.142 | 11 |

  The largest budget hurts rmp11/16, where the heuristic time is taken from
  B&B.
- Speed-ups that keep the output bit-identical:
  - lazy liveness in the construction for rules that need no option counts
    (≈1.4×);
  - pruning in the greedy repair: give up once `delta` + a lower bound for
    the remaining open rows ≥ 0 (3–5×).

## Open problems

- **rmp18** is still ~0.7–0.9 above BKS (≈45 slack rows vs 6). Its LP bound
  is within 0.3% of BKS, so it is the primal side that fails, and neither
  greedy+LNS nor LP fixing closes it. A sub-MIP over the LNS neighbourhood
  is the next thing to try.
- **rmp16 and rmp17** are limited by the dual bound, not the primal one.

## Reproducing

```sh
cd Cbc/test && make spp-grasp-bench
./spp-grasp-bench rmp14.mps.gz --lpcache=/tmp/spp/lp --iters=1 \
    --lns=100000000                                # = Cbc's settings
# tuning: run unbounded and replay the trace offline
./spp-grasp-bench rmp14.mps.gz --lpcache=/tmp/spp/lp --iters=1 --lns=20000 \
    --noimp=0 --maxwork=0 --seed=3 --trace=rmp14.3.tr
python3 Cbc/test/cbc_pdi.py run --out DIR --cbc BIN --sec 120 --threads 1 \
    --jobs 16 --inst-dir /home/haroldo/inst/miplib/2017+spp 'rmp*'
```
