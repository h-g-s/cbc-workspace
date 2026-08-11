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
7. Exactness: all fields, as strings, all fixtures, **including the modes where a
   gate is true**. Use 0-cut fixtures as noise controls.
8. Time serially, min-of-N, ranked by absolute time on the slow tail. Report the
   slow tail as its own subtotal, cap reps on fixtures over ~20 s, and discard the
   first read of a large fixture (page cache).
9. `run-suite --after`; judge by PASS + confirmed optima; settle single instances
   at a fixed node limit with no `-sec`.
10. Commit, and write up the negative results too.
