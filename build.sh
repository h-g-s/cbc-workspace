#!/usr/bin/env bash
# build.sh — incremental, dependency-aware build for the cbc-workspace multi-repo stack.
#
# Order: CoinUtils -> Osi -> Clp -> Cgl -> Cbc
#
# Because these are 5 independent autotools projects (not one Makefile with real
# cross-project header/lib dependencies), a change in an upstream project (e.g.
# CoinUtils) does NOT automatically trigger a rebuild in downstream projects
# (Osi/Clp/Cgl/Cbc) that link against its installed .pc/library files. This script
# detects such changes (git commit + dirty working tree per submodule) and force
# rebuilds every downstream dependent, in addition to whatever changed directly.
#
# Usage:
#   ./build.sh                # rebuild changed projects + dependents, then install
#   ./build.sh --no-install   # build only, skip `make install`
#   ./build.sh --force        # force full rebuild of all 5 projects
#   ./build.sh CoinUtils Clp  # restrict "changed" set to these + their dependents
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$WORKSPACE_ROOT/.build-state"
JOBS="$(nproc)"

REPOS=(CoinUtils Osi Clp Cgl Cbc)

# Dependents map: for each project, the set of projects that must be force-rebuilt
# if it changes (in dependency order, downstream only).
declare -A DEPENDENTS=(
  [CoinUtils]="Osi Clp Cgl Cbc"
  [Osi]="Clp Cgl Cbc"
  [Clp]="Cgl Cbc"
  [Cgl]="Cbc"
  [Cbc]=""
)

DO_INSTALL=1
FORCE=0
EXPLICIT_REPOS=()

for arg in "$@"; do
  case "$arg" in
    --no-install) DO_INSTALL=0 ;;
    --force) FORCE=1 ;;
    --jobs=*) JOBS="${arg#*=}" ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    CoinUtils|Osi|Clp|Cgl|Cbc) EXPLICIT_REPOS+=("$arg") ;;
    *) echo "Unknown option/repo: $arg" >&2; exit 1 ;;
  esac
done

echo "=== build.sh (jobs=$JOBS, install=$DO_INSTALL, force=$FORCE) ==="

# ---- compute current state (commit + dirty flag) per submodule ------------
declare -A CUR_STATE
for repo in "${REPOS[@]}"; do
  dir="$WORKSPACE_ROOT/src/$repo"
  if [[ ! -d "$dir/.git" ]]; then
    echo "warning: $dir is not a git checkout (submodule not initialized?) — skipping" >&2
    continue
  fi
  commit="$(git -C "$dir" rev-parse HEAD)"
  dirty="clean"
  git -C "$dir" diff --quiet -- . || dirty="dirty"
  git -C "$dir" diff --cached --quiet -- . || dirty="dirty"
  CUR_STATE[$repo]="$commit:$dirty"
done

# ---- load previous state ---------------------------------------------------
declare -A PREV_STATE
if [[ -f "$STATE_FILE" ]]; then
  while IFS='=' read -r k v; do
    [[ -z "$k" ]] && continue
    PREV_STATE[$k]="$v"
  done < "$STATE_FILE"
fi

# ---- determine directly-changed projects -----------------------------------
declare -A CHANGED
if [[ ${#EXPLICIT_REPOS[@]} -gt 0 ]]; then
  for r in "${EXPLICIT_REPOS[@]}"; do CHANGED[$r]=1; done
elif [[ $FORCE -eq 1 ]]; then
  for r in "${REPOS[@]}"; do CHANGED[$r]=1; done
else
  for repo in "${REPOS[@]}"; do
    [[ -z "${CUR_STATE[$repo]:-}" ]] && continue
    if [[ "${CUR_STATE[$repo]}" != "${PREV_STATE[$repo]:-}" ]]; then
      CHANGED[$repo]=1
    fi
  done
fi

# ---- propagate to dependents (force rebuild even though their own source
# didn't change) ---------------------------------------------------------
declare -A TO_BUILD
for repo in "${!CHANGED[@]}"; do
  TO_BUILD[$repo]=1
  for dep in ${DEPENDENTS[$repo]}; do
    TO_BUILD[$dep]=1
  done
done

if [[ ${#TO_BUILD[@]} -eq 0 ]]; then
  echo "Nothing changed since last successful build. Nothing to do."
  echo "(use --force to rebuild everything anyway)"
  exit 0
fi

echo "Projects to (re)build, in order:"
for repo in "${REPOS[@]}"; do
  [[ -n "${TO_BUILD[$repo]:-}" ]] && echo "  - $repo$( [[ -n "${CHANGED[$repo]:-}" ]] || echo ' (forced: upstream dependency changed)' )"
done
echo

# ---- build in order ---------------------------------------------------------
for repo in "${REPOS[@]}"; do
  [[ -z "${TO_BUILD[$repo]:-}" ]] && continue
  dir="$WORKSPACE_ROOT/src/$repo"
  [[ -d "$dir" ]] || continue

  echo "=== [$repo] make clean ==="
  make -C "$dir" clean >/dev/null 2>&1 || true

  echo "=== [$repo] make -j$JOBS ==="
  make -C "$dir" -j"$JOBS"

  if [[ $DO_INSTALL -eq 1 ]]; then
    echo "=== [$repo] make install ==="
    make -C "$dir" install
  fi
done

# ---- persist new state (only for repos actually built successfully) --------
{
  for repo in "${REPOS[@]}"; do
    [[ -n "${CUR_STATE[$repo]:-}" ]] && echo "$repo=${CUR_STATE[$repo]}"
  done
} > "$STATE_FILE"

echo
echo "build.sh done."
