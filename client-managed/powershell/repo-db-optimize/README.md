# Qlik Sense Repository Database — Analysis Scripts

PowerShell scripts for read-only analysis of a Qlik Sense (client-managed) repository database. All scripts connect directly to the PostgreSQL repository database and produce human-readable console output and optional file exports.

> **Safety note**: all scripts are READ-ONLY. They do not modify any data.  
> Queries may have a performance impact; prefer running during maintenance windows or off-peak hours.

---

## Requirements

| Requirement | Version |
|---|---|
| PowerShell | Core 6.0+ (cross-platform) |
| PostgreSQL client (`psql`) | 12+ |
| Network access | to the PostgreSQL host on the configured port |

The `psql` binary must be available in `PATH`, or its location must be set via `QSR_PSQL_BIN_PATH`.

---

## Environment variables

All scripts share the same set of environment variables. Set them once before running any script. Parameters passed on the command line take precedence over environment variables.

| Variable | Default | Description |
|---|---|---|
| `QSR_DB_HOST` | `localhost` | PostgreSQL host |
| `QSR_DB_PORT` | `4432` | PostgreSQL port (Qlik Sense default) |
| `QSR_DB_NAME` | `QSR` | Repository database name |
| `QSR_DB_USER` | `postgres` | Database user |
| `QSR_DB_PASSWORD` | *(none)* | Database password — exported as `PGPASSWORD` |
| `QSR_PSQL_BIN_PATH` | `psql` | Full path to the `psql` binary, if not in `PATH` |
| `QSR_OUTPUT_DIRECTORY` | `.` | Directory where exported report files are written |
| `QSR_LOG_LEVEL` | `INFO` | Log verbosity: `DEBUG`, `INFO`, `WARN`, `ERROR` |

### Setting environment variables

**PowerShell (any platform):**
```powershell
$env:QSR_DB_HOST     = '192.168.1.10'
$env:QSR_DB_PORT     = '4432'
$env:QSR_DB_PASSWORD = 'your-password'
```

**Bash / zsh (macOS / Linux):**
```bash
export QSR_DB_HOST=192.168.1.10
export QSR_DB_PORT=4432
export QSR_DB_PASSWORD=your-password
```

---

## Scripts

### `repo-db-overview.ps1`

Provides a comprehensive overview of the Qlik Sense repository database: table statistics (row counts, sizes, indexes), user permissions, and overall database health metrics.

**Quick start:**
```powershell
# Summary report (default)
.\script\repo-db-overview.ps1

# Detailed report including per-table information
.\script\repo-db-overview.ps1 -DetailLevel details

# Export to file
.\script\repo-db-overview.ps1 -OutputFile report.txt
```

**Key parameters:**

| Parameter | Default | Description |
|---|---|---|
| `-DetailLevel` | `summary` | `summary` or `details` |
| `-OutputFile` | *(none)* | Write report to a timestamped file |
| `-StepDebug` | *(off)* | Pause and inspect output after each stage |
| `-StopAfter` | *(none)* | Exit after a named stage (useful with `-StepDebug`) |

📄 Full documentation: [docs/repo-db-overview.md](docs/repo-db-overview.md)

---

### `user-group-memberships.ps1`

Analyses user group memberships in the repository database. Shows summary statistics, a distribution histogram of groups-per-user, top-N rankings, and an optional bloat analysis that classifies groups as relevant or noise based on substring patterns.

**Quick start:**
```powershell
# Summary report (default)
.\script\user-group-memberships.ps1

# Detailed report with full user and group listings
.\script\user-group-memberships.ps1 -DetailLevel details

# List all users with their group counts
.\script\user-group-memberships.ps1 -ListUsers

# List all groups with their user counts
.\script\user-group-memberships.ps1 -ListGroups

# Show all groups a specific user belongs to
.\script\user-group-memberships.ps1 -FilterUser 'DOMAIN\userId'

# Show all members of a specific group (exact name)
.\script\user-group-memberships.ps1 -FilterGroup 'Domain Users'

# Bloat analysis: classify groups as relevant or bloat
# Groups whose name contains 'admin' or 'sense' are relevant; all others are bloat
.\script\user-group-memberships.ps1 -RelevantGroups 'admin,sense'
```

**Key parameters:**

| Parameter | Default | Description |
|---|---|---|
| `-DetailLevel` | `summary` | `summary` or `details` |
| `-ListUsers` | *(off)* | List all users with group counts |
| `-ListGroups` | *(off)* | List all groups with user counts |
| `-FilterUser` | *(none)* | Detail view for one user (`DOMAIN\userId`) |
| `-FilterGroup` | *(none)* | Detail view for one group (exact match) |
| `-RelevantGroups` | *(none)* | Comma-separated or repeated substring patterns for bloat analysis |
| `-TopN` | `10` | Number of entries in top-N rankings |
| `-OutputFile` | *(none)* | Write report to a timestamped file |
| `-StepDebug` | *(off)* | Pause and inspect output after each stage |
| `-StopAfter` | *(none)* | Exit after a named stage |

📄 Full documentation: [docs/user-group-memberships.md](docs/user-group-memberships.md)

---

## Shared modules (`script/shared/`)

The scripts load shared modules from the `script/shared/` folder at runtime using dot-sourcing. These modules must remain alongside the scripts and are not intended to be run directly.

| Module | Purpose |
|---|---|
| `qsr-configuration.ps1` | Resolves settings from environment variables and parameters |
| `qsr-logging.ps1` | Timestamped, colour-coded console logging |
| `qsr-database.ps1` | Executes queries via `psql` and returns pipe-delimited output |
| `qsr-validation.ps1` | Pre-flight checks: psql availability, DB connectivity, version |
| `qsr-output.ps1` | Writes report files to the output directory |

---

## Folder structure

```
repo-db-optimize/
├── README.md                          ← this file
├── script/
│   ├── repo-db-overview.ps1           ← DB overview script
│   ├── user-group-memberships.ps1     ← User group analysis script
│   └── shared/                        ← Shared modules (loaded automatically)
│       ├── qsr-configuration.ps1
│       ├── qsr-database.ps1
│       ├── qsr-logging.ps1
│       ├── qsr-output.ps1
│       └── qsr-validation.ps1
└── docs/
    ├── repo-db-overview.md            ← Full docs for repo-db-overview.ps1
    └── user-group-memberships.md      ← Full docs for user-group-memberships.ps1
```

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Fatal error (bad parameters, connection failure, etc.) |
| `2` | Non-fatal warning |

---

## Troubleshooting

**Test connectivity manually:**
```powershell
psql -h $env:QSR_DB_HOST -p $env:QSR_DB_PORT -d $env:QSR_DB_NAME -U $env:QSR_DB_USER -c "SELECT 1"
```

**Enable verbose logging:**
```powershell
$env:QSR_LOG_LEVEL = 'DEBUG'
.\script\repo-db-overview.ps1
```

**Inspect a specific stage and exit early:**
```powershell
.\script\user-group-memberships.ps1 -StepDebug -StopAfter connection
.\script\user-group-memberships.ps1 -StepDebug -StopAfter version
.\script\user-group-memberships.ps1 -StepDebug -StopAfter summary_stats
```
