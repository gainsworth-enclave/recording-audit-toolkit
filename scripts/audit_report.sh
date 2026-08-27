#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------------
# audit_report.sh
#
# Connects to a chosen remote node over SSH, buckets every file in a
# target directory by size, and optionally retrieves de-duplicated
# base filenames matching one of those size buckets.
#
# Requires config.sh alongside this script (see config.example.sh).
# ------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config.sh not found. Copy config.example.sh to config.sh and fill it in." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ------------------------------------------------------------------
# Where this script's outputs live
# ------------------------------------------------------------------
REPORT_NAME="audit_report.txt"
LOCAL_TMP="${SCRATCH_DIR}/size_counts.txt"

# Where to save the final report:
#   "local"  -> saved on this machine, in SCRATCH_DIR
#   "remote" -> rsync'd back to the selected node's home directory
DESTINATION="local"

# ------------------------------------------------------------------
# Size categories — shared by BOTH the count report and the filename
# retrieval filter below, so they're defined once. Adjust freely; the
# only fixed point is that ranges must stay non-overlapping and
# continuous if you add/remove a boundary.
# ------------------------------------------------------------------
BOUND_SMALL=44          # e.g. a known "empty file" marker size, in bytes
BOUND_MID=250000000     # 250MB in decimal bytes
BOUND_LARGE=500000000   # 500MB in decimal bytes

CATEGORY_LABELS=(
  "Sub ${BOUND_SMALL} bytes"
  "Exactly ${BOUND_SMALL} bytes"
  "Between ${BOUND_SMALL} bytes and $((BOUND_MID / 1000000))MB"
  "Between $((BOUND_MID / 1000000))MB and $((BOUND_LARGE / 1000000))MB"
  "Greater than or equal to $((BOUND_LARGE / 1000000))MB"
)

CATEGORY_FILTERS=(
  "-size -${BOUND_SMALL}c"
  "-size ${BOUND_SMALL}c"
  "-size +${BOUND_SMALL}c -size -$((BOUND_MID + 1))c"
  "-size +${BOUND_MID}c -size -${BOUND_LARGE}c"
  "-size +$((BOUND_LARGE - 1))c"
)

# ------------------------------------------------------------------
# Prompt for target node
# ------------------------------------------------------------------
PS3="Select a target node (1-${#TARGET_NODES[@]}): "
echo "=== Select Target Node ==="

select SELECTED_HOST in "${TARGET_NODES[@]}"; do
  if [[ -n "$SELECTED_HOST" ]]; then
    echo "Selected Target: $SELECTED_HOST"
    break
  else
    echo "Invalid selection. Please enter a valid number."
  fi
done

NODE_LABEL="Node ${REPLY}"

SSH_TARGET="${SSH_USER}@${SELECTED_HOST}"

mkdir -p "$SCRATCH_DIR"

# ------------------------------------------------------------------
# SSH connection multiplexing: authenticate once, reuse the connection
# for every subsequent call in this run, then explicitly close it.
# ------------------------------------------------------------------
SOCKET_DIR="${SCRATCH_DIR}/ssh_sockets"
CONTROL_PERSIST="2m"
mkdir -p "$SOCKET_DIR"
chmod 700 "$SOCKET_DIR"

SOCKET_PATH="${SOCKET_DIR}/%r@%h:%p"
SSH_OPTS=(
  -o "ControlMaster=auto"
  -o "ControlPath=${SOCKET_PATH}"
  -o "ControlPersist=${CONTROL_PERSIST}"
)
SSH_CMD=(ssh -p "$SSH_PORT" "${SSH_OPTS[@]}" "$SSH_TARGET")

cleanup_ssh_session() {
  if ssh -p "$SSH_PORT" -O check -o "ControlPath=${SOCKET_PATH}" "$SSH_TARGET" 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Closing multiplexed SSH session to ${SELECTED_HOST}..."
    ssh -p "$SSH_PORT" -O exit -o "ControlPath=${SOCKET_PATH}" "$SSH_TARGET" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Multiplexed SSH session to ${SELECTED_HOST} closed."
  fi
}
trap cleanup_ssh_session EXIT

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Establishing multiplexed SSH session to ${SELECTED_HOST} (${SSH_USER}) — will be reused for all commands in this run, and closed automatically at script end (or after ${CONTROL_PERSIST} idle)."

# ------------------------------------------------------------------
# Pull counts from the selected node, using the shared categories
# ------------------------------------------------------------------
{
  echo "=== Report Date: $(date) ==="
  echo "=== Target Node: $SELECTED_HOST ==="

  for i in "${!CATEGORY_LABELS[@]}"; do
    echo "=== ${CATEGORY_LABELS[$i]} ==="
    "${SSH_CMD[@]}" "find '$REMOTE_TARGET_DIR' -type f ${CATEGORY_FILTERS[$i]} | wc -l"
  done
} > "$LOCAL_TMP"

echo "Report generated:"
cat "$LOCAL_TMP"

# ------------------------------------------------------------------
# Optional: retrieve filenames matching a chosen size category.
# Strips a "-suffix1"/"-suffix2" leg pattern and de-duplicates — a
# common pattern where two files represent two sides of one event
# (e.g. call recording legs). Adjust or remove the sed step if your
# use case doesn't have this pattern.
# ------------------------------------------------------------------
read -rp "Retrieve matching filenames? (yes/no): " RETRIEVE_NAMES

if [[ "$RETRIEVE_NAMES" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
  PS3="Select a file size filter (1-${#CATEGORY_LABELS[@]}): "
  echo "=== Select File Size Filter ==="

  select CHOSEN_LABEL in "${CATEGORY_LABELS[@]}"; do
    if [[ -n "$CHOSEN_LABEL" ]]; then
      CHOSEN_FILTER="${CATEGORY_FILTERS[$((REPLY - 1))]}"
      echo "Selected filter: $CHOSEN_LABEL"
      break
    else
      echo "Invalid selection. Please enter a valid number."
    fi
  done

  SAFE_LABEL=$(echo "$CHOSEN_LABEL" | tr ' ' '_')
  NAMES_FILE="${SCRATCH_DIR}/filenames_${SELECTED_HOST}_${SAFE_LABEL}.txt"

  # Example suffix-stripping pattern — adjust "-rx.wav"/"-tx.wav" to
  # whatever your own two-sided naming convention is, or remove the
  # sed stage entirely if there isn't one.
  if "${SSH_CMD[@]}" "find '$REMOTE_TARGET_DIR' -type f ${CHOSEN_FILTER} -printf '%f\n' | sed -E 's/-(rx|tx)\.wav\$//' | sort -u" > "$NAMES_FILE"; then
    echo "Filenames for ${NODE_LABEL} Successfully Saved to ${NAMES_FILE}"
  else
    echo "ERROR: Failed to retrieve filenames for ${NODE_LABEL} (${SELECTED_HOST})" >&2
    rm -f "$NAMES_FILE"
  fi
fi

# ------------------------------------------------------------------
# Save the report to the chosen destination
# ------------------------------------------------------------------
case "$DESTINATION" in
  local)
    cp "$LOCAL_TMP" "${SCRATCH_DIR}/${REPORT_NAME}"
    echo "Saved report locally to ${SCRATCH_DIR}/${REPORT_NAME}"
    ;;
  remote)
    rsync -av -i --info=stats2 -e "ssh -p ${SSH_PORT}" \
      "$LOCAL_TMP" \
      "${SSH_TARGET}:${REPORT_NAME}"
    echo "Saved report to ${SELECTED_HOST}:${REPORT_NAME}"
    ;;
  *)
    echo "Unknown DESTINATION '$DESTINATION' — must be 'local' or 'remote'." >&2
    exit 1
    ;;
esac
