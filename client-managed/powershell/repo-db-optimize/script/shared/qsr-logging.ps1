#===============================================================================
# QSR Shared Module: Logging
#===============================================================================
# Provides the Write-Log function used by all QSR database scripts.
# Reads the current log level from $script:QSRConfig.LogLevel.
#
# Prerequisite: $script:QSRConfig must be initialized before calling Write-Log.
#
# Usage:
#   . "$PSScriptRoot/shared/qsr-logging.ps1"
#   Write-Log -Level "INFO" -Message "Hello"
#
# Author: Ptarmigan Labs/Göran Sander
#===============================================================================

<#
.SYNOPSIS
    Writes a timestamped, color-coded log message to the console.

.DESCRIPTION
    Write-Log outputs messages in the format:
        [yyyy-MM-dd HH:mm:ss.fff] [LEVEL  ] Message

    Messages below the configured log level ($script:QSRConfig.LogLevel) are suppressed.
    Colors are mapped per level: DEBUG=Gray, INFO=White, WARN=Yellow, ERROR=Red.
    An explicit -ForegroundColor overrides the default color for that level.

.PARAMETER Level
    Severity level of the message. Must be one of: DEBUG, INFO, WARN, ERROR.

.PARAMETER Message
    The text to log.

.PARAMETER ForegroundColor
    Optional override for the console color. When not specified (or "White"),
    the color is determined by the Level parameter.

.EXAMPLE
    Write-Log -Level "INFO" -Message "Database connection successful"

.EXAMPLE
    Write-Log -Level "ERROR" -Message "Query failed" -ForegroundColor "Magenta"
#>
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR")]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$ForegroundColor = "White"
    )

    # Map level names to numeric severity for comparison
    $levelOrder = @{ "DEBUG" = 0; "INFO" = 1; "WARN" = 2; "ERROR" = 3 }

    # Read configured log level from shared config; fall back to INFO
    $configuredLevel = if ($script:QSRConfig -and $script:QSRConfig.LogLevel) {
        $script:QSRConfig.LogLevel
    } else {
        "INFO"
    }

    # Suppress messages below the configured threshold
    if ($levelOrder[$Level] -lt $levelOrder[$configuredLevel]) {
        return
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $levelPadded = $Level.PadRight(7)

    # Default color per level
    $colorMap = @{
        "DEBUG" = "Gray"
        "INFO"  = "White"
        "WARN"  = "Yellow"
        "ERROR" = "Red"
    }

    $color = $colorMap[$Level]
    if ($ForegroundColor -ne "White") {
        $color = $ForegroundColor
    }

    Write-Host "[$timestamp] [$levelPadded] $Message" -ForegroundColor $color
}
