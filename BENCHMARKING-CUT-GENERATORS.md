# Benchmarking and improving a cut generator

A process document, written after doing this end-to-end for `CglBKClique`
(clique separation + clique extension). It generalises: nothing below is specific
to cliques except the fixture *payload*, and the parts that are clique-specific
are called out as such.

The point of the process is to make the iterate–measure loop cheap and the
verdicts trustworthy. Both had to be earned:

- **Cheap:** every experiment used to cost a full CBC run to reach the point where
  separation happens. Offline fixture replay brought that to milliseconds, which
  is what made a 7-way strategy sweep over 237 instances a five-minute
  question instead of an afternoon.
- **Trustworthy:** the first four "results" this process produced were all
  artifacts — load noise, a probe measuring the wrong graph, a strategy change
  confounded by downstream work, and a binary that never linked the change. Each
  of those has a named guard below. Assume your first measurement is wrong until
  it survives them.

Read `AGENTS.md` for build/test mechanics and `CLAUDE.md` for machine-local
traps. This file is only about the measurement methodology.

---

## 0. The one-paragraph version

Dump a fixture at the exact point the generator runs (preprocessed matrix +
optimal LP basis + whatever auxiliary structure the generator consumes), replay
it offline in a standalone benchmark, and judge changes by **bound improvement on
reoptimizing** — never by cut count. Prove any claimed equivalence by comparing
*every* output field as strings across the whole fixture set. Time only serially,
min-of-N. Then confirm with the full 471-instance suite before committing.

---

## 1. Metric hierarchy — decide this before measuring anything

Ranked, most to least meaningful. This ordering settled several questions where
the weaker metrics pointed the wrong way:

1. **Bound improvement on reoptimizing (`objImprove`)** — apply the cuts, re-solve
   the LP, take the objective delta. This is the only metric that answers "did
   the generator help". Definitive.
2. **Summed violation of generated cuts (`totalViol`)** — a cheap proxy, useful
   for ranking within a round, but a cut can be violated and useless.
3. **Time** — see §5 for how to measure it without fooling yourself.
4. **Cut count** — *weakest, and actively misleading.* Never rank by it, never
   compare it against zero.

Why cut count is a trap, concretely: pivoting strategy `off` produced **3,860**
cuts vs `weight`'s 4,939 — 22% fewer — yet reached 90% of `weight`'s bound
improvement, while `degree` produced *more* cuts than `off` and delivered *less*
bound. And `mdegree` produced 4,121 cuts to `weight`'s 4,939 while losing 25% of
the bound. Cuts are inputs; the bound is the output.

**`objImprove` is a difference of two LP bounds, so never read it against zero.**
Both operands carry the LP's absolute scale, so a fixture with objective 1e9 has
noise far above one with objective 1.0. Use a scale-relative test — the harness
exposes `objImproveRel` and a boolean `boundMoved` (`objImprove > 1e-9 * scale`)
precisely so "found no cuts" (a legitimate 0) is distinguishable from "moved the
bound by an amount indistinguishable from noise".

One more trap in aggregation: a `-nan` gap or objective *will* appear somewhere in
a 237-fixture set (`neos-3226448-wkra` has one). Coerce with a NaN guard before
summing, or one instance silently poisons every total.

---

## 2. Fixtures: dump once, replay forever

### What to capture

A fixture must pin down everything that determines the generator's behaviour at
the call site. For a cut generator that is:

| file | contents | why |
|---|---|---|
| `.mps.gz` | preprocessed matrix, `formatType 2` (IEEE hex) | exact double round-trip; plain MPS loses bits and the LP then lands elsewhere |
| `.bas` | optimal LP basis at the call site | so the replay starts from the same LP vertex, in 0 iterations |
| `.sol` | objective + column values | cross-check, and reduced costs for generators that use them |
| `.ctype` | integer/continuous per column | **MPS cannot express a fixed integer** — a `lb==ub` integer column reads back continuous, which silently changes the problem |
| `.meta` | rows/cols/density/objValue/`lpOptimal`/generator knobs | lets a driver filter fixtures without loading them |
| *generator-specific* | e.g. `.cgraph` for clique generators | see below |

The first five are **generator-agnostic** — reuse them verbatim. `~/instances/
miplib/2017+spp/preProcessedInstances/` already holds 357 `.mps.gz` + 354 `.bas` +
354 `.sol` from an earlier generation of this work, and
`~/instances/miplib/2017+spp/clqsepFixtures/` holds the 237 `sep` fixtures with
everything above. A new generator needs only its own auxiliary payload.

### Do not rebuild derived structures — serialize them

This is the single most important fixture decision, and it was measured, not
assumed. For cliques: CBC builds the conflict graph *before*
`CglCliqueStrengthening` deletes and adds rows, and then never invalidates it,
because `OsiSolverInterface::checkCGraph()` only rebuilds when the **column**
count changes. On `P1` the row count goes 304,432 → 43,748 with the graph pointer
unchanged. A fixture that rebuilds the graph on load therefore replays a graph
CBC never used — `trdtaunimep` 191,028 vs 190,900 direct conflicts. Cut counts
happened to match on all 11 instances checked, which is exactly why this is
dangerous: the cheap check passes and the fixture is still unfaithful.

Generalisation: **any structure CBC computes once and caches is a candidate for
this bug.** Serialize it byte-exactly and add a `--rebuild-<thing>` flag that
keeps the old behaviour, so the two paths can be compared rather than argued
about.

### Where to dump

At the one point where matrix, LP solution/basis, and auxiliary structure are
*simultaneously* consistent. For separation that is right after
`currentPassNumber_++` in `CbcModel.cpp`, gated on
`currentPassNumber_ == 1 && !node && !parentModel_` — root, first pass, before any
cut has been applied. One pass later the matrix has grown rows and the LP has
moved.

Keep all of it behind an `#ifdef` (`CBC_DUMP_CLQSEP_FIXTURE`), off by default, so
the shipped binary carries nothing. `Cbc/src/CbcClqFixtureDump.hpp` is the
template — header-only static functions, one entry point
`cbcDumpClqFixture(si, tag, ...)`. Everything except the `.cgraph` line is
reusable as-is.

**Skip, and say so loudly.** Many instances yield no structure at all (no
conflicts, in the clique case). Log one line per fixture with sizes, distinguishing
`DUMPED` / `SKIP (reason)` / `PARTIAL`, so a driver can tell "nothing to capture"
from "the dump failed". Also skip anything not replayable — e.g. graph node count
≠ 2 × columns.

**Gate the skip on the generator's own precondition, not on a previous
generator's.** It is tempting to reuse an existing fixture set, and for the first
five files that is right. But the *population* it selected is not: `clqsepFixtures`
exists only where a conflict graph does, whereas `CglZeroHalf` keys off integer
coefficients and cares nothing about binary conflicts. An instance of pure general
integers with no conflict graph at all is a perfectly good — possibly hard —
ZeroHalf case, and reusing the clique population would have silently excluded 121
of 358 instances and biased every measurement that followed.
`CbcZeroHalfFixtureDump.hpp` gates on whether `refreshSolver()` would find any
usable row instead, and records that count in the `.meta` so a driver can tell
"nothing to do here" from "the capture failed" without loading the model.

**A dump budget is not a solve budget.** The dump point is inside the cut loop, so
an instance whose *root LP alone* exceeds the time limit never reaches it and
writes nothing at all — which looks like a dump failure and is not. At 300 s per
instance, 87 of 358 came out that way, and they are exactly the large hard models
worth having. So order the driver largest-first, make it resumable on the presence
of the `.meta`, and plan a second pass at a much larger budget for the remainder;
`.claude/local/cutgen-harness/gen-zh-fixtures.py` does all three. Note also that
the dump is compile-gated while `CPPFLAGS` is empty in `Cbc/src/Makefile`, so
`make CPPFLAGS=-DCBC_DUMP_..._FIXTURE` adds the define without replacing
`CXXFLAGS` (which carries `-O3 -march=haswell` and would otherwise vanish). Build
it to a separate binary and restore the normal one afterwards — a dump-enabled
`cbc` writes fixtures on every solve.

### Basis gotchas worth pre-empting

- **A name mismatch makes a basis silently inert.** If the MPS was written with
  generated column names (`C0000000...`) and the `.bas` carries real ones,
  `readBasis` skips entries and *returns success*. The replay then starts cold and
  the LP lands somewhere else. Verify a loaded basis costs **0 dual iterations**;
  that is the real check.
- **`OsiClp` caches `basis_` and it shadows the model.** Call
  `setWarmStart(NULL)` then `resolve()` to refresh from the model.
- **`resolve()`, not `initialSolve()`** — presolve discards the basis.

---

## 3. The replay benchmark

One binary per generator, in `Cbc/test/`. `bkclique-bench.cpp` is the working
template; `coefstr-test.cpp` is the minimal in-tree example of a C++ test binary.

Emit **one CSV row per run** with a `--header` mode. That shape is what makes the
driver scripts in §4 trivial and lets every comparison be a string diff. The
clique bench emits 29 columns; the ones that generalise:

```
name,<knobs...>,rowsAdded,totalCuts,totalViol,maxViol,avgCutLen,sepTime,
warmStartTime,warmStartIters,resolveTime,resolveIters,
objStart,objEnd,objImprove,objImproveRel,boundMoved,cutsPerRound,violPerRound,objImprovePerRound
```

`warmStartIters` earns its place: it is how you notice a broken basis (see above).
The `*PerRound` columns expose whether round 2+ contributes anything.

Expose every knob you might sweep as a flag (`--rounds=`, `--max-calls=`,
`--pivoting=`, `--ext-method=`), plus a `--quiet` that prints only the CSV row.

**A control that disables the expensive stage is the highest-value flag you can
add.** `--ext-method=0` disables clique extension while leaving everything else
untouched, so `sep@4 − sep@0` isolates extension exactly. That one flag is what
found the real bottleneck in a single sweep — extension was 90.2% of all
separation time and >99% on every slow fixture. Build the equivalent for your
generator before you start optimizing.

Two measurement hazards to encode *in the tool*:

- **Watch for monotonic ratchets.** `CglBKClique.cpp:311` does
  `maxCallsBK_ = bk->numCalls()`, shrinking the generator's own budget after every
  call. A multi-round benchmark must construct a fresh generator per round or
  re-assert the budget, else later rounds silently get less. Any sweep over such a
  parameter must use `--rounds=1` or it measures the ratchet, not the parameter.
- **Bound work by count, not time.** `generateCuts` shrinks its budget again when
  `0 < maxSeconds_ < 30`. Leave time limits at 0 for reproducibility.

Add a `--self-test` that round-trips the serialized structure: `save`, `load`,
`save` again, `cmp` the two files, then compare every field and every element
against the original. Must be *identical*, not close.

---

## 4. Proving a change is exactness-preserving

Many worthwhile optimizations are meant to change nothing but time. Claiming that
is easy; proving it costs one script and is non-negotiable.

Compare **every** output field as **strings**, across **all** fixtures:

```python
for k in ("totalCuts", "objImprove", "totalViol", "maxViol",
          "avgCutLen", "objEnd", "boundMoved"):
    if a[F[k]].strip() != b[F[k]].strip():
        diffs.append(f"{name}: {k} {a[F[k]]} -> {b[F[k]]}")
```

String comparison, not `abs(x-y) < eps`: a tolerance hides exactly the small
drifts that indicate you changed which cuts get generated. `.claude/local/cutgen-harness/cand-cmp.py` is the working
example.

**Also test the paths that only *look* unaffected.** When gating a computation on
a flag, run the settings where the gate is *true* and confirm they are identical
too — that is what proves the gate condition itself is right, not merely that the
default path survived. For the modified-degree gate that meant 4 extra modes ×
237 fixtures = **948 runs**, all byte-identical. Reading the code said the same
thing, but the code had a genuine second reader (`CoinCliqueExtender`, extension
methods 3 and 5) that only turned out to be harmless because it reads the *full*
graph rather than the induced subgraph being gated. Cheap insurance against that
kind of reasoning error.

Fixtures where the generator finds **0 cuts are a free control**: they never enter
the changed code, so any movement there is proof of measurement noise. `cvs16r128-89`
served exactly that role — it "regressed 48%" while finding 0 cuts, which is what
exposed the parallel-harness timing problem below.

---

## 5. Timing: the trap that produced three false findings

**Never time under a parallel harness.** The 12-way comparison script gave:
`eilA101-2` baseline ranging 2.21–3.53s across runs; five fixtures apparently
1.5–2.5x *slower* from a change that only ever removes work; and a "0.91x overall
regression" for a gate that removes a computation and is 1.01x when measured
properly. All noise.

Use the parallel harness for **correctness** (§4), where every run is compared to
its own pair and load cancels. Use a **serial, min-of-N** harness for time:

```sh
python3 .claude/local/cutgen-harness/cand-serial.py 5   # serial, min of 5 reps
```

Min, not mean: load only ever *adds* time, so the minimum is the least
contaminated estimator. `.claude/local/cutgen-harness/` holds this and every other script below,
with a README mapping each to the trap it guards against.

**Rank by absolute time on the slow tail, never by share or by aggregate.** A 99%
share of a 3 ms fixture is worth nothing. Separation time was extraordinarily
concentrated — top 1 fixture 40.3%, top 4 82.6%, top 16 93.8% of 8.5s — so a
per-fixture table sorted by absolute time is the only view that matters, and a
15-fixture serial harness covers essentially all of it.

**Two more ways a timing comparison lies:**

- **A probe that builds a different structure than the real path.** A standalone
  probe estimated `computeModifiedDegree` at 0.95s on `eilA101-2`; the real number
  is ~19 ms. The probe built the **full** conflict graph, while the real call site
  computes on `ppcg`, the small *induced subgraph*. If a probe and the real path
  disagree by 50x, trust neither until you know why.
- **Changing a strategy to isolate a cost.** Comparing `--pivoting=mdegree`
  against `--pivoting=degree` to price the exact computation gave a *negative*
  total delta — because changing the strategy changes which cliques are found, so
  downstream extension cost (>99% of time) swings and swamps the signal. Only an
  A/B at *fixed* settings, where every other output is byte-identical, isolates a
  cost.
- **The first read of a large fixture is page-cache cost, not separation cost.**
  A 57 MB ZeroHalf fixture reported `sepTime 9.757` on its first replay and
  **0.048** on every run after, on the same binary. Read cold that looks like a
  200x discrepancy against the serial harness and invites a hunt for a linking
  problem that is not there. A min-of-N harness discards it for free; a
  hand-run one-off does not, so run any spot check twice and use the second.

**Past ~20 s, more repetitions buy nothing.** Repetition exists to reject
scheduler noise, which is tens of milliseconds — below the reporting precision of
a fixture that takes minutes. `--reps=5` on a 30-minute baseline fixture spends
two and a half hours refining a digit that will not move. `zh-serial.py` stops
after one rep once a fixture exceeds 20 s, and five where it matters.

**A bench's own bound measurement can dwarf what you are measuring, and then it
sets the price of every repetition.** On `chromaticindex1024-7` the Gomory replay
takes ~17 minutes, of which `sepTime` is **23.6 s and `resolveTime` is 1010 s** —
the LP re-solve with 21,729 cuts of average length 701, i.e. 96% of the wall. Two
consequences, and the second is the expensive one:

- **Read the field, not the wall clock.** A 17-minute replay looks like a
  catastrophic outlier and says nothing whatever about the generator.
- **A serial min-of-3 costs an hour and a half to measure 70 seconds of work,**
  which is how a fixture ends up timed under load instead — and that is exactly
  how the false regression below was manufactured. `gomory-bench --no-bound`
  skips the re-solve, turning a 17-minute rep into ~25 s; the whole min-of-3
  then runs in 2.5 minutes. It reports `objImprove` as no movement by
  construction, so it is for timing only and warns on stderr every time.

**A "regression" on one fixture is a contention artifact until proven serially,
and the bench prints its own control.** `chromaticindex1024-7` measured `sepTime`
23.65 → 40.87 = **1.73x slower** in a run overlapping the validity sweep. But
`resolveTime` — *identical code in both builds* — moved 1016 → 1396 = 1.37x in
the same run, which is the tell: a field that cannot have changed, changing.
Re-measured serially with `--no-bound`, min-of-3, nothing else on the machine:
24.73 → 23.81 = **1.038x**, a mild *speedup*, with rowCuts 21729 and totalViol
44523.41954 identical on all 6 reps. When a fixture disagrees with the rest of the
population, look for a field in the same row that acts as an invariant before
believing the number.

**Report the slow tail as its own row.** An aggregate TOTAL is dominated by
whichever single fixture is worst, so it flatters a change that fixes exactly one
instance. A separate "fixtures over 1s" subtotal is what answers "did the slow
cases get faster", which is usually the actual question: for the ZeroHalf
group-by, TOTAL read 12.76x while the ten slow fixtures read 20.10x and the worst
single fixture read 0.99x — on 6.8 ms, i.e. noise.

---

## 6. Confirm on the real solver before committing

Fixture replay is one call at the root. It cannot see interactions with branching,
other generators, or cut management. So:

```sh
./.claude/local/run-suite --baseline   # before (or reuse /tmp/baseline.tsv)
./.claude/local/run-suite --after      # after; auto-compares
```

**Judge by PASS count and confirmed optima.** `compare-mip-sanity-results` exits 1
on *any* gap movement including pure noise; a non-zero exit is not by itself a
correctness failure. The harness runs `-threads 1 -sec 120`, which is wall-clock
dependent — the *baseline* binary alone yields bounds of 2173.28 then 2117.97 on
`misc07` across repeat runs. To settle one instance, re-run it under a fixed node
limit with **no** `-sec`, where before/after agree exactly. That is how `pk1` was
settled: at a fixed 20,000-node limit the baseline alone yields 3.34643 / 3.40616
/ 3.9845, bracketing the changed binary's 3.41647.

**And an identical node count is not evidence of an identical search when the run
stopped *on* the node limit** — the counts match because the limit is the stopping
rule, so the agreement is trivial while the bound reached by that node is still
wall-clock dependent. The Twomir run made this concrete: of the 9 instances whose
gap moved, **8 had byte-identical node counts** and different final bounds, which
reads like a deterministic behavior change and is not one. Re-run at a fixed
`-maxNodes` with **no `-sec`** and `-threads 0`; all 9 then agreed on objective
*and* lower bound to every printed digit. One of them, `markshare_4_0`, had looked
alarming — gap `0.0000% → 1539320000000000.0000%` — purely because its bound moved
from exactly `0` to `-4.55e-13` and the gap formula divides by it.

Also: `run-suite` must be run against a binary that actually contains the change.
`./build` does not descend into `Cbc/test/`, and a make-built test binary links
the **installed** CoinUtils/Cgl/Clp/Osi — see `CLAUDE.md`. `cmp` two binaries: if
they are byte-identical, the change was not linked, not "had no effect".

---

## 7. Deciding whether an idea is worth building at all

The clique exercise's headline result is a *negative* one, reached before writing
any of the code the hypothesis called for. Two cheap questions, in this order:

**(a) Is the signal any good?** The premise was that a cheap approximate modified
degree would help BK find more violated cliques. Sweeping all 7 pivoting
strategies over 237 fixtures ranked modified degree **last**: `weight` (CBC's
default) 157,991 Σ`objImprove` vs `mdegree` 118,159 (0.748x). Only 20 fixtures
differ at all, and `mdegree` wins on *exactly one*. A faster way to compute an
inferior ranking is still inferior — hypothesis closed, no implementation needed.

Sweep the existing alternatives before optimizing one of them. If a strategy knob
already exists, the sweep costs one script.

**(b) What is the ceiling if it were free?** Gating the computation out entirely
measured 1.01x overall, 1.03x on the worst fixture (~19 ms of 733 ms). That 19 ms
is the *entire* prize for any faster version. Measure the ceiling before
designing the optimization.

Check robustness to a single dominant instance. `trdtaunimep` alone was 40,485 of
`weight`'s 157,991, so the aggregate could have been one fixture — re-total
without it (117,506 → 116,908, same verdict) and count per-fixture wins/losses
(better on 1, worse on 19).

Record negative results as first-class findings. "Do not re-investigate X" is
worth as much as a speedup, and the alternative is rediscovering it.

---

## 8. Worked summary — what this produced for `CglBKClique`

| step | finding |
|---|---|
| Control flag (`--ext-method=0`) | extension is 90.2% of separation time, >99% on every slow fixture |
| Instrumentation | `eilA101-2` issued **9.77M** `conflicting()` calls to keep 568k candidates, of which only 512 per clique survive |
| Fix | verify candidates in cost order and stop at the cap — selects the identical set, since `CompareCost` is a strict weak ordering |
| Exactness | **byte-identical** on all 237 fixtures, every field |
| Speedup (serial, min-of-5) | `eilA101-2` **2.99x**, 2.00x over the 15 fixtures that matter |
| Suite | 471/471 PASS, 324 confirmed optima, unchanged |
| Budget sweep | `maxCallsBK_=1000` already captures 99.9% of the bound available at 100x the budget — raising it is a dead end |
| Negative result | modified-degree pivoting is *worse* than the default and costs ~1% — the original hypothesis is dead |

Ruled out and recorded: 64-bit BK bitsets (identical output, no gain);
`maxInducedSize_` (not binding); the BK recursion itself (~0.015s); disabling
extension (it earns the bound: `objImprove` 6.598 at method 4 vs 0.627 at
method 0).

### And for `CglZeroHalf`, following the same recipe

| step | finding |
|---|---|
| Stage profiling | the `REDUCTION` duplicate-row scan is **63%** of separation time overall, 83–98% on the slow tail — 14.0 billion inner iterations on `neos-4532248-waihi` |
| Fix | its own comment called it a "very trivial implementation": an O(mr²) ordered-pair scan for a group-by. Bucket by a hash of the equality fields, compare only within a bucket |
| Exactness | all 22 non-timing fields byte-identical over **885 of 896** fixtures (330 producing cuts) |
| Speedup (serial, min-of-5) | slow tail **20.10x** (212.77s → 10.59s), best single fixture **370.8x**, worst 0.99x on 6.8 ms |
| Whole solve | `neos-3402294-bobin` ZeroHalf 16.7s → **0.176s**, same 337 cuts at the same density |
| Validity | Osi row-cut debugger against proven optima on the 19 instances where ZeroHalf actually cuts: **0 violations** |
| Suite | 471/471 PASS, 324 confirmed optima, unchanged |
| Negative result | the O(cnt³) pair-weakening stage — the *original* hypothesis — is only 6.1% aggregate and ≤0.8% on any slow fixture. Dead |

The transferable lesson is the order of operations: the pair-weakening stage was
the obvious suspect from reading the code, and pricing it with a control flag
(`--max-pairs=0`) before optimizing anything is what stopped a week of work on a
0.8% stage. §7 exists for this reason.

Also worth carrying forward: reproducing a loop that **mutates its own guard
while iterating** needs the semantics derived explicitly, not eyeballed. Here that
meant three separate facts — only rows active on entry participate, the survivor
of a class is the *last* row attaining the minimum slack, and classes are
independent — each of which changes the output if got wrong. They were checked
against a literal transcription of the old loop on 40,000 randomized instances
with heavy slack ties and pre-deleted rows *before* the C++ was written, which is
far cheaper than discovering it from a fixture diff.

### And for `CglProbing`

| step | finding |
|---|---|
| Two cut kinds | first generator here emitting both `OsiRowCut` and `OsiColCut`, so the gate compares 28 fields; a change preserving only one kind still fails |
| Stage profiling, level 1 | `probeCore` is **98%** of generator wall (median 94% per fixture). A location, not yet a target |
| Levels 2 and 3 | `probeCore` → `wayCuts` 70.4% → `rowCutGen` 99.5% → **`upRows` 98.4%**, i.e. one loop is ~69% of the whole generator on `neos-4532248-waihi` |
| Counters inside the loop | `guardPass` 100%, `gapLoScan` 98.6% (**1.72e9** full row scans), `cutBuilt` **0** |
| Fix | row activity at `colsol` is loop-invariant — `colsol`'s last write precedes the probe nest. Cache it lazily per row |
| Exactness | all 28 fields byte-identical over **292** fixtures (107 row cuts, 27 column cuts, 172 neither as noise controls) |
| Speedup | **1.24x** over the slowest 40 of 339 fixtures; **1.26x** on the 15 over 1 s; **1.23x** on the 19 that find no cuts at all. Best 6.21x (`neos-2075418-temuka`, zero-cut), then 3.19x, 3.06x, 2.82x, 2.57x; worst 0.98x |
| Whole solve | `-passC 1 -maxNodes 1`, no `-sec`: `neos-3402294-bobin` probing 0.157s→0.059s (0 cuts both), `trdnc` 0.325s→0.203s (864 cuts both); lower bound identical on both |
| Negative results | five targets picked by reading the code, all dead: `tighten()` (0.08–0.53%), the `skipGenIntColCuts` save/restore (0.08–0.39%), candidate selection + sort (0.11–0.53%), skipping clean bound restores (99.9% are genuinely dirty), and hoisting the strengthening block on `ifCut` (`ifCutTrue` = 0 on every fixture) |

Four transferable lessons, three of them new:

**Profile until you reach a loop, not until you reach a function.** `probeCore` at
98% is a true measurement that identifies nothing actionable — it is most of the
generator by construction. The finding only became a change at level 3.

**Nested levels need their own array and their own remainder.** Shares must be of
the enclosing level; summing a child alongside its own parent double counts. The
first version of this instrumentation made exactly that mistake. Use RAII scoped
guards for sub-timers, too — regions inside loops that `continue`/`break` cannot
use hand-placed END calls.

**Entry counts are not iteration counts.** `downRows` and `upRows` recorded
identical entry counts (86836) while differing **3950x** in iterations, because one
loop's bound is capped and the other's is not. Count both, or the asymmetry that
is the whole finding stays invisible. And at 1e9 scale use **counters, not
timers**: a `CoinWallclockTime()` pair costs more than the body it measures.

**One fixture is not a profile.** Across 9 slow-tail fixtures one stage ranged
13.6%→96.8%, and one fixture inverted the leader's picture entirely. §5's warning
about ranking by absolute time applies to attribution as well as to timing.

A fixture-production lesson worth carrying: when an instance yields no fixture,
suspect **root heuristics** before the time budget. The dump fires after
preprocessing and the root LP, so an instance can clear both and still never reach
the capture point — `scpj1` spent 2400s at 0 nodes and 0 LP iterations, and dumped
in 38s with `-heuristicsOnOff off`. Record the resulting shape change in the
`.meta` (no incumbent → infinite cutoff), because a fixture that is infinite for
that reason is otherwise indistinguishable from one that found no incumbent.

### And for `CglGomory`

| step | finding |
|---|---|
| Fixture precondition | first generator here where the `.bas` is **required, not provenance**: `needsOptimalBasis()` is true and the cut *is* a row of the tableau at that basis, so two optimal bases of one degenerate vertex give different valid cuts. A nonzero `warmStartIters` makes a replay incomparable, not merely noisy |
| Stage profiling | the dense nonbasic-column loop, 80–97% of separation on the fixtures first sampled |
| Why it is safe to skip columns | the BTRAN result's dense array is exactly 0.0 off-index, so an untouched column's alpha is exactly 0.0 and the loop's own `fabs(value)<1.0e-16` already discards it. Checked with a stray-nonzero counter, not assumed: **0** on every fixture |
| Fix | scatter through the row copy over the `numberInArray` nonzero rows, mark the columns reached, skip the rest — **gated** on a cost comparison both sides of which are known before either is paid |
| Speedup (serial, min-of-3) | slow tail (10 fixtures over 1 s) **12.39x**, 11.01x over 20; best `neos-2075418-temuka` 175.6s → 6.4s = **27.27x**, then 28.19x on `tutaki`; worst `scpl4` 0.0774s → 0.0857s = 0.90x, i.e. **8 ms** absolute — the gate holds losses to noise |
| Exactness | **331 fixtures, 0 differences**: every cut coefficient as exact IEEE hex (`--dump-cuts`, `%a`) plus every non-timing CSV field. ~11.3M coefficients, 49,728 row cuts and 30 column cuts. Column cuts are in the comparison because a Gomory cut over one column is a *bound*, so a row-only check would miss a class of change |
| Validity | Osi row-cut debugger against proven optima on the instances where Gomory actually cuts: **`OK=172 VIOLATION=0 RESTART=10 SKIP=43`** over all 225 where it fires at the root. Since the change is bit-identical this is evidence about `CglGomory` itself, not about the change |
| Negative result | **the unconditional form of the same fix is a 100x regression** (`scpm1` colLoop 0.139s → 15.23s) |
| False alarm, resolved | `chromaticindex1024-7` read 1.73x *slower* under load; serially it is **1.038x faster**. See the contention trap in §5 — `resolveTime` moved in the same run, and it cannot |

Three lessons, all of them about measuring rather than about Gomory:

**A sparse rewrite of a dense loop is not automatically a win, and the losses are
enormous.** Net saving as a fraction of dense element count ranges from +0.9994 to
**−202** across 56 fixtures. The `scp*`, `eil*` and `square*` families lose because
their tableau rows are dense enough that nearly every column is touched anyway, so
the scatter is pure overhead on top of a walk that still happens. What makes the
gate exact rather than a guess is that *both* costs are computable in advance:
Σ`rowLength` over the nonzero rows against Σ`columnLength` over nonbasic-movable
columns, the latter loop-invariant. Ship the gate, and check the distribution is
bimodal so the threshold is not load bearing.

**Instrumentation inside the loop you are measuring lands in the residual, not in
the stage.** A 90–97% "unattributed" residual (`scpn2`: total 185.8 s, stages
summing 5.57 s) was entirely the profile build's own sizing block, which is
O(numberRows + rowSupport) *per candidate* — 9.26e9 element visits on `scpm1`.
Being outside every timed *stage* is not the same as being outside the loop. The
consequence was worse than a wrong percentage: it put `scpn2` and `scpm1` at the
top of the slow tail when their true separation times are ~4.3 s and ~1.6 s, so
the ranking that drives everything downstream was wrong. Time the enclosing loop
as its own region and require `stages + instrumentation ≈ loop`, or the residual
tells you nothing about where it lives.

**Know the floor before quoting a ceiling.** The outer loop over all
`numberColumns` cannot be made sparse without changing which cuts are produced —
`if (number>limit) break;` makes the visit order decide the cut, and `rhs`
accumulates across it — so its cost bounds any exactness-preserving speedup. That
bound is a median **21%** of the inner element work and on 11 of 327 fixtures the
outer loop *dominates* (`cvs16r128-89` 69x, `chromaticindex1024-7` 1.3x, where
both builds exceed a 300 s cap identically). Compute that floor from the `.meta`
before optimizing, so a fixture that cannot improve is not mistaken for the change
misfiring.

And a third instance of the same mistake, which is why §5 says it twice: the
three-fixture sample that justified building this reported ratios of 2.75x–147x;
the population is **0.32x–1740x**. The same three fixtures also put the outer loop
at 0.6–1.4% when the median is 21%. Two wrong conclusions from one convenience
sample.

### And for `CglTwomir`

| step | finding |
|---|---|
| Fixture precondition | the `.bas` is required as it is for Gomory, **plus two preconditions no other generator here has**. `freeColumns > 0` makes `generateCuts` return at `CglTwomir.cpp:118` with no cuts at all — so the Gomory population cannot be reused wholesale. And `twomirCandidates == 0` is **not** a valid skip, unlike Gomory: `do_form_` builds bases from formulation rows and needs no fractional basic integer. A Gomory-shaped skip would have silently dropped 3 formulation-only fixtures |
| Population scan, before touching the generator | **85 of 357** instances keep TwoMir alive past the first root pass. 168 never add the row to the generator table at all; 102 add it and are then killed by `setSwitchOffIfLessThan(1)`. Conflating "row absent" with "row present, 0.00 s" would have put the population at 187 |
| Sizing gate (§5) | 30 instances ≥ 1.0 s (needs 15), population total 202.9 s (needs 60 s), top-20 = 161.8 s = **80%** of it (needs 50%). All three pass, so the optimization is in scope. Those are parallel-harness times and are quoted only as a *gate*, never as a result |
| Stage attribution without instrumentation | `setCutTypes(mir, twomir, tab, form)` partitions the generator into four independently gateable stages, so the four floors come from flags rather than from a profile scaffold. `--no-tab --no-form` is the per-call floor (`DGG_getData`, empty emit loop, `DGG_freeData` — **no `CoinFactorization` is built at all**, it is local to `DGG_generateTabRowCuts`); `--no-mir --no-2mir` sets `t_max = t_min-1` / `q_max = q_min-1` so the loop bodies never run while factorization and every `DGG_getTableauConstraint` still do, isolating exactly the tableau-row cost |
| Why it is safe to skip columns | the same claim as Gomory's, at a **1.0e-12** threshold rather than 1e-16 (`CBC_CHECK_CUT` is defined at `CglTwomir.hpp:341`), which makes a stray value *more* likely to survive the filter, not less. Measured with a stray-nonzero counter over **333 fixtures**: 9,125,148,323 skipped columns examined, **0 with alpha exactly nonzero**, 0 surviving the filter, worst \|alpha\| among the skipped **exactly 0.0**. The loose threshold turns out not to be load-bearing at all |
| Fix | scatter through the row copy over the `numberInArray` nonzero BTRAN rows, stamp the columns reached, skip the inner element loop for the rest — gated on `4·scatter < dense` with both sides known before either is paid, `dense` cached per call because it depends only on the basis. `-DCGL_TWOMIR_DENSE_COLLOOP` restores the original |
| The gate is exercised in both directions | 245,536 scatter calls against 68,108 dense calls; **100 fixtures take both branches**, 146 are all-sparse and 93 all-dense. Without that split a "0 differences" exactness result would not distinguish a correct gate from a gate that is constantly false |
| Speedup (serial, min-of-3) | slow tail (5 fixtures over 1 s on base) **1.98x**, **1.95x** over the 30 hottest (39.73 s → 20.32 s); best `neos-4647030-tutaki` 0.696 s → 0.052 s = **13.30x**; hottest `trdcrooms` 19.68 s → 8.62 s = 2.28x while emitting the same 4945 row cuts; worst `neos-933966` 1.00x and **nothing below 1.00x**; median 1.51x, 25 of 30 at ≥ 1.2x. `rowCuts_n`, `colCuts_n`, `objImprove` and `warmStartIters` matched on all 30 — a speedup on a changed cut set is not a speedup. Measured on an idle machine with BLAS threads pinned (see the trap below) |
| Exactness | **333 fixtures × 4 stage configurations, 0 differences, 223,152 cuts compared**: every coefficient as exact IEEE hex (`--dump-cuts`, `%a`) in generation order, both row and column cuts, plus every non-timing CSV field as a string (58 of 61, the three timing columns dropped **by name**). Default 108,194 cuts / `--no-form` — the tab stage, where the fix lives — 98,252 / `--no-tab` 16,706 / `--no-mir --no-2mir` **0**, a pure noise control that by construction compares nothing and is reported as such rather than counted. The `2mir_test:` line count was 0 on both sides in all four. One fixture is **not** in that count: `z26` exceeds 900 s per side *identically* on both binaries, and it is outside the addressable population anyway (`twomirPresent = 0`, so CBC never separates it) |
| Validity | Osi row-cut debugger against proven optima over every instance where Twomir emits row **or** column cuts: of 216 derived instances, **`OK=164 VIOLATION=0 RESTART=8 SKIP=44 OTHER=0`**. Report the coverage split or a pass count overstates itself: **142 of the OKs actually exercised TwoMir cuts, 70,780 cuts checked**; the other 22 are zero-coverage passes where the TwoMirCuts row was absent from the run. The 44 SKIPs are 38 "the reference is the relaxation, not a feasible point" and 6 "feasible reference, fixed LP infeasible after preprocessing"; a SKIP is never a pass. **`nu25-pr12` ran and passed with real coverage** (`OK twomirCuts=168`) — the instance that matters, since the roundoff guard at cpp:414-420 exists because a TwoMirCuts cut on it once excluded the certified optimum by ~1.14e-6. Because the change is bit-identical, this is evidence about `CglTwomir` itself, not about the change |
| Negative result | **three of the four fixtures that did not speed up are cases where the gate refused the scatter**, not cases where the change failed: `neos-933966` took 4 scatter calls against 1571 dense, `satellites2-60-fs` 33/927, `mcsched` 0/1259. Without those per-call branch counts all three read as the change misfiring. The fourth, `comp07-2idx` (1303 scatter / 0 dense, 1.04x), is **not** explained — two candidate mechanisms were measured and both refuted: its tab stage is essentially 100% of its runtime, so no other stage dominates, and 77.3% of its candidate columns *were* skipped, a **higher** selectivity than `buildingenergy`, which gained 2.34x. Recorded as unattributed rather than given an unmeasured mechanism; it is a 0.1 s fixture and immaterial to the aggregate |
| Regression suite | **500/500 PASS and 330 confirmed optima on both sides**, 0 failures, 0 errors, 0 overtime. `compare-mip-sanity-results` still exited 1, on 4 wider and 5 narrower gaps; all 9 were settled to exact agreement at a fixed `-maxNodes` with no `-sec` and `-threads 0`. Judge by PASS count and confirmed optima, as §6 says |
| False alarm, resolved | `markshare_4_0` reported its gap widening from `0.0000%` to `1539320000000000.0000%`. Same 90913 nodes, same objective 7, `is_optimal = 0` on both sides: the bound moved from exactly `0` to `-4.55e-13` and the gap formula divides by it. The 8 same-node-count cases are covered by the trap in §6 |

Twomir-specific traps, each of which would have produced a wrong number or a
wrong write-up:

**A generator can be disabled before it can cost anything, and the scan must say
which.** `switches=1` maps to `setSwitchOffIfLessThan(1)`, so 0 row cuts on the
first root pass sets `whenCutGenerator_ = -100` and `nextRunStr` reports
`"disabled"` for the rest of the solve. That is a *different fact* from a row that
was never added, and the two differ by 102 instances here. Record `twomirPresent`
and the verbatim `Next run` string separately, and parse
`printGeneratorTable` (`CbcOutput.cpp:2160-2207`) — the legacy
`"was tried %d times and created %d cuts"` string survives only in
`Cbc/src/Attic/CbcSolver.cpp` and will never match.

**Two unconditional `printf`s, and their count is evidence.**
`2mir_test: why does constraint not exist ?` at `CglTwomir.cpp:1588` and an
unprefixed copy at :1637 are not debug-gated. Filtering them before `cmp` is
obvious; **comparing how many were filtered** is the part that matters, because a
change in that count is itself a behavior change. On this population it is 0 on
every fixture in every configuration.

**`setAway`/`setAwayAtRoot` silently ignore out-of-range values rather than
clamping** (`if (value>0.0&&value<=0.5)`, cpp:2248-2263). A bench that echoes its
own variable will report `awayAtRoot 0.6` while the generator ran 0.005. Echo the
getter. The same shape bites `setFormulationRows`, whose `form_nrows_` is written
and never read — the generator uses `info.formulation_rows`, so the setter is dead
and the `--self-test` asserts that it is.

**A default can live in another generator's `#ifdef`.** `awayAtRoot = 0.005`
rather than 0.01 only because `#define MORE_CUTS` sits at
`CbcSolverCutSetup.cpp:139`, inside the *Gomory* block, and is never `#undef`'d.
Deriving the fixture's `cbc*` values by reading Twomir's own constructor would
have got this wrong by 2x.

**`--pass=0` is the only comparable call, for three independent reasons.**
`max_elements` becomes `getNumCols()` at pass 0 (cpp:297-303) and 250 or 50000
never applies; `do_tab_` is additionally gated on `info.level < 1 && info.pass < 6`
(cpp:314), so pass ≥ 6 is a structurally *different* call rather than a cheaper
one; and the kill switch judges exactly this call, so the population defined here
is the population that survives. A replay bench with `--rounds>1` must warn when
the effective pass reaches 6.

**`TWOMIR_LESS_MALLOC` cannot be used as an A/B control** — `intVar` is declared
at cpp:761 inside the `#ifdef` and used at :802 outside it, so the off state does
not compile. And `#undef DGG_DEBUG_DGG` at cpp:31 kills every `#if DGG_DEBUG_DGG`
block despite hpp:250 defining it 1, which makes `DGG_isConstraintViolated`
(2134-2153) dead twice over: every branch returns 0 *and* its only caller is under
the `#undef`.

**"Serial" timing is not serial if the bench links a threaded BLAS.**
`twomir-bench` pulls in `libopenblas.so.0` through Clp, and a single run measured
**372% CPU** — the LP resolve is multi-threaded even when the harness runs one
fixture at a time. `sepTime` brackets only single-threaded Cgl code so the metric
itself is sound, but the wall-clock around it is not reproducible unless BLAS
threads are pinned. Pin them, and keep timing off a machine running anything else.

**A whole-solve scan and a single-call bench measure different quantities — not
the same quantity at two noise levels.** The scan's `twomirTime` is what the
generator spent across the entire solve; the bench's `sepTime` is one root pass-0
call. On this population the two differ by far more than contention could explain:
`trdcrooms` 40.7 s scanned against 19.68 s serially, `academictimetablesmall`
2.08 → 0.20, `trdnc` 1.80 → 0.058. Ranking the hot set by scan time is
therefore legitimate, and is exactly what the sizing gate does — but quoting a
scan *magnitude* as a separation cost is not, and the two must never be
differenced. That is why the gate row above says its numbers are a gate and never
a result.

**The floor is `outerLoopWork`, and the ratio to it is a ceiling — not a
pass/fail test.** The emission contract is that structural entries appear in
increasing `j`, and `CoinSort_2` at cpp:1099 re-sorts **only the slack tail**, so
the `for j < ncol` sweep must stay dense and ordered; only the inner element loop
may be skipped. `tabRowWork / outerLoopWork` is therefore the headroom, and it
reduces algebraically to `nonbasicStructuralNz / cols` — the mean number of
nonzeros per nonbasic structural column (verified identical on all 334 fixtures,
so either form may be quoted). Read it as a rough ceiling of **`1 + ratio`**, in
units where visiting an element and testing a column cost the same, which they do
not. It is **not** the case that a ratio below 1 means the fixture cannot improve:
`chromaticindex512-7`, at **0.751** and the second most expensive instance in the
population, gained **1.37x** against a ceiling of about 1.75x. Publish the
distribution from the `.meta` before quoting any ratio, but compare each fixture
against its own ceiling rather than against 1.

**Known defect, held out of the speedup and then measured separately.**
`DGG_add2stepToList` shadows its loop variable `i` (1918 / 1940 / 1947),
truncating the alpha search to exactly one candidate — so
`best_rc_alpha == best_norm_alpha` always, and :1953-1957 compares that one
candidate against `COIN_DBL_MAX`. Fixing it changes which cuts are produced and
fails every exactness gate by construction, so it became its own experiment
judged on `objImprove` (below), never folded into the speedup. The same reasoning
still retires the `DGG_CHECKRVAL(rval, rval)` leaks at :1803/:1814/:1830/:1841
and the double `DGG_build2step` at :1935/:1959: real, but fixing them under cover
of a perf change misreports the change.

#### The 2-step alpha search, as its own experiment

The first cut-set-changing experiment in this document, so the metric hierarchy
of §1 does the deciding rather than an exactness gate. Kept strictly after the
bit-identical work was green, and in its own commit.

| step | finding |
|---|---|
| The defect, quantified before being judged | `DGG_build2step` copies every element of `base` unconditionally, so `cut->nz == base->nz`; after the inner scoring loops `i == base->nz`, the outer `i++` goes past the bound and the loop exits. Giving the inner loops their own `j` changes the emitted cut in **8,576 calls, 30.70% of the 27,939 productive ones** — of 201,771 total, since 173,832 build no candidate at all and are unaffected. Quantifying the blast radius first is what made the objImprove result interpretable |
| One of the two selection rules cannot fire, and reading the code does not show it | `rc_val = rhs · min_j(\|rc_j\|/coeff_j)` is a valid lower bound on the objective improvement the cut forces, and the code minimizes where bigger is better — an inverted bound. But the `> 1E-6` gate passed in **0 of 293,767 candidates and 0 of 27,939 productive calls** over 333 fixtures. The cause is not the sign of `rhs` (positive in 65.66%): the minimum itself is **0 in 92.44%**, because the row's own pivot column is admitted by `\|\| j==index`, is basic so its reduced cost is 0 by definition, and always receives `tau·rho ≥ DGG_MIN_RHO`. `rhs > 0 AND min > 0` holds in **exactly 0**. So the inversion is real and moot, and V1 (fix) against V2 (fix + maximize) is **333/333 bit-identical**. A rule that has never selected cannot be validated by measurement — ship the existing direction, put the other behind `-DCGL_TWOMIR_ALPHA_RC_MAX`, and say why |
| The surviving rule's approximation is better than the exact criterion | minimizing `Σ_{coeff>1E-6} coeff²/(rhs²+1)` maximizes `rhs/\|\|coeff\|\|`, the violation distance, with two departures: negative coefficients (which `DGG_build2step` does emit) are omitted from the norm, and the `+1` distorts scale for small `rhs`. Scoring the exact distance instead (`-DCGL_TWOMIR_ALPHA_DIST`) is **worse: 6 better, 14 worse**, −**3.78** once the single largest mover is excluded, +4.09%/6 against −**27.43%**/14 scale-free, and it reverses the fix's five best wins almost one for one. **REJECTED.** "The formula is mathematically wrong" was a false lead; the approximation correlates better with realized bound improvement |
| Result **in isolation**, on the replay bench | one CglTwomir call against one stored root LP. `objImprove` over 333 fixtures: **19 better, 9 worse, 305 unchanged**, total +12.37, **+4.87 excluding the largest mover** (`50v-10`). Scale-free the wins sum to **+82.70% against −8.74%** of losses — **9.5x** — best `d05100` **+36.96%**, worst `bupa.sc` −2.99%. Winners are the set-covering and knapsack families. `rowCuts_n` +58, reported and never ranked by |
| Result **in a real solve**, which is what governs the claim | the root dual bound after CBC's whole root cut loop, `cbc -maxNodes 1`, over all **500** mip-sanity instances, so branching plays no part: **identical 222, better 84, worse 82**, plus 51 proved-at-root (bound incomparable) and 61 where TwoMir is never reached. Over the 166 comparable movers, as a share of the root cut loop's own gain: mean **−0.52%**, median **+0.003%**. A coin flip. So the shipped claim is **correctness fix, measured-neutral on dual bound** — not the improvement the isolated number suggests |
| Why the two disagree, and it is not noise | the bench measures TwoMir alone against one LP; in a solve its cuts compete with seven other generators over as many as **100 passes**, so a locally better 2-step cut changes what Gomory/Knapsack/MIR find next. Splitting the movers on whether either side hit that cap separates the regimes cleanly — **pass-capped n=133: 65/68, mean −1.27%, median −0.044%**; **converged n=32: 18/14, mean +2.61%, median +0.583%**. Where the loop stops by its own criterion the fix is mildly positive (`rout` +29.6%, `nu25-pr12` +20.1%, three `cttp_hard` +15…21%); where it is truncated the bound records where the trajectory happened to stop |
| Regression suite | **500/500 PASS on both sides**, 330 → **335** confirmed optima, with `./build` on each side. Reported, not leaned on — see the cliff trap below: 14 instances gained proven optimality, 11 lost it, and **all 25 sit on the `-maxNodes = 3 × calibrated_nodes` cliff** |
| The proxy pointed the other way | `totalViol` moved **−370 while `objImprove` rose**, and on the rejected variant **+219 while it fell**. Two independent instances of the pre-resolve proxy contradicting the metric that decides, in one experiment. Use it to explain, never to choose |
| Composing runs instead of paying for one | `objImprove` is **bit-reproducible per (binary, fixture)** — CglTwomir reads no clock — verified as 0 mismatches on the shared column across two independent 333-fixture runs. So `base → dist` was composed from the `base → fix` and `fix → dist` logs rather than costing a third ~40-minute run |
| Validity | re-run in full, because here the verdict **is** evidence about the change: `OK=163 VIOLATION=0 RESTART=8 SKIP=44 OTHER=1` over the same 216 instances. **`nu25-pr12` — the instance the cpp:414-420 roundoff guard exists for — improved**: `twomirCuts=191` and optimality **proven** at obj=53905, where the pristine tree emitted 168 and did not prove it |
| Cost, bounded before it was measured | every guard before `DGG_build2step` is a `continue`, so the 173,832 calls that build no candidate scanned the full `base->nz` before the fix and cost the same after it. Only productive calls pay more: **~272k additional `DGG_build2step` + scoring passes** at O(nz ≤ 500), roughly 1e8 element visits across the whole population. Then measured, serially on a verified-idle machine: **66 fixtures 37.6939 → 37.5940 s = 1.00x**; the 40 fixtures whose cut set changed 9.6374 → 9.8386, **+0.2012 s, 0.98x**. The predicted O(nz) → O(nz²) is real and invisible, because `base->nz > 500` is rejected outright at cpp:1592 |

**The suite's confirmed-optima count is a tree-shape statistic, not a bound
measurement.** `limits.tsv` sets `-maxNodes = 3 × calibrated_nodes`, so every
instance whose node count is within 3x of its calibration sits on a cliff, and
**any** change to the cut set flips a batch of them — in both directions at once.
Here 14 gained proven optimality and 11 lost it, and all 25 are on that cliff:
`mod008` is capped at 18 nodes with a baseline of 6, and `p0201` is capped at 132
with the after-run terminating at exactly 132. The +5 net looked like the
headline result and is not a result at all. **The fix is to measure the root
bound instead**: `cbc <mps> -sec N -maxNodes 1 -solve` prints

```
✔ Cut generation complete — N cuts, obj A → B in P passes
```

where `B` is the dual bound after the root cut loop. It is the suite-side
analogue of the bench's `objImprove`, it does not depend on branching at all, and
because cuts only ever move the bound one way, `sign(B − A)` identifies the
improving direction per instance without needing to know the objective sense.
`.claude/local/cutgen-harness/suite-rootbound.py` runs it over both binaries.
Deliberately parallel — these are bound *values*, not timings — but never quote a
time out of it, and re-run solo any instance whose root loop was long enough for
`-sec` to truncate it.

**An instance that finishes at the root has no comparable root bound, and the
number CBC prints for it is nonsense.** Once the incumbent is known the root LP
carries a cutoff constraint; if it goes infeasible that *proves* optimality, and
the reported post-cut bound is garbage. `rcpsp_n8_r2_s137` reads
`obj 21.8226 → 142873` on the pristine tree against a true optimum of **32**, and
`gt2` reads 23145.8. Both binaries return the optimum on both. Taken at face
value that one row was a −142838 "catastrophe" and single-handedly dominated the
aggregate; it is in fact the fix *replacing* a nonsense bound with a plausible
35.49. **Filter on the result line, not on the magnitude** — 51 of 500 instances
are in this class here, and a magnitude filter would have kept the sign backwards
while looking principled.

**A pass-capped bound moves chaotically, so partition on the cap before reading
the aggregate.** CBC's root cut loop stops at 100 passes. On the 133 instances
that hit it the fix is 65 better / 68 worse; on the 32 that converge it is 18/14
with a median of +0.583%. Same change, same metric, and only the second group is
measuring cut quality — in the first, the final bound is an artifact of where the
trajectory was interrupted. `gesa2` goes 26 → 100 passes and `gesa2_o` 100 → 28
under the same edit, which is the mechanism visible in one line of output.

**Min-of-N does not protect a serial timing run from sustained load.** This
generalizes §1's "never time under the parallel scripts": the *first* clean-looking
serial run here reported **1.04x overall with a 1.37x outlier**, taken while a
500-instance root-bound sweep was still running at 8 workers. Re-run on a verified-
idle machine the same comparison is **1.00x** and the outlier is gone. Min-of-3
removes transient spikes and cannot remove a contended machine, because every rep
is contended. Check the machine is idle *before* the run, not the variance after
it. **The noise floor comes free if the population contains bit-identical
fixtures**: the 26 fixtures whose cut set did not change pay every extra
`DGG_build2step` pass and emit the same cuts, so they can only be slower — they
came out **1.01x faster**, which fixes this measurement's own floor at ~1% and
puts the real +0.2012 s cost at or below it.

**Prove a baseline binary's provenance by `cmp`, not by remembering how you built
it.** These builds are bit-reproducible, so the A/B pair is checkable in one step:
save the candidate binary, revert the source, build the baseline, restore the
source, rebuild, and `cmp` the rebuild against the saved candidate. Byte-identical
means the baseline really was built from HEAD and the two binaries differ in
nothing else. Both canaries passed here; the check costs one extra `./build` and it
is the difference between an A/B and a story about an A/B. Note also that
`run-suite` never rebuilds `libCbc`, so an "after" run without `./build` silently
solves against the pristine binary.

**A `*-validate-cuts` verdict is wall-clock limited, so a class change between two
batch runs is not by itself evidence about the code.** The harness runs
`mip-debug-cuts` at a 600 s limit with `JOBS=5` and `--threads=1`, so how deep a
solve gets — and therefore whether it ever reaches CBC's *aborting* debugger check
— depends on machine load. Exactly one instance moved here, `supportcase7`
`OK → rc=134`, and it looked like a violation the change had introduced. Run
**solo under both binaries**, the pristine tree aborts too, with a
**byte-identical invalid-cut stream**: 718 reports, the first
`(580th in this go, pass 1)`, every one `Cut generator 0 (Probing)` and none
TwoMir. Two further attributions come free from that stream: 80 of the violations
are at **root pass 1**, where Probing (generator 0) runs *before* TwoMir and no
TwoMir change can reach them; and the cut is invalid only against a **dirty
reference** — `col 4599 coef=-94687 knownVal=8.994209762e-08` gives LHS
−0.0088987 against `lb=-5.8e-11`, and the `.sol` carries 103 nonzero entries
below 1e-6 in 965 lines. Re-run solo and `cmp` the streams; it settles in one
step what three repeat batch runs could not.

**Note also that `[pre-resolve check]` prints without aborting.** It is a
diagnostic at `CbcModel.cpp:11190-11245`; only CBC's own check aborts. So a run
can log hundreds of reference violations and still exit `OK`, and the two facts
must be read separately — the count of printed violations is not the verdict.

### And for `CglMixedIntegerRounding2`

| step | finding |
|---|---|
| The fact the whole exercise rests on | **CBC runs this generator with `MAXAGGR_ == 1`, which makes its documented aggregation dead code.** `CbcSolverCutSetup.cpp:341` constructs `CglMixedIntegerRounding2 mixedGen(1, true, 1)`, and the `setMAXAGGR_` at :344 is guarded by `if (mixedRoundStrategy != 1)` while `mixedRoundStrategy_` **defaults to 1** (`CbcSolver.hpp:206`, re-asserted `CbcSolver.cpp:10926`). So the `iAggregate` loop runs exactly once with `iAggregate == 0` and takes the `if` arm at :880: `selectRowToAggregate` (:1124) and `aggregateRow` (:1209) are **never called**, and the restore loop at :1051 (`for jAggregate=1; jAggregate<MAXAGGR_`) runs zero times. A plan built by reading the generator's aggregation is a plan built on code CBC never executes |
| What that makes removable | **`matrixByCol` has no reader.** It is built unconditionally at :195 as `CoinPackedMatrix matrixByCol(matrixByRow,0,0,true)` — a full O(nnz) transpose with two fresh allocations, on every call — and all four of its consumers (`selectRowToAggregate` at :904 and :1170-1183, the two `SAFE_ROWS` blocks at :925-928 and :1057-1060) sit in the `else` arm at :897 or in a `< MAXAGGR_` loop starting at 1. Provably dead, not probably dead: the exactness argument is structural. `matrixByRow` at :193-194 is the same shape — `submatrixOfWithDuplicates(*si.getMatrixByRow(), numRows_, indRows_)` where `indRows_[iRow] = iRow` (:627), i.e. a full O(nnz) copy to build an identity submatrix |
| `SAFE_ROWS` is defined in the .cpp, so "dead" means one thing only | `#define SAFE_ROWS` is at **cpp:400**, inside the translation unit itself — so those blocks *are* compiled in, and their deadness rests **entirely** on `MAXAGGR_ == 1`, not on a build flag. Of the six `#ifdef SAFE_ROWS` sites (:401, :481, :567, :870, :923, :1051), **:481 and :567 are LIVE**: they are inside `mixIntRoundPreprocess` and save row types into `rowTypes_ + numRows_`, which is why `rowTypes_` is allocated at 2×`numRows_`. Reading "SAFE_ROWS is dead" off the `MAXAGGR_` argument and deleting all six would corrupt the row classification |
| Fixture precondition | the `.bas` is required, **but not for a factorization** — unlike Gomory and Twomir, MIR2 has no `needsOptimalBasis()` override and builds no `CoinFactorization`. It is required because `mixIntRoundPreprocess` reads `si.getRowActivity()` (:502) to resolve every range `'R'` row into G or L (:505-518), so the captured LP point decides `sense_`, `RHS_`, the row types and therefore the whole starting-row set. A Gomory-shaped "no basis needed" shortcut would have silently changed the algorithm's input |
| The only structural skip | **`startingRows == 0`**, i.e. `rowsMix + rowsContVB + rowsInt == 0`, which makes the outer loop at :854 run zero times. There is no `freeColumns`-style early return as in Twomir and no fractional-basic-integer precondition as in Gomory, so the population is larger than either. **It is a pass-0 property and only a pass-0 property**, for a reason worth stating: `numRows_ = si.getNumRows()` (:459) and `info.formulationRows` is never read, so from pass 1 on MIR2 classifies the *cuts other generators added* along with the formulation, and a single `ROW_MIX` cut row lifts `startingRows` above zero. Checked against the **complete** set of counter-evidence rather than a sample, which matters because the first example encountered was also the weakest: of the 27 pass-1 skips, exactly **5** are credited with cuts over a full solve — `neos-807456` 10, `irp` 9, `enigma` 7, `enlight_hard` 7, `nw04` 1, i.e. **34 cuts between them** — and at `-passC 1` **all five produce 0 cuts**. So every apparent violation of the precondition is explained by the pass-0 mechanism, with none left over |
| Why the sign flip cannot change that set (a plausible worry, killed by reading) | The `MODIFY_LP==2` branch negates every pure `>=` row before the separating call, which negates every coefficient and swaps `numPosInt`↔`numNegInt` and `numPosCon`↔`numNegCon` in `determineRowType` (:722-813). Every classification arm is invariant under that swap composed with 'L'↔'G': `ROW_MIX`, `ROW_CONT` and `ROW_INT` depend only on the invariant sums `numInt`/`numCon`, and the variable-bound ternary inverts with the sense (`numPosCon == 1 ? ROW_VARUB : ROW_VARLB` under 'L' against `? ROW_VARLB : ROW_VARUB` under 'G'), so a flipped VARUB is still a VARUB. `fabs(rhs)` guards are invariant too. So the flip changes no row type, and a fixture skipped for `startingRows == 0` was not going to acquire starting rows inside the recursion |
| The skip biases the speedup measurement downward, and the direction matters | The skipped instances are the population's **purest fixed-cost probes**: `startingRows == 0` means preprocessing and both O(nnz) matrix copies run and the separation loop then executes zero times, so 100% of their cost is what OPT-A/B/C remove. Over the full pass-1 population **27 instances skip here, carrying 16.75 s** of root MIR2 time — **4.2% of the 400.2 s total, all of it fixed cost by construction** — for 34 whole-solve cuts, **none of them at pass 0**. `eilA101-2` alone is 5.53 s across 50 passes for 0 cuts, i.e. ~0.11 s per call of pure fixed cost; `eilD76.2` 2.09, `ds` 2.02, `eilB101.2` 1.67, `eilC76-2` 1.60 and `supportcase6` 1.04 add another 8.4 s in the same shape. Excluding them means the measured slow-tail speedup **understates** the population effect — the safe direction, but one to state rather than discover later as an apparent inconsistency with the "124 instances produce 0 cuts for 60.5 s" row. **Those two sets overlap; they are not nested**, and the distinction is the same pass-0 mechanism again: 22 of the 27 skips have 0 whole-solve cuts and so sit *inside* that 60.5 s (15.80 s of it), while the other 5 are credited with cuts arising at pass ≥ 1 and so are counted among the 167 cut-producing instances instead. They are swept in the second fixture pass under `--allow-empty-start` (dumper env var `CBC_MIR_FIXTURE_ALLOW_EMPTY_START`) and reported as their own labelled sub-population, held out of the work-class table because `cmirWork == 0` by construction would inflate the `nnzWork` share for a structural rather than a measured reason |
| The 27 skips have **one** cause, not a scattering, and the deciding line is nameable | Worth checking because "no starting row" could be 27 different degeneracies: it is not. **27 of 27** report `rowsMix=0 rowsContVB=0 rowsInt=0` *and* **27 of 27** report zero variable upper and zero variable lower bounds in the entire model. Reading `determineRowType` (:773-806) explains it exactly. All three starting-row classes need something these models lack: `ROW_MIX` and `ROW_CONT` both require `numCon > 0` (:773, :796), and `ROW_INT` requires `numCon == 0` **and** `sense == 'L' || sense == 'G'` (:800). So in a model whose every row is all-integer — `air03`, `air04`, `air05`, `nw04`, `qap10`, `ns1952667` are set partitioning / covering — an **equality** row of integer columns is classified `ROW_OTHER` (:806), not `ROW_INT`, and with `numCon == 0` throughout there is no `ROW_MIX`, no `ROW_CONT`, and hence no `ROW_CONT`-with-a-variable-bound either. `rowsInt = 0` on a pure set-partitioning model looks like a bug in the counter and is not: it is the `sense` test on the `ROW_INT` arm |
| A §7 candidate this turned up, recorded and **not** pursued | An equality row is both `≤` and `≥`, so a c-MIR inequality derived from either side is valid, and classifying `numCon == 0 && sense == 'E'` as `ROW_INT` would hand MIR2 starting rows on all 27 of these instances instead of zero. It is recorded rather than tried because the expected value is low **on this population specifically**: the equality rows here are set-partitioning rows (`Σx_j = 1`, binaries, unit coefficients), where the MIR inequality is dominated by the row itself and adds nothing. It would be worth an experiment only on a population with integer equality rows of varied coefficients, and it is a **cut-set** change, so it would go through the root-bound metric and a fresh `mir-validate-cuts`, never into the bit-identical commit |
| A harness trap the escape hatch introduced, and why the fixture set was never at risk | The `--allow-empty-start` arm of the dumper (`CbcMirFixtureDump.hpp:1155-1172`) prints its probe notice and then **falls through** to write all five files and print `DUMPED`, so such an instance emits **two** `[mirfixture]` lines. `gen-mir-fixtures.py` classified on the **first** one it found, which contains neither `DUMPED` nor `SKIP`, and so labelled every one of them `NONE` — the second pass logged **26 of 27 as `NONE` while all 27 dumps were complete on disk**. Two things make this worth recording rather than just fixing. First, the failure is *invisible in the artifact and visible only in the accounting*: had the TSV been trusted, the probe sub-population would have been reported as 0 instead of 27, and the "27 instances, 16.75 s, 4.2%, all fixed cost" row above would have silently become an unsupported claim. Second, the check that caught it is the one worth generalising — when a log says a dump failed, **look on disk** (`nw04.mir.{bas,ctype,meta,mps.gz,sol}` all present, all non-empty, `allowEmptyStart 1`, `startingRows 0`) before believing it, because the dumper and the log are two independent witnesses and only one of them is the deliverable. Fixed by scanning every `[mirfixture]` line and classifying on the **last** classifiable one: a notice always precedes its verdict, and the three verdicts are mutually exclusive because the `SKIP` arm returns immediately. Final accounting for this sub-population is taken from disk regardless — 27 requested, **27 complete, 0 partial, 0 absent** |
| Fixture population, and the three sub-populations it is deliberately split into | **333 complete five-file fixtures from 357 instances**, in three groups that must not be pooled: **264 plain** (CBC's call reproduced with no deviation), **27 probe** (`allowEmptyStart 1`, the `startingRows == 0` set swept only so the fixed-cost path has coverage), **42 no-heuristics** (`genHeuristics 0`, instances that never reached a cut pass inside the budget until `-heuristicsOnOff off` removed root heuristics — not the budget, which is the trap recorded for Gomory). **Zero fixtures carry two deviations at once**, which was the reason for running the sweeps as separate passes rather than one: an instance given both `--allow-empty-start` *and* `-heuristicsOnOff off` would be a probe measured on a `reducedCostFix`-tightened LP whose row **types** differ, and it would have been pooled into the same table as the plain fixtures. Checked, not assumed: 0 of 333. The **24** instances with no fixture are 21 that produce no dump even with heuristics off (5 of them allocation failures under the 12 GB per-child cap) and 3 that skip on `noStartingRow` **after** the heuristics deviation and are therefore left alone rather than given a second one (`ds-big`, `ivu06`, `neos-3226448-wkra`). Two more were absent for a reason worth recording because reconciliation is what found it and nothing else would have: the retry list was built with **64** of the **66** unique pass-1 `NONE` names, silently dropping `core4284-1064` and `keller4cpart`, so `--only-file` never retried them. Both dumped on the first attempt once actually run (4131 and 24759 starting rows — not marginal fixtures), which is the argument for closing the population by arithmetic (`263 pass-1 DUMPED + 1 resumed = 264 plain`; `264 + 27 + 42 = 333`; `333 + 24 = 357`) rather than by reading a final tally off the last log line |
| Population scan, before touching the generator | **291 of 357** instances put a `MixedIntegerRounding2` row in the generator table; 66 never reach a cut pass at all (`passes=0`, budget spent in presolve and root heuristics). **182 of the 291 report `Next run: disabled`** — and for MIR2 that is *frequency tuning after the root*, not a first-pass veto, because `switches = 0` (see the trap below). Conflating "row absent" with "row present, 0.00 s" would have misstated the population |
| Sizing gate (§5) | 49 instances ≥ 1.0 s (needs 15), population total **400.2 s** (needs 60 s), top-20 = **307.0 s = 77%** of it (needs 50%). All three pass, so optimization is in scope. Concentration: top-1 37%, top-5 56%, top-10 67%, top-20 77%, top-50 89%. Those are parallel-harness times, quoted as a **gate** and never as a result |
| What the population spends on nothing | **124 of the 291 row-present instances produce 0 cuts and burn 60.5 s doing it (15% of the total)**; 36 more produce 1-10 cuts for another 34.8 s, so **95.3 s (24%) goes to instances yielding ≤10 cuts**. Worst cost-per-cut: `bab6` 2.790 s/cut, `bab2` 2.480, `nursesched-medium-hint03` 2.200, `seymour` 1.930. Sharper still, and the figure that actually bears on the optimization: **of the 49 instances in the ≥ 1.0 s hot tail, 19 produce zero cuts and carry 49.24 s of the tail's 356.21 s (13.8%)** — the waste is not confined to cheap instances. 23 zero-cut instances cost ≥ 0.5 s each, totalling **52.04 s = 13.0% of the population**, led by `sts405` 7.52, `v150_d50_2hopCDS` 6.19, `eilA101-2` 5.53, `sorrell3` 3.46, `neos-4763324-toguru` 2.85; **every one of the 23 reports `Next run: disabled`**, so CBC's frequency tuning does eventually switch MIR2 off — after the root cost has already been paid in full. This is the shape that makes a fixed-cost removal attractive before any inner-loop work is considered, and it corroborates the OPT-A/B/C direction *without* depending on the work-class table |
| Work-class distribution, and why it must be time-weighted | `nnzWork` vs `cmirWork` per fixture from the `.meta` (`mir-meta-stats.py`) predicts *which* candidate can help: `nnzWork`-dominated fixtures are OPT-A/B/C (the O(nnz) copies), `cmirWork`-dominated ones are OPT-D (`cMirSeparation`'s O(numInt²)). **Settled on the completed 306-fixture non-probe population, 380.1 s of scan time:** `cmirWork` 83 fixtures / **238.9 s / 62.9%**, `balanced` 176 / 98.9 s / 26.0%, `nnzWork` 47 / 42.3 s / 11.1%. The time shares are **identical to the 260-fixture reading** and that is not a coincidence to be reported as stability: only **2 of the 42 no-heuristics fixtures carry any scan time at all, 0.06 s between them**, because those instances are in that sub-population precisely *because* they never reached a cut pass in the scan. So the last 46 fixtures moved the count column and contributed nothing to the time column — which is the sharpest available illustration of why the two columns must be read separately, and a warning against quoting a class share as "N fixtures, X%" as though the N produced the X. In the 25-fixture hot tail (315.3 s) the split is sharper: `cmirWork` 69.8% (11 fixtures), `balanced` 18.3% (11), `nnzWork` 11.9% (3). **The shares moved a lot as the population grew** — at 15 fixtures they read 80.7 / 5.2 / 14.2 and at 20 they read 72.9 / 15.3 / 11.8 — which is exactly why the partial reading was marked non-actionable rather than published. The distribution inverts the motivating intuition: `bab6` — 3.92 s for **three** cuts, the shape that suggested the fixed-cost copies in the first place — is `cmirWork` at **27,271x** (31.6e9 against 1.16e6, one row with `knapMax=62482`), i.e. an OPT-D case, and `bab2` is worse at **45,308x** with `knapMax=101633`. **But the counter-example is the point:** `neos-848589`, the *second* hottest instance in the population at 32.5 s, is `nnzWork`-dominated with `cmirWork = 1449` and `knapsackIntMax = 1` — its knapsacks hold at most one integer column, so `cMirSeparation` does essentially nothing and its cost is the O(nnz) preprocessing and copies repeated across passes. A class *share* never licenses a claim about an individual instance. `knapsackIntMax` is the cheap predictor: single digits cannot be a `cmirWork` case whatever the row count |
| The ceiling on OPT-A/B, stated before measuring rather than after | Because OPT-A/B remove work proportional to `nnzWork`, the time-weighted `nnzWork` fraction of counted work — **14.1%** — is an upper bound on what they can reach population-wide, and a *loose* one: the two O(nnz) copies are only part of the nnz-proportional cost, and counted work is not measured time. So a modest population-wide figure is the predicted outcome, not a failed change, and the places to look for a real factor are the 47 `nnzWork`-dominated fixtures (42.26 s) and the 27 fixed-cost probes (16.75 s, where the removal is 100% of the cost by construction). Recording this **up front** is the same discipline §5 prescribes for a diffuse cost: the alternative is measuring 1.1x and having to argue afterwards that it was expected |
| Count-weighting and time-weighting disagree, and only one of them is the answer | Whether the `MODIFY_LP==2` deep copy fires at all decides whether OPT-C and OPT-E are visible, and `geRowsToFlip == 0` measures it. **By fixture count 190 of 306 (62.1%) never fire it; by time those are only 139.48 s of 380.12 s (36.7%)** — so the flip path is live on **63.3% of the population's time**, not 37.9%. The count figure was the one to hand and would have understated both candidates by a factor of 1.6. In the hot 25 the gap persists in the other direction: 16 of 25 fixtures have `geRowsToFlip == 0` but they carry only 31.3% of the tail's time. Same rule as the work-class table: weight by time, then say which weighting you used |
| OPT-F, found while proving OPT-C: a whole solver deep copy taken before it is known to be needed | The `MODIFY_LP==2` branch opens with `OsiClpSolverInterface si2 = *clpSolver;` (:126) — a full `ClpSimplex` copy: bounds, objective, row and column activities, duals, and the packed matrix — and only *then* scans for rows to flip. But the scan (:136-143) reads **exactly one array**, `rowUpper`, and the lines between the copy and the scan (:127-134) only fetch pointers and allocate a `bool[numberRows]`, so nothing writes `rowUpper` in between. `nChanged` is therefore a function of `clpSolver`'s **own** `rowUpper`, reachable without the copy and without a cast: `ClpSimplex *getModelPtr() const` (`OsiClpSolverInterface.hpp:1083`) and `inline double *rowUpper() const` (`ClpModel.hpp:563`) both hand back non-const pointers from const methods. And on the `nChanged == 0` path the copy has no other purpose — `grep -n si2` gives exactly three mentions in this branch, `:126` (construct), `:127` (`getModelPtr`) and `:175` (the recursion, which does not run); separation then proceeds on `si` from :185, and `si2` is destroyed at :181. So a full solver copy is built and thrown away to answer one question `clpSolver` could have answered itself. By the row above that is the **190-fixture, 139.48 s, 36.7%-of-population-time** case |
| Why OPT-C and OPT-F are one restructuring, not two candidates | They are **complementary, and together they cover the whole branch**: OPT-C skips the discarded first `mixIntRoundPreprocess` only when the branch *will* recurse (`nChanged > 0` — 116 fixtures, 240.64 s, **63.3%** of population time), and OPT-F skips the deep copy only when it will *not* (`nChanged == 0` — 190 fixtures, 139.48 s, **36.7%**). Neither set is empty and the two partition the root calls exactly, so every root call through `MODIFY_LP==2` gains from one of them. The partition is exact and not merely complementary because the branch's *other* gate excludes nothing here: `getObjSense()==1.0` holds on **all 333** fixtures (`objSense 1` in every `.meta`, checked rather than assumed — a maximization would have shrunk both halves and left a silent remainder). **All 27 fixed-cost probes are OPT-F cases**, contributing their full 16.75 s to the `nChanged == 0` half: every one reports `geRowsToFlip == 0`, `rangeRows == 0` and `rowsOther == rows` with **zero exceptions** — i.e. every row in all 27 models is `ROW_OTHER`, which is exactly the all-equality-rows-of-integer-columns signature and therefore corroborates the `sense == 'E'` reading of the `ROW_INT` arm (below) from a **different counter** than the one that produced it. Both also follow from the *same* edit — hoist the `swap` scan above both the copy and the preprocess block, since its only input is `rowUpper` — which is why the plan's OPT-C restructuring ("compute `swap`/`nChanged` first, then preprocess-or-not, then flip") should be read as delivering both. One thing to **check rather than assume**: a copy constructor may populate the *source*'s mutable lazy caches, so not taking it can move when `*si.getMatrixByRow()` (:191) builds a row copy. That is semantically transparent but exactly the shape that shows up later as a timing shift attributed to the wrong line, so it is settled by the 54-field string comparison at `--level=0`, not by argument |
| Stage attribution comes from a flag, not a scaffold | `--level=-1` reproduces the **inner** call (no deep copy, no sign flip, no recursion, one preprocess pass) and `--level=0` reproduces CBC's own call (everything). The difference is the overhead OPT-C and OPT-E target. It is an **attribution, not a partition**: those are two different calls, not two stages of one, and the bench prints that caveat above the table |
| OPT-D's two exactness hazards, both settled by reading rather than by an assertion run | The plan budgeted an instrumented run to test whether the winning cut's `(setC, numeratorBeta)` survive to the end of `cMirSeparation`. It does not need one; both hazards fall out of the source. **(b) winner state equals final state, by construction.** Each accept in the complT loop strictly increases `maxViolation`, so the last accept is the winner; on accept `setC` keeps its `insert` (:1556) and `numeratorBeta = localNumeratorBeta` (:1574), and on reject `setC.quickAdd(jIndex,-1.0)` (:1577) undoes it while `numeratorBeta` is untouched — so every candidate after the winner is a no-op on both, and if the winner came from the earlier delta scan instead, no complT candidate was accepted at all. **The undo is not representationally clean, and that nearly breaks the argument:** `quickAdd(-1.0)` on a 1.0 entry yields 0.0, which is below `COIN_INDEXED_TINY_ELEMENT`, so `CoinIndexedVector.hpp:218` stores **`1.0e-100`** and leaves the index in `indices_` with `nElements_` still incremented. It is semantically a no-op only because the sole read is `setC.denseVector()[i] != 1.0` (:1775), an **exact** comparison, under which `1.0e-100` reads as "in T" exactly as absence does. Rewriting that test as `!= 0.0` would silently invert it. Two further reasons it is safe rather than lucky: `setC.insert` at :1556 can never hit a present index, because the `if`/`else` at :1465-1476 sends each knapsack position to *either* `setC` or `complT`; and `setC.clear()` (:1458) does reclaim the leftover, since the index is still listed. **(a) purity holds for `cMIR`, `rhscMIR` and `sCoef`, but NOT for `violation`.** `rhscMIR` (:1769) and `sCoef` (:1789) are plain assignments, and `cMIR` is pure for a non-obvious reason: `CoinIndexedVector::setElement` is **positional, not keyed** — `elements_[indices_[index]] = element` (`CoinIndexedVector.cpp:246`) — so it never touches `indices_`/`nElements_`, `cMIR`'s index list is fixed once by `copy(mixedKnapsack)` (:1441), and both branches (:1780, :1786) write all `numInt` positions unconditionally. A recomputation at the end is therefore bit-identical. But **`violation` is never initialized inside `cMirInequality`**: :1778/:1783 accumulate with `+=`/`-=` into the caller's variable, and it is correct today only because all three call sites declare `double violation = 0.0;` immediately before (:1496, :1525, :1557). It is an in/out parameter wearing an out parameter's signature, and an OPT-D restructuring that adds a final materializing call must zero it or silently double-count |
| A trap specific to the OPT-D rewrite | Because `setElement` is positional, the *obvious* correction — writing `cMIR.setElement(knapsackIndices[i], G)` on the theory that the argument is a column index — writes to the wrong slot, or throws `index >= size()` from :242 when the column index exceeds `nElements_`. The existing `setElement(i, G)` is right and the natural-looking fix is wrong |
| Fix | **Four removals, 114 insertions / 31 deletions in 5 hunks, all inside `generateCuts`** — and the insertion count is comment: the executable change is small. **OPT-A** builds `matrixByCol` only when `MAXAGGR_ > 1`, into a local that is then `swap`ped in, so the `> 1` path still runs the identical constructor with no extra copy. **OPT-B** binds `matrixByRow` as a reference to `tempMatrixByRow` when `numRows_ == si.getNumRows()` and falls back to the copy otherwise. **OPT-C** and **OPT-F** come from one hoist: the `nChanged` scan moves to the top of the function and reads `clpSolver`'s **own** `rowUpper` through `getModelPtr()`, which lets the first `mixIntRoundPreprocess` be skipped when the recursion will discard it (`nChanged > 0 && doPreproc_ == 1`) *and* lets `OsiClpSolverInterface si2 = *clpSolver` plus its `bool[numberRows]` move inside `if (nChanged)`, deleting the `else { delete [] swap; }` arm as dead. OPT-D and OPT-E are deliberately **not** here — see Negative results |
| Two details in the fix that are not stylistic | The hoisted count tests `!(rowUpper[i] < 1.0e50)`, the **negation of the block's own test**, not the more natural `>= 1.0e50`: with a NaN bound both comparisons are false, so only the negated form counts such a row exactly as the original block would have and keeps `nChanged` identical on an input no one expects. And asking `clpSolver` for its model is **inert on the source solver** — `OsiClpSolverInterface::getModelPtr()`'s `freeCachedResults()` call is commented out (`OsiClpSolverInterface.cpp:5152`) — which is what makes reading `rowUpper` before the copy free of side effects on `si`'s lazy caches. `getConstClpSolver(&si)` hands back `si` itself via the `dynamic_cast` overload (`OsiClpSolverInterface.hpp:1688`; the pointer-hack twin at `:1671` is under `#if 0`), so the array read is the very one the copy would have duplicated |
| Why OPT-B's guard is the row count and not "is `indRows_` the identity" | `mixIntRoundPreprocess` sets `numRows_ = si.getNumRows()` (:459) and fills `indRows_[iRow] = iRow` (:627) in the same pass, so the two agree whenever it has just run. But the `doneInitPre_` path can leave `numRows_` over from a **shorter** model, and then `submatrixOfWithDuplicates` genuinely selects the first `numRows_` rows of a taller matrix — which a reference would silently get wrong. Guarding on the equality makes the fallback fire exactly when the submatrix is not the identity |
| Why OPT-A needs no conditional locals | the three pointers are formed at :205-207 before `generateMirCuts` is entered, so a default-constructed `matrixByCol` must be safe to read. Checked in the source rather than assumed: `CoinPackedMatrix.hpp:125/135/157/163` are plain inline returns (`return element_;`) with **no assert and no lazy build**, and the default ctor (`CoinPackedMatrix.cpp:1824-1839`) sets `element_(0)`, `index_(0)`, `length_(0)` but `start_ = new CoinBigIndex[1]; start_[0] = 0;`. So `getElements()`/`getIndices()`/`getVectorLengths()` return NULL while `getVectorStarts()` returns a **valid** 1-element array, and forming all three is fully defined |
| Why OPT-B is safe | `submatrixOfWithDuplicates` removes gaps (`CoinPackedMatrix.cpp:770-812`) while preserving within-major element **order** exactly, so binding a reference to the source is only safe if every consumer is gap-tolerant. Audit, re-run before committing: the `matrixByRow` local is read at **exactly two** sites, `matrixByRow.getVector(rowSelected)` (:1101) and `matrixByRow.getVector(iRow)` (:1649), both gap-tolerant. The raw-array reads at :458-464 are on a **different, shadowed** object (`const CoinPackedMatrix & matrixByRow = *si.getMatrixByRow();` inside `mixIntRoundPreprocess`) and pair `rowStarts[iRow]` with `rowLengths[iRow]`, gap-tolerant anyway. Order preservation is what makes the FP summation identical |
| Exactness | SETTLED — bit-identical in **four** configurations, because a guard must be exercised where it is *true*. `mir-exactness` over all **306** replayable fixtures each time (`--level=0`, CBC's own call; `--level=-1`, the inner call where OPT-B and OPT-D live; **`--max-aggr=2`**, the only configuration that turns OPT-A's and OPT-B's `else` branches on at all; `--criterion=2`, the bound-substitution rule CBC hardcodes away): **0 diff-cuts, 0 diff-csv, 0 stray output** in every one, `rc=0` throughout. Cuts and `%a`-exact coefficients compared: 32,312 / 1,330,995 at `--level=0`, the same 32,312 / 1,330,995 at `--level=-1`, **44,146 / 2,239,246** at `--max-aggr=2`, 26,135 / 872,774 at `--criterion=2` — **5,774,010 coefficients per side in total**, every stream `cmp`-identical. Plus `mir-cmp.py` at `--level=0` and `--max-aggr=2`, 51 of 54 header fields with the completeness assertion: "all compared fields byte-identical" both times, and its independently-computed nonzero totals (1,330,995 and 2,239,246) agree with `mir-exactness`'s to the digit. Claim = string equality on every non-timing field **and** `%a`-exact coefficients in generation order; neither half alone is the claim |
| Why the four configurations are not four copies of one run | the cut counts prove each one reached different code, which is the only thing that makes a guard's exactness claim mean anything. **`--max-aggr=2` produced 11,834 MORE cuts than CBC's shape** (44,146 vs 32,312) — aggregation demonstrably ran, so OPT-A's and OPT-B's `else` branches were taken and not merely compiled. `--criterion=2` produced **fewer** (26,135), i.e. a genuinely different `boundSubstitution` path. `--level=-1` produced *exactly* the same 32,312: expected, and a useful internal consistency check rather than a redundancy, because at `--level=0` the outer call flips the `>=` rows and recurses with `level = -1`, so the cuts come from the inner call either way — that configuration's value is CSV coverage of the no-deep-copy, single-preprocess path, not extra cut coverage |
| The 27 fixtures that are not evidence | 333 fixtures exist but only **306** can be replayed. The other 27 have `startingRows 0`, so the loop at :866 runs zero times and no cut can exist; `mir2-bench` refuses them by design and they are in the population only because `gen-mir-fixtures.py` ran with `--allow-empty-start`. The two classes coincide **exactly** — 27 with `startingRows 0`, 27 with `allowEmptyStart 1`, 27 in both — which is the check that the flag is what admitted them. `mir-cmp.py` originally scored them **FAIL**, having no structural-refusal verdict, so it exited 1 on a run with zero differences; it now scores them SKIP, reports "306 of 333 compared", and only counts a no-CSV-row as FAIL when it is **asymmetric** (one binary loading a fixture the other cannot is a real failure and must not be swallowed) |
| Why generation order is load-bearing here | the single insertion point is `cs.insertIfNotDuplicateAndClean(cMirCut, 31, tolTest)` at :1044 with `CoinAbsFltEq tolTest(1.0e-4)` (:865). Which of two near-duplicate cuts survives therefore depends on which arrives **first**, so the cut dump is unsorted and a reordering with the same cut set is a real difference the gate must fail on, not a cosmetic one to normalise away. There is no column-cut half to check: MIR2 emits row cuts only, no `OsiColCut` anywhere in the file |
| Validity | SETTLED — `mir-validate-cuts` over all **128** derived instances (`rowCuts_n > 0` in the pass-0 replay **and** a reference solution present), 600 s each: **OK=79, VIOLATION=13, RESTART=6, SKIP=30**. Arming is not assumed: run under an Osi built with `printActivationNotice = true`, **every one of the 100 non-SKIP verdicts reads `arm=ARMED` and none reads `NOTARMED`**. Of the 13 VIOLATIONs, **exactly one carries any MixedIntegerRounding2 attribution** — `supportcase7`, 525 of its 718 invalid-cut lines — and it is **pre-existing**, settled by relinking `mip-debug-cuts` against base `libCgl.a` and `cmp`ing the streams: all 718 lines byte-identical. The other 12 are `mir2=0`, i.e. cuts MIR2 did not emit. Across the whole audit the invalid-cut lines attribute to just **two** generators, MIR2 525 and Probing 324, and the arithmetic closes: Probing's 324 = 193 on `supportcase7` + 131 across the other twelve, matching their `lines=` sum exactly. Because the change is bit-identical this is evidence about `CglMixedIntegerRounding2` itself, not about the change. A SKIP is never a pass, and OK is an upper bound on the *checked* set, not a pass — see the coverage trap below |
| The exit status was hiding twelve of those thirteen | Only `supportcase7` (rc=134) and `n3div36` (rc=77) exit non-zero. The remaining **12 VIOLATIONs all exit 0** while printing invalid-cut lines, so the first version of this harness — which judged on exit status, exactly as the Gomory, ZeroHalf and Twomir scripts still do — scored every one of them **OK**. The cause is that CBC has two invalid-cut checks and only one aborts (table above); the fix is to take the verdict from an **output scan first** and the exit status second. This is not a MIR2 finding and it is not confined to this generator: the same false pass is available to every `*-validate-cuts` script in the harness |
| Why an `OK` cannot be strengthened into "checked" | Both checks are skipped whenever the reference has left the current bounds. `getRowCutDebugger()`'s `onOptimalPath` (`OsiRowCutDebugger.cpp:144-173`) tests **integer columns only, at 1e-3**; the pre-resolve block's own `knownSolutionStillOnPath` (`CbcModel.cpp:11211-11225`) tests **all columns, at 1e-6**. The direction of the bias is the useful part: the pre-resolve guard is the **stricter** of the two, so the printing check under-reports and **cannot manufacture a false VIOLATION** — which is precisely what makes the 13 actionable. What it cannot do is promise coverage |
| The generator's own filters, as new information | SETTLED — the whole rejection funnel over the 306 replayable fixtures at pass 0 root, from `mir-filter-counts-build.sh` + `mir-filter-counts.py`. Percentages are of `cMirSeparation` **entries**, not of cuts: `sepCalls` **5,144,728** → `sepNoDelta` **5,111,955 (99.36 %)**, `sepRecheckKilled` **155 (0.0030 %)**, `sepGenerated` **32,618 (0.63 %)** → `wideRejected` **0**, `unstableRejected` **46**, `uselessRejected` **0**, `offered` **32,572** → `dupRejected` **260** → `rowCuts_n` **32,312**. Weakening, a modification rather than a rejection: **15,174** cuts lost at least one coefficient and **1,523,577** coefficients were zeroed, 100.41 per weakened cut. **The result contradicts the framing this row was written under.** The funnel was ordered cheap-to-expensive because the original-space recheck (`violation > TOLERANCE_`, `TOLERANCE_ = 1.0e-4`, :1650-1730) fires only after the cut has been fully rebuilt in the original variables *and* after the small-coefficient weakening has moved the RHS — so it looked like the place where work is thrown away. It fires **155 times in 5.14 million**. What actually happens is that **99.36 % of entries die at the `maxViolation == 0.0` early return**, before anything is written in the original variables at all: MIR2's cost is not wasted construction, it is the sheer number of `cMirSeparation` entries that produce nothing. That is a measured argument against OPT-D independent of its exactness hazards — deferred cut construction exists to avoid building cuts that are then discarded, and the discard it targets is 0.0030 % of calls. Two predictions did hold exactly, and both were load-bearing: `wideRejected` is **0**, confirming that `:1001`'s `info_->pass \|\| info_->inTree` test is inactive at pass-0 root and therefore that the replay call shape is the one this write-up claims; and `uselessRejected` is **0**, so nothing that survives separation turns out to be un-violated at the current point after all. `unstableRejected 46` (:1027) and `dupRejected 260` are real but tiny — together 0.9 % of what reaches the accept path |
| Why the funnel numbers can be trusted, and what `dupRejected` really counts | four identities are checked per fixture, and only the fourth leaves the generator. I1 `sepCalls = noDelta + recheckKilled + generated` and I2 `generated = wide + unstable + useless + offered` are bookkeeping: they prove the counters partition the control flow, nothing more. I3 `offered − dupRejected = rowCuts_n` crosses into the bench's own accounting. **I4 `sepCalls = cmirCalls` is the real check**, because `cmirCalls` is not a counter at all — `CbcMirFixtureDump.hpp:905-935` *reimplements* `copyRowSelected` + `boundSubstitution` and re-derives from the LP alone which multiply directions should reach `cMirSeparation`. So I4 tests the generator against an independent model of the generator, and it is what decides whether `cmirWork` — the axis the slow tail is ranked by, built from that same simulation — means anything. I4 is checked at **`--level=-1` only**, and it **fails on 3 of 306** — by −0.208 % (`map10` 18712 vs 18673), +0.473 % (`map16715-04` 18402 vs 18489) and +0.021 % (`unitcal_7` 33730 vs 33737), in **both** directions. The cause is located, and it is in the dumper's simulation rather than in the generator: all three are in the **53 fixtures that use VLB/VUB substitution**, and I4 holds exactly on the 253 that do not. *Density* of substitution is not the predictor — the top seven by `vlbCount+vubCount` all pass (`kasavu` vub 677768, `cuanza` 228096, `buildingenergy` 43798/82534, `neos-873061` 87610, `thor50dday` 53130, `sing44` 15971/15971, `sing326` 14954/14954). Nor is the threshold: `CbcMirFixtureDump.hpp:830` uses `COIN_INDEXED_TINY_ELEMENT`, the same macro the generator's own `CoinIndexedVector` uses. What differs is **accumulated versus per-contribution accounting**. VLB/VUB substitution is the only mechanism that maps two contributions onto one knapsack index; the generator's zero-lower-bound loop reads the *accumulated* `mixedKnapsack` and **skips** an index whose accumulated value is under `EPSILON_` before testing `colLowerBound`, while the dumper's loop over `touched` tests each contribution against a mark array and has no such skip. (`CoinIndexedVector::add` was the first suspect and is innocent: a contribution that cancels is stored as `COIN_INDEXED_REALLY_TINY_ELEMENT` and its index **stays** in `indices_`, so `getNumElements()` does not shrink.) The bound matters more than the cause, because I4 exists to decide whether `cmirWork` is a sound ranking axis: **Spearman ρ(`sepCalls`, `cmirCalls`) = 1.000000 over all 306**, so a ≤ 0.47 % divergence on three fixtures cannot reorder anything, and the axis survives its own test. Separately: `dupRejected` is detected as "did `cs` grow", because MIR2 **discards** the `bool notDuplicate` that `insertIfNotDuplicateAndClean` returns (`OsiCuts.hpp:155`) — and for MIR2 that proxy is *exact*, since the function's one non-duplicate rejection path, the badly-scaled-cut drop, is guarded by `if (typeCut == 61)`, i.e. CglTwoMir, and MIR2 passes 31. The same three lines around a Twomir insert would be misnamed. Worth noting in passing that the `1e8` ratio Osi applies only to Twomir at insert is the same ratio MIR2 already applies to itself at :1027, one filter earlier |
| The two sizing axes disagree, so only one of them can be the ranking | ρ(`sepCalls`, `cmirCalls`) = 1.000000 above says the dumper's *simulation* is faithful. It says nothing about which axis predicts **cost**, and the two candidates turn out to be nearly independent: **ρ(`sepCalls`, `cmirWork`) = 0.323385** over the same 306 fixtures. Their top eights are almost disjoint. By `cmirWork` (Σ numInt² over starting rows × `upperLimit`, i.e. the O(numInt²) inside `cMirSeparation`): `ivu52` 1.203e11, `bab2` 8.359e10, `bab6` 3.164e10, `scpn2` 3.126e10, `roi5alpha10n8` 2.927e10, `s100` 2.613e10, `scpm1` 7.818e9, `roi2alpha3n4` 7.808e9. By `sepCalls` (how many times `cMirSeparation` is entered at all): `kasavu` 531357, `temuka` 349602, `buildingenergy` 221328, `cuanza` 170560, `uccase12` 125411, `rd-rplusc-21` 105871, `widden` 104872, `neos-1122047` 95704. This is the `nnzWork / cmirWork` class distinction §5 asked for, made concrete: a fixture can enter separation half a million times and do almost nothing in each, or enter it comparatively rarely and do 10¹¹ units of work per entry, and a change that helps one class will look like it misfired on the other. **Which axis predicts wall clock is now measured, and it is neither of those two.** A serial single-rep baseline pass over all 306 fixtures (`mir-rank.py`, whose times are a ranking key and not a measurement) gives, against the bench's own `sepTime`: ρ(`nnzWork`) = **0.962854**, ρ(`cmirWork`) = 0.715895, ρ(`startingRows`) = 0.589522, ρ(`cutNzTotal`) = 0.119209, ρ(`rowCuts_n`) = **0.077703**. So per-call separation time is very nearly monotone in the matrix nonzero count and only loosely related to the O(numInt²) axis — which is what a cost dominated by fixed O(nnz) passes rather than by `cMirSeparation` looks like, and it is the axis OPT-A/B/C remove work from. Two honest qualifications. **ρ(`nnzWork`) is partly a size effect**: `nnzWork` *is* the element count, so it proxies instance size in general, and a high rank correlation with it is weaker evidence than the number looks — the discriminating evidence is the measured speedup and the counter-examples, not the ρ. And it does **not** contradict the `cmirWork`-carries-62.9%-of-time row above: that share is weighted by `cbc` **root** time across all passes, this ρ ranks **one pass-0 call**, and the two are different quantities (below). The counter-examples are the sharper form of the same point: `ivu52` is #1 by `cmirWork` at 1.203e11 — 4x the next fixture — and ranks **8th** in time at 0.678 s, while `kasavu` is **1st** at 3.220 s with `cmirWork` 1.445e8, three orders of magnitude lower. The `bab6` reading this row previously offered as an encouraging sign for the `cmirWork` axis is **withdrawn**: `bab6` is 0.365 s in the bench (rank 14), not the 3.92 s it showed in the planning `cbc -maxNodes 1` probe, and that gap between 3.92 s and 0.365 s is itself the cleanest single demonstration that scan time and bench time are not the same measurement. Worth recording separately that **ρ(`rowCuts_n`) = 0.0777** — cut count carries essentially no information about cost, an independent arrival at the same rule the process doc states for ranking |
| What the `MODIFY_LP==2` flip actually changes: nothing but the order of two cuts | The counters above were collected at both `--level=0` (CBC's own call: deep-copy the `OsiClpSolverInterface`, sign-flip every pure `>=` row, `setNewRowCopy(NULL)`, preprocess again, recurse) and `--level=-1` (none of that). **All twelve counters and `rowCuts_n` are identical on every one of the 306 fixtures.** That is not the instrumentation failing to see the branch: `modifyLpFired` is **1** at `--level=0` and **0** at `--level=-1` on the **116** fixtures with `geRowsToFlip > 0` (`map10` flips 29013 rows, `unitcal_7` 19454, `kasavu` 7644), while `neos-2075418-temuka`, with `geRowsToFlip 0`, reports `0` at both levels. The copy, the flip and the recursion all demonstrably ran. They are inert because **the flip is a permutation inside a pair the generator already evaluates both halves of.** `copyRowSelected` (:1169) does not canonicalize by sense: it copies the row as stored, sets `rhsToAggregate = rhs`, and appends a slack with coefficient `+1` and `xlpExtra = rhs − lhs` for `'L'`, `−1` and `lhs − rhs` for `'G'`. So `a·x ≥ b` becomes `(a, −1)·(x,s) = b` and its flipped twin `−a·x ≤ −b` becomes `(−a, +1)·(x,s) = −b` — an exact negation carrying the same slack *value*. And the multiply loop at :1022 runs `upperLimit = 2` whenever `MULTIPLY_` is set, which CBC's constructor does: `rowToUse.copy(rowAggregated)` at `i=0`, `rowToUse *= −1.0` at `i=1`, and both iterations always run — there is no break on success. The flipped model's `{i=0, i=1}` is the unflipped model's `{i=1, i=0}`. Nothing else moves: row-type classification is invariant because negation swaps `sense` `'L'`↔`'G'` **and** `numPosCon`↔`numNegCon` simultaneously, which is exactly the pair `determineRowType`'s VARUB/VARLB switch reads, while MIX/CONT/INT depend only on variable-type counts; and the flip touches only rows with `rowUpper >= 1e50`, which are never range rows, so the solution-dependent `'R'` classification is untouched. **The prediction was then tested on the cut streams themselves**, because equal counters are order-blind while MIR2's single insert is not: `mir-level-streams.sh` compared the `%a`-exact `[cut]` stream at the two levels on the **71** fixtures where the flip fires *and* cuts exist (the other 235 have nothing to flip or nothing to produce). **68 are byte-identical; 3 differ, and differ by a permutation only** — `neos-873061`, `ran14x18-disj-8` and `physiciansched3-3` emit the identical multiset of cuts with maximum displacement **1**, and every displaced cut belongs to a consecutive `(+1, −1)` transposition (6, 1 and 4 swaps, accounting for 12 of 12, 2 of 2 and 8 of 8 movers). That is the ± swap landing exactly where the argument says it must: on a flipped starting row that produced an accepted cut at *both* signs. 239,860 coefficients compared. **The consequence is a candidate, not a commit.** Skipping the `MODIFY_LP==2` block when `MULTIPLY_` is set is cut-**multiset**-identical over the whole population and would delete a `ClpSimplex` deep copy, an O(nnz) row-copy rebuild and a second full `mixIntRoundPreprocess` — but it is not cut-**order**-identical, and cut order reaches CBC, so it has to go through the root-bound metric like any other cut-set change rather than be asserted as bit-identical. The gate must be `MULTIPLY_`: at `--no-multiply` `upperLimit` is 1, the pair is no longer evaluated both ways, and the whole argument lapses |
| The two time axes differ by 18x, and the sizing gate lives on only one of them | The §5 gate was judged on **`mir-scan.py`'s `cbc -maxNodes 1` figure** — the `MixedIntegerRounding2` row of `printGeneratorTable` — and it passed on all three counts: population total **400.2 s**, **49** instances ≥ 1.0 s (needs 15), top-20 = 307.0 s (**77%**). The **bench replay measures a different quantity**: one pass-0 call per fixture, **22.473 s** over 306 fixtures, **5** fixtures ≥ 1.0 s, top-20 = 17.749 s (**79.0%**). That is a factor of **17.8** on the total, and the two must never be quoted side by side without naming the axis — because read against the gate thresholds the bench distribution (5 and 22.5 s) looks like a **failed** gate, and it is not one: the gate is defined on the scan axis and was met there. The gap has three causes, only the first of which is interesting. CBC calls MIR2 **once per cut pass** and `setDoPreproc(1)` re-runs the whole preprocess every time, so the scan's number is a sum over every root pass, while the bench replays **exactly one** call — deliberately, since pass 0 is the only pass where the :1001 wide-cut filter is off and is therefore the only one comparable across binaries. Second, the populations are not the same set (357 instances scanned, 291 row-present, against 306 replayable fixtures). Third, the scan's per-instance time includes root work the bench never does. **The single-instance proof is `bab6`: 3.92 s in the planning probe, 0.365 s in the bench** — same generator, same instance, two honest numbers 10.7x apart. What *does* agree is the **shape**: top-20 carries 77% of the scan total and 79.0% of the bench total, so the cost is concentrated the same way on both axes even though the magnitudes are not comparable. The consequence for reading the row below: a bench speedup is a **per-call** figure, and what reaches CBC is that figure diluted by every other pass and by the rest of the root. Do not multiply the two together |
| Speedup | **1.11x over the 20 slowest fixtures (17.6718 s -> 15.8767 s), 1.10x on the 5-fixture slow tail (11.1453 s -> 10.1029 s).** `mir-serial.py`, min of 3 serial reps, idle machine, `--pass=0`, ranked by absolute time. Every fixture `n=3/3` and **no MISMATCH on any of the 20** -- `rowCuts_n`, `cutNzTotal`, `objImprove` and `warmStartIters` all matched, which is the only thing that makes these times comparable at all. Best **`square47` 3.31x** (0.2548 -> 0.0769), then `scpl4` and `roi5alpha10n8` at 1.33x and `neos-848589` at 1.21x; worst `var-smallemery-m6j6` **1.03x**. Read this against the two-axis row above: it is a **per-call** figure on one pass-0 call, not a suite-wide one, and the 22.473 s bench population total is not the 400.2 s the sizing gate was defined on. Two things worth saying plainly. First, **11 of the 20 produce zero cuts** -- 10.3835 s of the 17.6718 s base, 58.8 % -- including 3 of the 5 tail fixtures (`scpn2`, `temuka`, `scpm1`, 6.75 s of the 11.145 s tail). So most of what got faster is faster *nothing*-generation, which is honest work removed but must not be reported as better separation. Second, 1.10x on the tail is unremarkable on its own and matches the ceiling stated up front when gate (3) held. |
| Why the speedup varies 3.31x to 1.03x, and it is not fixture luck | The change removes a **fixed cost per matrix nonzero**, and every ratio above follows from that one number. Saved seconds / `nnzWork` over all 20: **mean 30.7 ns/nnz, median 28.6, range 14.3-49.3 (factor 3.45)**, aggregate 1.7952 s over 5.98e7 nonzeros = 30.0 ns/nnz. The 3.45x spread looks like noise until you use it as a model: predicted speedup = `baseNs / (baseNs - 30)`, where `baseNs` is the fixture's own base time per nonzero. That predicts **19 of the 20 to within 15 %, mean error 3.3 %** (worst `roi5alpha10n8` 15 %, then `neos-848589` 7 %). What actually varies is not the saving but the *denominator*: base cost spans **30.1 to 1428.7 ns/nnz, a 47x range**. `square47` is the whole mechanism in one fixture -- its entire base cost is **30.1** ns/nnz and **21.0** of that was the removed copies, i.e. ~70 % of its separation time was the identity submatrix copy plus the dead transpose, hence 3.31x. It is also the one fixture the constant-30 form cannot predict numerically (it gives 380x): when `baseNs` lands *inside* the saving band the ratio is hypersensitive, so exclude it from the fit and quote it as the demonstration instead. At the other end `buildingenergy` and `var-smallemery-m6j6` sit at ~1400 ns/nnz, so a 30 ns/nnz saving is arithmetically capped at ~1.02x no matter how well the change works. **Corollary for the next reader: this change's payoff is set by absolute `nnzWork` relative to total time, not by the `cmirWork/nnzWork` ratio class** -- the ratio class predicts whether OPT-A/B/C are *visible*, absolute `nnzWork` predicts the *seconds*, and the two disagree (`scpn2` and `scpm1` are cmirWork-class by ratio at 2501x and 1251x while being #1 and #4 in the population by absolute `nnzWork`). |
| Regression suite | **500/500 PASS and 336 confirmed optima on both halves**, against a fresh baseline taken on the same HEAD (the Twomir-era 471/471 · 361 figures are not comparable — `Cbc f10b4e70` changed `CbcAllowableGap` to 1e-6 and `CbcAllowableFractionGap` to 1e-4). Every aggregate delta is **0**: Passed 0, Failed 0, Overtime 0, Error 0, **Optimal solutions found 0**. `compare-results` still exits 1, purely on gap movement, which is expected and is not by itself a correctness failure. Both `cbc` binaries were confirmed to have actually relinked against the new `libCgl.a` (17:21:01 base, 17:32:12 candidate) and both were provenance-checked **by object member**, `ar p libCgl.a CglMixedIntegerRounding2.o`, not by archive |
| The gap movement, settled rather than waved away | A diff on `gap_pct` **or** `bound` **or** `obj` gives **17** rows, not the 8 `compare-results` flagged. All 17 are PASS on both sides, and — the load-bearing observation — **all 17 have identical node counts**, which localizes the movement to the stopping rule rather than to the search. Two are visibly wall-clock truncated: `supportcase6` stops at **0 nodes** after 180.7 s against a 180 s `-sec` (its node limit is 71), and `sorrell3` at 2 nodes after 186.5 s vs 182.4 s. `supportcase6` is the cleanest single datum in the pair, because its **dual bound is bit-identical at 45090.7** and only the incumbent moved (52119.4519703 → 52166.0806015): a heuristic found a different solution in the time available, and the cut-set-sensitive quantity did not budge. The other 15 stop on their **node** limit exactly (`nodes == node_limit`), so truncation is *not* their explanation and their bound differences must come from time-dependent decisions inside CBC. All 17 were therefore re-run at **`-maxNodes 1 -threads 0` with no `-sec`** — `-threads 0` because a fixed node limit is not deterministic under `-threads 1`, and no `-sec` because that is the clock dependence being removed. Result: **17 of 17 IDENTICAL** on the full `Result / Objective value / Lower bound` triple, `differs=0 unsettled=0`. The suite's gap movement is search noise; the root bound, which is the cut-set metric, does not move anywhere |
| Negative results | **OPT-D and OPT-E were priced and held back, for opposite reasons.** OPT-E — applying the `>=` flip to the generator's own `sense_`/`RHS_`/`LHS` copies instead of to a cloned LP — is **superseded**, not merely deferred. OPT-F already removes the copy on the 36.7% of population time where it is *pure* waste; on the remaining 63.3% the copy is genuinely consumed by the recursion, and OPT-E as planned would have had to **reimplement** the flip. The flip row above removes that requirement — the flip changes no counter and no cut, only the order of two cuts on 3 of 71 fixtures — so the cheaper candidate is to **skip the `MODIFY_LP==2` block entirely when `MULTIPLY_` is set** and reimplement nothing. It stays out of this commit regardless, for a sharper reason than risk: it is a cut-**order** change, so its evidence is the root bound, not string equality. OPT-D — deferred cut construction in `cMirSeparation` — is unblocked on exactness grounds (both hazards settled by reading, above) and is where the `cmirWork`-dominated 62.9% of the population's time lives, so it is the *right* next candidate; it is out of this commit because its exactness argument is **measured, not structural**, unlike OPT-A/B/C/F where the claim is "no reachable reader". Any OPT-D rewrite must also zero `violation`, which `cMirInequality` accumulates into rather than assigns. Three further items are recorded and deliberately untouched: `aggregateRow`'s `operator-` temporary (unreachable at `MAXAGGR_ == 1`; closing paragraph), the `MAXAGGR_` restore leak the recursion's `return` skips (its own one-liner commit, with its own reproduction), and the `numCon == 0 && sense == 'E'` → `ROW_INT` reclassification that would give all 27 zero-starting-row instances starting rows (a **cut-set** change, so it goes through the root-bound metric and a fresh `mir-validate-cuts`, never into this commit) |

MIR2-specific traps, each of which would have produced a wrong number or a wrong
write-up:

**The generator emits no output at all, which changes how you instrument it.**
Every `printf` and `std::cout` in `CglMixedIntegerRounding2.cpp` (:593-602,
:760-766, :969, :1029, :1034, :1038-1042, :1331, :1385, :1395) sits inside
`#if CGL_DEBUG`, and **`CGL_DEBUG` is defined nowhere** — not in
`Cgl/src/CglCommon/config.h`, and the generator's Makefile has an empty `CPPFLAGS`,
`DEFS = -DHAVE_CONFIG_H` and no `-DCGL_DEBUG`. Two consequences, in opposite
directions. There is no stray-`printf` class to filter, the exact opposite of
Twomir's two unconditional ones — so the exactness script instead **asserts** the
absence, failing any stdout line whose field count does not match the header's,
because a future unconditional `printf` would otherwise be absorbed silently into
the compared text or land inside a field. And the rejection counts in the filter row
above cannot be obtained by building with `-DCGL_DEBUG`: it also enables ~10 other
`printf` blocks and an `O(n)` assert loop in `cMirSeparation`'s tail, so the counts
would not describe the binary whose time is quoted. Eleven counters and one exit-time
`fprintf` do not, so they live in uncommitted instrumentation
(`mir-filter-instrument.py`, applied and reverted under a trap by
`mir-filter-counts-build.sh`).

**Anchored instrumentation must be compiled, not just matched.** The instrumentation
is applied by unique-substring anchors rather than as a `.diff`, because base and
candidate differ by 114 inserted lines and no single set of hunk offsets fits both;
each anchor is asserted to match **exactly once**, so drift fails loudly instead of
misplacing a counter. That assert is necessary and **not sufficient**. The first
version anchored the counter block on `#define SAFE_ROWS`, which *is* unique — and
sits at :481 **inside the copy constructor's body**, where `namespace { }` is
ill-formed and the eleven `static long long` would have become function-local statics
invisible to every increment elsewhere. The 12/12 match report was green; only
compiling caught it. Hence `mir-filter-counts-build.sh --check` applies the anchors to
`/tmp` copies of *both* variants and runs `g++ -fsyntax-only` on each, so a typo is
discoverable without touching a tree that a 40-minute experiment may be holding.

**CBC has two invalid-cut checks and only one of them is fatal, so an `OK`
verdict is an upper bound on the checked set, not a pass.** This is the trap that
matters most for every generator, not just MIR2, because it silently converts a
detection into a pass. Both checks are compiled — `Osi/src/Osi/OsiRowCutDebugger.hpp:7`
has `#define CHECK_KNOWN_SOLUTION`, tracked upstream (`cb16146c`), and
`strings Cbc/src/libCbc_la-CbcModel.o | grep -c "pre-resolve check"` returns 6, so
this is live code and not a dormant `#ifdef`. The two sites differ in exactly the way
that decides whether a harness can see them:

| site | accessor | on detection |
|---|---|---|
| `CbcModel.cpp:11376-11398` | `getRowCutDebugger()` — internally requires `onOptimalPath()` | writes `badCut.mps`, prints, then **`abort()`** → rc=134 |
| `CbcModel.cpp:11178-11304` | `getRowCutDebuggerAlways()` — **deliberately bypasses** `onOptimalPath()` | **prints only** — six `printf` sites and no abort, assert or throw in those 127 lines |

The pre-resolve block bypasses `onOptimalPath()` on purpose (its own comment at
:11227-11234: that predicate has been observed to return false unconditionally for
the *preprocessed* root solver, which would disable the whole class of checks). The
cost of that choice is that it detects without failing. `mip-debug-cuts.cpp:380-421`
sets `violationDetected` **only** from a caught `CoinError`, so an instance whose
`onOptimalPath()` has gone false prints every invalid cut it finds and **exits 0** —
a false pass, with the evidence on stdout and nothing in the exit status. Fix in the
harness: scan the **output** for `produced invalid cut` / `produced invalid COLUMN
cut`, retain the matching lines, and attribute them per generator with
`sed -n 's/.*Cut generator [0-9]* (\([^)]*\)) produced invalid.*/\1/p' | sort | uniq -c`
— because an abort naming *another* generator is not your result. Validated against
the one instance that does abort: 718 lines, **525 naming MixedIntegerRounding2 and
193 naming Probing**.

**What `OK` cannot promise is coverage, and the reason is the path guard, not a
silent arming failure.** The obvious suspect is `OsiRowCutDebugger::activate`'s quiet
failure branch (`:1479-1491`): the LP with every integer fixed at `floor(ref+0.5)` not
provenly optimal frees `integerVariable_`, returns false, and says nothing, its return
value is discarded by the caller, and `active()` — literally `integerVariable_ != NULL`
(`:178-181`) — then makes both `getRowCutDebugger()` and `getRowCutDebuggerAlways()`
hand back NULL. That would be a fully silent false pass, invisible even to an output
scan. **It is unreachable from CBC.** That branch is inside `if (keepContinuous ==
false)`, and CBC's call sites (`CbcSolver.cpp:8156`, `:8200`, `CbcBab.cpp:681`) pass the
solution alone, so the parameter takes its default `true` and control goes to the
`:1492` `else`: copy the reference verbatim, compute `knownValue_` from the objective,
never touch `integerVariable_`. Every instance that clears CBC's *own* pre-check is
therefore armed unconditionally — and that pre-check is the `BAD debug file` path at
`CbcSolver.cpp:8170-8199`, which a harness already sees and scores SKIP. Worth a second
look before trusting either name: the declaration calls that parameter
**`enforceOptimality`** (`OsiSolverInterface.hpp:1993`) while the definition calls it
**`keepContinuous`** (`OsiRowCutDebugger.cpp:1433`) — opposite senses for the same
argument, and the definition's is the operative one, so reading the header alone gets
the behaviour backwards.

What does bound coverage is that **both** checks are skipped whenever the reference has
left the current bounds — `onOptimalPath()` (`:144-173`, integer columns at 1e-3) for
the aborting site, and the pre-resolve block's own `knownSolutionStillOnPath`
(`CbcModel.cpp:11211-11225`, **all** columns at 1e-6) for the printing one. That is the
normal state deep in a tree, and it is why `OK` is an upper bound on the checked set.
The bias has a direction worth stating, because it decides whether a scan can produce a
false alarm: the pre-resolve guard is the **stricter** of the two, so a printed line
means the reference satisfied every current bound and the cut excluded it anyway. It
under-reports and cannot manufacture a false `VIOLATION`. Recording the two guards is
also what stops the opposite error — reading `getRowCutDebuggerAlways()` as
"unguarded", which it is only with respect to `onOptimalPath()`.

**A reference that is the LP relaxation rather than a feasible point makes every
invalid-cut line meaningless — and the check for it must be on the file, before the
solve.** `neos-3381206-awhea`'s `.sol` header reads `Stopped on time (no integer
solution - continuous used) - objective value 415.24000000`: the "reference" is the
relaxation, so a **valid** cut is supposed to cut it off. That one line explained a
23,952-line report flagging **all six** active generators at once — Gomory 11214,
Probing 7398, Twomir 4743, MixedIntegerRounding2 510, ZeroHalf 45, FlowCover 42, with
`obj=COIN_DBL_MAX`. Six simultaneous generator bugs is not the parsimonious reading of
that; one bad reference is, and confirming it cost **zero** solve time against a
planned ~20-minute base-vs-candidate run. Read the input before spending an experiment
on it.

The leak is quantifiable and its cause is a **placement** bug rather than a missing
check. **28 of the 128 instances carry a relaxation reference**; 26 of them were caught
only because CBC happened to print `BAD debug file`, which comes from
`CbcSolver.cpp:8193` and is reached **only when preprocessing changed the column
count** — when it does not, `CbcSolver.cpp:8156` arms the debugger with no check at
all. So the harness had the right test inside the wrong arm, and the verdict depended
on an incidental property of preprocessing. Exactly **2 leaked**, one in each
direction: `neos-3381206-awhea` → a false `VIOLATION`, and `buildingenergy` → a
**vacuous `OK`**, which is the worse of the two because an invisible false pass leaves
nothing to investigate. Being the relaxation is a property of the *file*, so the check
now reads the `.sol` header at the top of `run_one()` and yields `SKIP` before the
solve, and the old branch collapses as unreachable.

Two details are worth keeping. **Why `rc=0` coexists with 23,952 printed lines** is the
two-check table above seen from the other side: the aborting site's `onOptimalPath`
tests **integrality** (`OsiRowCutDebugger.cpp:144-173`, ±1e-3) and goes false at once
on a fractional reference, while the printing site's `knownSolutionStillOnPath`
(`CbcModel.cpp:11211-11225`) tests only **bounds** (±1e-6), which a
fractional-but-in-range point satisfies — thousands of lines, no abort. And **a flat
`head -400` of the retained evidence is not a sample of it**: on this instance the
first 400 lines were led by Probing and Gomory and contained **not one**
MixedIntegerRounding2 line although the full-stream tally counts 510. Evidence that
omits the generator under test is worse than no evidence, because it reads as absence.
Retain a per-generator quota instead and print a footer naming what was dropped, so a
cap can never be mistaken for the whole stream.

**`rc=77` is not the Osi `#else` branch, and it means the instance validated nothing.**
It is `CbcHeuristic.cpp:1113`, inside `#ifdef CHECK_KNOWN_SOLUTION` at `:1095`: on a
restart with a debugger active (`numberNodes < 0 && solver->getRowCutDebugger()`) CBC
prints "Trying rowcutdebugger on restart", writes `/tmp/before2.mps` and
`/tmp/after2.mps`, and exits 77. Proof it is not the Osi site:
`strings mip-debug-cuts | grep -c "code must be compiled with CHECK_KNOWN_SOLUTION"`
returns 0, so that `#else` is not compiled at all. `RESTART` therefore has to be its own
verdict — counting it as OK would credit a run that stopped before the cut loop.

**`grep -q` in a pipeline under `set -o pipefail` misclassifies exactly the runs whose
output is largest.** A matching `grep -q` exits on the first hit, the upstream `printf`
then dies of SIGPIPE, and `pipefail` promotes that 141 to the pipeline's status — so a
**successful** match reads as failure and control falls through to whatever the last
`else` is. The bite is size-dependent, which is what makes it so hard to see: while the
whole log fits the 64K pipe buffer `printf` finishes before `grep` exits and the arm is
correct, so small instances classify properly and large ones silently do not. It cost a
20-minute run here: 12 of the first 24 instances landed in `UNKNOWN`, `gen-ip054` among
them, whose `activate: activated, z = 6840.97` sits on line 51 of a 385,518-line log.
The same shape produced a false `FATAL: the activation string is absent` from a
provenance check whose string was present. Two defences, both cheap: don't set
`pipefail` in a script whose logic is `grep -q` arms (none of the committed
`*-validate-cuts` scripts do, which is why their verdicts were never at risk), and make
any classifier's fall-through arm a **loud** `UNKNOWN` that is re-run rather than a
quiet default — the bug was caught only because `UNKNOWN` was designed not to be a
verdict.

**`switches = 0` means there is no first-pass kill switch — the opposite of
Twomir.** `CbcSolverCutSetup.cpp:347` passes `switches = 0 | (ALL_LAGRANGEAN *
lagrangeanFlag)` with `lagrangeanFlag == 0`, so `setSwitchOffIfLessThan(0)` can
never fire. A `Next run: disabled` therefore comes from `CbcCutGenerator`'s own
frequency tuning *after* the root, not from a 0-cut veto on the first call. 182 of
291 instances here report it, and attributing those to a kill switch — the correct
reading for Twomir, where `switches = 1` — would describe a mechanism that does not
exist in this generator. Record the verbatim `Next run` string and a
`mirPresent` boolean, and do not infer the mechanism.

**The root call runs the generator twice, and the first preprocess pass is thrown
away.** `CGL_HAS_CLP` is defined (`Cgl/src/CglCommon/config.h:11`) so `#define
MODIFY_LP 2` at cpp:78 is live. At `!info.inTree && objSense == 1.0 &&
info.level >= 0` the branch deep-copies the solver (`OsiClpSolverInterface si2 =
*clpSolver;`, :126), sign-flips every pure `>=` row (`rowUpper[i] >= 1.0e50`,
:139-142), calls `model->setNewRowCopy(NULL)` (:150) forcing an O(nnz) row-copy
rebuild, then **recurses** with `info2.level = -1-info.level` and returns
(:175-176). With `setDoPreproc(1)` the `mixIntRoundPreprocess` at :57-74 has
already run on the *unflipped* model, and nothing between :74 and :175 reads a
single member it wrote. Note the flip touches only pure `>=` rows, so range rows and
the `'R'` branch are unaffected — which is the fact that makes the deep copy
avoidable in principle.

**A whole-solve scan time is not a separation cost, and MIR2 makes the gap
larger than Twomir does.** The scan's `mirTime` is what the generator spent across
every root pass; the bench's `sepTime` is one pass-0 call. `roi5alpha10n8` scans at
**148 s** and its pass-0 replay is a small fraction of that. The extra wrinkle here
is `setDoPreproc(1)`: preprocessing re-runs on **every** call, so multi-pass cost is
not amortized and a generator that looks expensive may simply be called often.
Ranking the hot set by scan time is legitimate and is exactly what the sizing gate
does; quoting a scan *magnitude* as a separation cost is not, and the two must never
be differenced.

**And the same trap has a second currency: a whole-solve cut *count* is not a
pass-0 property either.** This one was walked into here after the time version of it
had already been written down. Validating the dumper's `startingRows == 0` skip arm
against the scan's `mirRowCuts` column flagged `nw04` as wrongly skipped — it skipped
with zero starting rows, yet the scan credited it with a cut — and the apparent
contradiction read as a broken precondition worth restarting a three-hour fixture run
over. It is not. `numRows_ = si.getNumRows()` (:459) and `info.formulationRows` is
never read, so from pass 1 on MIR2 classifies the cut rows *other generators* just
added; one `ROW_MIX` cut row is enough to give it a starting row it did not have on
the original formulation. Re-run at `-passC 1` and `nw04` produces **0 cuts in
0.037 s**, against 1 cut in 0.616 s over 16 passes. The rule generalises: any scan
column is an aggregate over every root pass, so it can *corroborate* a pass-0
property but can never falsify one. To falsify one, re-run with a single cut pass.

**`--pass=0` is the only comparable call, and for MIR2 the reason is an
acceptance rule, not a cost.** The `#if 1` block at :1001-1008 rejects cuts wider
than `0.8*numCols_` — but **only** `if (info_->pass || info_->inTree)`, so at the
root first pass it is **off** and pass 0 accepts cuts every later pass discards.
That makes round 2 a structurally different call rather than a cheaper one, which is
why `--rounds>1` warns. (`#if CBC_CHECK_CUT_LENGTH` at :993-999 is defined nowhere
in Cgl or Cbc and is dead.)

**The setters throw where Twomir's silently ignore, and one getter is lossy.**
`setMAXAGGR_`, `setCRITERION_` and `setDoPreproc` **throw `CoinError`** on
out-of-range input (cpp:1969-1978), the opposite of `setAway`/`setAwayAtRoot`, which
silently keep the old value — so a bench here cannot end up quietly misconfigured
and must wrap its sets in `try`/`catch` and hard-fail. But `getDoPreproc()` is
`return (doPreproc_ != 0);` (:1980-1983), so **-1 ("follow solver settings") and 1
("always preprocess") are indistinguishable through the getter** — and that is
exactly the distinction OPT-C's guard turns on. The bench therefore echoes its own
value as `doPreproc` *and* the getter's as `doPreprocNonzero`, so the lossiness is
visible in the CSV rather than assumed away.

**Largest-first fixture ordering is a memory trap, and the OOM it causes is
load-dependent.** The generator script inherited `sort(key=-getsize)` from the
Twomir harness, where it is a harmless resume-friendliness trick. Here it
concentrates MIPLIB's twelve biggest instances into the first `jobs` slots, and at
`--jobs=12 --secs=900` that drove the machine to 48/49 GB resident with swap full
and **the kernel OOM-killed a neighbour** (`scpn2`, `total-vm 13.4 GB`,
`anon-rss 10.7 GB`) after 140 s. Which instance dies depends on which happen to be
co-resident, so a fixture population assembled under memory pressure is **not
reproducible** — the one property it must have. Two fixes, both worth carrying
forward. `--defer-file` reorders the named instances to the tail while keeping
largest-first within each group, and deliberately does *not* force a redo, so it
composes with resume. `--memlimit=GB` caps each child's address space via
`ulimit -v` in an `exec`'ing shell — **not** `preexec_fn`, which is
documented-unsafe from a threaded parent — and its purpose is not to save memory but
to make exhaustion **attributable**: an instance that wants more than the cap fails
by its own allocation, instead of the kernel picking a victim by RSS. Note the cap
is on *virtual* address space, which runs well above RSS, so leave headroom. Decode
the child's exit status too: `rc == -9` must be reported as SIGKILL rather than as a
bare nonzero, because it is the one failure class that is not a property of the
instance alone.

**And the instances that cost the most memory are the ones that cannot produce a
fixture.** Cross-referencing the size order against the scan's own `mirPresent`
column: **16 of the 20 largest instances never reach a cut pass** (`passes=0`) —
only `roi5alpha10n8`, `supportcase12`, `roi2alpha3n4` and `neos-4647030-tutaki` are
both in the top 20 and cut-producing. So largest-first front-loads hours of
provably-useless work **and** the OOM condition at the same time. Feed the scan's
`mirPresent != 1` column to `--defer-file` and the run spends its first hours on
instances that can actually dump.

**A `.meta` appears minutes before its child exits, so file counts and log rows
disagree legitimately.** The dump fires at root pass 1 from inside `CbcModel`, and
`cbc` then keeps solving to `-maxNodes 1` and shuts down cleanly. So a completed
fixture on disk is not a completed job, and comparing `ls *.mir.meta | wc -l`
against the log's row count will show a gap that is not corruption. Check
completeness by testing for all five files per stem, not by counting either one.

**`pkill -f <pattern>` matches the shell running it and kills the caller.** The
`pgrep -f` false-positive trap recorded elsewhere in this document is merely
misleading; with `pkill` it is fatal — a poll for `cbc-mirdump` terminated its own
shell with exit 144. Use `pgrep -af` and read the matched line, or the bracket trick
(`gen[-]mir-fixtures`) so the pattern text cannot match itself.

**The suite's printed "average gap" is a division-by-near-zero artifact of four
instances, but its *delta* is robust — and the two facts are worth separating.**
This is sharper than the known "average gap is not the mean of the gap column"
ladder, which is about the substitution rule, not about the arithmetic. Reproducing
the ladder over `/tmp/cbc-suite-baseline.tsv` gives `10775200127322.4844`, matching
the harness's printed `10775200127322.48` exactly — so the reconstruction is
verified, and can be interrogated. `markshare1` and `markshare2` finish with dual
bounds of **−9.09495e−13** and **−1.81899e−12** against optima of 30 and 38:
arithmetically correct bounds that are, numerically, zero. Dividing by them yields
gaps of **3.29853e15 %** and **2.08907e15 %**, and those two rows alone are
**99.999998818 %** of the printed average. They are the only two instances in the
whole 500 with `|bound| < 1e-6` — but removing them does not rescue the figure,
because `mushroom-best` (bound 1.27e-5 → 6.36e7 %) and `neos17` (bound 1.01e-3 →
1.57e4 %) simply take over at 127833.82 %. The artifact is a **class**, not two
rows: a relative gap taken against a near-zero bound. With all four dropped the
average is a sane **15.1891 %** base vs **15.1633 %** after.

The useful half is that all four are **bit-identical across the two halves**, so
the delta is **−0.0259 pp in all three views** — full 500, minus markshare, minus
all four. The candidate's average gap is very slightly *better*, and that
conclusion survives the artifact instead of being buried by it. So: never quote the
absolute average gap as evidence about a cut set, do quote the delta, and drop the
near-zero-bound class explicitly rather than hoping it cancels. A trap inside the
trap: `/tmp/baseline.tsv` still holds a **Twomir-era** run (`markshare1` at bound
`0`, gap `0.0000`) while these figures live in `/tmp/cbc-suite-{baseline,after}.tsv`
— reading the obvious filename would have produced numbers from the wrong
experiment.

**Two defects found by reading, both held out of the speedup.** `MAXAGGR_ < 0`
(reachable only via `-mixedRoundStrategy -1|-2`) is overwritten at :46-56, but the
`MODIFY_LP==2` recursion `return`s at :176 **before** the `MAXAGGR_ = saveMaxAggr`
restore at :220 — so `MAXAGGR_` stays 5 for every later in-tree call. And the
comment at :839-840 claims the aggregation loop exits when a violated cut is found;
the only `break` (:934) fires when no row *can* be aggregated. Neither belongs in a
performance commit: the leak gets its own one-liner with its own reproduction, the
comment gets fixed in the doc commit.

**Recorded as a measured non-finding, because it looks like an obvious win and is
not reachable.** `aggregateRow`'s `rowAggregated = rowAggregated - rowToAggregate`
(:1223) goes through `CoinIndexedVector::operator-`
(`CoinIndexedVector.cpp:835`), which copy-constructs a temporary whose `reserve`
does `new int[n+nPlus] + new double[n+9]` plus a full O(numCols) zeroing and then
returns by value. Genuinely wasteful, and **unreachable at `MAXAGGR_ == 1`**.
`operator-=` is no escape: it is literally `*this = *this - op2` (:977).

---

## 9. Checklist for the next generator

1. Pick the call site where matrix + LP + auxiliary structure are consistent.
   Dump behind an `#ifdef`; reuse `.mps.gz`/`.bas`/`.sol`/`.ctype`/`.meta`
   wholesale, add only your payload. Reuse the *files*, not another generator's
   *population* — gate the skip on your own generator's precondition.
2. Serialize any structure CBC caches. Add `--rebuild-<thing>` and quantify the
   difference rather than assuming there is none. If the generator rebuilds
   everything from the solver each call (as `CglZeroHalf::refreshSolver()` does),
   there is nothing to serialize and reconstructing on load is what CBC itself
   does — confirm that by reading the refresh, not by assuming either way.
3. Write the replay bench: one CSV row per run, `--header`, `--quiet`, every knob
   a flag, **and a control flag that disables the expensive stage**.
4. `--self-test` the serialization round-trip byte-exactly.
5. Establish the metric hierarchy: `objImprove` decides, cut count decides
   nothing.
6. Sweep the existing strategy knobs before writing any new code. Measure the
   ceiling of the optimization you are considering.
6b. Profile down to a **loop**, not to a function — a stage at 98% of wall is a
   location, not a target. Give each nested level its own array and remainder,
   use RAII guards, count iterations *and* entries separately, and use counters
   rather than timers at 1e9 scale. Then check the shares hold across the whole
   slow tail: one fixture is not a profile.
6c. Time the **enclosing loop** as its own region and require that stages plus
   instrumentation account for it. Instrumentation inside the loop lands in the
   residual, and "outside every timed stage" is not "outside the loop" — this
   put two fixtures at the top of a slow tail they did not belong in.
6d. Before optimizing, compute from the `.meta` the cost of the part you are
   **not allowed to change**. That is the floor on any speedup, and a fixture
   sitting on its floor is not the change misfiring.
6e. If the fix is "do the sparse thing instead of the dense thing", price the
   sparse thing's own cost on the whole population first. Both costs are usually
   computable before either is paid, which turns a heuristic into a gate — and
   the unconditional form was a 100x regression in the one case tried here.
7. Exactness: all fields, as strings, all fixtures, **including the modes where a
   gate is true**. Use 0-cut fixtures as noise controls.
8. Time serially, min-of-N, ranked by absolute time on the slow tail. Report the
   slow tail as its own subtotal, cap reps on fixtures over ~20 s, and discard the
   first read of a large fixture (page cache).
9. `run-suite --after`; judge by PASS + confirmed optima; settle single instances
   at a fixed node limit with no `-sec`.
9b. If the change alters the cut set, the suite is not enough: its confirmed-optima
   count moves on the `3 × calibrated_nodes` cliff and is a tree-shape statistic.
   Measure the **root bound** at `-maxNodes 1` over the whole population, exclude
   instances that finish at the root (their bound is nonsense), and partition on
   the 100-pass cap before reading the aggregate.
10. Commit, and write up the negative results too.
