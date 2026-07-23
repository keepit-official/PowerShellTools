<#
.SYNOPSIS
    Reports all SharePoint sites that have ever been backed up on a Keepit connector.
.DESCRIPTION
    Searches one or all o365-admin connectors for every SharePoint site collection
    that has ever had data backed up. Output is a CSV file containing the site URL,
    display name, most recent backup timestamp, current status, protection state,
    and connector name.

    By default all o365-admin connectors in the tenant are scanned and results are
    deduplicated by site URL across connectors.  Use -Connector to scope the report
    to a single connector.

    Two BSearch API calls are made per connector:
      1. All      sites directly under /SharePoint. This call is not filtered on
                  deleted state, so it returns removed sites as well as in-scope
                  ones.
      2. Deleted  sites directly under /SharePoint. Normally a subset of the first
                  call, retained as a safety net for connector types whose
                  unfiltered search excludes deleted entries.
    A site is included when it appears in either result set. Each site's Status is
    taken from that entry's own IsDeleted flag, not from which call returned it.
    LastSeenDate reflects the most recent backup timestamp for each site.

    The script reuses an existing Connect-KeepitService session when one is
    present.  Provide -Credential (and -Environment) to establish a new session.
.PARAMETER Credential
    Optional PSCredential. When provided the script calls Connect-KeepitService
    before running the report.  If omitted and no active session exists the
    script prompts for a username and password. Ignored when already connected.
.PARAMETER Environment
    Keepit datacenter region. Required when no active session exists.
    Valid values: ws.keepit, au-sy, ca-tr, dk-co, de-fr, uk-ld, us-dc, ch-zh,
                  ws-test, ws-test-b, ws-test-c, staging, dev.
    Ignored when an active session already exists.
.PARAMETER Connector
    Optional. Name or GUID of a single o365-admin connector to report on.
    If omitted, all o365-admin connectors in the tenant are scanned and results
    are deduplicated by site URL.
.PARAMETER OutputPath
    Optional. Full path for the CSV output file.
    Defaults to EverCovered-Sites-All-<yyyy-MM-dd>.csv (multi-connector) or
    EverCovered-Sites-<ConnectorName>-<yyyy-MM-dd>.csv (single connector) in
    the current working directory.
.EXAMPLE
    .\EverCovered-Sites.ps1 -Environment us-dc

    Connects interactively, scans all M365 connectors, and writes a CSV.
.EXAMPLE
    $cred = Get-Credential
    .\EverCovered-Sites.ps1 -Environment us-dc -Credential $cred

    Connects with explicit credentials and scans all M365 connectors.
.EXAMPLE
    .\EverCovered-Sites.ps1 -Connector "Production M365" -OutputPath C:\Reports\sp.csv

    Reuses an existing session and reports on a single named connector.
.OUTPUTS
    CSV file with columns:
        - SiteName     : Display name of the site from the backup index
        - SiteURL      : Full SharePoint site URL extracted from the backup path
        - LastSeenDate : Most recent backup timestamp in which this site appeared
        - Status       : Active   — site is currently in backup scope
                         Removed  — site was previously backed up but has since
                                    been deleted or removed from backup scope
        - Protected    : True  — site carries the Keepit 'protected' flag
                         False — site does not carry the flag
        - Connector    : Name of the connector that provided the most recent data
.NOTES
    Requires the KeepitTools module at ../../src/KeepitTools.psd1 (repository
    layout) or installed in the PowerShell module path.

    Requires PowerShell 7+.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
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
    $keepitManifest = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'src', 'KeepitTools.psd1'
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
# Authentication / connection
# ---------------------------------------------------------------------------

$isConnected = $null -ne (Get-Module KeepitTools).SessionState.PSVariable.GetValue('KeepitAuth')

if ($isConnected) {
    Write-Verbose "Reusing existing Keepit session."
}
else {
    if (-not $Environment) {
        throw "Not connected to Keepit. Provide -Environment (and optionally -Credential) to connect."
    }

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
}

# ---------------------------------------------------------------------------
# Connector selection
# ---------------------------------------------------------------------------

try {
    $allO365Connectors = @(Get-KeepitConnector -Type 'o365-admin' -ErrorAction Stop)
}
catch {
    throw "Failed to retrieve connectors: $($_.Exception.Message)"
}

if ($allO365Connectors.Count -eq 0) {
    throw "No accessible o365-admin connectors found."
}

if ($Connector) {
    $connectorsToScan = @(
        $allO365Connectors |
            Where-Object { $_.Name -eq $Connector -or $_.ConnectorGuid -eq $Connector }
    )
    if ($connectorsToScan.Count -eq 0) {
        throw "Connector '$Connector' was not found or is not of type o365-admin."
    }
}
else {
    $connectorsToScan = $allO365Connectors
}

$multiConnector = $connectorsToScan.Count -gt 1

if ($multiConnector) {
    Write-Host "Scanning $($connectorsToScan.Count) o365-admin connector(s): $($connectorsToScan.Name -join ', ')"
}
else {
    Write-Host "Connector : $($connectorsToScan[0].Name) ($($connectorsToScan[0].ConnectorGuid))"
}

# ---------------------------------------------------------------------------
# Default output path
# ---------------------------------------------------------------------------

if (-not $OutputPath) {
    $dateStamp = Get-Date -Format 'yyyy-MM-dd'
    if ($multiConnector) {
        $OutputPath = "EverCovered-Sites-All-${dateStamp}.csv"
    }
    else {
        $safeName  = $connectorsToScan[0].Name -replace '[\\/:*?"<>|]', '_'
        $OutputPath = "EverCovered-Sites-${safeName}-${dateStamp}.csv"
    }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function ConvertFrom-KngMaskedUrl {
    # Reverses Keepit path-masking applied to URL segments:
    #   -- → -    (single dashes were doubled)
    #   -s → /    (slashes were replaced)
    #   -c → :    (colons were replaced)
    # Unescape doubled-dashes first to avoid conflicts with -s and -c prefixes.
    param([string]$Masked)
    $r = $Masked -replace '--', "`u{FFFE}"
    $r = $r -replace '-s', '/'
    $r = $r -replace '-c', ':'
    $r -replace "`u{FFFE}", '-'
}

function Get-SiteUrlFromEntry {
    param($Entry)
    # Extract the URL from the kng:// URI in Id (more reliable than Name,
    # which may be a display name rather than the full URL).
    if ($Entry.Id -match '/SharePoint/(.+)$') {
        $url = ConvertFrom-KngMaskedUrl -Masked $Matches[1]
        if ($url -match '^https?://') { return $url }
    }
    return $Entry.Name
}

function Get-SiteStatusFromEntry {
    param($Entry)
    # Status must come from the entry's own IsDeleted flag rather than from which
    # search returned it. The first search is not filtered on deleted state, so it
    # returns removed sites too; treating everything it returns as Active would
    # mask exactly the sites this report exists to surface.
    if ($Entry.IsDeleted) { return 'Removed' }
    return 'Active'
}

function Get-ProtectedFlagFromEntry {
    param($Entry)
    # BSearch exposes protection as an empty element, <kng:meta key="protected"/>,
    # which Search-KeepitSnapshot surfaces as Metadata['protected'] = $true.
    # There is no explicit false value: absence of the key means "not protected",
    # so test for the key rather than comparing its value.
    if ($null -eq $Entry.Metadata) { return $false }
    return $Entry.Metadata.ContainsKey('protected')
}

# Key   = site URL (unmasked, unique per site)
# Value = PSCustomObject { SiteName, LastSeen, Status, Protected, Connector }
$siteTable = [System.Collections.Generic.Dictionary[string, pscustomobject]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

function Update-SiteEntry {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [System.Collections.Generic.Dictionary[string, pscustomobject]]$Table,
        [string]$Url,
        [string]$Name,
        [string]$Timestamp,
        [string]$Status,
        [bool]$Protected,
        [string]$ConnectorName
    )
    if ([string]::IsNullOrWhiteSpace($Url)) { return }
    if (-not $PSCmdlet.ShouldProcess($Url, 'Update site entry')) { return }

    $existing = $null
    if ($Table.TryGetValue($Url, [ref]$existing)) {
        $promoteToActive = ($Status -eq 'Active' -and $existing.Status -ne 'Active')

        $isNewer = $false
        if (-not [string]::IsNullOrWhiteSpace($Timestamp) -and
            -not [string]::IsNullOrWhiteSpace($existing.LastSeen)) {
            try {
                $existingDt = [DateTime]::Parse(
                    $existing.LastSeen, $null,
                    [System.Globalization.DateTimeStyles]::RoundtripKind)
                $newDt = [DateTime]::Parse(
                    $Timestamp, $null,
                    [System.Globalization.DateTimeStyles]::RoundtripKind)
                $isNewer = $newDt -gt $existingDt
            }
            catch { $isNewer = $true }
        }

        if ($promoteToActive) {
            # Active always beats Removed; adopt this connector as authoritative
            $existing.Status    = 'Active'
            $existing.LastSeen  = $Timestamp
            $existing.Protected = $Protected
            $existing.Connector = $ConnectorName
        }
        elseif ($isNewer -and $Status -eq $existing.Status) {
            # Same status, newer timestamp: update to more recent observation
            $existing.LastSeen  = $Timestamp
            $existing.Protected = $Protected
            $existing.Connector = $ConnectorName
        }
    }
    else {
        $Table[$Url] = [PSCustomObject]@{
            SiteName  = $Name
            LastSeen  = $Timestamp
            Status    = $Status
            Protected = $Protected
            Connector = $ConnectorName
        }
    }
}

# ---------------------------------------------------------------------------
# Scan connectors
# ---------------------------------------------------------------------------

foreach ($conn in $connectorsToScan) {
    Write-Host "Scanning '$($conn.Name)'..."

    # All sites. This search is not filtered on deleted state, so it returns both
    # in-scope and removed sites; each entry's own IsDeleted flag decides its status.
    Write-Progress -Activity "Scanning '$($conn.Name)'" -Status 'Searching SharePoint sites...'
    try {
        $activeSites = @(
            Search-KeepitSnapshot -Connector $conn.ConnectorGuid `
                -RootPath   '/SharePoint' `
                -ResultSize Unlimited `
                -WarningAction SilentlyContinue `
                -ErrorAction Stop
        )
    }
    catch {
        Write-Progress -Activity "Scanning '$($conn.Name)'" -Completed
        Write-Warning "Active site search failed on '$($conn.Name)' (skipping): $($_.Exception.Message)"
        continue
    }
    Write-Verbose "'$($conn.Name)': $($activeSites.Count) SharePoint entry/entries."

    # Deleted sites. Normally a subset of the search above, kept as a safety net for
    # connector types whose unfiltered search excludes deleted entries. Duplicates
    # are harmless: they merge on URL and resolve to the same IsDeleted status.
    Write-Progress -Activity "Scanning '$($conn.Name)'" -Status 'Searching deleted SharePoint sites...'
    try {
        $deletedSites = @(
            Search-KeepitSnapshot -Connector $conn.ConnectorGuid `
                -RootPath    '/SharePoint' `
                -DeletedOnly `
                -ResultSize  Unlimited `
                -WarningAction SilentlyContinue `
                -ErrorAction Stop
        )
    }
    catch {
        Write-Warning "Deleted site search failed on '$($conn.Name)' (skipping): $($_.Exception.Message)"
        $deletedSites = @()
    }
    Write-Verbose "'$($conn.Name)': $($deletedSites.Count) deleted SharePoint entry/entries."

    Write-Progress -Activity "Scanning '$($conn.Name)'" -Completed

    if ($activeSites.Count -eq 0 -and $deletedSites.Count -eq 0) {
        Write-Warning "No SharePoint sites found on connector '$($conn.Name)'."
        continue
    }

    foreach ($entry in @($activeSites) + @($deletedSites)) {
        $url = Get-SiteUrlFromEntry -Entry $entry
        Update-SiteEntry -Table $siteTable -Url $url -Name $entry.Name `
            -Timestamp $entry.Updated `
            -Status (Get-SiteStatusFromEntry -Entry $entry) `
            -Protected (Get-ProtectedFlagFromEntry -Entry $entry) `
            -ConnectorName $conn.Name
    }
}

if ($siteTable.Count -eq 0) {
    Write-Warning "No SharePoint sites found across all scanned connectors. Nothing to report."
    exit 0
}

# ---------------------------------------------------------------------------
# Export CSV
# ---------------------------------------------------------------------------

Write-Host "Found $($siteTable.Count) unique SharePoint site(s) with backup coverage."
Write-Host "Writing report to '$OutputPath'..."

$rows = @(
    $siteTable.GetEnumerator() |
        ForEach-Object {
            [PSCustomObject]@{
                SiteName     = $_.Value.SiteName
                SiteURL      = $_.Key
                LastSeenDate = $_.Value.LastSeen
                Status       = $_.Value.Status
                Protected    = $_.Value.Protected
                Connector    = $_.Value.Connector
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
