#!/usr/bin/env pwsh
#===============================================================================
# Qlik Sense Repository Database - User Group Memberships
#===============================================================================
# This script provides an overview of user group memberships in the Qlik Sense
# repository database. It queries the Users and UserAttributes tables to show:
#
#   - Total users, groups, and group-membership rows
#   - Average groups per user
#   - Top-N users by group count and top-N groups by user count
#   - Optional full user/group listings and filtered detail views
#
# All settings are configurable via environment variables or parameters.
# The script is READ-ONLY and does NOT modify the repository database.
#
# Requirements:
# - PowerShell Core 6.0+ (cross-platform)
# - PostgreSQL client tools (psql) version 12+
#
# Usage:
#   .\user-group-memberships.ps1                              # Summary
#   .\user-group-memberships.ps1 -DetailLevel details         # Detailed report
#   .\user-group-memberships.ps1 -ListUsers                   # List all users
#   .\user-group-memberships.ps1 -ListGroups                  # List all groups
#   .\user-group-memberships.ps1 -FilterUser 'DOMAIN\userId'  # Specific user
#   .\user-group-memberships.ps1 -FilterGroup 'GroupName'     # Specific group
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
# Version: 1.0.0
#===============================================================================

#requires -version 6.0

#-------------------------------------------------------------------------------
# WARNING: PERFORMANCE IMPACT DISCLAIMER
#-------------------------------------------------------------------------------
# This script is READ-ONLY and does NOT modify the repository database.
# However, it performs queries against the database which may cause performance
# impact in the Qlik Sense environment. Run during maintenance windows or
# off-peak hours to minimize risk.
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
    [switch]$ListUsers,

    [Parameter(Mandatory = $false)]
    [switch]$ListGroups,

    [Parameter(Mandatory = $false)]
    [string]$FilterUser = "",

    [Parameter(Mandatory = $false)]
    [string]$FilterGroup = "",

    [Parameter(Mandatory = $false)]
    [int]$TopN = 10,

    [Parameter(Mandatory = $false)]
    [string[]]$RelevantGroups = @(),

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

    [ValidateSet("connection","version","summary_stats","users","groups","none")]
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

#===============================================================================
# Data Retrieval Functions
#===============================================================================

<#
.SYNOPSIS
    Retrieves summary statistics about users and group memberships.

.DESCRIPTION
    Queries the Users and UserAttributes tables to compute:
    - Total user count
    - Users with at least one group membership
    - Users with zero group memberships
    - Total group-membership rows (UserAttributes where AttributeType = 'Group')
    - Distinct group count
    - Average, minimum, and maximum groups per user

.OUTPUTS
    [PSCustomObject] with TotalUsers, UsersWithGroups, UsersWithoutGroups,
    TotalGroupRows, DistinctGroups, AvgGroupsPerUser, MinGroupsPerUser,
    MaxGroupsPerUser. Returns $null on failure.
#>
function Get-GroupMembershipSummary {
    Write-Log -Level "INFO" -Message "Retrieving group membership summary statistics"

    $query = @"
SELECT
    (SELECT COUNT(*) FROM public."Users") as total_users,
    (SELECT COUNT(DISTINCT ua."User_ID")
     FROM public."UserAttributes" ua
     WHERE ua."AttributeType" = 'Group') as users_with_groups,
    (SELECT COUNT(*) FROM public."UserAttributes"
     WHERE "AttributeType" = 'Group') as total_group_rows,
    (SELECT COUNT(DISTINCT "AttributeValue")
     FROM public."UserAttributes"
     WHERE "AttributeType" = 'Group') as distinct_groups;
"@

    $result = Invoke-PsqlQuery -Query $query

    if ($LASTEXITCODE -ne 0 -or -not $result) {
        Write-Log -Level "ERROR" -Message "Failed to retrieve group membership summary"
        return $null
    }

    $resultText = if ($result -is [array]) { ($result -join "`n").Trim() } else { $result.ToString().Trim() }
    Write-Log -Level "DEBUG" -Message "Summary stats raw: '$resultText'"

    $parts = $resultText -split '\|'
    if ($parts.Length -lt 4) {
        Write-Log -Level "ERROR" -Message "Unexpected summary stats format: '$resultText'"
        return $null
    }

    $totalUsers    = [int64]$parts[0].Trim()
    $usersWithGroups = [int64]$parts[1].Trim()
    $totalGroupRows  = [int64]$parts[2].Trim()
    $distinctGroups  = [int64]$parts[3].Trim()
    $usersWithoutGroups = $totalUsers - $usersWithGroups

    # Get avg/min/max groups per user (only for users that have groups)
    $queryStats = @"
SELECT
    COALESCE(ROUND(AVG(cnt), 2), 0),
    COALESCE(MIN(cnt), 0),
    COALESCE(MAX(cnt), 0)
FROM (
    SELECT u."ID", COUNT(ua."ID") as cnt
    FROM public."Users" u
    LEFT JOIN public."UserAttributes" ua
        ON ua."User_ID" = u."ID" AND ua."AttributeType" = 'Group'
    GROUP BY u."ID"
) sub;
"@

    $resultStats = Invoke-PsqlQuery -Query $queryStats

    $avgGroups = 0.0; $minGroups = 0; $maxGroups = 0
    if ($LASTEXITCODE -eq 0 -and $resultStats) {
        $statsText = if ($resultStats -is [array]) { ($resultStats -join "`n").Trim() } else { $resultStats.ToString().Trim() }
        $statsParts = $statsText -split '\|'
        if ($statsParts.Length -ge 3) {
            $avgGroups = [double]$statsParts[0].Trim()
            $minGroups = [int64]$statsParts[1].Trim()
            $maxGroups = [int64]$statsParts[2].Trim()
        }
    }

    $summary = [PSCustomObject]@{
        TotalUsers          = $totalUsers
        UsersWithGroups     = $usersWithGroups
        UsersWithoutGroups  = $usersWithoutGroups
        TotalGroupRows      = $totalGroupRows
        DistinctGroups      = $distinctGroups
        AvgGroupsPerUser    = $avgGroups
        MinGroupsPerUser    = $minGroups
        MaxGroupsPerUser    = $maxGroups
    }

    $cfg = $script:QSRConfig
    if ($cfg.StepDebug -and $cfg.StopAfter -eq 'summary_stats') {
        Write-Log -Level "INFO" -Message "StepDebug: Summary stats: $($summary | Format-List | Out-String)"
        Write-Log -Level "INFO" -Message "StepDebug: exiting after summary_stats"
        exit 0
    }

    return $summary
}

<#
.SYNOPSIS
    Retrieves row counts and byte sizes of the Users and UserAttributes tables.

.DESCRIPTION
    Queries pg_class and pg_namespace for exact row counts (via COUNT(*)) and
    table sizes (pg_total_relation_size) for the two key tables.

.OUTPUTS
    [PSCustomObject[]] — Each object has: TableName, RowCount (int64),
    TotalBytes (int64), TotalSizeHuman (string). Returns empty array on failure.
#>
function Get-TableSizeInfo {
    Write-Log -Level "INFO" -Message "Retrieving table size info for Users and UserAttributes"

    $query = @"
SELECT
    'Users' AS table_name,
    (SELECT COUNT(*) FROM public."Users") AS row_count,
    pg_total_relation_size(c.oid) AS total_bytes,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size_human
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relname = 'Users'
UNION ALL
SELECT
    'UserAttributes' AS table_name,
    (SELECT COUNT(*) FROM public."UserAttributes") AS row_count,
    pg_total_relation_size(c.oid) AS total_bytes,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size_human
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relname = 'UserAttributes';
"@

    $result = Invoke-PsqlQuery -Query $query

    $items = @()
    if ($LASTEXITCODE -ne 0 -or -not $result) {
        Write-Log -Level "WARN" -Message "Failed to retrieve table size info"
        return $items
    }

    $rows = if ($result -is [array]) { $result } else { $result -split "`n" }
    foreach ($line in $rows) {
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split '\|'
        if ($parts.Length -ge 4) {
            $items += [PSCustomObject]@{
                TableName      = $parts[0].Trim()
                RowCount       = [int64]$parts[1].Trim()
                TotalBytes     = [int64]$parts[2].Trim()
                TotalSizeHuman = $parts[3].Trim()
            }
        }
    }
    return $items
}

<#
.SYNOPSIS
    Retrieves the distribution of group counts across users.

.DESCRIPTION
    Produces a frequency table: for each distinct group-count value (0, 1, 2, …)
    returns how many users have exactly that many group memberships.
    Used to render a text-based histogram.

.OUTPUTS
    [PSCustomObject[]] — Each object has: GroupCount (int), UserCount (int).
    Sorted by GroupCount ascending.
#>
function Get-GroupCountDistribution {
    Write-Log -Level "INFO" -Message "Retrieving group-count distribution"

    $query = @"
SELECT sub.cnt AS group_count, COUNT(*) AS user_count
FROM (
    SELECT u."ID", COUNT(ua."ID") AS cnt
    FROM public."Users" u
    LEFT JOIN public."UserAttributes" ua
        ON ua."User_ID" = u."ID" AND ua."AttributeType" = 'Group'
    GROUP BY u."ID"
) sub
GROUP BY sub.cnt
ORDER BY sub.cnt;
"@

    $result = Invoke-PsqlQuery -Query $query

    $items = @()
    if ($LASTEXITCODE -ne 0 -or -not $result) {
        Write-Log -Level "WARN" -Message "Failed to retrieve group-count distribution"
        return $items
    }

    $rows = if ($result -is [array]) { $result } else { $result -split "`n" }
    foreach ($line in $rows) {
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split '\|'
        if ($parts.Length -ge 2) {
            $items += [PSCustomObject]@{
                GroupCount = [int64]$parts[0].Trim()
                UserCount  = [int64]$parts[1].Trim()
            }
        }
    }
    return $items
}

<#
.SYNOPSIS
    Retrieves the top-N users with the most group memberships.

.PARAMETER TopN
    Number of users to return. Default: 10.

.OUTPUTS
    [PSCustomObject[]] — Each object has: UserDirectory, UserId, Name, GroupCount.
#>
function Get-TopUsersByGroupCount {
    param([int]$TopN = 10)

    Write-Log -Level "INFO" -Message "Retrieving top $TopN users by group count"

    $query = @"
SELECT
    u."UserDirectory",
    u."UserId",
    u."Name",
    COUNT(ua."ID") as group_count
FROM public."Users" u
JOIN public."UserAttributes" ua
    ON ua."User_ID" = u."ID" AND ua."AttributeType" = 'Group'
GROUP BY u."ID", u."UserDirectory", u."UserId", u."Name"
ORDER BY group_count DESC
LIMIT $TopN;
"@

    $result = Invoke-PsqlQuery -Query $query
    return ConvertTo-UserGroupRows -RawResult $result -ColumnNames @("UserDirectory","UserId","Name","GroupCount")
}

<#
.SYNOPSIS
    Retrieves the top-N groups with the most user members.

.PARAMETER TopN
    Number of groups to return. Default: 10.

.OUTPUTS
    [PSCustomObject[]] — Each object has: GroupName, UserCount.
#>
function Get-TopGroupsByUserCount {
    param([int]$TopN = 10)

    Write-Log -Level "INFO" -Message "Retrieving top $TopN groups by user count"

    $query = @"
SELECT
    ua."AttributeValue" as group_name,
    COUNT(DISTINCT ua."User_ID") as user_count
FROM public."UserAttributes" ua
WHERE ua."AttributeType" = 'Group'
GROUP BY ua."AttributeValue"
ORDER BY user_count DESC
LIMIT $TopN;
"@

    $result = Invoke-PsqlQuery -Query $query
    return ConvertTo-GroupRows -RawResult $result
}

<#
.SYNOPSIS
    Lists all users with their group counts, sorted by group count descending.

.OUTPUTS
    [PSCustomObject[]] — UserDirectory, UserId, Name, GroupCount.
#>
function Get-AllUsersWithGroupCounts {
    Write-Log -Level "INFO" -Message "Retrieving all users with group counts"

    $query = @"
SELECT
    u."UserDirectory",
    u."UserId",
    u."Name",
    COUNT(ua."ID") as group_count
FROM public."Users" u
LEFT JOIN public."UserAttributes" ua
    ON ua."User_ID" = u."ID" AND ua."AttributeType" = 'Group'
GROUP BY u."ID", u."UserDirectory", u."UserId", u."Name"
ORDER BY group_count DESC, u."UserDirectory", u."UserId";
"@

    $result = Invoke-PsqlQuery -Query $query
    return ConvertTo-UserGroupRows -RawResult $result -ColumnNames @("UserDirectory","UserId","Name","GroupCount")
}

<#
.SYNOPSIS
    Lists all distinct groups with their member counts, sorted by member count descending.

.OUTPUTS
    [PSCustomObject[]] — GroupName, UserCount.
#>
function Get-AllGroupsWithUserCounts {
    Write-Log -Level "INFO" -Message "Retrieving all groups with user counts"

    $query = @"
SELECT
    ua."AttributeValue" as group_name,
    COUNT(DISTINCT ua."User_ID") as user_count
FROM public."UserAttributes" ua
WHERE ua."AttributeType" = 'Group'
GROUP BY ua."AttributeValue"
ORDER BY user_count DESC, ua."AttributeValue";
"@

    $result = Invoke-PsqlQuery -Query $query
    return ConvertTo-GroupRows -RawResult $result
}

<#
.SYNOPSIS
    Retrieves detailed info for a specific user, including all group memberships.

.DESCRIPTION
    Accepts a user identifier in DOMAIN\userId format. Splits on backslash to
    match the UserDirectory and UserId columns in public."Users".

.PARAMETER UserIdentifier
    The user in DOMAIN\userId format (e.g. 'MYCOMPANY\jdoe').

.OUTPUTS
    [PSCustomObject] with UserDirectory, UserId, Name, Inactive, CreatedDate,
    ModifiedDate, Groups (string[]).  Returns $null if not found.
#>
function Get-UserDetail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserIdentifier
    )

    # Parse DOMAIN\userId
    $slashIndex = $UserIdentifier.IndexOf('\')
    if ($slashIndex -le 0) {
        Write-Log -Level "ERROR" -Message "Invalid user format: '$UserIdentifier'. Expected DOMAIN\userId"
        return $null
    }
    $domain = $UserIdentifier.Substring(0, $slashIndex).Replace("'", "''")
    $userId = $UserIdentifier.Substring($slashIndex + 1).Replace("'", "''")

    Write-Log -Level "INFO" -Message "Retrieving details for user: $UserIdentifier"

    # Get user info
    $query = @"
SELECT
    u."UserDirectory",
    u."UserId",
    u."Name",
    u."Inactive",
    u."CreatedDate",
    u."ModifiedDate"
FROM public."Users" u
WHERE u."UserDirectory" = '$domain' AND u."UserId" = '$userId';
"@

    $result = Invoke-PsqlQuery -Query $query

    if ($LASTEXITCODE -ne 0 -or -not $result) {
        Write-Log -Level "WARN" -Message "User not found: $UserIdentifier"
        return $null
    }

    $resultText = if ($result -is [array]) { ($result -join "`n").Trim() } else { $result.ToString().Trim() }
    $parts = $resultText -split '\|'
    if ($parts.Length -lt 6) {
        Write-Log -Level "ERROR" -Message "Unexpected user detail format: '$resultText'"
        return $null
    }

    # Get groups for this user
    $queryGroups = @"
SELECT ua."AttributeValue"
FROM public."UserAttributes" ua
JOIN public."Users" u ON u."ID" = ua."User_ID"
WHERE u."UserDirectory" = '$domain' AND u."UserId" = '$userId'
  AND ua."AttributeType" = 'Group'
ORDER BY ua."AttributeValue";
"@

    $groupResult = Invoke-PsqlQuery -Query $queryGroups
    $groups = @()
    if ($LASTEXITCODE -eq 0 -and $groupResult) {
        $rows = if ($groupResult -is [array]) { $groupResult } else { $groupResult -split "`n" }
        foreach ($row in $rows) {
            $row = $row.Trim()
            if (-not [string]::IsNullOrWhiteSpace($row)) {
                $groups += $row
            }
        }
    }

    return [PSCustomObject]@{
        UserDirectory = $parts[0].Trim()
        UserId        = $parts[1].Trim()
        Name          = $parts[2].Trim()
        Inactive      = ($parts[3].Trim() -eq 't')
        CreatedDate   = $parts[4].Trim()
        ModifiedDate  = $parts[5].Trim()
        Groups        = $groups
    }
}

<#
.SYNOPSIS
    Retrieves detailed info for a specific group, including all member users.

.PARAMETER GroupName
    The group name to look up (matches AttributeValue in UserAttributes).

.OUTPUTS
    [PSCustomObject] with GroupName, Members (PSCustomObject[] with UserDirectory,
    UserId, Name). Returns $null if not found.
#>
function Get-GroupDetail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GroupName
    )

    $safeName = $GroupName.Replace("'", "''")
    Write-Log -Level "INFO" -Message "Retrieving details for group: $GroupName"

    $query = @"
SELECT
    u."UserDirectory",
    u."UserId",
    u."Name"
FROM public."Users" u
JOIN public."UserAttributes" ua ON ua."User_ID" = u."ID"
WHERE ua."AttributeType" = 'Group'
  AND ua."AttributeValue" = '$safeName'
ORDER BY u."UserDirectory", u."UserId";
"@

    $result = Invoke-PsqlQuery -Query $query

    if ($LASTEXITCODE -ne 0 -or -not $result) {
        Write-Log -Level "WARN" -Message "Group not found or has no members: $GroupName"
        return $null
    }

    $members = @()
    $rows = if ($result -is [array]) { $result } else { $result -split "`n" }
    foreach ($line in $rows) {
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $parts = $line -split '\|'
        if ($parts.Length -ge 3) {
            $members += [PSCustomObject]@{
                UserDirectory = $parts[0].Trim()
                UserId        = $parts[1].Trim()
                Name          = $parts[2].Trim()
            }
        }
    }

    return [PSCustomObject]@{
        GroupName = $GroupName
        Members   = $members
    }
}

#===============================================================================
# Parsing Helpers
#===============================================================================

<#
.SYNOPSIS
    Converts raw psql pipe-separated output to user-group row objects.

.DESCRIPTION
    Parses lines with 4 pipe-separated fields: UserDirectory, UserId, Name, GroupCount.

.PARAMETER RawResult
    Raw psql output (string or string[]).

.PARAMETER ColumnNames
    Not used for parsing but documents the expected column order.

.OUTPUTS
    [PSCustomObject[]]
#>
function ConvertTo-UserGroupRows {
    param(
        [Parameter(Mandatory = $false)]
        $RawResult,
        [string[]]$ColumnNames
    )

    $items = @()
    if (-not $RawResult) { return $items }

    $rows = if ($RawResult -is [array]) { $RawResult } else { $RawResult -split "`n" }
    foreach ($line in $rows) {
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $parts = $line -split '\|'
        if ($parts.Length -ge 4) {
            $items += [PSCustomObject]@{
                UserDirectory = $parts[0].Trim()
                UserId        = $parts[1].Trim()
                Name          = $parts[2].Trim()
                GroupCount    = [int64]$parts[3].Trim()
            }
        } else {
            Write-Log -Level "DEBUG" -Message "Skipping unparsable user-group line: '$line'"
        }
    }
    return $items
}

<#
.SYNOPSIS
    Converts raw psql pipe-separated output to group row objects.

.DESCRIPTION
    Parses lines with 2 pipe-separated fields: GroupName, UserCount.

.PARAMETER RawResult
    Raw psql output (string or string[]).

.OUTPUTS
    [PSCustomObject[]]
#>
function ConvertTo-GroupRows {
    param(
        [Parameter(Mandatory = $false)]
        $RawResult
    )

    $items = @()
    if (-not $RawResult) { return $items }

    $rows = if ($RawResult -is [array]) { $RawResult } else { $RawResult -split "`n" }
    foreach ($line in $rows) {
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $parts = $line -split '\|'
        if ($parts.Length -ge 2) {
            $items += [PSCustomObject]@{
                GroupName = $parts[0].Trim()
                UserCount = [int64]$parts[1].Trim()
            }
        } else {
            Write-Log -Level "DEBUG" -Message "Skipping unparsable group line: '$line'"
        }
    }
    return $items
}

#===============================================================================
# Output / Formatting Functions
#===============================================================================

<#
.SYNOPSIS
    Formats the group membership summary into a readable text report.

.PARAMETER Summary
    Summary object from Get-GroupMembershipSummary.

.PARAMETER TopUsers
    Top-N users array from Get-TopUsersByGroupCount.

.PARAMETER TopGroups
    Top-N groups array from Get-TopGroupsByUserCount.

.PARAMETER TopN
    Number of top entries displayed.

.OUTPUTS
    [string] — Formatted multi-line report text.
#>
function Format-GroupMembershipSummary {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Summary,

        [Parameter(Mandatory = $true)]
        [array]$TopUsers,

        [Parameter(Mandatory = $true)]
        [array]$TopGroups,

        [Parameter(Mandatory = $false)]
        [array]$Distribution = @(),

        [Parameter(Mandatory = $false)]
        [array]$TableSizes = @(),

        [int]$TopN = 10
    )

    $cfg = $script:QSRConfig
    $output = @()
    $output += "=" * 80
    $output += "Qlik Sense Repository - User Group Memberships"
    $output += "=" * 80
    $output += ""
    $output += "Connection Information:"
    $output += "  Host:       $($cfg.DbHost)"
    $output += "  Port:       $($cfg.DbPort)"
    $output += "  Database:   $($cfg.DbName)"
    $output += "  User:       $($cfg.DbUser)"
    $output += ""
    $output += "-" * 80
    $output += "Summary Statistics:"
    $output += "-" * 80
    $output += ""
    $output += "  Total Users:              $($Summary.TotalUsers.ToString("N0"))"
    $output += "  Users with Groups:        $($Summary.UsersWithGroups.ToString("N0"))"
    $output += "  Users without Groups:     $($Summary.UsersWithoutGroups.ToString("N0"))"
    $output += "  Total Group Memberships:  $($Summary.TotalGroupRows.ToString("N0"))"
    $output += "  Distinct Groups:          $($Summary.DistinctGroups.ToString("N0"))"
    $output += ""
    $output += "  Avg Groups per User:      $($Summary.AvgGroupsPerUser)"
    $output += "  Min Groups per User:      $($Summary.MinGroupsPerUser)"
    $output += "  Max Groups per User:      $($Summary.MaxGroupsPerUser)"
    $output += ""

    # Table sizes
    if ($TableSizes.Count -gt 0) {
        $output += "-" * 80
        $output += "Table Storage:"
        $output += "-" * 80
        $output += ""
        foreach ($tbl in $TableSizes) {
            $output += "  $($tbl.TableName):"
            $output += "    Rows:       $($tbl.RowCount.ToString('N0'))"
            $output += "    Size:       $($tbl.TotalSizeHuman) ($($tbl.TotalBytes.ToString('N0')) bytes)"
        }
        $output += ""
    }

    # Distribution histogram
    if ($Distribution.Count -gt 0) {
        $histText = Format-DistributionHistogram -Distribution $Distribution -TotalUsers $Summary.TotalUsers
        $output += $histText
        $output += ""
    }

    # Top users by group count
    $output += "-" * 80
    $output += "Top $TopN Users by Group Count:"
    $output += "-" * 80

    if ($TopUsers.Count -gt 0) {
        $tableData = $TopUsers | ForEach-Object {
            [PSCustomObject]@{
                "User Directory" = $_.UserDirectory
                "User ID"        = $_.UserId
                "Name"           = $_.Name
                "Group Count"    = $_.GroupCount.ToString("N0")
            }
        }
        $tableData | Format-Table -AutoSize | Out-String | ForEach-Object { $output += $_ }
    } else {
        $output += "  (no data)"
        $output += ""
    }

    # Top groups by user count
    $output += "-" * 80
    $output += "Top $TopN Groups by User Count:"
    $output += "-" * 80

    if ($TopGroups.Count -gt 0) {
        $tableData = $TopGroups | ForEach-Object {
            [PSCustomObject]@{
                "Group Name"  = $_.GroupName
                "User Count"  = $_.UserCount.ToString("N0")
            }
        }
        $tableData | Format-Table -AutoSize | Out-String | ForEach-Object { $output += $_ }
    } else {
        $output += "  (no data)"
        $output += ""
    }

    $output += "=" * 80

    return $output -join "`r`n"
}

<#
.SYNOPSIS
    Formats a text-based horizontal histogram of the group-count distribution.

.DESCRIPTION
    Renders a bar chart where each row represents a group-count bucket
    (0 groups, 1 group, 2 groups, …). Bars are drawn with '#' characters,
    scaled so the longest bar is BarWidth characters. Each row also shows
    the user count and percentage of total.

.PARAMETER Distribution
    Array of objects with GroupCount and UserCount from Get-GroupCountDistribution.

.PARAMETER TotalUsers
    Total number of users (for percentage calculation).

.PARAMETER BarWidth
    Maximum bar width in characters. Default: 40.

.OUTPUTS
    [string] — Formatted multi-line histogram text.
#>
function Format-DistributionHistogram {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Distribution,

        [Parameter(Mandatory = $true)]
        [int64]$TotalUsers,

        [int]$BarWidth = 40
    )

    $output = @()
    $output += "-" * 80
    $output += "Distribution: Users by Number of Group Memberships"
    $output += "-" * 80
    $output += ""

    if ($Distribution.Count -eq 0 -or $TotalUsers -eq 0) {
        $output += "  (no data)"
        $output += ""
        return $output -join "`r`n"
    }

    $maxCount = ($Distribution | Measure-Object -Property UserCount -Maximum).Maximum
    if ($maxCount -eq 0) { $maxCount = 1 }

    # Column widths
    $maxGroupCount = ($Distribution | Measure-Object -Property GroupCount -Maximum).Maximum
    $labelWidth = [Math]::Max(([string]$maxGroupCount).Length + 8, 10)  # "N groups" label
    $countWidth = [Math]::Max(([string]$maxCount).Length, 5)

    # Header
    $header = "  {0,-$labelWidth}  {1,$countWidth}  {2,6}  Bar" -f "Groups", "Users", "%"
    $output += $header
    $output += "  $("-" * ($labelWidth + $countWidth + $BarWidth + 12))"

    foreach ($bucket in $Distribution) {
        $gc = $bucket.GroupCount
        $uc = $bucket.UserCount
        $pct = [Math]::Round(($uc / $TotalUsers) * 100, 1)
        $barLen = [Math]::Max([Math]::Round(($uc / $maxCount) * $BarWidth), ($uc -gt 0 ? 1 : 0))
        $bar = "#" * $barLen

        $label = if ($gc -eq 1) { "$gc group" } else { "$gc groups" }
        $line = "  {0,-$labelWidth}  {1,$countWidth}  {2,5:N1}%  {3}" -f $label, $uc, $pct, $bar
        $output += $line
    }

    $output += ""
    return $output -join "`r`n"
}

<#
.SYNOPSIS
    Formats the full user list with group counts.

.PARAMETER Users
    Array of user objects with GroupCount from Get-AllUsersWithGroupCounts.

.OUTPUTS
    [string] — Formatted multi-line report text.
#>
function Format-UserList {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Users
    )

    $output = @()
    $output += "=" * 80
    $output += "All Users with Group Counts (sorted by group count, descending)"
    $output += "=" * 80
    $output += ""
    $output += "Total Users: $($Users.Count)"
    $output += ""

    if ($Users.Count -gt 0) {
        $tableData = $Users | ForEach-Object {
            [PSCustomObject]@{
                "User Directory" = $_.UserDirectory
                "User ID"        = $_.UserId
                "Name"           = $_.Name
                "Group Count"    = $_.GroupCount.ToString("N0")
            }
        }
        $tableData | Format-Table -AutoSize | Out-String | ForEach-Object { $output += $_ }
    } else {
        $output += "  (no users found)"
        $output += ""
    }

    $output += "=" * 80
    return $output -join "`r`n"
}

<#
.SYNOPSIS
    Formats the full group list with user counts.

.PARAMETER Groups
    Array of group objects with UserCount from Get-AllGroupsWithUserCounts.

.OUTPUTS
    [string] — Formatted multi-line report text.
#>
function Format-GroupList {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Groups
    )

    $output = @()
    $output += "=" * 80
    $output += "All Groups with User Counts (sorted by user count, descending)"
    $output += "=" * 80
    $output += ""
    $output += "Total Groups: $($Groups.Count)"
    $output += ""

    if ($Groups.Count -gt 0) {
        $tableData = $Groups | ForEach-Object {
            [PSCustomObject]@{
                "Group Name"  = $_.GroupName
                "User Count"  = $_.UserCount.ToString("N0")
            }
        }
        $tableData | Format-Table -AutoSize | Out-String | ForEach-Object { $output += $_ }
    } else {
        $output += "  (no groups found)"
        $output += ""
    }

    $output += "=" * 80
    return $output -join "`r`n"
}

<#
.SYNOPSIS
    Formats the detail view for a single user, including their group memberships.

.PARAMETER UserDetail
    Object from Get-UserDetail with Groups array.

.OUTPUTS
    [string] — Formatted multi-line report text.
#>
function Format-UserDetail {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$UserDetail
    )

    $output = @()
    $output += "=" * 80
    $output += "User Detail: $($UserDetail.UserDirectory)\$($UserDetail.UserId)"
    $output += "=" * 80
    $output += ""
    $output += "  User Directory:  $($UserDetail.UserDirectory)"
    $output += "  User ID:         $($UserDetail.UserId)"
    $output += "  Name:            $($UserDetail.Name)"
    $output += "  Inactive:        $(if ($UserDetail.Inactive) { 'Yes' } else { 'No' })"
    $output += "  Created:         $($UserDetail.CreatedDate)"
    $output += "  Modified:        $($UserDetail.ModifiedDate)"
    $output += ""
    $output += "-" * 80
    $output += "Group Memberships: $($UserDetail.Groups.Count)"
    $output += "-" * 80

    if ($UserDetail.Groups.Count -gt 0) {
        $output += ""
        foreach ($group in $UserDetail.Groups) {
            $output += "  - $group"
        }
        $output += ""
    } else {
        $output += ""
        $output += "  (no group memberships)"
        $output += ""
    }

    $output += "=" * 80
    return $output -join "`r`n"
}

<#
.SYNOPSIS
    Formats the detail view for a single group, including its member users.

.PARAMETER GroupDetail
    Object from Get-GroupDetail with Members array.

.OUTPUTS
    [string] — Formatted multi-line report text.
#>
function Format-GroupDetail {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$GroupDetail
    )

    $output = @()
    $output += "=" * 80
    $output += "Group Detail: $($GroupDetail.GroupName)"
    $output += "=" * 80
    $output += ""
    $output += "  Group Name:   $($GroupDetail.GroupName)"
    $output += "  Member Count: $($GroupDetail.Members.Count)"
    $output += ""
    $output += "-" * 80
    $output += "Members:"
    $output += "-" * 80

    if ($GroupDetail.Members.Count -gt 0) {
        $tableData = $GroupDetail.Members | ForEach-Object {
            [PSCustomObject]@{
                "User Directory" = $_.UserDirectory
                "User ID"        = $_.UserId
                "Name"           = $_.Name
            }
        }
        $tableData | Format-Table -AutoSize | Out-String | ForEach-Object { $output += $_ }
    } else {
        $output += ""
        $output += "  (no members)"
        $output += ""
    }

    $output += "=" * 80
    return $output -join "`r`n"
}

<#
.SYNOPSIS
    Retrieves all group names and their per-user membership rows for relevance
    classification.

.DESCRIPTION
    Returns every (GroupName, UserDirectory, UserId) tuple from UserAttributes
    where AttributeType = 'Group'. The caller classifies groups as relevant
    or bloat using the RelevantGroups substring patterns.

.OUTPUTS
    [PSCustomObject[]] — Each object has: GroupName, UserDirectory, UserId.
#>
function Get-AllGroupMembershipRows {
    Write-Log -Level "INFO" -Message "Retrieving all group membership rows for relevance analysis"

    $query = @"
SELECT
    ua."AttributeValue" AS group_name,
    u."UserDirectory",
    u."UserId"
FROM public."UserAttributes" ua
JOIN public."Users" u ON u."ID" = ua."User_ID"
WHERE ua."AttributeType" = 'Group'
ORDER BY ua."AttributeValue", u."UserDirectory", u."UserId";
"@

    $result = Invoke-PsqlQuery -Query $query

    $items = @()
    if ($LASTEXITCODE -ne 0 -or -not $result) {
        Write-Log -Level "WARN" -Message "Failed to retrieve group membership rows"
        return $items
    }

    $rows = if ($result -is [array]) { $result } else { $result -split "`n" }
    foreach ($line in $rows) {
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split '\|'
        if ($parts.Length -ge 3) {
            $items += [PSCustomObject]@{
                GroupName     = $parts[0].Trim()
                UserDirectory = $parts[1].Trim()
                UserId        = $parts[2].Trim()
            }
        }
    }
    return $items
}

<#
.SYNOPSIS
    Classifies groups as relevant or bloat and computes metrics.

.DESCRIPTION
    Given the list of all group membership rows and the user-supplied relevance
    patterns, classifies each distinct group as "relevant" (its name contains
    at least one pattern as a case-insensitive substring) or "bloat".

    Returns an analysis object with:
    - Patterns used
    - Relevant/bloat group lists with user counts
    - Summary counts: total groups, relevant/bloat groups, total/relevant/bloat
      membership rows, users with relevant groups, users with only bloat

.PARAMETER AllRows
    Array from Get-AllGroupMembershipRows.

.PARAMETER Patterns
    String array of case-insensitive substring patterns.

.PARAMETER TotalUsers
    Total user count (for percentage calculations).

.OUTPUTS
    [PSCustomObject] with analysis results.
#>
function Get-RelevanceAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [array]$AllRows,

        [Parameter(Mandatory = $true)]
        [string[]]$Patterns,

        [Parameter(Mandatory = $true)]
        [int64]$TotalUsers
    )

    Write-Log -Level "INFO" -Message "Classifying groups using patterns: $($Patterns -join ', ')"

    # Build distinct group -> user-count map
    $groupUsers = @{}
    $userRelevant = @{}   # userId -> $true if has relevant group
    $userBloat    = @{}   # userId -> $true if has bloat group

    foreach ($row in $AllRows) {
        $gn = $row.GroupName
        if (-not $groupUsers.ContainsKey($gn)) {
            $groupUsers[$gn] = [System.Collections.Generic.HashSet[string]]::new()
        }
        $userKey = "$($row.UserDirectory)\$($row.UserId)"
        [void]$groupUsers[$gn].Add($userKey)
    }

    # Classify each group
    $relevantGroups = @()
    $bloatGroups = @()

    foreach ($gn in ($groupUsers.Keys | Sort-Object)) {
        $isRelevant = $false
        foreach ($pat in $Patterns) {
            if ($gn.IndexOf($pat, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $isRelevant = $true
                break
            }
        }

        $userCount = $groupUsers[$gn].Count
        $obj = [PSCustomObject]@{
            GroupName = $gn
            UserCount = $userCount
            Category  = if ($isRelevant) { "Relevant" } else { "Bloat" }
        }

        if ($isRelevant) {
            $relevantGroups += $obj
            foreach ($uk in $groupUsers[$gn]) { $userRelevant[$uk] = $true }
        } else {
            $bloatGroups += $obj
            foreach ($uk in $groupUsers[$gn]) { $userBloat[$uk] = $true }
        }
    }

    # Sort by user count descending
    $relevantGroups = $relevantGroups | Sort-Object -Property UserCount -Descending
    $bloatGroups    = $bloatGroups    | Sort-Object -Property UserCount -Descending

    $totalGroups       = $relevantGroups.Count + $bloatGroups.Count
    $totalRows         = $AllRows.Count
    $relevantRows      = ($AllRows | Where-Object {
        $gn = $_.GroupName
        $isRel = $false
        foreach ($pat in $Patterns) {
            if ($gn.IndexOf($pat, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $isRel = $true; break
            }
        }
        $isRel
    }).Count
    $bloatRows         = $totalRows - $relevantRows
    $usersWithRelevant = $userRelevant.Count
    $usersWithBloat    = $userBloat.Count
    $usersOnlyBloat    = ($userBloat.Keys | Where-Object { -not $userRelevant.ContainsKey($_) }).Count
    $usersOnlyRelevant = ($userRelevant.Keys | Where-Object { -not $userBloat.ContainsKey($_) }).Count
    $usersBoth         = ($userRelevant.Keys | Where-Object { $userBloat.ContainsKey($_) }).Count
    $usersNoGroups     = $TotalUsers - ($userRelevant.Keys + $userBloat.Keys | Sort-Object -Unique).Count

    return [PSCustomObject]@{
        Patterns           = $Patterns
        TotalGroups        = $totalGroups
        RelevantGroupCount = $relevantGroups.Count
        BloatGroupCount    = $bloatGroups.Count
        RelevantGroups     = $relevantGroups
        BloatGroups        = $bloatGroups
        TotalRows          = $totalRows
        RelevantRows       = $relevantRows
        BloatRows          = $bloatRows
        TotalUsers         = $TotalUsers
        UsersWithRelevant  = $usersWithRelevant
        UsersWithBloat     = $usersWithBloat
        UsersOnlyRelevant  = $usersOnlyRelevant
        UsersOnlyBloat     = $usersOnlyBloat
        UsersBoth          = $usersBoth
        UsersNoGroups      = $usersNoGroups
    }
}

<#
.SYNOPSIS
    Formats the relevance analysis into a readable text report section.

.PARAMETER Analysis
    Object from Get-RelevanceAnalysis.

.OUTPUTS
    [string] — Formatted multi-line report text.
#>
function Format-RelevanceAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Analysis
    )

    $output = @()
    $output += "=" * 80
    $output += "Group Relevance Analysis (bloat detection)"
    $output += "=" * 80
    $output += ""
    $output += "  Filter patterns (case-insensitive substring match):"
    foreach ($pat in $Analysis.Patterns) {
        $output += "    - `"$pat`""
    }
    $output += ""
    $output += "-" * 80
    $output += "Summary:"
    $output += "-" * 80
    $output += ""

    $pctRelevantGroups = if ($Analysis.TotalGroups -gt 0) { [Math]::Round(($Analysis.RelevantGroupCount / $Analysis.TotalGroups) * 100, 1) } else { 0 }
    $pctBloatGroups    = if ($Analysis.TotalGroups -gt 0) { [Math]::Round(($Analysis.BloatGroupCount / $Analysis.TotalGroups) * 100, 1) } else { 0 }
    $pctRelevantRows   = if ($Analysis.TotalRows -gt 0)   { [Math]::Round(($Analysis.RelevantRows / $Analysis.TotalRows) * 100, 1) } else { 0 }
    $pctBloatRows      = if ($Analysis.TotalRows -gt 0)   { [Math]::Round(($Analysis.BloatRows / $Analysis.TotalRows) * 100, 1) } else { 0 }

    $output += "  Groups:"
    $output += "    Total:       $($Analysis.TotalGroups)"
    $output += "    Relevant:    $($Analysis.RelevantGroupCount)  ($pctRelevantGroups%)"
    $output += "    Bloat:       $($Analysis.BloatGroupCount)  ($pctBloatGroups%)"
    $output += ""
    $output += "  Membership rows (in UserAttributes):"
    $output += "    Total:       $($Analysis.TotalRows.ToString('N0'))"
    $output += "    Relevant:    $($Analysis.RelevantRows.ToString('N0'))  ($pctRelevantRows%)"
    $output += "    Bloat:       $($Analysis.BloatRows.ToString('N0'))  ($pctBloatRows%)"
    $output += ""
    $output += "  Users ($($Analysis.TotalUsers.ToString('N0')) total):"
    $output += "    With relevant groups:      $($Analysis.UsersWithRelevant.ToString('N0'))"
    $output += "    With bloat groups:         $($Analysis.UsersWithBloat.ToString('N0'))"
    $output += "    With relevant only:        $($Analysis.UsersOnlyRelevant.ToString('N0'))"
    $output += "    With bloat only:           $($Analysis.UsersOnlyBloat.ToString('N0'))"
    $output += "    With both:                 $($Analysis.UsersBoth.ToString('N0'))"
    $output += "    With no groups at all:     $($Analysis.UsersNoGroups.ToString('N0'))"
    $output += ""

    # Relevant groups table
    $output += "-" * 80
    $output += "Relevant Groups ($($Analysis.RelevantGroupCount)):"
    $output += "-" * 80

    if ($Analysis.RelevantGroups.Count -gt 0) {
        $tableData = $Analysis.RelevantGroups | ForEach-Object {
            [PSCustomObject]@{
                "Group Name"  = $_.GroupName
                "User Count"  = $_.UserCount.ToString("N0")
            }
        }
        $tableData | Format-Table -AutoSize | Out-String | ForEach-Object { $output += $_ }
    } else {
        $output += "  (none)"
        $output += ""
    }

    # Bloat groups table
    $output += "-" * 80
    $output += "Bloat Groups ($($Analysis.BloatGroupCount)):"
    $output += "-" * 80

    if ($Analysis.BloatGroups.Count -gt 0) {
        $tableData = $Analysis.BloatGroups | ForEach-Object {
            [PSCustomObject]@{
                "Group Name"  = $_.GroupName
                "User Count"  = $_.UserCount.ToString("N0")
            }
        }
        $tableData | Format-Table -AutoSize | Out-String | ForEach-Object { $output += $_ }
    } else {
        $output += "  (none)"
        $output += ""
    }

    # Bloat-ratio bar
    $barWidth = 40
    $bloatFill = if ($Analysis.TotalRows -gt 0) { [Math]::Round(($Analysis.BloatRows / $Analysis.TotalRows) * $barWidth) } else { 0 }
    $relevantFill = $barWidth - $bloatFill
    $bar = ("R" * $relevantFill) + ("x" * $bloatFill)
    $output += "-" * 80
    $output += "Membership Row Composition:"
    $output += "-" * 80
    $output += ""
    $output += "  [$bar]"
    $output += "  R = Relevant ($pctRelevantRows%)    x = Bloat ($pctBloatRows%)"
    $output += ""
    $output += "=" * 80

    return $output -join "`r`n"
}

#===============================================================================
# Main Script
#===============================================================================
function Main {
    $cfg = $script:QSRConfig

    Write-Log -Level "INFO" -Message "Starting Qlik Sense Repository - User Group Memberships"
    Write-Log -Level "INFO" -Message "Detail Level: $DetailLevel"

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

    # ---- Determine mode and build output ----
    $outputSections = @()

    # Mode: FilterUser
    if ($FilterUser) {
        Write-Log -Level "INFO" -Message "Mode: FilterUser ($FilterUser)"
        $detail = Get-UserDetail -UserIdentifier $FilterUser
        if (-not $detail) {
            Write-Log -Level "ERROR" -Message "User not found: $FilterUser"
            exit 1
        }
        $outputSections += Format-UserDetail -UserDetail $detail
    }
    # Mode: FilterGroup
    elseif ($FilterGroup) {
        Write-Log -Level "INFO" -Message "Mode: FilterGroup ($FilterGroup)"
        $detail = Get-GroupDetail -GroupName $FilterGroup
        if (-not $detail) {
            Write-Log -Level "ERROR" -Message "Group not found or empty: $FilterGroup"
            exit 1
        }
        $outputSections += Format-GroupDetail -GroupDetail $detail
    }
    # Mode: ListUsers
    elseif ($ListUsers) {
        Write-Log -Level "INFO" -Message "Mode: ListUsers"
        $allUsers = Get-AllUsersWithGroupCounts
        if (-not $allUsers) {
            Write-Log -Level "WARN" -Message "No users found"
            $allUsers = @()
        }
        $outputSections += Format-UserList -Users $allUsers
    }
    # Mode: ListGroups
    elseif ($ListGroups) {
        Write-Log -Level "INFO" -Message "Mode: ListGroups"
        $allGroups = Get-AllGroupsWithUserCounts
        if (-not $allGroups) {
            Write-Log -Level "WARN" -Message "No groups found"
            $allGroups = @()
        }
        $outputSections += Format-GroupList -Groups $allGroups
    }
    # Default mode: Summary (with optional details)
    else {
        Write-Log -Level "INFO" -Message "Mode: Summary"
        $summary = Get-GroupMembershipSummary
        if (-not $summary) {
            Write-Log -Level "ERROR" -Message "Failed to retrieve group membership summary"
            exit 1
        }

        $topUsers = Get-TopUsersByGroupCount -TopN $TopN
        if (-not $topUsers) { $topUsers = @() }

        $topGroups = Get-TopGroupsByUserCount -TopN $TopN
        if (-not $topGroups) { $topGroups = @() }

        $distribution = Get-GroupCountDistribution
        if (-not $distribution) { $distribution = @() }

        $tableSizes = Get-TableSizeInfo
        if (-not $tableSizes) { $tableSizes = @() }

        $outputSections += Format-GroupMembershipSummary `
            -Summary $summary `
            -TopUsers $topUsers `
            -TopGroups $topGroups `
            -Distribution $distribution `
            -TableSizes $tableSizes `
            -TopN $TopN

        # Relevance analysis (if -RelevantGroups specified)
        # Normalize: split comma-separated values so 'admin,sense' becomes two patterns
        $normalizedPatterns = @($RelevantGroups | ForEach-Object { $_ -split ',' } | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
        if ($normalizedPatterns.Count -gt 0) {
            Write-Log -Level "INFO" -Message "Running relevance analysis"
            $allMembershipRows = Get-AllGroupMembershipRows
            if ($allMembershipRows -and $allMembershipRows.Count -gt 0) {
                $analysis = Get-RelevanceAnalysis `
                    -AllRows $allMembershipRows `
                    -Patterns $normalizedPatterns `
                    -TotalUsers $summary.TotalUsers
                $outputSections += Format-RelevanceAnalysis -Analysis $analysis
            } else {
                Write-Log -Level "WARN" -Message "No group membership rows found for relevance analysis"
            }
        }

        # If details mode, also show full user and group lists
        if ($DetailLevel -eq "details") {
            Write-Log -Level "INFO" -Message "Details mode: including full user and group lists"

            $allUsers = Get-AllUsersWithGroupCounts
            if (-not $allUsers) { $allUsers = @() }
            $outputSections += Format-UserList -Users $allUsers

            $allGroups = Get-AllGroupsWithUserCounts
            if (-not $allGroups) { $allGroups = @() }
            $outputSections += Format-GroupList -Groups $allGroups
        }
    }

    $fullOutput = $outputSections -join "`r`n"

    # Output to screen
    Write-Host $fullOutput

    # Export to file if specified
    if ($OutputFile) {
        if (-not ($OutputFile -match "\d{8}_\d{6}")) {
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $filenameWithTimestamp = "$timestamp-$OutputFile"
        } else {
            $filenameWithTimestamp = $OutputFile
        }

        Export-Output -Content $fullOutput -Filename $filenameWithTimestamp | Out-Null
    }

    Write-Log -Level "INFO" -Message "User Group Memberships report completed successfully"
    exit 0
}

# Run main function
Main
