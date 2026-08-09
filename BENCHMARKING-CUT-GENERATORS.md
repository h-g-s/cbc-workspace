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

---

## 9. Checklist for the next generator

1. Pick the call site where matrix + LP + auxiliary structure are consistent.
   Dump behind an `#ifdef`; reuse `.mps.gz`/`.bas`/`.sol`/`.ctype`/`.meta`
   wholesale, add only your payload.
2. Serialize any structure CBC caches. Add `--rebuild-<thing>` and quantify the
   difference rather than assuming there is none.
3. Write the replay bench: one CSV row per run, `--header`, `--quiet`, every knob
   a flag, **and a control flag that disables the expensive stage**.
4. `--self-test` the serialization round-trip byte-exactly.
5. Establish the metric hierarchy: `objImprove` decides, cut count decides
   nothing.
6. Sweep the existing strategy knobs before writing any new code. Measure the
   ceiling of the optimization you are considering.
7. Exactness: all fields, as strings, all fixtures, **including the modes where a
   gate is true**. Use 0-cut fixtures as noise controls.
8. Time serially, min-of-N, ranked by absolute time on the slow tail.
9. `run-suite --after`; judge by PASS + confirmed optima; settle single instances
   at a fixed node limit with no `-sec`.
10. Commit, and write up the negative results too.
