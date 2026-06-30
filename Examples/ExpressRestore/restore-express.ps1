#Requires -Modules KeepitTools
#Requires -Modules PwshSpectreConsole
#Requires -Version 7.0

<#
.SYNOPSIS
    Interactive wizard for Start-KeepitExpressRestore.

.DESCRIPTION
    A guided, step-by-step prompt flow that collects parameters for
    Start-KeepitExpressRestore using PwshSpectreConsole, then previews
    (-WhatIf) and submits the restore operation.

    Steps:
      1. Select Connector
      2. Enter User (UPN validation via Convert-KeepitUPNToGuid)
      3. Configure Restore (timespan, start time, workload, options)
      4. Review & Confirm

.EXAMPLE
    ./restore-express.ps1
    ./restore-express.ps1 -Credential $cred -Environment 'us-dc'
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
# Connect and fetch connectors
# ===================================================================

$connectParams = @{}
if ($Credential)  { $connectParams['Credential']  = $Credential }
if ($Environment) { $connectParams['Environment'] = $Environment }

try {
    Connect-KeepitInteractive @connectParams | Out-Null
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

$connectors = Invoke-SpectreCommandWithStatus -Title 'Fetching connectors...' -Spinner 'Dots2' -ScriptBlock {
    @(Get-KeepitConnector -Type 'o365-admin' -ErrorAction Stop)
}

if ($connectors.Count -eq 0) {
    Write-SpectreHost '[red]No connectors found for this account.[/]'
    exit 1
}

Write-SpectreHost "[green]Found $($connectors.Count) connector(s).[/]"

# ===================================================================
# Step 1: Select Connector
# ===================================================================

Write-SpectreRule -Title 'Step 1: Select Connector' -Color 'Cyan1'

$connector = Select-Connector -Connectors $connectors
if (-not $connector) {
    Write-SpectreHost '[yellow]Cancelled.[/]'
    exit 0
}

Write-SpectreHost "  Selected: [green]$($connector.Name)[/]"

# ===================================================================
# Step 2: Enter User
# ===================================================================

Write-SpectreRule -Title 'Step 2: Enter User' -Color 'Cyan1'

$userResult = Read-UserPrincipalName -ConnectorGuid $connector.ConnectorGuid
if (-not $userResult) {
    Write-SpectreHost '[yellow]Cancelled.[/]'
    exit 0
}

# ===================================================================
# Step 3: Configure Restore
# ===================================================================

Write-SpectreRule -Title 'Step 3: Configure Restore' -Color 'Cyan1'

# --- Timespan selection ---
$TimespanPresets = @(
    [PSCustomObject]@{ Label = '1 day';   Duration = 'P1D'  }
    [PSCustomObject]@{ Label = '3 days';  Duration = 'P3D'  }
    [PSCustomObject]@{ Label = '7 days';  Duration = 'P7D'  }
    [PSCustomObject]@{ Label = '14 days'; Duration = 'P14D' }
    [PSCustomObject]@{ Label = '30 days'; Duration = 'P30D' }
    [PSCustomObject]@{ Label = 'Custom';  Duration = $null  }
)

$tsChoice = Read-SpectreSelection `
    -Message 'Restore items from the last' `
    -Choices $TimespanPresets `
    -ChoiceLabelProperty 'Label'
if (-not $tsChoice) {
    Write-SpectreHost '[yellow]Cancelled.[/]'
    exit 0
}

$resolvedTimespan = $null
$timespanDisplay = $tsChoice.Label

if (-not $tsChoice.Duration) {
    # Custom duration
    $customDuration = Read-SpectreText -Message 'Enter ISO 8601 duration (e.g. P3D, PT12H)'
    if ([string]::IsNullOrWhiteSpace($customDuration)) {
        Write-SpectreHost '[yellow]Cancelled.[/]'
        exit 0
    }

    $errMsg = $null
    $resolvedTimespan = ConvertTo-RestoreTimespan -Duration $customDuration -ErrorMessage ([ref]$errMsg)
    if (-not $resolvedTimespan) {
        Write-SpectreHost "[red]$errMsg[/]"
        exit 1
    }
    $timespanDisplay = "$customDuration ($resolvedTimespan)"
}
else {
    $resolvedTimespan = [System.Xml.XmlConvert]::ToTimeSpan($tsChoice.Duration)
}

# --- Start time ---
$startTime = $null
$useStartTime = Read-SpectreConfirm -Message 'Specify a custom start time? (default: now)' -DefaultAnswer 'n'
if ($useStartTime) {
    $startStr = Read-SpectreText -Message 'Start date (yyyy-MM-dd)'
    if (-not [string]::IsNullOrWhiteSpace($startStr)) {
        $parsed = [DateTime]::MinValue
        if ([DateTime]::TryParseExact($startStr, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$parsed)) {
            $startTime = $parsed
        }
        else {
            Write-SpectreHost '[red]Invalid date format. Using default (now).[/]'
        }
    }
}

# --- Options ---
$prioritizeCalendar = Read-SpectreConfirm -Message 'Prioritize Calendar items?' -DefaultAnswer 'n'
$inboxOnly = Read-SpectreConfirm -Message 'Inbox only?' -DefaultAnswer 'n'

# ===================================================================
# Step 4: Review & Confirm
# ===================================================================

Write-SpectreRule -Title 'Step 4: Review' -Color 'Cyan1'

Show-ReviewTable -Title 'Express Restore Configuration' -Rows @(
    @{ Label = 'Connector';         Value = "$($connector.Name) [$($connector.ConnectorGuid)]" }
    @{ Label = 'User';              Value = $userResult.UPN }
    @{ Label = 'Time window';       Value = $timespanDisplay }
    @{ Label = 'Starting from';     Value = if ($startTime) { $startTime.ToString('yyyy-MM-dd') } else { '(now)' } }
    @{ Label = 'Workload';          Value = 'Exchange' }
    @{ Label = 'Calendar priority'; Value = if ($prioritizeCalendar) { 'Yes' } else { 'No' } }
    @{ Label = 'Inbox only';        Value = if ($inboxOnly) { 'Yes' } else { 'No' } }
)

$proceed = Read-SpectreConfirm -Message 'Preview express restore?' -DefaultAnswer 'y'
if (-not $proceed) {
    Write-SpectreHost '[yellow]Cancelled.[/]'
    exit 0
}

# ===================================================================
# Preview
# ===================================================================

Write-SpectreRule -Title 'Express Restore Preview' -Color 'Yellow'

$restoreParams = @{
    Connector         = $connector.ConnectorGuid
    UserPrincipalName = $userResult.UPN
    Timespan          = $resolvedTimespan
    Workload          = 'Exchange'
    WhatIf            = $true
}
if ($startTime)          { $restoreParams['StartTime']          = $startTime }
if ($prioritizeCalendar) { $restoreParams['PrioritizeCalendar'] = $true }
if ($inboxOnly)          { $restoreParams['InboxOnly']          = $true }

Start-KeepitExpressRestore @restoreParams

# ===================================================================
# Submit
# ===================================================================

Write-Host ''
$confirm = Read-SpectreConfirm -Message 'Submit express restore?' -DefaultAnswer 'n'

if ($confirm) {
    $restoreParams.Remove('WhatIf')
    Write-SpectreHost '[yellow]Submitting express restore...[/]'
    Start-KeepitExpressRestore @restoreParams
    Write-SpectreHost '[green]Done.[/]'
}
else {
    Write-SpectreHost '[yellow]Restore cancelled.[/]'
}
