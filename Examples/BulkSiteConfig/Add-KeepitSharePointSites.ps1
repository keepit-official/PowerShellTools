<#
.SYNOPSIS
    Bulk-adds SharePoint site collections to the manual backup scope of Keepit
    Microsoft 365 connectors, from a plain-text or CSV file.
.DESCRIPTION
    Reads SharePoint site URLs from a file and adds them to the SiteCollections
    ("manually included sites") list of the target connector(s) via
    Set-KeepitConnectorConfiguration. This is intended for connectors that do NOT
    use auto-include-by-naming-convention and instead have sites hand-picked in the
    UI — a task that becomes impractical for thousands of sites.

    There are two ways to choose the target connector:

    1. Single connector (-Connector). Every site in the file is added to one
       connector. Works with a plain-text file or a CSV.

    2. Per-row routing (-TargetConnector, CSV only). Each CSV row names its own
       target connector in the column you pass to -TargetConnector; the site on
       that row is added to that connector. This lets a single CSV distribute
       thousands of sites across several connectors in one run.

    -Connector and -TargetConnector are mutually exclusive. A plain-text file can
    only be used with -Connector (it has no columns to route by).

    Input formats:
      - Plain text: one site URL per line; blank lines and lines beginning with
        '#' are ignored. (-Connector only.)
      - CSV: the site URL comes from -SiteUrlColumn, or an auto-detected column
        named SiteUrl / SiteURL / URL / Url / Site / SiteCollection.

    Sites are added with AutoIncludeAllSubSites = $true (the same default the UI
    applies). Existing sites are preserved; the operation is additive and
    idempotent — re-running with the same input adds nothing new.

    The Keepit connector configuration attribute accepts payloads up to 1 GB, so
    even several thousand sites per connector fit in a single update (a
    SiteCollections entry is ~100 bytes, so 4000 sites is only ~400 KB).

    The script reuses an existing Connect-KeepitService session when one is
    present. Provide -Credential (and -Environment) to establish a new session.
.PARAMETER Connector
    A single connector name or GUID. Every site in the file is added to this
    connector. Must be a Microsoft 365 (o365-admin) connector. Mutually exclusive
    with -TargetConnector.
.PARAMETER TargetConnector
    The name of a CSV column whose value, on each row, is the connector that
    row's site should be added to. Requires a CSV -SitesFile. Mutually exclusive
    with -Connector.
.PARAMETER SitesFile
    Path to the file containing the site URLs to add (plain text or CSV).
.PARAMETER SiteUrlColumn
    Optional. For CSV input, the name of the column holding the site URLs. When
    omitted for a CSV, a URL column is auto-detected. Ignored for plain text.
.PARAMETER Credential
    Optional PSCredential. When provided the script calls Connect-KeepitService
    before running. If omitted and no active session exists, the script prompts
    for a username and password. Ignored when already connected.
.PARAMETER Environment
    Keepit datacenter region. Required when no active session exists.
    Valid values: ws.keepit, au-sy, ca-tr, dk-co, de-fr, uk-ld, us-dc, ch-zh,
                  ws-test, ws-test-b, ws-test-c, staging, dev.
    Ignored when an active session already exists.
.EXAMPLE
    .\Add-KeepitSharePointSites.ps1 -Connector "Production M365" -SitesFile .\sites.txt -Environment us-dc

    Adds every URL in sites.txt to the "Production M365" connector.
.EXAMPLE
    .\Add-KeepitSharePointSites.ps1 -Connector abc -SitesFile .\junk.csv

    Adds every site in junk.csv to connector "abc" (single-connector mode with a
    CSV; the URL column is auto-detected or set with -SiteUrlColumn).
.EXAMPLE
    .\Add-KeepitSharePointSites.ps1 -SitesFile .\4000.csv -TargetConnector "whichOne"

    Per-row routing: for each row in 4000.csv, adds the row's site to the connector
    named in that row's "whichOne" column.
.EXAMPLE
    .\Add-KeepitSharePointSites.ps1 -Connector "Production M365" -SitesFile .\sites.txt -WhatIf

    Previews the change: reports how many sites would be added, without writing.
.OUTPUTS
    PSCustomObject, one per target connector, with:
        - Connector       : Connector name or GUID as supplied
        - ConnectorGuid   : Resolved connector GUID
        - SitesRequested  : Unique valid URLs targeted at this connector
        - AlreadyPresent  : Of those, how many were already in the connector
        - Added           : How many new sites were added (0 under -WhatIf)
        - TotalAfter      : SiteCollections count after the operation
        - Status          : Success, Skipped, WhatIf, or Failed
.NOTES
    Requires the KeepitTools module at ../../src/KeepitTools.psd1 (repository
    layout) or installed in the PowerShell module path.

    Requires PowerShell 7+.

    Performance: the module de-duplicates each incoming site against the existing
    list, which is O(n^2). For multi-thousand-site lists the single update call can
    take a while; this is expected. The script pre-deduplicates its input to keep
    that cost as low as possible.
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'SingleConnector')]
param (
    [Parameter(Mandatory = $true, ParameterSetName = 'SingleConnector')]
    [ValidateNotNullOrEmpty()]
    [string]$Connector,

    [Parameter(Mandatory = $true, ParameterSetName = 'ColumnRouting')]
    [ValidateNotNullOrEmpty()]
    [string]$TargetConnector,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SitesFile,

    [Parameter(Mandatory = $false)]
    [string]$SiteUrlColumn,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [ValidateSet('ws.keepit', 'au-sy', 'ca-tr', 'dk-co', 'de-fr', 'uk-ld', 'us-dc', 'ch-zh',
                 'ws-test', 'ws-test-b', 'ws-test-c', 'staging', 'dev')]
    [string]$Environment
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
# Read the input file and build per-connector site assignments
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $SitesFile -PathType Leaf)) {
    throw "Sites file not found: '$SitesFile'"
}

$isCsv     = ([System.IO.Path]::GetExtension($SitesFile) -ieq '.csv')
$routing   = ($PSCmdlet.ParameterSetName -eq 'ColumnRouting')
$urlCandidates = 'SiteUrl', 'SiteURL', 'URL', 'Url', 'Site', 'SiteCollection'

function Resolve-CsvColumn {
    param([string[]]$Headers, [string]$Requested, [string[]]$Candidates, [string]$Purpose)
    if ($Requested) {
        if ($Requested -notin $Headers) {
            throw "Column '$Requested' not found in '$SitesFile'. Columns present: $($Headers -join ', ')."
        }
        return $Requested
    }
    $found = $Candidates | Where-Object { $_ -in $Headers } | Select-Object -First 1
    if (-not $found) {
        throw "Could not auto-detect a $Purpose column in '$SitesFile'. Columns present: $($Headers -join ', '). Specify it explicitly."
    }
    Write-Verbose "Auto-detected $Purpose column: '$found'"
    return $found
}

# Collect (connector, rawUrl) pairs from the file.
$pairs        = [System.Collections.Generic.List[object]]::new()
$blankConnCnt = 0

if ($routing) {
    if (-not $isCsv) {
        throw "-TargetConnector requires a CSV file, but '$SitesFile' is not a .csv. Use -Connector for a plain-text list."
    }
    $rows = @(Import-Csv -LiteralPath $SitesFile)
    if ($rows.Count -eq 0) { throw "CSV '$SitesFile' contains no rows." }

    $headers = $rows[0].PSObject.Properties.Name
    if ($TargetConnector -notin $headers) {
        throw "Connector column '$TargetConnector' not found in '$SitesFile'. Columns present: $($headers -join ', ')."
    }
    $urlCol = Resolve-CsvColumn -Headers $headers -Requested $SiteUrlColumn -Candidates $urlCandidates -Purpose 'URL'

    foreach ($row in $rows) {
        $conn = "$($row.$TargetConnector)".Trim()
        if ([string]::IsNullOrWhiteSpace($conn)) { $blankConnCnt++; continue }
        $pairs.Add([PSCustomObject]@{ Conn = $conn; Url = $row.$urlCol })
    }
}
elseif ($isCsv) {
    $rows = @(Import-Csv -LiteralPath $SitesFile)
    if ($rows.Count -eq 0) { throw "CSV '$SitesFile' contains no rows." }
    $urlCol = Resolve-CsvColumn -Headers $rows[0].PSObject.Properties.Name -Requested $SiteUrlColumn -Candidates $urlCandidates -Purpose 'URL'
    foreach ($row in $rows) {
        $pairs.Add([PSCustomObject]@{ Conn = $Connector; Url = $row.$urlCol })
    }
}
else {
    # Plain text: one URL per line; ignore blanks and '#' comments.
    Get-Content -LiteralPath $SitesFile |
        Where-Object { $_ -notmatch '^\s*(#|$)' } |
        ForEach-Object { $pairs.Add([PSCustomObject]@{ Conn = $Connector; Url = $_ }) }
}

# Normalize, validate, and de-duplicate URLs per connector, preserving order.
# $assignments: connectorId -> ordered dictionary of normalizedKey -> cleanUrl
$assignments  = [ordered]@{}
$invalidCount = 0

foreach ($p in $pairs) {
    $u = $p.Url
    if ([string]::IsNullOrWhiteSpace($u)) { continue }
    $clean = $u.Trim().TrimEnd('/')
    if ($clean -notmatch '^https?://') { $invalidCount++; continue }

    $conn = $p.Conn
    if (-not $assignments.Contains($conn)) { $assignments[$conn] = [ordered]@{} }
    $key = $clean.ToLowerInvariant()
    if (-not $assignments[$conn].Contains($key)) { $assignments[$conn][$key] = $clean }
}

if ($invalidCount -gt 0) {
    Write-Warning "Ignored $invalidCount line(s) that do not look like site URLs (must start with http:// or https://)."
}
if ($blankConnCnt -gt 0) {
    Write-Warning "Ignored $blankConnCnt CSV row(s) with an empty '$TargetConnector' value."
}

$totalUnique = ($assignments.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
if (-not $totalUnique) {
    throw "No valid site URLs found in '$SitesFile'."
}

Write-Host "Read $totalUnique unique site URL(s) for $($assignments.Count) connector(s) from '$SitesFile'."

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
# Helper: current SiteCollections URLs for a connector
# ---------------------------------------------------------------------------

function Get-IncludedSiteUrl {
    param([string]$ConnectorId)
    $cfg = Get-KeepitConnectorConfiguration -Connector $ConnectorId -Workload SharePoint -ErrorAction Stop
    $obj = $cfg.RawConfiguration | ConvertFrom-Json -AsHashtable
    $sp  = $obj['SharePointNG']

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($sp -and $sp.ContainsKey('SiteCollections')) {
        foreach ($entry in @($sp['SiteCollections'])) {
            if ($entry.SiteUrl) { [void]$set.Add($entry.SiteUrl.Trim().TrimEnd('/').ToLowerInvariant()) }
        }
    }
    $autoAll = [bool]($sp -and $sp['AutoIncludeAllSiteCollections'])
    [PSCustomObject]@{ Urls = $set; AutoIncludeAll = $autoAll }
}

# ---------------------------------------------------------------------------
# Apply to each target connector
# ---------------------------------------------------------------------------

$results = foreach ($entry in $assignments.GetEnumerator()) {
    $conn     = $entry.Key
    $wantUrls = @($entry.Value.Values)

    Write-Host ""
    Write-Host "Connector: $conn ($($wantUrls.Count) site(s) requested)"

    try {
        $current = Get-IncludedSiteUrl -ConnectorId $conn
    }
    catch {
        Write-Warning "  Could not read configuration for '$conn' (skipping): $($_.Exception.Message)"
        [PSCustomObject]@{
            Connector = $conn; ConnectorGuid = $null; SitesRequested = $wantUrls.Count
            AlreadyPresent = $null; Added = 0; TotalAfter = $null; Status = 'Failed'
        }
        continue
    }

    if ($current.AutoIncludeAll) {
        Write-Warning "  '$conn' has AutoIncludeAllSiteCollections = true; every site is already backed up, so manually adding sites has no effect. Skipping."
        [PSCustomObject]@{
            Connector = $conn; ConnectorGuid = $null; SitesRequested = $wantUrls.Count
            AlreadyPresent = $null; Added = 0; TotalAfter = $null; Status = 'Skipped'
        }
        continue
    }

    $beforeCount = $current.Urls.Count
    $toAdd = [System.Collections.Generic.List[string]]::new()
    foreach ($u in $wantUrls) {
        if (-not $current.Urls.Contains($u.ToLowerInvariant())) { $toAdd.Add($u) }
    }
    $alreadyPresent = $wantUrls.Count - $toAdd.Count

    Write-Host "  Currently included: $beforeCount | already present: $alreadyPresent | to add: $($toAdd.Count)"

    if ($toAdd.Count -eq 0) {
        Write-Host "  Nothing to add."
        [PSCustomObject]@{
            Connector = $conn; ConnectorGuid = $null; SitesRequested = $wantUrls.Count
            AlreadyPresent = $alreadyPresent; Added = 0; TotalAfter = $beforeCount; Status = 'Skipped'
        }
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($conn, "Add $($toAdd.Count) SharePoint site(s) to backup scope")) {
        # -WhatIf path: report the projection without writing.
        $projected = $beforeCount + $toAdd.Count
        Write-Host "  WhatIf: would add $($toAdd.Count) site(s); SiteCollections would grow from $beforeCount to $projected."
        [PSCustomObject]@{
            Connector = $conn; ConnectorGuid = $null; SitesRequested = $wantUrls.Count
            AlreadyPresent = $alreadyPresent; Added = 0; TotalAfter = $projected; Status = 'WhatIf'
        }
        continue
    }

    try {
        $applied = Set-KeepitConnectorConfiguration -Connector $conn -Workload SharePoint `
            -AddIncludedSites $toAdd.ToArray() -Confirm:$false `
            -WarningAction SilentlyContinue -ErrorAction Stop

        # Confirm the result by re-reading the connector.
        $after = Get-IncludedSiteUrl -ConnectorId $conn
        $added = $after.Urls.Count - $beforeCount
        Write-Host "  Added $added site(s). SiteCollections now: $($after.Urls.Count)."

        [PSCustomObject]@{
            Connector = $applied.Name; ConnectorGuid = $applied.ConnectorGuid ?? $applied.Name
            SitesRequested = $wantUrls.Count; AlreadyPresent = $alreadyPresent
            Added = $added; TotalAfter = $after.Urls.Count; Status = 'Success'
        }
    }
    catch {
        Write-Warning "  Failed to update '$conn': $($_.Exception.Message)"
        [PSCustomObject]@{
            Connector = $conn; ConnectorGuid = $null; SitesRequested = $wantUrls.Count
            AlreadyPresent = $alreadyPresent; Added = 0; TotalAfter = $beforeCount; Status = 'Failed'
        }
    }
}

Write-Host ""
$results
