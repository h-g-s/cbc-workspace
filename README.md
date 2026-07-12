# cbc-workspace

Multi-repository development workspace for the COIN-OR **Cbc** MIP solver and its
direct dependencies, wired together as git submodules:

```
CoinUtils -> Osi -> Clp -> Cgl -> Cbc
```

Each submodule tracks the official `coin-or/<repo>` upstream, checked out on a
`next` branch (see `AGENTS.md` for the full branching convention).

## Quick start

```sh
git clone --recurse-submodules git@github.com:h-g-s/cbc-workspace.git
cd cbc-workspace

# Interactive configuration wizard:
./conf_wiz

# Or non-interactive, configure + build + install everything:
./conf_wiz --opt --install

# Later, incremental rebuilds after editing sources (dependency-aware):
./build.sh
```

See `AGENTS.md` for full documentation: build system details, branching
convention, dependency-aware rebuild rules, and testing guidance.
