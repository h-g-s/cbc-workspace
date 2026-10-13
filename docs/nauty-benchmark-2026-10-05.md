# Nauty dependency assessment

Analysis date: **2026-10-05**. Experiments ran on **hal**, October 3-5, 2026.

## Recommendation

**Retain Nauty as an optional capability, not a required dependency.** This
sweep does not justify enabling symmetry unconditionally for general-purpose
performance: without Nauty, Cbc proves four more instances and runs faster on
the commonly solved set. Nauty nevertheless provides a substantial benefit on
`neos6`, so removing the capability altogether would lose a useful option.

This is a recommendation from one paired sweep, not a change to the workspace's
build or solver defaults. Repeat paired runs with frozen binaries and source
manifests before changing defaults.

## Experiment setup and provenance

| Setting | Both experiments |
|---|---|
| Instance set | `/home/haroldo/inst/miplib/2017+spp`, 393 identical unique instances |
| Time limit | 18,000 seconds (five hours) per instance |
| Node limit | 10,000,000 |
| Solver threads | 1 per instance |
| Concurrent instances | 100, dispatched by GNU parallel |
| Relative / absolute gap tolerance | `0.0001` / `1e-06` |
| Binary path recorded by harness | `/home/haroldo/prog/cbc/bin/cbc` |
| Sampled log revision | `de837849-dirty` in both experiments |

Original output directories on hal:

```text
/home/haroldo/experiments/cbc/git_10_03_nauty
/home/haroldo/experiments/cbc/git_10_03_nonauty
```

The non-Nauty run started October 3 at 23:55 EDT and finished October 4 at
15:38 EDT. The Nauty run started October 4 at 21:05 EDT and finished October 5
at 12:49 EDT. They ran sequentially, not simultaneously.

The summary tables have matching instance sets and expected objectives, and
the statistics tables record identical runtime options:

```text
-seconds 18000 -maxNodes 10000000 -threads 1 -ratioGap 0.0001 -allowableGap 1e-06 -solve
```

Matching dirty revision banners do **not** establish identical dirty source
contents, dependency revisions, compiler flags, or binary hashes. Those details
cannot be recovered from the inspected artifacts alone.

## Aggregate results

| Metric | With Nauty | Without Nauty |
|---|---:|---:|
| Solved/proved | 109 | **113** |
| Limit reached with an integer solution | **216** | 211 |
| Limit reached without an integer solution | **68** | 69 |
| Reported errors / hard-kill overtimes / wrong answers | 0 / 0 / 0 | 0 / 0 / 0 |
| Mean weighted cost (lower is better) | **51.1145** | 51.1873 |
| Penalized/clipped mean primal gap versus BKS | 29.47% | **29.19%** |
| Penalized/clipped mean dual gap versus BKS | 30.48% | **30.36%** |
| Peak whole-machine memory reported by harness | 197,399 MB | 187,704 MB |

These gap averages are the comparison tool's **penalized/clipped** metrics,
not averages restricted to runs with solutions. Missing-solution and failure
categories receive a 100-point gap penalty; clipping follows
`Cbc/test/compare_benchmarks_weights.json`. Primal and dual gaps are kept
separate. The default cost scores solved outcomes at 0, capped reported gaps
at up to 100, and no-solution timeouts at 200.

`compare-benchmarks --verify` found no input-bookkeeping inconsistencies.
This is not an independent validation of saved solution feasibility or
optimality certificates. Likewise, the memory figures are whole-machine
peaks under parallel load, not isolated measurements of Nauty's footprint.

### Runtime on the common solved subset

**108 instances are solved/proved by both experiments.**

| Metric on these 108 instances | With Nauty | Without Nauty |
|---|---:|---:|
| Total elapsed time | 162,457 s | **155,710 s** |
| Shifted geometric mean runtime, 10-second shift | 180.11 s | **169.94 s** |
| Runtime wins exceeding both 10 seconds and 10% | 2 | **12** |

Nauty's summed runtime is **4.33% higher** on this subset. The ratio of shifted
geometric means, before subtracting the shift, is **1.05655**, approximately
5.7% slower. Specifically, the reported shifted mean is
`exp(mean(log(t + 10))) - 10`; the ratio uses the corresponding values before
subtracting 10.

This matched-subset comparison excludes one-sided timeouts and must not be
interpreted as a full-set speedup estimate.

## Instance-level benefits and regressions

| Instance | With Nauty | Without Nauty |
|---|---:|---:|
| `neos6` | **Solved in 956 s** | Timeout at 18,001 s, 1.2% gap |
| `neos-960392` | Timeout, 2.1% gap | **Solved in 1,127 s** |
| `ns1758913` | Timeout, 0.4% gap | **Solved in 5,702 s** |
| `trdca23002` | Timeout, 10.8% gap | **Solved in 2,124 s** |
| `trdHardCA4500-8` | Timeout, 43.6% gap | **Solved in 5,397 s** |
| `trdtatl9220` | Timeout, 0.3% gap | **Solved in 10,414 s** |

`neos6` is the clearest success. Its Nauty log explicitly reports useful
symmetry and successful orbital branching. Explored nodes fall from
**240,176 to 11,012**, and simplex iterations from **35,434,279 to 2,103,040**.

All five one-sided proof regressions also report useful symmetry. Their
initial detection times are only **8.02, 14.8, 1.24, 0.235, and 0.313 seconds**,
respectively. The large deterioration is associated with changed search,
not simply the initial detection cost. For example:

| Instance | Nauty nodes / iterations | Non-Nauty nodes / iterations |
|---|---:|---:|
| `neos-960392` | 3,290 / 17,166,777 | 126 / 215,070 |
| `trdca23002` | 6,892 / 1,468,598 | 624 / 93,799 |
| `trdHardCA4500-8` | 23,737 / 4,950,400 | 7,150 / 673,070 |

Even when both runs solve, large regressions occur: `trdHard5600-6` rises
from **1,342 to 6,278 seconds**, while nodes increase from 1,022 to 3,326.

### Why the weighted score slightly favors Nauty

Nauty has a strictly lower per-instance cost on **17** instances; without
Nauty wins on **21**, with **355 ties**.

The aggregate advantage is only **0.0728 cost points per instance**. A major
contributor is `satellites2-60-fs`: Nauty finds an integer incumbent, while
the non-Nauty run finds none. Both remain unsolved, but the default scoring
assigns costs of 100 and 200 respectively.

As a sensitivity diagnostic, excluding this one instance reverses the
ranking: **50.9898 with Nauty versus 50.8077 without**. This is not a reason to
discard a legitimate incumbent-finding benefit; it shows why the headline
weighted winner is too fragile to establish a broad default.

## Symmetry detection coverage and overhead

Extracting the symmetry sections from the Nauty logs gives:

| Observation | Value |
|---|---:|
| Instances reporting detection | 348 |
| Detection calls | 350 |
| Instances with useful symmetry | 112 |
| Instances reporting no useful orbits | 236 |
| Sum of printed detection times | 7,030.252 s |
| Median summed detection time per reporting instance | 0.4545 s |
| Maximum summed detection time | 467 s (`neos-631710`) |

Within the 112-instance useful-symmetry subset, Nauty proves **30** instances
versus **34** without Nauty. Outside that subset, both experiments prove
**79** instances.

Detection is usually inexpensive, but has an important long tail. Examples
with no useful orbits include `gmut-75-50` (369 s), `app1-2` (317 s), and
`supportcase6` (307 s). `neos-1122047` spends 196 seconds detecting symmetry;
its total runtime rises from 36 to 235 seconds.

These are rounded times printed in the initial detection sections, not
complete accounting of symmetry-related work throughout the search tree.

## Caveats and next experimental decision

This is one run per build under substantial parallel load, so timing noise
and unrecorded build differences remain possible confounders. Root LP
objectives and processed dimensions agree in the statistics tables for
**392 of 393 instances**. `usafa` differs in both continuous objective and
processed row count; the cause was not established.

The evidence supports keeping Nauty **available but optional**, and favors
symmetry-off for general-purpose performance in this sweep. A cleaner
follow-up would compare repeated runs with symmetry enabled and disabled
using the **same frozen Nauty-enabled binary**, keeping all other settings
fixed. That would separate symmetry-policy effects from build differences.
Record binary hashes, exact source/dependency revisions and dirty patches,
compiler flags, and machine load before drawing a causal conclusion.

## Saved data and reproducing the report

The compact experiment tables are preserved under
[`benchmarks/nauty-2026-10-05/`](benchmarks/nauty-2026-10-05/):

- `nauty/` and `nonauty/`: original `summary.tsv`, `stats.csv`, `report.txt`,
  and `memory_usage.tsv`.
- `comparison.txt`: the standard comparison tool's ranking and divergence report.
- `symmetry.tsv`: per-instance detection-call count, useful-symmetry flag,
  and sum of printed detection times.

The full solver logs and solution files remain in the original directories
on hal; they are not duplicated in this repository.

From the workspace root:

```sh
./compare-benchmarks --verify --no-color \
  nauty=docs/benchmarks/nauty-2026-10-05/nauty \
  nonauty=docs/benchmarks/nauty-2026-10-05/nonauty
```

No source code, build settings, or solver defaults were changed for this report.
