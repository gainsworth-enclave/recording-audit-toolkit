#!/bin/bash
set -uo pipefail
# Deliberately not using `set -e` — this script branches on the exit
# code of the query (success / timeout / failure), which -e would
# interfere with capturing cleanly.

# ------------------------------------------------------------------
# query_details.sh
#
# Reads a filenames_*.txt file produced by audit_report.sh, builds a
# safely-quoted SQL IN (...) list from it, and runs an example lookup
# query against Postgres with layered timeouts and connection cleanup.
#
# *** The SQL query below is a WORKED EXAMPLE. ***
# It matches a specific job-queue schema (a "jobs" table joined to a
# "log" table by a JSON-embedded foreign key) that will NOT match your
# schema out of the box. Read the query, adapt table/column names to
# your own database, then remove this comment block.
# ------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config.sh not found. Copy config.example.sh to config.sh and fill it in." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

PROCESS_TIMEOUT_SECONDS=$((QUERY_TIMEOUT_SECONDS + 5))
APP_NAME="recording_audit_query"

mkdir -p "$SCRATCH_DIR"

# ------------------------------------------------------------------
# 1) Pick which filenames file to query from
# ------------------------------------------------------------------
shopt -s nullglob
NAME_FILES=("${SCRATCH_DIR}"/filenames_*.txt)
shopt -u nullglob

if [[ ${#NAME_FILES[@]} -eq 0 ]]; then
  echo "ERROR: No filenames_*.txt files found in ${SCRATCH_DIR}." >&2
  echo "Run audit_report.sh first (choose 'Retrieve matching filenames? yes') to generate one." >&2
  exit 1
fi

PS3="Select a filenames file to query (1-${#NAME_FILES[@]}): "
echo "=== Select Filenames File ==="
select NAMES_FILE in "${NAME_FILES[@]}"; do
  if [[ -n "$NAMES_FILE" ]]; then
    echo "Selected file: $NAMES_FILE"
    break
  else
    echo "Invalid selection. Please enter a valid number."
  fi
done

# ------------------------------------------------------------------
# 2) Which queue/partition value to filter on (example-specific —
#    remove or adapt this prompt if your schema doesn't have an
#    equivalent concept)
# ------------------------------------------------------------------
read -rp "Queue/partition value to filter on (e.g. your-queue-name.example.com): " FILTER_VALUE

if [[ -z "$FILTER_VALUE" ]]; then
  echo "ERROR: A filter value is required." >&2
  exit 1
fi

# ------------------------------------------------------------------
# 3) Build a safely-quoted SQL IN (...) list from the names file
# ------------------------------------------------------------------
IN_LIST=""
while IFS= read -r name || [[ -n "$name" ]]; do
  [[ -z "$name" ]] && continue
  ESCAPED="${name//\'/\'\'}"
  if [[ -z "$IN_LIST" ]]; then
    IN_LIST="'${ESCAPED}'"
  else
    IN_LIST="${IN_LIST},
'${ESCAPED}'"
  fi
done < "$NAMES_FILE"

if [[ -z "$IN_LIST" ]]; then
  echo "ERROR: ${NAMES_FILE} contained no names — nothing to query." >&2
  exit 1
fi

# ------------------------------------------------------------------
# 4) Output path
# ------------------------------------------------------------------
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
CSV_FILE="${SCRATCH_DIR}/query_details_${TIMESTAMP}.csv"

# ------------------------------------------------------------------
# 5) Build the SQL — EXAMPLE SCHEMA, adapt to your own tables
# ------------------------------------------------------------------
SQL_BODY=$(cat <<SQL
SET application_name = '${APP_NAME}';
SET statement_timeout = '${QUERY_TIMEOUT_SECONDS}s';
COPY (
  SELECT
    j.id,
    j."result",
    l.item_key AS "Item Key",
    l.source_host AS "Source Host",
    j.queue AS "Queue",
    j.created AS "Job Created",
    j.attempts AS "Job Attempts",
    j."state"
  FROM job_queue.jobs j
  LEFT JOIN app.item_log l ON l.id::TEXT = j.args -> 0 ->> 'item_log_id'
  WHERE j.task = 'example_task'
    AND j.queue = '${FILTER_VALUE}'
    AND l.item_key IN (
${IN_LIST}
    )
) TO STDOUT WITH (FORMAT csv, HEADER true);
SQL
)

# ------------------------------------------------------------------
# 6) Run it — OS-level timeout wrapping a non-interactive psql call
# ------------------------------------------------------------------
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running query (statement timeout ${QUERY_TIMEOUT_SECONDS}s, process timeout ${PROCESS_TIMEOUT_SECONDS}s)..."

timeout -k 5 "${PROCESS_TIMEOUT_SECONDS}" \
  sudo -u "$DB_OS_USER" psql -X -q -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "$SQL_BODY" > "$CSV_FILE"
EXIT_CODE=$?

terminate_tagged_connections() {
  sudo -u "$DB_OS_USER" psql -X -q -d "$DB_NAME" \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = '${APP_NAME}' AND pid <> pg_backend_pid();" \
    >/dev/null 2>&1
}

if [[ $EXIT_CODE -eq 0 ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Query Succeeded — Details Saved to ${CSV_FILE}"

elif [[ $EXIT_CODE -eq 124 || $EXIT_CODE -eq 137 ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Query Timed Out after ${PROCESS_TIMEOUT_SECONDS}s — terminating connection..." >&2
  terminate_tagged_connections
  rm -f "$CSV_FILE"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Connection terminated. No CSV was produced." >&2

else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Query Failed (exit code ${EXIT_CODE}) — terminating connection..." >&2
  terminate_tagged_connections
  rm -f "$CSV_FILE"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Connection terminated. No CSV was produced." >&2
fi

exit "$EXIT_CODE"
