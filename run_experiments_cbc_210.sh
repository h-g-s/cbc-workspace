#!/usr/bin/env bash
# run_experiments_cbc_210.sh — run mip-sanity-data experiments with an old
# stable COIN-OR Cbc 2.10 release binary, for baseline comparison against
# this workspace's current `next`-branch build (via ./run_full_benchmark).
#
# Ported from MIPster's `scripts/run_experiments_cbc_stable.sh`
# (h-g-s/mipster), adapted to this workspace's `Cbc/test/mip-sanity-data`
# instance set (bks.tsv/limits.tsv) instead of MIPLIB's
# solution_metadata.csv/benchmark.csv, and reusing the instance-discovery /
# reference-lookup / reporting conventions already established by
# `./run_full_benchmark`.
#
# Key differences from ./run_full_benchmark (which targets this workspace's
# current Cbc build):
#   - Always injects "-timeMode elapsed" before "-seconds" (Cbc 2.10 defaults
#     to CPU time; wall-clock time is what's comparable across runs/machines)
#   - Always injects default MIP gap tolerances matching HiGHS's defaults, so
#     a 2.10 vs current-build comparison isn't confounded by looser stopping
#     criteria: "-allowableGap 1e-6" (absolute, HiGHS mip_abs_gap) and
#     "-ratioGap 1e-4" (relative, HiGHS mip_rel_gap) — override with
#     --allowable-gap/--ratio-gap if needed
#   - No -writeStat support (Cbc 2.10 does not have this extension); all
#     result extraction is done purely from log parsing
#   - No -threads support (Cbc 2.10's CLI has no -threads keyword)
#   - No ASan/TSan/valgrind/--env options (this script targets a plain
#     release build of an old tag, not this workspace's sanitizer builds)
#   - Log parsing uses precise patterns tied to Cbc 2.10's Result block
#     format: "^Objective value:" for the best incumbent, "^Lower bound:"
#     for the dual bound, "^Gap:" for the primal-dual gap, and
#     "^Result - Stopped on time"/"^Result - .*infeasible" for status
#
# Output layout ($OUTDIR/), same as ./run_full_benchmark for interoperability
# with ./compare-benchmarks and ./compare-results:
#   summary.tsv              — one row per instance: status, obj, dual_bound,
#                               expected, elapsed_s, threads, gap_field,
#                               solution_found, proven_infeasible, timed_out
#   <instance>.log            — full Cbc stdout/stderr
#   <instance>.sol            — solution file (present when feasible solution found)
#   <instance>.validate.log   — cbc_validate_sol output
#   <instance>.err            — extracted error snippet (wrong obj / crash / invalid sol)
#   parallel.log              — GNU parallel job log (timing, exit codes)
#   report.txt                — human-readable summary
#   memory_usage.tsv          — memory utilisation sampled every 5 min during the run
#   experiment_setup.md       — binary info, hardware, and experiment parameters
#
# Status values in summary.tsv:
#   SOLVED            proven optimal; objective matches the mip-sanity-data reference
#   SOLVED(no_ref)    proven optimal; no reference objective available
#   SOLVED(inf)       proven infeasible; bks.tsv agrees (or no reference)
#   WRONG_OBJ         solved but objective is worse than the reference
#   INVALID_SOL       Cbc found a solution but cbc_validate_sol rejected it
#   INFEASIBLE_WRONG  Cbc proved infeasible but a numeric objective was expected
#   NO_SOLUTION       Cbc exited normally but found no feasible solution
#   TIMEOUT           reached the time/node limit; Cbc exited on its own
#   TIMEOUT(no_sol)   timed out without finding any feasible solution
#   TIMEOUT(gap=X%)   timed out with a feasible solution, remaining gap X%
#   OVERTIME          Cbc ignored its own -seconds/-maxNodes limit and was hard-killed
#   CRASH(exit=N)     non-zero exit code, not a known timeout
#
# Usage:
#   ./run_experiments_cbc_210.sh --bin PATH/TO/cbc-2.10 [OPTIONS] [instance-glob ...]
#
# Required:
#   --bin PATH          Path to the Cbc 2.10 binary (e.g. a checkout of
#                        coin-or/Cbc at tag releases/2.10.* built standalone,
#                        NOT this workspace's ./config-built binary)
#
# Optional (positional arguments select a subset of mip-sanity-data by name,
# e.g. `./run_experiments_cbc_210.sh --bin ... 'jssp_*' 'cvrp_*'`):
#   --parallel N         Instances to run concurrently (default: nproc)
#   --timelimit T        Cbc -seconds time limit; overrides per-instance
#                        limits.tsv suggestion for every instance (default: use
#                        limits.tsv, falling back to 120s for unlisted instances)
#   --overtime-grace G   Seconds to wait after the time limit before hard-killing
#                        Cbc (default: use limits.tsv hard_kill, falling back to
#                        180s). Instance is tagged OVERTIME if killed.
#   --allowable-gap G    Cbc -allowableGap (absolute MIP gap; default: 1e-6,
#                        matches HiGHS's mip_abs_gap default)
#   --ratio-gap G        Cbc -ratioGap (relative MIP gap; default: 1e-4,
#                        matches HiGHS's mip_rel_gap default)
#   --outdir DIR         Output directory (default: auto-named under exp_results/)
#   --instances DIR      mip-sanity-data checkout with mips/*.mps.gz, bks.tsv,
#                        limits.tsv (default: Cbc/test/mip-sanity-data)
#   --opts FLAG          Extra Cbc flag before -solve (repeatable)
#                        e.g. --opts "-probing 1" --opts "-gomory 1"
#   --dry-run            Print commands without executing them
#   -h, --help           Show this help message and exit
#
# Examples:
#   # Default run over the full mip-sanity-data set, using an old stable build:
#   ./run_experiments_cbc_210.sh --bin ~/dev/cbc-stable/Cbc/Cbc/src/cbc
#
#   # Only a couple of families, 300s/instance, 20 at a time:
#   ./run_experiments_cbc_210.sh --bin ~/dev/cbc-stable/Cbc/Cbc/src/cbc \
#     --timelimit 300 --parallel 20 'jssp_*' 'cvrp_*'
#
#   # Compare against this workspace's current build on the same instances:
#   ./run_full_benchmark             --outdir exp_results/current
#   ./run_experiments_cbc_210.sh --bin ~/dev/cbc-stable/Cbc/Cbc/src/cbc \
#                                 --outdir exp_results/cbc210
#   ./compare-benchmarks current=exp_results/current cbc210=exp_results/cbc210
set -uo pipefail
trap '' HUP   # survive terminal disconnection while GNU parallel workers run

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

show_help() {
  sed -n '2,99p' "$0" | sed 's/^# \{0,1\}//'
}

# ── Defaults ──────────────────────────────────────────────────────────────────
CBC_BIN=""
PARALLEL="$(nproc)"
TIMELIMIT=""
OVERTIME_GRACE=""
ALLOWABLE_GAP="1e-6"
RATIO_GAP="1e-4"
INSTANCES_DIR="$REPO_ROOT/Cbc/test/mip-sanity-data"
OUTDIR=""
CBC_EXTRA_OPTS=()
DRY_RUN=0
PATTERNS=()

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin)            CBC_BIN="$2";              shift 2 ;;
    --parallel)       PARALLEL="$2";              shift 2 ;;
    --timelimit)      TIMELIMIT="$2";             shift 2 ;;
    --overtime-grace) OVERTIME_GRACE="$2";        shift 2 ;;
    --allowable-gap)  ALLOWABLE_GAP="$2";         shift 2 ;;
    --ratio-gap)      RATIO_GAP="$2";             shift 2 ;;
    --outdir)         OUTDIR="$2";                shift 2 ;;
    --instances)      INSTANCES_DIR="$2";         shift 2 ;;
    --opts)           CBC_EXTRA_OPTS+=("$2");     shift 2 ;;
    --dry-run)        DRY_RUN=1;                  shift   ;;
    -h|--help)        show_help; exit 0                   ;;
    -*) echo "Unknown option: $1" >&2; exit 1  ;;
    *) PATTERNS+=("$1");                          shift   ;;
  esac
done

[[ -z "$CBC_BIN" ]] && { echo "Error: --bin is required (path to a Cbc 2.10 binary)." >&2; exit 1; }
[[ -x "$CBC_BIN" ]] || { echo "Error: $CBC_BIN is not executable." >&2; exit 1; }

REL_TOL=1e-4
ABS_TOL=1e-4
# GAP_REL_TOL/GAP_ABS_TOL are the tolerances used when cross-checking a
# claimed-optimal objective against mip-sanity-data's best-known value (in
# this script's own ref_allows_obj/gap_vs_ref helpers) — as opposed to
# REL_TOL/ABS_TOL above, which feed cbc_validate_sol's generic numerical-
# correctness checks (-p/-i/-o) and stay at a conservative 1e-4 regardless.
# They default to exactly the -ratioGap/-allowableGap values this script
# forces on every Cbc invocation (see ALLOWABLE_GAP/RATIO_GAP above), so that
# a solution Cbc legitimately reports as "Optimal solution found (within gap
# tolerance)" — i.e. one that stopped on the gap rather than proving exact
# optimality — is never misclassified as WRONG_OBJ: by construction Cbc only
# stops early when |incumbent - bestPossible| <= max(ratioGap * |obj|,
# allowableGap), and since the true optimum lies between those two bounds,
# the reported objective is guaranteed to be within that same tolerance of
# the reference value. (Matches ./run_full_benchmark's GAP_REL_TOL/GAP_ABS_TOL.)
GAP_REL_TOL="$RATIO_GAP"
GAP_ABS_TOL="$ALLOWABLE_GAP"
# Cbc 2.10 prints .sol variable values with only ~6-8 significant digits, so
# rows summing many large-magnitude terms can show a spurious multi-unit
# activity "violation" from print rounding alone, not a real infeasibility
# (see cbc_validate_sol's --row-scale-tol). Scale by 1e-6 to absorb that.
ROW_SCALE_TOL=1e-6

echo "==> Using cbc (2.10 stable): $CBC_BIN"

# ── Snapshot binary (+ sibling libs) so rebuilds during the run don't interfere ─
EXP_TMPDIR=$(mktemp -d /tmp/cbc_210_exp_XXXXXXXX)
trap 'rm -rf "${EXP_TMPDIR:-}"' EXIT
mkdir -p "$EXP_TMPDIR/bin"
ORIGINAL_CBC_BIN="$CBC_BIN"
ORIGINAL_BINDIR="$(cd "$(dirname "$CBC_BIN")" && pwd)"
TMP_CBC_BIN="$EXP_TMPDIR/bin/$(basename "$CBC_BIN")"
cp "$CBC_BIN" "$TMP_CBC_BIN"
chmod +x "$TMP_CBC_BIN"
for f in "$ORIGINAL_BINDIR"/*; do
  [[ -f "$f" && -x "$f" ]] && cp "$f" "$EXP_TMPDIR/bin/"
done
if [[ -d "$ORIGINAL_BINDIR/../lib" ]]; then
  mkdir -p "$EXP_TMPDIR/lib"
  cp -rP "$ORIGINAL_BINDIR/../lib/"* "$EXP_TMPDIR/lib/" 2>/dev/null || true
fi
CBC_BIN="$TMP_CBC_BIN"
echo "    (snapshotted to: $CBC_BIN)"

# ── Locate/build the validator (shared with ./run_full_benchmark / ./test) ───
VALIDATOR="$REPO_ROOT/Cbc/test/cbc_validate_sol"
if [[ ! -x "$VALIDATOR" ]]; then
  echo "==> Building cbc_validate_sol..."
  if [[ ! -f "$REPO_ROOT/Cbc/test/Makefile" ]]; then
    echo "Error: Cbc/test/Makefile missing — configure Cbc first (./config --opt --install)." >&2
    exit 1
  fi
  make -C "$REPO_ROOT/Cbc/test" cbc_validate_sol || {
    echo "Error: failed to build cbc_validate_sol." >&2
    exit 1
  }
fi
echo "==> Using validator: $VALIDATOR"

# ── Instances / references (mip-sanity-data layout, same as ./run_full_benchmark) ─
[[ -f "$INSTANCES_DIR/bks.tsv" ]] || { echo "Error: $INSTANCES_DIR/bks.tsv not found." >&2; exit 1; }
if [[ -d "$INSTANCES_DIR/mips" ]]; then
  MIPS_DIR="$INSTANCES_DIR/mips"
else
  MIPS_DIR="$INSTANCES_DIR"
fi
mapfile -t ALL_INSTANCES < <(cd "$MIPS_DIR" && ls *.mps.gz 2>/dev/null | sed 's/\.mps\.gz$//' | sort)
[[ ${#ALL_INSTANCES[@]} -eq 0 ]] && { echo "No .mps.gz files in $MIPS_DIR" >&2; exit 1; }

BKS_HEADER_COLS=$(head -1 "$INSTANCES_DIR/bks.tsv" | awk -F'\t' '{print NF}')
if [[ "$BKS_HEADER_COLS" -ge 4 ]]; then
  BKS_FORMAT="sanity"   # instance status objective sense [source]
else
  BKS_FORMAT="miplib"   # instance bks
fi
echo "==> Instances: $MIPS_DIR ($BKS_FORMAT-format bks.tsv$([[ -f "$INSTANCES_DIR/limits.tsv" ]] || echo ", no limits.tsv — using defaults/--timelimit"))"

INSTANCES=()
if [[ ${#PATTERNS[@]} -eq 0 ]]; then
  INSTANCES=("${ALL_INSTANCES[@]}")
else
  for name in "${ALL_INSTANCES[@]}"; do
    for pat in "${PATTERNS[@]}"; do
      # shellcheck disable=SC2053
      if [[ "$name" == $pat ]]; then INSTANCES+=("$name"); break; fi
    done
  done
fi
[[ ${#INSTANCES[@]} -eq 0 ]] && { echo "No instances matched the given pattern(s)." >&2; exit 1; }
TOTAL=${#INSTANCES[@]}

# ── Output directory ──────────────────────────────────────────────────────────
if [[ -z "$OUTDIR" ]]; then
  VARIANT="cbc210"
  TS=$(date +%Y%m%d_%H%M%S)
  OUTDIR="exp_results/${VARIANT}_p${PARALLEL}_${TS}"
fi
mkdir -p "$OUTDIR"
SUMMARY="$OUTDIR/summary.tsv"
REPORT="$OUTDIR/report.txt"

# ── Colour support (TTY + not NO_COLOR) ───────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then USE_COLOR=1; else USE_COLOR=0; fi

# ── Serialise arrays for export to GNU parallel workers ──────────────────────
CBC_EXTRA_OPTS_STR=$(printf '%s\n' "${CBC_EXTRA_OPTS[@]+"${CBC_EXTRA_OPTS[@]}"}")

export CBC_BIN VALIDATOR OUTDIR TIMELIMIT OVERTIME_GRACE INSTANCES_DIR MIPS_DIR BKS_FORMAT
export ALLOWABLE_GAP RATIO_GAP CBC_EXTRA_OPTS_STR
export REL_TOL ABS_TOL GAP_REL_TOL GAP_ABS_TOL ROW_SCALE_TOL DRY_RUN USE_COLOR

# ── Helper: objective within tolerance of an exact reference ─────────────────
obj_ok() {
  local got="$1" ref="$2"
  awk -v got="$got" -v ref="$ref" -v rtol="$GAP_REL_TOL" -v atol="$GAP_ABS_TOL" \
    'BEGIN {
       diff = got - ref; if (diff < 0) diff = -diff
       absref = ref < 0 ? -ref : ref
       tol = rtol * absref; if (atol > tol) tol = atol
       exit (diff <= tol) ? 0 : 1
     }'
}
export -f obj_ok

# kind: "optimal" (exact) or "best_known" (one-sided). sense: min/max.
ref_allows_obj() {
  local got="$1" ref="$2" kind="$3" sense="$4"
  if [[ "$kind" == "best_known" ]]; then
    case "$sense" in
      min)
        awk -v got="$got" -v ref="$ref" -v rtol="$GAP_REL_TOL" -v atol="$GAP_ABS_TOL" '
          BEGIN { tol = rtol * ((ref<0)?-ref:ref); if (atol>tol) tol=atol; exit (got <= ref + tol) ? 0 : 1 }'
        return ;;
      max)
        awk -v got="$got" -v ref="$ref" -v rtol="$GAP_REL_TOL" -v atol="$GAP_ABS_TOL" '
          BEGIN { tol = rtol * ((ref<0)?-ref:ref); if (atol>tol) tol=atol; exit (got + tol >= ref) ? 0 : 1 }'
        return ;;
    esac
  fi
  obj_ok "$got" "$ref"
}
export -f ref_allows_obj

gap_vs_ref() {
  local got="$1" ref="$2" kind="$3" sense="$4"
  awk -v got="$got" -v ref="$ref" -v kind="$kind" -v sense="$sense" -v rtol="$GAP_REL_TOL" -v atol="$GAP_ABS_TOL" '
    function abs(x) { return x < 0 ? -x : x }
    BEGIN {
      absref = abs(ref); tol = rtol * absref; if (atol > tol) tol = atol
      if (kind == "best_known" && sense == "min") diff = got - ref
      else if (kind == "best_known" && sense == "max") diff = ref - got
      else diff = abs(got - ref)
      if (diff <= tol) { print "0.0%"; exit 0 }
      if (absref <= 1e-10) { print "100%"; exit 0 }
      pct = diff / absref * 100.0
      if (pct > 100.0) print "100%"; else printf "%.1f%%\n", pct
    }'
}
export -f gap_vs_ref

fmt_time() {
  local s=$1 t
  if   (( s < 60 ));   then t=$(printf "%ds"     "$s")
  elif (( s < 3600 )); then t=$(printf "%dm%02ds" "$((s/60))" "$((s%60))")
  else                      t=$(printf "%dh%02dm" "$((s/3600))" "$(( (s%3600)/60 ))")
  fi
  printf "%6s" "$t"
}
export -f fmt_time

# ── Per-instance worker (called by GNU parallel) ──────────────────────────────
run_instance() {
  local name="$1"
  local mps="$MIPS_DIR/${name}.mps.gz"
  local logfile="$OUTDIR/${name}.log"
  local errfile="$OUTDIR/${name}.err"
  local resultfile="$OUTDIR/${name}.result"
  local solutionfile="$OUTDIR/${name}.sol"
  local validatelog="$OUTDIR/${name}.validate.log"
  rm -f "$solutionfile" "$logfile" "$errfile" "$resultfile" "$validatelog"

  # ── suggested limits from limits.tsv (unless --timelimit overrides them) ────
  local node_limit=0 time_limit=120 hard_kill=180
  local limits_row
  limits_row="$(awk -F'\t' -v n="$name" '$1==n{print $3"\t"$4"\t"$5; found=1} END{if(!found) exit 1}' \
    "$INSTANCES_DIR/limits.tsv" 2>/dev/null)"
  [[ -n "$limits_row" ]] && IFS=$'\t' read -r node_limit time_limit hard_kill <<< "$limits_row"
  if [[ -n "$TIMELIMIT" ]]; then
    time_limit="$TIMELIMIT"
    hard_kill=$(( TIMELIMIT + ${OVERTIME_GRACE:-180} ))
  elif [[ -n "$OVERTIME_GRACE" ]]; then
    hard_kill=$(( time_limit + OVERTIME_GRACE ))
  fi

  # ── expected status/objective/sense from bks.tsv ────────────────────────────
  local bks_row exp_status="" exp="" exp_sense=""
  if [[ "$BKS_FORMAT" == "sanity" ]]; then
    bks_row="$(awk -F'\t' -v n="$name" '$1==n{print $2"\t"$3"\t"$4; found=1} END{if(!found) exit 1}' \
      "$INSTANCES_DIR/bks.tsv" 2>/dev/null)"
    [[ -n "$bks_row" ]] && IFS=$'\t' read -r exp_status exp exp_sense <<< "$bks_row"
    [[ "$exp" == "NA" ]] && exp=""
  else
    # Flat MIPLIB-style bks.tsv: "instance\tbks" where bks is a numeric value,
    # "infeasible", or "nan"/blank (no reference known). No sense info is
    # available, so numeric references are treated as "best_known" with no
    # sense — ref_allows_obj/gap_vs_ref then fall back to an exact-tolerance
    # match.
    local bks_val
    bks_val="$(awk -F'\t' -v n="$name" '$1==n{print $2; found=1} END{if(!found) exit 1}' \
      "$INSTANCES_DIR/bks.tsv" 2>/dev/null)"
    if [[ "$bks_val" == "infeasible" ]]; then
      exp_status="infeasible"
    elif [[ -n "$bks_val" && "$bks_val" != "nan" ]]; then
      exp_status="best_known"
      exp="$bks_val"
    fi
  fi

  # Reconstruct extra Cbc opts (each line may contain multiple words)
  local cbc_extra=()
  if [[ -n "$CBC_EXTRA_OPTS_STR" ]]; then
    while IFS= read -r opt; do
      [[ -n "$opt" ]] || continue
      read -ra words <<< "$opt"
      cbc_extra+=("${words[@]}")
    done <<< "$CBC_EXTRA_OPTS_STR"
  fi

  local node_args=()
  [[ "$node_limit" != "0" ]] && node_args=(-maxNodes "$node_limit")

  # -timeMode elapsed MUST come before -seconds so the limit is measured in
  # wall-clock time (Cbc 2.10 defaults to CPU time). -allowableGap/-ratioGap
  # set the default MIP gap tolerances (HiGHS-equivalent) so a comparison
  # against ./run_full_benchmark isn't confounded by looser stopping criteria.
  local cmd=("$CBC_BIN" "$mps"
             "-timeMode" "elapsed"
             "-allowableGap" "$ALLOWABLE_GAP"
             "-ratioGap" "$RATIO_GAP"
             "-seconds" "$time_limit" "${node_args[@]}")
  [[ ${#cbc_extra[@]} -gt 0 ]] && cmd+=("${cbc_extra[@]}")
  cmd+=("-solve" "-solu" "$solutionfile" "-quit")

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: ${cmd[*]}"
    return 0
  fi

  local start_ts end_ts elapsed
  start_ts=$(date +%s.%N)
  set +e
  timeout --kill-after=30 "${hard_kill}s" "${cmd[@]}" > "$logfile" 2>&1
  local exit_code=$?
  set -e
  end_ts=$(date +%s.%N)
  elapsed=$(awk -v a="$start_ts" -v b="$end_ts" 'BEGIN{printf "%d", b-a}')

  # ── Extract results from log ──────────────────────────────────────────────
  # Use the final "Result - ..." line as the canonical status indicator. Cbc
  # 2.10 prints this block once per solve (occasionally twice for presolve +
  # main solve); tail -1 always picks the definitive last one.
  local result_line
  result_line=$(grep '^Result - ' "$logfile" | tail -1 || true)

  # Fallback: infeasibility/unboundedness detected during preprocessing/cut
  # generation (e.g. "Pre-processing says infeasible or unbounded") makes
  # Cbc 2.10 exit 0 without ever printing a "Result - ..." line to the log,
  # even though it still writes a .sol file whose own header carries the
  # real status (e.g. "Integer infeasible - objective value ..."). Without
  # this fallback such runs were silently misclassified as NO_SOLUTION.
  if [[ -z "$result_line" && -f "$solutionfile" ]]; then
    local sol_header
    sol_header=$(head -1 "$solutionfile")
    if echo "$sol_header" | grep -qi 'infeasible\|unbounded'; then
      result_line="Result - $sol_header"
    fi
  fi

  local proven_infeasible=0
  echo "$result_line" | grep -qi 'infeasible' && proven_infeasible=1

  local timed_out=0
  echo "$result_line" | grep -qi 'stopped on time\|stopped on node' && timed_out=1

  # Best incumbent — "Objective value:" appears only in the Result block and
  # only when Cbc has found a feasible integer solution.
  local obj
  obj=$(grep '^Objective value:' "$logfile" | tail -1 | grep -oP '[-\d.eE+]+$' || true)

  # Discard sentinel "no incumbent" values Cbc sometimes emits (±1e50).
  if [[ -n "$obj" ]] && awk -v x="$obj" 'BEGIN { exit (x >= 1e49 || x <= -1e49) ? 0 : 1 }'; then
    obj=""
  fi

  local no_feasible_solution=0
  [[ -z "$obj" && $proven_infeasible -eq 0 ]] && no_feasible_solution=1

  # Dual bound (lower bound for minimisation).
  local dual
  dual=$(grep -oP '^Lower bound:\s+\K[-\d.eE+]+' "$logfile" | tail -1 || true)
  if [[ -n "$dual" ]] && awk -v x="$dual" 'BEGIN { exit (x >= 1e49 || x <= -1e49) ? 0 : 1 }'; then
    dual=""
  fi
  # For proven-optimal cases the dual bound equals the primal; fill from obj.
  if [[ -z "$dual" && -n "$obj" && $timed_out -eq 0 && $proven_infeasible -eq 0 ]]; then
    dual="$obj"
  fi

  local solution_found=0
  [[ -n "$obj" ]] && solution_found=1

  # ── Validate solution with cbc_validate_sol ────────────────────────────────
  local validation_failed=0 validation_msg=""
  if [[ $solution_found -eq 1 && -f "$solutionfile" && -x "$VALIDATOR" ]]; then
    local val_args=(-p "$ABS_TOL" -i "$ABS_TOL" -o "$REL_TOL" --row-scale-tol "$ROW_SCALE_TOL")
    if [[ "$exp_status" == "optimal" || "$exp_status" == "infeasible" ]]; then
      val_args+=(--expected-status "$exp_status")
    fi
    [[ -n "$exp" ]] && val_args+=(--expected-obj "$exp")
    set +e
    "$VALIDATOR" "${val_args[@]}" "$mps" "$solutionfile" > "$validatelog" 2>&1
    local validate_exit=$?
    set -e
    if [[ $validate_exit -eq 1 ]]; then
      validation_failed=1
      validation_msg=$(grep -m1 -E "MISMATCH|^  BOUND:|^  INTEG:|^  ROW:|^  OBJ:" "$validatelog")
      [[ -z "$validation_msg" ]] && validation_msg="Validation failed (see ${name}.validate.log)"
    fi
  fi

  local ref_kind="optimal"
  [[ "$exp_status" == "best_known" ]] && ref_kind="best_known"

  # ── Gap for timed-out runs with a feasible solution ───────────────────────
  local cbc_gap="-"
  if [[ $timed_out -eq 1 && -n "$obj" ]]; then
    local raw_gap
    raw_gap=$(grep -oP '^Gap:\s+\K[-\d.eE+]+' "$logfile" | tail -1 || true)
    if [[ -n "$raw_gap" ]]; then
      cbc_gap=$(awk -v g="$raw_gap" 'BEGIN { pct=g*100; if (pct>100) print "100%"; else printf "%.1f%%\n", pct }')
    elif [[ -n "$exp" ]]; then
      cbc_gap=$(gap_vs_ref "$obj" "$exp" "$ref_kind" "$exp_sense")
    fi
  fi

  # ── Classify status ──────────────────────────────────────────────────────────
  local status
  if [[ $exit_code -eq 124 || $exit_code -eq 137 ]]; then
    status="OVERTIME"; cbc_gap="300%"
  elif [[ $exit_code -ne 0 ]]; then
    status="CRASH(exit=$exit_code)"
  elif [[ $validation_failed -eq 1 ]]; then
    status="INVALID_SOL"
  elif [[ $proven_infeasible -eq 1 ]]; then
    if [[ "$exp_status" == "infeasible" || -z "$exp_status" ]]; then
      status="SOLVED(inf)"
    else
      status="INFEASIBLE_WRONG"
    fi
  elif [[ -z "$obj" ]]; then
    if [[ $timed_out -eq 1 ]]; then status="TIMEOUT(no_sol)"; else status="NO_SOLUTION"; fi
    cbc_gap="200%"
  elif [[ $timed_out -eq 1 ]]; then
    if [[ "$cbc_gap" != "-" ]]; then status="TIMEOUT(gap=${cbc_gap})"; else status="TIMEOUT"; fi
  elif [[ -n "$exp" ]]; then
    if ref_allows_obj "$obj" "$exp" "$ref_kind" "$exp_sense"; then
      status="SOLVED"; cbc_gap="0%"
    else
      status="WRONG_OBJ"
    fi
  else
    status="SOLVED(no_ref)"; cbc_gap="0%"
  fi

  # ── Write .err snippet for actionable failures ────────────────────────────
  > "$errfile"
  if [[ "$status" == "INVALID_SOL" ]]; then
    { echo "=== Solution validation failed ==="; echo "  Cbc reported: $obj"
      [[ -n "$validation_msg" ]] && echo "  $validation_msg"; echo ""
      echo "  See ${name}.validate.log for full validation output"; echo ""; } >> "$errfile"
  fi
  if [[ "$status" == "WRONG_OBJ" ]]; then
    { echo "=== Objective worse than reference ==="; echo "  got:      $obj"; echo "  expected: $exp"
      echo "  ref kind: $ref_kind"; [[ -n "$exp_sense" ]] && echo "  sense:    $exp_sense"; echo ""; } >> "$errfile"
  fi
  if [[ "$status" == "OVERTIME" ]]; then
    { echo "=== Cbc ignored its time/node limit ==="; printf "  Timelimit:  %ds\n" "$time_limit"
      printf "  Wallclock:  %ds (killed after hard_kill=%ds)\n" "$elapsed" "$hard_kill"; echo ""; } >> "$errfile"
  fi
  if [[ "$status" =~ ^CRASH ]]; then
    { echo "=== Exit code: $exit_code ==="; echo ""; } >> "$errfile"
  fi
  [[ ! -s "$errfile" ]] && rm -f "$errfile"

  # ── Write machine-readable result for summary assembly ────────────────────
  printf "%s\t%s\t%s\t%s\t%d\t%s\t%s\t%d\t%d\t%d\n" \
    "$status" "${obj:--}" "${dual:--}" "${exp:--}" "$elapsed" "1" "$cbc_gap" \
    "$solution_found" "$proven_infeasible" "$timed_out" > "$resultfile"

  # ── One-line console output ───────────────────────────────────────────────
  local C_RESET='' C_BGREEN='' C_CYAN='' C_BYELLOW='' C_BRED=''
  if [[ "${USE_COLOR:-0}" -eq 1 ]]; then
    C_RESET='\033[0m'; C_BGREEN='\033[1;32m'; C_CYAN='\033[0;36m'; C_BYELLOW='\033[1;33m'; C_BRED='\033[1;31m'
  fi
  local icon sc
  case "$status" in
    SOLVED|SOLVED\(*)      icon="✓"; sc="$C_BGREEN"  ;;
    TIMEOUT*)              icon="⏱"; sc="$C_CYAN"    ;;
    NO_SOLUTION)           icon="⚠"; sc="$C_BYELLOW" ;;
    *)                     icon="✗"; sc="$C_BRED"    ;;
  esac
  local display_name="$name"
  (( ${#name} > 38 )) && display_name="${name:0:37}…"
  local extra=""
  [[ "$status" == "INVALID_SOL" ]]      && extra="  validation failed"
  [[ "$status" == "WRONG_OBJ" ]]        && extra="  exp=${exp}"
  [[ "$status" == "INFEASIBLE_WRONG" ]] && extra="  exp=${exp}"
  local padded_status padded_obj time_str
  padded_status=$(printf "%-20s" "$status")
  padded_obj=$(printf "%-16s" "${obj:--}")
  time_str=$(fmt_time "$elapsed")
  printf "  %b%s%b %-38s  %b%s%b  %s  wall=%s%s\n" \
    "$sc" "$icon" "$C_RESET" "$display_name" "$sc" "$padded_status" "$C_RESET" "$padded_obj" "$time_str" "$extra"
}
export -f run_instance

# ── Write experiment_setup.md ─────────────────────────────────────────────────
write_setup_md() {
  local bin="$1"
  local md="$OUTDIR/experiment_setup.md"

  local bin_version bin_build_date bin_mtime bin_size_kb
  bin_version=$(  "$bin" 2>&1 </dev/null | grep '^Version:'    | head -1 | awk '{print $2}' || true)
  bin_build_date=$("$bin" 2>&1 </dev/null | grep '^Build Date:' | head -1 | cut -d: -f2- | xargs || true)
  bin_mtime=$(stat -c "%y" "$bin" 2>/dev/null | cut -d. -f1 || echo "?")
  bin_size_kb=$(( $(stat -c "%s" "$bin" 2>/dev/null || echo 0) / 1024 ))

  local arch="" cpu_model="" cpus="" sockets="" cores_per_sock="" threads_per_core=""
  local max_mhz="" numa="" cache_l3="" mem_total="" mem_used="" mem_avail=""
  if command -v lscpu &>/dev/null; then
    local lscpu_out; lscpu_out=$(lscpu 2>/dev/null)
    arch=$(            awk -F': +' '/^Architecture/{print $2}'          <<< "$lscpu_out")
    cpu_model=$(       awk -F': +' '/^Model name/{print $2}'            <<< "$lscpu_out")
    cpus=$(            awk -F': +' '/^CPU\(s\):/{print $2; exit}'       <<< "$lscpu_out")
    sockets=$(         awk -F': +' '/^Socket\(s\)/{print $2}'           <<< "$lscpu_out")
    cores_per_sock=$(  awk -F': +' '/^Core\(s\) per socket/{print $2}'  <<< "$lscpu_out")
    threads_per_core=$(awk -F': +' '/^Thread\(s\) per core/{print $2}'  <<< "$lscpu_out")
    max_mhz=$(         awk -F': +' '/^CPU max MHz/{print $2}'           <<< "$lscpu_out")
    numa=$(            awk -F': +' '/^NUMA node\(s\)/{print $2}'        <<< "$lscpu_out")
    cache_l3=$(        awk -F': +' '/^L3 cache/{print $2}'              <<< "$lscpu_out")
  fi
  read -r mem_total mem_used mem_avail \
    < <(free -m 2>/dev/null | awk 'NR==2{print $2, $3, $7}' || echo "? ? ?")

  {
    echo "# Cbc 2.10 (stable) Experiment Setup"
    echo ""
    echo "**Started:** $(date)"
    echo "**Outdir:** \`$OUTDIR\`"
    echo ""
    echo "## Experiment Parameters"
    echo ""
    echo "| Parameter | Value |"
    echo "|:---|:---|"
    echo "| Binary | \`$bin\` |"
    echo "| Cbc version | ${bin_version:-?} |"
    echo "| Cbc build date | ${bin_build_date:-?} |"
    echo "| Concurrent instances | $PARALLEL |"
    if [[ -n "$TIMELIMIT" ]]; then
      echo "| Time limit | ${TIMELIMIT}s wall-clock (overrides limits.tsv) |"
    else
      echo "| Time limit | per-instance (limits.tsv), fallback 120s |"
    fi
    echo "| Time mode | elapsed (wall-clock; -timeMode elapsed injected automatically) |"
    echo "| Allowable gap | ${ALLOWABLE_GAP} (absolute; -allowableGap, matches HiGHS mip_abs_gap) |"
    echo "| Ratio gap | ${RATIO_GAP} (relative; -ratioGap, matches HiGHS mip_rel_gap) |"
    echo "| Instances dir | \`$INSTANCES_DIR\` ($TOTAL instances) |"
    if [[ ${#CBC_EXTRA_OPTS[@]} -gt 0 ]]; then
      echo "| Extra Cbc opts | \`${CBC_EXTRA_OPTS[*]}\` |"
    else
      echo "| Extra Cbc opts | _(none)_ |"
    fi
    echo ""
    echo "## Binary"
    echo ""
    echo "| | |"
    echo "|:---|:---|"
    echo "| Path  | \`$bin\` |"
    echo "| Version | ${bin_version:-?} |"
    echo "| Build date | ${bin_build_date:-?} |"
    echo "| File mtime | $bin_mtime |"
    echo "| Size  | ${bin_size_kb} KB |"
    echo ""
    echo "## Hardware"
    echo ""
    echo "| Property | Value |"
    echo "|:---|:---|"
    echo "| Hostname | \`$(hostname 2>/dev/null || echo '?')\` |"
    echo "| Kernel | \`$(uname -r 2>/dev/null || echo '?')\` |"
    echo "| Architecture | ${arch:-?} |"
    echo "| CPU model | ${cpu_model:-?} |"
    echo "| CPU count | ${cpus:-?} (${sockets:-?} socket × ${cores_per_sock:-?} core × ${threads_per_core:-?} thread) |"
    [[ -n "$max_mhz"  ]] && echo "| CPU freq | ${max_mhz} MHz max |"
    [[ -n "$numa"     ]] && echo "| NUMA nodes | $numa |"
    [[ -n "$cache_l3" ]] && echo "| L3 cache | $cache_l3 |"
    echo "| Memory | ${mem_total:-?} MiB total, ${mem_avail:-?} MiB available (${mem_used:-?} MiB used) |"
    echo ""
  } > "$md"

  echo "==> Experiment setup saved: $md"
}

# ── Header / report ────────────────────────────────────────────────────────────
{
  echo "Cbc 2.10 (stable) benchmark run"
  echo "Started:        $(date)"
  echo "Binary:         $ORIGINAL_CBC_BIN"
  echo "Binary (snap):  $CBC_BIN"
  echo "Parallel:       $PARALLEL  (concurrent instances)"
  [[ -n "$TIMELIMIT" ]] && echo "Timelimit:      ${TIMELIMIT}s (overrides limits.tsv)" \
    || echo "Timelimit:      per-instance (limits.tsv), fallback 120s"
  echo "Time mode:      elapsed (wall-clock)"
  echo "Allowable gap:  $ALLOWABLE_GAP  (absolute)"
  echo "Ratio gap:      $RATIO_GAP  (relative)"
  echo "Instances:      $TOTAL  (from $INSTANCES_DIR)"
  echo "Outdir:         $OUTDIR"
  echo ""
} | tee "$REPORT"
write_setup_md "$ORIGINAL_CBC_BIN"

# ── Memory monitor: sample free memory every 5 minutes ───────────────────────
MEM_TSV="$OUTDIR/memory_usage.tsv"
MEM_MONITOR_PID=""
EXP_START_EPOCH=$SECONDS
printf "timestamp\telapsed_s\ttotal_mb\tused_mb\tfree_mb\tavailable_mb\tpct_used\n" > "$MEM_TSV"
if [[ "$DRY_RUN" -eq 0 ]]; then
  (
    trap 'exit 0' TERM INT
    while true; do
      _ts=$(date -Iseconds)
      _elapsed=$(( SECONDS - EXP_START_EPOCH ))
      read -r _total _used _free _avail < <(free -m 2>/dev/null | awk 'NR==2{print $2, $3, $4, $7}') || true
      _pct=$(awk -v u="${_used:-0}" -v t="${_total:-1}" 'BEGIN { printf "%.1f", u/t*100 }')
      printf "%s\t%d\t%d\t%d\t%d\t%d\t%s\n" "$_ts" "$_elapsed" "${_total:-0}" "${_used:-0}" "${_free:-0}" "${_avail:-0}" "${_pct:-0}" >> "$MEM_TSV"
      sleep 300 & wait $! 2>/dev/null || true
    done
  ) &
  MEM_MONITOR_PID=$!
fi

# ── Run instances via GNU parallel ───────────────────────────────────────────
printf '%s\n' "${INSTANCES[@]}" \
  | setsid parallel --will-cite --jobs "$PARALLEL" --line-buffer \
      --joblog "$OUTDIR/parallel.log" run_instance \
  || true  # non-zero exit when any worker fails; summary assembly must still run

if [[ "$DRY_RUN" -eq 1 ]]; then
  rm -rf "$OUTDIR"
  exit 0
fi

# ── Stop memory monitor, take a final sample ──────────────────────────────────
if [[ -n "${MEM_MONITOR_PID:-}" ]]; then
  kill "$MEM_MONITOR_PID" 2>/dev/null || true
  wait "$MEM_MONITOR_PID" 2>/dev/null || true
fi
_ts=$(date -Iseconds)
_elapsed=$(( SECONDS - EXP_START_EPOCH ))
read -r _total _used _free _avail < <(free -m 2>/dev/null | awk 'NR==2{print $2, $3, $4, $7}') || true
_pct=$(awk -v u="${_used:-0}" -v t="${_total:-1}" 'BEGIN { printf "%.1f", u/t*100 }')
printf "%s\t%d\t%d\t%d\t%d\t%d\t%s\n" "$_ts" "$_elapsed" "${_total:-0}" "${_used:-0}" "${_free:-0}" "${_avail:-0}" "${_pct:-0}" >> "$MEM_TSV"

# ── Assemble summary from per-instance .result files ─────────────────────────
printf "%-42s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
  "instance" "status" "objective" "dual_bound" "expected" "elapsed_s" "threads" "gap_field" \
  "solution_found" "proven_infeasible" "timed_out" > "$SUMMARY"

SOLVED_COUNT=0; TIMEOUT_COUNT=0; CLEAN_NO_SOLUTION_COUNT=0; FAIL=0; OVERTIME_COUNT=0
NO_FEASIBLE_COUNT=0
FAILED_NAMES=()

for name in "${INSTANCES[@]}"; do
  resultfile="$OUTDIR/${name}.result"
  if [[ -f "$resultfile" ]]; then
    IFS=$'\t' read -r status obj dual exp elapsed thr gap solution_found proven_infeasible timed_out < "$resultfile"
  else
    status="MISSING"; obj="-"; dual="-"; exp="-"; elapsed=0; thr=1; gap="-"
    solution_found=0; proven_infeasible=0; timed_out=0
  fi
  printf "%-42s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$name" "$status" "$obj" "${dual:--}" "$exp" "$elapsed" "$thr" "${gap:--}" \
    "$solution_found" "$proven_infeasible" "$timed_out" >> "$SUMMARY"
  if [[ "${solution_found:-0}" -eq 0 && "${proven_infeasible:-0}" -eq 0 ]]; then
    NO_FEASIBLE_COUNT=$((NO_FEASIBLE_COUNT+1))
  fi
  if [[ "$status" == SOLVED || "$status" == SOLVED\(* ]]; then
    SOLVED_COUNT=$((SOLVED_COUNT+1))
  elif [[ "$status" == TIMEOUT* ]]; then
    TIMEOUT_COUNT=$((TIMEOUT_COUNT+1))
  elif [[ "$status" == "NO_SOLUTION" ]]; then
    CLEAN_NO_SOLUTION_COUNT=$((CLEAN_NO_SOLUTION_COUNT+1))
  else
    FAIL=$((FAIL+1)); FAILED_NAMES+=("$name")
    [[ "$status" == "OVERTIME" ]] && OVERTIME_COUNT=$((OVERTIME_COUNT+1))
  fi
done

MEM_PEAK_USED=""; MEM_PEAK_TOTAL=""; MEM_PEAK_PCT=""; MEM_PEAK_TS=""
if [[ -f "$MEM_TSV" ]] && [[ $(wc -l < "$MEM_TSV") -gt 1 ]]; then
  read -r MEM_PEAK_USED MEM_PEAK_TOTAL MEM_PEAK_PCT MEM_PEAK_TS < <(
    awk -F'\t' 'NR>1 && $4+0>max { max=$4+0; total=$3+0; pct=$7; ts=$1 }
                END { if (max>0) print max, total, pct, ts }' "$MEM_TSV") || true
fi

{
  echo ""
  echo "═══════════════════════════════════════════════════"
  printf "  Results: %d/%d solved/proved, %d timed out, %d failed\n" \
    "$SOLVED_COUNT" "$TOTAL" "$TIMEOUT_COUNT" "$FAIL"
  if [[ $NO_FEASIBLE_COUNT -gt 0 ]]; then
    printf "  %d instance(s) finished without ever finding a feasible solution (TIMEOUT(no_sol) + failures)\n" \
      "$NO_FEASIBLE_COUNT"
  fi
  if [[ $OVERTIME_COUNT -gt 0 ]]; then
    printf "  %d instance(s) OVERTIME — ignored their own time/node limit and had to be killed\n" \
      "$OVERTIME_COUNT"
  fi
  if [[ $CLEAN_NO_SOLUTION_COUNT -gt 0 ]]; then
    printf "  %d instance(s) NO_SOLUTION — exited cleanly with no limit hit and no solution/proof (unexpected — investigate)\n" \
      "$CLEAN_NO_SOLUTION_COUNT"
  fi
  echo "  Finished: $(date)"
  if [[ -n "$MEM_PEAK_USED" ]]; then
    echo "  Peak memory used:  ${MEM_PEAK_USED} MB / ${MEM_PEAK_TOTAL} MB (${MEM_PEAK_PCT}%)"
    echo "  Peak at:           $MEM_PEAK_TS"
  fi
  echo "═══════════════════════════════════════════════════"
  if [[ ${#FAILED_NAMES[@]} -gt 0 ]]; then
    echo ""
    echo "Failed instances:"
    for n in "${FAILED_NAMES[@]}"; do
      st=$(awk -F'\t' -v n="$n" '$1==n{print $2}' "$SUMMARY")
      printf "  %-42s  %s\n" "$n" "$st"
      [[ -f "$OUTDIR/${n}.err" ]] && printf "    error detail: %s\n" "$OUTDIR/${n}.err"
    done
  fi
  echo ""
  echo "Per-instance logs: $OUTDIR/"
  echo "Summary TSV:       $SUMMARY"
  echo "Solutions:         $OUTDIR/*.sol  (present when feasible solution found)"
  echo "GNU parallel log:  $OUTDIR/parallel.log"
  [[ -f "$MEM_TSV" ]] && echo "Memory usage log:  $MEM_TSV"
  echo "Experiment setup:  $OUTDIR/experiment_setup.md"
} | tee -a "$REPORT"

exit 0
