# SppGrasp — set partitioning/packing heuristic with slack columns

## Current solver default (2026-10-28)

`sppGrasp` defaults to **auto**: enable SppGrasp when the existing structural
applicability checks accept the model, with **500 million work units per call**
and **FPump retained** (`sppGraspFpump on`). `on` is an alias for this enabled
mode; it does not force unsupported models through the applicability checks.
Explicit `sppGraspWork`, `sppGraspFpump` and `feasibilityPump` settings take
precedence. `-sppGrasp off` or `-heur off` disables the heuristic.
This changes the solver defaults, not the standalone heuristic class defaults.

This is the measured `-sppGrasp on -sppGraspWork 500 -sppGraspFpump on`
candidate, not a new untested trigger. On all 47 SPP-dominant models with four
matched seeds (564 validated solves across three arms), it lowered mean PDI
by **29.85%** versus OFF and preserved every one of OFF's **104 optimal solves**.
No-incumbent runs fell from 16 to 4; mean runtime rose from 839.42 to 839.85 s.
Individual regressions remain, and the tuning-exposed collection is not an
unseen-instance holdout. Historical defaults below describe earlier studies.

The default change also passed a fresh before/after run of all **511**
`mip-sanity-data` instances, using the suite's own time/node limits:
511 validated passes and 345 confirmed optima in each run, no individual
proof losses, and no regressions detected by `compare-results` (three
final-gap improvements). This is a regression check, not another 1,800-second
PDI experiment. Default/AUTO parity, explicit work/pump/off overrides,
initial-LP/preprocessing timeouts and the installed binary's unqualified
`rmp03 -threads 32 -solve` path were checked separately.

- [Full report, plots, manifest and source patches](https://github.com/h-g-s/set-packing-partitioning-instances/tree/main/results/2026-10-28-sppgrasp-auto-confirmation)
- [PDF and full raw evidence](https://github.com/h-g-s/set-packing-partitioning-instances/releases/tag/sppgrasp-auto-confirmation-2026-10-28)
- [Forrest discussion and test results](https://github.com/coin-or/Cbc/commit/65e778e18abadcd13a84ad8a900969b08cbc2450#commitcomment-207118838)

`CbcHeuristicSppGrasp` (`Cbc/src/CbcHeuristicSppGrasp.{hpp,cpp}`) targets pure
set partitioning/packing models (binary columns, unit coefficients, rows
`Σx = 1` or `Σx ≤ 1`) where **every partitioning row has a singleton "slack"
column** (covers only that row, at a penalty cost), so a trivial solution
always exists. Optional artificial-slack mode can extend applicability to
models missing native slack columns. The motivating instances are `rmp01`–`rmp18` in
`/home/haroldo/inst/miplib/2017+spp`. The same structure also appears in
`eil*`, `ds`, `ds-big`, `irp`, `ivu06` and `ivu06-big`. A prior full
mip-sanity-data diagnostic at submodule commit
`82ef3107342a09648e34c2ac5db36f9d83ef2c01` used
`-sppGrasp on -sppGraspArtificial 1.1` and reported applicability on 20
instances and 39 root-sequence calls; therefore the dataset is not
categorically inapplicable. `CbcHeuristicSppGrasp::applicability()` returns
native applicability when singleton slacks already exist, or experimental
artificial-slack applicability when that factor is positive and the model
otherwise passes the structural checks. Those diagnostic runs are integration
coverage, not a representative comparison of SppGrasp policies.

At log level 1, the original-model run prints a compact `SPPGrasp` summary
(first cost to best cost, or no feasible solution, plus elapsed time).
The opening `SPPGrasp ...` text is flushed before the search starts;
the result is appended on the same line when the search finishes.
Root-node calls use the heuristic results table without individual
`SppGrasp: first ...` / `SppGrasp: no feasible solution ...` diagnostics.
Those detailed per-call messages remain available at log level 2 and above.

> **PDI EVIDENCE STATUS — HISTORICAL RANKINGS WITHDRAWN (2026-10-21).**
> Prior PDI means, paired deltas, confidence intervals, and
> no-incumbent-by-horizon counts in this document are withdrawn and must not
> be used for policy ranking. Their progress CSVs did not timestamp the
> accepted original-model SppGrasp incumbent before root processing, so the
> earliest genuine incumbent can be missing from the PDI history; the older
> analyzer also used the text-log end time instead of the progress CSV's
> global `final` event. This affects the mixed-neighborhood/related-row,
> pump-policy, adaptive-gate, root-order, and staged-effort PDI comparisons.
> Do not infer that the reported ranking, interval, or no-incumbent count
> survives. The historical raw CSVs and endpoint results are preserved.
> Saved-solution validation, terminal status/proof counts, and final
> primal/dual gaps do not depend on the omitted event and remain usable as
> endpoint evidence. The full provenance/count audit is in the session
> artifact `files/adaptive-gating/pdi-correction/historical-pdi-audit.json`.
> Corrected-clock reruns show a favorable mixed-neighborhood PDI result on
> fresh seeds of the same 36 fixtures (not an instance holdout); the 250M
> stall gate lowered PDI but lost proofs; and every tested explicit root
> ordering was worse than legacy even when FPump performed LP/pass work.
> The 500M gate's fresh-seed replication is also on the same fixtures and
> retains a terminal-gap tradeoff. Corrected results and limitations are summarized in
> [Corrected common-origin PDI evidence](#corrected-common-origin-pdi-evidence-2026-10-21).
> Those tuning comparisons did not change solver defaults. The later,
> separately confirmed native pre-LP completion now defaults to `auto`;
> see [Integration](#integration).

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

### Early native completion (automatic for eligible models)

```sh
Cbc/src/cbc problem.mps.gz -solve -solu problem.sol
# Disable only the early completion:
Cbc/src/cbc problem.mps.gz -sppGraspNativePreLp off -solve
```

`sppGraspNativePreLp` defaults to **auto**. It tries one
deterministic feasible completion after pre-root strengthening but **before
the initial LP**. Existing SppGrasp, FPump, cut and branching parameters are
not retuned or reordered. `on` uses the same safety checks as `auto`, not a
forced run. `off` disables this pass; `-heur off` or `-sppGrasp off` also
disables it.

The check uses the **current solver's actual rows and bounds**, not original
input statistics and not only the rows retained by SppGrasp's internal
representation. Every partitioning row must have an available real binary
alternative that touches no other active constraint. For each such row,
choose the cheapest strictly private alternative; a cheaper column coupled
to a benign omitted row does not qualify. Complemented columns are mapped
back to their real values. Forced columns are conservatively rejected.
The complete vector is checked against every actual row, column bound and
integer requirement, and its objective is recomputed including the objective
constant. It must strictly improve the incumbent and respect the user cutoff.

This is **feasibility only**: no LP, artificial columns, randomized
construction or LNS is run in this pass. It does not promise a good objective.
Extraction and validation time count toward the global solve limit, but not
toward GRASP/LNS work units. The code does not change the LP solution or basis
while constructing the candidate.

The implementation supports binary linear **minimization**
models with the legacy root sequence and SppGrasp enabled. It conservatively
skips custom solver callbacks, Cbc event handlers, installed cut generators,
SOS/noninteger branching objects, nonlinear models, AMPL models, and pending
MIP starts or hot starts. Those paths retain their existing behavior.
Log level 2 reports why a requested completion was skipped.

An accepted vector is saved as a genuine incumbent before the LP starts.
If the initial LP times out, the solution writer and statistics retain that
integer vector rather than exporting the fractional relaxation as its place.
`-progressCsv` records `SppGraspNativePreLp` at its real positive acceptance
time, with an explicitly unknown dual bound. Early-return progress histories
also receive a final event; this finalization is data-only and does not
dispatch callbacks before search. The same final-event repair applies to
explicitly disabled runs, so on/off PDI comparisons do not compare different
reporting omissions.

Focused coverage:

```sh
python3 Cbc/test/spp-grasp-native-prelp-selftest.py
```

This exercises strict versus packing/benign-row coupling, cheapest private
selection, incomplete coverage, complements, negative costs, objective
constants, user cutoffs, progress ordering, saved-vector feasibility,
MIP-start precedence, custom callback/cut/SOS guards, existing incumbents,
unsupported modes, default/explicit-auto parity and explicit opt-out behavior.
It compiles its small
C++ integration probe against the configured in-tree library; no install
or new dependency is required.

#### Integration confirmation (2026-10-22)

The integrated option was compared **on/off in the same frozen binary**,
with unchanged legacy search and FPump explicitly on in both arms, at a
common 120-second horizon. Two fresh seeds (3621–3622) on the original
42-instance cohort gave:

| Metric | Off | On |
|---|---:|---:|
| Mean PDI | 0.447751 | 0.344532 |
| Proven-optimal runs | 42/84 | 42/84 |
| Runs without an incumbent | 10/84 | 1/84 |

There were no individual proof gains or losses. This is another same-instance
replication, not an independent population. All saved solutions passed
independent validation. `compare-results` still flagged **one terminal-gap
regression**, `eil33-2`/3622: **5.1833% -> 5.3114%**, a widening of
0.1281 percentage points; it is retained, not dismissed as noise. Missing
incumbents or unknown duals are not exported as finite MIP gaps.

A structural-only screen of 150 additional pure-integer sanity models with
partitioning rows and at most two million nonzeros found just one strict
completion candidate outside the tuning cohort, `harp2`. Its two runs
improved mean PDI **0.004210 -> 0.002071**, with no proofs in either arm.
These models had prior correctness-suite exposure, and **one additional
instance is not a broad generalization test**.

The full confirmation comprises **179 validated solver runs**: 168 original
cohort runs, four `harp2` runs, three duplicate off-controls, and four separate
12-second initial-LP timeout probes. All four timeout probes retained a
genuine independently validated integer solution, a positive-time native
event, an unknown dual and a final event. No PDI value was missing.
Accepted completion extraction/validation took a median **0.0274 seconds**
and maximum **3.052 seconds** under 32-way load; these figures exclude
rejected attempts. Duplicate controls showed PDI variation of about 0.0041
on `rmp03` and 0.0054 on `air04`. The RMP mean on/off difference,
-0.00146, does not establish a separate RMP optimization benefit.

At the time of this confirmation the option was **off by default**. This focused confirmation does not
replace the earlier full-suite evidence or claim a new all-green full-suite
run. Frozen manifests, binaries, logs, vectors, structural screen and
`compare-results` output are retained in session artifacts under
`files/native-prelp-integration/`.

The same frozen binary, 43 models and two seeds were then repeated with a
**720-second horizon**, retaining three duplicate off-controls (**175 runs**).
All saved solutions validated; no PDI values were missing. On the original
42 models, mean PDI fell **0.299580 -> 0.203624** (32.0% lower),
proofs remained **45/84 in each arm**, with no individual proof transitions,
and missing incumbents fell **8 -> 0**. `harp2` was proven optimal in both
seeds and both arms, bringing the combined proof count to **47/86** each.
The RMP mean PDI difference was only **-0.000177**, not a demonstrated
RMP optimization gain.

The earlier `eil33-2` terminal-gap regression did not persist: **both seeds
and both arms proved objective 934.007916**, and enabled PDI was lower for
both seeds. However, four other terminal-gap regressions remain in this
longer-horizon comparison: `t1722`/3621 **24.6635% -> 25.3565%**,
`t1722`/3622 **23.8927% -> 24.2142%**, `rmp16`/3622
**35.0511% -> 35.3672%**, and `ds`/3622 **71.1449% -> 73.2947%**.
These observed regressions are retained; equal proof counts and better
aggregate PDI do not establish uniformly better terminal quality.
Frozen evidence is under `files/native-prelp-twelve-minute/`.

#### Default promotion after upstream rebase

After rebasing onto `coin-or/Cbc`'s `next` at `3a56bdc2`, the early completion
was promoted to default **auto**. Eligibility is determined by the strict
current-model checks above, never by instance names. Repeated aggregate PDI
improvements, unchanged proof counts with no individual proof losses, and
fewer missing incumbents justify enabling it despite isolated terminal-gap
regressions. This is not a claim of uniformly better endpoint gaps or of a
separate RMP optimization gain. The other experimental root sequences and
tuning profiles are not promoted by this change.

The local lazy/TSP checks also exposed a separate integration omission:
`-heur off` did not turn off SppGrasp. It now does, preserving the C interface's
requirement to disable heuristics when lazy constraints are registered.

With default auto, the rebased build passed the full **511/511** sanity
suite (345 proven-optimal runs; zero failures, overtimes or errors), plus
**9/9** C API smoke tests, **64/64** LP-relaxation checks, **213/213**
lazy/TSP checks, **198/198** MIP-start checks, **80/80** coefficient-tightening
checks and **34/34** row-activity checks. Final-bound and progress-callback
tests also passed. Focused native-completion, coverage, staged-effort,
parameter/FPump policy, root ordering, progress-history and objective-offset
checks passed. After refreshing configure-time provenance, the build was
installed to `~/prog/cbc`; the quick suite and native-completion test passed
again, including the installed binary's default-auto and explicit-off paths.
Logs and per-instance results are retained under
`files/rebase-native-auto-sanity/` and `files/rebase-native-auto-*.log`.

#### RMP sanitizer stress confirmation (2026-10-23)

Frozen debug builds instrumented all five COIN-OR projects separately with
ASan, UBSan and TSan, using static COIN-OR libraries, assertions, debug
symbols and frame pointers. System libraries and sanitizer runtimes remained
dynamically linked and were not rebuilt with instrumentation. No sanitizer
suppressions were used; each process stopped on its first report.

Each sanitizer ran `rmp11`, `rmp13`, `rmp16`, `rmp17` and `rmp18` in serial
and with two CBC workers, for one hour per run, with matched seeds and zero
absolute/relative gap tolerances. All **30 runs** reached their time limits
normally; all saved integer solutions passed independent validation.

| Sanitizer | Clean one-hour runs | Search nodes |
|---|---:|---:|
| ASan (including leak detection) | 10/10 | 75,252 |
| UBSan | 10/10 | 69,369 |
| TSan | 10/10 | 12,650 |

A further TSan run on `rmp11`, seed 8712, used **32 CBC workers for 30
minutes**. It explored **2,075 nodes**, performed **3,982,989 LP iterations**
and consumed 45,518 CPU seconds over 1,802 wall seconds (about 25 active
cores on average). Its saved integer solution also validated independently.
No run reported memory errors, leaks, undefined behavior, races, assertion
failures or crashes, and no bound/proof contradicted the recorded known
feasible objectives. These checks are coverage evidence, not a proof of
universal correctness or a performance comparison between sanitizers.
Frozen source patches, input and binary hashes, commands, logs and results
are retained in the session artifacts under `files/rmp-sanitizer-stress/`.

Before publication, Cbc was rebased onto `36293c2c` (the installed
`CbcSolverCutSetup.hpp` fix), and the workspace onto `978b745`, including
its Clp `5d224a70` pointer. `./build Clp` rebuilt and installed Clp and both
downstream projects. Clp's unit, OsiClp, racing and barrier-control checks
and Cgl's unit tests passed using official Sample data. The complete Cbc
suite again passed **511/511**, with **344** confirmed optima and zero
failures, overtimes or errors, plus all ancillary suites listed above.
This run used 32 concurrent jobs rather than the earlier seven; its solve
counts and timings are not a paired performance comparison. All focused
SppGrasp tests, including acceptance/SA, phase switching, aggregate work,
backtracking, progress gates and the installed default-auto path, passed.
Publication logs are retained as `files/publish-spp-*.log` and
`files/publish-spp-sanity/`.

### Experimental related-row selection

The fixture benchmark accepts `--related=P` to draw later LNS seed rows
from partitioning rows freed by earlier seeds. `--relatedafter=1` keeps
this probability at zero until the run has found an artificial-free
solution, then uses `P` for subsequent iterations. With native singleton
slacks, a valid trivial solution already counts as feasible; temporary
artificial columns do not. The switch stays enabled once feasibility has
been found, even if a later accepted search state uses artificials.
The default is `--relatedafter=0`, preserving the always-on interpretation
of `--related`. These remain experimental benchmark/`RunParams` options,
not new solver command-line parameters or tuned defaults.

### Experimental bounded backtracking repair

`--btprob=P` supplements a fraction of LNS greedy repairs with bounded
depth-first search; zero preserves the greedy path and its random draws.
The greedy result is retained as the fallback. Search keeps retained and
forced columns fixed, branches on scarce-option open partitioning rows,
and considers columns in construction-score order. Sparse row-owner
updates undo each selection without copying the entire state at every node.
It does not prune by accumulated cost, which would be invalid with negative
column costs.

`--btwidth` (default 3) limits alternatives per row, `--btdepth` (8) limits
the levels with alternatives, and `--btnodes` (200) limits selected search
nodes. Beyond the branching depth, only the first option is tried.
`--btwork` (one million) caps extra counted search work; a single sparse
operation or the final local-search improvement may exceed that budget.
Budget exhaustion is not an infeasibility proof and returns the best
completed repair. Complete repairs prefer fewer artificials, then lower
cost. Both greedy and search work count toward the run's overall work cap.
These settings remain experimental; the default trigger probability is zero.

Run `python3 Cbc/test/spp-backtracking-selftest.py Cbc/test/spp-grasp-bench`
from the workspace after building the benchmark for small exhaustive checks.

`--btstats=FILE` writes separate aggregate repair diagnostics as TSV, leaving
the improvement trace unchanged. Counters include calls, selected nodes,
completed leaves, artificial-free leaves, dead ends, exit reasons (work,
nodes, exhausted bounded tree, invalid retained partial solution), calls
without a completed leaf, improvements over the call's greedy fallback,
and calls converting an artificial fallback to an artificial-free repair.
They also record the total/maximum initially open partitioning rows,
maximum search depth, and extra work excluding greedy fallback construction.
An exhausted bounded tree is not an infeasibility proof: branching width
and depth still restrict the explored alternatives. Per-call improvements
and feasibility gains are not necessarily new run incumbents.

`--btonlyart=1` checks greedy's completed repair first and samples the
backtracking probability only if that repair still uses artificials (or
greedy could not complete it). Skipped feasible repairs do not consume a
trigger random draw or extra search work, and are counted separately in
`skipped_feasible`. `--btrealfirst=1` places real columns ahead of artificial
ones in the bounded branch list, preserving score order within each group;
singleton-choice rows can be selected without scanning the remaining rows.
Artificial alternatives can still be excluded by the branching-width limit,
but the completed greedy solution remains available as a fallback.
Both options default to zero and remain experimental.

### Experimental LNS acceptance policies

The existing threshold policy and both LAHC variants now share a small
interchangeable acceptance component with experimental simulated annealing
(bench `--amode=3`). Modes 0–2 retain their previous acceptance tests and
LAHC ring reset behavior; invalid (`COIN_DBL_MAX` or non-finite) trials are
rejected explicitly. SA accepts non-worsening trials, and accepts a worsening
trial with the Metropolis probability `exp(-normalized_delta / temperature)`.
The positive normalization scale is `max(1, |current objective|,
|trial objective|)`, so negative and zero objectives need no special-case
division or sign convention.

`--satemp` sets the initial temperature as a fraction of that scale,
`--sacool` is the work-based temperature half-life, and `--sareheat` optionally
restarts the cooling clock after a number of consecutive rejected trials.
All cooling/reheating is driven by deterministic SppGrasp work, not elapsed
time. A penalty escalation resets the acceptance history/cooling phase at the
new penalized objective scale. Best-solution recording is independent of
whether a trial becomes the current LNS state. `--acceptstats=FILE` writes
candidate/accept/reject/invalid/reheat counts separately from `--btstats`.
These options are benchmark/`RunParams` experiments only; solver defaults
and activation policy are unchanged. Run
`python3 Cbc/test/spp-grasp-acceptance-selftest.py` after building the
benchmark for direct policy and seeded end-to-end checks.

**Metric correction:** the first analysis mistakenly divided by `|reference|`
instead of the established symmetric denominator `max(|value|, |reference|)`.
Those inflated scores are withdrawn; the following are corrected **final
primal-gap** scores, not PDI. References were frozen across labels as the
minimum of numeric BKS and any artificial-free result in the screen/holdout
data (40/40 fixture names matched numeric BKS entries after stripping `.root`).

On the 40-fixture set with a 1.5-billion-work cap, artificial penalty
escalation every 500 million work, and related-row selection enabled after a
real solution, a seven-policy screen over seeds 61–70 scored 14.285 for
threshold, 14.359 for SA temperature 0.02, and 14.486 for temperature 0.005.
The best SA setting was still slightly worse than threshold (SA 0.02 paired
delta `+0.074` percentage points, seed-bootstrap 95% interval
`[-0.551, 0.788]`; 32 no-solution runs for each). Temperature 0.15 and a
three-billion-work cooling half-life were worse. On fresh seeds 71–80, SA
temperature 0.005 scored 14.036 versus threshold's 14.624 (paired delta
`-0.588` points, interval `[-1.171, -0.067]`; 31 versus 34 no-solution runs).
This holdout gain is mostly from the small `air` family and conflicts with
the screening direction. Matched threshold/SA tests on seeds 81–90 then found
SA 0.005 lower by `0.441` points on the independent-row backbone
(95% interval `[-1.047, 0.137]`) and `0.486` points on the phased related-row
backbone (interval `[-1.055, 0.035]`); each comparison had 34 versus 31
no-solution runs. SA 0.02 was similar but not better. The subsequent fresh
confirmation on seeds 91–110 did not reproduce the gain: SA 0.005 was
`+0.114` points versus threshold on the independent backbone
(interval `[-0.303, 0.553]`) and `+0.080` on the phased backbone
(interval `[-0.388, 0.548]`), with 66 no-solution runs for each policy in
both comparisons.

Across the more recent seeds 81–110, the descriptive pooled SA-0.005 delta
was `-0.109` points on the phased backbone (95% interval `[-0.482, 0.267]`,
100 versus 97 no-solution runs) and `-0.071` on the independent backbone
(interval `[-0.434, 0.292]`, also 100 versus 97 no-solution runs). Pooling
all phased screen/holdout/tuning/confirmation seeds 61–110 gives
`-0.143` points (interval `[-0.450, 0.163]`; 166 versus 161 no-solution
runs), but that aggregate includes the data used to select settings and is
descriptive, not an independent confirmation. The apparent gain is
concentrated in `air`; regressions in `rmp`, `t17`, and `eil` offset it.
These comparisons do not establish a robust overall improvement. Keep
threshold acceptance as the default; SA remains an experimental option.
All reported figures are corrected final primal gaps, not PDI. The SA
benchmark binaries were byte-identical (`bench-SA1` and `bench-SA2`), and
the corrected summaries, frozen references, scripts, and per-run evidence
are retained in the session acceptance-work artifacts.

#### Broader SA/LAHC tuning and fresh confirmation

A later, broader acceptance study used the same frozen references and
corrected symmetric final-primal-gap metric (100 for no feasible incumbent or
opposite-sign objectives; this is not PDI). Each policy was run on all 40 root
fixtures with paired seeds; refinement and confirmation cohorts also compared
independent-row and phased-related-row backbones. The score weights the `rmp`
family 50% and the mean of the other families 50%; no-solution counts and
feasible-only gaps are reported separately. The fixed-work comparison used a
1.5-billion work cap and the same construction/neighbourhood settings for every
acceptance policy.

The study comprised a 6,480-run coarse screen (seeds 121--122), an 8,800-run
refinement (seeds 131--135), a 5,600-run fresh confirmation (seeds 141--150),
and a 2,400-run additional confirmation (seeds 151--160). The screen varied
fixed SA temperature over `0.0001`--`1` and exponential cooling half-life
over `0.05`--`2` times the work budget; calibrated SA varied target uphill
acceptance and positive-delta quantile, with 100 threshold-policy warmup
trials. Refinement also compared 50/100/200-trial calibration, local
temperature/cooling refinements, linear cooling, and LAHC history lengths
5--5000 under both LAHC update rules. Calibration warmup work counted against
the same work cap, and the corrected binary starts cooling after warmup.

The leading candidate was empirical SA with 200 threshold warmup trials,
target uphill acceptance `0.1`, the 25th percentile of positive normalized
uphill deltas, and exponential cooling with a 750-million-work half-life.
On refinement seeds 131--135 it scored 14.153 versus 14.789 for threshold on
the independent backbone (delta `-0.636`, paired hierarchical-bootstrap 95%
interval `[-2.779, 0.409]`) and 13.987 versus 14.622 on the phased backbone
(delta `-0.635`, interval `[-2.892, 0.427]`). It had 15 versus 17 no-solution
runs in each comparison, but its feasible-only gap was slightly worse than
threshold. These seeds selected the candidate and are screening/refinement
evidence, not independent confirmation.

The candidate's paired score remained lower on both later cohorts, but each
interval still included zero. On seeds 141--150 its deltas were `-0.309`
(95% interval `[-1.573, 0.292]`) and `-0.322` (`[-1.572, 0.259]`) for the
independent and phased backbones; no-solution counts were 31 versus 33.
On the additional, fresh seeds 151--160 the deltas were `-0.574`
(`[-1.904, 0.133]`) and `-0.288` (`[-1.744, 0.464]`), with 29 versus 32
no-solution runs. Pooling these two confirmation cohorts descriptively
(800 runs per policy/backbone), the calibrated candidate scored `-0.441`
points versus threshold on the independent backbone
(`[-1.512, 0.143]`) and `-0.305` on the phased backbone
(`[-1.381, 0.266]`), with 60 versus 65 no-solution runs in each comparison.
Its feasible-only mean gap was essentially tied on the independent backbone
(9.371 versus 9.358) and worse on the phased backbone (9.203 versus 9.109).
Thus the modest pooled score difference is largely associated with five fewer
no-solution outcomes, not a consistent improvement among feasible solutions.

Fixed SA at temperature `0.02` with a 750-million-work half-life was close to
threshold in pooled confirmation (deltas `-0.061` and `-0.041` points, both
with intervals crossing zero); it did not improve feasible-only gaps.
LAHC-L10, LAHC-better-L10, and LAHC-better-L5 all had worse mean scores than
threshold on seeds 141--150 on both backbones, with bootstrap intervals that
still included zero. The coarse screen's apparent best fixed setting did not
survive refinement, illustrating the noise and selection effect in small
screens. Overall, these results do not establish a robust acceptance-policy
gain. Keep threshold acceptance and all solver defaults unchanged; the
calibrated policy is only a promising experiment, not a recommended default.
This fixture study did not run SA through the CBC command-line solver or
compare solver-level PDI; that requires solver-facing policy controls and a
separate matched PDI experiment.

End-to-end validation also compared the installed pre-build Cbc binary
(`v2.933-156-g288f475d-dirty`, SHA-256 recorded with the run artifacts) with
the result of `./build Cbc` (`v2.933-158-g454a0e72-dirty`). The full
511-instance mip-sanity suite passed all 511 instances in both runs, with
344 confirmed optima each; `compare-results` found no status, objective, or
gap regressions. The C API smoke tests, LP-relaxation, MIP-start,
coefficient-tightening, row-activity, final-bound, and progress-callback
tests passed in both runs. The lazy-constraint/TSP test reported the same
pre-existing 119/213 checks passing and 94 failing before and after the
build; those failures are recorded rather than attributed to the acceptance
change. On bounded 120-second `rmp01`, `air04`, and `neos-1440225` runs,
both binaries returned validator-approved results: `rmp01` and `air04`
proved the same objectives, and `neos-1440225` stopped without an
integer-feasible solution in both. SppGrasp was exercised in the solver
logs on all three. No acceptance/default/Feasibility Pump behavior was
changed for these results. Full logs, result tables, solution files, and
baseline provenance are retained in the session integration-validation
artifacts.

At the full-suite 180-second limit, `supportcase42` also timed out without an
integer solution in both runs, but the frozen binary completed its root LP
while the rebuilt binary had not yet completed it. A matched 300-second
rerun completed the same root LP in both and produced the same validated
incumbent (`17.0014377001`), bound (`7.34356`), and node count (1317).

A ten-fresh-seed confirmation (51--60, 40 fixtures, 1.5 billion work cap)
found that small artificial-only search at probability 0.25 used about 82%
less extra search work than unconditional small search, while preserving
the rmp greedy trajectory. Its weighted score was 14.708 versus greedy's
15.111, with air04 failures 3/10 versus 5/10. Unconditional small search
scored 14.589 with 2/10 air04 failures in that batch. Real-column-first
ordering did not improve this comparison, and none of these policies solved
the three difficult neos instances. These modest, seed-sensitive feasibility
differences do not yet justify changing the default.

An initial diagnostic comparison (40 fixtures, three seeds, greedy plus
three search budgets; 480 runs) found that small searches improved only
about 4.6% of individual rmp greedy repairs. Small and standard budgets
completed no search repairs on ds/ds-big. Searches on the three difficult
neos instances often improved artificial solutions but never eliminated
all artificials. Increasing search budgets alone is therefore not supported
as a global policy; selective triggering and better branching need separate
experiments.

- `CbcSolver::babRunSppGraspOriginal()` runs it on the **original** model,
  after the root LP and **before preprocessing**, with the LP x/dj. The
  solution becomes the incumbent of `model_`/`babModel_` and is mapped
  through preprocessing like any other pre-preprocessing incumbent.
  Preprocessing usually destroys the structure (substitutions create rows
  such as `−x6 + Σ others = 0`), so a run inside B&B alone is not enough.
- If the preprocessed model still has the structure (rmp11, 16, 18), it also
  runs at the B&B root ('L' and 'C' hooks), starting from the incumbent.
- The default `-sppGraspFpump on` retains FPump. Explicit
  `-sppGraspFpump auto` restores the historical behavior:
  native singleton-slack SPP can switch off FPump unless the user explicitly
  set `-feas`; artificial-slack runs keep FPump enabled. FPump defaults are
  set with `setModeValAuto`, so `isUserSet()` means the user really set it.
- Parameters:
  - `-sppGrasp off|auto|on|both|before` (default `auto`; `on` is an alias).
  - `-sppGraspWork` (default 500, in millions of work units per call).
  - `-sppGraspNoImprove` (default 1000 LNS iterations without a new best).
  - `-sppGraspRealStallWork` (default 0, disabled): optional work-based stop
    after a real-feasible incumbent has stalled; see the adaptive-gate study
    below.
  - `-sppGraspTime` (default 60 s per call): a safety cap only, because
    reaching it makes results machine-dependent.
  - Solver-facing LNS controls retain the legacy defaults:
    `-sppGraspDestroyRows` (5), `-sppGraspStall` (200),
    `-sppGraspDestroyGrow` (0), and `-sppGraspArtificial` (1.1).
    The PDI-screened mixed bundle (`destroyRows=2`, `stall=0`,
    `destroyGrow=0.1`, `artificial=2`) remains opt-in pending review of its
    final-gap tradeoff. `-sppGraspRelatedRows` remains experimental (default
    0); a nonzero value activates connected-row selection only after a real
    artificial-free solution exists.
  - `-sppGraspFpump auto|on|after` (default `on`): `auto` keeps historical behavior; `on`
    prevents automatic disabling; `after` disables FPump only after the
    original-model SppGrasp call returns a real-feasible improving solution.
    Explicit `-feas on|off` always takes precedence.

## Solver-facing neighborhood PDI validation

**SUPERSEDED PDI RESULTS:** the means, paired intervals, and PDI-based
comparisons in this historical section are withdrawn pending corrected
original-stage incumbent histories. The saved-solution validation and
terminal proof/gap evidence below remain valid.

The legacy solver defaults were compared with the mixed neighborhood
(`destroyRows=2`, `destroyGrowProbability=0.1`, `stallIterations=0`,
`artificialFactor=2`) and with the same settings plus phased related-row
selection (`relatedRowProbability=0.75`, enabled only after feasibility).
All runs were full Cbc solves on 36 MIPLIB instances (all 18 rmp, air03–05,
10 eil, t1717/t1722, and three hard neos), with a 120 s horizon, matched
seeds 111/112, `-threads 0`, and exact `-progressCsv` events. Solutions were
checked using `cbc_validate_sol`; every saved solution passed. This full-solver
bundle comparison supersedes earlier fixture-only evidence when evaluating
the mixed bundle, but does not isolate the contribution of individual controls
or by itself authorize a default change.

The mixed bundle was confirmed on seed 113 across the same 36 instances.
Across all three seeds (108 paired instance-runs):

| setting | mean PDI (lower better) | proven optimal | no incumbent |
|---|---:|---:|---:|
| prior defaults | 0.26226 | 66 | 1 |
| mixed neighborhood | 0.23438 | 66 | 1 |

Paired PDI change was −0.02788 (instance-cluster bootstrap 95% interval
[−0.03772, −0.01577]); the same PDI direction appeared on each seed. The
mixed bundle also reduced mean logged SppGrasp wall time from 8.94 s to 5.62 s
per run in the initial two-seed screen. Because these values were tested as a
bundle, the experiment does not attribute the gain to any one control.

The related-row screen was slightly lower in mean PDI (0.24286 versus
0.27151 over seeds 111/112) but lost one proven-optimal solve (43 versus 44);
it was not promoted and remains off by default.

Separately, retaining FPump (`sppGraspFpump on`) was compared with disabling it
only after a returned real SppGrasp solution (`after`) on 10 cases including
air03 and the three hard neos, two matched seeds each. Mean PDI was 0.50587
versus 0.50579; the paired interval crossed zero, with equal optimal/no-
incumbent counts (11/20 optimal, 1/20 no incumbent per arm). In after-mode,
the pump-disable message appeared only on runs with an original-model
SppGrasp solution; infeasible/no-success cases retained FPump. There is no
evidence for a better pump default, so `auto` and explicit `-feas` precedence
remain unchanged. The solver-policy selftest also covers `-feas on` and a
cutoff preventing SppGrasp improvement.

## Matched full-suite validation of the mixed bundle

The mixed bundle was compared against a frozen Cbc binary built from the same
source revision and experimental parameter plumbing, with the legacy
neighborhood defaults restored. The args-empty control binary's help strings
and the original `RunParams` source confirm the legacy `destroyRows=5`,
`stall=200`, `destroyGrow=0` settings; the mixed arm explicitly supplied
`destroyRows=2`, `stall=0`, `destroyGrow=0.1`, and `artificial=2`. Both binaries
ran all 511
`mip-sanity-data` instances with the same harness limits and 32 GNU-parallel
jobs. Both had 511/511 validated PASS results, 344 confirmed optima, and no
status or optimal-count changes. `compare-results` did report two final-gap
regressions: `air04` widened from 0.8803% to 1.8850% and `air05` from 2.2810%
to 2.6044%; no other instance regressed. This is a real quality tradeoff even
though the matched PDI study favored the mixed bundle. The mixed bundle is
therefore available only through explicit parameter settings; legacy defaults
are retained until this final-gap tradeoff is reviewed.

## Results (120 s, `-threads 1`, 16 jobs in parallel, `cbc_pdi.py`)

**SUPERSEDED PDI TABLE:** these historical progress traces omit the
original-model incumbent and are not a complete primal history. The values
below are retained only to document the old experiment; do not use them to
rank variants or select defaults.

| set | variant | PDI | opt | no sol |
|---|---|---|---|---|
| rmp01–18 | baseline (control run concurrently) | 0.285 | 12 | 1 (rmp18) |
| rmp01–18 | SppGrasp | 0.145 | 12 | 0 |
| rmp01–18 | SppGrasp v2 (tuned LNS, work/no-improve stop) | 0.127 | 12 | 0 |
| eil*/ds/irp/ivu06 (15) | baseline | 0.675 | 5 | 3 |
| eil*/ds/irp/ivu06 (15) | SppGrasp | 0.566 | 5 | 3 |

mip-sanity-data: 511/511 pass and 344 confirmed optima in both arms of the
matched legacy-default versus mixed-bundle comparison; see the explicit
final-gap regressions above.

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

## Adaptive progress diagnostics and opt-in stall gate

**SUPERSEDED PDI COMPARISON:** the gate-on/off PDI means, paired interval,
and no-incumbent-by-horizon counts reported in this section are withdrawn
until the same cohort is analyzed with complete original-stage events and
the global CSV final timestamp. The deterministic fixture replay based on
final primal gap, solver exits, validated solutions, final proof counts,
and terminal gaps are separate endpoint evidence and remain available.

`CbcSppGrasp::featureSummary()` exposes structure already available after
loading an SPP model, with expected `O(nnz + ncols + nrows)` work (its
quantiles use `std::nth_element`, not a full sort): native singleton
coverage (excluding appended artificial columns), real options per
partitioning row, column-degree summaries, singleton-versus-multicolumn cost
differences, and restricted/complemented/forced-column fractions. It reports
LP fractionality and native-singleton LP mass only when an LP vector is
already present; feature extraction never solves an LP. The benchmark flags
`--features=FILE` and `--progress=FILE` export these independently of the
existing incumbent trace; the feature table reports `load_seconds` and
`feature_seconds` separately to make extraction overhead directly measurable.
Five info-only repetitions on `air04`, `rmp14`, `rmp18`, `ds-big`, and `t1717`
measured median feature extraction at 0.34 ms to 14.4 ms, or 4.1%–10.9% of
`CbcSppGrasp::load()` time (not including MPS parsing); no LP was solved.
Progress event kinds are 1 (initial/trivial solution or penalized best), 2
(real-feasible improvement), 3 (artificial-penalty epoch reset), and 4
(real-best stall stop). Inspect `artificial_used == 0` and a finite
objective, not the event kind alone, to identify genuine feasibility.
In particular a native trivial solution is logged even if construction
never improves it. Its measured event time and charged work are distinct
from time/work to the first cost improvement. Penalty rescaling is not
counted as real progress. These benchmark events are not the whole-solver
`progressCsv` history: an internal trivial vector is not claimed as a Cbc
incumbent before Cbc has actually accepted it.

`--totalwork=W` limits aggregate deterministic work across artificial-penalty
epochs, unlike `--maxwork`'s legacy per-epoch behavior when no explicit
`--artwork` schedule is used. Zero disables the aggregate cap; negative,
nonfinite, empty, or nonnumeric budgets are rejected. Checks occur at move
boundaries, so an indivisible construction/repair can overshoot the budget;
the trace reports the work actually spent. A fair comparison must retain
that overshoot rather than charge only the requested budget.

`-sppGraspRealStallWork M` is an experimental, explicit continuation gate
(`M` is millions of deterministic work; default 0 disables it). After a
real-feasible incumbent exists, the LNS call stops after one completed
iteration whose work has advanced by `M` since the last better real-feasible
incumbent. It does not stop a run that has not found a real solution, does not
discard the best real solution already found, and does not replace the
independent `sppGraspWork`, `sppGraspNoImprove`, or time safety limits. This
setting is wired to both original-model and root heuristic calls; it does not
alter feasibility-pump policy. It remains off by default pending full-solver
PDI evidence.
The direct-run check is
`python3 Cbc/test/spp-grasp-progress-gate-selftest.py Cbc/test/spp-grasp-bench`;
`spp-grasp-solver-parameters-selftest.py --cbc <cbc-binary>` also checks the
solver-facing option and activation message.

Structural and progress diagnostics were collected on 40 root fixtures, with
paired legacy and mixed-neighborhood runs on seeds 161--163 (240 benchmark
runs; mapped solutions/objectives were checked by the benchmark). The
descriptive feature associations are not a trained gate: several features
showed sample correlations with failure to find a real incumbent, but those
outcomes were concentrated in a few instances/families and do not establish
generalizable stopping decisions. In particular, do not use instance names,
family identity, BKS, final objectives, or future progress for runtime
decisions.

### Empirical feature analysis (2026-10-21)

The question was separated into four endpoints: finding any real-feasible
solution; improving the first genuine solution; final objective quality; and
whether extra work or a solver-side gate helps. These are not interchangeable.
The reproducible joins, per-instance/per-run TSVs, bootstrap summaries, and
nested tree predictions are retained under the session artifact
`files/spp-feature-analysis/` (`analysis.json`,
`instance-features-outcomes.tsv`, `direct-bench-per-run.tsv`,
`corrected-root-pdi-per-run.tsv`, `interpretable-rules.json`, and
`interpretable-rules-predictions.tsv`). The two root-fixture collections were
kept distinct; Cbc's SppRoot features were joined only to the 40 direct
SppRoot runs, and original-model Osi features only to exact-name matches.
Direct results are aggregated over the three legacy seeds per instance before
analysis; a seed is never treated as an independent feature row.

**A useful one-feature feasibility diagnostic is native singleton coverage.**
Define it as
`nativeSingletonRows / partitionRows`; it counts partitioning rows with a
usable *native* binary column whose retained normalized-row degree is one, and
excludes appended artificial columns. In the 40 direct fixtures, 26 models
had 100% native coverage and zero forced columns. All 26 found a genuine
feasible solution in all three legacy seeds (78/78); this is the expected
trivial completion of one private singleton per partitioning row, not a
learned quality prediction. Of the remaining 14 models, 31/42 direct runs
found a solution; ten instances still succeeded in all seeds, while the four
imperfect instances were `air04` (1/3) and three NEOS instances (0/3 each).
Thus full private coverage is a strong *feasibility certificate under the
loaded-model conditions*, but incomplete coverage does not imply failure,
and coverage says nothing about whether the solution is good or whether
continuing SppGrasp benefits the full CBC solve. The source counts singleton columns in its retained row representation and excludes
artificials in `CbcSppGrasp::load()` and `featureSummary()` in
`Cbc/src/CbcHeuristicSppGrasp.cpp`; `trivialSolution()` constructs and checks
the completion. `trivialSolutionExists()` in the corresponding header also
counts appended artificial slack columns, so that method alone is **not**
a native-feasibility certificate.

The certificate is **stage-local**: use the exact loaded matrix, current
bounds, fixed columns, complement/restriction handling, and packing rows at
that invocation. The original-model pass checks the original model; a root
pass must check the preprocessed/root model again, including any current
cuts, and validate the mapped incumbent. Original-model coverage can justify
a cheap original-model opportunity, but is not a certificate for the later
root model. For example, in 36 name-matched original/SppRoot fixture pairs,
19 changed partition-row count and 18 changed native-covered-row count.
`rmp03` changes from 766/766 native-covered original rows to 607/608 in its
historical SppRoot fixture; `air04` changes from 0/823 to 15/700. These
fixtures are not necessarily the current full solver's root/cut state.
Both vectors are retained separately in
`files/spp-auto-policy/original-vs-historical-spproot.tsv`; a rule trained
at one stage must not silently reuse another stage's vector.

The requested shallow-tree check did **not** produce a generalizable
feasibility predictor. With a fixed short structural candidate list, minimum
leaf size 5, instance-aggregated labels, and leave-one-family-out testing,
the nested stump/depth-2 procedure had feasible-rate RMSE 0.389 versus 0.308
for the family-training-mean baseline; depth 2 was not selected in any of
nine outer family folds. Its exploratory out-of-fold rule labelled 18/40
instances “risk” (estimated success rate below 100%): it caught the four
imperfect instances (4 true positives, 14 false positives, 22 true
negatives, no misses), but 43 of the 54 legacy direct trials on flagged
instances had in fact produced feasible solutions. That is too much
opportunity cost for a stop/skip policy. The feature shortlist was fixed in
the analysis code after an earlier broad exploratory screen, so even this
family-held-out result is not an external validation; it is not a runtime
rule.

For **objective improvement after the first feasible solution**, a more
promising single feature was Osi's `rPacking` count. Improvement is
`(first-feasible objective - final objective)` in minimization orientation,
divided by the original objective-coefficient L1 norm (the objective offset
cancels); it is not a measure of finding a feasible solution. Across 37
instances with the needed outcomes, the mean improvement was 0.00435
(instance-cluster bootstrap 95% interval [0.00170, 0.00748]). `rPacking` had
exploratory Spearman rho +0.693. A full-cohort descriptive stump split at
1546.5 packing rows: the 8-instance upper leaf averaged 0.01734 improvement,
versus 0.000674 for the 29-instance lower leaf. In family-held-out stump
predictions, RMSE was 0.00715 versus 0.00960 for the family-mean baseline
(25.5% lower; family-cluster bootstrap interval for the paired RMSE difference
[-0.00457, -0.00133]); the stump selected `rPacking` in 8/9 outer families.
However, the upper leaf is mostly RMP instances (plus one NEOS case), the
feature shortlist followed broad screening, and no external instance-family
cohort was tested. Treat this as a specific candidate for confirmation, not
a universal cutoff or gate.

This separation matters: the mean normalized final-to-BKS residual was
0.000905 (37 instances; cluster 95% interval [0.000377, 0.001550]) and the
mean final-to-LP gap was 0.01815 ([0.00220, 0.03883]); neither a full-data
ranking nor the nested shallow trees showed a useful held-out predictor of
final BKS residual. The share of work after the last improving feasible
incumbent was about 49.7% on successful legacy runs, but the corresponding
family-held-out tree did not beat the family-mean baseline. This is an
ex-post work share, **not evidence that the work was wasted**. First-feasible
time on successful runs was 0.0204 s median / 1.60 s P90; counted work was
9.38 million median / 638 million P90.

The corrected-clock full-solver baseline has 84 runs (42 instances, two
seeds), mean PDI 0.4384 (instance-cluster interval [0.2697, 0.6357]), 43
confirmed optima, and 10 runs without an incumbent. There is no matched
SppGrasp-on/off comparison here, so these data cannot estimate the heuristic's
total solver benefit. The subsequent original-model study in
[Causal activation and fixed tuning](#causal-activation-and-fixed-tuning-2026-10-21)
adds that missing ON/OFF contrast; it is a separate cohort, not a relabelling
of these fixtures. Within this earlier cohort, the causal contrast is narrower: the 500M
after-cuts stall gate versus gate-off reduced mean PDI by 0.01303 on the
six-seed screen (36 instances; 95% interval [-0.01896, -0.00686]) and by
0.01239 on three fresh seeds of the same instances ([-0.01884, -0.00641]);
29 instances improved and 7 worsened in each cohort. This is the **marginal
gate effect only**, not the effect of SppGrasp itself. Osi-only family-held-out
trees did not yield a stable gate-benefit rule: the nested depth-2 selector
chose depth 2 in only 2/5 fresh-seed family folds, and its paired
RMSE-improvement interval over the stump included zero. Leave the gate
disabled by default.

**What the feature tables mean.** Current `OsiFeatures` defines 229 numeric
static matrix/bounds/objective features (`Osi/src/Osi/OsiFeatures.hpp:10-12`):
model size/density, variable types, row-class counts and nonzero summaries,
row/column degree distributions, and coefficient/objective/RHS summaries.
It does not compute LP solution/fractionality/reduced-cost or conflict-graph
features. In particular, Osi `rSingleton` counts rows with one nonzero
(`Osi/src/Osi/OsiFeatures.cpp:478-482`); it is **not** the count of partition
rows covered by degree-one columns. The original MIPLIB export used here has
only 207 numeric fields (208 columns including name, 403 rows), versus 229 in
the current enum; joins therefore use its existing schema and exact instance
names, never fill missing newer columns with zero. The 42 corrected-PDI and
40 direct instances all joined by exact name.

Several Osi fields were retained in the spreadsheet export but excluded from
associations after source inspection: `rPartPacking` is never incremented and
`rPercRowsPartPacking` consequently divides its zero value
(`Osi/src/Osi/OsiFeatures.cpp:549-558,704-706`); `rPercFlowBin` and
`rPercFlowMx` use their own zero percentage fields rather than the row counts
(`:719-720`); and `rPercKnapsack` is not assigned in that percentage block
(`:704-720`). The nonzero-based packing/partitioning counters are maintained
separately. Do not interpret these defective percentages as absence of those
structures. The regression self-test now includes a case where each equality
row has one coefficient but those variables also touch a packing row: it
verifies that row-only singletons do not count as native private singleton
coverage. Run it with
`python3 Cbc/test/spp-grasp-adaptive-features-selftest.py`.

No new feature-driven policy or default is recommended. The smallest next
experiment for a runtime decision is a matched solver-level SppGrasp
on/off/control run on a modest family-stratified holdout, reporting
feasibility, optimal proofs, PDI, and the feasible solutions that any
candidate skip would suppress separately. For `rPacking`, the first
confirmation should be a small new-family cohort rather than more seeds on
the same RMP-heavy instances.

A strict-prefix replay required a real-best progress event before it could
stop; runs with no real solution never fired. On legacy neighborhoods, a
250-million-work probe followed by one 250-million-work quiet window fired on
69/120 runs, saved 26.3% of total work on average, and worsened the weighted
final primal gap by 0.304 percentage points (instance/seed hierarchical
bootstrap 95% interval [0.140, 0.580]); it did not change the no-solution
count. Two quiet 250-million-work windows saved 13.4% but still worsened gap
by 0.102 points (95% interval [0.042, 0.188]). More conservative 500-million
work windows saved at most 6.3% for one quiet window, with a small but
positive gap penalty; two quiet windows saved only 0.2%. The mixed
neighborhood showed the same direction. These are offline replay results on
final primal gap, **not PDI**; they do not justify choosing a gate threshold.

The solver-level test then compared only `sppGraspRealStallWork=0` with
`250` (millions of work), keeping the legacy neighborhood controls fixed:
`destroyRows=5`, `stall=200`, `destroyGrow=0`, artificial penalty `1.1`,
related-row probability `0`, `sppGraspWork=1500`, and
`sppGraspNoImprove=1000`. Six fresh seeds (177--182) covered the same 36
instances, for 216 matched instance-seed pairs per arm. Each run used
`-threads 1`, a 120-second horizon, and a `progressCsv` event stream; PDI was
computed with `cbc_pdi.py --events csv`, not from final gap or the text log.
The gate-off and gate-on calls used the same frozen CBC binary
(`cbc-adaptive-gate-validated`, SHA-256
`596594561eba293df54fbc806cdd98b3bee9c136ab17a517bd37297d145cef63`).
All 432 solver exits and saved-solution validations succeeded, with no runner
hard kills.

| setting | mean PDI (lower is better) | proven optimal | no incumbent |
|---|---:|---:|---:|
| gate off (`0`) | 0.28890 | 118 / 216 | 5 / 216 |
| real-best stall gate (`250M`) | 0.25749 | 116 / 216 | 5 / 216 |

The paired PDI change was **−0.03140** (hierarchical seed-and-instance
bootstrap 95% interval **[−0.04077, −0.02165]**); all six seed-level means
favored the gate, and 160/216 paired runs had lower PDI (41 higher, 15 tied).
The gate also reduced mean logged SppGrasp time per solve from 5.78s to 2.44s,
while mean total solver wall time changed from 66.85s to 66.01s. These wall
times are secondary and more exposed to runtime noise than the event-based
PDI. The no-incumbent count was unchanged, but the gate found two fewer
proven optima; both losses were in the RMP family. Mean terminal primal-dual
gap among runs with an available value was also slightly worse (0.10942 to
0.11322), despite the lower PDI.
Family effects are descriptive: RMP/EIL/AIR/T17 means improved, while the
hard NEOS mean was effectively unchanged.

This is solver-level evidence for **testing the opt-in gate**, not a basis
for changing its default: the gate remains disabled (`0`) because the finite
cohort traded two optimal proofs and a small terminal-gap increase for lower
PDI. Exact run manifests, CSV events, logs, validator outputs, per-seed
tables, and the bootstrap analysis are in the session artifact directory
`files/adaptive-gating/full-cbc-pdi/`; the analysis forces CSV events and
retains no-incumbent and optimal counts separately. Do not interpret the
fixture replay's final-primal-gap penalty as a PDI result.

## Experimental root ordering with FPump

**SUPERSEDED HISTORICAL PDI RANKINGS:** all PDI values, PDI-derived
confidence intervals, first-incumbent timing claims, and no-incumbent-at-
horizon counts in the root-order, FPump-policy, full-sanity, and staged-
effort results below are withdrawn pending complete common-origin histories.
Several old “unconditional” FPump arms also invoked the heuristic but hit
its legacy solution-count guard before an LP solve; invocation alone was not
evidence of pump work. The new per-call LP/pass telemetry and explicit
experimental `LC` root placements are being used in the corrected rerun.
Terminal solve status, optimality/BKS cross-checks, saved-solution validity,
and final gaps remain endpoint evidence; they do not validate the old PDI
ranking.

The opt-in `-sppGraspRootSequence` parameter compares root calls without
changing the legacy default:

| value | root phase-1 order |
|---|---|
| `legacy` | Preserve the original-model SppGrasp call and existing FPump policy. |
| `spp-fpump` | SppGrasp, then attempt FPump improvement even when SppGrasp found an incumbent. |
| `spp-fpump-if-no-feasible` | SppGrasp, then FPump only when CBC has no accepted incumbent. |
| `fpump-spp` | FPump, then SppGrasp. |
| `fpump-spp-guide` | FPump, then SppGrasp with an optional fractional-value guide. |

An experimental ordering suppresses the separate original-model SppGrasp call
so it cannot run before the requested sequence. If FPump is explicitly off,
SppGrasp falls back to its original-model call instead of being suppressed.
The experimental `-sppGraspRootKeepOriginal on` override preserves that
original-model call before the ordered root calls; it defaults off and is
intended to separate the effect of replacing the original stage from the root
heuristic order itself.
The conditional SppGrasp-first mode checks CBC's actual `bestSolution()`
pointer before invoking FPump, so a MIP start or any other accepted incumbent
prevents the second call; an unsuccessful SppGrasp candidate does not. The
sequence is applied at both root
heuristic hooks (after preprocessing, and after root cuts); ordinary
constructive heuristics are excluded from the ordered phase, while the
existing improvement phase remains available. The conditional SppGrasp-first
test is based on incumbent availability rather than a proxy solution counter.
Explicit `-feas` settings are preserved; all modes remain opt-in.
In these experimental sequence modes, FPump is allowed at root hooks `L` and
`C` unless `-pumpRootPlaces` is explicitly set; its ordinary cutoff, time,
feasibility, and node safeguards still apply. Thus an incumbent no longer
triggers the legacy “solution-count” early return solely because it exists,
but a cutoff that proves there is no eligible improvement can still yield a
legitimate zero-work return. At log level 2, each root FPump invocation
reports whether an incumbent existed, LP solves, pump passes, improvement,
and any early-return reason; the sequence scheduler separately logs whether
it invoked or conditionally skipped FPump. This distinguishes an actual
improvement attempt from a scheduled call.

### Incumbent handling and fractional guidance

SppGrasp already consults `CbcModel::bestSolution()` in its heuristic entry
point, maps a present incumbent through `CbcSppGrasp::fromOriginal()` (which
handles complemented columns), and can pass the mapped vector to `run()` as an
initial candidate. The mapping is checked against the loaded SPP rows,
forced/restricted columns, and artificial columns before it is treated as a
real SPP starting solution. A stale or incompatible mapping is discarded
without charging the deterministic search-work counter. The regular construction
still runs first; the mapped incumbent can seed subsequent LNS only if it is
better than that construction. The CBC heuristic returns a solution only
when it strictly improves the supplied objective cutoff. This is an
improvement path, not a reason to skip SppGrasp.
The separate pre-preprocessing `CbcSolver::babRunSppGraspOriginal()` entry
also does not skip merely because a MIP start or another heuristic supplied an
incumbent: it initializes SppGrasp's objective cutoff from CBC and relies on
the same strict-improvement check before updating the saved solution. An
incompatible mapping is never passed as an SPP seed, but its existence does
not suppress the construction/LNS call.

FPump's failure-recovery path retains its best rounded attempt for
FeasibilityJump. In addition, when the explicit `fpump-spp-guide` mode is
active, FPump retains the *unrounded source LP point* that produced that
attempt, together with its integer-column map and fractionality score. This
extra full-column vector is captured only for that opt-in guide mode. After
FPump fails, the raw point may guide SppGrasp only when CBC has no genuine
incumbent and its recomputed sum-of-distance-to-integer (and fractional count)
matches the saved metadata and is strictly better than the captured root LP
on the same integer columns. The raw point is checked for dimensions, finite
values, bounds, unchanged integer-column map, and unchanged root bounds;
full-row feasibility is not assumed. Metadata disagreement rejects the
guide, with no fallback to the rounded attempt. The selected point is an
LP-value bias only: it is not passed as a feasible start, does not count as a
real solution, and never replaces LP reduced costs. SppGrasp uses a snapshot
of the original root LP and its matching reduced costs, not a solver pointer
potentially changed by a heuristic. A genuine CBC incumbent takes precedence
over the guide. FeasibilityJump's existing rounded-seed behavior is unchanged.

The root-order study compares the legacy combination, SppGrasp-only and
FPump-only controls, both SppGrasp-first modes, FPump-first with and without
the fractional guide, and the FPump-first/SppGrasp-incumbent-improvement
path. Results are reported separately for PDI, proof count, no-incumbent
count, final gap, and held-out instance names; these small fixture screens
are exploratory and do not establish a new default. See the session artifact
directory `files/adaptive-gating/root-guide/pdi-screen5/` for the frozen
binary provenance, exact manifests, logs, progress events, and solution
validation outputs. The comparison uses a 120-second global horizon with
matched seeds; paired instance-level variation and wall-clock noise remain
important limitations.

#### Focused 300-second endpoint follow-up

To check whether the proof/gap trade-off was only a 120-second cutoff effect,
legacy and conditional SppGrasp→FPump were rerun on `air04`, `t1717`, and
`t1722` at 300 seconds, with the same four paired seeds (211--214). All 24
CBC exits were zero and all saved solutions validated. The longer horizon
restored all four `air04` proofs in both arms (objective 56,137; zero final
gap), so the earlier 120-second `air04` proof losses were delayed proofs, not
persistent failures. `t1722` also favored the conditional arm in all four
seeds (mean terminal gap 0.20988 versus 0.24667). In contrast, `t1717` still
favored legacy in every seed: mean terminal gap 0.44321 versus 0.31238, with
legacy's incumbent/bound remaining substantially better. Across these three
selected instances, conditional mean PDI was 0.30184 versus 0.27122 for
legacy; this subset is diagnostic, not a representative aggregate.

The `t1717` seed-211 logs identify an important confound in the root-order
experiment. With the conditional root sequence, the separate original-model
SppGrasp call is suppressed; root SppGrasp found 263,165 and FPump was then
skipped because a genuine incumbent existed. In legacy mode, the original-
model call first found 311,824 and a later root SppGrasp call improved it to
196,966. Thus the persistent `t1717` loss is not evidence that the skipped
FPump harmed the result; the tested system-level ordering replaced a
productive original-model SppGrasp stage. A future causal comparison should
preserve that stage identically across arms before drawing conclusions about
heuristic order. The longer-horizon data therefore strengthens the
no-default-change conclusion rather than establishing a generally superior
root policy. Per-run PDI tables, logs, progress CSVs, and validations are in
`files/adaptive-gating/root-guide/pdi-endpoint-followup/`.

To isolate the original-stage confound, the additional opt-in
`-sppGraspRootKeepOriginal on` was tested on the same three instances and
seeds at 120 seconds, using one newly frozen binary for every arm. In this
selected 12-run-per-arm diagnostic, legacy had 4 proven optima and mean PDI
0.41886; conditional SppGrasp→FPump with the original call suppressed had
0/12 proofs and mean PDI 0.42450; preserving the original call with the
conditional sequence had 0/12 proofs and mean PDI 0.57899; preserving it with
unconditional FPump had 2/12 proofs and mean PDI 0.49943. All arms had zero
no-incumbent runs. This does not support promoting original-call preservation:
the added work and changed incumbent trajectory were harmful on this
small selected set, and unconditional FPump recovered only two of four
`air04` proofs. The parameter remains an explicit experimental diagnostic,
off by default; the focused solver-policy selftest checks that its original-
model SppGrasp call occurs before the ordered root sequence.

#### Fresh-seed confirmation and trade-offs

The conditional SppGrasp→FPump ordering was selected on the 36-instance
training cohort and then compared with legacy, unconditional SppGrasp→FPump,
and SppGrasp-only on all 42 instances with four fresh, paired seeds
(211--214): 672 runs total, 120-second horizon, one solver thread, identical
legacy SppGrasp neighborhood settings, and the adaptive stall gate disabled.
All 672 CBC exits were zero, all saved solutions passed `cbc_validate_sol`,
and there were no runner hard kills. PDI came from the CSV progress-event
stream; terminal gap is the final primal-dual gap, not a best-known-solution
gap.

| arm | mean PDI (lower is better) | proven optimal | no incumbent | mean terminal gap |
|---|---:|---:|---:|---:|
| legacy | 0.48664 | 80 / 168 | 22 / 168 | 0.33742 |
| SppGrasp→FPump | 0.45586 | 79 / 168 | 22 / 168 | 0.34504 |
| SppGrasp→FPump only without incumbent | 0.45584 | 79 / 168 | 22 / 168 | 0.34481 |
| SppGrasp-only | 0.48133 | 79 / 168 | 23 / 168 | 0.34945 |

For the preselected conditional ordering, the paired PDI change versus legacy
was `−0.03079` (hierarchical instance/seed bootstrap 95% interval
`[−0.04625, −0.01786]`); all four seed-level means favored it. The
RMP-balanced mean was 0.41896 versus 0.45103 for legacy (RMP means 0.16079
versus 0.20176; other-family means 0.67713 versus 0.70030). The six instances
not in the earlier root-order cohort (`ds`, `ds-big`, `irp`, `ivu06`,
`ivu06-big`, `ivu52`) had a mean paired PDI change of `−0.01368`, with a
hierarchical interval `[−0.03226, 0]`: only `ds` and `irp` improved; the
other four tied. This is useful instance-level holdout evidence, but not
evidence of a broad per-instance benefit.

The PDI improvement has a measurable endpoint trade-off: the conditional arm
had one fewer proven optimum overall, and its mean terminal gap was 0.00739
higher; runs with terminal gap above 0.5 were 28 versus 26. The paired proof
transitions were four losses on `air04` (one at each seed) and three gains
(one `eil33-2`, two `rmp09`); no-incumbent transitions were unchanged. The
unconditional and conditional orderings were practically indistinguishable
in this study. Conditional mode skipped 256 of 293 scheduled FPump calls, but
mean total solver wall time was 75.86 seconds versus 75.93 seconds for the
unconditional arm and 72.41 seconds for legacy, so this did not demonstrate
resource savings. The SppGrasp-only control was statistically inconclusive
and did not reproduce the combined ordering's PDI change.

These are system-level sequence comparisons: an active experimental sequence
suppresses the separate original-model SppGrasp call and substitutes its
ordered root phase; it is not a pure permutation of otherwise identical
heuristic invocations. The four held-out instances that tied and the
air04 proof losses argue against promoting the sequence or changing defaults.
At the time of this cohort, no gate-on full sanity suite or full sanity suite
with a non-legacy root sequence had been run; the later combined full-sanity
check is documented below. Keep the opt-in strategy experimental. Exact
commands, frozen binary provenance, per-instance/seed PDI tables, progress
CSVs, logs, and validator outputs are retained under
`files/adaptive-gating/root-guide/pdi-confirm1/`; the 42-instance two-seed
screen is under `pdi-screen5/`.

#### Fair root-order confirmation with original stage fixed

> **SUPERSEDED PDI:** The table below came from the earlier binary whose
> pre-root original-model incumbent events were absent and whose ordered FPump
> calls did not yet ensure inner LP work. Its PDI means, intervals, and
> no-incumbent-by-horizon counts are withdrawn. The saved-solution checks and
> endpoints describe that historical binary only; the corrected experiment
> immediately below is the relevant active-FPump comparison.

To remove the original-stage confound, the five root-order arms were rerun
with `-sppGraspRootKeepOriginal on` in every arm, one frozen binary, all 42
fixtures, paired seeds 221--222, one solver thread, and a common 120-second
horizon (420 runs). Every CBC process exited zero, and all 420 saved solutions
passed the validator. This is a fairer system-level contrast, not a new
instance holdout: all 42 fixtures had appeared in prior studies.

| arm | mean PDI | proven optimal | no incumbent | mean terminal gap |
|---|---:|---:|---:|---:|
| legacy, original stage preserved | 0.45522 | 43 / 84 | 10 / 84 | 0.31191 |
| SppGrasp→FPump, conditional | 0.49241 | 38 / 84 | 10 / 84 | 0.32239 |
| SppGrasp→FPump, unconditional | 0.49556 | 38 / 84 | 10 / 84 | 0.32302 |
| FPump→SppGrasp | 0.49181 | 38 / 84 | 10 / 84 | 0.32372 |
| FPump→SppGrasp, raw-source guide | 0.49054 | 38 / 84 | 10 / 84 | 0.32374 |

All four explicit sequence arms had five fewer proven optima (six losses,
one gain) with no change in no-incumbent count. Conditional SppGrasp→FPump
increased mean PDI by 0.03719 versus legacy (instance/seed bootstrap 95%
interval `[0.00259, 0.08799]`) and worsened mean terminal gap by 0.01048.
Unconditional and conditional SppGrasp-first behaved similarly. The raw
FPump guide was selected in 4/84 runs and used by SppGrasp once; no benefit
was established. In the conditional arm, the root scheduler invoked FPump
16 times and skipped 124 calls because an incumbent already existed.

An isolated exact-seed repeat of the legacy seed-221 control was run over all
42 fixtures. Status matched on 41/42 instances; the repeated run had one fewer
optimum. Median absolute PDI difference was 0.00446 (90th percentile 0.02519,
maximum 0.08324), while median absolute terminal-gap difference was zero.
This exposes nontrivial timing/PDI noise despite fixed seeds; two-seed root
comparisons are therefore directional evidence, not a promotion basis. The
full per-instance transitions, PDI events, logs, and validators are retained
under `files/adaptive-gating/root-guide/root-fair-confirm-221-222/` and
`duplicate-control-seed221/`.

#### Corrected common-origin root-order rerun with active FPump

The five matched arms were rerun after correcting the full-solve progress
clock and making explicit root-order modes use the `LC` FPump placement
unless `-pumpRootPlaces` is explicitly overridden. Every arm preserved the
original-model SppGrasp call (`-sppGraspRootKeepOriginal on`), used the same
42 instances, seeds 221--222, one CBC thread, and a 120-second horizon, and
shared the frozen binary
`8508a70c33cccb2b707c1db998d3310acb6f74075aa80d3defb80ba3069a53d0`.
All 420 validator checks passed: 366 integer solutions were feasible and
validated, and 54 fractional-relaxation-only outputs were correctly
classified as no incumbent. Of 420 runs, 380 have
final global-clock progress-CSV events; 350 also have genuine, positive-time
`SppGraspOriginal` incumbent events. Forty empty CSVs are the same four
instances per seed across the five arms (`ds-big`, `ivu06`, `ivu06-big`,
`ivu52`): CBC stopped in the initial LP relaxation, the logs and validator
confirm no integer-feasible solution and no accepted original-stage/MIP-start
incumbent, and branch-and-bound never opened a progress stream. Those forty
cases are explicitly labeled timestamped-log fallbacks; their PDI is exactly
2.0 for the full horizon because no incumbent exists at any time. No
timestamp-zero or fabricated CSV event was inserted. The analysis records
380 CSV histories plus 40 exact no-incumbent fallbacks, with 84 PDI rows per
arm.

| root-order arm | mean PDI ↓ | RMP-balanced PDI ↓ | proved optimal | no incumbent by 120s | mean terminal gap | p90 terminal gap |
|---|---:|---:|---:|---:|---:|---:|
| legacy, original stage preserved | 0.43839 | 0.40529 | 43 / 84 | 10 / 84 | 0.31255 | 2.0 |
| SppGrasp→FPump, unconditional | 0.62807 | 0.60898 | 40 / 84 | 11 / 84 | 0.42450 | 2.0 |
| SppGrasp→FPump, conditional | 0.47507 | 0.43850 | 37 / 84 | 11 / 84 | 0.34639 | 2.0 |
| FPump→SppGrasp | 0.63652 | 0.61880 | 39 / 84 | 11 / 84 | 0.43701 | 2.0 |
| FPump→SppGrasp, raw-source guide | 0.63530 | 0.61758 | 39 / 84 | 11 / 84 | 0.43742 | 2.0 |

Relative to legacy, paired mean PDI deltas were `+0.18968`
(`[+0.11056, +0.27816]` 95% instance-cluster interval) for unconditional
SppGrasp→FPump, `+0.03668` (`[+0.00032, +0.09768]`) for conditional
SppGrasp→FPump, `+0.19813` (`[+0.11795, +0.28663]`) for FPump→SppGrasp, and
`+0.19691` (`[+0.11705, +0.28501]`) for the raw-source-guide variant. The
RMP-balanced deltas were respectively `+0.20369`, `+0.03321`, `+0.21352`,
and `+0.21230`; their RMP-balanced 95% instance-cluster intervals were
`[+0.12611, +0.29017]`, `[+0.00016, +0.08602]`,
`[+0.13684, +0.29867]`, and `[+0.13587, +0.29708]`. All four sequence arms
lost proven-optimal endpoints (net losses of 3, 6, 4, and 4). None reduced
the no-incumbent count. Paired PDI improved/worsened/tied on 8/66/10 runs for
unconditional SppGrasp→FPump, 44/30/10 for conditional SppGrasp→FPump,
10/64/10 for FPump→SppGrasp, and 11/63/10 for the raw-guide variant. On this
matched cohort, none of the tested orderings is a PDI/proof improvement;
keep the legacy default and do not promote these explicit sequences.

The unconditional arm did do the requested FPump work, so its poor outcome
cannot be attributed to the prior solution-count early return: it recorded
152 root invocations, 4,984 LP solves, 4,250 pump passes, and 39 calls that
improved the incumbent. Legacy recorded 108 root invocations, of which 66
incumbent-present calls returned under the legacy guard, plus 746 LP solves,
608 passes, and 3 improving calls. Conditional scheduling recorded 60
invocations, 1,361 LP solves, 1,140 passes, and 9 improving calls; it skipped
124 scheduled calls because an incumbent was present. Thus actual execution
was verified, but extra pump effort worsened this cohort's PDI and proof
retention. Full paired tables, raw CSVs, logs, validators, source-exception
counts, and binary/manifest hashes are in
`files/adaptive-gating/pdi-correction/root-order-globalclock-active-20261021/analysis.json`.

#### Historical full-sanity check of the gated root sequence (PDI superseded)

> **PDI WITHDRAWN:** the progress traces in this older full-sanity experiment
> omit original-stage incumbents and cannot support the PDI/no-incumbent
> ranking below. Its validated solutions, terminal statuses/proof counts, and
> final primal-dual gaps remain endpoint evidence for this historical binary.

The paired full-sanity check used the same frozen CBC binary
(`4186855ad87aa6823eb50db517a5555b179f244ba1f1a62ff012c7bd98f89760`) and
all 511 mip-sanity instances. Both arms kept the original-model SppGrasp call,
`-feas on`, `-sppGraspFpump auto`, and the same SppGrasp neighborhood,
500-million maximum work, and no-improvement limit. The control used legacy
root scheduling with the real-stall gate off; the experimental arm used
unconditional SppGrasp→FPump root scheduling and the 250-million-work
real-stall gate. Thus this is an end-to-end check of the combined opt-in
configuration, not a causal estimate that separates root order from the
gate. The earlier five-arm root-order confirmation compared orderings with
the gate off.

All 511 main-suite statuses and saved-solution validations passed in each
arm. At the common 120-second PDI horizon, 509 matched progress traces were
available (the same two presolve-infeasible cases lack traces in both arms).
The control had mean PDI 0.190435, 344 proven optima, 13 runs without an
incumbent by the PDI horizon, and mean terminal gap 0.14116. The experimental
arm had mean PDI 0.190704, 343 proven optima, 15 without an incumbent by that
horizon, and mean terminal gap 0.14473. The paired mean PDI delta was
`+0.000268` (candidate minus control): 243 pairs improved, 231 worsened, and
35 tied. CBC's result-table comparison identified one proof/gap regression
(`nw04`, optimal to a 2.9175% gap) and two gap improvements (`air04`,
`air05`). The experimental arm therefore did not improve aggregate PDI and
lost one proof in this run.

The no-incumbent figure above is specifically **within the 120-second PDI
horizon**, not a count of final infeasible/no-solution runs. Both arms ended
with no integer-feasible solution for the same 11 instances; both also
validated the same two infeasible cases. The two additional candidate
no-incumbent-by-120 events (`neos-3226448-wkra` and `snp-02-004-104`) later
produced validated solutions in the full runs. The candidate had 93 runs
with terminal gap above 0.1 in each arm and 51 versus 50 above 0.5.

An RMP-first descriptive split gives mixed evidence: among the 10 `rmp*`
traces, mean PDI changed from 0.05476 to 0.05215 with all 10 proven optimal
in both arms; among the other 499 traces, it changed from 0.19315 to 0.19348,
with proofs changing from 334 to 333 and mean terminal gap from 0.14399 to
0.14763. Giving the RMP group and all other instances equal weight yields
0.12396 versus 0.12281, but that aggregate improvement is driven by the
small RMP subset and does not erase the full-suite PDI/proof result.

A separate full log-level-2 repeat confirmed that the opt-in sequence and
gate were actually active; its performance values are not used for the paired
PDI comparison. Root scheduling appeared on 20 SppGrasp-applicable instances
and logged 39 SppGrasp plus 39 FPump calls across the root phases. FPump was
called with an incumbent 34 times and returned immediately each time; five
calls had no incumbent, of which three took measurable time (0.051, 0.521,
and 111.850 seconds). The 111.850-second call on `neos-3226448-wkra` found
the zero-objective solution. The real-stall gate logged 26 root-call stops
and 10 original-model stops. All 511 results in that diagnostic repeat also
passed validation; it reproduced the candidate's 343-optimum count, the
`nw04` proof loss, and the same 11 final no-integer-solution instances.

The full sanity runner itself exited nonzero in both paired arms because the
lazy-constraint/TSP test had the same 94 pre-existing failing assertions;
no other inspected auxiliary test failed. This is not a clean full-suite
green, and the combined candidate is not a promotion: keep the gate and
experimental root ordering opt-in, with defaults unchanged. The corrected
paired analysis, result tables, solver logs, diagnostic repeat, and
provenance are retained under
`files/adaptive-gating/root-guide/full-sanity-root-active-unconditional500m-stall250m/`.

#### Joint work/stall effort screen and instance holdout

Before the full-sanity check, the opt-in unconditional SppGrasp→FPump
configuration was screened jointly at 500M maximum SppGrasp work and a 250M
real-best stall budget, with the original-model SppGrasp call preserved in
every arm. The 12-instance training cohort (seeds 231--232) was used for
effort-setting selection; its fixtures had appeared in earlier root-order
work. The predeclared 30-instance holdout (seeds 241--242) was disjoint by
instance from that effort-setting screen, but these instances were not
previously unseen in the broader SppGrasp/root-order study. All runs used the
same frozen binary, single-threaded CBC, 120-second PDI horizon, and matched
solver settings; all 216 training and 300 holdout solver exits and saved
solutions were validated.

| cohort and setting | instances × seeds | mean PDI | optima | no incumbent by 120s | mean terminal gap |
|---|---:|---:|---:|---:|---:|
| training, legacy 1500M / no gate | 12 × 2 | 0.55491 | 14 / 24 | 4 / 24 | 0.39749 |
| training, selected 500M / 250M gate | 12 × 2 | 0.52534 | 13 / 24 | 4 / 24 | 0.41897 |
| holdout, legacy 1500M / no gate | 30 × 2 | 0.45800 | 26 / 60 | 6 / 60 | 0.27868 |
| holdout, 500M / 250M gate | 30 × 2 | 0.41701 | 26 / 60 | 6 / 60 | 0.29253 |

On the effort-screen training cohort, the selected setting lowered mean PDI by
0.02957 versus legacy; the paired instance-bootstrap 95% interval was
`[−0.07770, 0.00593]`. It lost one proof on `air04` in this screen and
increased mean terminal gap by 0.02149. On the disjoint-by-instance effort
holdout, it lowered mean PDI by 0.04099 versus legacy (paired hierarchical
bootstrap 95% interval `[−0.06163, −0.02165]`) with the same proven-optimal
and no-incumbent-by-120s counts, but mean terminal gap increased by 0.01384
and runs with terminal gap above 0.1 increased from 19 to 24. Relative to
matched SppGrasp→FPump sequence-only references, the selected setting
improved mean PDI on both cohorts; however, those sequence-reference arms
were not the legacy baseline. The training and holdout results therefore
support a PDI-versus-endpoint trade-off, not a regression-free setting. The
subsequent full-sanity comparison did not confirm an overall PDI/proof
advantage. Keep the work/stall configuration experimental and disabled by
default. Consolidated paired tables and confidence intervals are in
`files/adaptive-gating/root-guide/effort-screen-231-232/effort-screen-holdout-consolidated.json`.

#### Bounded `nw04` proof-loss factor isolation

The full-sanity comparison's `nw04` proof loss is real in that paired run:
legacy found objective 16,862 at 2.987 seconds and proved it at 4.08 seconds;
the candidate first found 17,288 at 2.251 seconds, reached 16,862 at
12.813 seconds, and stopped at the configured node limit with a 2.91748%
gap (276 reported nodes). The log-level-2 diagnostic repeat reproduced this
result. All saved solutions validated; this was delayed proof, not loss of
feasibility.

To separate work, stall, and root ordering, a 2×2 run fixed the original-
model SppGrasp call, `-feas on`, the neighborhood and 500M maximum work, and
varied legacy versus SppGrasp→FPump root scheduling and a 0 versus 250M
real-stall gate. Five selected cases (`nw04`, `air04`, `t1717`,
`neos-3226448-wkra`, and `snp-02-004-104`) used their full-sanity time/node
limits. A legacy 1500M/no-gate arm isolated the maximum-work setting. All 25
no-explicit-seed runs validated. A separate 80-run, three-seed factor study
also validated all runs; every `nw04` run in its five arms proved the optimum.
The full-sanity proof loss therefore did not reproduce consistently across
these bounded replays, and the screen does not establish that the gate,
500M budget, or root sequence alone caused it.

The per-case contrast is more informative than pooling the different
horizons. In the default-RNG 2×2, `t1717` legacy versus SppGrasp→FPump PDI
was 0.4091 versus 0.6108 with the gate off, and 0.4049 versus 0.6079 with
the 250M gate; terminal gap changed from about 0.325 to 0.557 in both
comparisons. All arms proved `nw04` (objective 16,862); its PDI was 0.0306
for legacy 500M/no gate and 0.0236 with the gate, versus 0.0299 and 0.0246
for the corresponding ordered-root arms. The added legacy 1500M arm also
proved `nw04` but had PDI 0.0642 in that run. `air04`, the two difficult
no-incumbent-horizon cases, and the complete per-instance/seed results are
in `files/adaptive-gating/root-guide/nw04-causal-defaultseed-20261021/` and
`nw04-causal-20261021/`.

An isolated same-seed control repeated five legacy cases twice, serially
with no other experiment running. All ten solutions validated; status,
objective, and terminal gap agreed on every pair. Mean absolute PDI
difference was 0.00072 (maximum 0.00259). This small control shows that the
full-sanity proof loss is not explained by ordinary PDI timing noise on
these five cases, but it does not identify the solver-path cause. Do not
infer a universal gate or work-budget rule from these selected runs.

#### FPump effort when a SppGrasp incumbent exists

The ordinary unconditional root schedule can invoke FPump yet return
immediately when an incumbent already exists; invocation is not evidence
that the pump did work. A matched 18-run follow-up on `nw04`, `air04`, and
`t1717` (three seeds, one thread) set `-pumpRootPlaces L` to explicitly
allow FPump at the pre-cut root hook. This safely overrides the legacy
placement decision; it does not bypass FPump's normal solution/cutoff
checks. All saved solutions validated.

| instance | conditional PDI / optima | unconditional PDI / optima | mean final objective, conditional → unconditional | actual FPump seconds, conditional → unconditional |
|---|---:|---:|---:|---:|
| `nw04` | 0.02295 / 3 of 3 | 0.02492 / 3 of 3 | 16,862 → 16,862 | 0.107 → 0.801 |
| `air04` | 0.08203 / 0 of 3 | 0.06650 / 0 of 3 | 56,529 → 56,369 | 0 → 25.273 |
| `t1717` | 0.61051 / 0 of 3 | 0.86457 / 0 of 3 | 291,519 → 226,666 | 0 → 241.598 |

With an incumbent, the conditional strategy skipped FPump; it ran once
(0.107 seconds) when no incumbent existed and found no solution. The
unconditional strategy did substantive work: it sometimes improved the
incumbent, including `t1717` seeds 272–273, but spent 62–115 seconds per
run there and had worse finite-horizon PDI on `t1717`. The `air04` endpoint
also varied by seed. Thus explicit unconditional FPump can help an endpoint
on some runs, but these results do not establish a general PDI or proof
benefit; keep the ordering and root-placement override experimental.
Exact logs, progress CSVs, validation, and per-seed comparisons are retained
under `files/adaptive-gating/root-guide/pump-rootplaces-L-20261021/`.

#### Existing-incumbent handling audit

No incumbent-handling fix was needed. The original-model entry point
`CbcSolver::babRunSppGraspOriginal()` does not skip merely because a CBC
incumbent exists: it calls the heuristic with the current cutoff and only
updates the model if SppGrasp returns a qualifying improvement. In
`CbcHeuristicSppGrasp::solution()`, a present incumbent is mapped into the
active SPP model and accepted as an LNS starting solution only when its
mapped objective is finite, it uses no artificial rows, and the mapping is
valid. A rejected mapping is cleared, not treated as a real solution; the
heuristic continues searching. The returned vector is still required to
strictly improve the supplied cutoff. Experimental root-sequence policy
can intentionally suppress the separate original-model call unless
`-sppGraspRootKeepOriginal on` is selected; that is a scheduling choice,
not an incumbent-based skip. The raw FPump point remains a soft LP-value
guide only when no genuine incumbent exists, as described above.

#### Experimental staged SppGrasp effort allocation

`-sppGraspRootSequence spp-fpump-staged` is an opt-in policy for testing a
short original-model SppGrasp pass followed by root processing and one
post-cuts SppGrasp call. `-sppGraspStageFirstPercent` (1–99, default 25)
allocates that percentage of the positive `-sppGraspWork` budget to the first
pass. The remaining budget is computed from actual counted work and offered
to the post-cuts call; that pass is not repeated on a later root hook. A zero
or unlimited `sppGraspWork` cannot be split and therefore falls back to legacy
heuristic scheduling. The configured FPump root hooks and global CBC time/node
limits are not changed by this mode.

Two explicit controls use the same hard aggregate work accounting without a
post-cuts SppGrasp call: `spp-fpump-upfront` assigns the full budget to the
original-model pass, while `spp-fpump-short` assigns only the configured
first-pass share. These make it possible to compare staged effort against
same-total upfront and short-only effort without counting multiple full
per-call `maxWork` allowances as one budget. All three effort policies retain
the original-model call and leave FPump scheduling and global limits
unchanged.

The staged calls use a hard aggregate work limit across artificial-penalty
rounds, rather than the ordinary per-round `maxWork` behavior. As with other
SppGrasp work stops, one in-progress LNS iteration can cross the threshold;
the actual work is recorded and subtracted before the second pass. Root
processing can prove the model, hit a global limit, or find no feasible root
LP before the post-cuts hook, in which case no second pass runs. An existing
CBC incumbent is used as an SppGrasp start only if it maps to a real,
artificial-free SPP solution on the active root model. An incompatible mapping
is rejected; the current root LP may guide the search instead, and no invalid
candidate is returned as a CBC incumbent.

The focused checks are:

```sh
python3 Cbc/test/spp-grasp-staged-effort-selftest.py \
  --cbc Cbc/src/cbc --baseline /path/to/frozen-legacy-cbc
python3 Cbc/test/spp-grasp-staged-effort-selftest.py \
  --cbc Cbc/src/cbc --air04
```

The second command also runs a bounded air04 root integration check. In a
single-seed pilot (`randomSeed=randomCbcSeed=271`, 30-second horizon,
`maxNodes=1`, 500M total work), the 25/75 split recorded about 125.04M work
in the original pass and 375.07M after cuts. The second-stage incumbent did
not map to the active SPP model, so it was rejected; this arm returned a
validated objective of 58,639 at a 5.10% terminal gap. A matched 75/25
single-seed screen on air04 (`maxNodes=50`) recorded 375.18M + 124.93M work.
Its post-cuts SppGrasp candidate did not improve the validated incumbent.
At a common 30-second PDI horizon, staged PDI was 0.5005 versus 0.2591 for
legacy scheduling; both had no proof/no-incumbent event and final gaps of
0.0088 versus 0.0086. The staged arm found its first incumbent at 7.39s,
versus 3.68s for legacy.

A corrected-order screen then compared the four policies on air03, air04,
nw04, and rmp10, with seeds 271–273, one CBC thread, a common 30-second
horizon, the per-instance node limits from `mip-sanity-data/limits.tsv`, and
the same FPump settings. `t1717` is not present in the checked-in fixture
dataset, so air03 was used as the small air-class reference instead. PDI was
computed from each run's `-progressCsv` events with `cbc_pdi.py --events csv
--sec 30`; all 48 saved solutions passed `cbc_validate_sol`, and all 35 CBC
optimality claims also matched `bks.tsv` within its configured tolerance.

| policy (12 runs) | mean PDI ↓ | optimal | no incumbent | mean terminal gap | worst terminal gap |
|---|---:|---:|---:|---:|---:|
| legacy | 0.3367 | 9/12 | 0 | 0.401% | 1.964% |
| staged 75/25 | 0.4902 | 9/12 | 0 | 0.458% | 3.516% |
| upfront full-work | 0.4037 | 9/12 | 0 | 0.237% | 1.028% |
| short-only 75% | 0.3715 | 8/12 | 0 | 0.496% | 2.905% |

Paired mean PDI deltas versus legacy were +0.1535 for staged (approximate
95% t interval [-0.0467, 0.3538]), +0.0670 for upfront ([-0.1241, 0.2581]),
and +0.0348 for short-only ([-0.1379, 0.2075]); these 12 paired instance/seed
observations are a small, non-independent screen, not a significance claim.
All policies proved all three nw04 seeds except short-only, which stopped on
the node limit once despite finding the BKS incumbent. Staged also had the
largest air04 PDI and the worst terminal-gap tail. Upfront had the best mean
terminal gap and preserved the legacy proof count, but not the mean PDI.
Thus none dominates across PDI, proof count, and final-gap tails; staged
effort is not promoted, and defaults remain unchanged.

The reported PDI is specifically the progress-CSV event integral: CBC does
not emit the original-model SppGrasp incumbent as a progress event before the
root callbacks begin, so this measure omits that initial incumbent even
though it is retained in the model. Interpret it as a common-source
progress-event comparison, not a complete primal history. Aggregate work was
counted deterministically: staged used 5.763B of 6.0B allocated work across
12 runs (stage 2 ran 10 times); upfront used 6.088B of 6.0B and short-only
4.590B of 4.5B, with small one-iteration boundary overshoots. Legacy made 34
logged SppGrasp calls across the same 12 runs; its `maxWork` remains
per-call/per-penalty-round rather than a comparable aggregate cap.

This was a screening set only—no independent holdout and no full 511-instance
sanity rerun were performed. Keep all effort policies experimental. Run logs,
progress traces, validation results, and binary provenance are retained in
the session staged-effort artifacts.

## Corrected common-origin PDI evidence (2026-10-21)

The historical PDI rankings above remain withdrawn. The numbers below come
from corrected reruns, not from reconstructing missing historical events.
The global progress clock starts on the persistent CBC model before the
original-model SppGrasp call and root processing; accepted pre-root incumbents
are emitted at their genuine global times. PDI uses each progress CSV's
global `final` event for its terminal time, primal, and dual. Empty histories
are treated as PDI 2 only when the timestamped log verifies that no incumbent
was ever found. A nonempty CSV without a `final` row falls back to the
timestamped log with an explicit incomplete-source label; a proof without a
known positive time (including a rounded-zero timestamp) is not assigned a
fabricated time-zero event, and its PDI is left unavailable. A
proven-infeasible run with a known proof time integrates gap 2
until that proof, then gap 0, without inventing a primal. The corrected
comparison horizons are 120 seconds; bootstrap
intervals are clustered by instance, not by treating repeated seeds as
independent instances. The audit of every superseded study and its
replacement status is retained in
`files/adaptive-gating/pdi-correction/historical-pdi-audit.json`.

| corrected comparison | paired PDI delta (candidate − reference), 95% interval | endpoint evidence | decision |
|---|---:|---|---|
| Mixed neighborhood vs current default, initial screen | −0.02486 [−0.03688, −0.01330] | 36 fixtures, 3 seeds; no proof or no-incumbent change | Favorable screen |
| Mixed neighborhood, fresh-seed repeat | −0.02742 [−0.03713, −0.01850] | Same 36 fixtures as the initial screen, seeds 114–116 rather than 111–113; both arms 64/108 optima and 2/108 no-incumbents | Fresh-seed replication only, not a by-instance holdout |
| Mixed neighborhood, six out-of-cohort fixtures | −0.00113 [−0.00352, +0.00049] | `ds`, `ds-big`, `irp`, `ivu06`, `ivu06-big`, `ivu52`; seeds 187–189; both arms 3/18 optima and 12/18 no-incumbents | No material difference on this small extension |
| Real-best stall gate, 250M work | −0.02222 [−0.03075, −0.01330] | 36 fixtures, 6 seeds; gate loses 2 optima and raises mean terminal gap by 0.00365; no-incumbent counts equal | Do not promote |
| Real-best stall gate, 500M work — screen | −0.01303 [−0.01909, −0.00704] | 36 fixtures, 6 seeds; 120 vs 118 optima (2 gains, no losses), equal no-incumbent count, slightly lower mean terminal gap | Promising screen |
| Real-best stall gate, 500M work — fresh-seed holdout | −0.01239 [−0.01859, −0.00651] | Same 36 fixtures, seeds 186–188; both arms 62/108 optima and 2/108 no-incumbents; mean/p90 terminal gap slightly worse with gate | Confirms PDI tradeoff, not a regression-free promotion |
| Staged vs same-total upfront SppGrasp work | +0.00748 [−0.00672, +0.03472] | 4 fixtures, 3 seeds; both 9/12 optima and no no-incumbents | No staging benefit established |
| `sppGraspFpump after` vs keep FPump, no explicit `-feas` override | +0.00157 [−0.00084, +0.00398] | 10 fixtures, 2 seeds; both 11 optima and 1 no-incumbent; both did 198 LP solves, 167 passes, and 4 improvements | Near-neutral; policy only saves redundant calls after accepted original-stage SppGrasp |
| SppGrasp→FPump unconditional vs legacy-preserved root order | +0.18968 [+0.11056, +0.27816] | 42 fixtures, 2 seeds; 40 vs 43 optima and 11 vs 10 no-incumbents; FPump performed 4,984 LP solves, 4,250 passes, and 39 improving calls | Reject this ordering; substantive pump execution did not improve PDI or proof retention |

The mixed-neighborhood cohort previously called a “holdout” used the exact
same 36 fixtures as the initial screen; only the seeds were fresh. It is a
seed-based replication, not by-instance validation. A separate extension
used six fixtures absent from both mixed-neighborhood cohorts (`ds`,
`ds-big`, `irp`, `ivu06`, `ivu06-big`, `ivu52`), with three paired seeds.
This extension was nearly tied and small; it does not independently confirm
a broad mixed-neighborhood advantage.

The 500M gate screen's initial “holdout” label was incorrect: seeds 183–184
had already appeared in the historical threshold screen, even though those
old PDI values are invalid. Its corrected 183–185 rerun is therefore a
replication, not an independent holdout. The replication was directionally
consistent: gate-500M minus gate-off PDI was −0.01259
([−0.01854, −0.00679]), with one optimum gained, none lost, and equal
no-incumbent counts. The separate 186–188 cohort, unused in earlier gate
screens, confirmed the PDI direction on the same 36 fixtures, not on a
by-instance holdout: both arms proved 62/108 and had 2/108 no-incumbents,
while the gate's mean terminal gap was 0.09814 versus 0.09742 and p90 was
0.24884 versus 0.22222. Thus gate 500M is a reproducible PDI/endpoint
tradeoff, not a regression-free setting. A 36-run extension on the six other
SppGrasp fixtures absent from the gate-threshold screens was directionally
consistent (PDI delta −0.00870, 95% instance-cluster interval
[−0.02520, 0.00000]),
but descriptive only: both arms proved 3/18, had 12/18 no-incumbents, and
12/18 paired PDI values tied. Their mean terminal gaps were essentially
unchanged (1.48578 gate versus 1.48544 control). Across the new-seed holdout
and extension there was no proof/no-incumbent improvement; do not promote the
gate on PDI alone.

A repeated seed-221 legacy control also quantifies run-to-run timing
variation: the 42-instance repeat had a PDI delta of −0.00407
([−0.00756, −0.00125]) versus the preserved same-binary/settings/seed
baseline, with 25 pairs improving, 12 worsening, and 5 tied; one proven
optimum was lost and none gained. This is not a correction factor, but it
shows why the fresh gate holdout and its endpoint/proof evidence matter even
when paired bootstrap intervals are reported. Other tested root orderings
were also worse than legacy; the full arm-by-arm results are in the session
audit.

These SPP fixture studies do not justify changing solver defaults. The
earlier full-sanity integration run did include SppGrasp calls in artificial-
slack mode, but its PDI history is withdrawn because the progress stream did
not include the accepted original-stage incumbents. Its 511 endpoint rows
and the 94 known lazy-constraint/TSP assertion failures are kept separate
from the focused fixture PDI comparisons. All policy flags remain
explicit/experimental, and no solver defaults were changed.

The current in-tree binary (`8508a70c33cc`) was also run with no experimental
SppGrasp policy overrides through the full 511-instance sanity harness:
511/511 saved-solution/status rows passed, with 344 proven optima and no
main-suite failures, overtimes, or errors. The harness still exits nonzero
because the lazy-constraint/TSP checks have 94 failures (119/213 checks
passed); their exact failure assertions match the retained earlier full-suite
logs. The other auxiliary tests passed: C API 9/9, LP relaxation 64/64,
MIP-start 198/198, coefficient tightening 80/80, row activity 34/34, final
search-bound, and progress-callback tests. Full logs and results are in
`files/adaptive-gating/pdi-correction/full-sanity-current-binary-20261021/`.

## Causal activation and fixed tuning (2026-10-21)

**Outcome:** the mixed neighborhood remains a useful explicit tuning candidate,
but no feature-based `auto` activation rule is supported. It lowered PDI
without losing proven optima or incumbents in this study; it did **not**
increase the optimal-solve count. The paired full sanity suite also exposes
three wider terminal gaps, so this is not a performance-regression-free
promotion. Defaults and explicit ON/OFF semantics
remain unchanged. In particular, “native private coverage is incomplete” is
not a safe reason to disable the heuristic.

### Matched original-model experiment

This study loads all 42 matching **original** MPS files from
`/home/haroldo/inst/miplib/2017+spp`, rather than either root-fixture collection.
It uses the rebuilt, frozen in-tree binary `8508a70c33cc`, seeds 301/302
for both CBC random generators, one CBC thread, a common 120-second horizon,
and the corrected complete global progress history. Four arms were
interleaved at 32 concurrent runs. There were 336 primary runs plus seven
default duplicates; all saved solutions were validated against the original
model and the existing reference objective/status, with fractional
relaxations never counted as integer incumbents.

| Arm | Mean PDI | Optimal by 120 s / 84 | No incumbent by 120 s / 84 |
|---|---:|---:|---:|
| Current default SppGrasp / FPump auto | 0.474836 | 40 | 12 |
| Legacy SppGrasp ON / explicit FPump ON | 0.476477 | 40 | 12 |
| Mixed SppGrasp ON / explicit FPump ON | 0.454224 | 40 | 12 |
| SppGrasp OFF / explicit FPump ON | 0.684356 | 41 | 14 |

OFF disables **both** original and root SppGrasp entry points. The isolated
legacy-ON versus OFF contrast pins the same FPump enabled configuration and
leaves the other heuristic settings unchanged: PDI delta −0.207879,
instance-cluster 95% interval [−0.338474, −0.084289]. Its family-cluster
interval [−0.321647, +0.007032] crosses zero, warning against generalizing
this small, family-correlated sample. ON gained three incumbent opportunities
(`rmp13` once, `rmp18` twice), but lost one incumbent/proof opportunity
(`neos-1440225`, seed 302); thus its better average PDI is **not** a
proof-count improvement.

Pinning FPump enabled does not force equal FPump inner work: an incumbent
from SppGrasp can trigger FPump's existing solution-count guard. This is an
actual treatment mechanism, not a reason to force an experimental root
ordering. The default and pinned-legacy arms both performed 731 FPump LP
solves / 593 passes, despite different invocation counts; OFF performed
3,547 / 2,860, and mixed 700 / 570. No forced LC-pump placement was used.
The original-stage accepted progress event appeared in 70/84 runs in each
ON arm and never in OFF. Logged aggregate SppGrasp time was 542.44 seconds
for default, 552.91 for pinned legacy, and 346.17 for mixed; counted LNS
iterations were 308,760, 308,752, and 304,515 respectively. These are logged
wall times and iterations, **not deterministic work units**.

### Fixed tuning and held-out confirmation

The mixed setting changes only the previously promising neighborhood controls
relative to pinned legacy: destroy rows 5 → 2, growth probability 0 → 0.1,
stall iterations 200 → 0, and artificial penalty 1.1 → 2. It leaves related
rows, real-best stall gating, SA, backtracking, and root reordering disabled.
The exact explicit research configuration is:

```sh
cbc model.mps.gz -threads 1 -sec 120 \
  -randomSeed 303 -randomCbcSeed 303 -preprocess sos \
  -sppGrasp on -sppGraspFpump on -feas on \
  -sppGraspRootSequence legacy -sppGraspWork 1500 -sppGraspNoImprove 1000 \
  -sppGraspDestroyRows 2 -sppGraspDestroyGrow 0.1 \
  -sppGraspStall 0 -sppGraspArtificial 2 \
  -sppGraspRelatedRows 0 -sppGraspRealStallWork 0 -solve
```

A 28-instance training / 14-instance causal-label holdout split was recorded
before collecting these new outcomes. All 42 names had appeared in earlier
studies, so this is **not an external unseen-instance validation**.
Constant mixed was locked using the training subset after the learned
policies failed training-family-held-out guardrails:

| Paired mixed − default comparison | Mean PDI, default → mixed | Delta, instance-cluster 95% interval | Optimal / no incumbent, each arm |
|---|---:|---:|---:|
| Training 28, seeds 301/302 | 0.465233 → 0.448314 | −0.016919 [−0.030175, −0.005655] | 32 / 8 of 56 |
| Causal-label holdout 14, seeds 301/302 | 0.494043 → 0.466043 | −0.027999 [−0.043911, −0.013536] | 8 / 4 of 28 |
| Same holdout 14, fresh seeds 303/304 | 0.480490 → 0.455646 | −0.024845 [−0.038164, −0.011826] | 8 / 4 of 28 |

The fresh-seed confirmation has family-cluster interval
[−0.035635, −0.008335], ten improved and two worsened instance-mean PDIs,
and no paired proof/incumbent transitions. It comprised 56 primary runs and
four identical default duplicates. Their mean absolute PDI difference was
0.01139; this timing variation is a limitation, not a correction to subtract.
The screen's comparable-load duplicate mean absolute difference was 0.00612.
Its `rmp01` duplicate is excluded from that comparable-load summary because
the primary was an initial four-job smoke test whereas the duplicate ran
in the 32-job batch.

Across all 42 originals in the screen, mixed's PDI delta was −0.020612
([−0.030651, −0.011456]; family-cluster [−0.038495, −0.009454]).
Mean terminal gap was essentially unchanged (0.35978 versus 0.36019), and
both P90 gaps were 2 because the statistic includes no-incumbent runs.
This supports the bounded PDI claim, not an assertion of better endpoints
or universally better instance performance.

### Why not a one-feature AUTO rule?

The training-only policy search considered five cheap original-stage
features: forced-free full native private coverage, packing-row count and
fraction, real row-option lower quartile, and mean column degree. No names,
families, BKS, final objectives, or unavailable LP values were predictors.
Trees had depth at most two and minimum leaf support five. Features and
thresholds were fitted on training folds only; families were used for
validation, never as input. The penalized loss was
`PDI + 0.25*(not optimal) + 2*(no incumbent)`, with training-leaf
proof/incumbent guardrails against the reference.

The most attractive in-sample **one-feature** rule was:

> Original forced-free native private coverage = 100%: use mixed (23
> training instances); otherwise disable SppGrasp (5 training instances).

It fails the question that matters: on the 14-instance causal-label holdout,
it gives PDI **0.505510**, worse than both default **0.494043** and constant
mixed **0.466043**, with no extra optima or incumbents. Training-family-held-out
stump predictions were worse still: PDI 0.644370 versus 0.465233 default,
with 11 rather than 8 no-incumbent runs. Allowing depth two did not rescue
generalization: its training-family-held-out policy lost incumbent
opportunities, and the locked, rejected tree gave holdout PDI 0.513872.
The extra split at row-option Q25 500.125 is therefore **not** a proposed
runtime cutoff.

A simpler predeclared structural baseline, legacy ON only for full native
coverage and OFF otherwise, would skip eight of the 42 originals. It avoids
42 logged SppGrasp calls / 172.49 logged seconds but adds 662 FPump LP solves.
It worsens instance-mean PDI on five skipped models (`air04`, `air05`,
`neos-1620770`, `t1717`, `t1722`; four exceed 0.01 PDI), gains one proof
and incumbent overall, and has near-neutral aggregate PDI delta +0.00115
versus pinned legacy with an interval spanning both signs. It does not
establish the requested simultaneous PDI/proof improvement. Native singleton
coverage is a useful feasibility diagnostic, **not a validated effort or
activation policy**.

At this stage no new AUTO gate, default change, or additional heuristic
suppression was implemented. The subsequent direct percentage-coverage
follow-up below adds an explicitly opt-in experimental threshold, not a
default policy promotion. Retain stage-local structural eligibility,
cheap construction, and explicit user overrides; use the fixed mixed setting
only as the documented candidate. More data are needed particularly for
the single lost NEOS proof and for genuinely new families, rather than a
larger threshold grid on these same instances.

The complete reproducibility bundle is `files/spp-auto-policy/`: frozen
binary/parser/validator and SHA256 manifests, design/split/locked decisions,
`original-features.tsv`, `original-policy-features.tsv`,
`features-paired-instance-outcomes.tsv`, `per-run.tsv`,
`proof-and-feasibility-transitions.tsv`, `duplicate-control.tsv`,
`one-feature-policy-diagnostics.json`, and confirmation per-run/per-instance
tables. `study.py`, `analyze.py`, `confirmation.py`, and
`policy_diagnostics.py` use the Python standard library. No BKS file or
solver runtime default was modified.

### Full regression and activation coverage

The same frozen binary was subsequently checked on all **511** sanity
instances in both arms, using explicit default/mixed policy wrappers.
The two main suites ran concurrently at 16 jobs each; ancillary programs
ran serially to avoid shared-fixture races. Both main suites had
**511/511 PASS**, **344 proven optima**, and zero invalid solutions/statuses,
errors, or overtimes. This does not mean performance was unchanged:
`compare-results` exits **1** for three wider terminal gaps:

| Instance | Default gap | Mixed gap | Difference |
|---|---:|---:|---:|
| air04 | 0.8803% | 1.8850% | +1.0047 percentage points |
| air05 | 2.2810% | 2.6044% | +0.3234 percentage points |
| sorrell3 | 26.8951% | 27.2859% | +0.3908 percentage points |

No proof-count change or main status regression accompanies these wider
gaps. `sorrell3` executed no SppGrasp in either arm, so that difference
cannot be attributed directly to SppGrasp; background timing and automatic
seed effects remain possible. The harness has its own per-instance
node/time limits and normal thread defaults, so these are regression
checks, not another matched 120-second PDI experiment. Its raw aggregate
average gap is dominated by sentinel/undefined-bound cases and is not a
useful quality statistic here. The two SPP air cases remain explicit
endpoint warnings rather than being hidden by the mean PDI improvement.

Actual SppGrasp result lines occur on 21 models in each main suite.
Root-heuristic result lines occur on 19 default models and **20 mixed
models** (the difference is `rmp10`); the latter cover
`air03`, `air04`, `air05`, `eilB76`, `eilC76`, `gc_cycle_c5`, `irp`,
`neos-1440225`, `neos-3226448-wkra`, `nw04`, and `rmp01`–`rmp10`.
Positive artificial-slack penalties are enabled in both wrappers.
Failed-attempt logs explicitly contain remaining artificial rows on
`air04`, both NEOS models, and `rmp07` in mixed, plus `rmp03` in default.
Thus the active/artificials path really was exercised; neither an
invocation flag nor merely passing unrelated LP models is presented as
activation coverage.

Ancillary results are identical in both runs: C API **9/9**, LP
relaxation **64/64**, MIP-start **198/198**, coefficient tightening
**80/80**, row activity **34/34**, and final-bound/progress-callback tests
pass. Lazy-constraint/TSP checks retain the **94 known assertion failures**
(119/213 pass), with the same failing assertions in both arms and in the
retained current-binary baseline. Consequently each ancillary harness exits
1; this is **not an all-green suite**. These standalone C API/library
programs do not inherit CLI policy-wrapper overrides; the 511 CLI cases
and the execution coverage above provide the policy-specific checks.

Logs, wrapper commands, full per-instance results, exact assertion
comparison, `comparison.txt`, and `active-policy-coverage.tsv` are retained
under `files/spp-auto-policy/regression/`. The recommendation at this stage was to
keep current defaults, expose no learned AUTO gate, and retain mixed as an
explicit experimental option—not to claim that the requested simultaneous
increase in optimal solves and decrease in PDI has been established.

## Direct native-coverage threshold follow-up (2026-10-21)

The user's concrete proposal—run only with complete native private coverage,
or with a sufficient percentage—deserves a direct **solver-outcome** test,
not rejection on regression-prediction RMSE. In particular, the earlier
full-coverage comparison gained an optimum and an incumbent while barely
changing PDI. It was too conservative to summarize that as simply “no
supported rule” without testing intermediate percentages.

The coverage used in these recorded policies is the number of partitioning
rows with a usable real singleton in the core's retained normalized rows,
divided by partitioning rows; artificials do not count. Bounds,
complement normalization, packing rows and restriction handling apply.
**This is not always the stricter raw-matrix private-column statistic**:
a benign row omitted from the representation can still touch the column.
The policies below conservatively require zero forced columns. Full
represented coverage offers a trivial construction which must still be
validated against the actual model;
partial coverage is an empirical activation criterion, **not a feasibility
certificate**.

For the user's strict private-column criterion, degree must instead be
counted over **every actual finite-bound active constraint**, including
omitted benign/restricting rows. The later experimental pre-LP certificate
independently performs that scan and validates bounds, integrality and all
raw row activities. Historical coverage-policy results use the recorded
represented metric and must not be relabeled as a strict raw-degree study.

### Original-model prior: retrospective matched-policy replay

The two recorded matched seeds 301/302 allow the complete ON/OFF solver
policy to be replayed using original-input coverage. FPump is explicitly ON
under both treatments. Each rule enables/disables **both** SppGrasp entry
points; it does not recompute its threshold at the root:

| Original coverage threshold | Models ON / 42 | Mean PDI / 84 runs | Optima | No incumbent |
|---|---:|---:|---:|---:|
| Always ON | 42 | 0.476477 | 40 | 12 |
| At least 25% | 37 | 0.466530 | 41 | 11 |
| At least 50% | 36 | 0.468084 | 41 | 11 |
| At least 75% | 35 | 0.481725 | 41 | 11 |
| At least 90% | 35 | 0.481725 | 41 | 11 |
| Exactly/full 100% | 34 | 0.477631 | 41 | 11 |
| Always OFF | 0 | 0.684356 | 41 | 14 |

Thus 25%/50% improve all three **retrospective point estimates**. This is
a specific promising rule, not a claim that a classifier has generalized.
The threshold comparison was inspected after those outcomes, so fresh
confirmation is essential. The literal-majority **50%** rule was locked as
the primary candidate, with **25% and 100%** predeclared companions, before
collecting seeds **305–308**. Thresholds are not reselected on those fresh
outcomes.

The percentages are meaningful, not merely binary indicators. Original
coverage is 95.161% for `air03`, 59.165% for `t1717`, 48.225% for `t1722`,
zero for `air04`, `air05`, and three NEOS instances, and 100% for the
remaining 34 models. The historical 40-model SppRoot cohort is different:
its threshold-25/50/75/90/100 model counts are **32/31/30/29/26**, not
37/36/35/35/34. These root counts are structural diagnostics only, not a
transfer of original-model causal outcomes.

### Opt-in runtime policy on the actual active model

For an actual per-stage test, the experimental parameter
`sppGraspMinNativeCoverage` accepts a fraction in `[0,1]`:

```sh
# At least half of current partitioning rows need real private columns:
cbc model.mps.gz -sppGrasp on -sppGraspMinNativeCoverage 0.5 -feas on -solve
# Full current-model native coverage; no artificial-only completion:
cbc model.mps.gz -sppGrasp on -sppGraspMinNativeCoverage 1 -feas on -solve
```

The default **0** preserves legacy behavior and RNG trajectory; explicit
`sppGrasp off` still disables every entry point. A positive threshold is
checked independently at original-stage entry, at root installation, and
again on each active heuristic call. The active-call check includes all
current rows/cuts, rather than trusting an original-model certificate or a
continuous-root row prefix. Invalid structure or failed coverage safely
skips SppGrasp; FPump's explicit setting is preserved, and a skipped
SppGrasp does not itself suppress the fallback pump. The existing
`sppGraspArtificial 0` restriction is also preserved: a partial-coverage
gate cannot secretly enable artificial search. Log level 2 reports
`original-entry`, `root-entry`, and `active-call` coverage, forced-column
count, threshold, and run/skip decisions.

This runtime policy is deliberately **not identical** to the original-input
prior replay. Even the original-stage entry can see bound changes or row
reductions already performed before the first LP; root preprocessing and
cuts can change coverage again. The fresh 42-instance prior-policy cohort
and the separate small same-binary active-stage pilot are reported
separately in `files/spp-auto-policy/native-coverage-followup/`.

### Fresh seeds: the percentage rule was tested directly

Seeds **305–308** used the frozen pre-gate binary, the same 120-second
global horizon, and identical explicitly enabled FPump configuration.
The 34 full-coverage models have precisely the same ON command under all
rules, so those potential outcomes are shared rather than wasting duplicate
runs. The eight non-full models receive paired, randomized/interleaved
ON/OFF runs. Four identical ON duplicates quantify timing noise.
This is **204 actual validated runs**, representing 168 outcomes for each
policy—not four independently executed 168-run cohorts.

| Original prior policy | Mean PDI | PDI delta versus ON, instance-cluster 95% interval | Optima / 168 | No incumbent / 168 |
|---|---:|---:|---:|---:|
| Always ON | 0.452545 | — | 85 | 20 |
| Primary: at least 50% | 0.458944 | +0.006399 [−0.024843, +0.036292] | 84 | 21 |
| Companion: 100% | 0.467759 | +0.015214 [−0.022713, +0.055768] | 84 | 21 |
| Companion: at least 25% | 0.457584 | +0.005039 [−0.025344, +0.034876] | 84 | 21 |

The promising retrospective proof/feasibility gain **does not replicate**.
All three rules gain two proofs/incumbents on `neos-1440225` (seeds
306/307), but lose three on `neos-3226448-wkra` (305/306/308): net **one
fewer optimum and one additional no-incumbent run**. Both models have zero
original native coverage, so no positive threshold on this feature alone
can distinguish those opposing outcomes. This is an actual outcome
guardrail failure, not a prediction-RMSE argument. The PDI intervals include
zero; the 50% family-cluster interval is [−0.004963, +0.033314].
The 50% rule avoids 64 logged SppGrasp calls, 173,476 LNS iterations, and
271.26 logged seconds, but adds 748 FPump LP solves / 660 passes. The four
duplicate ON controls have mean absolute PDI difference 0.00474. Saving
heuristic work is therefore real, but does not compensate for the observed
proof/incumbent losses.

These are effects of the whole ON/OFF policy, including downstream
random-state and heuristic interactions, not proof that SppGrasp itself
supplied each incumbent. For example, on `neos-3226448-wkra` seed 305 the
ON logs show unsuccessful SppGrasp attempts with artificial rows remaining,
yet the full solver subsequently proves objective zero; OFF has no
incumbent at the horizon. The recorded treatment outcomes, not a guessed
mechanism, determine whether skipping was harmful.

### Actual active-stage pilot, rather than assuming the prior is equivalent

The opt-in implementation was then tested on the eight non-full originals
plus `rmp03`/`rmp10` as stage-change controls: ten instances, seeds
309/310, 72 actual validated runs. All arms use one frozen rebuilt binary,
legacy neighborhoods, explicitly enabled FPump, and the same corrected
120-second horizon. Original-prior-50 outcomes share identical ON/OFF
commands where appropriate; active-50 and active-100 are actual runtime
gates.

| Pilot policy | Mean PDI | Delta versus ON | Optima / 20 | No incumbent / 20 |
|---|---:|---:|---:|---:|
| Always ON | 0.489939 | — | 12 | 2 |
| Original-input prior 50% | 0.488681 | −0.001258 | 12 | 2 |
| Actual active-stage 50% | 0.507919 | +0.017980 | 12 | 2 |
| Actual active-stage 100% | 0.549111 | +0.059172 | 13 | 1 |

The active-50 instance-cluster interval is [−0.116187, +0.132338];
active-100 is [−0.100651, +0.215393]. This small pilot is deliberately
enriched for discordant/stage-changing cases, not a new full-42 estimate.
Active-100 gains one proof/incumbent on `neos-3226448-wkra` seed 309,
but does not improve PDI overall. On that zero-coverage model, active-50
and active-100 both skip at both entries; their differing proof outcomes
therefore also expose timing/load sensitivity among nearly identical
controls, not a credible intrinsic advantage of the 100% threshold.

The logged stage changes are operationally important:

* `rmp03`: original input features are full/forced-free, but actual
  original entry has 25 forced columns and skips. Root entry is 607/608
  covered with zero forced columns: active-50 runs, active-100 skips.
* `rmp10`: original entry has 33 forced columns and skips; root has full
  coverage/zero forced columns and both thresholds run.
* `air03`: original entry is 118/124 covered, while the actual root
  coverage varies with the treatment/seed (including 79/109 and 111/119).
  Active-50 runs; active-100 skips.
* `t1717` stays at 59.165% and runs only under active-50; `t1722` stays
  at 48.225% and skips under both.

These are separate active matrices, not renamed original features.
The threshold check itself scans existing row/column arrays and solves
no LP; existing diagnostic full-feature exports took about 0.55 ms median
(167 ms maximum under concurrency), excluding model loading. That is
context for feature cost, **not a dedicated timing measurement of the
runtime gate**.

**Decision:** retain the explicit experimental knob and current default
zero; do not promote an AUTO/default percentage rule. We directly tested
the promising 50% proposal, the requested 100% rule, and the 25% companion,
rather than dismissing them using prediction metrics. The fresh
original-prior policy fails proof/incumbent guardrails, and neither active
pilot achieves the requested simultaneous proof/PDI improvement. No
additional mixed/threshold grid or new full-511 run was launched after
these promotion guardrails failed. The earlier full suites are not
mislabelled as testing this new gate.

The new coverage self-test covers zero/partial/full boundaries, artificial
exclusion, packing-coupled columns, negative/complemented costs, forced
columns, explicit OFF/artificial-OFF/FPump overrides and fallback. With
threshold zero its tiny-model trajectories match the frozen pre-gate
binary. Existing corrected-history, parameter/FPump, feature, staged,
guide, progress-gate, backtracking, and acceptance self-tests also pass.
No `.am`/`.ac` files were changed, no installed-build claim is made, and
there were no commits or pushes. Frozen manifests, per-run and
per-instance TSVs, exact proof/incumbent transitions, and numeric
`active-stage-decisions.tsv` are in
`files/spp-auto-policy/native-coverage-followup/` and its `active-pilot/`
subdirectory.

## Opt-in coverage-conditional parameter experiments

`-sppGraspTuningProfile FILE` is an **experimental, default-empty** parameter
profile for studying improvements on the majority-native population. It is
not the activation gate above:

* At each original/root invocation, inspect that invocation's actual,
  bound-normalized active model. Require at least 50% real private-column
  coverage and no forced columns; artificials do not count.
* Qualifying calls receive the numerical profile. Below-50%, forced,
  too-restricted, or unsupported all-active models retain the existing
  legacy/user settings, rather than disabling SppGrasp. In particular an
  original-input coverage vector is not a root certificate.
* The qualification check includes current cuts. An incompatible artificial
  setting falls back to the legacy model, rather than silently suppressing
  a call. Existing structural applicability and solution validation remain.
* Explicit `sppGrasp off`, FPump controls, and the existing SppGrasp numerical
  overrides take precedence. The explicit work override protects both
  profile work caps; a positive aggregate allocation imposed by the outer
  short/staged scheduler also cannot be enlarged or disabled by a profile.
  Profile parsing is transactional: malformed, unknown,
  nonfinite, or unreadable entries warn and retain legacy settings.

For example, this is an opt-in experiment, **not a new recommendation or
default**:

```sh
cat > spp-native.params <<'EOF'
drows 2
dgrow 0.1
stall 0
artificial 2
EOF
cbc model.mps.gz -sppGrasp on -sppGraspTuningProfile spp-native.params \
    -sppGraspMinNativeCoverage 0 -feas on -solve
```

Each non-comment line is `benchmark-option-name numeric-value`, without
`--` or `=`. Configuration/search options include construction/repair rules,
RCLs, LP/conflict bias, neighborhoods, related/gain selection, acceptance,
bounded repair, artificial-penalty schedules, and stopping/work limits;
the validated key mapping is `applyCoverageTuningValue()` in
`CbcHeuristicSppGrasp.cpp`. Operational options such as benchmark input,
seed, time limit, cache, and output paths are not profile keys. `#` begins a
comment. File work values (`maxwork`, `totalwork`, `realstallwork`, `artwork`,
`btwork`, and `sacool`) are **basic work units**, whereas existing solver
CLI work controls use millions. Profile settings cannot remove the
whole-model time limit.

`totalwork` aggregates penalty epochs **within one invocation**. Under the
legacy root sequence, original and root calls have separate caps; this is
not a single cap for the entire solve. The staged scheduler's outer
allocation still takes precedence. Construction/move-boundary overshoot
is charged and reported, and whole-solver timing must include it.

Parameter studies must also respect when a setting is active. The first
GRASP construction forces both RCL alphas to zero; construction-row RCLs
therefore need additional starts. With `lrow=6` (random repair rows), all
row keys are equal, so changing only the row alpha does not change the
row selection. Conversely, `beta` remains meaningful with reduced-cost
column scoring: cost-per-row is its secondary tie-breaker. Coupled
rule/RCL/LP-bias studies are needed rather than interpreting dormant
one-factor settings as negative evidence.

With log level 2, assignment/fallback messages identify original versus
root stage, actual coverage, forced columns, selected neighborhood,
work/stagnation limits, and decision/reload overhead; result messages
report actual core work, iterations, time, and genuine feasibility. These
are assignments and executed-call statistics, not optimality proofs.
Ordinary calls also emit `SppGrasp run result: stage ...` at log level 2,
so baseline work is measured rather than mistaken for zero because no
profile was supplied.
`spp-grasp-coverage-profile-selftest.py` checks original/root cloning,
0/half/full boundaries, forced/packing fallbacks, exact default trajectory,
explicit overrides/OFF, budget precedence, and malformed/incompatible
profiles. `spp-grasp-total-work-selftest.py` checks aggregate caps across
penalty epochs. No tuning result or default promotion is implied by adding
this experimental interface.

### Experimental feasibility-phase repair

The benchmark and numerical profile key `lls` also accept three explicit
phase policies: **3** uses local-search mode 1 before the first genuine
feasible incumbent and mode 2 afterwards; **4** uses 0 then 2; **5** uses
2 then 1. Modes −1/0/1/2 retain their existing semantics. The switch is
per run and permanent once a genuine incumbent exists, even if a later
accepted search state uses artificial columns. A finite artificial
completion alone never triggers it.

Native-complete models have a genuine trivial initial vector, so modes
3/4 immediately use mode 2: with otherwise identical settings their work,
RNG, and search trajectory match fixed repair mode 2. Construction local
search remains independently controlled by `ls`. This opt-in experiment
separates cheap pre-feasibility repair from later objective optimization;
it does not change any default or prove a tuning benefit.
`spp-grasp-phase-search-selftest.py` checks full-native equivalence,
never-feasible artificial models, and exact seeded prefixes through the
first genuine-feasibility switch.

Preprocessed fixtures can contain a substantial objective constant even
when the original model has none. Both benchmark trajectories and
`cbc_validate_sol` use **`c x - OsiObjOffset`** for reported/recomputed
objectives; omitting the constant produces a false objective mismatch.
`cbc-validate-sol-offset-selftest.py` covers positive, negative, and large
constants, negative coefficients, and rejection of unshifted claims/BKS.
Fixture solutions remain in fixture coordinates: this check does not
turn them into original-model solutions or authorize updating original BKS.
Clp root dumps can omit integer declarations from the MPS itself.
Independent fixture integrality validation must therefore restore/check
the `.ctype` sidecar; a validator reading only the raw MPS can still check
names, rows, bounds, and objective, but cannot certify missing declarations.

## Coverage-conditioned tuning campaign (2026-10-21/22)

This campaign tunes **parameters**, not whether SppGrasp runs. Its opt-in
profile applies only when the *current invocation's* loaded model passes
the existing structural tests, has no forced columns, and has represented
real-singleton coverage at least 50% (the distinction from strict
all-active-row private degree is explained above). Otherwise the existing parameters remain
in force. It does **not** implement the earlier, unsuccessful policy of
turning the heuristic off below 50%. All defaults remain unchanged.

### Design and scope

The benchmark campaign executed 95,997 runs, including broad screening,
targeted interactions, fresh-seed refinement, a prospectively added
related-row/gain-tournament movement study, deep training, and held-out
evaluation. Parameters covered construction/scoring/RCLs, LP bias,
neighborhood size and growth, seed/scan limits, related/gain selection,
local-search and feasibility-phase repair, artificial penalties,
threshold/SA/LAHC acceptance, bounded repair, and stopping/work budgets.
Behaviorally inactive settings are not evidence of an algorithmic gain:
for example, scan limits 8/32/64 did not distinguish the selected mode-1
local search, and a 2B-work real-stagnation threshold cannot activate before
a 250M total-work cap.

There were 63 LP-warmed qualifying model stages: 45 training stages from
24 whole instances, and 18 held-out stages from 10 whole instances.
Original and historical preprocessed fixtures remained separate. Eight
held-out names were genuinely unexecuted by the campaign before candidate
freezing; two (`rmp03`, `t1717`) were quarantined after an initial split
mistake, and their early outcomes were excluded from selection. The
quarantined names must not be described as untouched holdouts.

The useful training trends were more specific than a global “singleton
fraction predicts success” rule:

- Raising artificial factor 2 to 5 won the broad screen, but this can
  affect only partial-native stages: complete-native stages contain no
  appended artificials. Native-invariant runs were reused explicitly,
  not counted as independent evidence for penalty settings.
- The fast mode-1/factor-5 combination was attractive for early cost/time,
  but versus mixed on the 13 training RMP means it worsened the equal-work
  integral by 0.002723 and final normalized LP gap by 0.003397. This is a
  combined-setting speed/quality tradeoff, not an isolated causal estimate
  of the local-search mode or a uniformly stronger search.
- A followup specifically recovered a promising movement direction
  dropped by a capped interaction pool: `related=.5`, gain tournament 2,
  factor 5, mode 2. Its training RMP work-integral/final-gap deltas were
  −0.002229/−0.002195. The later 1.5B-cap whole-Cbc development test
  nevertheless had PDI 0.451744 and 124 proofs, versus conditional
  mixed's 0.442566 and 126: better offline moves did not automatically
  produce a better solver policy.
- Calibrated SA, LAHC, phase repair, bounded repair, and alternative
  scoring/RCL settings were screened; neither frozen finalist uses SA,
  LAHC, or backtracking. This is not proof that these families cannot
  help under another budget/population.

Equal-work benchmark controls deliberately disable natural work/
no-improvement stopping. Their artificial-penalty escalation and
no-genuine counts are therefore not the production solver's behavior;
production feasibility conclusions below use the matched whole-Cbc runs.

The fast mode-1/artificial-factor-5 candidate improved early work-integral
quality in aggregate but **did not establish a general benchmark holdout
win**: on the eight untouched names its work-integral delta versus mixed
was +0.001691 (worse). The aggregate ten-name improvement was driven
mainly by the quarantined partial-coverage cases. The movement companion
(`related=.5`, gain tournament 2, factor 5, mode 2) had a small −0.001223
delta on the untouched eight. These are **heuristic-only, charged-work
integrals**, not full-Cbc PDI.

Production calibration therefore used actual whole-Cbc runs rather than
promoting the benchmark ranking. A development cohort contained 1,784
corrected-clock runs on 42 original models. A further 838-run budget
calibration used only 23 training whole instances, choosing between
100M/250M/500M/1B/1.5B per-invocation caps and no-improvement stopping
0/1000. It selected **250M, no-improvement 1000**, before the independent
confirmation labels were available. Selection prioritized proof and
incumbent losses, then the declared 50%-RMP/50%-non-RMP-family PDI score.

### Independent primary confirmation

The frozen candidate was evaluated on all 42 original models with fresh
Cbc seeds 1157–1160, a common 120-second global horizon, one Cbc thread,
matched FPump settings, interleaved policies, and ten duplicate controls:
850 actual runs, including 168 primary runs per policy.

| Policy | Mean PDI ↓ | Proven optimal ↑ | No incumbent ↓ |
|---|---:|---:|---:|
| Existing policy / FPump auto | 0.448524 | 83 | 19 |
| Legacy parameters / FPump on | 0.449412 | 83 | 19 |
| Mixed parameters, coverage-conditioned | 0.440576 | 83 | 19 |
| Mixed parameters, globally assigned | 0.428277 | 83 | 19 |
| Tuned 250M/1000, coverage-conditioned | **0.423533** | **85** | **19** |

Against matched legacy/FPump-on, the PDI delta was **−0.025878**
(5.76% lower), with a whole-instance bootstrap 95% interval
[−0.039653, −0.013743] and family-cluster interval
[−0.059364, −0.004838]. Against coverage-conditioned mixed, the delta
was −0.017043; the family interval barely excluded zero
[−0.046236, −0.00000128], so cross-family evidence for the incremental
gain is weaker. Seeds are aggregated within instances; stages/seeds are
not treated as independent instance samples.

Against the stronger **globally assigned mixed** comparator, the primary's
PDI delta was only −0.004743, with instance interval
[−0.017318, +0.007792] and family interval [−0.040282, +0.018870].
Its 50%-RMP/50%-non-RMP-family PDI score was **worse by 0.004102**.
Thus this cohort does not establish superiority over the best existing
mixed policy. Even against legacy, the RMP mean PDI improvement was only
−0.002428, much smaller than the global gain, while RMP mean final gap
worsened by +0.007243.

Both additional proofs were `rmp09`, seeds 1157 and 1158; there were no
lost-proof transitions in this cohort. This is an observed proof-count
gain, not a claim that two additional proofs are statistically established.
**There is an important terminal-quality tradeoff:** `rmp18` worsened by
0.079525 in mean normalized final primal–dual gap and by 0.046976 PDI
versus legacy. Against conditional mixed, `rmp14` also worsened.
The overall mean final gap was 0.302285 versus legacy 0.300427, despite
the better PDI and proof count. The candidate does not dominate every
instance or every objective, and is not promoted to the default.

The corrected progress clock includes the initial LP and accepted
original-model incumbents at their actual positive acceptance times.
Optimality after the 120-second horizon is not credited at 120 seconds.
Fractional vectors saved when no integer solution exists are not counted
as feasible incumbents. All run statuses, final vectors, and progress
histories were audited. No heuristic-OFF arm was included in this new
campaign: these comparisons estimate **policy changes**, not the benefit
of SppGrasp itself versus its absence.

### Fresh proof-priority replication

While the primary cohort was still running, and before its aggregate
outcomes were inspected, a second cohort was frozen to compare the primary
with a companion selected **only from the training budget Pareto table**:
the same factor-5/mode-1 settings, **500M total work and
no-improvement stopping disabled**. Both work and stopping change, so
this is a policy comparison, not an isolated work-cap effect.
All 42 originals were run with seeds 1401–1404 and the same 120-second
clock: another 850 audited runs.

| Policy | Mean PDI ↓ | Proven optimal ↑ | No incumbent ↓ |
|---|---:|---:|---:|
| Existing policy / FPump auto | 0.441529 | 85 | 18 |
| Legacy parameters / FPump on | 0.440300 | 85 | 18 |
| Mixed parameters, coverage-conditioned | 0.432419 | 83 | 18 |
| Tuned 250M/1000, coverage-conditioned | **0.413735** | 83 | 18 |
| Tuned 500M/0, coverage-conditioned | 0.420978 | 84 | 18 |

**The PDI gain replicated; the additional proofs did not.** Versus
legacy, the primary lost `rmp04` seed 1403 and `rmp09` seed 1402, with an
`eil33-2` seed-1401 gain offset by a seed-1403 loss. The 500M companion
lost `rmp04` 1403, and its `rmp09` 1401 gain/1402 loss canceled.
Its predeclared no-proof-loss guard failed, so the optional secondary
511-case run was not launched.

Across the two matched four-seed cohorts, the primary had **168 proofs
and 37 no-incumbent runs out of 336**, exactly the legacy totals.
Its pooled PDI was 0.418634 versus 0.444856 (5.89% lower).
Thus there is a repeatable PDI improvement relative to legacy with no
*net* proof-count loss in these eight seeds, but not a robust proof-count
improvement or a guarantee of no per-instance regressions. In particular,
the pooled `rmp09` proof gain is offset by an `rmp04` proof loss. Fresh
seeds are not new instances, and the terminal-gap caveats still apply.

### Separate 300-second horizon sensitivity

The two already frozen profiles were also tested without retuning on all
42 originals, seeds 1501–1502: 430 audited runs including duplicates.
Both the solver limit and the integration horizon were **300 seconds**.
These results must not be pooled with the 120-second cohorts.

| Policy | Mean PDI ↓ | Proven optimal ↑ | No incumbent ↓ |
|---|---:|---:|---:|
| Existing policy / FPump auto | 0.345787 | 44 | 8 |
| Legacy parameters / FPump on | 0.346349 | 44 | 8 |
| Mixed parameters, coverage-conditioned | 0.341685 | 46 | 8 |
| Tuned 250M/1000, coverage-conditioned | **0.334874** | **46** | 8 |
| Tuned 500M/0, coverage-conditioned | 0.338565 | 45 | 8 |

The primary gained `eil33-2` and `rmp09`, both seed 1501, versus legacy,
with no lost proofs in this cohort; conditional mixed gained the same
proofs. However, primary mean terminal normalized gap was **0.264204
versus 0.261994** for legacy, again showing that earlier progress and
terminal quality are distinct. This is two-seed horizon sensitivity on
the same known instances, not an independent-instance confirmation or
evidence that the 120-second proof regressions disappeared.

### Stronger mixed control and training-only repair follow-up

A further 682 audited 120-second runs used seeds 1701–1704 and included
the **global mixed** policy, rather than only coverage-conditioned mixed.
Among the 168 primary runs per arm:

| Policy | Mean PDI ↓ | Proven optimal ↑ | No incumbent ↓ | Mean terminal normalized gap ↓ |
|---|---:|---:|---:|---:|
| Legacy parameters / FPump on | 0.448045 | 86 | 18 | 0.290047 |
| Global mixed parameters | 0.424242 | 84 | 18 | 0.289841 |
| Tuned 250M/1000, coverage-conditioned | **0.420700** | **86** | 18 | 0.293000 |
| Tuned 500M/0, coverage-conditioned | 0.427408 | 85 | 18 | 0.290358 |

The primary-minus-global-mixed PDI difference was −0.003541, with a
whole-instance bootstrap 95% interval **[−0.017285, +0.011032]**.
The predeclared 50%-RMP/50%-other-family score was instead **+0.005405
worse**, and terminal gap was +0.003159 worse. The two additional proofs
were `eil33-2` seed 1701 and `rmp09` seed 1704. Thus the stronger control
does not establish a robust PDI or RMP-priority win for the primary.

A separate **training-only** 700-run interaction study on 23 originals,
seeds 1601–1603, investigated local-search mode, repair scan and work cap.
It did not reuse the campaign's held-out instance labels for selection.
The mode-1/250M primary had PDI 0.155868, 40 proofs and terminal gap
0.086675. Mode-2/scan-8/500M/1000 had PDI 0.159607, 42 proofs and gap
0.080746; both had no missing incumbents. Its proof gains were
`eil33-2`/1601 and `rmp09`/1602. This **proof/terminal-quality trade-off**,
not a PDI winner, was frozen for a subsequent fresh-seed exploratory
comparison. Changing search mode, scan and budget together does not
isolate the causal effect of any one parameter.

### Active-stage features are not raw-file certificates

An additional, explicitly experimental opportunity is **native completion
before the initial LP**, rather than waiting for the existing original-model
Spp search entry. Across the eight legacy confirmation seeds, `ds-big`,
`ivu06`, `ivu06-big` and `ivu52` had no incumbent and no Spp invocation;
the initial LP consumed the budget (`ivu52` also fails the search-effort
restriction filter). A feasible certificate does not require that LP.

The compile-time-only `CBC_SPP_NATIVE_PRELP` prototype scans the exact
current matrix after pre-root strengthening, chooses genuine binary
alternatives private over **all actual active rows**, and independently
checks every bound, integrality condition and row. It uses no artificial
columns, LP solution, BKS, family or instance lookup. It does not run
GRASP/LNS or disable any later heuristic. The existing search-effort
restriction is not a mathematical feasibility restriction and is not
applied to this certificate. OFF, cutoff and staged-sequence exclusions
are tested; maximization, SOS, custom objects/event handlers and lazy
cut-generator models are excluded. Custom `CbcSolver` callbacks and
general API/stop-limit behavior are not production-qualified.

The four originals passed actual 12-second **initial-LP-timeout** checks:
all saved vectors were genuine integer incumbents and independently
validated against the original models. This required fixing the prototype's
early-abort incumbent transfer to `.solu`; the earlier partial v3 trial
(86 completed, 32 interrupted in-flight tasks) is quarantined and supplies
**no efficacy evidence**. The successful frozen prototype is v5.
Its event uses actual positive global time and an unknown dual bound;
extraction/validation time is charged to global PDI, not to the existing
GRASP/LNS work counter. Normal binaries and defaults remain unchanged.

**Cheap feasibility is not good optimization.** The no-search native
objectives for `ds-big`, `ivu06` and `ivu06-big` were respectively
47892.8000, 2475.3903 and 2475.3903, versus fixed references 195.4398,
142.86 and 140.74. Their symmetric reference gaps were approximately
0.996, 0.942 and 0.943. The matched whole-solver component comparisons
and a separately labeled no-LP search-quality diagnostic must therefore
report incumbent availability, early progress and final quality separately.

The completed mechanism cohort used all 42 originals, seeds 1801–1802,
120-second global limits/horizons and FPump explicitly ON: 519 audited
runs including repeated controls, **84 primary runs per arm**.

| Frozen search policy | PDI without early native phase ↓ | PDI with early native phase ↓ | Proofs without / with ↑ | No incumbent without / with ↓ |
|---|---:|---:|---:|---:|
| Legacy | 0.438952 | **0.335603** | 42 / 42 | 9 / **1** |
| Global mixed | 0.413667 | **0.311927** | 44 / 44 | 9 / **1** |
| Coverage-conditioned 250M/1000 | 0.412375 | **0.314885** | 41 / 41 | 9 / **1** |

Each **matched component-only comparison** recovered an incumbent on
`ds-big`, `ivu06`, `ivu06-big` and `ivu52` in both seeds, with **no
individual proof gain or loss**. Legacy's mean PDI reduction was 0.103349
(23.5%); the whole-instance bootstrap 95% interval for the difference was
[−0.196929, −0.031787], and the family-cluster interval was
[−0.405734, −0.005142]. The predeclared RMP/family-balanced difference
was −0.113815. These are promising causal results for **adding this
component**, not evidence about switching the entire Spp heuristic ON/OFF
or about optimization quality beyond the native incumbent. They are fresh
seeds on known instances, not an external instance holdout.

In particular, these results do **not** make the tuned 250M profile the
winner: global mixed had three more proofs and lower PDI in this cohort.
Global mixed also changes parameters below 50% coverage, so it is a
strong comparator, not a promoted coverage-conditioned candidate.
Further fresh-seed replication and candidate correctness checks remain
separate from this initial mechanism result.

A separate strict-feature audit covered **85 model/stage pairs**: all
42 originals and 40/43 historical SppRoot fixtures were loadable, with
the three unavailable root cases explicitly retained as coverage gaps.
Integrality sidecars and fixture padding were handled as in the benchmark.
All **66 operationally qualifying stage models** (35 original, 31 root)
had matching represented and strict covered-row fractions. Thus the
general definition distinction does not change this campaign's qualifying
population. Strict full feasible completion held on **34 originals
versus 26 historical roots**; these remain separate stages, not runtime
root certificates inferred from original files.

The actual early phase accepted **16/42 instances** (32/84 runs in each
native arm), not all 34 raw-file certificates. None of the 18 RMP models
received an early native injection: current bounds/row reductions and
the prototype guards must be checked at invocation. The accepted-phase
median extraction/validation time was approximately **28 ms**, with a
maximum of **2.97 s** under 32-way load; this excludes rejected attempts.
The last accepted incumbent arrived at global time 7.80 s. Thus
linear-time/no-LP extraction is not cost-free, and its wall time is
included in the PDI.

The subsequent fresh-seed cohort (1901–1902, another **519 validated
runs**) did **not** confirm the training-only LS2/scan8/500M proof gain:

| Policy | PDI ↓ | Proofs ↑ | No incumbent ↓ |
|---|---:|---:|---:|
| Legacy | 0.444305 | 42 | 9 |
| Global mixed | 0.425405 | 44 | 9 |
| Conditioned 250M/1000 | 0.416249 | 44 | 9 |
| Conditioned LS2/scan8/500M | 0.421363 | 42 | 9 |
| Early native + 250M/1000 | 0.319982 | 43 | 1 |
| Early native + LS2/scan8/500M | 0.323334 | 42 | 1 |

Both native pairs again recovered the same eight missing incumbents.
However, **early native + 250M lost the `eil33-2`, seed 1902 proof**
relative to the identical no-native policy: normalized terminal gap
0.036705 versus 0. This is a real observed guardrail regression, not
dismissed as timing noise. The native/LS2 pair had no proof transition.
Consequently neither a parameter-profile winner nor a globally
proof-preserving native component is established by these two cohorts.
Additional unchanged-legacy replication is separate from tuning, and
there is **no default promotion**.

That budget-amended unchanged-legacy replication executed **178 runs**
(seeds 2301–2302, all 42 originals plus repeated controls). Mean PDI
fell from **0.433365 to 0.330409**, proofs remained **44/84**, and no
incumbent fell from **8 to 0**, with **no individual proof transition**.
Together with seeds 1801–1802, the identical legacy/component policy has
**168 matched runs per arm**: PDI **0.436159 → 0.333006**, proofs
**86 → 86**, and no incumbent **17 → 1**. These are four seeds on
the same known instances, not four independent instance populations.
This supports the early certificate with unchanged legacy search as an
experimental lead; it does not erase the separate native/250M proof
loss or establish a universally proof-preserving component.
The pooled instance-cluster 95% interval for its PDI difference is
**[−0.196820, −0.030874]**; the family-cluster interval is
**[−0.404665, −0.004942]**. The RMP mean difference itself is
**+0.001046** (slightly worse), with no native injections on those
18 models. The benefit is therefore not an RMP optimization win.

For diagnosis only, the `eil33-2`/1902 pair was also replayed with a
20,000-node cap and a 300-second guard. Both independently validated
the optimum **934.007916** at **18,227 nodes**, with matching Spp
iteration sequences. This supports investigating throughput sensitivity,
but the changed limit/load context is **not** another 120-second PDI
comparison and does not remove the observed wall-horizon proof loss.

The corrected no-LP diagnostic repeated 104 tasks with explicit LNS
limits for every search policy; the first 104 tasks remain archived with
their treatment-definition correction. All returned vectors were
independently feasible. On these four deliberately selected originals,
the native-only mean symmetric reference regret was **0.963214**.
Primary at the nominal 250M work cap reduced it to **0.649279**, with
mean cost improvement versus the native baseline **77.08%**, but this
is still poor final optimization quality. Mean actual work was
**318.10M**, not 250M; reported search-phase time averaged 1.63 seconds
and excludes model loading. Even a nominal 10M cap consumed 170.99M
mean actual work because initial construction/local search can
overshoot. Thus these are fixed-cap diagnostics with actual work
exported, **not equal-actual-work final-quality comparisons** or
whole-Cbc PDI results. Zero GRASP/LNS iterations also does not mean
zero diagnostic work or zero extraction time.

A final **32-run** diagnostic on the four deliberately selected
LP-blocked originals (seeds 2001–2002) tried explicit LP `dual` and
`primal` methods against `auto`, with the same native/legacy policy.
None released the downstream Spp search within 120 seconds: reported
Spp search work remained zero, and no run proved optimal.
Legacy/auto had PDI **2.000000** and eight missing incumbents; the
native auto/dual/primal arms had respectively **1.032840 / 1.032927 /
1.033034**, each with **zero missing incumbents**. Thus this bounded
LP-method opportunity was tested and did not improve on the native
availability fix. It is a selected four-instance diagnostic, not a
population estimate or an RMP result. The promising standalone no-LP
quality improvements above have **not** been integrated as new runtime
pre-LP optimization.

The later six-arm **511-case correctness batch** retained **344 confirmed
optima in every arm**, with no mathematical FAIL/ERROR. It was nevertheless
**not all green**: 3,063 PASS and three raw `OVERTIME` outcomes, all on
the nonbinary, Spp-inapplicable `proteindesign122trx11p8`. The harness
labels exit 137 as a timeout, but these processes stopped at 131–209
seconds, before the configured 300-second hard limit. A separate replay
measured approximately **18.2 GiB RSS per solver**; six such copies
exceed this machine's approximately 92 GiB physical RAM plus 8 GiB swap.
Memory pressure is therefore a strong hypothesis, **not a confirmed
kernel diagnosis**. The replay's four passing arms were preserved, and
the remaining two passed with measured memory-admission limits.
Those passing replays do **not erase** the original three guardrail
failures. Existing `compare-results` also reports terminal-gap
regressions; equal proof counts alone do not establish quality
nonregression, and this node-limited suite is not the matched 120-second
PDI experiment.

The final serialized default/native-default ancillary followup reproduced
exactly the same **94 lazy/TSP assertion failures** in each arm. Both
passed the 64 C-interface, 198 MIP-start, 80 coefficient-tightening and
34 row-activity checks, plus final-bound and progress-callback checks.
These use the normal C-interface library and do not establish general
API support for the experimental CLI-only native phase.

The runtime original pass can already have propagated bounds. For
example, raw `rmp03` and `rmp14` have complete native coverage, but their
runtime original passes had respectively 25 and 12 forced columns and
therefore retained legacy parameters. Their preprocessed root calls
qualified at 624/650 and 1197/1208 native-row coverage with no forced
columns. Later cuts or forced columns can cause fallback again.
Always recompute the decision on the exact active model; do not transfer
an original-file or historical-root certificate to another invocation.

A development `neos-1440225` proof gain occurred even though all its Spp
calls used unchanged fallback parameters and identical reported work.
It is not attributed to the tuned parameters. Identical controls and a
separate identity-profile/thread diagnostic investigate wall-clock/path
noise. Across 560 matched original-stage fallback pairs, LNS iterations,
reported work, and genuine-feasibility flags agreed exactly. This does
not imply identical wall-clock-limited whole-Cbc trajectories.

The completed 58-run diagnostic compared an **identity legacy profile**
with no profile on four models, seeds 1301–1303, both at threads 1 and
serial threads 0. Within each threading setting all paired proof and
no-incumbent statuses matched. Identity-minus-no-profile PDI was
+0.008236 at threads 1 and +0.001880 at threads 0. Identical-control
duplicates on `neos-1440225` differed by as much as 0.276561 PDI:
individual time-limited paths are noisy even without a parameter
intervention. Switching threads 1 to 0 exchanged a NEOS proof/incumbent
for an `rmp09` proof; these threading settings are not interchangeable
controls. The reused `mixed-conditional` label in **this diagnostic
only** denotes the identity legacy profile, not the mixed preset.

### Reproducing the opt-in primary

The frozen complete profile is the campaign artifact
`files/spp-tuning-12h/solver-budget-profiles/tuned-budget-250000000-1000.params`.
Its meaningful changes relative to the existing settings are:

```text
drows 2
dgrow 0.1
stall 0
artificial 5
ls 1
lls 1
noimp 1000
totalwork 250000000
```

The full frozen file additionally records all unchanged parameters and
inactive nominal settings (`scan 32`, `realstallwork 2000000000`, and
`relatedafter 1` with related probability zero); retain that file for
exact experimental reproduction. Profile work values are basic units,
not millions:

```sh
cbc model.mps.gz -threads 1 -sec 120 -preprocess sos \
    -sppGrasp on -feas on -sppGraspFpump on \
    -sppGraspRootSequence legacy -sppGraspMinNativeCoverage 0 \
    -sppGraspTuningProfile tuned-budget-250000000-1000.params \
    -progressCsv progress.csv -log 2 -solve -solu solution.sol
```

Keep `sppGraspMinNativeCoverage` at **0** for this experiment: setting it
to .5 changes activation and disables below-threshold calls, which is a
different, previously unsuccessful policy. The profile's 250M cap is
per invocation across penalty epochs, not a whole-solve work allowance.
Original/root invocations can each spend it; below-population legacy
calls retain their original budgets. Explicit user overrides and smaller
positive outer allocations take precedence.

### Regression and artifacts

Paired node-limited regression validated **511/511** cases under both
the existing default and the frozen primary, with **344 confirmed
optima in each**, no incorrect answers, and no new failures or overtimes.
The candidate actually exercised 21 profile assignments (6 original,
15 root) on 14 distinct instances, alongside 41 legacy-fallback decisions;
this was not a test in which the new branch remained dormant.
`compare-results` still returned nonzero for one terminal-gap change:
`sorrell3` widened by 0.0226 percentage points. Ancillary runs reproduced
the same **94 known lazy/TSP assertion failures** on both sides; other
auxiliary suites passed. Thus this is not an all-green auxiliary suite,
nor a claim of zero performance regressions.

The session artifact directory `files/spp-tuning-12h/` contains frozen
commands, source/binary hashes, splits, references, task manifests,
per-run TSVs, stage-local decisions/work, clustered uncertainty,
proof/incumbent transitions, duplicate controls, and the separate broader
structural census. The census examined 361 additional originals; its only
additional operationally eligible original was `nw04` (7/9 coverage),
whose root fixture was already in training. A separate 44-run original
`nw04` check found all eight primary runs optimal per policy, with PDI
0.051631 for tuned versus 0.094619 for matched legacy. It is useful
additional-stage evidence, **not** a new whole-instance holdout and is not
merged into the fixed-42 aggregate.
