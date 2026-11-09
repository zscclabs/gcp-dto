#!/usr/bin/env bash
# Run the DTO + Cloud NAT billing queries in order and save each result as CSV.
#
# Usage:
#   export BILLING_TABLE=proj.billing.gcp_billing_export_resource_v1_XXXX
#   export DS=proj.finops
#   export START=2026-10-01 END=2026-11-01      # END is exclusive
#   ./run_all.sh [options]
#
# Options:
#   --rebuild-map     Run 02 even if ${DS}.dto_sku_map already exists (REPLACES it, manual fixes lost)
#   --skip-discovery  Skip 01_sku_discovery.sql
#   --save-summary    Also write 06 output to table ${DS}.dto_nat_summary (replaced each run)
#   --strict          Exit non-zero if any check in 07 (7a/7b/7c) returns rows
#   --dry-run         Only estimate bytes scanned for each query; nothing is executed
#   --out DIR         Output directory (default: out/<START>_<END>_<timestamp>)
#   -h, --help        Show this help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="${SCRIPT_DIR}/sql"

REBUILD_MAP=0; SKIP_DISCOVERY=0; SAVE_SUMMARY=0; STRICT=0; DRY_RUN=0; OUT_DIR=""

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild-map)    REBUILD_MAP=1 ;;
    --skip-discovery) SKIP_DISCOVERY=1 ;;
    --save-summary)   SAVE_SUMMARY=1 ;;
    --strict)         STRICT=1 ;;
    --dry-run)        DRY_RUN=1 ;;
    --out)            OUT_DIR="${2:?--out needs a directory}"; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- Preflight ----------
for v in BILLING_TABLE DS START END; do
  [[ -n "${!v:-}" ]] || die "Environment variable $v is not set (see --help)."
done
for t in bq envsubst; do
  command -v "$t" >/dev/null 2>&1 || die "'$t' not found. Install the Google Cloud SDK (bq) / gettext (envsubst: brew install gettext)."
done
date_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
[[ "$START" =~ $date_re && "$END" =~ $date_re ]] || die "START/END must be YYYY-MM-DD."
[[ "$START" < "$END" ]] || die "START ($START) must be before END ($END)."
[[ "$DS" == *.* ]] || die "DS must be 'project.dataset' (got '$DS')."
[[ -d "$SQL_DIR" ]] || die "SQL directory not found: $SQL_DIR"

export BILLING_TABLE DS START END
DS_BQ="${DS/./:}"                       # project:dataset form for bq show / destination tables
BT_BQ="${BILLING_TABLE/./:}"

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="${SCRIPT_DIR}/out/${START}_${END}_$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUT_DIR"

if [[ $DRY_RUN -eq 0 ]]; then
  bq show "$BT_BQ" >/dev/null 2>&1 || die "Cannot access billing table $BILLING_TABLE (check name / bigquery.dataViewer)."
  bq show "$DS_BQ" >/dev/null 2>&1 || die "Working dataset $DS not found. Create it in the SAME location as the billing dataset: bq mk --location=US --dataset $DS_BQ"
fi

echo "Billing table : $BILLING_TABLE"
echo "Working DS    : $DS"
echo "Window        : $START (incl) -> $END (excl)"
echo "Output        : $OUT_DIR"
[[ $DRY_RUN -eq 1 ]] && echo "Mode          : DRY RUN (no queries executed)"

# ---------- Helpers ----------
render() { envsubst '$BILLING_TABLE $DS $START $END' < "$1"; }

# run_sql <name> <sql-text> [extra bq flags...]
# Saves CSV to $OUT_DIR/<name>.csv, prints a preview, echoes data row count on fd 3.
run_sql() {
  local name="$1" sql="$2"; shift 2
  local csv="${OUT_DIR}/${name}.csv"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '%s' "$sql" | bq --quiet query --use_legacy_sql=false --dry_run "$@" \
      || die "Dry run failed for $name"
    echo 0 >&3
    return
  fi
  printf '%s' "$sql" > "${OUT_DIR}/${name}.sql"
  if ! printf '%s' "$sql" | bq --quiet --headless query --use_legacy_sql=false \
        --format=csv --max_rows=1000000 "$@" > "$csv"; then
    die "Query failed: $name (SQL saved to ${OUT_DIR}/${name}.sql)"
  fi
  local rows=0
  [[ -s "$csv" ]] && rows=$(( $(wc -l < "$csv") - 1 ))
  (( rows < 0 )) && rows=0
  echo "Rows: $rows  ->  $csv"
  if (( rows > 0 )); then head -n 16 "$csv"; (( rows > 15 )) && echo "... ($rows rows total)"; fi
  echo "$rows" >&3
}

# Convenience wrapper that discards the row count.
run_file() { run_sql "$1" "$(render "$2")" 3>/dev/null; }

# ---------- 01 SKU discovery ----------
if [[ $SKIP_DISCOVERY -eq 0 ]]; then
  log "01 SKU discovery"
  run_file 01_sku_discovery "$SQL_DIR/01_sku_discovery.sql"
fi

# ---------- 02 SKU map ----------
log "02 SKU map"
if [[ $DRY_RUN -eq 0 ]] && bq show "${DS_BQ}.dto_sku_map" >/dev/null 2>&1 && [[ $REBUILD_MAP -eq 0 ]]; then
  echo "${DS}.dto_sku_map exists; keeping it (use --rebuild-map to replace)."
else
  [[ $REBUILD_MAP -eq 1 ]] && warn "Rebuilding ${DS}.dto_sku_map - manual UPDATEs will be lost."
  run_file 02_sku_map "$SQL_DIR/02_sku_map.sql"
  if [[ $DRY_RUN -eq 0 ]]; then
    run_sql 02_sku_map_contents \
      "SELECT category, sku_id, sku, service FROM \`${DS}.dto_sku_map\` ORDER BY category, sku" 3>/dev/null
    warn "New map created. Review ${OUT_DIR}/02_sku_map_contents.csv and fix REVIEW / wrong rows before trusting results."
  fi
fi

# ---------- 03 - 06 Reports ----------
log "03 DTO by region";       run_file 03_dto_by_region     "$SQL_DIR/03_dto_by_region.sql"
log "04 DTO by resource";     run_file 04_dto_by_resource   "$SQL_DIR/04_dto_by_resource.sql"
log "05 NAT processing";      run_file 05_nat_processing    "$SQL_DIR/05_nat_processing.sql"
log "06 DTO + NAT summary";   run_file 06_dto_and_nat_summary "$SQL_DIR/06_dto_and_nat_summary.sql"

if [[ $SAVE_SUMMARY -eq 1 && $DRY_RUN -eq 0 ]]; then
  log "06 -> table ${DS}.dto_nat_summary"
  render "$SQL_DIR/06_dto_and_nat_summary.sql" \
    | bq --quiet --headless query --use_legacy_sql=false \
        --destination_table="${DS_BQ}.dto_nat_summary" --replace >/dev/null \
    || die "Failed to save summary table"
  echo "Saved ${DS}.dto_nat_summary"
fi

# ---------- 07 Checks (split into individual statements) ----------
log "07 Checks"
CHECK_FAIL=0
declare -a CHECK_NAMES=(07a_unmapped_skus 07b_duplicate_skus 07c_review_rows 07d_totals_by_category)
i=0
while IFS= read -r -d $'\x1e' stmt; do
  # skip chunks that are only comments/whitespace
  if [[ -z "$(printf '%s\n' "$stmt" | sed -e 's/--.*$//' | tr -d '[:space:]')" ]]; then continue; fi
  name="${CHECK_NAMES[$i]:-07_check_$i}"
  echo "--- $name"
  exec 4>&1
  rows=$(run_sql "$name" "$stmt" 3>&1 1>&4)
  exec 4>&-
  if [[ $DRY_RUN -eq 0 && "$name" != 07d_* && "$rows" -gt 0 ]]; then
    warn "$name returned $rows row(s) - see ${OUT_DIR}/${name}.csv"
    CHECK_FAIL=1
  elif [[ $DRY_RUN -eq 0 && "$name" != 07d_* ]]; then
    echo "PASS"
  fi
  i=$((i + 1))
done < <(render "$SQL_DIR/07_checks.sql" | awk 'BEGIN{RS=";"; ORS="\x1e"} {print}')

# ---------- Done ----------
log "Done"
echo "Results: $OUT_DIR"
echo "Reminder: dto_gib is the DTO volume. Do NOT add nat_processed_gib to it (same bytes + ingress)."
if [[ $CHECK_FAIL -eq 1 ]]; then
  warn "One or more checks (7a/7b/7c) failed - DTO/NAT figures may be incomplete or double counted."
  [[ $STRICT -eq 1 ]] && exit 2
fi
exit 0
