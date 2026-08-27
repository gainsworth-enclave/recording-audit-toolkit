#!/bin/bash
# ------------------------------------------------------------------
# Copy this file to config.sh and fill in your own values.
#
#   cp config.example.sh config.sh
#
# config.sh is listed in .gitignore — it should never be committed.
# It holds anything specific to your infrastructure: node addresses,
# credentials, database names. This file (config.example.sh) is the
# only one that belongs in version control.
# ------------------------------------------------------------------

# --- SSH connection details ---
SSH_USER="your_ssh_user"
SSH_PORT=22

# Remote nodes this toolkit will connect to. Add as many as you need.
# The trailing comment becomes the friendly label used in menus/output
# (e.g. "Node 1"), based on position in this array.
TARGET_NODES=(
  "10.0.0.101" # Node 1 — replace with your own hosts
  "10.0.0.102" # Node 2
)

# --- Remote path being audited ---
# Any directory of files you want counted/listed by size — not limited
# to Asterisk. Adjust REMOTE_TARGET_DIR to whatever you're auditing.
REMOTE_TARGET_DIR="/var/spool/asterisk/monitor"

# --- Local scratch space ---
# Everything this toolkit writes lives here. Nothing is ever written
# outside this directory.
SCRATCH_DIR="${HOME}/recording_audit_tmp"

# --- Database connection (used by query_details.sh only) ---
DB_OS_USER="postgres"      # OS-level user Postgres runs as, for sudo -u
DB_NAME="your_database"

# --- Query behaviour ---
QUERY_TIMEOUT_SECONDS=60
