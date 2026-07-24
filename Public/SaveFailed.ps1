# =============================================================================
# Save-KeepitFailedItems - download the items that failed in a restore job.
# Companion to Restore-KeepitFailedItems: retry what can be retried in place,
# download the rest. Reuses the private helpers defined in RestoreFailed.ps1
# (Get-KeepitJobDetail, Get-KeepitJobFailedItems, ConvertFrom-KeepitJobReport).
# =============================================================================

# --- Private: mask one path segment the way Keepit masks bsearch item ids -----
function ConvertTo-KeepitMaskedSegment {
    <#
    .SYNOPSIS
        Masks a single path segment for comparison with a bsearch id (dash doubled,
        colon -> -c). Internal helper; not exported. Segments never contain '/'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Segment)
    ($Segment -replace '-', '--') -replace ':', '-c'
}

# --- Private: map a failure path's workload to its bsearch id namespace --------
function Get-KeepitWorkloadNamespace {
    <#
    .SYNOPSIS
        Maps the leading segment of a failure display path to a regex matching the
        bsearch id namespace it lives in. Internal helper; returns $null if unknown.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$FirstSegment)
    switch -Regex ($FirstSegment) {
        '^SharePoint$'                    { '^/SharePoint/'; break }
        '^(Groups & Teams|Groups|Teams)$' { '^/Groups/'; break }
        '^OneDrive$'                      { '^/Users/[^/]+/OneDrive'; break }
        '^(Exchange|Mail|Outlook)$'       { '^/Users/[^/]+/Outlook'; break }
        default                           { $null }
    }
}

# --- Private: resolve a failed display path to its backup item id (kng://) -----
function Resolve-KeepitBackupItemId {
    <#
    .SYNOPSIS
        Resolves a failed item's display path to its bsearch item id by searching
        for the file name and matching the id whose namespace and path tail best
        fit the display path. Internal helper; returns $null if nothing matches.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$DisplayPath,
        [Parameter(Mandatory)] [string]$ConnectorGuid,
        [Parameter(Mandatory)] [string]$Snaptime,
        [Parameter(Mandatory)] [string]$BaseUrl,
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$AuthHeader
    )
    $segs = $DisplayPath.Trim('/') -split '/'
    $leaf = $segs[-1]
    $expectedNs = Get-KeepitWorkloadNamespace -FirstSegment $segs[0]
    $query = "apiVersion=2&device=$ConnectorGuid&searchTerms=$([uri]::EscapeDataString('"' + $leaf + '"'))" +
             "&recursive=1&count=50&includeBody=1&snaptime=$([uri]::EscapeDataString($Snaptime))&filterAnd=AND:!deleted,!sys"
    $resp = Invoke-WebRequest -Uri "$BaseUrl/users/$UserId/bsearch?$query" `
        -Headers @{ Authorization = $AuthHeader; Accept = 'application/atom+xml' } -TimeoutSec 60 -ErrorAction Stop
    $xml = [xml]$resp.Content
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable); $ns.AddNamespace('a', 'http://www.w3.org/2005/Atom')
    $maskedDisplay = @($segs | ForEach-Object { ConvertTo-KeepitMaskedSegment -Segment $_ })

    $cands = foreach ($e in $xml.SelectNodes('//a:entry/a:id', $ns)) {
        $full = $e.InnerText -replace '^kng://[^/]+', ''   # keep leading '/'
        $idsegs = $full.Trim('/') -split '/'
        $n = 0
        while ($n -lt [Math]::Min($idsegs.Count, $maskedDisplay.Count)) {
            if ($idsegs[$idsegs.Count - 1 - $n].ToLower() -eq $maskedDisplay[$maskedDisplay.Count - 1 - $n].ToLower()) { $n++ } else { break }
        }
        [pscustomobject]@{ Id = $e.InnerText; Score = $n; NsMatch = ($expectedNs -and ($full -match $expectedNs)) }
    }

    # Prefer a candidate in the display's workload namespace (a leaf match is enough
    # there, so container-root items resolve); else best tail match with >=2 segments.
    $nsCands = @($cands | Where-Object NsMatch | Sort-Object Score -Descending)
    if ($nsCands.Count -and $nsCands[0].Score -ge 1) { return $nsCands[0].Id }
    $any = @($cands | Sort-Object Score -Descending)
    if ($any.Count -and $any[0].Score -ge 2) { return $any[0].Id }
    return $null
}

function Save-KeepitFailedItems {
    <#
    .SYNOPSIS
        Downloads the items that failed in a previous Keepit restore job as a ZIP,
        instead of restoring them back into Microsoft 365.

    .DESCRIPTION
        Companion to Restore-KeepitFailedItems. Where the retry cmdlet re-runs a
        restore in place, this reads the job's skipped-item list, resolves each
        failed file to its backup item, and downloads the backed-up contents as a
        single ZIP on local disk - with the files laid out in a folder tree that
        mirrors their original location.

        Because it reads straight from the backup snapshot it needs no target site
        and no live source, never provisions anything, and makes NO changes to
        Microsoft 365. This is the reliable fallback for failures that cannot be
        retried in place (for example a whole-site SharePoint restore that was
        relocated to a new URL).

        Coverage: SharePoint / Teams (Groups) / OneDrive document files download
        cleanly. Failed items are matched to their backup by workload (the failure
        path's leading segment) plus path tail, so a name that exists in several
        places resolves to the workload named in the failure. Non-file failures
        (list items, pages, folders, structural entries) are reported as skipped.

    .PARAMETER JobGuid
        The failed restore job to pull skipped items from.

    .PARAMETER Connector
        Connector GUID (or name) the job ran on. Aliases: ConnectorGuid, Name.

    .PARAMETER ReportPath
        Path to a Job Report CSV to use as the failed-item source instead of the
        live job log (for jobs whose 30-day skipped log has aged out).

    .PARAMETER OutputPath
        Directory (or full .zip path) for the download. Defaults to the current
        directory; a timestamped file name is generated when a directory is given.

    .PARAMETER IncludeCause
        Only download failures whose cause matches one of these wildcard patterns
        (e.g. '*507*', '*quota*').

    .PARAMETER ExcludeCause
        Skip failures whose cause matches one of these wildcard patterns.

    .PARAMETER TimeoutSec
        Max seconds to wait for a download to be ready. Default 300.

    .PARAMETER Credential
        Keepit credential. When omitted, the cached Connect-KeepitService session
        is used.

    .EXAMPLE
        Save-KeepitFailedItems -JobGuid abc123-... -Connector '2 Sandbox M365' -OutputPath ~/Downloads

    .EXAMPLE
        Save-KeepitFailedItems -JobGuid abc123-... -Connector abc123-... -IncludeCause '*507*' -WhatIf

    .OUTPUTS
        PSCustomObject with the job, snapshot, counts (RequestedCount,
        DownloadedCount, Unresolved, NotDownloadable), Batches, ZipPath and SizeBytes.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Job')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Job')]
        [ValidateNotNullOrEmpty()]
        [string]$JobGuid,

        [Parameter(Mandatory, ParameterSetName = 'Job', ValueFromPipelineByPropertyName)]
        [Parameter(Mandatory, ParameterSetName = 'Report', ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector,

        [Parameter(Mandatory, ParameterSetName = 'Report')]
        [ValidateNotNullOrEmpty()]
        [string]$ReportPath,

        [Parameter()] [string]$OutputPath = (Get-Location).Path,
        [Parameter()] [string[]]$IncludeCause,
        [Parameter()] [string[]]$ExcludeCause,
        [Parameter()] [ValidateRange(1, 3600)] [int]$TimeoutSec = 300,
        [Parameter()] [PSCredential]$Credential
    )

    begin {
        try {
            $authHeader = Get-AuthHeader -Credential $Credential
            $baseUrl    = Get-KeepitBaseUrl
            $userId     = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl
        }
        catch { throw }
    }

    process {
        try {
            # --- Connector + job + failed list --------------------------------
            $reportItems = $null
            if ($PSCmdlet.ParameterSetName -eq 'Report') {
                if (-not (Test-Path -LiteralPath $ReportPath)) { throw "Report file not found: $ReportPath" }
                $reportItems = @(ConvertFrom-KeepitJobReport -CsvText (Get-Content -LiteralPath $ReportPath))
                if ($reportItems.Count -eq 0) { Write-Warning "No failed items found in report '$ReportPath'."; return }
                $connectorInput = ($reportItems | Select-Object -First 1).ConnectorGuid
                $JobGuid        = ($reportItems | Select-Object -First 1).JobGuid
            }
            else {
                $connectorInput = $Connector
            }

            $resolvedConn  = Resolve-KeepitConnectorIdentity -Identity $connectorInput
            $connectorGuid = $resolvedConn.ConnectorGuid
            Write-Verbose "Connector: $($resolvedConn.Name) ($connectorGuid); Job: $JobGuid"

            $job = Get-KeepitJobDetail -ConnectorGuid $connectorGuid -JobGuid $JobGuid `
                -BaseUrl $baseUrl -UserId $userId -AuthHeader $authHeader
            if (-not $job.Snaptime) { throw "Job $JobGuid has no snaptime; cannot locate its backup items." }

            if ($null -ne $reportItems) {
                $failed = $reportItems
            }
            else {
                $finished = if ($job.Failed) { $job.Failed } elseif ($job.Succeeded) { $job.Succeeded } else { $null }
                if (-not $job.Started -or -not $finished) { throw "Job $JobGuid is missing started/finished times needed to query failures." }
                $failed = @(Get-KeepitJobFailedItems -JobGuid $JobGuid -Started $job.Started -Finished $finished `
                    -BaseUrl $baseUrl -UserId $userId -AuthHeader $authHeader)
            }

            # --- Cause filtering ---------------------------------------------
            if ($IncludeCause) { $failed = @($failed | Where-Object { $c = $_.Cause; $IncludeCause | Where-Object { $c -like $_ } }) }
            if ($ExcludeCause) { $failed = @($failed | Where-Object { $c = $_.Cause; -not ($ExcludeCause | Where-Object { $c -like $_ }) }) }

            # Only file failures are downloadable; count the rest as skipped.
            $fileItems = @($failed | Where-Object { $_.Kind -eq 'file' })
            $notDownloadable = @($failed).Count - $fileItems.Count

            # Deduplicate by path (the log lists items several times).
            $unique = $fileItems | Sort-Object ItemPath -Unique
            $requested = @($unique).Count
            if ($requested -eq 0) {
                Write-Warning "No downloadable failed files for job $JobGuid (after filtering). Non-file failures skipped: $notDownloadable."
                return
            }

            # --- Resolve each failed path to a backup item id -----------------
            $resolved   = [System.Collections.Generic.List[object]]::new()
            $unresolved = [System.Collections.Generic.List[string]]::new()
            foreach ($it in $unique) {
                $id = Resolve-KeepitBackupItemId -DisplayPath $it.ItemPath -ConnectorGuid $connectorGuid `
                    -Snaptime $job.Snaptime -BaseUrl $baseUrl -UserId $userId -AuthHeader $authHeader
                if ($id) { $resolved.Add([pscustomobject]@{ Id = $id; Display = $it.ItemPath; Leaf = $it.FileName }) | Out-Null }
                else { $unresolved.Add($it.ItemPath) | Out-Null }
            }
            if ($resolved.Count -eq 0) {
                Write-Warning "Could not locate any failed items in snapshot $($job.Snaptime) for job $JobGuid."
                return
            }

            # --- Output ZIP path ---------------------------------------------
            $zipPath = $OutputPath
            if ((Test-Path -LiteralPath $OutputPath -PathType Container) -or -not $OutputPath.ToLower().EndsWith('.zip')) {
                $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
                $short = ($JobGuid -split '-')[0]
                $zipPath = Join-Path $OutputPath "KeepitFailedItems_${short}_${stamp}.zip"
            }

            # --- Batch so no two items in a request share a leaf name ---------
            # The server ZIP is flat (entries named by leaf only), so a unique-leaf
            # batch lets each entry map unambiguously back to its item.
            $batches = [System.Collections.Generic.List[object]]::new()
            foreach ($ri in $resolved) {
                $leafKey = $ri.Leaf.ToLower(); $target = $null
                foreach ($b in $batches) { if (-not $b.Leaves.Contains($leafKey)) { $target = $b; break } }
                if (-not $target) {
                    $target = @{ Items = [System.Collections.Generic.List[object]]::new(); Leaves = [System.Collections.Generic.HashSet[string]]::new() }
                    $batches.Add($target) | Out-Null
                }
                $target.Items.Add($ri) | Out-Null; [void]$target.Leaves.Add($leafKey)
            }

            if (-not $PSCmdlet.ShouldProcess($zipPath, "Download $($resolved.Count) failed item(s) from job $JobGuid")) {
                return [pscustomobject]@{
                    JobGuid = $JobGuid; ConnectorGuid = $connectorGuid; SnapshotTstamp = $job.Snaptime
                    RequestedCount = $requested; DownloadedCount = 0; Unresolved = $unresolved.Count
                    NotDownloadable = $notDownloadable; Batches = $batches.Count; ZipPath = $zipPath; Mode = 'WhatIf'
                }
            }

            # --- Download each batch, lay out a folder tree, then re-zip ------
            $invalidChars = [IO.Path]::GetInvalidFileNameChars()
            $staging = Join-Path ([IO.Path]::GetTempPath()) ("keepitdl_" + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Force -Path $staging | Out-Null
            $written = 0
            try {
                foreach ($b in $batches) {
                    $idXml = ($b.Items | ForEach-Object { "<id>$([System.Security.SecurityElement]::Escape($_.Id))</id>" }) -join ''
                    $body = "<?xml version=`"1.0`" ?>`n<config><type>zip</type><snapshot><tstamp>$($job.Snaptime)</tstamp>$idXml</snapshot></config>"
                    $post = Invoke-WebRequest -Uri "$baseUrl/users/$userId/devices/$connectorGuid/downloads" -Method Post `
                        -Headers @{ Authorization = $authHeader; 'Content-Type' = 'application/xml' } -Body $body -TimeoutSec 60 -ErrorAction Stop
                    $location = $post.Headers['location']; if ($location -is [array]) { $location = $location[0] }
                    if (-not $location) { throw "Download request returned no URL (status $($post.StatusCode))." }
                    $downloadUrl = "$baseUrl$location`?cd"

                    $deadline = (Get-Date).AddSeconds($TimeoutSec); $bytes = $null
                    while ((Get-Date) -lt $deadline) {
                        $dl = Invoke-WebRequest -Uri $downloadUrl -TimeoutSec 120 -SkipHttpErrorCheck
                        if ($dl.StatusCode -eq 200) { $bytes = $dl.Content; break }
                        Write-Verbose "Download not ready (status $($dl.StatusCode)); retrying..."
                        Start-Sleep -Seconds 5
                    }
                    if (-not $bytes) { throw "A download did not become ready within $TimeoutSec s: $downloadUrl" }

                    $ms = [IO.MemoryStream]::new($bytes)
                    $za = [IO.Compression.ZipArchive]::new($ms, [IO.Compression.ZipArchiveMode]::Read)
                    try {
                        foreach ($entry in $za.Entries) {
                            if ([string]::IsNullOrEmpty($entry.Name)) { continue }
                            $item = $b.Items | Where-Object { $_.Leaf.ToLower() -eq $entry.Name.ToLower() } | Select-Object -First 1
                            if ($item) {
                                $ds = @($item.Display.Trim('/') -split '/')
                                $dirSegs = if ($ds.Count -gt 1) { $ds[0..($ds.Count - 2)] } else { @() }
                                $relDir = ($dirSegs | ForEach-Object { $s = $_; foreach ($c in $invalidChars) { $s = $s.Replace($c, '_') }; $s }) -join [IO.Path]::DirectorySeparatorChar
                            }
                            else { $relDir = '_unmatched' }
                            $destDir = if ($relDir) { Join-Path $staging $relDir } else { $staging }
                            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
                            $safeName = $entry.Name; foreach ($c in $invalidChars) { $safeName = $safeName.Replace($c, '_') }
                            $es = $entry.Open(); $fs = [IO.File]::Create((Join-Path $destDir $safeName))
                            try { $es.CopyTo($fs) } finally { $fs.Dispose(); $es.Dispose() }
                            $written++
                        }
                    }
                    finally { $za.Dispose(); $ms.Dispose() }
                }

                if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
                [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zipPath)
            }
            finally {
                if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
            }

            if ($unresolved.Count) { Write-Warning "$($unresolved.Count) failed item(s) could not be located and were not included." }
            if ($notDownloadable)  { Write-Warning "$notDownloadable non-file failure(s) are not downloadable and were skipped." }

            [pscustomobject]@{
                JobGuid         = $JobGuid
                ConnectorGuid   = $connectorGuid
                SnapshotTstamp  = $job.Snaptime
                RequestedCount  = $requested
                DownloadedCount = $written
                Unresolved      = $unresolved.Count
                NotDownloadable = $notDownloadable
                Batches         = $batches.Count
                ZipPath         = $zipPath
                SizeBytes       = (Get-Item -LiteralPath $zipPath).Length
            }
        }
        catch { throw }
    }
}
