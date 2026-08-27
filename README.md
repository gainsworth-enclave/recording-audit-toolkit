# Recording Audit Toolkit

Two bash scripts for auditing files across a fleet of remote nodes and
cross-referencing findings against a Postgres database — built to run
unattended, safely, on shared production infrastructure.

This is a generalized, anonymized version of a tool originally built to
diagnose redundant file recordings across a multi-node cluster; the
underlying design applies to any "count/categorize files on N remote
hosts, then look up details for a subset in a database" workflow.

## What it does

**`scripts/audit_report.sh`**
- Connects to a chosen node from a configurable list
- Buckets every file in a target directory into size categories (fully
  configurable — the shipped defaults are just an example)
- Optionally retrieves a de-duplicated list of filenames matching a
  chosen category

**`scripts/query_details.sh`**
- Reads a filenames file produced by the script above
- Builds a safely-quoted SQL `IN (...)` list from it
- Runs an example lookup query against Postgres, with layered timeouts
  and explicit connection cleanup on failure

## Setup

```bash
git clone <this-repo>
cd recording-audit-toolkit
cp config.example.sh config.sh
# edit config.sh with your own nodes, paths, and database details
chmod +x scripts/*.sh
./scripts/audit_report.sh
./scripts/query_details.sh
```

`config.sh` is gitignored — it's where anything specific to your
infrastructure lives. `config.example.sh` is the only config file meant
to be committed.

The SQL query in `query_details.sh` is a **worked example** against a
generic job-queue-style schema. It will not run as-is against your
database — read it, adapt the table/column names, and remove the
comment block at the top once you have.

## Design decisions

**Config externalized, not hardcoded.** Every environment-specific
value (node addresses, paths, DB name, timeouts) lives in `config.sh`,
loaded via `source` at runtime. The scripts themselves contain no
infrastructure-specific data.

**Everything lives in one scratch directory.** Both scripts confine
every file they read or write to `SCRATCH_DIR` — reports, retrieved
filenames, the SSH control socket. Nothing touches `~/.ssh/`, `/tmp`,
or any other shared path.

**SSH connection multiplexing, not static keys.** Rather than
installing a persistent SSH key (a standing credential that outlives
any one script run — a real concern on a shared account), the script
authenticates once per run via `ControlMaster`/`ControlPersist`, then
explicitly closes the session with `ssh -O exit` on exit — including
on interruption, via a `trap ... EXIT` handler.

**Layered timeouts on the database query.** `statement_timeout` is set
inside Postgres for a clean, server-side cancellation. An outer `timeout`
process wraps the whole `psql` call as a safety net for connection-level
hangs that `statement_timeout` alone wouldn't catch. Exit codes `124`/`137`
are distinguished from ordinary SQL failures in the reporting.

**Tagged, explicitly-terminated database connections.** The query
session is tagged with `application_name`, so on timeout or failure the
script can call `pg_terminate_backend()` scoped to exactly that tag —
without risking any other user's connection on a shared database.

**Safe SQL construction from untrusted input.** Filenames pulled from a
remote filesystem are not trusted as literal SQL — single quotes are
escaped (`'` → `''`) before being inserted into the `IN (...)` list.

**`COPY ... TO STDOUT WITH CSV HEADER` instead of hand-built CSV.**
Correct comma/quote escaping is delegated to Postgres's own CSV writer
rather than reconstructed with `sed`/`awk`.

## Requirements

- Bash 4+
- `ssh`, `rsync`, `find`, `sed`, `sort` on the machine running the scripts
- `psql` and appropriate `sudo` access to the database OS user, for
  `query_details.sh`
- Passwordless SSH access (or password entry once per multiplexed
  session) to the target nodes

## License

MIT — see `LICENSE`.
