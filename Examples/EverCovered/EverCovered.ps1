<#
.SYNOPSIS
    Reports all mailbox users that have ever been backed up on a Keepit connector.
.DESCRIPTION
    Searches an o365-admin connector for every user who has ever had
    Exchange/Outlook data backed up. Output is a CSV file containing the user
    GUID and the most recent backup timestamp on which they were seen.

    The script performs two BSearch API calls:
      1. Search for active   Outlook folders directly under /Users/ (recursive).
      2. Search for deleted  Outlook folders directly under /Users/ (recursive).
    A user is included when an Outlook folder appears in either result set.
    LastSeenDate is the Updated timestamp of the most recent Outlook folder
    entry found for that user (i.e. the last backup in which they appeared).
.PARAMETER Credential
    Optional PSCredential for authenticating to the Keepit service.
    If omitted, the script prompts for a username and password.
.PARAMETER Environment
    Required. The Keepit datacenter region to connect to.
    Valid values: ws.keepit, au-sy, ca-tr, dk-co, de-fr, uk-ld, us-dc, ch-zh,
                  ws-test, ws-test-b, ws-test-c, staging, dev.
.PARAMETER Connector
    Optional. The name or GUID of an o365-admin connector to report on.
    If omitted, the script lists available connectors and prompts for a selection.
.PARAMETER OutputPath
    Optional. Full path for the CSV output file.
    If omitted, defaults to EverCovered-<ConnectorName>-<yyyy-MM-dd>.csv in the
    current working directory.
.EXAMPLE
    .\EverCovered.ps1 -Environment us-dc

    Prompts for credentials and connector selection, then generates a CSV in the
    current directory.
.EXAMPLE
    $cred = Get-Credential
    .\EverCovered.ps1 -Environment us-dc -Connector "Production M365" `
        -Credential $cred -OutputPath C:\Reports\ever-covered.csv

    Runs non-interactively with all parameters supplied.
.OUTPUTS
    CSV file with columns:
        - UserGUID     : The Keepit internal GUID for the user (path-masked format)
        - UserUPN      : The User Principal Name resolved from the GUID (blank if
                         resolution fails for an individual user)
        - LastSeenDate : The Updated timestamp of the most recent Outlook folder
                         entry for this user (last backup in which they appeared)
.NOTES
    Requires the KeepitTools module at ../../src/KeepitTools.psd1 (repository layout)
    or installed in the PowerShell module path.

    Requires PowerShell 7+.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $true)]
    [ValidateSet('ws.keepit', 'au-sy', 'ca-tr', 'dk-co', 'de-fr', 'uk-ld', 'us-dc', 'ch-zh',
                 'ws-test', 'ws-test-b', 'ws-test-c', 'staging', 'dev')]
    [string]$Environment,

    [Parameter(Mandatory = $false)]
    [string]$Connector,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

if (-not (Get-Module -Name KeepitTools)) {
    $keepitManifest = Join-Path $PSScriptRoot '..' '..' 'src' 'KeepitTools.psd1'
    if (Test-Path $keepitManifest) {
        Write-Verbose "Loading KeepitTools from '$keepitManifest'"
        Import-Module $keepitManifest -Force -ErrorAction Stop
    }
    elseif (Get-Module -ListAvailable -Name KeepitTools) {
        Write-Verbose "Loading KeepitTools from module path"
        Import-Module KeepitTools -Force -ErrorAction Stop
    }
    else {
        throw "KeepitTools module not found. Expected it at '$keepitManifest' or installed in the module path."
    }
}

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

if (-not $Credential) {
    Write-Host "Enter Keepit credentials for environment '$Environment'."
    $username   = Read-Host 'Username'
    $securePass = Read-Host 'Password' -AsSecureString
    $Credential = [System.Management.Automation.PSCredential]::new($username, $securePass)
}

try {
    Connect-KeepitService -Credential $Credential -Environment $Environment -ErrorAction Stop | Out-Null
    Write-Verbose "Connected to Keepit ($Environment)."
}
catch {
    throw "Failed to connect to Keepit service: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# Connector selection and validation
# ---------------------------------------------------------------------------

try {
    $o365Connectors = @(Get-KeepitConnector -Type 'o365-admin' -ErrorAction Stop)
}
catch {
    throw "Failed to retrieve connectors: $($_.Exception.Message)"
}

if ($o365Connectors.Count -eq 0) {
    throw "No accessible o365-admin connectors found in environment '$Environment'."
}

if ($Connector) {
    $selectedConnector = $o365Connectors |
        Where-Object { $_.Name -eq $Connector -or $_.ConnectorGuid -eq $Connector } |
        Select-Object -First 1

    if (-not $selectedConnector) {
        throw "Connector '$Connector' was not found or is not of type o365-admin in environment '$Environment'."
    }
}
else {
    Write-Host ''
    Write-Host 'Available o365-admin connectors:'
    for ($idx = 0; $idx -lt $o365Connectors.Count; $idx++) {
        Write-Host ('  [{0}] {1}' -f ($idx + 1), $o365Connectors[$idx].Name)
    }

    [int]$selection = 0
    while ($selection -lt 1 -or $selection -gt $o365Connectors.Count) {
        $raw = Read-Host ('Select a connector [1-{0}]' -f $o365Connectors.Count)
        if (-not [int]::TryParse($raw, [ref]$selection) -or
            $selection -lt 1 -or $selection -gt $o365Connectors.Count) {
            Write-Host "Please enter a number between 1 and $($o365Connectors.Count)."
            $selection = 0
        }
    }

    $selectedConnector = $o365Connectors[$selection - 1]
}

Write-Host "Connector : $($selectedConnector.Name) ($($selectedConnector.ConnectorGuid))"

# ---------------------------------------------------------------------------
# Default output path
# ---------------------------------------------------------------------------

if (-not $OutputPath) {
    $safeName  = $selectedConnector.Name -replace '[\\/:*?"<>|]', '_'
    $dateStamp = Get-Date -Format 'yyyy-MM-dd'
    $OutputPath = "EverCovered-${safeName}-${dateStamp}.csv"
}

# ---------------------------------------------------------------------------
# Search for all users with Exchange/Outlook coverage
#
# Strategy: two BSearch calls (no date filter) instead of per-snapshot iteration.
#   1. Active   Outlook folders -> currently covered users
#   2. Deleted  Outlook folders -> users previously covered but since removed
#
# The BSearch Updated field reflects the last backup timestamp for each item,
# which we use as LastSeenDate.  This avoids the snaptimeFrom/snaptimeTo
# date-windowing that causes Exchange user objects to return empty results.
# ---------------------------------------------------------------------------

Write-Host "Searching for users with email coverage on connector '$($selectedConnector.Name)'..."

# Key   = user GUID (path-masked, e.g. bf06910a--a25b--42ef--...)
# Value = most recent Updated timestamp string seen for this user
$userLastSeen = [System.Collections.Generic.Dictionary[string, string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

function Update-UserSeen {
    param(
        [System.Collections.Generic.Dictionary[string, string]]$Dict,
        [string]$Guid,
        [string]$Timestamp
    )
    if ([string]::IsNullOrWhiteSpace($Timestamp)) { return }

    $existing = $null
    if ($Dict.TryGetValue($Guid, [ref]$existing)) {
        try {
            $existingDt = [DateTime]::Parse(
                $existing, $null,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            )
            $newDt = [DateTime]::Parse(
                $Timestamp, $null,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            )
            if ($newDt -gt $existingDt) {
                $Dict[$Guid] = $Timestamp
            }
        }
        catch {
            # If parsing fails, keep the new value as a best-effort update
            $Dict[$Guid] = $Timestamp
        }
    }
    else {
        $Dict[$Guid] = $Timestamp
    }
}

# --- Search 1: Active Outlook folders ---
Write-Progress -Activity 'Scanning for covered users' -Status 'Searching active Outlook folders...'
try {
    $activeOutlook = @(
        Search-KeepitSnapshot -Connector $selectedConnector.ConnectorGuid `
            -RootPath  '/Users' `
            -ItemName  'Outlook' `
            -Recursive `
            -ResultSize Unlimited `
            -WarningAction SilentlyContinue `
            -ErrorAction Stop
    )
}
catch {
    Write-Progress -Activity 'Scanning for covered users' -Completed
    throw "Active Outlook folder search failed: $($_.Exception.Message)"
}
Write-Verbose "Active Outlook entries: $($activeOutlook.Count)"

# --- Search 2: Deleted Outlook folders (users removed from backup) ---
Write-Progress -Activity 'Scanning for covered users' -Status 'Searching deleted Outlook folders...'
try {
    $deletedOutlook = @(
        Search-KeepitSnapshot -Connector $selectedConnector.ConnectorGuid `
            -RootPath  '/Users' `
            -ItemName  'Outlook' `
            -Recursive `
            -DeletedOnly `
            -ResultSize Unlimited `
            -WarningAction SilentlyContinue `
            -ErrorAction Stop
    )
}
catch {
    Write-Warning "Deleted Outlook folder search failed (skipping): $($_.Exception.Message)"
    $deletedOutlook = @()
}
Write-Verbose "Deleted Outlook entries: $($deletedOutlook.Count)"

Write-Progress -Activity 'Scanning for covered users' -Completed

$allOutlook = @($activeOutlook) + @($deletedOutlook)

if ($allOutlook.Count -eq 0) {
    Write-Warning "No Outlook folders found on connector '$($selectedConnector.Name)'. Nothing to report."
    exit 0
}

Write-Host "Processing $($allOutlook.Count) Outlook folder entry/entries..."

foreach ($entry in $allOutlook) {
    # Id is a kng:// URI; extract the GUID segment between /Users/ and /Outlook
    if ($entry.Id -match '/Users/([^/]+)/Outlook') {
        Update-UserSeen -Dict $userLastSeen -Guid $Matches[1] -Timestamp $entry.Updated
    }
}

# ---------------------------------------------------------------------------
# Resolve GUIDs to User Principal Names
# ---------------------------------------------------------------------------

Write-Host "Found $($userLastSeen.Count) unique user(s) with email backup coverage."
Write-Host "Resolving GUIDs to UPNs..."

Write-Progress -Activity 'Resolving GUIDs to UPNs' -Status 'Fetching user directory...'
$guidToUpn = @{}
try {
    $userLastSeen.Keys |
        Convert-KeepitGuidToUPN -Connector $selectedConnector.ConnectorGuid `
            -WarningAction SilentlyContinue -ErrorAction Stop |
        ForEach-Object { $guidToUpn[$_.Guid] = $_.UserPrincipalName }
}
catch {
    Write-Warning "UPN resolution failed (GUIDs will be written without UPNs): $($_.Exception.Message)"
}
Write-Progress -Activity 'Resolving GUIDs to UPNs' -Completed

# ---------------------------------------------------------------------------
# Export CSV
# ---------------------------------------------------------------------------

Write-Host "Writing report to '$OutputPath'..."

$rows = @(
    $userLastSeen.GetEnumerator() |
        ForEach-Object {
            [PSCustomObject]@{
                UserGUID     = $_.Key
                UserUPN      = $guidToUpn[$_.Key]
                LastSeenDate = $_.Value
            }
        } |
        Sort-Object LastSeenDate -Descending
)

try {
    $rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "Done. $($rows.Count) row(s) written to '$OutputPath'."
}
catch {
    throw "Failed to write CSV to '$OutputPath': $($_.Exception.Message)"
}
