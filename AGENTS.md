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

### Optional dependencies (LAPACK/OpenBLAS, zlib, bz2, Nauty)

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
./build --no-install  # build only, skip `make install`
./build --force       # force a full rebuild of all 5 projects regardless of diffs
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
> Never hand-roll a partial rebuild (e.g. `cd Cbc && make`) after touching
> `CoinUtils`/`Osi`/`Clp`/`Cgl` — use `build`, or you will silently test against
> stale dependency libraries.

State is tracked in `.build-state` (gitignored) at the workspace root.

## Hardware & Parallelism

Exploit all cores of the machine. Every script in this workspace (`config`,
`build`) defaults its job count to `$(nproc)` and never hardcodes a lower value.

- **`GNU parallel`** should be used for dispatching independent solver runs
  (benchmarking Cbc across many instances), same pattern as MIPster.
- Builds already parallelize internally (`make -j$(nproc)` per project).

## Testing

Each project has its own test suite (`make check` / `test/` directory, depending on
the project). Run tests for a project after building it:
```sh
cd Cbc/test && make -j$(nproc) && make test
```
Prefer testing the specific project(s) whose code changed rather than the whole
stack, unless the change is in a lower layer (`CoinUtils`, `Osi`, `Clp`) that could
affect everything downstream — in that case re-test all downstream projects too.

## Related Work

This workspace complements — but is independent from — `h-g-s/mipster`, a separate
monorepo fork of Cbc (with CoinUtils/Clp/Cgl embedded and rebranded). Use
`cbc-workspace` for upstream COIN-OR development on `next` branches; use `mipster`
for the divergent rebranded fork. Do not cross-apply MIPster-specific instructions
(e.g. `CbcSolver` API refactor, removed GLPK/ASL support) to the upstream Cbc code
here — they do not apply.
