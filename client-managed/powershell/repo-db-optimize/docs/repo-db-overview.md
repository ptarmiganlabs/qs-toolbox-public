# Qlik Sense Repository Database Overview

## Overview

`repo-db-overview.ps1` provides a readable overview of a Qlik Sense repository PostgreSQL database. It reports:

- database size and connection info
- table statistics (row estimates from pg_stat_user_tables and optional exact COUNT(*) values)
- table, index and total sizes
- database roles and permissions

The script is read-only but can execute expensive queries (COUNT(*)) when run in detailed mode; run during maintenance windows.

## Requirements

- PowerShell: Windows PowerShell 5.1+ or PowerShell Core 6.0+ (cross-platform)
- PostgreSQL client: `psql` 12+ (script uses modern catalog views and functions)
- Network: access to the PostgreSQL server from the machine running the script

## Important notes

- The script is READ-ONLY and does not modify data, but detailed mode runs `COUNT(*)` which can be slow and resource-intensive.
- Use a role with read access to system catalogs. `pg_roles` is used to list roles (preferred over `pg_user`).
- The script sets a per-COUNT statement timeout (60s by default) and limits the number of tables for exact counts by default.

## Features

- Table statistics: estimated row counts (`pg_stat_user_tables`) and sizes
- Optional exact row counts (COUNT(*)) with safeguards (timeout + sampling limit)
- Index statistics for all user tables retrieved in a single query
- Roles and permissions (uses `pg_roles`, `pg_class`, `pg_namespace`, `pg_auth_members`)
- Stepwise debug mode (`-StepDebug`) with `-StopAfter` stages to inspect intermediate outputs
- Output to console and optional file export
- Configurable via environment variables or parameters

## Usage

### Common commands

Run summary (fast, uses pg_stat estimates):

```powershell
.\repo-db-overview.ps1
```

Run detailed report (includes exact COUNTs for a sample of tables and index details):

```powershell
.\repo-db-overview.ps1 -DetailLevel details
```

Export to file:

```powershell
.\repo-db-overview.ps1 -DetailLevel details -OutputFile report.txt
```

Run StepDebug to inspect a stage and exit early:

```powershell
# Inspect connection stage and exit
.\repo-db-overview.ps1 -StepDebug -StopAfter connection

# Inspect parsed table statistics (then exit)
.\repo-db-overview.ps1 -StepDebug -StopAfter table_stats

# Inspect parsed indexes (then exit)
.\repo-db-overview.ps1 -StepDebug -StopAfter indexes -DetailLevel details

# Inspect exact-counts parsing only
.\repo-db-overview.ps1 -StepDebug -StopAfter counts -DetailLevel details
```

### Parameters of note

- `-DetailLevel` (summary|details) — `summary` uses pg_stat estimates; `details` runs COUNT(*) for a sample and collects index info.
- `-OutputFile <name>` — write full report to a timestamped file in `QSR_OUTPUT_DIRECTORY`.
- `-StepDebug` — enables stepwise debug mode.
- `-StopAfter <stage>` — stop after one stage; valid stages: `connection`, `version`, `size`, `table_stats`, `indexes`, `counts`, `users`, `none`.
- `-MaxExactCountTables <int>` — maximum tables to run exact `COUNT(*)` on (default 10).
- `-ForceExactCounts` — force exact counts for all tables (use with caution).

### Environment variables

All settings can be configured via environment variables or parameters. Defaults are shown:

| Variable | Default | Purpose |
|---|---:|---|
| QSR_DB_HOST | localhost | PostgreSQL host |
| QSR_DB_PORT | 4432 | PostgreSQL port |
| QSR_DB_NAME | QSR | Repository DB name |
| QSR_DB_USER | postgres | DB user |
| QSR_DB_PASSWORD | (none) | DB password (optional; exported to PGPASSWORD for psql) |
| QSR_PSQL_BIN_PATH | psql | Path to psql binary |
| QSR_OUTPUT_DIRECTORY | . | Directory for output files |
| QSR_LOG_LEVEL | INFO | Log level: DEBUG, INFO, WARN, ERROR |

Parameters mirror these variables and can be supplied on the command line.

## Output

### Console

The console output contains:

- Database summary (size, table count, user count)
- Table statistics (sorted by total size)
- Optional detailed per-table blocks (row counts, sizes, indexes) when `-DetailLevel details` is used
- Roles and permissions

### File

When `-OutputFile` is supplied, the script writes a timestamped file to `QSR_OUTPUT_DIRECTORY` (or current directory).

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Success |
| 1 | Error (fatal) |
| 2 | Warning / non-fatal issues |

## Internal notes (queries & parsing)

- `psql` is invoked with `-t -A -F '|'` (tuple-only, unaligned, pipe-separated) so output is stable for parsing. Queries are sent via **stdin** (not `-c`) to avoid Windows PowerShell 5.1 stripping double-quotes from command-line arguments, which would break case-sensitive table names such as `public."Users"`.
- Table statistics use joins between `pg_stat_user_tables`, `pg_class` and `pg_namespace` and sizes use `pg_total_relation_size()`, `pg_relation_size()` and `pg_indexes_size()`.
- Roles/users are read via `pg_roles` (script parses `rolcreatedb`, `rolsuper`, `rolcreaterole`, `rolreplication`, `rolvaliduntil`).
- Indexes use `pg_index`/`pg_class` and `pg_relation_size(i.oid)`.
- Exact counts execute `SET LOCAL statement_timeout = 60000; SELECT COUNT(*) FROM "schema"."table";` and parse the last non-empty psql line for the numeric result.
- The shared database module sets `[Console]::OutputEncoding` and `$OutputEncoding` to UTF-8 at load time, so international characters (e.g. names containing `ö`, `ä`, `ü`) are correctly handled on Windows PowerShell 5.1 where the default console encoding is the OEM codepage.

## Safeguards

- Exact `COUNT(*)` is limited to `-MaxExactCountTables` (default 10) unless `-ForceExactCounts` is used.
- Each COUNT uses a per-statement `statement_timeout` (60s default) to prevent very long running queries.
- Use `-StepDebug -StopAfter counts` to validate COUNT parsing behavior without running the full report.

## Troubleshooting

Check `psql` availability and connectivity:

```powershell
psql --version
psql -h $env:QSR_DB_HOST -p $env:QSR_DB_PORT -d $env:QSR_DB_NAME -U $env:QSR_DB_USER -c "SELECT 1"
```

If parsing errors occur, run with `-StepDebug` and the appropriate `-StopAfter` stage to inspect raw psql outputs printed by the script.

If COUNT(*) calls time out or are too slow:

- run in `summary` mode
- reduce `-MaxExactCountTables`
- increase the per-COUNT timeout in the script if you control the environment

Ensure the used role has read access to the system catalogs and tables referenced by the queries.

**International characters appear garbled on Windows:** This can happen if the Windows console codepage does not match the PostgreSQL server's `client_encoding`. The script sets the PowerShell encoding to UTF-8 automatically, but if psql itself is not returning UTF-8 (e.g. the server uses `WIN1252`), the data from PostgreSQL may still be mis-encoded. In that case, set the codepage manually before running the script:

```powershell
chcp 65001   # switch console to UTF-8
$env:PGCLIENTENCODING = 'UTF8'
```

## Related files

- Script: `/powershell/repo-db-optimize/script/repo-db-overview.ps1`

## License & Additional tools

MIT

More tools at https://github.com/ptarmiganlabs
