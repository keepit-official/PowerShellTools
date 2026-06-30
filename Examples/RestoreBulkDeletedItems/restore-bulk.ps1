#Requires -Modules KeepitTools
#Requires -Modules PwshSpectreConsole
#Requires -Version 7.0

<#
.SYNOPSIS
    Interactive wizard for Restore-KeepitBulkDeletedItems.

.DESCRIPTION
    A guided, step-by-step prompt flow that collects parameters for
    Restore-KeepitBulkDeletedItems using PwshSpectreConsole, then
    previews (-WhatIf) and submits the restore operation.

    Steps:
      1. Select Connector
      2. Enter User (UPN validation via Convert-KeepitUPNToGuid)
      3. Configure Search (date range, folder, type, recursive)
      4. Review & Confirm

.EXAMPLE
    ./restore-bulk.ps1
    ./restore-bulk.ps1 -Credential $cred -Environment 'us-dc'
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
# Step 3: Configure Search
# ===================================================================

Write-SpectreRule -Title 'Step 3: Configure Search' -Color 'Cyan1'

$dateRange = Read-DateRange
if (-not $dateRange) {
    Write-SpectreHost '[yellow]Cancelled.[/]'
    exit 0
}

$rootPath = Read-SpectreText -Message 'Folder path' -DefaultAnswer 'Inbox'
if ($null -eq $rootPath) {
    Write-SpectreHost '[yellow]Cancelled.[/]'
    exit 0
}

$itemType = Read-SpectreSelection `
    -Message 'Item type' `
    -Choices @('email', 'user', 'OneDrive')
if (-not $itemType) {
    Write-SpectreHost '[yellow]Cancelled.[/]'
    exit 0
}

$recursive = Read-SpectreConfirm -Message 'Recursive search?' -DefaultAnswer 'n'

# ===================================================================
# Step 4: Review & Confirm
# ===================================================================

Write-SpectreRule -Title 'Step 4: Review' -Color 'Cyan1'

Show-ReviewTable -Title 'Bulk Restore Configuration' -Rows @(
    @{ Label = 'Connector';  Value = "$($connector.Name) [$($connector.ConnectorGuid)]" }
    @{ Label = 'User';       Value = $userResult.UPN }
    @{ Label = 'Date range'; Value = "$($dateRange.StartDate.ToString('yyyy-MM-dd')) to $($dateRange.EndDate.ToString('yyyy-MM-dd'))" }
    @{ Label = 'Folder';     Value = $rootPath }
    @{ Label = 'Type';       Value = $itemType }
    @{ Label = 'Recursive';  Value = if ($recursive) { 'Yes' } else { 'No' } }
)

$proceed = Read-SpectreConfirm -Message 'Preview restore jobs?' -DefaultAnswer 'y'
if (-not $proceed) {
    Write-SpectreHost '[yellow]Cancelled.[/]'
    exit 0
}

# ===================================================================
# Preview
# ===================================================================

Write-SpectreRule -Title 'Restore Preview' -Color 'Yellow'

$restoreParams = @{
    Connector         = $connector.ConnectorGuid
    UserPrincipalName = $userResult.UPN
    RootPath          = $rootPath
    StartTime         = $dateRange.StartDate
    EndTime           = $dateRange.EndDate
    Type              = $itemType
    WhatIf            = $true
}
if ($recursive) { $restoreParams['Recursive'] = $true }

$previewResults = Restore-KeepitBulkDeletedItems @restoreParams

if (-not $previewResults) {
    Write-SpectreHost '[yellow]No items to restore.[/]'
    exit 0
}

# ===================================================================
# Submit
# ===================================================================

Write-Host ''
$confirm = Read-SpectreConfirm -Message 'Submit restore jobs?' -DefaultAnswer 'n'

if ($confirm) {
    $restoreParams.Remove('WhatIf')
    Write-SpectreHost '[yellow]Submitting restore jobs...[/]'
    Restore-KeepitBulkDeletedItems @restoreParams
    Write-SpectreHost '[green]Done.[/]'
}
else {
    Write-SpectreHost '[yellow]Restore cancelled.[/]'
}
