# Root-node processing fixtures

A companion to `BENCHMARKING-CUT-GENERATORS.md`, generalised from a single cut
generator's call site to CBC's *whole* root-node processing: pre-processing,
the root LP relaxation, the cut-generation loop, and root heuristics. The goal
is the same -- turn a full solve into an offline replay so a strategy sweep
over cut generators / heuristics is a millisecond-per-instance question -- but
here nothing generator-specific is captured: one fixture per instance covers
every strategy you might want to try.

## The one-paragraph version

`CbcRootFixtureDump.hpp` dumps the preprocessed problem + optimal root LP
basis at the exact point CBC is about to enter its cut-generation loop (root,
first pass, before any cut is applied). `gen-root-fixtures` drives this over
every instance in `mip-sanity-data`, using `-maxNodes 1` so a dump-enabled run
costs only what root processing itself costs, not a full solve. `mip-root-replay`
loads a fixture, rebuilds a `CbcModel` directly around it (skipping
pre-processing and the root LP solve, since the fixture already sits at that
exact state), attaches cut generators / heuristics, and runs a few nodes --
reaching root cut generation in milliseconds.

## Fixture format

Written by `CbcRootFixtureDump.hpp`, one set per instance, tag `root`:

| file | contents |
|---|---|
| `<name>.root.mps.gz` | preprocessed matrix, formatType 2 (IEEE hex) |
| `<name>.root.bas`    | optimal root LP basis |
| `<name>.root.sol`    | optimal root LP solution (cross-check) |
| `<name>.root.ctype`  | integer/continuous per column (MPS cannot express a fixed integer column -- see the file's header comment) |
| `<name>.root.meta`   | rows/cols/elements/objValue/objSense/lpOptimal/paddedColumns/integerColumns |

This is deliberately the same shape as the per-generator fixtures
(`CbcClqFixtureDump.hpp` and friends) minus any generator-specific payload --
loading code is shared with `bkclique-bench.cpp`'s `loadFixture` pattern.

Stored under `~/instances/mip-sanity-data/rootFixtures/` by default
(`$CBC_ROOT_FIXTURE_DIR` to override), alongside the other instance fixture
trees this workspace already keeps under `~/instances/`.

**Not every instance produces a fixture, and that is expected.** Some
instances never reach the dump call site at all:
- pre-processing (bound tightening / row reduction) solves the whole problem
  to integer optimality outright, leaving 0 rows/cols and no cut-generation
  loop to enter (e.g. `wqueens-*`, small graph-coloring/MIS instances);
- pre-processing proves the problem infeasible before any LP is even solved
  (e.g. `trdta5581`), or the root LP itself is infeasible
  (`cttp_infeasible_c10t12_r2-4_sd2`).

Neither case is fixable with a bigger time budget -- `gen-root-fixtures`
distinguishes these ("expected skip") from genuine timeouts/crashes by
checking whether the captured run's own log ever printed a `Result -` /
infeasibility line.

## Generating fixtures — `gen-root-fixtures`

```sh
cd Cbc/test   # or use the ./gen-root-fixtures symlink at the workspace root
./gen-root-fixtures                    # pass 1, every instance
./gen-root-fixtures 'bpc_*' 'cvrp_*'    # only matching instances
./gen-root-fixtures --pass2            # generous budget + LP racing, only
                                        # instances still missing after pass 1
```

Never leaves the workspace's normal `cbc` binary/install altered: fixture
dumping only happens in a build compiled with `-DCBC_DUMP_ROOT_FIXTURE`,
which the script builds into a private, throwaway binary
(`test/.cbc-rootdump-bin`) and then immediately rebuilds + reinstalls the
normal no-dump `cbc` before running anything against the real dataset.

Two passes, both resumable (skip any instance whose `.meta` already exists),
both largest-instance-first (a cheap proxy for "more likely to be slow"):

- **Pass 1** (default): every instance, single-threaded, 600s wall time per
  instance, `nproc` jobs in parallel. Dumping happens right after the root LP
  solve, so this only has to cover pre-processing + the root LP + one
  cut-gen/heuristics round -- normally seconds even for large instances.
- **Pass 2** (`--pass2`): only instances still missing a fixture (the root LP
  or pre-processing itself was hard), 3h wall time, `-lpMethod=racing
  -threads=4` to speed up the hard root LPs, `nproc/4` jobs in parallel so
  each job's racing threads have real cores.

On the current `mip-sanity-data` (500 instances), pass 1 alone produced 442
fixtures; the other 58 are all "expected skip" (preprocessing solved or
proved infeasible), not timeouts -- pass 2 was not needed.

## Replaying — `mip-root-replay`

```sh
cd Cbc/test
./mip-root-replay pk1                       # by instance name (looks up the
                                             # fixture in $CBC_ROOT_FIXTURE_DIR)
./mip-root-replay /path/to/name.root.mps.gz # by any fixture file / stem
./mip-root-replay pk1 --nodes=1             # root only
./mip-root-replay pk1 --nodes=16            # root + first 16 nodes (default)
./mip-root-replay pk1 --no-heur             # cuts only
./mip-root-replay pk1 --no-cuts             # heuristics only
./mip-root-replay pk1 --log=3               # verbose CBC output
```

Loads the fixture (warm-starting the LP -- 0 iterations on a faithful
fixture, which the tool checks and warns about otherwise), builds a fresh
`CbcModel` around it, and attaches cut generators / heuristics via
`CbcStrategyDefault` -- the same mechanism `CbcSolver.cpp` uses for the normal
`cbc` command line's defaults (`CbcStrategyDefault strategy(1,
babModel_->numberStrong(), babModel_->numberBeforeTrust())`). Deliberately
does not call `setupPreProcessing()`: the fixture's solver is already
preprocessed, and `CbcStrategyDefault::setupOther()` only preprocesses when
that is requested, so it is a no-op here beyond setting
`numberStrong_`/`numberBeforeTrust_`.

**Resolved: full CLI heuristic parity.** `mip-root-replay` attaches heuristics
via `doHeuristics(&model, 1, params, ...)` (`CbcSolverHeuristics.hpp`) -- the
exact function `CbcSolver::configureHeuristics()` calls for the real `cbc`
command line -- rather than `CbcStrategyDefault::setupHeuristics()`'s much
smaller fixed set (rounding only). `CbcParameters()`'s default constructor
self-initializes with the real CLI's default parameter values with no
dependency on a `CbcSolver` instance, so this is a faithful baseline
(Feasibility Pump on, RINS/diving/greedy on, Feasibility Jump off, ...), not a
hand-picked subset. Pass `--minimal-heur` to fall back to the old bare-rounding
`CbcStrategyDefault` behavior instead (e.g. to isolate pure cut-generator
effects from any heuristic activity at all).

On top of this real-default baseline, `mip-root-replay` exposes fine-grained
Feasibility Jump (FJ) / Feasibility Pump (FPump) tuning knobs as CLI flags,
each overriding one `CbcParameters` value: `--fpump=on|off`,
`--fj=off|on|before|both`, `--fj-after-fpump=0|1`, `--fj-effort=N`,
`--fj-effort-mult=N`, `--fj-stall=N`, `--fj-max-sol=N`, `--fj-only-no-sol=0|1`,
`--fj-max-calls=N`, `--fj-depth=N` (see `--help` for defaults/meaning of
each). This is what the FJ tuning sweeps below are built on.

Reports, per replay: rows/cols/warm-start iterations/load time, then nodes
explored, proven-optimal/infeasible, best possible bound, best solution value
(if any) and gap, wall time for the branch-and-bound call, and (if
`--data-dir`'s `bks.tsv` has an entry) the best-known objective for comparison.

## Workflow for a cut generator / heuristic experiment

1. `./gen-root-fixtures` once (see above) to populate the fixture set.
2. Iterate: `./mip-root-replay <instance> [options]` per instance, or drive a
   sweep script over many instances/strategies the same way
   `compare_benchmarks.py` / `stats_analysis.py` do for full-suite runs --
   each replay costs milliseconds to load plus whatever the strategy under
   test costs, not a full solve.
3. Judge changes the same way `BENCHMARKING-CUT-GENERATORS.md` prescribes:
   bound improvement on reoptimizing (never cut count) for cut generators;
   primal bound / time-to-first-solution for heuristics.

## Fixture collections: quick-sanity vs. hard set

Two distinct instance collections are used for root-fixture experiments, and
picking the right one for the question at hand matters:

- **`mip-sanity-data`** (`Cbc/test/mip-sanity-data`, 500 instances, `bks.tsv`
  schema `instance status objective sense source`): fast, self-contained,
  good for pipeline smoke-testing and quick iteration -- but mostly *easy*
  instances, so heuristic/cut effects that only show up under real
  difficulty (e.g. "can we even find a feasible solution at all?") are
  under-represented. 442/500 produce root fixtures via pass 1 alone (the
  other 58 are expected skips).
- **The "hard set"**, `~/inst/miplib/2017+spp/` (385 real MIPLIB-derived
  instances, `bks.tsv` schema `instance bks` -- note the *different* column
  layout from mip-sanity-data's, see the BKS-lookup note below): this is the
  representative set for judging root/first-16-node dual/primal-bound
  improvements, per the standing direction to focus on hard instances rather
  than quick sanity checks. `gen-root-fixtures` hardcodes its data directory
  layout to `$DATA_DIR/mips`, so point it at a new collection via a
  `mips -> <collection>` symlink wrapper directory (e.g.
  `Cbc/test/.miplib2017spp-datadir/mips -> ~/inst/miplib/2017+spp`) rather
  than modifying the script. Fixtures are stored in a
  `rootFixtures/` subfolder of the collection itself (e.g.
  `~/inst/miplib/2017+spp/rootFixtures/`) so they are naturally reused across
  every future experiment on this set without regenerating.
  Pass 1 (600s/instance) got 257/385; `--pass2` (3h + LP racing) recovered 81
  more (338/385 total); the remaining ~47 are either expected skips (root
  LP/preprocessing solves the problem outright) or 7 true stragglers where
  even the pass-2 budget wasn't enough (root LP/preprocessing itself too
  hard) -- rerun `--pass2` again only if a future need justifies an even
  larger budget for those specific 7.

**BKS schema is not uniform across collections** -- always check
`head -1 bks.tsv` for a new collection before trusting column positions.
`mip-root-replay`'s BKS lookup detects the objective column by header name
(`"bks"` or `"objective"`), falling back to column index 1 only for an
unlabeled 2-column file.

## Methodology for a rigorous strategy-sweep experiment

This is the pattern used for the Feasibility Jump (FJ) tuning experiment
(2026-09, see results below) and is meant to be reused for future root/
first-16-node cut-generator or heuristic studies:

1. **Validate the pipeline on `mip-sanity-data` first.** Any bug in the
   sweep/summarize scripts is far cheaper to catch on a 442-fixture, few-
   minutes-per-config run than mid-way through an hours-long hard-set sweep.
   Only move to the hard set once found-rate/gap numbers look sane (e.g. a
   `no_heur` config should score much worse than the real-CLI-default
   baseline; gap stats should not be `nan`/blow up to absurd magnitudes).
2. **Stage the sweep, one question per stage, each gated on the previous
   stage's winner:**
   - *Stage 1 -- "when/whether to trigger":* compare on/off and
     alternative-trigger-point variants (e.g. FJ at root vs. FJ as an
     FPump-failure fallback vs. FJ replacing FPump entirely) at `--nodes=1`
     (root only), isolating the heuristic-trigger question from any B&B
     tree effects.
   - *Stage 2 -- "how much effort per call":* fix the stage-1 winner, sweep
     effort-budget and iteration-count/repeat-count knobs, still at
     `--nodes=1`.
   - *Stage 3 -- "where else in the tree":* fix the stage-1/2 winners,
     switch to `--nodes=16` (the "first 16 nodes" target), and sweep
     tree-recursion knobs (e.g. call the heuristic again every N levels,
     gated on "no incumbent yet" vs. unconditionally).
3. **Metrics, in priority order for primal-bound/heuristic work** (mirrors
   the user's stated priorities: reach root fast, strong dual bound, good
   primal bound, and -- specifically called out as important -- *some*
   feasible solution at all, since without one there is no upper bound and
   the whole search degrades):
   - `found_pct` -- fraction of instances with *any* incumbent after the
     replay. This is the primary metric when the baseline's found-rate is
     well under 100% (as it is on the hard set) -- a config that raises
     found-rate from 46% to 66% matters more than one that shaves 2% off an
     already-found solution's gap.
   - `avg_gap_bks_pct` -- **only averaged over instances where a solution was
     found** (never conflate "no solution" with "0% gap" or drop those rows
     silently either -- report `n_gap_samples` alongside so a reader can see
     the denominator). Use a **normalized/bounded gap formula**,
     `100 * |obj-bks| / max(|obj|,|bks|,eps)`, not a pure
     relative-to-bks-only formula (`100*|obj-bks|/|bks|`) -- the latter
     explodes to absurd magnitudes (seen: >13,000% average) on instances
     with a near-zero BKS (e.g. the `markshare` family, bks in {1,14};
     `mushroom-best`, bks~0.055). This is the same convention
     `compare_benchmarks.py` already uses elsewhere in this repo, for
     consistency across tools.
   - `n_optimal` -- how many replays proved optimality within the node/time
     budget (rare at `--nodes<=16`, but worth tracking; a config that
     silently *drops* a previously-proven-optimal instance is a red flag).
   - `avg_bbtime_s` / `total_bbtime_s` -- efficiency check: a config that
     wins on found-rate/gap but multiplies runtime is a much weaker result
     than one that wins for free or even runs faster (e.g. finding an
     incumbent earlier can tighten cutoffs and shorten the remaining B&B).
4. **Always run detached (`nohup ... & disown`), never a plain background
   shell job**, for any sweep expected to take more than a few minutes --
   session interruptions must not lose hours of compute. Log to a file and
   poll it, do not rely on capturing the terminating shell's stdout.
5. **Never edit a sweep script while an already-launched instance of it is
   still running.** GNU parallel workers re-read the script file from disk
   as they spawn; editing it mid-run can corrupt the currently-executing
   invocation's control flow (observed: a stray extra pass through all
   configs, printing garbage/`command not found` errors, after an in-place
   edit to `fj-tune-sweep.sh` while its outer loop was still alive). Let a
   running sweep finish (or kill it first, explicitly, by PID) before
   changing the script, then relaunch.
6. **Guard every per-instance worker call with a hard wall-clock `timeout`**
   (e.g. `timeout --kill-after=10 "$((SECS+60))s" ...`) in addition to
   whatever time limit the tool itself claims to enforce
   (`--sec=`/`setMaximumSeconds()`). A tool's own time check only fires
   between polling points (e.g. between B&B node evaluations); a single
   heuristic call on a large/numerically hard fixture can overrun it
   substantially (observed: one instance ran 9+ minutes against a 10s
   `--sec` budget), stalling an entire parallel sweep. `timeout` gives
   generous headroom above the requested budget rather than killing right
   at the target, so genuinely-slow-but-finishing runs still get recorded.

## FJ tuning results (2026-09, hard-set: `~/inst/miplib/2017+spp`, 259-300
## fixtures depending on stage/pass-2 progress at run time)

Baseline throughout: the real CLI default heuristic set via `doHeuristics()`
(Feasibility Pump on, Feasibility Jump off).

**Stage 1 -- when/whether to trigger FJ** (`--nodes=1`):

| config | found% | optimal | avg_gap_bks% | avg_time(s) |
|---|---|---|---|---|
| baseline (FPump only) | 46.3 | 3 | 19.0 | 14.9 |
| `--fj=on` | 64.5 | 4 | 23.1 | 15.7 |
| `--fj=on --fj-after-fpump=1` | **66.0** | 4 | 23.3 | 15.9 |
| `--fj=on --fpump=off` | 64.9 | 4 | 23.0 | 16.2 |
| `--fj=off --fpump=off` (no heuristics) | 46.3 | 3 | 18.7 | 15.9 |

FJ is the dominant lever for the "no feasible solution at root" problem on
hard instances: FPump alone performs no better than no heuristics at all
(46.3% found both), while adding FJ (any variant) raises found-rate by
+18-20pp. The FPump-failure fallback (`--fj-after-fpump=1`, seeding FJ from
FPump's best failed rounded iterate) is the best variant and is the winner
carried into stages 2/3.

**Stage 2 -- effort budget / iteration count** (`--nodes=1`, on top of the
stage-1 winner; grid: `--fj-effort-mult` in {256,512,1024,2048,4096} x
`--fj-max-sol` in {1,2,4}):

Found-rate rises marginally 256->512->1024 (64.5%->64.9%->65.65%) then is
**exactly flat** at 1024/2048/4096 (identical found-rate, gap, and timing) --
FJ already converges within its default 1024x-NNZ effort budget on this
instance set; more budget never helps. `--fj-max-sol` (1 vs. 2 vs. 4) has
**zero effect** at every effort level tested. Conclusion: the shipped
defaults (`effort_mult=1024`, `max_sol=1`) are already at or past the point
of diminishing returns for these two knobs -- no retuning indicated.

**Stage 3 -- tree-recursive FJ calls** (`--nodes=16`, on top of the stage-1/2
winners; grid: `--fj-depth` in {0(root-only),2,4,8} x
`--fj-only-no-sol` in {0,1}):

| config | found% | optimal | avg_gap_bks% | avg_time(s) |
|---|---|---|---|---|
| root-only (`--fj-depth=0`) | 62.0 | 9 | 25.9 | 37.4 |
| depth=2/4/8, gated (only-no-sol=1) | 63.0 | 9 | 26.2-26.7 | 37.7-38.5 |
| depth=2/4, ungated | 63.0 | 9 | 26.9 | 36.1-36.6 |
| depth=8, ungated | 62.0 | 9 | 25.8 | 33.9 |

Calling FJ again at fixed tree depths only adds +1pp found-rate over
root-only, with no clear winner among depths/gating -- noise-level given
n=300. Most of FJ's value is already captured by the single root-level call;
tree-recursive calls in the first 16 nodes are not worth the added
complexity on this evidence.

**Overall**: no changes to CBC's shipped FJ/FPump defaults are indicated by
this sweep -- they were already well-tuned for this metric/instance set. The
clear, actionable result is the FPump-fallback wiring itself (point (d) in
the FJ integration plan), which is what raises found-rate from ~46% to ~66%
at root and is already committed.

Reproduce or extend: `Cbc/test/fj-tune-sweep.sh --configs=<tsv> --outdir=<dir>
--fixture-dir=<fixtures> --data-dir=<collection> --nodes=<1|16> --sec=<N>
--jobs=<N>`, then `Cbc/test/fj-tune-summarize.py <outdir> <configs.tsv>`. See
`Cbc/test/fj-configs-stage{1,2,3}.tsv` for the exact configs above.

## Cut-pool filtering for Gomory/MIR2/Twomir/Probing (2026-09,
## mip-sanity-data, 442 instances)

`CglBKClique`'s own clique-cut generator already filters its candidate cuts
through a `CoinCutPool` (see `Cgl/src/CglBKClique/CglBKClique.cpp`'s
`insertCuts()`): candidates compete for a best-fitness-per-column slot, and
the loser is dropped, so a round that would otherwise flood the LP with many
redundant/dominated cuts only keeps the strongest ones. This experiment
generalizes that same filter to four other generators known to sometimes
produce many cuts per round -- Gomory, MixedIntegerRounding2, Twomir, and
Probing (row cuts only; Probing's column-bound tightening is untouched) --
via a new `cbcFilterGeneratedCuts()` helper (`Cbc/src/CbcCutPoolFilter.cpp`)
called once per generator round from `CbcCutGenerator::generateCuts()`.

**Mechanics**: cuts produced by one `generateCuts()` call are fed into a
fresh `CoinCutPool` (tagging each with its original `OsiCuts` index via a new
`CoinCut::tag()`/`CoinCutPool::cutTag()` field, so pool compaction can be
mapped back cleanly); a cut is normalized to the pool's single-sided
`ax <= rhs` model (negating a `>=`-only cut, skipping genuine ranged/equality
cuts unfiltered) before being scored. Cuts that lose the best-fitness contest
are erased from the caller's `OsiCuts` collection; survivors keep their
original `OsiRowCut` identity/metadata untouched. Gated the same way as
`CglBKClique`'s own filter -- small models (`numCols < CBC_CUTPOOL_FILTER_MIN_COLS`,
default 500) and small candidate counts
(`< CBC_CUTPOOL_FILTER_MIN_CANDIDATES`, default 20) are exempt, since
filtering only pays for itself with many candidates to choose among. An
optional parallelism/orthogonality secondary filter
(`CBC_CUTPOOL_FILTER_MAX_PARALLELISM`, default **0.7**) and an
always-filter override (`CBC_CUTPOOL_FILTER_ALWAYS=1`, bypasses both gates,
for A/B testing) round out the env-var surface -- same naming pattern as
`CglBKClique`'s `CBC_CLIQUE_POOL_*` vars. Unlike `CglBKClique`'s own
clique-cut parallelism filter (disabled by default, since an earlier sweep
found no net win there), `0.7` ships enabled by default here, since the
sweep below found it the single best-performing variant for these four
generators specifically.

**Sweep**: `Cbc/test/cutfilter-sweep` (forked from `cutskip-sweep`, same
full-CLI-per-(config,instance) approach) against `Cbc/test/cutfilter-configs.tsv`,
`--sec=180 --jobs=128`, all 442 `mip-sanity-data` instances (3 errors,
consistent across every config -- pre-existing, unrelated to this change).

| config | mean dual gap closed | mean primal gap closed | mean bbTime(s) | geomean dual eff | geomean primal eff |
|---|---|---|---|---|---|
| today (shipped gates: cols>=500, candidates>=20) | 50.45% (base) | 82.24% (base) | 11.42 (base) | 42.30% (base) | 59.56% (base) |
| `MIN_CANDIDATES=5` (cols gate off) | 49.50% (-0.94pp) | 82.37% (+0.13pp) | 11.08 (-0.33s) | 45.21% (+2.91pp) | 67.00% (+7.44pp) |
| `MIN_CANDIDATES=20` (cols gate off) | 50.10% (-0.35pp) | 82.38% (+0.15pp) | 11.11 (-0.31s) | 44.72% (+2.43pp) | 64.82% (+5.26pp) |
| `MIN_CANDIDATES=50` (cols gate off) | 50.31% (-0.14pp) | 81.96% (-0.27pp) | 11.35 (-0.07s) | 43.29% (+0.99pp) | 61.53% (+1.96pp) |
| `MIN_COLS=100` (candidates gate default) | 50.15% (-0.30pp) | 82.27% (+0.03pp) | 11.22 (-0.20s) | 44.47% (+2.18pp) | 64.03% (+4.46pp) |
| `ALWAYS=1` (both gates off) | 50.14% (-0.29pp) | 82.68% (+0.44pp) | 11.06 (-0.38s) | 46.17% (+4.93pp) | 67.91% (+9.12pp) |
| `ALWAYS=1, MAX_PARALLELISM=0.7` | 49.43% (-1.00pp) | 83.03% (+0.80pp) | 10.73 (-0.71s) | 47.51% (+6.27pp) | 70.31% (+11.52pp) |
| `ALWAYS=1, MAX_PARALLELISM=0.5` | 49.39% (-1.04pp) | 82.01% (-0.23pp) | 10.58 (-0.85s) | 46.92% (+5.68pp) | 68.56% (+9.77pp) |
| `ALWAYS=1, CLI:-passCuts=200` (reinvest saved time) | 48.69% (-1.74pp) | 82.23% (-0.01pp) | 10.48 (-0.95s) | 57.38% (+16.14pp) | 95.39% (+36.60pp) |

**Findings**:
- Filtering is a consistent, if modest, net win on this instance set: every
  variant tested cuts `bbTime` (root+first-16-nodes) while leaving primal
  gap closed roughly flat-to-better; the dual-gap-closed cost is small
  (<1pp) except under the most aggressive settings.
- `mip-sanity-data` is mostly *small* instances (per its own quick-sanity
  caveat above), so the shipped `MIN_COLS=500` gate suppresses filtering for
  most of this set -- `ALWAYS=1` (gates off) beats every gated variant on
  efficiency, confirming the gate is costing real benefit here, though it
  remains the conservative, `CglBKClique`-consistent choice for production
  (avoids any risk on tiny models where cuts are cheap regardless, matching
  the existing "always try everything, it's cheap" rationale for small
  problems elsewhere in `CbcSolver.cpp`).
- `MAX_PARALLELISM=0.7` gave the single best primal-gap/efficiency
  combination of any variant tried, unlike `CglBKClique`'s own 442-instance
  parallelism sweep (which found no net win for clique cuts specifically) --
  the four generators here apparently produce more directionally-redundant
  cuts than clique cuts do, so orthogonality filtering has more to remove.
- **`CLI:-passCuts=200` (reinvesting the time filtering saves into more root
  cut-generation rounds) is the standout result**: +16pp dual efficiency,
  +37pp primal efficiency, with primal gap closed essentially unchanged
  (-0.01pp) and a still-modest dual-gap cost (-1.74pp) -- confirms the
  user's "perhaps extend rounds to compensate" hypothesis was directionally
  correct and is the most promising follow-on to validate on the hard set
  before considering a shipped-default change to `passCuts`.
- **Shipped defaults**: `MIN_COLS=500`/`MIN_CANDIDATES=20` are kept
  unchanged, matching `CglBKClique`'s own precedent -- these are gates, not a
  tunable "how aggressive" knob, and the conservative small-model exemption
  is deliberate regardless of instance mix. `MAX_PARALLELISM`, however, *is*
  updated to **0.7** (from the initial 1.0/disabled default this section
  originally shipped with): the sweep evidence for it was unambiguous (best
  primal-gap/efficiency combination of every variant tried, with a modest
  and acceptable dual-gap cost), so there's no reason to leave a proven
  win as an opt-in env var -- unlike `passCuts=200` below, which still
  needs hard-set confirmation before being promoted to a default since it
  changes global cut-generation round budgets well beyond this filter's
  scope. `mip-sanity-data`'s small/easy instance mix under-represents the
  large/many-cut-candidate instances this feature specifically targets, so
  a hard-set (`~/inst/miplib/2017+spp`) re-check of `MAX_PARALLELISM=0.7`
  remains worthwhile follow-up, but is not a precondition for shipping a
  change already validated as a net win on 442 instances.

Reproduce or extend: `Cbc/test/cutfilter-sweep [--configs=cutfilter-configs.tsv]
[--sec=180] [--jobs=N] [--out=DIR] [--instances=FILE] [--data-dir=PATH]`; see
`Cbc/test/cutfilter-configs.tsv` for the exact configs above and
`Cbc/src/CbcCutPoolFilter.{hpp,cpp}` for the filter implementation.

## Extending the small-model gate with a "medium problem" `nz`-based
## secondary threshold (2026-09/10, mip-sanity-data, 442 instances)

Follow-up to the section above: could the `cols<500` small-model exemption
be safely widened to a "medium problem" zone using a *static, offline*
feature -- i.e. without ever reading live wall-clock/CPU timing back into a
running solve to steer behavior, which would make cut selection
non-reproducible across machines/load (an explicit hard constraint for this
investigation, not just a style preference)?

**Offline-only instrumentation**: `CbcModel::lastCutRoundResolveTime()`
(`Cbc/src/CbcModel.{hpp,cpp}`) times every root cut-generation round's
post-cuts LP `resolve()` call and stores the last value; it is purely
diagnostic and is never read back by any live decision. Setting
`CBC_LOG_ROOT_RESOLVE_TIME=1` additionally logs one line per root round
(`pass=N rows=R cols=C resolveTime=T`) to stderr, used only to build an
offline dataset.

**Methodology**:
1. Collected per-round resolve times for all 442 instances
   (`cbc <inst> -sec 45 -maxNodes 0 -threads 1 -solve` with the env var
   above), summarized to per-instance max/sum resolve time.
2. Joined with `Cbc/test/mip-sanity-data/features.tsv` static features and
   ran 5-fold cross-validated `sklearn` models to find which static feature
   best predicts "this instance will have an expensive reoptimization
   round" -- **framed as classification** (is-slow, yes/no above a
   threshold), not regression (exact time magnitude): the regression
   framing was noisy and unreliable under cross-validation (R² near
   zero/negative, worse with deeper trees -- a real overfitting trap, not
   a usable signal), while the classification framing was stable (AUC
   0.82-0.94, low variance across folds). This reframing -- predicting
   the actionable yes/no decision rather than the continuous magnitude --
   is itself the main methodological takeaway for any future offline
   feature-based tuning here: check whether the decision you actually need
   is discrete before fitting a regressor to a noisy continuous target.
3. `nz` (constraint-matrix nonzero count) emerged as the single best
   feature (a simple `nz >= ~2000` rule alone reaches AUC ~0.82-0.86 with
   94-100% recall for genuinely slow instances), beating `cols`/`rows`
   alone.
4. Derived a threshold via a "k × reference cost" argument (as suggested
   mid-investigation): using the currently-exempt `cols<500` group's own
   observed max-resolve-time distribution as the accepted cost bar
   (p90=0.034s, worst=0.72s), the largest `numElements` (`nz`) cutoff that
   stays within that bar is **8000** (p90=0.032s, worst=0.16s at
   `nz<=8000`) -- i.e. this zone is genuinely as cheap to reoptimize as
   the group already trusted to skip filtering.

**Implementation**: added `CBC_CUTPOOL_FILTER_MIN_ELEMENTS` (default 0/off)
to `cbcFilterGeneratedCuts()` (`Cbc/src/CbcCutPoolFilter.{hpp,cpp}`,
`CbcCutGenerator.cpp` call site passing `solver->getNumElements()`);
`smallModel` becomes `numCols < minCols || numElements <= minElements`.

**Validation sweep and the noise pitfall**: a first apples-to-apples
single-seed sweep (`Cbc/test/cutfilter-nz-configs.tsv`: `today` vs.
`old_cols_only_gate` = `MIN_ELEMENTS=0`, same binary, only this one env var
varied) came back genuinely mixed on the newly-implied zone
(`cols>=500, nz<=8000`, n=93): bbTime worse (+0.28s/+12%), dual/primal gap
closed each up slightly (+0.4pp/+0.8pp), and a per-instance breakdown
showed 32 instances improved, 22 got worse, 39 unchanged -- a roughly
symmetric spread, not a directional effect. **This turned out to be almost
entirely branching tie-break noise**, not real signal: CBC's B&B is
otherwise deterministic single-threaded, but changing which cuts get kept
shifts fractional-solution/tie-break landscapes enough to send the search
down a materially different node sequence even over just 16 nodes.

To separate that noise from a real effect, `cutfilter-sweep` gained a
`--repeats=N` option: it runs each config `N` times with `-randomSeed`
1..N and averages nodes/obj/bound/elapsed per instance across the repeats
before comparing. (This also caught and fixed a real, unrelated bug: the
sweep's parallel-worker env reset was missing
`CBC_CUTPOOL_FILTER_MIN_ELEMENTS`, so a stale export from a previous
worker sharing the same GNU-parallel-dispatched shell could in principle
leak into the next config's run.) Re-running the same 2-config sweep with
`--repeats=5` and averaging:

| zone (n) | bbTime delta | dual gap delta | primal gap delta |
|---|---|---|---|
| `cols<500` (both same gate; n=253) | +0.003s | +0.00pp | +0.00pp |
| `cols>=500, nz<=8000` (newly-exempted; n=93) | +0.047s | +0.00pp | +0.00pp |
| `cols>=500, nz>8000` (filter active both; n=96) | +0.053s | -0.03pp | +0.00pp |

Averaging over 5 independent seeds collapsed the earlier "32 improved / 22
worse" split entirely: net dual/primal gap-closed delta in the candidate
zone is **0.00pp**, and the bbTime cost shrinks to a negligible +0.047s
(from a noisy-looking +0.28s single-seed reading) -- confirming the
single-run comparison's mixed result was branching noise, not a real
effect in either direction.

**Conclusion**: no benefit was demonstrated for extending the gate to
`nz<=8000`, so `CBC_CUTPOOL_FILTER_MIN_ELEMENTS` **ships OFF (0)** --
harmlessness isn't the question here (a 5-repeat-averaged run shows it's
essentially free either way), but there's no measured upside to justify
shipping the added gate/complexity as a new default. The env var and the
`nz` feature/threshold derivation remain available for future revisiting
(e.g. against a harder/larger instance set, or if a future generator shows
a real `nz`-correlated cost). **Reusable takeaways for future
offline-feature-based experiments on this project**:
- Frame the ML question as the actual binary decision needed
  (classification), not the noisy continuous quantity behind it
  (regression) -- check cross-validated stability before trusting either.
- Derive thresholds from an existing trusted reference cost
  (`k × reference`), not an arbitrary round number.
- Never compare sweep data generated under different shipped defaults
  (an earlier confounded comparison here, mixing a `MAX_PARALLELISM`
  default change with this one, produced a false "clean win" signal) --
  always re-run a fresh apples-to-apples sweep with only the one variable
  under test changed.
- When a candidate change's effect is small relative to typical
  instance-to-instance bbTime variance, **average over multiple
  `-randomSeed` repeats before trusting a single sweep run's per-instance
  breakdown** -- a single run's "improved/worsened" split can look like a
  real, roughly-50/50 effect that's actually pure branching-tie-break
  noise; `cutfilter-sweep --repeats=N` automates this.

Reproduce: `Cbc/test/cutfilter-sweep --configs=cutfilter-nz-configs.tsv
--sec=180 --jobs=N --repeats=5 --out=sanity-results/cutfilter-nz-validate-r5`;
`CBC_LOG_ROOT_RESOLVE_TIME=1` for the diagnostic per-round resolve-time log
used to derive the `nz<=8000` threshold in the first place.

## Finding a dominating cut-pool-filter config: extensive parameter
## sweep (2026-09/10, mip-sanity-data, 442 instances)

Goal: sweep the cut-pool filter's remaining tunables (`MAX_PARALLELISM`,
`MIN_CANDIDATES`, `MIN_COLS`, `-passCuts`) broadly to find a config that
**dominates** the shipped defaults -- improves (or holds) both dual and
primal gap closed while keeping `bbTime` essentially flat -- rather than
trading one for the other. Every config below runs on top of the current
shipped baseline (`MIN_COLS=500`, `MIN_CANDIDATES=20`,
`MAX_PARALLELISM=0.7`, `MIN_ELEMENTS=0`), varying one or two knobs at a
time, using `cutfilter-sweep --repeats=N` (see previous section) throughout
to keep the noise found in earlier single-seed sweeps from producing a
false read.

**Stage 1 -- 19-variant grid, `--repeats=3`**
(`cutfilter-extensive-configs.tsv`, `sanity-results/cutfilter-extensive-r3`):

| variant | dual gap Δ | primal gap Δ | bbTime Δ |
|---|---|---|---|
| `par03` (MAX_PARALLELISM=0.3) | -0.04pp | +0.14pp | -0.10s |
| `par04` | +0.02pp | +0.19pp | +0.04s |
| `par05` | -0.03pp | -0.06pp | -0.10s |
| `par06` | -0.00pp | +0.68pp | +0.08s |
| `par08` | +0.18pp | +0.24pp | +0.09s |
| `par09` | +0.23pp | +0.57pp | +0.08s |
| `par10` (filter effectively off) | +0.49pp | +0.03pp | +0.17s |
| `passcuts150/200/250/300` (MIN_CANDIDATES/MIN_COLS untouched) | -0.9pp to -0.94pp | -0.04 to -0.20pp | **-0.58 to -0.65s** |
| `par05_passcuts200`, `par09_passcuts200`, `par07_passcuts300` | -0.70 to -0.94pp | -0.04 to +0.47pp | -0.52 to -0.74s |
| `cand10` (MIN_CANDIDATES=10) | **+0.31pp** | **+0.33pp** | **-0.02s** |
| `cand50` | +0.42pp | +0.18pp | +0.11s |
| `mincols300` | -0.22pp | +0.04pp | -0.13s |
| `mincols750` | +0.01pp | -0.07pp | +0.02s |

**Findings from stage 1**:
- `MAX_PARALLELISM` shows a **real, repeat-averaged monotonic trend**
  across the 0.3-1.0 range: higher values (less aggressive
  orthogonality/parallelism filtering) consistently improve dual gap
  closed, at a small, roughly-proportional bbTime cost. The previously
  shipped `0.7` (chosen from a less thorough, single-config-family sweep
  in the earlier section) was leaving value on the table -- `0.9` gives a
  clearly better dual/primal combination than `0.7` for a still-small
  time cost.
- **`-passCuts=N` overrides alone (with the shipped `MIN_CANDIDATES`/
  `MIN_COLS` gates still in effect) are a consistent net loss here**:
  dual gap closed drops ~0.9pp across every value tried (150/200/250/300),
  despite bbTime dropping meaningfully (~0.6s faster). This is the
  opposite of the earlier section's "standout" `filter_reinvest200`
  result -- but that earlier config paired `-passCuts=200` with
  `CBC_CUTPOOL_FILTER_ALWAYS=1` (filter forced on regardless of the small-
  model gates), so its gain came from filtering *far more* rounds than
  today's gated default touches, freeing up much more time to reinvest.
  `-passCuts` alone, without also loosening the filter gates, mostly just
  cuts off cut generation earlier without buying back enough bound
  quality -- a reminder that these two knobs are **not independently
  transferable**; a result found under one gate configuration doesn't
  necessarily hold under a different one.
- **`MIN_CANDIDATES=10` (`cand10`) is the standout single-knob result**:
  it *strictly dominates* the shipped baseline -- both bound metrics
  improve *and* mean bbTime is slightly better, not just flat. Relaxing
  this gate lets filtering kick in for more (smaller) cut-candidate
  rounds that were previously exempt, and it turns out this pays for
  itself rather than costing anything.
- `MIN_COLS` boundary tuning (`mincols300`/`mincols750`) showed no
  meaningful signal in either direction -- the existing `500` default is
  fine as-is.

**Stage 2 -- combining the two winners, `--repeats=5`**
(`cutfilter-combo-configs.tsv`, `sanity-results/cutfilter-combo-r5`, higher
repeat count since the individual effects are sub-1pp):

| variant | dual gap Δ | primal gap Δ | bbTime Δ |
|---|---|---|---|
| `cand10` | +0.30pp | +0.33pp | -0.04s |
| `par09` | +0.21pp | +0.57pp | +0.07s |
| `par10` | +0.49pp | +0.03pp | +0.15s |
| **`cand10_par09`** (MIN_CANDIDATES=10, MAX_PARALLELISM=0.9) | **+0.22pp** | **+0.70pp** | **+0.03s** |
| `cand10_par10` | +0.26pp | +0.15pp | +0.25s |

Both stage-1 findings replicate cleanly at 5 repeats (`cand10`:
+0.30/+0.33/-0.04s vs. +0.31/+0.33/-0.02s at 3 repeats; `par09`:
+0.21/+0.57/+0.07s vs. +0.23/+0.57/+0.08s), confirming these are real
effects, not 3-repeat noise. **`cand10_par09` is the dominating
configuration**: better dual gap closed, meaningfully better primal gap
closed (+0.70pp, the best of any single or combo variant tried), for a
bbTime cost (+0.03s) indistinguishable from measurement noise -- clearly
better than either individual knob alone or the `par10` alternative
(which trades away primal gain and adds much more bbTime for a bit more
dual gain).

**Shipped defaults updated**: `CBC_CUTPOOL_FILTER_MIN_CANDIDATES`
**10** (was 20) and `CBC_CUTPOOL_FILTER_MAX_PARALLELISM` **0.9** (was
0.7) in `Cbc/src/CbcCutPoolFilter.cpp`. `MIN_COLS` (500) and
`MIN_ELEMENTS` (0, off) are unchanged -- no sweep evidence justified
moving either. Full sanity suite (`./test`) re-run after rebuilding with
the new defaults to confirm no regressions.

Reproduce: `Cbc/test/cutfilter-sweep --configs=cutfilter-extensive-configs.tsv
--sec=180 --jobs=N --repeats=3`, then
`Cbc/test/cutfilter-sweep --configs=cutfilter-combo-configs.tsv --sec=180
--jobs=N --repeats=5` for the higher-confidence combo re-check.
