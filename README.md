# cbc-workspace

Multi-repository development workspace for the COIN-OR **Cbc** MIP solver and its
direct dependencies, wired together as git submodules:

```
CoinUtils -> Osi -> Clp -> Cgl -> Cbc
```

Each submodule tracks the official `coin-or/<repo>` upstream, checked out on a
`next` branch (see `AGENTS.md` for the full branching convention).

**Goal:** provide a comfortable, self-contained workspace for developing Cbc and
its dependencies together — usable equally well by human developers and by
coding agents/bots, with a single entry point (`./config`) to configure the
whole stack and a single command (`./build`) for correct, dependency-aware
incremental rebuilds afterwards.

## Quick start

```sh
git clone --recurse-submodules git@github.com:h-g-s/cbc-workspace.git
cd cbc-workspace

# Interactive configuration wizard:
./config

# Or non-interactive, configure + build + install everything:
./config --opt --install --prefix=~/prog/cbc

# Later, incremental rebuilds after editing sources (dependency-aware,
# always builds AND installs whatever changed + its downstream dependents):
./build
```

## `config` examples

```sh
# Optimised (release) build, installed to ~/prog/cbc:
./config --opt --install --prefix=~/prog/cbc

# Debug build with AddressSanitizer, installed to its own prefix
# (debug builds are suffixed automatically, e.g. ~/prog/cbc-asan):
./config --debug --sanitizer=asan --install --prefix=~/prog/cbc

# Debug build with ThreadSanitizer:
./config --debug --sanitizer=tsan --install --prefix=~/prog/cbc
```

`config` also lets you pick the target CPU architecture (`--arch=...`), toggle
hand-written AVX2 SIMD paths, select which optional dependencies to link
(LAPACK/OpenBLAS, zlib, bz2, Nauty — auto-detected, Homebrew-aware), and choose
static/shared/both library types. Run `./config --help` for the full list of
flags, or just run `./config` with no arguments for the interactive wizard.

### Wizard screenshots

| Build mode | Sanitiser (debug only) |
|---|---|
| ![Build mode selection](docs/img/config-build-mode.png) | ![Sanitiser selection](docs/img/config-sanitizer.png) |

| Optional dependencies | Configuration summary |
|---|---|
| ![Optional dependencies checklist](docs/img/config-optional-deps.png) | ![Configuration summary](docs/img/config-summary.png) |

## `build`

```sh
./build              # rebuild whatever changed (+ dependents), then install
./build --force       # force a full rebuild + install of all 5 projects
./build CoinUtils     # rebuild only this project and everything that depends on it
```

`build` tracks each submodule's git commit + dirty-tree state and automatically
force-rebuilds every downstream dependent whenever an upstream project's
sources changed (e.g. editing `CoinUtils` forces `Osi`, `Clp`, `Cgl`, and `Cbc`
to rebuild too). Every rebuilt project is always `make install`-ed immediately
afterwards, since downstream projects discover their dependencies through the
shared prefix's installed headers/libraries/`.pc` files, not the in-tree build
output.

See `AGENTS.md` for full documentation: build system details, branching
convention, dependency-aware rebuild rules, and testing guidance.
