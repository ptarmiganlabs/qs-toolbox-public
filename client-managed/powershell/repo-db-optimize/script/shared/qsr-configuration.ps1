#===============================================================================
# QSR Shared Module: Configuration
#===============================================================================
# Provides centralized configuration initialization for all QSR database scripts.
# Call Initialize-QSRConfiguration at script startup to populate $script:QSRConfig.
#
# All settings follow the priority: parameter value > environment variable > default.
#
# Usage:
#   . "$PSScriptRoot/shared/qsr-configuration.ps1"
#   $script:QSRConfig = Initialize-QSRConfiguration -DbHost $DB_HOST -DbPort $DB_PORT ...
#
# Author: Ptarmigan Labs/Göran Sander
#===============================================================================

<#
.SYNOPSIS
    Initializes a QSR configuration hashtable from parameters, environment variables, and defaults.

.DESCRIPTION
    Initialize-QSRConfiguration builds a standardized configuration hashtable used by all
    shared QSR modules (logging, database, validation, output). Each setting is resolved
    with the following priority:

        1. Explicit parameter value (if non-empty)
        2. Corresponding QSR_* environment variable
        3. Built-in default

    The returned hashtable is typically stored in $script:QSRConfig so that shared
    functions (Write-Log, Invoke-PsqlQuery, etc.) can reference it.

.PARAMETER DbHost
    PostgreSQL host. Env var: QSR_DB_HOST. Default: localhost

.PARAMETER DbPort
    PostgreSQL port. Env var: QSR_DB_PORT. Default: 4432

.PARAMETER DbName
    Repository database name. Env var: QSR_DB_NAME. Default: QSR

.PARAMETER DbUser
    Database user. Env var: QSR_DB_USER. Default: postgres

.PARAMETER PsqlBin
    Path to the psql binary. Env var: QSR_PSQL_BIN_PATH. Default: psql

.PARAMETER OutputDirectory
    Directory for file export. Env var: QSR_OUTPUT_DIRECTORY. Default: .

.PARAMETER LogLevel
    Logging verbosity: DEBUG, INFO, WARN, ERROR. Env var: QSR_LOG_LEVEL. Default: INFO

.PARAMETER StepDebug
    Enable stepwise debug mode (prints intermediate outputs and can exit early).

.PARAMETER StopAfter
    When StepDebug is enabled, stop execution after this stage. Valid values are
    script-specific but the configuration carries the value for shared functions.

.OUTPUTS
    [hashtable] — Keys: DbHost, DbPort, DbName, DbUser, PsqlBin, OutputDirectory,
                  LogLevel, StepDebug, StopAfter

.EXAMPLE
    $script:QSRConfig = Initialize-QSRConfiguration -DbHost "server1" -LogLevel "DEBUG"
#>
function Initialize-QSRConfiguration {
    param(
        [string]$DbHost,
        [string]$DbPort,
        [string]$DbName,
        [string]$DbUser,
        [string]$PsqlBin,
        [string]$OutputDirectory,
        [string]$LogLevel,
        [switch]$StepDebug,
        [string]$StopAfter
    )

    # Helper: resolve value with priority param > env var > default
    function Resolve-Setting {
        param([string]$ParamValue, [string]$EnvVarName, [string]$Default)
        if ($ParamValue) { return $ParamValue }
        $envVal = [System.Environment]::GetEnvironmentVariable($EnvVarName)
        if ($envVal) { return $envVal }
        return $Default
    }

    return @{
        DbHost          = Resolve-Setting -ParamValue $DbHost          -EnvVarName 'QSR_DB_HOST'          -Default 'localhost'
        DbPort          = Resolve-Setting -ParamValue $DbPort          -EnvVarName 'QSR_DB_PORT'          -Default '4432'
        DbName          = Resolve-Setting -ParamValue $DbName          -EnvVarName 'QSR_DB_NAME'          -Default 'QSR'
        DbUser          = Resolve-Setting -ParamValue $DbUser          -EnvVarName 'QSR_DB_USER'          -Default 'postgres'
        PsqlBin         = Resolve-Setting -ParamValue $PsqlBin         -EnvVarName 'QSR_PSQL_BIN_PATH'    -Default 'psql'
        OutputDirectory = Resolve-Setting -ParamValue $OutputDirectory -EnvVarName 'QSR_OUTPUT_DIRECTORY'  -Default '.'
        LogLevel        = Resolve-Setting -ParamValue $LogLevel        -EnvVarName 'QSR_LOG_LEVEL'         -Default 'INFO'
        StepDebug       = [bool]$StepDebug
        StopAfter       = if ($StopAfter) { $StopAfter } else { '' }
    }
}
