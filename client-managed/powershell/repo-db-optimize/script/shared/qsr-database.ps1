#===============================================================================
# QSR Shared Module: Database
#===============================================================================
# Provides the Invoke-PsqlQuery function used by all QSR database scripts.
# Reads connection parameters from $script:QSRConfig (DbHost, DbPort, DbName,
# DbUser, PsqlBin).
#
# Prerequisites:
#   - $script:QSRConfig must be initialized (via qsr-configuration.ps1)
#   - Write-Log must be available (via qsr-logging.ps1)
#
# Usage:
#   . "$PSScriptRoot/shared/qsr-database.ps1"
#   $rows = Invoke-PsqlQuery -Query "SELECT 1"
#
# Author: Ptarmigan Labs/Göran Sander
#===============================================================================

<#
.SYNOPSIS
    Executes a SQL query against PostgreSQL using the psql command-line tool.

.DESCRIPTION
    Invoke-PsqlQuery invokes psql with tuple-only (-t), unaligned (-A), and
    pipe-separated (-F '|') output. Connection parameters are read from
    $script:QSRConfig. The QSR_DB_PASSWORD environment variable (if set) is
    exported as PGPASSWORD for password authentication.

    On success the raw psql output (string or string[]) is returned.
    On failure $null is returned and an error is logged.

.PARAMETER Query
    The SQL query string to execute.

.PARAMETER SuppressOutput
    When set, suppresses the "Query executed successfully" debug log line.
    Useful for high-frequency calls (e.g. per-table COUNT loops).

.OUTPUTS
    [string] or [string[]] — raw psql output lines, or $null on error.

.EXAMPLE
    $result = Invoke-PsqlQuery -Query "SELECT COUNT(*) FROM public.\"Users\""
#>
function Invoke-PsqlQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [Parameter(Mandatory = $false)]
        [switch]$SuppressOutput = $false
    )

    # Read connection settings from shared config
    $cfg = $script:QSRConfig
    $psqlBin  = $cfg.PsqlBin
    $dbHost   = $cfg.DbHost
    $dbPort   = $cfg.DbPort
    $dbName   = $cfg.DbName
    $dbUser   = $cfg.DbUser

    # Build psql arguments — query is piped via stdin to avoid Windows
    # PowerShell 5.1 stripping double-quotes from -c arguments, which
    # breaks case-sensitive PostgreSQL table names like public."Users".
    $psqlArgs = @(
        "-h", $dbHost,
        "-p", $dbPort,
        "-d", $dbName,
        "-U", $dbUser,
        "-t",       # Tuple-only output (no headers)
        "-A",       # Unaligned output (no padding)
        "-F", "|"   # Pipe field separator
    )

    # Export password for psql if configured
    $env:PGPASSWORD = $env:QSR_DB_PASSWORD

    $pwdSet = if ($env:PGPASSWORD) { 'yes' } else { 'no' }
    Write-Log -Level "DEBUG" -Message "Invoking psql: $psqlBin with args: $($psqlArgs -join ' ') (PGPASSWORD set: $pwdSet)"

    try {
        $output = $Query | & $psqlBin @psqlArgs 2>&1
        $script:LASTEXITCODE = $LASTEXITCODE

        $outPreview = ""
        if ($output) {
            if ($output -is [array]) { $outPreview = ($output | Select-Object -First 10) -join "|" } else { $outPreview = $output }
        }

        Write-Log -Level "DEBUG" -Message "psql returned exit=$script:LASTEXITCODE outputPreview='$outPreview'"

        if ($script:LASTEXITCODE -ne 0) {
            Write-Log -Level "ERROR" -Message "psql command failed with exit code $script:LASTEXITCODE"
            Write-Log -Level "ERROR" -Message "Error output: $outPreview"
            return $null
        }

        if (-not $SuppressOutput) {
            Write-Log -Level "DEBUG" -Message "Query executed successfully"
        }

        return $output
    } catch {
        Write-Log -Level "ERROR" -Message "Exception executing query: $_"
        return $null
    }
}
