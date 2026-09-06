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

**Known gap vs. full CLI fidelity:** `CbcStrategyDefault::setupHeuristics()`
attaches a smaller, fixed heuristic set (rounding + a diving heuristic) than
the full `cbc` command line's default configuration, which
`babExecuteSearchAndPostprocess` in `CbcSolver.cpp` assembles heuristic by
heuristic from dozens of individually-toggled CLI options (feasibility pump,
RINS, local search, ...). For root-processing experiments that specifically
compare *cut generator* strategies this does not matter (cuts are unaffected);
for heuristic-strategy experiments that need exact CLI parity, extend
`ReplayStrategy::setupHeuristics()` in `mip-root-replay.cpp` to add the
specific heuristics under study.

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
