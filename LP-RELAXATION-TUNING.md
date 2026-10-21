# LP relaxation parameter tuning

Ported from an earlier, standalone `~/dev/cbc` checkout (pre-dating this
workspace) where a first round of experiments tuned the method/parameters CBC
uses to solve the **root LP relaxation** (`-initialSolve`): dual vs. primal
simplex, dual pivot rule, perturbation, idiot/sprint crash, and barrier
(Cholesky variant). Scripts, parameter files, prior reports, and the
machine-learning analysis workflow all live under `Cbc/test/lp-tuning/` —
this file is the entry point/history note; see
`Cbc/test/lp-tuning/doc/lp_racing_analysis_howto.md` for the full step-by-step
how-to.

## Layout

```
Cbc/test/lp-tuning/
├── run_lp_experiments.sh        orchestrator: instances × params × seeds, GNU parallel, resumable
├── run_one_lp.sh                worker invoked by the orchestrator (one job)
├── monitor_lp_experiment.sh     live snapshot: progress, statuses, peak/current RSS of jobs
├── lp_params.txt                current parameter set in use (tag|cbc_params)
├── lp_params_orig.txt           original non-barrier set (dual/primal/idiot/sprint variants)
├── lp_params_extended.txt       extended set (superset used in later rounds)
├── lp_params_barrier.txt        barrier variants, kept separate (memory-heavy)
├── analyze_lp_params.py         per-(instance,param) SGM ranking, head-to-head, error/timeout accounting
├── analyze_racing_portfolios.py racing/portfolio (K parallel CLP solves, min(t_1..t_K)) analysis
├── run_lp_dtree.py              feature-based decision tree (which param per instance-structure leaf)
├── make_lp_report.py            6-page PDF report (charts + decision tree + key findings)
├── summarize_lp_results.py      fake-optimal / timeout / correctness validation pass
├── compare_fpp_results.py       cross-check helper against miplib2017 .solu reference file
├── ml/                          heavier ML workflow: k-fold validated classifiers/regressors/clustering
│   ├── cluster_lp_params.py               cluster instances by which params solve them well
│   ├── build_lp_param_scorer.py           per-instance param scoring/ranking model
│   ├── build_racing_portfolios_by_group.py per-cluster racing portfolio construction
│   └── kfold_*.py                         k-fold validated: decision tree (sklearn/fbps-style),
│                                           random forest, XGBoost, LightGBM, multi-output
│                                           regression, single-param and racing-portfolio
│                                           recommenders — see each file's docstring for its
│                                           strategy/methodology
└── doc/                         prior reports and process how-tos (see below)
```

## Prior reports (background reading before another tuning round)

- `doc/lp_racing_analysis_howto.md` — **the workflow document**: run →
  per-param analysis → racing/portfolio analysis → decision tree → PDF report
  → validation, with exact commands for each step and how to interpret every
  table (SGM ranking, portfolio construction curve, decision-tree leaves,
  uniqueness table, etc.).
- `doc/barrier-experiment-report.tex`/`.pdf` — first (small-scale, 11
  instances) barrier vs. primal/dual comparison. Conclusion at the time:
  primal simplex was the best default; native-Cholesky barrier was only
  competitive on a couple of dense instances at a 10–15× memory cost;
  AMD/`-chol uni` gave no benefit; barrier diverged/failed on degenerate LPs
  (`seymour`, `momentum1`). **This is the natural starting point for the next
  round** — the barrier method was never tuned at the scale the dual/primal
  variants were (only the small `lp_params_barrier.txt` set, never merged into
  the main `lp_params.txt`/racing-portfolio/decision-tree pipeline).
- `doc/guess_methods_report.tex`/`.pdf` — evaluation of CBC's `guess()`
  heuristic (which auto-picks dual/primal/other settings) against the 4
  decision-tree leaves it encodes.
- `doc/guess_option.tex`/`.pdf` — candidate options considered for `guess()`,
  including the barrier candidates referenced by `lp_params_barrier.txt`.
- `doc/clp-tuning-guide.tex`/`.pdf` — general CLP parameter reference (not
  experiment-specific), useful background on what each `-dualPivot`/`-idiot`/
  `-cholesky`/etc. option actually does.
- `doc/exp_guess.md`, `doc/lp_relax_experiments.md` — original short task
  briefs that kicked off this line of experiments.
- `doc/parallel_experiments_howto.md` — general GNU-parallel experiment
  patterns (worker/orchestrator script pairing, common pitfalls) used
  throughout this workspace's benchmarking tooling, not LP-tuning specific.
- `doc/lp-method-auto-tuning.md` — **short blog-post write-up** (drafted for
  publication, never posted) summarizing the whole ML effort end-to-end:
  classification framing (predict fastest LP param from 207 `OsiFeatures`
  structural features), model comparison (decision tree/Random Forest/
  XGBoost/LightGBM/multi-output regression — Random Forest won, 1.33× k-fold
  speedup, and is the only one whose `m2cgen`-generated C++ export was small
  enough to embed), the win-profile Jaccard/Ward-clustering trick that
  shrank 70 candidate params down to 12 well-separated classes (bumping the
  speedup to 1.36×), the most predictive features (objective-coefficient
  scale, covering-row fraction, density), and which instances benefit most
  (large, very sparse, set-covering/packing problems — up to 50× on the LP
  alone). **Note:** the described integration (`-lpMethod=auto`,
  `CbcLpParamScorer.{hpp,cpp}`) was implemented in the `mipster` fork, not
  upstream `Cbc` — treat the ML methodology as the reusable part, not the
  described C++ integration point.
- `doc/analyze_lp_tunning_parameters.md` — the task brief that drove the
  k-fold methodology: how instances are split into 10 folds
  (`~/inst/miplib/2017+spp/partitions/fold_NN.txt`, seed 42, round-robin, no
  overlap), the train-on-9/validate-on-1 protocol, and the correctness/
  timing-penalty convention (wrong or infeasible results penalized at 2×
  the time limit so every outcome reduces to a single comparable time).

## Quick start (matching this workspace's conventions)

```sh
./config --opt --install     # build cbc first

Cbc/test/lp-tuning/run_lp_experiments.sh \
  --bin ~/prog/cbc/bin/cbc \
  --params Cbc/test/lp-tuning/lp_params.txt \
  --instances ~/inst/miplib/2017+spp \
  --timelimit 14400 \
  --seeds 1,2,3 \
  --outdir ~/experiments/cbc/lp_relaxation_$(date +%Y_%m_%d)
```

Then follow `doc/lp_racing_analysis_howto.md` steps 2–4 (per-param analysis,
racing/portfolio analysis, decision tree, PDF report).

## Barrier round (Cholesky variants, memory-capped)

The ML model behind `-lpMethod recommend` was trained on
`lp_relax_2026_05_15_noblas`: 70 simplex configs and no barrier. Barrier
*was* run earlier (`04_27`/`04_28`), but only on a `_noblas` build, with no
memory control, and with barrier failures that did not show up in the
results (see below). `lp_params_barrier.txt` holds the three variants to
test: `-cholesky native` (the default), `dense` and `Uni`
(UniversityOfFlorida = SuiteSparse CHOLMOD + AMD ordering).

```sh
EXP=~/experiments/cbc/lp_barrier_2026_09_28
mkdir -p $EXP
# same 380 instances the simplex round (and the ML model) used
awk -F, 'NR>1 {print $1}' ~/experiments/cbc/lp_relax_2026_05_15_noblas/lp_results.csv \
  | sort -u > $EXP/instances.txt
nohup Cbc/test/lp-tuning/run_lp_experiments.sh \
  --bin ~/prog/cbc/bin/cbc \
  --params Cbc/test/lp-tuning/lp_params_barrier.txt \
  --instance-list $EXP/instances.txt \
  --timelimit 10800 --overtime 600 --seeds 1,2,3 \
  --parallel 32 --mem-limit 12G --mem-method cgroup \
  --common-args "-rowReductions force" \
  --outdir $EXP > $EXP/nohup.log 2>&1 &

Cbc/test/lp-tuning/monitor_lp_experiment.sh $EXP            # or: --watch 60
echo 48 > $EXP/parallel_jobs   # change parallelism live (applied as jobs finish)
```

Points to keep in mind for this round:

- **No failure fallback in training experiments.** Build a dedicated binary
  with `CLP_BARRIER_NO_FALLBACK` to stop immediately with a `CoinError` when
  barrier returns status 4 (Cholesky setup/factorization failure), rather than
  solving the job with dual simplex under a barrier label. The `cbc` driver
  returns exit code 99 and the LP worker records `ERROR`. Normal builds retain
  fallback; successful barrier crossover and postsolve cleanup are unchanged.
  Use a fresh output directory when switching binaries:

  ```sh
  CXXFLAGS="-O3 -DNDEBUG -march=native -mtune=native -ffp-contract=off -DCLP_BARRIER_NO_FALLBACK" \
    ./config --opt --lapack --amd --install --prefix="$HOME/prog/cbc-lp-strict"
  ```

- **Same LP as the default `-solve` root.** `-initialSolve` runs the same
  pre-root-LP strengthening as `-solve` (bound propagation, clique
  strengthening, coefficient tightening) *except* row reductions. The LP-only
  commands skip those to keep dual values. In a 40-instance sample, half the
  instances lose rows in the real root (e.g. `gmut-76-50`: 5727 vs 6128 dual
  iterations). `-rowReductions force` turns them on for `-initialSolve` too,
  so the experiment solves exactly the LP the branch-and-bound root solves.
  The `05_15` simplex data predates row reductions, so comparing it with
  this round mixes slightly different LPs. If exact comparability matters,
  rerun a few simplex anchor configs with the same `--common-args`.
- **Memory.** `--mem-limit 12G` caps each job. `--mem-method cgroup` runs each
  job in a `systemd-run --user --scope` with `MemoryMax`, no swap and
  `OOMPolicy=continue` (only cbc is killed, and GNU `time` still reports its
  peak RSS). These scopes die when your last login session ends, unless
  lingering is enabled (`loginctl enable-linger $USER`). Without lingering,
  `auto` falls back to `rlimit` (`prlimit --as`). That caps *address space*,
  which is stricter than RSS, and cbc sees failed allocations instead of
  being killed. OOM runs get status `MEMOUT`, and every row records
  `max_rss_mb`.
- **Threads.** The orchestrator exports `OPENBLAS_NUM_THREADS=1` and
  `OMP_NUM_THREADS=1`. This build links OpenBLAS/CHOLMOD, and 32 jobs each
  running a multi-threaded BLAS would oversubscribe the machine and distort
  timings.
- **Barrier fallbacks.** When the Cholesky factorization could not be set up
  (factor too large or out of memory), Clp fell back to dual simplex without
  saying so and reported `Optimal`, so the run looked like a barrier success.
  Clp now prints `Barrier: Cholesky setup/factorization failed ... falling
  back to dual simplex`, and the worker marks the row `barrier_fallback` in
  the `notes` column. Before this fix, `-cholesky Uni` crashed (SIGSEGV)
  whenever CHOLMOD's factor needed more than 2^31 nonzeros (32-bit indices),
  and `-cholesky dense`/`Uni` aborted on a buffer overflow in the barrier log
  handler. The April barrier results (including their `ERROR`s) are
  therefore unreliable.
- **Target instances.** In `05_15` no simplex config solved `a2864-99blp` or
  `supportcase19` within 3h (`trdta5581` really is infeasible: bound
  propagation proves it). In April, `barrier_native` solved `supportcase19`
  in about 2400s.
- Barrier does not check `-sec`, so a barrier timeout costs the full hard
  limit (`timelimit + overtime`).

CSV columns added for this round (appended, so older analysis scripts still
work): `max_rss_mb` and `notes`.

### Dualize result and TODO: auto-tune flags instead of multiplying configs

Dualizing the LP for barrier (`-dualize 1`) cut the barrier_univ shifted
geomean from 175s to 11s for rows/cols >= 1.5 (worse below 1), so
`-dualize 3` now dualizes automatically for barrier when rows >= 1.5*cols
(`CbcSolver::runSolveContinuous`). The same approach should be tried for
other flags rather than adding configurations to the portfolio:

- [ ] **Dualize for primal/dual simplex configs.** Run `-dualize 1` on the
  current primal/dual settings and look for a simple rule (rows/cols,
  size) as for barrier; make it automatic only if it wins consistently.
- [ ] **Scaling.** Compare `-scaling` modes (off/equilibrium/geometric/
  auto/dynamic) per method; look for a simple rule from instance features.
  **What already exists for scaling** (read before changing anything):
  Clp's default `-scaling automatic` (mode 3, `ClpPackedMatrix::scale`)
  computes geometric scaling, then compares the resulting
  smallest/largest-coefficient ratio against equilibrium and keeps
  geometric only if its ratio is more than 2x better. It is a matrix-shape
  heuristic, never a solve-time one, and scaling is skipped when the
  coefficient range is small. Modes `dynamic` (4) and `rowsonly` (5) exist
  and were never benchmarked here. The only scaling choice in the ML
  portfolio is the `dual_pesteep_scaling_off` class
  (`CbcLpParamScorer`/`parseLpParamTag`); in the strict experiment it beats
  `dual_pesteep_pertv58` by >1.25x on 46/380 instances (22 by >2x) and loses
  by >1.25x on 99, so it is a real per-instance decision. Features most
  correlated with "off wins": share of singleton rows, bin-packing rows,
  rows with <4 nonzeros.
  Screening experiment: `lp_params_scaling.txt` (best dual x2, primal and
  barrier_univ configs x {default, off, equilibrium, geometric, automatic,
  dynamic, rowsonly}), 1 seed, 3600s, 64 parallel, 12 GB cap, results in
  `~/experiments/cbc/lp_scaling_2026_10_13`. Next: per-method best mode,
  oracle gain vs default, whether a cheap rule (matrix ranges from the
  scaling pass, row-type features) predicts it, then replace the mode-3
  heuristic accordingly.
- [ ] Build both into the default auto-tuning so every method runs with
  them, then retrain the ML recommender and racing portfolio on top
  (`Cbc/test/lp-tuning/ml/`), with fewer configs.
- [ ] After the barrier rerun (`lp_barrier_autodz_2026_10_12`) finishes,
  merge it with the 17 non-barrier configs of the strict experiment and
  redo analysis, clustering and k-fold.

## Barrier readiness for racing

Native barrier cancellation is cooperative: the racing event handler checks
the shared winner flag, and native Cholesky polls at ordering, symbolic,
sparse-update, and dense-recursion boundaries. Interrupted factors must not
be used for triangular solves or crossover. Time limits retain status 3;
event cancellation retains status 5, rather than becoming a setup failure
or triggering a simplex fallback.

Barrier progress is delivered through `endOfBarrierIteration` with a
`ClpInterior*` payload, not by pretending an interior model is a simplex.
It feeds the same synchronized, rate-limited LP table as simplex racing
participants; crossover is labeled `B+Cross`. Expected Cholesky setup
exceptions are reported per participant, while unexpected worker exceptions
are rethrown on the calling thread after workers are joined.

The default racing portfolios remain unchanged pending real-race performance
measurements. These checks do not impose a hard deadline on an individual
allocation, external library call, or the optional Cilk dense kernel.

`Clp/test/testBarrierControl` covers interrupted-model reuse, isolated wall/CPU
limits, typed progress, barrier-winning/losing races, and winner recovery.
It accepts an optional MPS path for a one-second wall/CPU/cancellation stress
check, for example `satellites2-40.mps.gz` (run with BLAS threads set to one).

The 2026-10-19 stopping sweep exercised one-second wall and CPU deadlines and
an external cancellation after one second on 24 hard instances (72 checks,
12 GB per process). All checks passed; every solve returned within 1.77 seconds
of starting, with the longest being the CPU-deadline test on `trdcrooms`
(wall time includes scheduling delays). On `satellites2-40`, native numerical
factorization previously delayed either stop to roughly 51 seconds.
Dense kernels poll cancellation at recursive tile boundaries but amortize
clock reads over 64 calls: reading the CPU clock on every tile proved
expensive. With CPU and wall deadlines both active, paired serial numerical
factorizations took 49.51s before versus 50.15s after (two samples each).
Full solves of `air04`, `co-100`, and `rmp14` retained identical objectives
and iteration counts; these small timing samples are not a universal
performance guarantee.
The final build passed the Clp/OsiClp tests, all 122 existing racing checks,
the barrier-control tests, and all 508 Cbc sanity instances plus auxiliary tests.
Logs and before/after timing samples are under
`~/experiments/cbc/native_cancellation_2026_10_19/`.

### Actual concurrent racing pilot

`~/experiments/cbc/racing_pilot_2026_10_19/` contains a reproducible,
experiment-only binary and scripts comparing the current pair/triple defaults
against native barrier + dual72, with idiot50 added for the new triple.
The new triple uses perturbation 100 for idiot50, matching its isolated
benchmark label; the current defaults retain perturbation 50 for primal methods.
The binary overrides only a snapshot of the racing implementation, leaving
installed defaults unchanged, and records winner completion separately from
worker joins and total race-return time.

The pilot selects 26 instances: strong isolated wins for each candidate method,
high native-barrier memory consumers, and stopping/numerical stress cases.
It runs all four portfolios with seeds 1/2/3 (312 runs), eight races at a time,
with a 12 GB cap per whole race and single-threaded BLAS. It retains
`-rowReductions force`, the 10800-second limit and 600-second hard-kill grace.
`-timeMode elapsed` gives portfolios the same wall-clock budget rather than
charging a triple more process CPU time than a pair.

`results/lp_results.csv` is the live raw summary; `race_results.csv` adds winner,
join-delay, and validation fields. `summary.txt` is refreshed every minute,
using matched completed instance/seed blocks and separately excluding known
objective-spread cases. `resources.csv` records available RAM and system load.
These deliberately stratified results are a pilot, not a full-dataset ranking;
keep them separate from the isolated-method database used for ML.

The follow-up full comparison lives in
`~/experiments/cbc/racing_full_2026_10_19/`: 403 instances, three seeds,
current triple versus native triple (2418 fresh races, no pilot-result reuse).
It uses the same snapshotted binary, preprocessing, memory, concurrency, and
elapsed-time limits as the pilot. Its `summary.txt`, `race_results.csv`,
`results/lp_results.csv`, and `resources.csv` follow the same conventions.
The comparison completed with defaults unchanged: 1205/1209 validated terminal
results for the current triple versus 1208/1209 for the native triple. The current
triple timed out on all three `supportcase19` seeds; both triples had the same
`rail01` seed-3 dual-optimality-check failure. Penalized shifted geometric means
were 3.6167s and 3.4965s, respectively. Multi-minute loser joins remain a blocker.

### Diagnosing multi-minute loser joins

The 2026-10-20 debugger reproductions attribute the worst `bohle` and `kasavu`
stalls to the shared **idiot50 participant**, not native factorization:
`Idiot::IdiSolve` and its outer `Idiot::solve2` loop do not poll the racing
event handler. On `bohle`, the native-barrier worker stopped 0.35s after the
dual winner; only the idiot worker was still computing at the stack sample.
The main thread was waiting in `pthread_join`, not a logging lock.

An isolated prototype in `~/experiments/cbc/racing_delays_2026_10_20/` checks
for cancellation/deadlines every eight minor iterations and at outer-loop
boundaries, unwinds through existing array cleanup, and skips idiot crossover
when stopped. Checking every minor iteration first cost about 5% in repeated
`co-100` kernel-only measurements; sampling every eight reduced this to 0.80%
(eight alternating pairs). The standalone one-second wall/CPU/event-stop checks
on `bohle` and `kasavu` all returned within 1.51s of starting idiot work.

Real-race seed-1 join delays with the sampled prototype were 2.41s for
`bohle` native triple, 0.58s for `kasavu` native triple, and 0.42s for
`bobin` native triple. Fresh debugger baselines for the first two were
263.06s and 58.58s. The current triple's `bohle` delay fell from 277.60s
to 8.37s; its remaining wait was the dual worker, not idiot50.
All four prototype race solutions passed independent LP optimality checks.

Uninterrupted full solves, run serially in alternating before/after order
(two samples each), changed by -0.73% (`air04`), +0.26% (`co-100`), and
-0.36% (`rmp14`), with identical objectives and iteration counts. These small
samples are not a universal overhead guarantee. An unrestricted full primal
run on `kasavu` was stopped during lengthy simplex cleanup; its bounded
kernel-only timing and racing reproduction were used instead.

The production integration uses a dedicated `idiotCheckpoint` event, preserves
status 3 (limit) / 5 (event cancellation), and skips subsequent crossover,
simplex startup, and postsolve cleanup solves after interruption. Existing
scaling, objective/bound restoration, postsolve, and array cleanup still run.
Do not return directly from an inner numerical loop or use thread cancellation.

`Clp/test/testBarrierControl` also covers idiot interruption before/during
crash, with presolve on/off, wall/CPU/iteration limits, positive postsolve
cleanup requests after stopping, unchanged model bounds/objective/scaling,
interrupted-model reuse, and a losing idiot racer. Its optional
`<instance.mps.gz> --idiot` form stress-tests the presolved primal/idiot path.

Integration evidence is under `~/experiments/cbc/idiot_integration_2026_10_20/`.
The real before/after 508-instance sanity comparison found no regressions;
Clp/OsiClp, all 122 existing racing checks, Cgl, and Cbc's auxiliary tests passed.
All 36 races over six worst-delay instances (both triples, all three seeds)
validated. The native triple's worst join decreased from 558.08s to 1.334s;
the current triple still had a 54.73s outlier, not attributed by these traces.
Eighteen presolved one-second wall/CPU/event stress checks returned within 3.35s.
Serial full-solve timing samples changed by +1.13% (`air04`), -0.18%
(`co-100`), and +0.19% (`rmp14`), with identical objectives and iteration counts.

The fresh 2418-race follow-up is
`~/experiments/cbc/racing_full_idiotstop_2026_10_20/`, using the same instance
set, seeds, eight-race concurrency, 12 GB caps, and elapsed-time limits.
It completed all 2418 races and retains the prior full experiment as its baseline
in `before_after_summary.txt`. The current triple validated 1206/1209 results
(two `supportcase19` timeouts and the known `rail01` seed-3 check failure);
the native triple validated 1207/1209 (a new `a2864-99blp` seed-1 timeout
and the same `rail01` failure). Penalized shifted geometric means fell from
3.6167s to 2.8422s and from 3.4965s to 2.7533s, respectively, approximately
21% in each case. Maximum joins were 82.38s and 26.52s; joins above 60s
fell from eight per portfolio to one and zero. No new objective-spread
instances appeared. Default portfolios remain unchanged.

### Residual joins and sanitizer investigation

The follow-up evidence is in
`~/experiments/cbc/racing_sanitizers_2026_10_20/`. Experiment-only worker
completion traces attribute a fresh `bohle` current-triple seed-2 delay to
**sprint**: idiot stopped 0.94s after the dual winner, while sprint finished
31.85s later. A separate debugger reproduction sampled the sprint worker
continuing primal simplex pivots while the main thread waited in
`pthread_join`; this is not a single long factorization call.
An optimized-symbol build locates all three samples at `ClpSolve.cpp`'s
final sprint `model2->primal(1)` cleanup. In standalone root solves,
`ClpSimplexPrimal::pivotResult` only honors per-pivot `endOfIteration`
cancellation when `inCbcBranchAndBound()` is true; otherwise the checked
callback is at a factorization boundary. Its progress callback also calls
`endOfIteration` but ignores the return value. Any fix must address that
safe-point gap without changing the numerical behavior via unrelated
branch-and-bound flags, and must preserve sprint restoration/cleanup.

The `a2864-99blp` timeout had no race winner: all three workers reported
time-limit status. Its seed-2 runs before and after the change reached the
same final primal iteration/objective/residual sequence but at substantially
different elapsed times (about 8302s versus 10603s to the winner). Seed 1
previously needed about 10160s, already close to the 10800s budget. These
observations motivate longer repeated before/after runs; they do not prove
that the timeout is merely load variation or exclude a solver regression.

The diagnostic plan snapshots all five projects, including current dirty
sources, and builds a separate `-O1 -g -UNDEBUG` stack with combined
AddressSanitizer and UndefinedBehaviorSanitizer, frame pointers, and
`-ffp-contract=off`. The optimized installation is untouched. System libraries
(including BLAS) are not instrumented. ASan leak detection is enabled and
both sanitizers stop on the first error. ASan/UBSan do not detect data races;
clean results would not establish race freedom or numerical determinism.

The detached 14-race instrumented experiment covers the timeout, residual-join cases,
and `rail01`, using 43200s limits (four times the original), four concurrent
races, and a 12 GiB physical-memory cgroup per whole race, with no swap.
Do not apply a virtual-address-space limit: ASan reserves a large shadow
mapping. Four optimized `a2864-99blp` seed-1 repeats compare the pre-fix
snapshot and current code with 21600s limits. These are diagnostic runs,
not an uninterrupted-runtime benchmark. `summary.tsv`, per-case
`result.json`/`solution.check`, sanitizer reports, and `progress.log`
preserve both failures and independent LP validation.

The initial combined-sanitizer barrier/idiot controls and all 122 racing
checks passed. The actual `air04` native-triple smoke run then exposed a
one-byte LeakSanitizer report at `ClpCholeskyBase::symbolic`: after
`symbolic2` reports cancellation, the index-shrinking block still allocates
`new CoinBigIndex[sizeIndex_]`, but skips assigning/freeing it because
`noMemory` is already true. The fix gates the entire shrinking block on
`!noMemory`; successful symbolic work is unchanged. This leak is not evidence
of the hypothesized memory corruption or nondeterminism.

`testBarrierControl` now sweeps every symbolic cancellation checkpoint on a
small ordered matrix. Against the unchanged snapshot, it deterministically
leaks two one-byte allocations; with the fix it passes ASan/UBSan and leak
detection, as does the same real `air04` native race, with the same winner,
worker iteration counts, and checked objective. The verified fix is in the
working tree, not installed into the normal prefix. The ongoing long races
retain their original immutable binary and may still report this known leak;
their sanitizer output is not suppressed.

Four additional optional real-LP idiot stress invocations hit their separate
300s wrapper limits without flushed diagnostic output under instrumentation.
They are inconclusive, not passing stop-latency measurements. The long-race
plan uses much larger limits precisely because sanitizer overhead, including
root preprocessing, is substantial.

The long batch completed all 19 cases. Of 14 combined-sanitizer races,
11 passed independent LP optimality validation without sanitizer reports;
both `rail01` runs retained their known dual-optimality-check failure, and
native `bohle` stopped on a UBSan signed-overflow report. None timed out.
All four longer optimized `a2864-99blp` seed-1 repeats validated at objective
`-282.960474309395`: before/after wall times were 5483.8/5488.7s and
5846.9/5923.9s (approximately +0.09% and +1.32%). These controlled repeats
do not reproduce the earlier timeout, but are not a proof of determinism.
The nineteenth case is the previously completed optimized `bohle` diagnostic.
The supervisor exits nonzero intentionally when any case has a sanitizer error.

Native `bohle` overflowed `sizeFactor_` while counting its ordering graph:
`2147354976 + 133188` at `ClpCholeskyBase::preOrder`. The old check tested
for a negative sum only after signed overflow (already undefined behavior)
and delayed the 4 GiB graph cap until counting completed. The fix checks
the remaining capacity before each row's addition, retaining the existing
index-size/memory limits and ordering-failure path, and releases scratch
arrays on rejection or allocation failure. This changes oversized graphs'
failure timing, not their allowed size.

A seeded-count regression exercises the real counting code near both
`INT_MAX` and the memory cap without allocating a huge graph. It reproduces
UBSan on the old code and passes combined sanitizers with leak detection
after the fix, alongside the existing barrier/idiot controls. The actual
native `bohle` rerun uses the separate `cbc-sanitized-ordering-fixed` binary;
its output is `bohle-ordering-fixed.log`/`.check`/`.exit`.
It returned the independently validated optimum zero with a 2.42s join and
no overflow report. However, LeakSanitizer then reported 57,757,922 bytes
in 17 allocations: the explicit strict-barrier setup-failure exception
bypassed `initialSolve`'s borrowed solution-array and presolve cleanup.
The barrier failed safely at the graph cap; dual won the race.

The strict failure is now deferred until normal model/presolve/temporary-array
cleanup and solver-setting restoration have completed. Status 4 is retained,
postsolve recovery solves are skipped, and the original `CoinError` is still
thrown (both for explicit strict barrier options and the compile-time
no-fallback flag). Failed barrier output no longer triggers optional variable
fixing. Ordinary successful barrier and non-strict fallback paths are retained.

The regression forces dense setup to reject a 40000-row sparse cyclic model
at its existing factor-memory cap, with presolve on/off and a bounded reuse
solve. Against the earlier snapshot it leaks 2,880,256 bytes in 12 allocations;
with deferred failure it passes ASan/UBSan and leak detection. The optimized
non-strict-build test also passes while requesting strict failure explicitly.
The follow-up actual race is detached under `cbc-race-cleanup-fixed.scope`,
with output `bohle-cleanup-fixed.log`/`.check`/`.exit`. It completed with exit
zero and no ASan, UBSan, or LeakSanitizer reports. Dual won in 416 iterations
at independently validated objective zero; the barrier reported status 4
and its explicit setup-failure message, while idiot stopped with status 5.
The join was 3.023s, total instrumented wall time 2106.6s including root
preprocessing, and peak RSS approximately 5.07 GiB. All three fixes are now
included in the normal installation. The original diagnostic batch is complete.

### Publication verification (2026-10-21)

Clp commit `5d224a70127819e32a92524c9c77f4609c46fe54` on upstream `next`
contains the cooperative barrier/idiot changes and all three sanitizer
fixes, including their regression tests and generated autotools wiring.
The default LP portfolios are unchanged.

After rebuilding/installing Clp and every downstream project, Clp/OsiClp,
all 122 racing checks, the barrier/idiot controls, and Cgl's tests pass.
The controls also pass the final production-linked ASan+UBSan build with
leak detection enabled. The full Cbc suite passes 508/508 before and after,
with 339 confirmed optima in both runs and no failures, errors, or overtimes.
Cbc's auxiliary interface/callback/reduction/bound checks also pass; the
optional `decomp2` root cut-purge fixture is unavailable and is skipped.
Logs and result tables are under
`~/experiments/cbc/lp_fix_verification_2026_10_21/`.

The comparison script reports one wider final gap:
`upms_n8_m3_int_wct_s42`, 1.4870% to 1.8657%, both stopping at 120s.
Its common search trajectory is unchanged, but the deadline cuts off the
new run 1610 nodes earlier. A matched-work rerun at 220000 nodes produces
byte-identical saved solutions, objective 273, bound 270, 220003 enumerated
nodes, and 493105 iterations in both binaries; wall times are 58.33/57.17s.
The saved solution independently validates. This supports a deadline/load
effect, not a repeatable algorithmic regression; the single paired timing
does not establish a speedup. The other comparison outlier, `markshare1`,
is a near-zero-bound gap-percentage artifact (`-9.09e-13` versus zero),
not a meaningful improvement. Do not interpret that comparison's average
gap as a performance metric.

### Standalone simplex sanitizer campaign (2026-10-21)

`~/experiments/cbc/simplex_sanitizers_2026_10_21/` contains a detached
144-run ASan+UBSan campaign: 12 difficult instances, six configurations,
and seeds 1/2. Four independent runs execute concurrently with GNU parallel.
Each serial LP solve has a 43200s elapsed limit, a 45000s external timeout
plus 30s kill grace, and a whole-process cgroup limited to 12 GiB physical
memory with no swap. No virtual-address limit is imposed, since ASan needs
its shadow address space. BLAS/OpenMP threads are limited to one.

| Tag | Configuration |
|---|---|
| `dual72` | Dual simplex, perturbation 72 |
| `dual_pesteep` | Dual simplex, positive-edge steepest pivoting |
| `primal_plain` | Primal simplex, idiot and sprint explicitly disabled |
| `primal_idiot50_pert50` | Primal simplex, 50 idiot passes, perturbation 50 |
| `primal_idiot50_pert100` | Primal simplex, 50 idiot passes, perturbation 100 |
| `primal_sprint30` | Primal simplex, 30 sprint passes, idiot disabled |

Instances are `air04`, `neos-3402454-bohle`, `a2864-99blp`, `usafa`,
`neos-5114902-kasavu`, `neos-2075418-temuka`, `savsched1`, `rail01`,
`irish-electricity`, `co-100`, `rmp14`, and `square41`. The runs retain
`-rowReductions force -initialSolve` to exercise the default root's fast
preprocessing, not just Clp's own presolve. These are standalone methods,
not races; this broadens algorithm coverage but does not exercise loser
cancellation.

The frozen `cbc-asan-ubsan` uses the production racing implementation, with
no diagnostic portfolio overrides. `build.json`, `manifest.json`, patches,
and `fixed-sources/` preserve build/source provenance; the unchanged
instrumented objects and external-library limitations are inherited from
the original sanitizer stack. Three fixed production translation units
override the corresponding older archive members. The production-linked
barrier/idiot controls pass combined sanitizers and leak detection. A
memory-capped smoke solve also agrees with a separate optimized solve of
the same root-preprocessed model.

`summary.tsv` is refreshed every minute and includes pending/running cases.
Per-case `command.json`, `run.log`, `result.json`, saved basis/solution,
independent `solution.check`, and any `asan.*`/`ubsan.*` reports are under
`results/`. `progress.log`, `supervisor.log`, `parallel.tsv`, and
`resources.tsv` record dispatch and machine health. Completed cases are
not overwritten on supervisor restart.

A pass requires zero exit status, no sanitizer report, independent LP
feasibility and optimality, and objective agreement within relative `1e-6`
with at least one historical validated objective in the consolidated LP
database. Historical objective-spread cases are therefore checked against
an envelope, not treated as proof of determinism. Time limits, hard
timeouts, checker failures, objective mismatches, process failures, and
sanitizer failures remain explicit non-pass statuses. The known `rail01`
checker failure is not waived. ASan/UBSan cannot establish data-race freedom,
and instrumented runtimes must not be used as performance measurements.

## Checking numerical correctness

Do not trust an `Optimal` log line alone. Run `-checkSolution` after
`-initialSolve`; the checker independently recomputes unscaled primal
feasibility and dual optimality. The analysis scripts classify a failed
check (including `optimal=no` with `feasible=yes`) as a wrong result, not a
successful solve.

LP-only actions synchronize the numerical parameters just like `-solve`,
including primal/dual tolerances, iteration/time limits and the random seed.
Inspect `primal_tolerance` and `dual_tolerance` in the check report to confirm
the requested settings were actually used.

Clp's cleanup may switch from dual to primal or back again. A primal-feasible
solution is not necessarily optimal after such a switch: cleanup must also
finish against the original costs and bounds. Cbc additionally re-solves the
root LP without scaling when Clp reports unscaled infeasibilities; this does
not enable unscaled cleanup at every branch-and-bound node.
For a root solve, Cbc also enables a per-solve unscaled postsolve recovery option:
if the presolved optimum reports unscaled infeasibility and postsolve leaves
dual residuals whose average floating-point roundoff scale exceeds the dual
tolerance, recovery starts without scaling, rather than waiting until the
whole initial solve returns. Ordinary postsolve residuals and final root
cleanup retain their existing paths. The option belongs to the root's local
`ClpSolve` configuration, including each racing configuration; it does not
enable this recovery for subsequent node solves.
The LP deadline stays armed through racing and unscaled cleanup, so cleanup
uses the remaining solve budget rather than starting an unlimited phase.
For reported unscaled dual infeasibility, explicit cleanup also omits Clp's
ordinary tolerance-only dual relaxation, so a residual several times the
requested dual tolerance cannot be dismissed solely by that allowance.

Small objective differences can still occur between solutions accepted at
the configured feasibility tolerance. Before calling such a difference a
wrong result, rerun both methods with a tighter `-primalTolerance` and inspect
the checker's worst row/column violations. This is especially important when
many tiny bound violations accumulate into a visible objective difference.

### Irish-electricity: postsolve instability

Matched seed-3 runs on `hal` isolate a scaling-sensitive failure: dual with
either ordinary or positive-edge steepest-edge pricing stops without a valid
solution at 900 seconds, whereas both scaling-off variants produce independently
validated optima in approximately 495 and 423 seconds, respectively.
`-scaling off` is a verified workaround for this instance, not a new default.

Saved-state diagnostics locate the amplification in presolve's
`forcing_constraint_action` reversals: the largest row multiplier grows from
about `4.36e4` before postsolve to `2.67e37` afterwards. The presolved solution
also has an unscaled primal residual around `9.15e-4` at a requested `1e-6`
tolerance. Subsequent scaled recovery can exhaust the deadline before Cbc's
root-only unscaled cleanup is reached. Starting unscaled recovery immediately
after postsolve avoids that delay; it does not change the forcing-row
transformations or discard the recovered primal solution.

With this root-only policy, fresh ordinary dual, positive-edge dual and racing
runs pass the independent primal/dual checks at `1e-6`. Verified postsolve-state
replays also pass under AddressSanitizer and UndefinedBehaviorSanitizer, as do
synthetic tests for severe versus ordinary residuals and
iteration-limited recovery. Separate unit tests cover legacy-option isolation,
copying and assignment. The full 500-instance MIP sanity comparison has
500 valid results and 317 confirmed optima on both sides.

Some limited-search gaps still vary between runs. Controlled reruns reproduce
the flagged cases with the before-fix binary too. Before the final-bound fix
described below, Cbc could report a stale, wall-clock-driven progress bound
despite identical search node and iteration counts. Time-budgeted heuristics
can also change their incumbents under full-suite contention. These variations
are not evidence of an LP correctness failure or a repeatable regression from
this recovery policy; compare controlled runs before attributing a gap change
to it.

### Final bounds after interrupted search

Progress reporting still refreshes the cached tree bound on a wall-clock
cadence, but interrupted search now refreshes it from the live frontier before
cleanup destroys the nodes. Parallel searches include finished workers' pending
parent and created nodes before worker shutdown discards them. The refresh
retains a stronger previously certified bound, caps it at the incumbent, and
keeps the last known bound when no frontier remains or a stopped subtree is
unaccounted for. It does not change progress frequency or node selection.

`Cbc/test/final-bound-test` uses an enumerated binary optimum and a recording
tree to check minimization/maximization, serial/parallel search, zero-node
limits, node/time/event termination and completed searches. `./test` runs it
automatically; `--no-final-bound-tests` skips it. Controlled repeated runs of
`upms_n7_m3_int_wct_s137` now report bound `201`, and
`upms_n9_m2_lgset_cmax_s137` report `18.1237`, whereas the baseline's reported
bounds fluctuate despite identical node and iteration counts.

### Interrupted-search shutdown safety

Custom `CbcEventHandler` subclasses do not need a `CbcBnBOutput` controller:
end-of-search statistics are sent only when one is attached, while the
`endSearch` callback still runs normally. Regression cases cover both
configurations and verify that the callback is delivered once.

On interrupted parallel searches, completed workers can still own a parent
node and a newly created child that have not been merged into the shared tree.
Shutdown retains these nodes before discarding worker state and returns them
to the tree only after every worker has exited, so the existing depth-ordered
cleanup releases their cuts and ancestor/basis
references. Deleting only the parent previously leaked the child and its
reference chain. The extended final-bound tests include one, two and four
workers and deterministic parallel mode. Twenty isolated node-limited ASan
runs leaked before the fix and none afterward; UBSan and real cut-generating
MIPs stopped at a node limit also pass. A separate intermittent leak remains
in completed parallel searches: it reproduced once in 100 additional isolated
ASan runs both with and without the shutdown fix. That issue does not involve
pending interrupted-worker nodes and is still under investigation.

### Root-cut termination status

Post-cut root heuristics now skip slack-row cleanup when cut generation has
already fathomed the root or stopped inconclusively. Removing rows at that
point invalidated Clp's termination status, causing a completed cutoff proof
to look like an abandoned LP and be reported as a time limit. This affected
optimal MIP starts and repeated C API solves after adding a row on every CI
platform, even when the objective and bound were correct. The existing
MIP-start and lazy-constraint tests also check the completed status and bound;
genuine time/event/node stops remain covered by the final-bound tests.

## Raw historical experiment data

Past experiment output directories (`.sol`/`.bas`/`.log`/`.result` per job,
too large to check in — hundreds of thousands of files) remain on the `hal`
server under `~/experiments/cbc/lp_relax_2026_{04_27,04_28,05_12,05_15}_noblas`.
The `_noblas` suffix means OpenBLAS was disabled for these runs (isolating the
LP-method effect from BLAS backend effects).
