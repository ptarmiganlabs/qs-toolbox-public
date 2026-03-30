#!/usr/bin/env pwsh
#===============================================================================
# Qlik Sense Repository Database Overview Script
#===============================================================================
# This script provides a comprehensive overview of the Qlik Sense repository
# database (PostgreSQL). It displays table statistics (row counts, sizes,
# indexes), user permissions, and supports both screen output and file export.
#
# All settings are configurable via environment variables or parameters.
# No hardcoded values are used.
#
# Requirements:
# - Windows PowerShell 5.1+ or PowerShell Core 6.0+ (cross-platform)
# - PostgreSQL client tools (psql) version 12+
#
# Usage:
#   .\repo-db-overview.ps1                          # Basic run with summary
#   .\repo-db-overview.ps1 -DetailLevel "details"  # Include detailed information
#   .\repo-db-overview.ps1 -OutputFile "report.txt" # Export to file
#
# Environment Variables:
#   QSR_DB_HOST           - PostgreSQL host (default: localhost)
#   QSR_DB_PORT           - PostgreSQL port (default: 4432)
#   QSR_DB_NAME           - Repository database name (default: QSR)
#   QSR_DB_USER           - Database user (default: postgres)
#   QSR_DB_PASSWORD       - Database password (optional, for password auth)
#   QSR_PSQL_BIN_PATH     - Path to psql binary (default: psql in PATH)
#   QSR_OUTPUT_DIRECTORY  - Output directory for file export (default: .)
#   QSR_LOG_LEVEL         - Log level: DEBUG, INFO, WARN, ERROR (default: INFO)
#
# Exit Codes:
#   0 - Success
#   1 - Error (invalid parameters, database connection failed, etc.)
#   2 - Warning (non-critical issues)
#
# Author: Ptarmigan Labs/Göran Sander
# Version: 2.0.0
#===============================================================================

#requires -version 5.0

#-------------------------------------------------------------------------------
# WARNING: PERFORMANCE IMPACT DISCLAIMER
#-------------------------------------------------------------------------------
# This script is READ-ONLY and does NOT modify the repository database.
# However, it performs potentially heavy queries against the database which may
# cause performance impact in the Qlik Sense environment. Run during maintenance
# windows or off-peak hours to minimize risk.
#===============================================================================

#-------------------------------------------------------------------------------
# Parameters
#-------------------------------------------------------------------------------
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("summary", "details")]
    [string]$DetailLevel = "summary",

    [Parameter(Mandatory = $false)]
    [string]$OutputFile = "",

    [Parameter(Mandatory = $false)]
    [string]$DB_HOST = $env:QSR_DB_HOST,

    [Parameter(Mandatory = $false)]
    [string]$DB_PORT = $env:QSR_DB_PORT,

    [Parameter(Mandatory = $false)]
    [string]$DB_NAME = $env:QSR_DB_NAME,

    [Parameter(Mandatory = $false)]
    [string]$DB_USER = $env:QSR_DB_USER,

    [Parameter(Mandatory = $false)]
    [string]$PSQL_BIN = $env:QSR_PSQL_BIN_PATH,

    [Parameter(Mandatory = $false)]
    [string]$OUTPUT_DIRECTORY = $env:QSR_OUTPUT_DIRECTORY,

    [Parameter(Mandatory = $false)]
    [string]$LOG_LEVEL = $env:QSR_LOG_LEVEL
    ,
    [Parameter(Mandatory = $false)]
    [switch]$StepDebug,
    [Parameter(Mandatory = $false)]
    [int]$MaxExactCountTables = 10,
    [Parameter(Mandatory = $false)]
    [switch]$ForceExactCounts,
    [ValidateSet("connection","version","size","table_stats","indexes","counts","users","none")]
    [string]$StopAfter = ""
)

#-------------------------------------------------------------------------------
# Load Shared Modules
#   Order matters: Configuration -> Logging -> Database -> Validation -> Output
#-------------------------------------------------------------------------------
$sharedDir = Join-Path $PSScriptRoot "shared"
. (Join-Path $sharedDir "qsr-configuration.ps1")
. (Join-Path $sharedDir "qsr-logging.ps1")
. (Join-Path $sharedDir "qsr-database.ps1")
. (Join-Path $sharedDir "qsr-validation.ps1")
. (Join-Path $sharedDir "qsr-output.ps1")

#-------------------------------------------------------------------------------
# Initialize Configuration
#-------------------------------------------------------------------------------
$script:QSRConfig = Initialize-QSRConfiguration `
    -DbHost $DB_HOST `
    -DbPort $DB_PORT `
    -DbName $DB_NAME `
    -DbUser $DB_USER `
    -PsqlBin $PSQL_BIN `
    -OutputDirectory $OUTPUT_DIRECTORY `
    -LogLevel $LOG_LEVEL `
    -StepDebug:$StepDebug `
    -StopAfter $StopAfter

#-------------------------------------------------------------------------------
# Error Handling
#-------------------------------------------------------------------------------
$ErrorActionPreference = "Stop"

trap {
    Write-Log -Level "ERROR" -Message "An error occurred: $_"
    Write-Log -Level "ERROR" -Message "Script terminated with exit code 1"
    exit 1
}

#-------------------------------------------------------------------------------
# Script-Specific Database Functions
#-------------------------------------------------------------------------------

<#
.SYNOPSIS
    Retrieves table statistics from pg_stat_user_tables with size information.

.DESCRIPTION
    Queries pg_stat_user_tables joined with pg_class and pg_namespace to get
    estimated row counts (n_live_tup) and sizes (table, index, total) for
    every user table. Results are sorted by total size descending.

.OUTPUTS
    [PSCustomObject[]] — Each object has: TableName, RowCount, TotalSizePretty,
    TotalSizeBytes, TableSizePretty, TableSizeBytes, IndexesSizePretty,
    IndexesSizeBytes. Returns $null on failure.
#>
function Get-TableStatistics {
    Write-Log -Level "INFO" -Message "Retrieving table statistics"

    $query = @"
SELECT
    n.nspname || '.' || c.relname as table_name,
    s.n_live_tup as row_count,
    pg_size_pretty(pg_total_relation_size(c.oid)) as total_size_pretty,
    pg_total_relation_size(c.oid) as total_size_bytes,
    pg_size_pretty(pg_relation_size(c.oid)) as table_size_pretty,
    pg_relation_size(c.oid) as table_size_bytes,
    pg_size_pretty(pg_indexes_size(c.oid)) as indexes_size_pretty,
    pg_indexes_size(c.oid) as indexes_size_bytes
FROM pg_stat_user_tables s
JOIN pg_class c ON s.relid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
ORDER BY pg_total_relation_size(c.oid) DESC;
"@

    $result = Invoke-PsqlQuery -Query $query
    $cfg = $script:QSRConfig

    if ($LASTEXITCODE -ne 0 -or -not $result) {
        Write-Log -Level "ERROR" -Message "Failed to retrieve table statistics"
        if ($cfg.StepDebug -and (-not $cfg.StopAfter -or $cfg.StopAfter -eq 'table_stats')) {
            $preview = if ($result) { ($result | Select-Object -First 20) -join "|" } else { "<no output>" }
            Write-Log -Level "INFO" -Message "StepDebug: raw table-stats output preview: $preview"
            Write-Log -Level "INFO" -Message "StepDebug: exiting after table-stats failure"
            exit 1
        }
        return $null
    }

    $exitAfterParse = $false
    if ($cfg.StepDebug) {
        if (-not $cfg.StopAfter) {
            $preview = ($result | Select-Object -First 40) -join "|"
            Write-Log -Level "INFO" -Message "StepDebug: raw table-stats output preview: $preview"
            Write-Log -Level "INFO" -Message "StepDebug: exiting after fetching table statistics (no parse)"
            exit 0
        } elseif ($cfg.StopAfter -eq 'table_stats') {
            $exitAfterParse = $true
        }
    }

    # Parse the result — one row per table, handle both array and single-string outputs
    $tables = @()
    if (-not $result) { 
        Write-Log -Level "DEBUG" -Message "No table-statistics rows returned"
        return $tables
    }

    if ($result -is [array]) {
        $rows = $result
    } else {
        $rows = $result -split "`n"
    }

    foreach ($line in $rows) {
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match "^([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)$") {
            $tables += [PSCustomObject]@{
                TableName          = $matches[1].Trim()
                RowCount           = [int64]($matches[2].Trim())
                TotalSizePretty    = $matches[3].Trim()
                TotalSizeBytes     = [int64]($matches[4].Trim())
                TableSizePretty    = $matches[5].Trim()
                TableSizeBytes     = [int64]($matches[6].Trim())
                IndexesSizePretty  = $matches[7].Trim()
                IndexesSizeBytes   = [int64]($matches[8].Trim())
            }
        } else {
            Write-Log -Level "DEBUG" -Message "Skipping unparsable table-stats line: '$line'"
        }
    }

    Write-Log -Level "DEBUG" -Message "Retrieved $($tables.Count) tables"

    if ($cfg.StepDebug -and $exitAfterParse) {
        Write-Log -Level "INFO" -Message "StepDebug: parsed $($tables.Count) table rows"
        $sample = $tables | Select-Object -First 10 | ForEach-Object { "{0} | {1} rows | {2}" -f $_.TableName, $_.RowCount, $_.TotalSizePretty }
        if ($sample) { Write-Log -Level "INFO" -Message ("StepDebug: sample parsed rows:`n" + ($sample -join "`n")) }
        Write-Log -Level "INFO" -Message "StepDebug: exiting after parsing table statistics"
        exit 0
    }

    return $tables
}

<#
.SYNOPSIS
    Retrieves exact row counts for a set of tables using COUNT(*).

.DESCRIPTION
    Runs COUNT(*) with a per-statement timeout (60s) for each table. By default
    only the first MaxToCheck tables are counted; use -Force to count all.

.PARAMETER Tables
    Array of table objects (from Get-TableStatistics) with a .TableName property.

.PARAMETER MaxToCheck
    Maximum number of tables to count. Default: 10.

.PARAMETER Force
    Override the MaxToCheck limit and count all tables.

.OUTPUTS
    [hashtable] — Keys are table names, values are exact row counts (or -1 on error).
#>
function Get-TableRowCountsExact {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Tables,
        [int]$MaxToCheck = 10,
        [switch]$Force
    )

    Write-Log -Level "INFO" -Message "Retrieving exact row counts for all tables"

    $exactCounts = @{}

    $toCheck = $Tables
    if (-not $Force -and $Tables.Count -gt $MaxToCheck) {
        Write-Log -Level "WARN" -Message "$($Tables.Count) tables requested for exact counts; limiting to first $MaxToCheck (use -ForceExactCounts to override)"
        $toCheck = $Tables | Select-Object -First $MaxToCheck
    }

    foreach ($table in $toCheck) {
        $tableName = $table.TableName.Trim()
        Write-Log -Level "DEBUG" -Message "Counting rows in $tableName"

        $parts = $tableName -split '\.'
        if ($parts.Length -ne 2) {
            Write-Log -Level "WARN" -Message "Unexpected table name format: $tableName; skipping"
            $exactCounts[$tableName] = -1
            continue
        }

        $schema = $parts[0].Replace("'","''")
        $rel = $parts[1].Replace("'","''")

        # Set a statement timeout to avoid long-running counts
        $query = "SET LOCAL statement_timeout = 60000; SELECT COUNT(*) FROM " + '"' + $schema + '"' + "." + '"' + $rel + '"' + ";"
        $result = Invoke-PsqlQuery -Query $query -SuppressOutput

        if ($LASTEXITCODE -eq 0 -and $result) {
            # psql may return multiple lines (e.g., 'SET' then the count). Extract the last non-empty line.
            $lines = @()
            if ($result -is [array]) { $lines = $result } else { $lines = $result -split "`n" }
            $lines = $lines | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne "" }
            $valueLine = $lines | Select-Object -Last 1

            $num = $null
            if ($valueLine -match "(\d+)") { $num = $matches[1] }
            else {
                try { $num = ([int64]$valueLine) } catch { $num = $null }
            }

            if ($num -ne $null) {
                $exactCounts[$tableName] = [int64]$num
            } else {
                Write-Log -Level "WARN" -Message ("Could not parse COUNT() result for {0}: '{1}'" -f $tableName, $valueLine)
                $exactCounts[$tableName] = -1
            }
        } else {
            $exactCounts[$tableName] = -1  # Error or timed out
        }
    }

    return $exactCounts
}

<#
.SYNOPSIS
    Retrieves index statistics for the given tables.

.DESCRIPTION
    For each table, queries pg_index/pg_class to list indexes and their sizes.

.PARAMETER Tables
    Array of table objects (from Get-TableStatistics).

.OUTPUTS
    [PSCustomObject[]] — Each object has: TableName, IndexName, SizePretty, SizeBytes.
#>
function Get-IndexStatistics {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Tables
    )

    Write-Log -Level "INFO" -Message "Retrieving index statistics"

    $indexes = @()

    foreach ($table in $Tables) {
        $tableName = $table.TableName.Trim()

        $parts = $tableName -split '\.'
        if ($parts.Length -ne 2) {
            Write-Log -Level "WARN" -Message "Unexpected table name format for indexes: $tableName; skipping"
            continue
        }

        $schema = $parts[0].Replace("'","''")
        $rel = $parts[1].Replace("'","''")

        $query = @"
SELECT
    i.relname as index_name,
    pg_size_pretty(pg_relation_size(i.oid)) as index_size_pretty,
    pg_relation_size(i.oid) as index_size_bytes
FROM pg_class t
JOIN pg_index x ON t.oid = x.indrelid
JOIN pg_class i ON i.oid = x.indexrelid
WHERE t.relname = '$rel'
  AND t.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = '$schema')
ORDER BY pg_relation_size(i.oid) DESC;
"@

        $result = Invoke-PsqlQuery -Query $query

        if ($LASTEXITCODE -eq 0 -and $result) {
            $rows = $(if ($result -is [array]) { $result } else { $result -split "`n" })
            foreach ($line in $rows) {
                $line = $line.Trim()
                if ($line -match "^([^|]+)\|([^|]+)\|([^|]+)$") {
                    $indexes += [PSCustomObject]@{
                        TableName   = $tableName
                        IndexName   = $matches[1].Trim()
                        SizePretty  = $matches[2].Trim()
                        SizeBytes   = [int64]$matches[3].Trim()
                    }
                } else {
                    Write-Log -Level "DEBUG" -Message ("Skipping unparsable index line for {0}: '{1}'" -f $tableName, $line)
                }
            }
        }
    }

    return $indexes
}

<#
.SYNOPSIS
    Retrieves PostgreSQL database roles (users) and their attributes.

.OUTPUTS
    [PSCustomObject[]] — Each object has: Username, UserID, CanCreateDB, IsSuperUser,
    CanCreateRole, CanReplicate, PasswordValidUntil.
#>
function Get-DatabaseUsers {
    Write-Log -Level "INFO" -Message "Retrieving database users and permissions"
    $cfg = $script:QSRConfig

    $query = @"
SELECT
    r.rolname as username,
    r.oid as user_id,
    r.rolcreatedb as can_create_db,
    r.rolsuper as is_superuser,
    r.rolcreaterole as can_create_role,
    r.rolreplication as can_replicate,
    r.rolvaliduntil as password_valid_until
FROM pg_roles r
ORDER BY r.rolname;
"@

    $result = Invoke-PsqlQuery -Query $query

    if ($LASTEXITCODE -ne 0 -or -not $result) {
        Write-Log -Level "WARN" -Message "Failed to retrieve database users; continuing with empty list"
        if ($cfg.StepDebug -and (-not $cfg.StopAfter -or $cfg.StopAfter -eq 'users')) {
            $preview = if ($result) { ($result | Select-Object -First 20) -join "|" } else { "<no output>" }
            Write-Log -Level "INFO" -Message "StepDebug: raw users output preview: $preview"
            if ($cfg.StopAfter -eq 'users') {
                Write-Log -Level "INFO" -Message "StepDebug: exiting after users preview"
                exit 0
            }
        }
        return @()
    }

    $users = @()
    foreach ($line in $result) {
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $parts = $line -split '\|'
        if ($parts.Length -lt 7) {
            Write-Log -Level "DEBUG" -Message "Skipping unparsable user line: '$line'"
            continue
        }

        $users += [PSCustomObject]@{
            Username           = $parts[0].Trim()
            UserID             = $parts[1].Trim()
            CanCreateDB        = ($parts[2].Trim() -eq 't')
            IsSuperUser        = ($parts[3].Trim() -eq 't')
            CanCreateRole      = ($parts[4].Trim() -eq 't')
            CanReplicate       = ($parts[5].Trim() -eq 't')
            PasswordValidUntil = $parts[6].Trim()
        }
    }

    if ($cfg.StepDebug -and $cfg.StopAfter -eq 'users') {
        Write-Log -Level "INFO" -Message "StepDebug: parsed $($users.Count) users"
        $sample = $users | Select-Object -First 10 | ForEach-Object { "{0} | id={1} | super={2}" -f $_.Username, $_.UserID, $_.IsSuperUser }
        if ($sample) { Write-Log -Level "INFO" -Message ("StepDebug: sample parsed users:`n" + ($sample -join "`n")) }
        Write-Log -Level "INFO" -Message "StepDebug: exiting after parsing users"
        exit 0
    }

    return $users
}

<#
.SYNOPSIS
    Retrieves direct object ownership and role memberships for database users.

.PARAMETER Users
    Array of user objects (from Get-DatabaseUsers).

.OUTPUTS
    [PSCustomObject[]] — Permissions/memberships with SchemaName, TableName,
    ObjectType, Grantee, GranteeID, ACL.
#>
function Get-UserPermissions {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Users
    )

    Write-Log -Level "INFO" -Message "Retrieving user permissions"

    $permissions = @()

    foreach ($user in $Users) {
        $username = $user.Username

        # Direct object ownership
        $query = @"
SELECT
    n.nspname as schema_name,
    c.relname as table_name,
    CASE
        WHEN c.relkind = 'r' THEN 'TABLE'
        WHEN c.relkind = 'v' THEN 'VIEW'
        WHEN c.relkind = 'S' THEN 'SEQUENCE'
        ELSE c.relkind::text
    END as object_type,
    u.usename as grantee,
    u.usesysid as grantee_id,
    c.relacl as acl
FROM pg_class c
JOIN pg_user u ON u.usesysid = c.relowner
LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE u.usename = '$username'
  AND c.relkind IN ('r', 'v', 'S')
ORDER BY n.nspname, c.relname;
"@

        $result = Invoke-PsqlQuery -Query $query

        if ($LASTEXITCODE -eq 0 -and $result) {
            foreach ($line in $result) {
                if ($line -match "^([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|(.*)$") {
                    $permissions += [PSCustomObject]@{
                        SchemaName   = $matches[1]
                        TableName    = $matches[2]
                        ObjectType   = $matches[3]
                        Grantee      = $matches[4]
                        GranteeID    = $matches[5]
                        ACL          = $matches[6]
                    }
                }
            }
        }

        # Role memberships (inherited permissions)
        $query = @"
SELECT
    u.usename as member_name,
    u.usesysid as member_id,
    r.relname as role_name,
    r.oid as role_id,
    m.admin_option
FROM pg_auth_members m
JOIN pg_user u ON m.member = u.usesysid
JOIN pg_roles r ON m.roleid = r.oid
WHERE u.usename = '$username'
ORDER BY r.relname;
"@

        $result = Invoke-PsqlQuery -Query $query

        if ($LASTEXITCODE -eq 0 -and $result) {
            foreach ($line in $result) {
                if ($line -match "^([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)$") {
                    $adminOption = if ($matches[5] -eq "t") { " (with admin option)" } else { "" }
                    $permissions += [PSCustomObject]@{
                        SchemaName   = ""
                        TableName    = ""
                        ObjectType   = "ROLE_MEMBERSHIP"
                        Grantee      = $matches[1]
                        GranteeID    = $matches[2]
                        ACL          = "Member of role: $($matches[3])$adminOption"
                    }
                }
            }
        }
    }

    return $permissions
}

<#
.SYNOPSIS
    Retrieves the total size of the current database.

.OUTPUTS
    [PSCustomObject] with SizePretty and SizeBytes, or $null on failure.
#>
function Get-TotalDatabaseSize {
    Write-Log -Level "INFO" -Message "Calculating total database size"
    $cfg = $script:QSRConfig

    $query = @"
SELECT
    pg_size_pretty(pg_database_size(current_database())) as size_pretty,
    pg_database_size(current_database()) as size_bytes;
"@

    $result = Invoke-PsqlQuery -Query $query

    $exit = $script:LASTEXITCODE
    $resultText = ""
    if ($result) {
        if ($result -is [array]) { $resultText = ($result -join "`n").Trim() } else { $resultText = $result.ToString().Trim() }
    }

    Write-Log -Level "DEBUG" -Message "Parsing total DB size output: '$resultText' (exit=$exit)"

    if ($exit -eq 0 -and $resultText) {
        $clean = $resultText.Trim().TrimEnd('|').Trim()
        $parts = $clean -split '\|'
        $parts = $parts | ForEach-Object { $_.Trim() }

        if ($parts.Length -ge 2) {
            $obj = [PSCustomObject]@{
                SizePretty = $parts[0]
                SizeBytes  = [int64]$parts[1]
            }
            if ($cfg.StepDebug -and (-not $cfg.StopAfter -or $cfg.StopAfter -eq 'size')) {
                Write-Log -Level "INFO" -Message "StepDebug: total DB size raw: '$resultText'"
                Write-Log -Level "INFO" -Message "StepDebug: parsed SizePretty=$($obj.SizePretty) SizeBytes=$($obj.SizeBytes)"
                Write-Log -Level "INFO" -Message "StepDebug: exiting after total database size check"
                exit 0
            }
            return $obj
        } else {
            Write-Log -Level "WARN" -Message "Unexpected format for total size output: '$resultText'"
            if ($cfg.StepDebug -and (-not $cfg.StopAfter -or $cfg.StopAfter -eq 'size')) {
                Write-Log -Level "INFO" -Message "StepDebug: exiting after total database size with parse warning"
                exit 1
            }
        }
    }

    return $null
}

#-------------------------------------------------------------------------------
# Output Functions
#-------------------------------------------------------------------------------

<#
.SYNOPSIS
    Formats table statistics into a readable text report.

.PARAMETER Tables
    Array of table objects from Get-TableStatistics.

.PARAMETER ExactCounts
    Optional hashtable of exact row counts (from Get-TableRowCountsExact).

.PARAMETER Indexes
    Optional array of index objects (from Get-IndexStatistics).

.PARAMETER Detailed
    When set, includes per-table detail blocks with index breakdowns.

.OUTPUTS
    [string] — Formatted multi-line report text.
#>
function Format-TableStatistics {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Tables,

        [Parameter(Mandatory = $false)]
        [hashtable]$ExactCounts = @{},

        [Parameter(Mandatory = $false)]
        [array]$Indexes = @(),

        [Parameter(Mandatory = $false)]
        [switch]$Detailed
    )

    Write-Log -Level "INFO" -Message "Formatting table statistics"

    $output = @()
    $output += "=" * 80
    $output += "Qlik Sense Repository Database - Table Statistics"
    $output += "=" * 80
    $output += ""

    $output += "Total Tables: $($Tables.Count)"
    $output += ""

    $output += "Table Summary (sorted by size, largest first):"
    $output += "-" * 80

    $tableData = @()
    foreach ($table in $Tables) {
        $rowCount = if ($ExactCounts.ContainsKey($table.TableName)) {
            if ($ExactCounts[$table.TableName] -ge 0) {
                $ExactCounts[$table.TableName]
            } else {
                $table.RowCount
            }
        } else {
            $table.RowCount
        }

        $tableData += [PSCustomObject]@{
            "Table Name"        = $table.TableName
            "Row Count"         = $rowCount.ToString("N0")
            "Table Size"        = $table.TableSizePretty
            "Indexes Size"      = $table.IndexesSizePretty
            "Total Size"        = $table.TotalSizePretty
        }
    }

    $tableData | Format-Table -AutoSize | Out-String | ForEach-Object { $output += $_ }

    if ($Detailed) {
        $output += ""
        $output += "-" * 80
        $output += "Detailed Table Information:"
        $output += "-" * 80

        foreach ($table in $Tables) {
            $rowCount = if ($ExactCounts.ContainsKey($table.TableName)) {
                if ($ExactCounts[$table.TableName] -ge 0) {
                    $ExactCounts[$table.TableName]
                } else {
                    $table.RowCount
                }
            } else {
                $table.RowCount
            }

            $output += ""
            $output += "Table: $($table.TableName)"
            $output += "  Row Count:          $($rowCount.ToString("N0"))"
            $output += "  Table Size:         $($table.TableSizePretty) ($($table.TableSizeBytes.ToString("N0")) bytes)"
            $output += "  Indexes Size:       $($table.IndexesSizePretty) ($($table.IndexesSizeBytes.ToString("N0")) bytes)"
            $output += "  Total Size:         $($table.TotalSizePretty) ($($table.TotalSizeBytes.ToString("N0")) bytes)"

            $tableIndexes = $Indexes | Where-Object { $_.TableName -eq $table.TableName }
            if ($tableIndexes.Count -gt 0) {
                $output += "  Indexes:"
                foreach ($idx in $tableIndexes) {
                    $output += "    - $($idx.IndexName): $($idx.SizePretty) ($($idx.SizeBytes.ToString("N0")) bytes)"
                }
            }
        }
    }

    $output += ""
    $output += "=" * 80

    return $output -join "`r`n"
}

<#
.SYNOPSIS
    Formats database users and their permissions into a readable report.

.PARAMETER Users
    Array of user objects from Get-DatabaseUsers.

.PARAMETER Permissions
    Array of permission objects from Get-UserPermissions.

.OUTPUTS
    [string] — Formatted multi-line report text.
#>
function Format-UserPermissions {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Users,

        [Parameter(Mandatory = $true)]
        [array]$Permissions
    )

    Write-Log -Level "INFO" -Message "Formatting user permissions"

    $output = @()
    $output += ""
    $output += "=" * 80
    $output += "Database Users and Permissions"
    $output += "=" * 80
    $output += ""

    $output += "Database Users: $($Users.Count)"
    $output += "-" * 80

    foreach ($user in $Users) {
        $output += ""
        $output += "User: $($user.Username)"
        $output += "  User ID:            $($user.UserID)"
        $output += "  Can Create DB:      $(if ($user.CanCreateDB) { "Yes" } else { "No" })"
        $output += "  Is Super User:      $(if ($user.IsSuperUser) { "Yes" } else { "No" })"
        $output += "  Can Create Role:    $(if ($user.CanCreateRole) { "Yes" } else { "No" })"
        $output += "  Can Replicate:      $(if ($user.CanReplicate) { "Yes" } else { "No" })"
        if ($user.PasswordValidUntil) {
            $output += "  Password Valid Until: $($user.PasswordValidUntil)"
        }
    }

    $output += ""
    $output += "-" * 80
    $output += "Permissions:"
    $output += "-" * 80

    $directPermissions = $Permissions | Where-Object { $_.ObjectType -ne "ROLE_MEMBERSHIP" }
    $roleMemberships = $Permissions | Where-Object { $_.ObjectType -eq "ROLE_MEMBERSHIP" }

    if ($directPermissions.Count -gt 0) {
        $output += ""
        $output += "Direct Permissions:"
        $output += ""

        $permData = @()
        foreach ($perm in $directPermissions) {
            $permData += [PSCustomObject]@{
                "Schema"     = $perm.SchemaName
                "Table"      = $perm.TableName
                "Type"       = $perm.ObjectType
                "Grantee"    = $perm.Grantee
                "Permissions" = $perm.ACL
            }
        }
        $permData | Format-Table -AutoSize | Out-String | ForEach-Object { $output += $_ }
    }

    if ($roleMemberships.Count -gt 0) {
        $output += ""
        $output += "Role Memberships (Inherited Permissions):"
        $output += ""

        $roleData = @()
        foreach ($role in $roleMemberships) {
            $roleData += [PSCustomObject]@{
                "User" = $role.Grantee
                "Role" = ($role.ACL -replace "^Member of role: ", "")
            }
        }
        $roleData | Format-Table -AutoSize | Out-String | ForEach-Object { $output += $_ }
    }

    $output += ""
    $output += "=" * 80

    return $output -join "`r`n"
}

<#
.SYNOPSIS
    Formats the database summary header block.

.PARAMETER DatabaseSize
    Object with SizePretty and SizeBytes from Get-TotalDatabaseSize.

.PARAMETER TableCount
    Total number of tables.

.PARAMETER UserCount
    Total number of database roles/users.

.OUTPUTS
    [string] — Formatted summary text.
#>
function Format-DatabaseSummary {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$DatabaseSize,

        [Parameter(Mandatory = $true)]
        [int]$TableCount,

        [Parameter(Mandatory = $true)]
        [int]$UserCount
    )

    Write-Log -Level "INFO" -Message "Formatting database summary"
    $cfg = $script:QSRConfig

    $output = @()
    $output += "=" * 80
    $output += "Qlik Sense Repository Database - Overview"
    $output += "=" * 80
    $output += ""
    $output += "Connection Information:"
    $output += "  Host:       $($cfg.DbHost)"
    $output += "  Port:       $($cfg.DbPort)"
    $output += "  Database:   $($cfg.DbName)"
    $output += "  User:       $($cfg.DbUser)"
    $output += ""
    $output += "Database Statistics:"
    $output += "  Total Size:    $($DatabaseSize.SizePretty) ($($DatabaseSize.SizeBytes.ToString("N0")) bytes)"
    $output += "  Tables:        $TableCount"
    $output += "  Users:         $UserCount"
    $output += ""
    $output += "=" * 80

    return $output -join "`r`n"
}

#-------------------------------------------------------------------------------
# Main Script
#-------------------------------------------------------------------------------
function Main {
    $cfg = $script:QSRConfig

    Write-Log -Level "INFO" -Message "Starting Qlik Sense Repository Database Overview"
    Write-Log -Level "INFO" -Message "Detail Level: $DetailLevel"
    Write-Log -Level "INFO" -Message "Output Directory: $($cfg.OutputDirectory)"

    # Validate psql exists
    Write-Log -Level "INFO" -Message "Checking for psql binary"
    if (-not (Test-CommandExists -command $cfg.PsqlBin)) {
        Write-Log -Level "ERROR" -Message "psql binary not found: $($cfg.PsqlBin)"
        Write-Log -Level "ERROR" -Message "Please set QSR_PSQL_BIN_PATH environment variable or use -PSQL_BIN parameter"
        exit 1
    }
    Write-Log -Level "INFO" -Message "Found psql binary: $($cfg.PsqlBin)"

    # Validate output directory
    if (-not (Test-Path -Path $cfg.OutputDirectory)) {
        Write-Log -Level "WARN" -Message "Output directory does not exist, creating: $($cfg.OutputDirectory)"
        try {
            New-Item -Path $cfg.OutputDirectory -ItemType Directory | Out-Null
        } catch {
            Write-Log -Level "ERROR" -Message "Failed to create output directory: $_"
            exit 1
        }
    }

    # Test database connection
    if (-not (Test-DatabaseConnection)) {
        Write-Log -Level "ERROR" -Message "Cannot proceed without database connection"
        exit 1
    }

    # Check PostgreSQL version
    Test-PostgreSQLVersion | Out-Null

    # Get database size
    $dbSize = Get-TotalDatabaseSize
    if (-not $dbSize) {
        Write-Log -Level "ERROR" -Message "Failed to get database size"
        exit 1
    }

    # Get table statistics
    $tables = Get-TableStatistics
    if (-not $tables) {
        Write-Log -Level "ERROR" -Message "Failed to get table statistics"
        exit 1
    }

    # Get exact row counts if detailed mode
    $exactCounts = @{}
    if ($DetailLevel -eq "details") {
        $exactCounts = Get-TableRowCountsExact -Tables $tables
    }

    # Get index statistics if detailed mode
    $indexes = @()
    if ($DetailLevel -eq "details") {
        $indexes = Get-IndexStatistics -Tables $tables
    }

    if ($cfg.StepDebug -and $cfg.StopAfter -eq 'indexes') {
        Write-Log -Level "INFO" -Message "StepDebug: parsed $($indexes.Count) index entries"
        $sampleIdx = $indexes | Select-Object -First 10 | ForEach-Object { "{0} | {1} | {2}" -f $_.TableName, $_.IndexName, $_.SizePretty }
        if ($sampleIdx) { Write-Log -Level "INFO" -Message ("StepDebug: sample parsed indexes:`n" + ($sampleIdx -join "`n")) }
        Write-Log -Level "INFO" -Message "StepDebug: exiting after parsing indexes"
        exit 0
    }

    # Get user permissions
    $users = Get-DatabaseUsers
    if (-not $users) {
        Write-Log -Level "WARN" -Message "Failed to get database users"
        $users = @()
    }

    $permissions = Get-UserPermissions -Users $users

    # Format output
    $output = @()

    # Database summary
    $output += Format-DatabaseSummary -DatabaseSize $dbSize -TableCount $tables.Count -UserCount $users.Count

    # Table statistics
    $output += Format-TableStatistics -Tables $tables -ExactCounts $exactCounts -Indexes $indexes -Detailed:($DetailLevel -eq "details")

    # User permissions
    $output += Format-UserPermissions -Users $users -Permissions $permissions

    $fullOutput = $output -join "`r`n"

    # Output to screen
    Write-Host $fullOutput

    # Export to file if specified
    if ($OutputFile) {
        # Add timestamp to filename if not already present
        if (-not ($OutputFile -match "\d{8}_\d{6}")) {
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $filenameWithTimestamp = "$timestamp-$OutputFile"
        } else {
            $filenameWithTimestamp = $OutputFile
        }

        Export-Output -Content $fullOutput -Filename $filenameWithTimestamp | Out-Null
    }

    Write-Log -Level "INFO" -Message "Qlik Sense Repository Database Overview completed successfully"
    exit 0
}

# Run main function
Main
