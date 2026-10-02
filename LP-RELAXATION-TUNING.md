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
The LP deadline stays armed through racing and unscaled cleanup, so cleanup
uses the remaining solve budget rather than starting an unlimited phase.

Small objective differences can still occur between solutions accepted at
the configured feasibility tolerance. Before calling such a difference a
wrong result, rerun both methods with a tighter `-primalTolerance` and inspect
the checker's worst row/column violations. This is especially important when
many tiny bound violations accumulate into a visible objective difference.

## Raw historical experiment data

Past experiment output directories (`.sol`/`.bas`/`.log`/`.result` per job,
too large to check in — hundreds of thousands of files) remain on the `hal`
server under `~/experiments/cbc/lp_relax_2026_{04_27,04_28,05_12,05_15}_noblas`.
The `_noblas` suffix means OpenBLAS was disabled for these runs (isolating the
LP-method effect from BLAS backend effects).
