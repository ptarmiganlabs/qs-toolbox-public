#===============================================================================
# QSR Shared Module: Validation
#===============================================================================
# Provides reusable validation functions for QSR database scripts:
#   - Test-CommandExists    — check if a command/binary is available
#   - Test-DatabaseConnection — verify psql can connect to the database
#   - Test-PostgreSQLVersion  — check the PostgreSQL server version
#
# Prerequisites:
#   - $script:QSRConfig must be initialized (via qsr-configuration.ps1)
#   - Write-Log must be available (via qsr-logging.ps1)
#   - Invoke-PsqlQuery must be available (via qsr-database.ps1)
#
# Author: Ptarmigan Labs/Göran Sander
#===============================================================================

<#
.SYNOPSIS
    Tests whether a command or binary exists and is callable.

.DESCRIPTION
    Uses Get-Command to check if the specified command is available in the
    current session. Returns $true if found, $false otherwise.

.PARAMETER command
    The command name or path to test.

.OUTPUTS
    [bool]

.EXAMPLE
    if (-not (Test-CommandExists "psql")) { exit 1 }
#>
function Test-CommandExists {
    param($command)
    try {
        if (Get-Command $command -ErrorAction Stop) {
            return $true
        }
    } catch {
        return $false
    }
    return $false
}

<#
.SYNOPSIS
    Verifies that psql can connect to the configured PostgreSQL database.

.DESCRIPTION
    Runs "SELECT 1" via Invoke-PsqlQuery. Returns $true on success, $false on failure.
    When StepDebug is enabled in $script:QSRConfig and StopAfter is 'connection',
    the function prints diagnostic output and exits the process.

.OUTPUTS
    [bool]

.EXAMPLE
    if (-not (Test-DatabaseConnection)) { exit 1 }
#>
function Test-DatabaseConnection {
    $cfg = $script:QSRConfig
    Write-Log -Level "INFO" -Message "Testing database connection to $($cfg.DbHost):$($cfg.DbPort)/$($cfg.DbName)"

    $query = "SELECT 1"
    $result = Invoke-PsqlQuery -Query $query

    $exit = $script:LASTEXITCODE
    $resultText = ""
    if ($result) {
        if ($result -is [array]) { $resultText = ($result -join "`n").Trim() } else { $resultText = $result.ToString().Trim() }
    }

    Write-Log -Level "DEBUG" -Message "psql exit code: $exit; output: $resultText"

    if ($exit -eq 0 -and ($resultText -eq "1" -or $resultText -match "\b1\b")) {
        Write-Log -Level "INFO" -Message "Database connection successful"
        if ($cfg.StepDebug -and (-not $cfg.StopAfter -or $cfg.StopAfter -eq 'connection')) {
            Write-Log -Level "INFO" -Message "StepDebug: raw psql output for connection: '$resultText'"
            Write-Log -Level "INFO" -Message "StepDebug: exiting after successful connection (exit=0)"
            exit 0
        }
        return $true
    } else {
        Write-Log -Level "ERROR" -Message "Database connection failed (exit=$exit)"
        if ($cfg.StepDebug -and (-not $cfg.StopAfter -or $cfg.StopAfter -eq 'connection')) {
            Write-Log -Level "INFO" -Message "StepDebug: raw psql output for failed connection: '$resultText'"
            Write-Log -Level "INFO" -Message "StepDebug: exiting after failed connection"
            exit 1
        }
        return $false
    }
}

<#
.SYNOPSIS
    Checks the PostgreSQL server version and warns if below minimum.

.DESCRIPTION
    Runs "SELECT version();" and parses the major.minor version number.
    Returns $true if the version is 8.0 or higher (or if it cannot be determined).
    When StepDebug is enabled and StopAfter is 'version', prints diagnostics and exits.

.OUTPUTS
    [bool]

.EXAMPLE
    Test-PostgreSQLVersion | Out-Null
#>
function Test-PostgreSQLVersion {
    Write-Log -Level "INFO" -Message "Checking PostgreSQL version"
    $cfg = $script:QSRConfig

    $query = "SELECT version();"
    $result = Invoke-PsqlQuery -Query $query

    if ($LASTEXITCODE -eq 0) {
        # Extract version number (e.g., "14.5" from "PostgreSQL 14.5")
        $versionMatch = $result | Select-String -Pattern "PostgreSQL\s+(\d+\.\d+)"
        if ($versionMatch) {
            $version = $versionMatch.Matches.Groups[1].Value
            Write-Log -Level "INFO" -Message "PostgreSQL version: $version"

            $versionNum = [version]$version
            $minVersion = [version]"8.0.0"

            if ($versionNum -ge $minVersion) {
                Write-Log -Level "INFO" -Message "PostgreSQL version is compatible"
                if ($cfg.StepDebug -and (-not $cfg.StopAfter -or $cfg.StopAfter -eq 'version')) {
                    Write-Log -Level "INFO" -Message "StepDebug: raw version output: '$result'"
                    Write-Log -Level "INFO" -Message "StepDebug: exiting after version check"
                    exit 0
                }
                return $true
            } else {
                Write-Log -Level "WARN" -Message "PostgreSQL version $version is below minimum recommended version 8.0"
                if ($cfg.StepDebug -and (-not $cfg.StopAfter -or $cfg.StopAfter -eq 'version')) {
                    Write-Log -Level "INFO" -Message "StepDebug: raw version output: '$result'"
                    Write-Log -Level "INFO" -Message "StepDebug: exiting after version check (warn)"
                    exit 0
                }
                return $true  # Continue but warn
            }
        }
    }

    Write-Log -Level "WARN" -Message "Could not determine PostgreSQL version"
    return $true  # Continue but warn
}
