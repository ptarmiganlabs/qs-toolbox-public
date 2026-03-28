#===============================================================================
# QSR Shared Module: Output
#===============================================================================
# Provides the Export-Output function for writing report content to disk.
# Reads the output directory from $script:QSRConfig.OutputDirectory.
#
# Prerequisites:
#   - $script:QSRConfig must be initialized (via qsr-configuration.ps1)
#   - Write-Log must be available (via qsr-logging.ps1)
#
# Author: Ptarmigan Labs/Göran Sander
#===============================================================================

<#
.SYNOPSIS
    Writes report content to a UTF-8 file in the configured output directory.

.DESCRIPTION
    Export-Output joins the output directory from $script:QSRConfig.OutputDirectory
    with the supplied filename and writes the content as UTF-8 text. Returns $true
    on success or $false on failure.

.PARAMETER Content
    The full text content to write.

.PARAMETER Filename
    The filename (not path) to create inside the output directory.

.OUTPUTS
    [bool]

.EXAMPLE
    Export-Output -Content $reportText -Filename "20260328_120000-report.txt"
#>
function Export-Output {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$Filename
    )

    $outputDir = if ($script:QSRConfig -and $script:QSRConfig.OutputDirectory) {
        $script:QSRConfig.OutputDirectory
    } else {
        "."
    }

    $filepath = Join-Path -Path $outputDir -ChildPath $Filename

    try {
        $Content | Out-File -FilePath $filepath -Encoding UTF8 -Width 200
        Write-Log -Level "INFO" -Message "Output exported to: $filepath"
        return $true
    } catch {
        Write-Log -Level "ERROR" -Message "Failed to export output: $_"
        return $false
    }
}
