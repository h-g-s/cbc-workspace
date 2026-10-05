# Measuring and improving CglPreProcess

How to see where integer preprocessing (`CglPreProcess::preProcessNonDefault`,
called by `cbc` before branch and bound) spends its time, how to tell whether a
change helped, and the traps that each produced a false result once while
working out the answers below.

The timing instrumentation and preprocessing correctness fixes are enabled.
The initial-LP warm-start optimization described below remains **deferred**:
although it reduced preprocessing time on the hard set, the full mip-sanity
comparison showed mixed search performance (68 wider gaps, 59 improvements).
Fixed-node reruns reproduced losses on `A-1`, `misc07`, `j3041_1`, and
`etDecsi`; omitting only that optimization restored their baseline results.
Preserving the cached basis alone still reproduced three of those losses,
while forcing primal also lost `j3041_1`'s root solution. The measurements
below describe the experimental optimization, not the current default.
With that optimization deferred, the full suite passes 509/509, matches the
baseline's 349 confirmed optima and reported gaps, and has no regressions.

## Seeing where the time goes: `-preprocTimes on`

```sh
cbc model.mps.gz -preprocTimes on -solve
```

prints, at the end of the preprocessing section,

```
  Phase                         Time(s)      %  Calls
  preprocessing (wall clock)       14.6  100.0
    CglPreProcess                  14.6  100.0      1
      model analysis              0.050    0.3      1
      initial presolve            0.117    0.8      1
      initial LP                  0.040    0.3      1
      pass presolve               0.373    2.6      9
      pass LP                     0.267    1.8      9
      modify                       1.84   12.6      9
        probing                   0.786    5.4     13
        apply row cuts            0.879    6.0     23
        ...
      pass LP re-solve             11.8   81.4      9
    outside CglPreProcess         0.000    0.0

   Pass     Rows     Cols         NZ  Changes         LP obj  Time(s) Presolve       LP   Modify  Probing
   init                                               -41.45
      1    63924    22227     371404    73566         -41.45     2.30    0.100    0.976     1.23    0.562
      2    58081    18762     287265      973         -41.45     1.34    0.106     1.03    0.209    0.098
      ...
```

(`neos-3555904-turama`, abridged) and a smaller table after postprocessing.
What to read off it:

- **The phase tree.**  27 phases (`CglPreProcessStats::Phase`), nested; each
  parent is followed by an `other` row for the time it spent outside its
  children.  Times accumulate over every `preProcessNonDefault()` call on the
  object, so Cbc's simpler retry after a failed first attempt shows up as
  `Calls 2` on the root.
- **`outside CglPreProcess`** is the caller's own time for the phase:
  checking the returned LP and retrying.  On `supportcase42` it was the whole
  story — CglPreProcess took 0.86 s, the phase 386 s, because Cbc re-solved a
  returned LP that was not proven optimal.
- **`LP obj` per pass** says whether a pass still moves the bound.  On
  `momentum1` it settled after pass 2 while passes 3–9 cost 27 of 32 s.
- **`NZ` per pass**: later passes strengthen rows by making them *denser*
  (`rd-rplusc-21`: 483k nonzeros after 3 passes, 672k after 9), which every
  later LP pays for.

From code, the same numbers are in `CglPreProcess::stats()`
(`CglPreProcess.hpp`), and Cbc's pass table is built from them rather than by
parsing message text.

## What the default path is

`cbc` calls `preProcessNonDefault(model, 2, 10, tunePreProcess)` with one
CglProbing generator (CglDuplicateRow is prepended when more than 10% of rows
are all +1).  Two facts that are easy to get wrong:

- **The effective tuning is 6, though `-tunePreProcess` reports 7.**  The
  default-strategy block in `CbcSolver.cpp` sets the variable that is used to
  6 and the displayed parameter to 7.  6 = bits 2|4, i.e. `makeIntegers2()`
  runs ("N continuous variables made integer"); bit 1 (heavy probing,
  dominated columns) is off.
- **10 passes means 9 main passes** (pass 0 is the initial presolve).
  `-tunePreProcess aa000006` sets `aa` passes, so `4000006` gives 3.
- `CBC_PREPROCESS_EXPERIMENT` looks like a dead experiment flag but is
  defined by `CoinUtils/src/CoinPresolveDupcol.hpp` unless set to 0.

## Measuring a change

1. **Time paired, never under a parallel sweep.**  Run both binaries back to
   back on the same instance in the same worker, so both see the same load
   (`.claude/local/preprocess-harness/paired.py`).  Stop cbc as soon as
   "Preprocessing complete" is printed — a run then costs root LP +
   preprocessing, not a whole solve.  Unpaired, a change measured 0.65–0.8x
   on a dozen instances that paired showed to be within noise.
2. **Prove behaviour-neutral changes neutral.**  Dead-code removal:
   `CglPreProcess.o` byte-identical with the build's own flags (they include
   `-DNDEBUG`, and `__LINE__` appears only under `COIN_DEVELOP`).  Anything
   else: the preprocessing section of the log identical with timings
   stripped, over the 40 slowest mip-sanity instances plus a random 30.  The
   `Conflict graph: built in` line must be stripped too — it is printed only
   when that time is nonzero.
3. **Judge bounds by the root bound, on the hard set.**  mip-sanity is for
   correctness; most of it preprocesses in milliseconds.  The slow cases are
   in `~/inst/miplib/2017+spp/` (48 of 339 take >= 10 s).  Use
   `.claude/local/cutgen-harness/suite-rootbound.py --mpsdir=...` with the
   filters from `BENCHMARKING-CUT-GENERATORS.md` (drop instances solved at the
   root, split on the 100-pass cap); its `pre-cut` value is the LP bound right
   after preprocessing, the most direct measure of preprocessing strength.
   Give it enough `-sec`: at 300 s, 32 of 53 slow instances produced no
   bound at all.

## Traps

- **The ClpSimplex status array is stale after OsiPresolve.**  OsiClp keeps
  its own cached warm start (`getPointerToWarmStart()`), and `initialSolve()`
  installs that over the model's status.  Reading the status array to decide
  which columns are "nonbasic" relabelled every fractional *basic* column
  superbasic and destroyed the root LP's optimal basis: `scpj1` 24908 primal
  iterations instead of 0, `scpk*` hit the 120 s initial-LP cap and
  preprocessing was abandoned.  A correct warm start from an optimal basis
  costs 0 iterations — check for it.
- **Primal, not dual, from a kept optimum.**  The initial LP's warm start is
  the root LP's optimum carried through presolve: primal feasible.  Dual from
  it cost `ex9` 51849 iterations (89 s); primal, 4.
- **"0 iterations" with perturbation off is not a solve.**  Setting Clp's
  perturbation to 100 made the per-pass re-solves report optimal in 0
  iterations — and leave the infeasible point untouched; the next pass then
  did the work.  The per-pass re-solve cost is real: dual re-solve and the
  next pass's primal cost about the same (supportcase10 34k vs 36k
  iterations).
- **`-sec` changes what preprocessing does.**  A capped initial LP returns
  NULL and Cbc falls back to the simple retry; a capped pass returns an
  unsolved LP and Cbc's double-check `resolve()` can eat the rest of the
  budget.  Time-limited runs are not preprocessing measurements.
- **gdb cannot attach** (`ptrace_scope=1`); `sample.py` preloads a shim that
  calls `prctl(PR_SET_PTRACER_ANY)`.  Its ~1 sample/s is too coarse for small
  phases — use `-preprocTimes` instead.

## Where it stands (2026-10)

On the 48 slow hard-set instances, with the experimental initial-LP
warm-start optimization, the **per-pass LP re-solve** is 63% of preprocessing time
(6362 of 10026 s; the initial LP is now 0.9%) and **probing** most of the
rest (`k1mushroom` is 99% probing).  Experiments on it so far, none
committed:

| idea | preprocessing time (paired, hard 48) | bound |
|---|---|---|
| 3 passes instead of 9 (`-tunePreProcess 4000006`) | 8232 -> 6574 s (1.25x) | mip-sanity: LP after preprocessing worse on 12 of 385 (rcpsp_n9 -3..-4%) |
| stop once a pass moves neither the LP objective (1e-5 rel.) nor any column | 5459 -> 4806 s over 45 (1.14x) | mip-sanity: worse on 3 of 387, all < 0.05% |
| re-solve with perturbation off | — | **invalid**: "optimal" in 0 iterations, point untouched |
| one-thread race warm vs cold dual, doubling slices | kumeu 637 -> 607 s, savsched1 98 -> 182 s | — |

The warm basis is often the problem, not the algorithm.  On the pass-1
re-solve, measured in-process on the same model:

| instance | warm dual | dual from slack |
|---|---|---|
| neos-3656078-kumeu | 224710 it, 156 s | 28500 it, 10 s |
| irish-electricity | 337 s | 32528 it, 37 s |
| ex9 | 23603 it, 125 s | 11762 it, 18 s |
| ex10 | ~300 s | 17954 it, 48 s |
| supportcase10 | 22357 it, 63 s | 25095 it, 68 s |
| trdta8265 | ~2.6 s | 1.8 s |
| savsched1 | ~0.1 s | > 90 s |
| gfd-schedulen180f7d50m30k18 | ~126 s | > 91 s (no progress) |

Neither the number of changes in the pass nor the iteration count predicts
which wins (ex9: 2x the iterations, 7x the time).  Slicing does not work
because an interrupted Clp solve does not resume efficiently.  What is left:
a real parallel race when threads are available, or a predictor.  Barrier is
not a candidate: on ex9 it ran 783 s through a 90 s limit.

Two more things the measurements turned up:

- Cbc's "recommended" root method for kumeu, primal + sprint, takes 750 s on
  the pass-1 model where dual takes 7 s (standalone clp); the root LP itself
  took 104 s that way.
- kumeu's default pass-2 dual re-solve gives up after 527k iterations and
  reports the (feasible) LP infeasible, which ends preprocessing early.
