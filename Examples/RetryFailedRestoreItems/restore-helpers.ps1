#Requires -Version 7.0

<#
.SYNOPSIS
    Shared helper functions for the retry-failed wizard.

.DESCRIPTION
    Provides interactive connection, connector selection, restore-job selection,
    and a review-table helper used by retry-failed.ps1. Uses PwshSpectreConsole
    for all interactive prompts. Mirrors the helpers used by the other restore
    wizards (restore-bulk.ps1, restore-express.ps1).
#>

# ---------------------------------------------------------------------------
# Connect-KeepitInteractive
# ---------------------------------------------------------------------------

function Connect-KeepitInteractive {
    <#
    .SYNOPSIS
        Establishes a KeepitTools session, prompting for credentials and
        auto-discovering the environment when not supplied.

    .OUTPUTS
        [string] The resolved environment name (e.g. 'us-dc').
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [PSCredential]$Credential,

        [ValidateSet(
            'ws.keepit', 'au-sy', 'ca-tr', 'dk-co', 'de-fr', 'uk-ld', 'us-dc', 'ch-zh',
            'ws-test', 'ws-test-b', 'ws-test-c', 'staging', 'dev'
        )]
        [string]$Environment
    )

    if (-not $Credential) {
        Write-Host 'Please enter your Keepit credentials...' -ForegroundColor Cyan
        $Credential = Get-Credential
        if (-not $Credential) { throw 'No credential supplied.' }
    }

    if ($Environment) {
        Write-Host "Connecting to specified environment: $Environment" -ForegroundColor Yellow
        try {
            Connect-KeepitService -Credential $Credential -Environment $Environment -ErrorAction Stop | Out-Null
            Write-Host "  Successfully connected to: $Environment" -ForegroundColor Green
            return $Environment
        }
        catch {
            throw "Failed to connect to ${Environment}: $($_.Exception.Message)"
        }
    }

    # Auto-discover across production data centres
    $ProductionDCs = @('us-dc', 'de-fr', 'dk-co', 'ca-tr', 'ch-zh', 'au-sy', 'uk-ld')
    Write-Host 'Auto-discovering environment...' -ForegroundColor Yellow

    foreach ($dc in $ProductionDCs) {
        try {
            Connect-KeepitService -Credential $Credential -Environment $dc -ErrorAction Stop | Out-Null
            Write-Host "  Found account in: $dc" -ForegroundColor Green
            return $dc
        }
        catch { continue }
    }

    throw 'Account not found in any production environment.'
}

# ---------------------------------------------------------------------------
# Select-Connector
# ---------------------------------------------------------------------------

function Select-Connector {
    <#
    .SYNOPSIS
        Prompts the user to select a connector from a searchable list.

    .PARAMETER Connectors
        Array of connector objects from Get-KeepitConnector.

    .OUTPUTS
        The selected connector object, or $null if cancelled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Connectors
    )

    $selected = Read-SpectreSelection `
        -Message 'Select a connector' `
        -Choices $Connectors `
        -ChoiceLabelProperty {
            $name = ($_.Name -replace '\[', '[[') -replace '\]', ']]'
            "$name ($($_.TypeDisplayName)) [[$($_.ConnectorGuid)]]"
        } `
        -EnableSearch `
        -PageSize 15

    return $selected
}

# ---------------------------------------------------------------------------
# Select-RestoreJob
# ---------------------------------------------------------------------------

function Select-RestoreJob {
    <#
    .SYNOPSIS
        Lists recent restore jobs on a connector and prompts the user to pick one.

    .DESCRIPTION
        Uses Get-KeepitJobHistory (the PUT /jobs history filter) to fetch jobs in
        the last -DaysBack days and keeps the restore-type ones (restore and
        srestore). Unlike the GET-based Get-KeepitJobs, the history filter reliably
        reaches back the full window. Get-KeepitJobHistory surfaces per-job status,
        so jobs that failed are marked and listed first (they are the retry
        candidates); Restore-KeepitFailedItems still confirms the actual failed
        items for the chosen job.

    .PARAMETER ConnectorGuid
        GUID of the connector whose jobs to list.

    .PARAMETER DaysBack
        How many days of history to search. Defaults to 30 (Keepit retains the
        skipped-items log about 30 days, so older jobs cannot be retried anyway).

    .OUTPUTS
        The selected job object (with a JobGuid property), or $null if none / cancelled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConnectorGuid,

        [int]$DaysBack = 30
    )

    $jobs = Invoke-SpectreCommandWithStatus -Title 'Fetching recent restore jobs...' -Spinner 'Dots2' -ScriptBlock {
        @(Get-KeepitJobHistory -Connector $ConnectorGuid `
                -StartTime ([DateTime]::Today.AddDays(-$DaysBack)) `
                -EndTime ([DateTime]::Now) -FailReason -ErrorAction Stop) |
            Where-Object { $_.Type -in @('restore', 'srestore') } |
            Sort-Object `
                @{ Expression = { [bool]$_.Failed }; Descending = $true }, `
                @{ Expression = { if ($_.Start) { [datetime]$_.Start } else { [datetime]::MinValue } }; Descending = $true }
    }

    if (-not $jobs -or $jobs.Count -eq 0) {
        Write-SpectreHost "[yellow]No restore jobs found in the last $DaysBack day(s).[/]"
        return $null
    }

    $selected = Read-SpectreSelection `
        -Message 'Select a restore job to retry' `
        -Choices $jobs `
        -ChoiceLabelProperty {
            # Escape square brackets: Spectre reads [..] as markup, and restore
            # descriptions (and fail reasons) contain tags/underscores we show literally.
            $desc = ($_.Description -replace '\[', '[[') -replace '\]', ']]'
            $tag  = if ($_.Failed) {
                if ($_.FailReason) {
                    $reason = ($_.FailReason -replace '\[', '[[') -replace '\]', ']]'
                    "[[failed: $reason]] "
                }
                else { '[[failed]] ' }
            }
            else { '' }
            "$tag$($_.Start)  $desc [[$($_.JobGuid)]]"
        } `
        -EnableSearch `
        -PageSize 15

    return $selected
}

# ---------------------------------------------------------------------------
# Show-ReviewTable
# ---------------------------------------------------------------------------

function Show-ReviewTable {
    <#
    .SYNOPSIS
        Displays a review summary as a formatted Spectre table.

    .PARAMETER Rows
        Array of hashtables with Label and Value keys.

    .PARAMETER Title
        Title for the table panel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable[]]$Rows,

        [string]$Title = 'Configuration'
    )

    $data = $Rows | ForEach-Object {
        [PSCustomObject]@{ Setting = $_.Label; Value = $_.Value }
    }

    $data | Format-SpectreTable `
        -Property Setting, Value `
        -Border Rounded `
        -Color 'Cyan1' `
        -Title $Title
}
