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
  - Destroy around 5 rows: 90% are rows left to slacks, 10% are any
    partitioning row (`randomRowFraction`). Remove the columns that conflict
    with each row's 5 best options, rebuild, then run local search.
  - Accept solutions within 0.5% of the best.
  - After 200 iterations with no new best, the number of destroyed rows
    doubles, up to 40, then it restarts from the best.

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
  - `-sppGraspTime` (default 2 s per call).

## Results (120 s, `-threads 1`, 16 jobs in parallel, `cbc_pdi.py`)

| set | variant | PDI | opt | no sol |
|---|---|---|---|---|
| rmp01–18 | baseline (control run concurrently) | 0.285 | 12 | 1 (rmp18) |
| rmp01–18 | SppGrasp | 0.145 | 12 | 0 |
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
    --lns=100000000 --accept=0.005 --time=2       # = Cbc's settings
python3 Cbc/test/cbc_pdi.py run --out DIR --cbc BIN --sec 120 --threads 1 \
    --jobs 16 --inst-dir /home/haroldo/inst/miplib/2017+spp 'rmp*'
```
