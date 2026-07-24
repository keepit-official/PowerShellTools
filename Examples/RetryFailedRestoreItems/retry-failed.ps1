#Requires -Modules KeepitTools
#Requires -Modules PwshSpectreConsole
#Requires -Version 7.0

<#
.SYNOPSIS
    Interactive wizard for Restore-KeepitFailedItems.

.DESCRIPTION
    A guided, step-by-step prompt flow that retries the items which failed in a
    previous Keepit restore job. The failed job can be picked from recent restore
    history, or supplied as a Job Report CSV exported from the admin center. The
    wizard previews the retry with -WhatIf and only submits after confirmation.

    Steps:
      1. Choose the retry source (recent restore job, or a Job Report CSV)
      2. (job source) Select Connector, then Select the failed restore job
      3. Optionally filter by failure cause (e.g. CODE:507)
      4. Review, preview (-WhatIf), and confirm

.EXAMPLE
    ./retry-failed.ps1
    ./retry-failed.ps1 -Credential $cred -Environment 'us-dc'
#>

param(
    [PSCredential]$Credential,

    [ValidateSet(
        'ws.keepit', 'au-sy', 'ca-tr', 'dk-co', 'de-fr', 'uk-ld', 'us-dc', 'ch-zh',
        'ws-test', 'ws-test-b', 'ws-test-c', 'staging', 'dev'
    )]
    [string]$Environment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source shared helpers
. (Join-Path $PSScriptRoot 'restore-helpers.ps1')

# ===================================================================
# Connect
# ===================================================================

$connectParams = @{}
if ($Credential)  { $connectParams['Credential']  = $Credential }
if ($Environment) { $connectParams['Environment'] = $Environment }

try {
    $envName = Connect-KeepitInteractive @connectParams
    Write-SpectreHost "[green]Connected to $envName.[/]"
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

# Parameters accumulate here; preview always runs with -WhatIf first.
$retryParams = @{ WhatIf = $true }

# ===================================================================
# Step 1: Choose retry source
# ===================================================================

Write-SpectreRule -Title 'Step 1: Choose Retry Source' -Color 'Cyan1'

$source = Read-SpectreSelection `
    -Message 'How do you want to identify the failed restore?' `
    -Choices @('Select a recent restore job', 'Use a Job Report CSV file')

if ($source -eq 'Use a Job Report CSV file') {
    $csvPath = Read-SpectreText -Message 'Path to the Job Report CSV'
    if ([string]::IsNullOrWhiteSpace($csvPath)) {
        Write-SpectreHost '[yellow]Cancelled.[/]'
        exit 0
    }
    if (-not (Test-Path -LiteralPath $csvPath)) {
        Write-SpectreHost "[red]File not found: $csvPath[/]"
        exit 1
    }
    $retryParams['ReportPath'] = $csvPath
    $sourceLabel = "CSV: $csvPath"
}
else {
    # --- Select connector ---
    Write-SpectreRule -Title 'Step 2: Select Connector' -Color 'Cyan1'

    $connectors = Invoke-SpectreCommandWithStatus -Title 'Fetching connectors...' -Spinner 'Dots2' -ScriptBlock {
        @(Get-KeepitConnector -Type 'o365-admin' -ErrorAction Stop)
    }
    if ($connectors.Count -eq 0) {
        Write-SpectreHost '[red]No connectors found for this account.[/]'
        exit 1
    }

    $connector = Select-Connector -Connectors $connectors
    if (-not $connector) {
        Write-SpectreHost '[yellow]Cancelled.[/]'
        exit 0
    }
    Write-SpectreHost "  Selected: [green]$($connector.Name)[/]"

    # --- Select the failed restore job ---
    Write-SpectreRule -Title 'Step 3: Select Restore Job' -Color 'Cyan1'

    $job = Select-RestoreJob -ConnectorGuid $connector.ConnectorGuid
    if (-not $job) {
        Write-SpectreHost '[yellow]Cancelled.[/]'
        exit 0
    }

    $retryParams['Connector'] = $connector.ConnectorGuid
    $retryParams['JobGuid']   = $job.JobGuid
    $sourceLabel = "$($connector.Name) / job $($job.JobGuid)"
}

# ===================================================================
# Step: Optional cause filter
# ===================================================================

$causeLabel = '(all causes)'
if (Read-SpectreConfirm -Message 'Filter by a specific failure cause?' -DefaultAnswer 'n') {
    $cause = Read-SpectreText -Message 'Cause to include (e.g. CODE:507)'
    if (-not [string]::IsNullOrWhiteSpace($cause)) {
        $retryParams['IncludeCause'] = $cause
        $causeLabel = $cause
    }
}

# ===================================================================
# Review
# ===================================================================

Write-SpectreRule -Title 'Review' -Color 'Cyan1'

Show-ReviewTable -Title 'Retry Failed Items' -Rows @(
    @{ Label = 'Source';       Value = $sourceLabel }
    @{ Label = 'Cause filter'; Value = $causeLabel }
)

if (-not (Read-SpectreConfirm -Message 'Preview the retry?' -DefaultAnswer 'y')) {
    Write-SpectreHost '[yellow]Cancelled.[/]'
    exit 0
}

# ===================================================================
# Preview (-WhatIf)
# ===================================================================

Write-SpectreRule -Title 'Retry Preview (-WhatIf)' -Color 'Yellow'

$preview = Restore-KeepitFailedItems @retryParams

if (-not $preview -or -not $preview.TotalItems -or $preview.TotalItems -eq 0) {
    Write-SpectreHost '[yellow]No failed items to retry for this job.[/]'
    exit 0
}

Write-SpectreHost "[green]$($preview.TotalItems) item(s) would be retried in $($preview.JobCount) job(s) from snapshot $($preview.SnapshotId).[/]"
if ($preview.Unmapped -gt 0) {
    Write-SpectreHost "[yellow]$($preview.Unmapped) item(s) could not be mapped to a restore path and will be skipped.[/]"
}

# ===================================================================
# Submit
# ===================================================================

Write-Host ''
if (Read-SpectreConfirm -Message 'Submit the retry restore job?' -DefaultAnswer 'n') {
    $retryParams.Remove('WhatIf')
    Write-SpectreHost '[yellow]Submitting retry...[/]'
    $results = Restore-KeepitFailedItems @retryParams -Confirm:$false
    $results | Format-SpectreTable -Property JobGuid, ItemCount, Status, SnapshotId -Border Rounded -Color 'Green'
    Write-SpectreHost '[green]Done.[/]'
}
else {
    Write-SpectreHost '[yellow]Retry cancelled.[/]'
}
