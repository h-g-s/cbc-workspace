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

## Raw historical experiment data

Past experiment output directories (`.sol`/`.bas`/`.log`/`.result` per job,
too large to check in — hundreds of thousands of files) remain on the `hal`
server under `~/experiments/cbc/lp_relax_2026_{04_27,04_28,05_12,05_15}_noblas`.
The `_noblas` suffix means OpenBLAS was disabled for these runs (isolating the
LP-method effect from BLAS backend effects).
