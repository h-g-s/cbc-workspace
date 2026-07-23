# CBC Workspace — Development Instructions

> ⚠️ **IMPORTANT — Git commits:** **NEVER commit all files blindly.** Always review
> `git status` and `git diff --staged` (in the relevant submodule *and* in the
> superproject) to select only the files relevant to the change. Stage files
> explicitly with `git add <file>`; never use `git add .` or `git add -A`.

## Repository Overview

`cbc-workspace` (`github.com/h-g-s/cbc-workspace`) is a **multi-repository workspace**
for developing the COIN-OR **Cbc** MIP solver together with its direct dependencies.
Unlike a monorepo, each project below is a **separate upstream git repository**,
wired in here as a **git submodule**:

| Submodule path | Upstream repo | Role |
|---|---|---|
| `CoinUtils` | `coin-or/CoinUtils` | Utility types/data structures (base layer, no COIN-OR deps) |
| `Osi` | `coin-or/Osi` | Abstract LP/MIP solver interface (depends on CoinUtils) |
| `Clp` | `coin-or/Clp` | Simplex LP solver + `OsiClp` (depends on CoinUtils, Osi) |
| `Cgl` | `coin-or/Cgl` | Cut generators (depends on CoinUtils, Osi, Clp) |
| `Cbc` | `coin-or/Cbc` | Branch-and-cut MIP solver (depends on all of the above) |

**Dependency / build order (strict):** `CoinUtils → Osi → Clp → Cgl → Cbc`.
Each project is configured/built/installed into a **shared prefix**; later projects
discover earlier ones via `pkg-config` (`.pc` files installed under
`$PREFIX/lib/pkgconfig`).

We are direct developers of these upstream COIN-OR repositories (not working from
personal forks). Each submodule tracks the **official `coin-or/<repo>` remote**.

## Branching Convention

> ⚠️ **Always work on the `next` branch in every submodule, never on `master`/`stable`.**

Each of the five submodules has a `next` branch already created and pushed to the
official upstream repo, and each submodule is checked out on `next` by default
(`.gitmodules` pins `branch = next` for every entry, so
`git submodule update --remote` tracks it automatically).

Before starting work in any submodule:
```sh
cd <Project>
git checkout next
git pull origin next
```

When your change is ready, push directly to `next` on the official repo (or open a
PR against `next` if project policy requires review):
```sh
cd <Project>
git push origin next
```

After updating a submodule's `next` branch, update the superproject's pointer too:
```sh
cd cbc-workspace
git add <Project>
git commit -m "Bump <Project> to latest next"
```

## Custom Autotools (COIN-OR BuildTools)

> ⚠️ Each of the 5 submodules uses **COIN-OR's patched autotools** (via
> `BuildTools`, checked out separately at `~/dev/BuildTools`), not the
> system's stock `autoconf`/`automake`/`libtool`. **Never run plain
> `autoreconf`/`automake` from `$PATH`** after editing a `configure.ac` or
> `Makefile.am` — it will silently drop COIN-specific macros/patches and
> produce a broken build.

The custom autotools binaries are pre-installed at `~/prog/coin-autotools`
(automake 1.17, autoconf 2.72, libtool). Point `COIN_AUTOTOOLS_DIR` there and
use `BuildTools/run_autotools` to regenerate `configure`/`Makefile.in` after
touching a submodule's `configure.ac`/`Makefile.am`:

```sh
export COIN_AUTOTOOLS_DIR=~/prog/coin-autotools
~/dev/BuildTools/run_autotools /path/to/submodule   # e.g. cbc-workspace/Cbc
```

For convenience, `./regen-autotools <Project>` (workspace root) wraps this
(sets `COIN_AUTOTOOLS_DIR` and calls `run_autotools` for the given submodule).
Run it any time you add/remove a `bin_PROGRAMS`/`noinst_PROGRAMS` entry, a
new source file list, or otherwise edit `Makefile.am`/`configure.ac` in a
submodule — `configure`/`Makefile.in` are checked into git and must stay in
sync with the `.am`/`.ac` sources.

## Build Commands

### Preferred workflow — `config` (all-in-one, multi-repo aware)

`config` is the **single entry point** for configuring, building, and installing
the full CoinUtils → Osi → Clp → Cgl → Cbc stack into one shared prefix.

```sh
# Interactive mode (no arguments) — walks through all options, project by project:
./config

# Non-interactive — configure + build + install everything in one shot:
./config --opt --install

# Debug build with AddressSanitizer:
./config --debug --sanitizer=asan --install

# Debug build with ThreadSanitizer:
./config --debug --sanitizer=tsan --install

# Configure only (requires a previously installed prefix for .pc file discovery):
./config --opt

# Custom prefix, jobs, shared libs:
./config --opt --install --prefix=/opt/cbc --jobs=8 --shared

# Enable AVX2 hand-written SIMD paths (x86_64 only):
./config --opt --avx2 --install

# Target a specific CPU generation (haswell = AVX2+FMA+BMI2, 2013):
./config --opt --arch=haswell --avx2 --install
```

Key options (mirrors MIPster's `configster`, adapted for 5 independent projects):

| Option | Default | Description |
|---|---|---|
| `--opt` / `--debug` | `--opt` | Build mode |
| `--sanitizer=none\|asan\|tsan\|valgrind` | `none` | Sanitizer (debug only) |
| `--arch=native\|generic\|<preset>` | `native` | Target CPU: `native` (`-march/-mtune=native`), `generic` (no arch flags), or a named milestone preset (see below) |
| `--march-native` / `--no-march-native` | — | Legacy aliases for `--arch=native` / `--arch=generic` |
| `--avx2` / `--no-avx2` | off | `-DCOIN_AVX2=4` hand-written SIMD (x86_64 only, independent of `--arch`) |
| `--lapack` / `--no-lapack` | on if found | LAPACK/BLAS (prefers OpenBLAS when available) — CoinUtils |
| `--amd` / `--no-amd` | on if found | SuiteSparse AMD ordering (Clp dense/CHOLMOD Cholesky) — Clp |
| `--zlib` / `--no-zlib` | on if found | `.gz` compressed MPS/LP file I/O — CoinUtils |
| `--bz2` / `--no-bz2` | on if found | `.bz2` compressed MPS/LP file I/O — CoinUtils |
| `--nauty` / `--no-nauty` | on if found | Graph automorphism for symmetry cuts — Cbc |
| `--static` / `--shared` / `--both` | `--static` | Library type |
| `--prefix=PATH` | `~/prog/cbc` | Shared install prefix for all 5 projects |
| `--jobs=N` | `nproc` | Parallel make jobs (used for every project) |
| `--install` | off | Build + install after configure |
| `--dry-run` | off | Show commands without running |

`--arch` presets (3 milestones per architecture, besides `native`/`generic`):

| Architecture | Presets |
|---|---|
| x86_64 | `sandybridge` (AVX, 2011) · `haswell` (AVX2+FMA+BMI2, 2013) · `skylake-avx512` (AVX-512, 2017) |
| aarch64 | `cortex-a72` (ARMv8.0, e.g. Raspberry Pi 4) · `neoverse-n1` (ARMv8.2, e.g. AWS Graviton2) · `neoverse-v1` (ARMv8.4+SVE, e.g. AWS Graviton3) |

> **`-ffp-contract=off` is always added**, regardless of `--arch`, for reproducible
> floating-point results (no silent FMA contraction across build modes or CPU
> generations). This is a deliberate difference from `configster`, which only adds
> it conditionally.

**Behaviour:** with **no arguments**, `config` enters interactive mode by default
(prompts for build mode, sanitizer, target arch, AVX2, prefix, jobs, library type).
**With any argument**, it skips the interactive prompts and goes straight to
configuring (and building/installing if `--install`/`--build` is given).

> **Important:** `config` always processes the 5 projects **in dependency order**
> and, when `--install` is given, interleaves configure → build → install **per
> project** (same rationale as `configster`): each project's `.pc` files must be in
> `$PREFIX/lib/pkgconfig` before the next project's `configure` runs, since
> dependency discovery is pkg-config based (`AC_COIN_CHK_PKG` in each `configure.ac`).

Debug builds install to a suffixed prefix based on sanitizer: `$PREFIX-asan`,
`$PREFIX-tsan`, `$PREFIX-vg` (valgrind), or plain `$PREFIX-dbg` (no sanitizer),
matching `configster`'s `derive_prefix` convention.

> **Note:** NEON hand-written SIMD support was evaluated and dropped — it showed
> no measurable speedup, so `config` (unlike `configster`) does not offer a
> `--neon` option. AVX2 is still offered since it is useful on x86_64.

### Optional dependencies (LAPACK/OpenBLAS, AMD, zlib, bz2, Nauty)

`config` auto-detects these optional libraries and only exposes toggles for the
ones actually found on the system (undetected ones aren't shown at all, since
there's nothing to toggle). Detection is **Homebrew-aware**: if the compiler
that will be used for the build (`$CC`, falling back to `cc`) resolves to a
path inside a Homebrew prefix, Homebrew's copy of each library is preferred
over the system one (when installed); otherwise the system's libraries are
used, matching plain autoconf auto-detection. This mirrors — but is stricter
than — `configster`'s Homebrew-preference logic, which always prefers Homebrew
regardless of which compiler is selected.

- **LAPACK/OpenBLAS** (CoinUtils): OpenBLAS is preferred over a bare reference
  LAPACK/BLAS when found, since it's a faster drop-in replacement.
- **AMD** (Clp): SuiteSparse's Approximate Minimum Degree ordering, used by
  Clp's dense/CHOLMOD-based Cholesky factorisation. BSD-3-Clause licensed, so
  it's safe to bundle in redistributed binaries.
- **zlib / bz2** (CoinUtils): enable reading/writing compressed `.gz`/`.bz2`
  MPS/LP files.
- **Nauty** (Cbc): graph automorphism library used for symmetry-detection cuts.

In the interactive TUI, these appear as a checklist step (debug/opt- and
arch-independent) right after the AVX2 prompt, defaulting to "on" for whatever
was detected. In plain-text mode, the fallback is one y/N prompt per
detected dependency.

### Incremental rebuilds — `build`

After the initial `config` run has configured every project, use `build` for
day-to-day incremental builds:

```sh
./build              # rebuild whatever changed (+ dependents), install, use all cores
./build --force       # force a full rebuild+install of all 5 projects regardless of diffs
./build CoinUtils     # rebuild only this project and everything that depends on it
```

> ⚠️ **Critical — cross-project rebuilds are NOT automatic.** These are five
> independent autotools projects linked via installed `.pc`/library files, not a
> single Makefile with real header/library dependencies. If `CoinUtils` changes,
> `make` inside `Clp`/`Cgl`/`Cbc` has **no idea** anything changed — it will happily
> link against a stale installed `libCoinUtils`. **`build` compensates for this
> by tracking each submodule's git commit (+ dirty-tree state) and force-cleaning
> and rebuilding every downstream dependent whenever an upstream project's sources
> changed**, using this dependency map:
>
> | Changed project | Forces rebuild of |
> |---|---|
> | `CoinUtils` | `Osi`, `Clp`, `Cgl`, `Cbc` |
> | `Osi` | `Clp`, `Cgl`, `Cbc` |
> | `Clp` | `Cgl`, `Cbc` |
> | `Cgl` | `Cbc` |
> | `Cbc` | *(itself only)* |
>
> **Every rebuilt project is always `make install`-ed immediately after `make`**
> (there is no `--no-install` opt-out). Downstream projects discover their
> dependencies through the shared prefix's installed headers/libs/`.pc` files,
> not the in-tree build output — so building-without-installing would leave the
> *next* project in the same `build` run configured against stale artifacts,
> silently defeating the whole point of the dependents-rebuild logic above.
>
> Never hand-roll a partial rebuild (e.g. `cd Cbc && make`) after touching
> `CoinUtils`/`Osi`/`Clp`/`Cgl` — use `build`, or you will silently test against
> stale dependency libraries.

State is tracked in `.build-state` (gitignored) at the workspace root.

### Packaging relocatable distribution bundles — `package`

After `./config --install`, `./package` turns an installed prefix into a
self-contained, relocatable tarball (`.tar.gz`, or `.zip` on Windows) suitable
for CI artifact upload / release distribution:

```sh
./config --opt --install --prefix=/tmp/cbc-build
./package --prefix=/tmp/cbc-build --name=cbc-linux-x86_64 --out=dist
```

It copies the installed `bin/`/`lib/`/`include/`/`share/` tree, then for every
binary and shared library bundles any non-baseline-OS runtime dependency
(OpenBLAS, AMD/CHOLMOD, zlib, bz2, Nauty, libgfortran, etc.) alongside it and
rewrites rpath/RUNPATH (Linux: `patchelf`) or install names (macOS:
`install_name_tool`) to `$ORIGIN`/`@rpath`-relative paths — so the resulting
tarball runs on a bare target machine without the build system's `-dev`
packages installed. On Windows (MSYS2/MinGW) DLL dependencies are copied next
to the `.exe` instead, since Windows has no rpath concept.



Exploit all cores of the machine. Every script in this workspace (`config`,
`build`) defaults its job count to `$(nproc)` and never hardcodes a lower value.

- **`GNU parallel`** should be used for dispatching independent solver runs
  (benchmarking Cbc across many instances), same pattern as MIPster.
- Builds already parallelize internally (`make -j$(nproc)` per project).

## Testing

### Cbc's mip-sanity-data regression suite — `./test`

Cbc's main regression suite solves real MIP instances from the
[`h-g-s/mip-sanity-data`](https://github.com/h-g-s/mip-sanity-data) dataset
(365 instances across 16 problem families, each with a certified best-known/
optimal objective in `bks.tsv` and suggested node/time limits in
`limits.tsv`) and validates every saved solution. This suite is **entirely
self-contained in the `Cbc` repository** (on `next`) — `mip-sanity-data` is
wired in as a submodule at `Cbc/test/mip-sanity-data`, and the orchestration
script/validator live at `Cbc/test/run-mip-sanity-tests` /
`Cbc/test/cbc_validate_sol.cpp` — so it works from a standalone `Cbc` clone,
not just from within this workspace. `./test` at the cbc-workspace root is
just a convenience symlink to `Cbc/test/run-mip-sanity-tests`.

```sh
./config --opt --install     # build everything first
./test                        # run the full suite (all instances, nproc jobs)
./test 'jssp_*' 'cvrp_*'      # only instances matching these glob patterns
./test --jobs=4               # override parallelism
./test --update-data          # refresh the mip-sanity-data submodule first
```

How it works, per instance:
1. Runs `cbc <instance>.mps.gz -threads 1 -sec <time_limit> -maxNodes <node_limit>
   -solve -solu <instance>.sol` (one Cbc thread per instance; up to `--jobs`
   instances run concurrently via GNU parallel), using the suggested limits
   from `limits.tsv` (falls back to unlimited nodes / 120s / 180s hard-kill
   for instances not listed there).
2. Runs `cbc_validate_sol` against the saved `.sol` file, which:
   - parses Cbc's solution header to classify the run's status (proven
     optimal, proven infeasible, stopped-with-a-solution, or
     stopped-with-**no** integer solution — in which case the listed values
     are the fractional LP relaxation and are *not* checked for
     integrality/row feasibility, since Cbc saves that fractional solution
     when no integer-feasible one was found);
   - for genuine integer-feasible solutions: checks variable bounds,
     integrality, and every row's activity (tolerance `1e-4`), and
     recomputes the objective from the solution vector;
   - if optimality is claimed, cross-checks the objective against `bks.tsv`
     (tolerance `max(1e-4 absolute, 0.01% relative)`) — a mismatch is a hard
     error;
   - if infeasibility is claimed, cross-checks against `bks.tsv`'s expected
     status — a false infeasibility claim is a hard error.
3. Prints colored pass/fail progress per instance, then a summary; full Cbc
   log + validator output is printed for every failure.

Runs automatically in CI (`.github/workflows/sanity-tests.yml` in Cbc) on
every push/PR to `next`.

### Testing the C interface directly — `mip-c-solve`

`Cbc/test/mip-c-solve.cpp` (built via `Cbc/test/Makefile.am`, binary
`Cbc/test/mip-c-solve`) drives a MIP solve **purely through Cbc's C API**
(`Cbc_C_Interface.h` — `Cbc_newModel`/`Cbc_readMps`/`Cbc_readLp`,
`Cbc_setMaximumSeconds`/`Cbc_setMaximumNodes`, `Cbc_solve`, then
`Cbc_status`/`Cbc_isProvenOptimal`/`Cbc_getObjValue`/`Cbc_bestSolution`/
`Cbc_savedSolution`/...), so it doubles as a quick way to confirm the C
interface behaves the same as the `cbc` command line for a given instance.
It reports the whole solution pool's feasibility/objective consistency and,
when a best-known reference is available, cross-checks optimality claims
against it. Two invocation forms:

```sh
# Generic form — any MPS/MPS.gz/LP file, explicit limits, no lookup:
Cbc/test/mip-c-solve <instanceFileName> <timeLimit> <nodesLimit>
# e.g. mimicking `cbc file.mps.gz -sec 30 -maxNodes 5000 -solve`:
Cbc/test/mip-c-solve myinstance.mps.gz 30 5000

# mip-sanity-data instance-name form — applies limits.tsv/bks.tsv automatically:
Cbc/test/mip-c-solve 10teams
```

`nodesLimit` of `0` means unlimited. See `mip-c-solve --help` for the full
option list (`--threads`, `--log-level`, `--verbose`, `--expected-status`,
`--expected-obj`, `--data-dir`, ...). Exit code `0` = OK, `1` = a
feasibility/objective/optimality mismatch was found, `2` = usage/file error.

### Checking for regressions/improvements — `./compare-results`

`./test` always saves a per-instance results table to a TSV file — default
`Cbc/test/sanity-results/results.tsv`, overridable with
`--results-tsv=PATH` — with columns `instance status elapsed_s nodes
gap_pct is_optimal obj bound` (`status` is the validator outcome:
PASS/FAIL/OVERTIME/ERROR; `is_optimal` is 1 only for a confirmed/validated
optimum). **Whenever you implement a solver change (new cut, heuristic,
branching rule, etc.), always benchmark it against a baseline** using
`./compare-results` (a symlink to `Cbc/test/compare-mip-sanity-results`):

```sh
./test --results-tsv=/tmp/baseline.tsv        # run the suite before your change
# ...implement the change, rebuild with ./build...
./test --results-tsv=/tmp/after.tsv           # run the suite again after
./compare-results /tmp/baseline.tsv /tmp/after.tsv
```

`compare-results` prints an aggregate table (Passed/Failed/Overtime/Error
counts, confirmed-optimal count, average gap — each with a baseline/new/delta
column) plus a per-instance breakdown:
- **Regressions** — any instance whose validated status got strictly worse
  (e.g. `PASS -> FAIL/OVERTIME/ERROR`), or whose gap widened by more than
  `--gap-tol` (default `0.01` percentage points). This is what to watch for:
  more errors/overtimes, or wider gaps, indicate the change hurt performance
  or correctness.
- **Improvements** — the inverse: a status that got better, or a gap that
  narrowed by more than `--gap-tol`.

It exits `0` if no regressions were found and `1` otherwise, so it can gate
a script/CI step. Instances present in only one of the two files (e.g. after
`--update-data`, or when comparing a subset run against a full run) are
reported separately and excluded from the aggregate/per-instance comparison.
See `Cbc/test/compare-mip-sanity-results --help` for the full option list.

### Other projects

Each of the other 4 projects has its own test suite (`make check` / `test/`
directory, depending on the project). Run tests for a project after building
it, e.g.:
```sh
cd Osi/test && make -j$(nproc) && make test
```
Prefer testing the specific project(s) whose code changed rather than the whole
stack, unless the change is in a lower layer (`CoinUtils`, `Osi`, `Clp`) that could
affect everything downstream — in that case re-test all downstream projects too
(including Cbc's `./test`).

### Fetching "official" CI builds — `./fetch-ci-build`

`coin-or/Cbc`'s `next-release.yml` GitHub Actions workflow ("Next branch
release builds") builds relocatable `next`-branch binaries for 5 platforms
(Linux x86_64/aarch64, macOS arm64/x86_64, Windows x86_64) using **this
repo's own `config`/`package` scripts** (cloned at ref `main` inside the
workflow), so it's a convenient way to test against an "official",
independently-built binary — e.g. to confirm a `config`/`package` change
behaves the same in CI as it did locally, or to sanity-check a change without
doing a full local build.

```sh
./fetch-ci-build                       # trigger + wait + install to ~/prog/cbc-ci
./fetch-ci-build --prefix=/tmp/cbc-ci  # install elsewhere
./fetch-ci-build --no-trigger          # skip triggering; use the latest existing run
./fetch-ci-build --run-id=12345678     # fetch a specific already-completed run
./fetch-ci-build --dry-run             # show what would happen, do nothing
```

It: (a) triggers `next-release.yml` via `gh workflow run` (`workflow_dispatch`)
on `coin-or/Cbc@next`; (b) detects the local machine's OS/architecture and
polls **only the matching job** (not the full 5-platform matrix, so it
doesn't block on the slowest platform) until it completes; (c) downloads that
platform's artifact and installs it into `--prefix` (default `~/prog/cbc-ci`,
replaced wholesale on each run), recording provenance (run ID/URL, commit SHA,
fetch timestamp) in `<prefix>/.cbc-ci-build.info`. Requires `gh` (authenticated)
and `jq`. See `./fetch-ci-build --help` for the full option list
(`--repo`, `--workflow`, `--ref`, `--poll-interval`, `--timeout`, `--keep-tmp`).

## Code Formatting

`Cbc` (only — no other submodule currently has one) ships a `.clang-format`
file at its root (`Cbc/.clang-format`, WebKit-derived: 2-space indent, no
column limit, `SpacesInAngles: Always` so template args are written
`std::vector< std::pair< std::string, double > >`, etc.). This is the
project's canonical style, previously applied wholesale in commit
`8b713420` ("apply the formatting available in .clang-format for this
repository").

> ⚠️ **After any refactor that touches `Cbc/src/CbcSolver*` (or adds new
> files there), run `clang-format -i` over every changed file before
> committing** — manual edits/refactors drift from the config (missing
> angle-bracket spaces, inconsistent brace/indent style) and this has
> caused real inconsistency in the past. Example:
> ```sh
> cd Cbc
> clang-format -i src/CbcSolver.cpp src/CbcSolver.hpp src/CbcSolverHeuristics.cpp ...
> ```
> Formatting-only changes should be committed separately from functional
> changes, and validated with a rebuild + a quick `./test` subset (e.g.
> `./test 'bpc_*' 'kna*'`) to confirm the reformat didn't alter behavior.

## Related Work

This workspace complements — but is independent from — `h-g-s/mipster`, a separate
monorepo fork of Cbc (with CoinUtils/Clp/Cgl embedded and rebranded). Use
`cbc-workspace` for upstream COIN-OR development on `next` branches; use `mipster`
for the divergent rebranded fork. Do not cross-apply MIPster-specific instructions
(e.g. `CbcSolver` API refactor, removed GLPK/ASL support) to the upstream Cbc code
here — they do not apply.
