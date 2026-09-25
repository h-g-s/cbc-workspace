# RINS (and VND) heuristic fixtures

A companion to `ROOT-FIXTURES.md` and `BENCHMARKING-CUT-GENERATORS.md`, applying
the same "dump once, replay forever" idea to incumbent-based heuristics --
RINS (`CbcHeuristicRINS`) foremost, with the same fixtures also usable for VND
(`CbcHeuristicVND`) and for measuring how much bound propagation could fix
before delegating to a sub-MIP solver.

## The one-paragraph version

RINS only becomes interesting to experiment on once TWO things exist at once:
a fractional LP relaxation at some node, and an incumbent integer-feasible
solution to compare it against. `CbcHeuristicRinsFixtureDump.hpp` dumps both,
captured from inside `CbcHeuristicRINS::solution()` the first time it is
actually invoked with an incumbent present, then the process exits
immediately. `gen-rins-fixtures` drives this over `mip-sanity-data`.
`test/rins-bench` loads a fixture, rebuilds a `CbcModel` around it, installs
the incumbent as the best solution, and calls the REAL `CbcHeuristicRINS` (or
`CbcHeuristicVND`) class directly with tunable knobs -- so a parameter sweep
over how aggressively RINS fixes variables costs milliseconds per point
instead of a full branch-and-bound run.

## Why this needs its own fixture (not the root fixture)

The existing root fixture (`ROOT-FIXTURES.md`) captures the state right after
the root LP solve, before any heuristic has necessarily found a solution --
that is the right state for cut generators and for "what does the root LP
alone give you", but RINS's entire mechanism is comparing a fractional
solution against an incumbent it does not have yet at that point (unless
Feasibility Pump/Jump found one first). Capturing at RINS's own call site,
deeper in the tree, is what a faithful RINS fixture requires.

## Fixture format

Written by `CbcHeuristicRinsFixtureDump.hpp`, one set per instance, tag `rins`:

| file | contents |
|---|---|
| `<name>.rins.mps.gz`   | the current node's matrix (preprocessed problem + any cuts added so far), formatType 2 (IEEE hex) |
| `<name>.rins.bas`      | the optimal LP basis at this node |
| `<name>.rins.sol`      | the fractional LP solution at this node |
| `<name>.rins.ctype`    | integer/continuous per column (MPS cannot express a fixed integer column) |
| `<name>.rins.incumbent`| the incumbent's value for EVERY column, dense (RINS needs exact values, including zeros, to test agreement) |
| `<name>.rins.meta`     | rows/cols/elements/nodeCount/numberIntegers/lpObjValue/incumbentObjValue/... |

**Caveat, by design, not a bug:** `CbcModel` derives each integer object's
"original bounds" from the solver's bounds at construction time. The real
RINS call this fixture captures reads original bounds set at the *root*
(unaffected by later branching); a fresh `CbcModel` built around this fixture
instead treats the *captured node's* (branching-tightened) bounds as
original. This only matters for `shallowDepth_` fixing modes 1-3 (fix
only at/away-from-original-lower-bound) -- mode 0 ("fix all agreeing", the CLI
default) is completely unaffected. `rins-bench` prints a one-line reminder
whenever a non-zero `--shallow` is requested.

Stored under `~/instances/mip-sanity-data/rinsFixtures/` by default
(`$CBC_RINS_FIXTURE_DIR` to override).

**Not every instance produces a fixture, and that is expected**, for reasons
that don't exist for the root fixture: RINS has to actually be *installed*
(the CLI's `-rins` default is on, but a driver could disable it) and its
node/frequency gate has to fire at least once with an incumbent already
present. Some instances are solved to proven optimality or infeasibility
(by other heuristics, presolve, or a short tree) before that ever happens --
an expected skip, not a failure.

## Generating fixtures -- two tools, prefer the root-fixture-replay one

**`gen-rins-fixtures-from-root` is the preferred tool whenever the target
instance already has a root fixture** (`ROOT-FIXTURES.md`) -- it drives
`test/mip-root-replay` (built with `-DCBC_DUMP_RINS_FIXTURE`) starting from
the already-preprocessed problem + optimal root basis, instead of re-running
preprocessing and the root LP relaxation from a raw `.mps.gz` every time.
Confirmed empirically to reproduce byte-for-byte the same fixture/no-fixture
outcome as the raw-CLI tool on every instance tested, at a large speedup
(~4x on a medium instance; larger on instances whose root LP itself is slow) --
because `mip-root-replay`'s `ReplayStrategy` installs cut generators and
heuristics via the exact same `installCutGenerators()`/`doHeuristics()`
production free functions the real `cbc` CLI calls, not a smaller default set.

```sh
cd Cbc/test
./gen-rins-fixtures-from-root \
  --root-fixture-dir=/path/to/rootFixtures \
  --fixture-dir=/path/to/rinsFixtures        # every instance with a root fixture
./gen-rins-fixtures-from-root --nodes=256 --sec=600 'bpc_*'   # wider budget, a subset
```

Options: `--jobs=N`, `--nodes=N` (default **128**), `--sec=N` (default **300**),
`--root-fixture-dir=PATH`, `--fixture-dir=PATH`, `--prefix=PATH`,
`--skip-build`, `--keep-bin`, `--no-color`. The **128-node / 300s default is a
deliberate choice**, not just "as much budget as the fast replay affords": the
goal of this fixture set is capturing RINS's/VND's behavior at *early/initial
tree nodes*, not after deep search -- letting a run wander for hours to find
its first incumbent late in a huge tree would capture a fixture unrepresentative
of the "RINS fires early in the search" scenario this tool exists to study.

**`gen-rins-fixtures` (the original, raw-`.mps.gz`-based tool) is the fallback**
for instances that don't have a root fixture yet, or when experimenting
without the root-fixture infrastructure at all:

```sh
cd Cbc/test   # or use the ./gen-rins-fixtures symlink at the workspace root
./gen-rins-fixtures                    # every instance, default 7200s/unlimited-node budget
./gen-rins-fixtures 'bpc_*' 'cvrp_*'    # only instances matching these globs
./gen-rins-fixtures --sec=1800 --nodes=128   # narrower, early-node-focused budget
```

Same non-destructive pattern as `gen-root-fixtures`: fixture dumping only
happens in a throwaway build compiled with `-DCBC_DUMP_RINS_FIXTURE`
(`test/.cbc-rinsdump-bin`), immediately followed by rebuilding + reinstalling
the normal no-dump `cbc`. Each worker runs single-threaded (`-threads 1`) --
`exit()`-on-first-dump is not meant to be called from more than one thread.

Options mirror `gen-root-fixtures`: `--jobs=N`, `--sec=N`, `--fixture-dir=PATH`,
`--data-dir=PATH`, `--prefix=PATH`, `--skip-build`, `--keep-bin`, `--no-color`.
`--nodes=N` (default **0**, meaning the `-maxNodes` flag is omitted entirely --
see the "`-maxNodes 0` gotcha" callout below) is RINS-specific: since finding
*any* incumbent to compare against can require real tree search (not just the
root LP), pass an explicit `--nodes` when the goal is specifically early-node
behavior, matching `gen-rins-fixtures-from-root`'s 128-node default.

> **`-maxNodes 0` is NOT "unlimited"** -- it is a special `CbcModel` case
> (`CbcModel.cpp` around the `if (!getMaximumNodes())` check) that stops all
> branching immediately after the root node (root heuristics, including RINS,
> still run via `doHeuristicsAtRoot()` beforehand). `mip-sanity-data`'s own
> convention -- node_limit=0 means *omit* `-maxNodes` from the command line
> entirely, never pass literal `0` -- is what both scripts follow for "true
> unlimited". Also confirmed empirically: whether cut generators are on or
> off makes no measurable difference to whether RINS fires -- that is governed
> purely by RINS's own internal node-count/`howOften_` gate
> (`CbcHeuristicRINS.cpp`), not by cut presence.

## Large-scale fixture collection results (`/home/haroldo/inst/miplib/2017+spp`, 385 instances)

Run with `gen-rins-fixtures-from-root --nodes=128 --sec=300 --jobs=16`
(early-node-focused budget, 16 physical cores) against that instance set's
`rootFixtures/` (root fixtures generated separately via `gen-root-fixtures`,
pass-1 600s/instance budget, `--jobs=16`):

| stage | count | % of 385 |
|---|---|---|
| root fixture exists | 349 | 91% |
| RINS fixture successfully dumped | 223 | 58% |
| root fixture exists but no RINS fixture (expected skip -- see below) | 126 | 33% |
| no root fixture at all (root LP/preprocessing too slow even at 600s) | 36 | 9% |

The "expected skip" cases are genuinely expected, not failures: either RINS's
periodic gate (`howOften_`, default every 100 nodes plus special windows)
never opened within the 128-node/300s budget, or the instance was solved to
proven optimality/infeasibility by other heuristics/presolve before that could
happen. The 36 instances without any root fixture are, by construction, the
hardest instances in the set -- their root LP relaxation and/or preprocessing
alone exceeds a 600s (pass-1) budget; `ROOT-FIXTURES.md` documents that most
(not all) of these can eventually be recovered with a much more generous
`--pass2` (3h+ LP racing) budget, not attempted here given the early-node
focus of this fixture set and the low expected yield relative to the time
cost. (One of the 36 -- `physiciansched3-3` -- was later recovered by a
follow-up pass-1 retry that happened to finish just under its own 600s
timeout; it still produced no RINS fixture at the 128-node/300s budget, so
the final counts above are effectively unchanged: 349/385 root fixtures,
223/385 RINS fixtures.)

## ⚠️ Known bug: `--sweep`'s in-process grid can silently misreport some points

Confirmed empirically (2026-09): running the same `(shallow, fixClose,
nodes)` point via `--sweep` (48 points back-to-back in one process) can
report a *different, strictly worse* result than an isolated single-point
run (`./rins-bench <instance> --shallow=S --fix-close=F --nodes=N`, no
`--sweep`) with **identical** options -- most visibly with `--method=vnd`,
where grid points after the first for a given instance sometimes report
`found=0` when a fresh, separate process for the exact same point reliably
reports `found=1` with the correct objective. Root cause not found yet (Clp's
`CoinThreadRandom`/`ClpModel` RNG is deterministically re-seeded to `1234567`
at every `ClpSimplex` construction, so it is not the obvious suspect); some
other state evidently leaks across successive `CbcModel`/`OsiSolverInterface`
builds within one process. `rins-bench` now prints a warning to this effect
before running `--sweep`. **Until this is root-caused, treat `--sweep`
output as directional ranking only, and always re-confirm any promising
cell with a separate one-shot invocation** -- this is exactly what the
large-scale results below do (one process per grid point, not `--sweep`).

## Large-scale parameter sweep results (same 223-instance RINS fixture set)

One-shot (isolated-process-per-point) grid over `shallow x fixClose x nodes`
for RINS (4x4x3 = 48 points/instance, 10704 total) and `nodes` alone for VND
(shallow/fixClose are read by `CbcHeuristicVND::solution()` for reporting
only -- confirmed by code inspection and by direct testing that VND's actual
result is identical across all `--shallow` values -- so only `nodes` was
swept: 3 points/instance, 669 total), `--sec=5` per point (bounds the
worst case; a RINS/VND call that needs more than 5s to explore up to 1000
sub-MIP nodes is not "early-node-friendly" regardless of what it might
eventually find):

**RINS**, found-rate and median relative improvement (`(incumbentObj -
newObj) / |incumbentObj|`) by parameter combination, out of 223 instances:

| shallow | fixClose | nodes | found | found-rate | median relImprove | avg time |
|---|---|---|---|---|---|---|
| 0 | *(any)* | 50   | 71 | 31.8% | 20.3% | ~0.4s |
| 0 | *(any)* | 200  | 85 | 38.1% | 27.8% | ~0.6s |
| 0 | *(any)* | 1000 | 85 | 38.1% | 35.1% | ~0.8s |
| 1 or 3 | *(any)* | 50   | 68 | 30.5% | 26.2% | ~0.4s |
| 1 or 3 | *(any)* | 200  | 82 | 36.8% | 30.9% | ~0.65s |
| 1 or 3 | *(any)* | 1000 | 84 | 37.7% | 34.9% | ~0.8s |
| 2 | *(any)* | any  | 0-2 | ~0% | n/a | trivial |

Three clear, previously-unverified findings:

- **`fixClose` (the close-fix fallback distance) has *zero* measurable
  effect** on this instance set at this node budget -- found-rate and median
  improvement are identical across `fixClose in {0.0, 0.2, 0.4, 0.6}` for
  every `(shallow, nodes)` combination (only wall time varies slightly,
  `fixClose=0` being marginally cheaper since it skips the fallback scan
  entirely). The exact-agreement fixing pass alone already saturates what's
  achievable here; the close-fix heuristic earns its keep on some other
  instance/regime, not on this early-node RINS-fixture population.
- **`shallow=0` (fix all agreeing columns, the CLI default) is the best or
  tied-best choice at every node budget** -- modes 1/3 (fix only at original
  lower bound) are a close second (fewer columns fixed -> occasionally a
  slightly *larger* median improvement per found solution, e.g. 34.9% vs
  35.1% at nodes=1000, but a consistently *lower* found-rate). **`shallow=2`
  (fix only AWAY from original lower bound) is nearly useless on this set**
  -- not a bug, just a direct consequence of most agreeing integer columns
  in these MIPLIB-style instances already sitting at their original lower
  bound (typically 0 for binaries), leaving almost nothing for mode 2 to fix.
- **`nodes=200` already captures nearly all of the found-rate gain of
  `nodes=1000`** (85/223 either way, for `shallow=0`) at roughly 25-30% less
  time; the extra node budget mainly pays off in finding a *better* solution
  when one is found (median relImprove 27.8% -> 35.1%), not in finding one
  more often. For a strictly early-node/cheap-heuristic budget, `nodes=200,
  shallow=0, fixClose=0` is the standout default -- as good a hit-rate as any
  richer setting, at close to the lowest cost measured.

**VND vs. RINS**, head-to-head at `nodes=200` (VND's `shallow` is a no-op;
RINS at `shallow=0, fixClose=0`):

| | found | of 223 |
|---|---|---|
| RINS | 85 | 38.1% |
| VND | 72 | 32.3% |
| both found | 72 | -- |
| RINS-only | 13 | -- |
| VND-only | **0** | -- |

**VND is not a good replacement for RINS at early nodes on this set**: every
single instance where VND found an improvement, RINS also found one (often
the *same* objective value -- median improvement among double-successes is
identical to 4 significant figures), and RINS additionally succeeds on 13
instances VND misses entirely. VND's average time (534ms) is marginally
lower than RINS's (603ms), but not by enough to offset strictly worse
coverage. At `nodes=1000` VND's found-rate plateaus at 32.3% (no further
gain over 200), confirming this isn't just a node-budget-starvation effect.

**Bound-propagation headroom (`--probe-report`, default params, all 223
fixtures)**: 93/223 instances (42%) show `CglProbing` fixing at least one
*additional* integer column beyond RINS's own exact-agreement pass, before
any sub-MIP solve happens. The gains are concentrated but occasionally
huge -- `savsched1` (+990 columns, on top of RINS's own 215626/280152),
`neos-3555904-turama` (+986/18762), `satellites2-40` (+935/32998),
`neos-1445765` (+811, 38% of its 2143 integers -- the largest *relative*
gain measured). Confirms, at full scale, the smaller earlier sample's
finding that a probing-based propagation pass right after RINS's exact-match
fixing (and before delegating to `smallBranchAndBound`) is worth
prototyping for real on a meaningful fraction of instances -- still not
wired into production code; see the `--probe-report` section below for the
measurement methodology and its caveats.

## Replaying / sweeping -- `test/rins-bench`

```sh
cd Cbc/test
./rins-bench 10teams                          # one point, RINS defaults
./rins-bench 10teams --shallow=1 --fix-close=0.2 --nodes=1000
./rins-bench 10teams --method=vnd              # try VND on the same fixture
./rins-bench 10teams --probe-report            # bound-propagation experiment (see below)
./rins-bench 10teams --sweep                   # built-in shallow x fixClose x nodes grid
```

Each point: loads the fixture (warm-starting the LP, same as `mip-root-replay`),
builds a fresh `CbcModel`, installs the incumbent via `setBestSolution()` +
`setSolutionCount(1)` (the exact precondition `CbcHeuristicRINS::solution()`'s
"new incumbent" gate checks), attaches one `CbcHeuristicRINS` (or
`CbcHeuristicVND`) instance configured with `--shallow`/`--fix-close`/
`--nodes`/`--frac-small`, and calls `heuristic->solution()` directly -- the
exact call `CbcModel`'s own search loop makes (`heuristicValue` seeded from
`model.getCutoff()`, matching `CbcModel.cpp`'s own convention), just without
the surrounding tree.

Reports, per point: `nFixExact` (the number of integer columns whose LP value
agrees with the incumbent under RINS's own tolerance and `shallowDepth_`
filter -- computed independently of the real class, purely for visibility into
why the size-gate `5*nFix > numberIntegers` passed or failed) out of
`numberIntegers`, whether a solution was found, its objective/improvement over
the incumbent, and wall time.

`--sweep`'s grid: `shallow` in `{0,1,2,3}`, `fixClose` in `{0,0.2,0.4,0.6}`,
`nodes` in `{50,200,1000}` -- 48 points per fixture, each a few milliseconds,
so a sweep across the whole fixture set is a batch-script's worth of work, not
a benchmarking campaign. On `bell5`, for example, `shallow=1`/`3` roughly
double the improvement `shallow=0` finds at the same 200-node budget (the
close-fix fallback and continuous-fixing thresholds don't move the needle
there since the exact-agreement count alone already clears RINS's gate) --
exactly the kind of result this tool exists to surface quickly.

### Testing VND as a RINS replacement

`--method=vnd` swaps in `CbcHeuristicVND` on the identical fixture (same
incumbent, same fractional LP, same `--shallow`/`--nodes`/`--frac-small`
knobs it shares with the base `CbcHeuristic` class) so a side-by-side
comparison never has to control for anything but the heuristic itself. VND
predates RINS in this codebase and shares its "fix by agreement with the
incumbent" fixing loop (`solutionFix`), plus its own step/decomposition
machinery (`stepSize_`/`k_`/`kmax_`) -- `--method=vnd` does not expose those
yet; add flags analogous to `--shallow`/`--fix-close` if a VND-specific sweep
needs them.

### Checking whether more bound propagation would help -- `--probe-report`

RINS's own sub-MIP solve already benefits from some bound propagation (fast
MILP preprocessing -- singleton tightening + knapsack backtracking, 100
rounds -- inside `smallBranchAndBound`, see `doc/rins-parameters.md` §4.4).
`--probe-report` measures, on top of RINS's *own* exact-agreement fixing pass
(replicated standalone, not touching the real heuristic call), how many
*additional* variables `CglProbing` can fix purely through bound propagation
before any sub-MIP solve happens at all -- a cheap, apples-to-apples way to
answer "would stronger bound tightening let RINS work with an even smaller,
faster sub-MIP".

Measured results across the small fixture set generated for this tool's own
validation (`--nodes=1000`, defaults otherwise):

| instance | RINS exact-agreement fix | probe found additional |
|---|---|---|
| `10teams` | 1402 / 1600 | **+198** (every remaining free column) |
| `gesa2_o` | 631 / 720   | +25 |
| `p0201`   | 155 / 183   | +27 |
| `vpm2`    | 94 / 119    | +13 |
| `gesa2`   | 659 / 720   | +13 |
| `p0282`   | 168 / 202   | +8 |
| `p0033`   | 17 / 32     | +6 |
| `noswot`  | 74 / 95     | +2 |
| `bell5`   | 31 / 52     | +0 |
| `stein45` | 7 / 45      | +0 |

`10teams` is the standout: probing alone collapses the *entire* remaining
198-column sub-MIP after RINS's own fixing pass, on a fixture where RINS
itself found no improvement in this run. That is a concrete signal that
adding a probing-based propagation pass right after RINS's exact-match fixing
(and before delegating to `smallBranchAndBound`) is worth prototyping for real
-- either the sub-MIP becomes small enough to solve exhaustively fast, or (as
here) it collapses to nothing and RINS can skip the sub-MIP call altogether.
Most other instances see a smaller but still real reduction (a handful to a
few dozen extra fixed columns); `bell5`/`stein45` saw none in this sample --
not every instance benefits, which is itself useful to know before wiring
this into production code.

**Not wired into `CbcHeuristicRINS.cpp` itself** -- this is a standalone
measurement, matching the "prove it before touching production code" stance
`BENCHMARKING-CUT-GENERATORS.md` takes for cut generators. Before acting on
this, sweep it across the full fixture set (not just the 10 instances above)
and weigh the extra `CglProbing` call's own cost against the sub-MIP time it
saves.

## Workflow for a RINS/VND parameter experiment

1. `./gen-rins-fixtures` once (see above) to populate the fixture set.
2. Iterate: `./rins-bench <instance> --sweep` per instance, or drive your own
   grid/script over many instances the same way `compare_benchmarks.py` /
   `stats_analysis.py` do for full-suite runs -- each point costs milliseconds.
3. Judge changes the same way heuristics always should: primal bound found
   (and how much better than the incumbent it started from) versus sub-MIP
   size/time -- never raw fix-count alone (a huge fix count that leaves no
   improving move is not "better", it's just conservative).
4. Confirm any change that looks promising with the full `mip-sanity-data`
   suite (`./test`, `./compare-results`) before trusting it -- a fixture-level
   win on a handful of instances is a hypothesis, not a result.
