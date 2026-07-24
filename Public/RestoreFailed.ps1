# Restore-KeepitFailedItems and supporting private helpers.
#
# Retries the items that failed in a previous Keepit restore job. The list of
# failures and the snapshot to restore from are recovered from the platform:
#   - GET  .../jobs/{job}            -> snaptime, scope, exec summary, RestoreConfig (paths + modes)
#   - PUT  /users/{uid}/log/filter   -> failed ("skipped") items as CSV (Accept: text/csv)
#   - snaptime -> SnapshotId via an EXACT-timestamp snapshot match
# The failed-item display paths are reconciled onto the job's RestoreConfig path
# namespace (the authoritative namespace the restore engine uses) and resubmitted.

# --- Private: parse one job-report / log CSV message into a failed item -------

function ConvertFrom-KeepitFailureMessage {
    <#
    .SYNOPSIS
        Parses a Keepit "/uservisiblemsg" failure message into action, path and cause.
        Internal helper; not exported. Returns $null for non-failure messages.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Message)

    # Strip the leading "/uservisiblemsg: " marker if present.
    $m = $Message -replace '^\s*/uservisiblemsg:\s*', ''

    # Pattern-based and extensible: one matcher per known wording. The item path
    # is everything between the verb and the trailing ". Cause: ...".
    #   "Failed to restore file: <path>. Cause: CODE:507"
    #   "Failed to get file: <path>"      (no cause)
    $rx = '^Failed to (?<action>\w+) (?<kind>file|message|item|folder):\s*(?<path>.+?)(?:\.\s*Cause:\s*(?<cause>.+))?$'
    $match = [regex]::Match($m, $rx)
    if (-not $match.Success) { return $null }

    $path = $match.Groups['path'].Value.Trim()

    # SharePoint reports a secondary "<file>.<ext> Fields" failure for a file's
    # list-item metadata ("Cause: Corresponding file was not restored"). Normalize
    # it to the underlying file so it deduplicates with the file's own failure.
    if ($path -match '^(?<base>.+\.[A-Za-z0-9]+) Fields$') { $path = $matches['base'] }
    [PSCustomObject]@{
        Action   = $match.Groups['action'].Value
        Kind     = $match.Groups['kind'].Value
        ItemPath = $path
        FileName = ($path -split '/')[-1]
        Cause    = if ($match.Groups['cause'].Success) { $match.Groups['cause'].Value.Trim() } else { $null }
        Message  = $Message
    }
}

# --- Private: turn CSV rows (from API or file) into failed-item objects --------

function ConvertFrom-KeepitJobReport {
    <#
    .SYNOPSIS
        Converts Keepit job-report / log CSV text into failed-item objects.
        Internal helper; not exported. Accepts the CSV produced by the admin-center
        Job Report export or by the log/filter API. Only "Failed to ..." rows are
        returned.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory)] [string[]]$CsvText)

    $rows = $CsvText | ConvertFrom-Csv
    foreach ($row in $rows) {
        $msg = if ($null -ne $row.message) { $row.message } else { '' }
        $parsed = ConvertFrom-KeepitFailureMessage -Message $msg
        if (-not $parsed) { continue }
        [PSCustomObject]@{
            Time          = $row.time
            Account       = $row.account
            ConnectorGuid = $row.device
            JobGuid       = $row.job
            Action        = $parsed.Action
            Kind          = $parsed.Kind
            ItemPath      = $parsed.ItemPath
            FileName      = $parsed.FileName
            Cause         = $parsed.Cause
            Message       = $msg
        }
    }
}

# --- Private: GET a single job, including its RestoreConfig --------------------

function Get-KeepitJobDetail {
    <#
    .SYNOPSIS
        Retrieves one job (GET .../jobs/{job}) with its restore configuration.
        Internal helper; not exported.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string]$ConnectorGuid,
        [Parameter(Mandatory)] [string]$JobGuid,
        [Parameter(Mandatory)] [string]$BaseUrl,
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$AuthHeader
    )

    $uri = "$BaseUrl/users/$UserId/devices/$ConnectorGuid/jobs/$JobGuid"
    $headers = @{ Authorization = $AuthHeader; Accept = 'application/vnd.keepit.v4+xml' }
    $resp = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
    [xml]$xml = $resp.Content
    $job = $xml.job

    # Exec summary is an escaped XML string; pull the <summary> text out of it.
    $summary = $null
    if ($job.execsummary) {
        $em = [regex]::Match([string]$job.execsummary, '<summary>(?<s>[^<]+)</summary>')
        if ($em.Success) { $summary = $em.Groups['s'].Value }
    }

    $rc = $job.commands.restore.RestoreConfig
    $paths = @()
    if ($rc -and $rc.Rules.RestorePaths.Path) { $paths = @($rc.Rules.RestorePaths.Path) }
    $mode = if ($rc) { $rc.Rules.Mode } else { $null }

    [PSCustomObject]@{
        JobGuid          = [string]$job.guid
        Type             = [string]$job.type
        Description      = [string]$job.description
        Summary          = $summary
        Started          = [string]$job.started
        Failed           = [string]$job.failed
        Succeeded        = [string]$job.succeeded
        Snaptime         = [string]$job.snaptime
        Scope            = [string]$job.scope
        RestorePaths     = $paths
        RestoreConfigXml = if ($rc) { $rc.OuterXml } else { $null }
        FolderRestoreMode         = if ($mode) { [string]$mode.FolderRestoreMode } else { 'DeltaAppend' }
        FileConflictResolutionMode = if ($mode) { [string]$mode.FileConflictResolutionMode } else { 'Restore' }
        Method                     = if ($mode) { [string]$mode.Method } else { 'InPlace' }
    }
}

# --- Private: resolve a snaptime to a SnapshotId by EXACT timestamp match ------

function Resolve-KeepitSnapshotByTime {
    <#
    .SYNOPSIS
        Resolves a snapshot creation time (snaptime) to a SnapshotId by exact match.
        Internal helper; not exported. A plain reverse-search returns the PREVIOUS
        snapshot because the range upper bound is exclusive, so we bracket the time
        and match Timestamp == snaptime.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$ConnectorGuid,
        [Parameter(Mandatory)] [string]$Snaptime
    )
    $target = [datetime]::Parse($Snaptime, [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()

    $cands = @(Get-KeepitSnapshot -Connector $ConnectorGuid `
        -StartTime $target.AddMinutes(-5) -EndTime $target.AddMinutes(5) -WarningAction SilentlyContinue)

    foreach ($s in $cands) {
        $ts = [datetime]::Parse($s.Timestamp, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if (([math]::Abs(($ts - $target).TotalSeconds)) -lt 1) { return $s.Id }
    }
    return $null
}

# --- Private: read the failed ("skipped") items for a job via log/filter -------

function Get-KeepitJobFailedItems {
    <#
    .SYNOPSIS
        Queries the failed items for a job via PUT /users/{uid}/log/filter (text/csv).
        Internal helper; not exported.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string]$JobGuid,
        [Parameter(Mandatory)] [string]$Started,
        [Parameter(Mandatory)] [string]$Finished,
        [Parameter(Mandatory)] [string]$BaseUrl,
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$AuthHeader
    )
    $body = @"
<?xml version="1.0" encoding="UTF-8"?>
<and>
  <contains><arg>job</arg><arg>$JobGuid</arg></contains>
  <equal><arg>path</arg><arg>/uservisiblemsg</arg></equal>
  <submatch><arg>text</arg><arg>"Failed to"</arg></submatch>
  <greater><arg>$Finished</arg><arg>time</arg><arg>$Started</arg></greater>
</and>
"@
    $headers = @{ Authorization = $AuthHeader; Accept = 'text/csv'; 'Content-Type' = 'application/xml' }
    $resp = Invoke-WebRequest -Uri "$BaseUrl/users/$UserId/log/filter" -Method Put -Headers $headers -Body $body -ErrorAction Stop
    $text = if ($resp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($resp.Content) } else { [string]$resp.Content }
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    ConvertFrom-KeepitJobReport -CsvText ($text -split "`r?`n")
}

# --- Private: graft a failed display path onto a RestoreConfig scope path ------

function Resolve-KeepitRetryPath {
    <#
    .SYNOPSIS
        Maps a failed item's display path onto the job's internal RestoreConfig
        path namespace. Internal helper; not exported. Aligns on the longest
        trailing segment-run of a scope folder that appears in the display path,
        then appends the remainder. The scope path from the RestoreConfig is
        already in masked form (e.g. doubled dashes); the appended remainder comes
        from the display log and must be masked too. Returns $null if no scope
        path matches.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$DisplayPath,
        [Parameter(Mandatory)] [string[]]$ScopePaths
    )
    foreach ($scope in $ScopePaths) {
        $segs = $scope.Trim('/') -split '/'
        # Try the longest trailing run of scope segments first (most specific).
        for ($take = $segs.Count; $take -ge 1; $take--) {
            $suffix = '/' + (($segs[($segs.Count - $take)..($segs.Count - 1)]) -join '/') + '/'
            $idx = $DisplayPath.IndexOf($suffix, [System.StringComparison]::OrdinalIgnoreCase)
            if ($idx -ge 0) {
                $remainder = $DisplayPath.Substring($idx + $suffix.Length).TrimStart('/')
                if ($remainder) {
                    # Mask only the display-derived remainder; the scope folder is
                    # already masked and ConvertTo-MaskedPath would double-escape it.
                    $maskedRemainder = ConvertTo-MaskedPath -Path $remainder
                    return ($scope.TrimEnd('/') + '/' + $maskedRemainder)
                }
            }
        }
    }
    return $null
}

# --- Private: find the real GUID of a just-submitted job by its description ----

function Resolve-KeepitSubmittedJobGuid {
    <#
    .SYNOPSIS
        Looks up the GUID of a job we just submitted, by matching its (unique)
        description in the job history. The srestore POST does not echo a usable
        GUID, so Submit-KeepitJob returns a placeholder; this recovers the real one.
        Internal helper; not exported. Returns $null if not found.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$ConnectorGuid,
        [Parameter(Mandatory)] [string]$Description,
        [Parameter(Mandatory)] [datetime]$Since
    )
    $start = $Since.ToUniversalTime().AddMinutes(-2)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $end = [DateTime]::UtcNow.AddMinutes(2)
        try {
            $candidates = @(Get-KeepitJobs -Connector $ConnectorGuid -StartTime $start -EndTime $end -WarningAction SilentlyContinue |
                Where-Object { $_.Description -eq $Description })
            if ($candidates.Count -gt 0) {
                return ($candidates | Sort-Object { if ($_.Start) { [datetime]$_.Start } else { [datetime]::MinValue } } -Descending |
                    Select-Object -First 1).JobGuid
            }
        }
        catch { Write-Verbose "Job-guid lookup attempt $attempt failed: $($_.Exception.Message)" }
        Start-Sleep -Seconds 2
    }
    return $null
}

<#
.SYNOPSIS
    Retries the items that failed in a previous Keepit restore job.
.DESCRIPTION
    Identifies the items that failed in a prior restore job and resubmits a new
    restore job containing only those items, restoring from the same snapshot the
    original job used.

    The failed items, the snapshot, and the restore configuration are all recovered
    from the Keepit platform:
      - the original job (GET .../jobs/{job}) supplies the snapshot creation time
        (snaptime), the restore modes, and the scope path namespace;
      - the failed items are read from the job log (log/filter), or from a Job
        Report CSV exported from the admin center when -ReportPath is used;
      - the snapshot id is resolved from snaptime by exact-timestamp match.

    Only the failed items are restored, into their original location, using the same
    restore modes (e.g. DeltaAppend / InPlace) as the original job.

    Some restore jobs restore a whole scope rather than a list of items and so have
    no per-item paths in their configuration - for example a SharePoint site restore
    (which uses <RestoreSharePoint><Site>), a Salesforce restore, or a whole-mailbox
    restore. For these, the cmdlet retries by re-running the job's own restore
    configuration with the resolved snapshot (a "replay"), which re-runs the entire
    original restore and thereby retries the failed items. -IncludeCause /
    -ExcludeCause do not apply in this case.
.PARAMETER JobGuid
    GUID of the failed restore job to retry. Used with -Connector.
.PARAMETER Connector
    The connector (name or GUID) the job ran on. Aliases: ConnectorGuid, Name.
.PARAMETER ReportPath
    Path to a Job Report CSV exported from the admin center. The connector and job
    GUIDs are read from the CSV; the API is still used to fetch the job's restore
    configuration and snapshot.
.PARAMETER IncludeCause
    Only retry failed items whose cause matches one of these (wildcards allowed),
    e.g. 'CODE:507'.
.PARAMETER ExcludeCause
    Skip failed items whose cause matches one of these (wildcards allowed).
.PARAMETER ShowJobs
    Print the restore job XML that would be / was submitted.
.EXAMPLE
    Restore-KeepitFailedItems -Connector "2 Sandbox Microsoft 365" -JobGuid "41uuom-csg9bg-zu01hz-r8apss" -WhatIf

    Shows the failed items that would be retried, without submitting anything.
.EXAMPLE
    Restore-KeepitFailedItems -ReportPath ./Job_Report.csv -IncludeCause 'CODE:507'

    Retries only the items that failed with Microsoft 'Insufficient Storage' (507).
.OUTPUTS
    With -WhatIf: a summary object. Without: the submitted restore job result(s).
.NOTES
    Requires an active connection via Connect-KeepitService. Items are restored
    in-place to their original location.

    Retries are only possible within about 30 days of the original failure:
    Keepit retains the skipped-items log (the source of the failed-item list) for
    roughly 30 days. After that the failed-item list is no longer available, even
    if the job and its snapshot still exist, and the job cannot be retried.
#>
function Restore-KeepitFailedItems {
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Job')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Job')]
        [ValidateNotNullOrEmpty()]
        [string]$JobGuid,

        [Parameter(Mandatory, ParameterSetName = 'Job', ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector,

        [Parameter(Mandatory, ParameterSetName = 'Report')]
        [ValidateNotNullOrEmpty()]
        [string]$ReportPath,

        [Parameter()] [string[]]$IncludeCause,
        [Parameter()] [string[]]$ExcludeCause,
        [Parameter()] [switch]$ShowJobs
    )

    begin {
        try {
            $authHeader = Get-AuthHeader
            $baseUrl    = Get-KeepitBaseUrl
            $userId     = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl
        }
        catch { throw }
    }

    process {
        try {
            # --- Determine connector + job + (for Report mode) the failed list ---
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

            $resolved      = Resolve-KeepitConnectorIdentity -Identity $connectorInput
            $connectorGuid = $resolved.ConnectorGuid
            Write-Verbose "Connector: $($resolved.Name) ($connectorGuid); Job: $JobGuid"

            # --- Fetch the original job (snaptime, modes, scope paths) ---
            $job = Get-KeepitJobDetail -ConnectorGuid $connectorGuid -JobGuid $JobGuid `
                -BaseUrl $baseUrl -UserId $userId -AuthHeader $authHeader

            if ($job.Type -notin @('restore', 'srestore')) {
                Write-Warning "Job $JobGuid is type '$($job.Type)', not a restore job."
            }
            if ($job.Summary -and $job.Summary -notmatch 'fail|incomplete|unsuccess') {
                Write-Warning "Job $JobGuid summary is '$($job.Summary)' - it may not have failed items."
            }
            if (-not $job.Snaptime) { throw "Job $JobGuid has no snaptime; cannot resolve a snapshot." }

            # Whole-scope restores (a SharePoint site restore, Salesforce, a whole
            # mailbox, etc.) do not use per-item <RestorePaths> in their RestoreConfig
            # (SharePoint sites use <RestoreSharePoint><Site>...</Site>), so there is
            # nothing to map failed items onto. Retry them by re-running the job's own
            # RestoreConfig with the resolved snapshot (replay).
            if (-not $job.RestorePaths -or $job.RestorePaths.Count -eq 0) {
                if (-not $job.RestoreConfigXml) {
                    throw "Job $JobGuid has no restore configuration; cannot retry."
                }

                # A whole-site restore that was RELOCATED to a new URL cannot be retried
                # by replay: the engine re-provisions the destination site and fails with
                # "a site already exists at url ..." once it exists (which it does after the
                # original run, even a partial one). Decline rather than submit a job that
                # is guaranteed to fail.
                if ($job.RestoreConfigXml -match '<UrlToRelocate>') {
                    $relocTarget = ([regex]::Match($job.RestoreConfigXml, '<UrlToRelocate>(?<u>[^<]+)</UrlToRelocate>')).Groups['u'].Value
                    Write-Warning ("Job $JobGuid restored a whole site relocated to '$relocTarget'. A relocated " +
                        "whole-site restore cannot be retried by re-running it, because the destination site already " +
                        "exists and the restore engine cannot re-create it. Re-run it from the admin center's Job Monitor " +
                        "into a fresh or empty target, or download the failed items with Save-KeepitFailedItems.")
                    return
                }

                if ($IncludeCause -or $ExcludeCause) {
                    Write-Warning "Job $JobGuid is a whole-scope restore (no per-item paths); it is retried by re-running the original restore, so -IncludeCause/-ExcludeCause do not apply."
                }

                # Best-effort list of what failed originally, for the preview only.
                $failedForPreview = @()
                if ($null -ne $reportItems) {
                    $failedForPreview = @($reportItems)
                }
                else {
                    $finished = if ($job.Failed) { $job.Failed } elseif ($job.Succeeded) { $job.Succeeded } else { $null }
                    if ($job.Started -and $finished) {
                        try {
                            $failedForPreview = @(Get-KeepitJobFailedItems -JobGuid $JobGuid -Started $job.Started -Finished $finished `
                                -BaseUrl $baseUrl -UserId $userId -AuthHeader $authHeader)
                        }
                        catch { }
                    }
                }

                # Resolve the snapshot and substitute it for the #HASH# placeholder.
                $snapshotId = Resolve-KeepitSnapshotByTime -ConnectorGuid $connectorGuid -Snaptime $job.Snaptime
                if (-not $snapshotId) { throw "Could not resolve a snapshot for snaptime '$($job.Snaptime)' on connector $connectorGuid." }
                $replayConfig = $job.RestoreConfigXml -replace '<SnapshotId>[^<]*</SnapshotId>', "<SnapshotId>$snapshotId</SnapshotId>"
                $desc = "[srestore] [KeepitPSTools][retry] Re-run restore for job $JobGuid"
                $replayXml = "<job><description>$([System.Security.SecurityElement]::Escape($desc))</description><type>$($job.Type)</type><immediate/><priority>1</priority><commands><restore>$replayConfig</restore></commands></job>"

                if ($WhatIfPreference) {
                    Write-Host "WhatIf: Would re-run the original restore for job $JobGuid (whole scope) from snapshot $snapshotId."
                    Write-Host "  This restore has no per-item paths (for example a SharePoint site restore), so the entire original restore is re-run - not just the failed items."
                    if ($failedForPreview.Count -gt 0) {
                        Write-Host "  $($failedForPreview.Count) item(s) failed in the original run:"
                        $failedForPreview | Select-Object -First 25 | ForEach-Object { Write-Host "    ! $($_.ItemPath)" }
                    }
                    if ($ShowJobs) { Write-Host "`nJob XML (replay):"; Write-Host $replayXml }
                    return [PSCustomObject]@{
                        JobGuid    = $JobGuid
                        SnapshotId = $snapshotId
                        Mode       = 'Replay'
                        TotalItems = $failedForPreview.Count
                        JobCount   = 1
                        Unmapped   = 0
                    }
                }

                if ($ShowJobs) { Write-Host "`nJob XML (replay):" -ForegroundColor Cyan; Write-Host $replayXml -ForegroundColor Yellow }
                if ($PSCmdlet.ShouldProcess("connector $connectorGuid", "Re-run original restore for job $JobGuid (whole scope)")) {
                    $submittedAt = [DateTime]::UtcNow
                    $r = Submit-KeepitJob -Connector $connectorGuid -Configuration $replayXml
                    $realGuid = $r.JobGuid
                    if ($r.IsPlaceholderGuid) {
                        $looked = Resolve-KeepitSubmittedJobGuid -ConnectorGuid $connectorGuid -Description $desc -Since $submittedAt
                        if ($looked) { $realGuid = $looked }
                        else { Write-Warning "Submitted replay restore, but could not resolve its GUID from history yet (description: $desc)." }
                    }
                    [PSCustomObject]@{
                        JobGuid       = $realGuid
                        ConnectorGuid = $connectorGuid
                        SourceJobGuid = $JobGuid
                        SnapshotId    = $snapshotId
                        Mode          = 'Replay'
                        ItemCount     = $failedForPreview.Count
                        Status        = $r.Status
                        CreatedAt     = $r.CreatedAt
                    }
                }
                return
            }

            # --- Failed item list (from API log/filter, unless supplied by CSV) ---
            if ($null -ne $reportItems) {
                $failed = $reportItems
            }
            else {
                $finished = if ($job.Failed) { $job.Failed } elseif ($job.Succeeded) { $job.Succeeded } else { $null }
                if (-not $job.Started -or -not $finished) { throw "Job $JobGuid is missing started/finished times needed to query failures." }
                $failed = @(Get-KeepitJobFailedItems -JobGuid $JobGuid -Started $job.Started -Finished $finished `
                    -BaseUrl $baseUrl -UserId $userId -AuthHeader $authHeader)

                # If the job recorded failures but the log query returned nothing, the
                # skipped-items log has aged out (Keepit retains it ~30 days), so the
                # failed-item list can no longer be recovered for this job.
                if ($failed.Count -eq 0 -and $job.Summary -and $job.Summary -match 'fail|incomplete|unsuccess') {
                    $ageNote = ''
                    try {
                        $finishedDt = [datetime]::Parse($finished, [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                        $ageDays = [int][math]::Round(([datetime]::UtcNow - $finishedDt).TotalDays)
                        $ageNote = " It finished about $ageDays day(s) ago."
                    }
                    catch { }
                    Write-Warning ("Job $JobGuid reports failed items (summary: '$($job.Summary)'), but its skipped-items " +
                        "log returned nothing.$ageNote Keepit retains the skipped-items log for about 30 days, so the " +
                        "failed-item list for this job is no longer available and it cannot be retried.")
                    return
                }
            }

            # --- Cause filtering ---
            if ($IncludeCause) {
                $failed = @($failed | Where-Object { $c = $_.Cause; $IncludeCause | Where-Object { $c -like $_ } })
            }
            if ($ExcludeCause) {
                $failed = @($failed | Where-Object { $c = $_.Cause; -not ($ExcludeCause | Where-Object { $c -like $_ }) })
            }
            if ($failed.Count -eq 0) { Write-Warning "No failed items to retry for job $JobGuid (after filtering)."; return }

            # --- Reconcile each failed display path onto the RestoreConfig namespace ---
            # The log can list the same item many times (retries, plus SharePoint
            # "Fields" sub-failures), so deduplicate by the resolved internal path.
            $items = [System.Collections.ArrayList]::new()
            $unmapped = [System.Collections.ArrayList]::new()
            $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($f in $failed) {
                $internal = Resolve-KeepitRetryPath -DisplayPath $f.ItemPath -ScopePaths $job.RestorePaths
                if ($internal) {
                    if ($seen.Add($internal)) {
                        [void]$items.Add([PSCustomObject]@{ Id = $internal; Title = $f.FileName; Cause = $f.Cause; Display = $f.ItemPath })
                    }
                }
                elseif (-not $unmapped.Contains($f.ItemPath)) {
                    [void]$unmapped.Add($f.ItemPath)
                }
            }
            if ($unmapped.Count -gt 0) {
                Write-Warning "$($unmapped.Count) failed item(s) could not be mapped to the job's restore paths and will be skipped:"
                $unmapped | ForEach-Object { Write-Warning "  ? $_" }
            }
            if ($items.Count -eq 0) { Write-Warning "No failed items could be mapped to a restore path; nothing to submit."; return }

            # --- Resolve the snapshot from snaptime (exact match) ---
            $snapshotId = Resolve-KeepitSnapshotByTime -ConnectorGuid $connectorGuid -Snaptime $job.Snaptime
            if (-not $snapshotId) { throw "Could not resolve a snapshot for snaptime '$($job.Snaptime)' on connector $connectorGuid." }
            Write-Verbose "Resolved snapshot: $snapshotId"

            # --- Build batches respecting the XML size limit ---
            # $MaxXmlBatchSize is defined in Restore.ps1; fall back defensively.
            # Build the batch list explicitly: @(, $array) re-flattens a plain
            # object[] and would yield one job per item.
            $maxBatch  = if ($script:MaxXmlBatchSize) { $script:MaxXmlBatchSize } else { 61440 }
            $allItems  = $items.ToArray()
            $estimated = Get-RestoreItemsXmlSize -Items $allItems
            $batches   = [System.Collections.Generic.List[object]]::new()
            if ($estimated -gt $maxBatch) {
                foreach ($b in (Split-RestoreItemsBatches -Items $allItems -MaxSizeBytes $maxBatch)) { $batches.Add($b) }
            }
            else {
                $batches.Add($allItems)
            }

            # --- WhatIf preview ---
            if ($WhatIfPreference) {
                Write-Host "WhatIf: Would retry $($items.Count) failed item(s) from job $JobGuid in $($batches.Count) restore job(s)"
                Write-Host "  Snapshot $snapshotId (snaptime $($job.Snaptime)); mode $($job.FolderRestoreMode)/$($job.Method)"
                foreach ($it in $items) { Write-Host "    + $($it.Id)" }
                if ($ShowJobs) {
                    $bi = 0
                    foreach ($b in $batches) {
                        $bi++
                        $xml = New-KeepitRetryJobXml -SnapshotId $snapshotId -Job $job -Paths (@($b | ForEach-Object { $_.Id })) -ItemCount $b.Count
                        Write-Host "`nJob XML (batch $bi of $($batches.Count)):"; Write-Host $xml
                    }
                }
                return [PSCustomObject]@{
                    JobGuid     = $JobGuid
                    SnapshotId  = $snapshotId
                    TotalItems  = $items.Count
                    JobCount    = $batches.Count
                    Unmapped    = $unmapped.Count
                }
            }

            # --- Submit ---
            $results = [System.Collections.ArrayList]::new()
            $bi = 0
            foreach ($b in $batches) {
                $bi++
                $paths = @($b | ForEach-Object { $_.Id })
                $batchTag = if ($batches.Count -gt 1) { " (batch $bi/$($batches.Count))" } else { '' }
                $desc = "[srestore] [KeepitPSTools][retry] Retry $($b.Count) failed item(s) from job $JobGuid$batchTag"
                $xml = New-KeepitRetryJobXml -SnapshotId $snapshotId -Job $job -Paths $paths -ItemCount $b.Count -Description $desc
                if ($ShowJobs) { Write-Host "`nJob XML (batch $bi of $($batches.Count)):" -ForegroundColor Cyan; Write-Host $xml -ForegroundColor Yellow }
                if ($PSCmdlet.ShouldProcess("connector $connectorGuid", "Retry restore of $($b.Count) failed item(s) from job $JobGuid$batchTag")) {
                    $submittedAt = [DateTime]::UtcNow
                    $r = Submit-KeepitJob -Connector $connectorGuid -Configuration $xml

                    # The srestore POST returns no usable GUID, so Submit-KeepitJob
                    # hands back a placeholder. Recover the real GUID from history.
                    $realGuid = $r.JobGuid
                    if ($r.IsPlaceholderGuid) {
                        $looked = Resolve-KeepitSubmittedJobGuid -ConnectorGuid $connectorGuid -Description $desc -Since $submittedAt
                        if ($looked) { $realGuid = $looked }
                        else { Write-Warning "Submitted retry job, but could not resolve its GUID from history yet (description: $desc)." }
                    }

                    [void]$results.Add([PSCustomObject]@{
                        JobGuid        = $realGuid
                        ConnectorGuid  = $connectorGuid
                        SourceJobGuid  = $JobGuid
                        SnapshotId     = $snapshotId
                        ItemCount      = $b.Count
                        BatchNumber    = if ($batches.Count -gt 1) { $bi } else { $null }
                        Status         = $r.Status
                        CreatedAt      = $r.CreatedAt
                    })
                }
            }
            $results.ToArray()
        }
        catch {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Failed to retry failed items: $($_.Exception.Message)", $_.Exception),
                    'KeepitRetryError',
                    [System.Management.Automation.ErrorCategory]::NotSpecified,
                    $JobGuid
                )
            )
        }
    }
}

# --- Private: build the retry restore-job XML, preserving the original modes ---

function New-KeepitRetryJobXml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$SnapshotId,
        [Parameter(Mandatory)] [PSCustomObject]$Job,
        [Parameter(Mandatory)] [string[]]$Paths,
        [Parameter(Mandatory)] [int]$ItemCount,
        [Parameter()] [string]$Description
    )
    $pathElements = ($Paths | ForEach-Object {
        "<Path>$([System.Security.SecurityElement]::Escape($_))</Path>"
    }) -join ''
    $desc = if ($Description) { [System.Security.SecurityElement]::Escape($Description) }
            else { "[srestore] [KeepitPSTools][retry] Retry $ItemCount failed item(s) from job $($Job.JobGuid)" }
    @"
<job><description>$desc</description><type>srestore</type><immediate/><priority>1</priority><commands><restore><RestoreConfig><SnapshotId>$SnapshotId</SnapshotId><Rules><Mode><FolderRestoreMode>$($Job.FolderRestoreMode)</FolderRestoreMode><FileConflictResolutionMode>$($Job.FileConflictResolutionMode)</FileConflictResolutionMode><Method>$($Job.Method)</Method></Mode><RestorePaths>$pathElements</RestorePaths></Rules></RestoreConfig></restore></commands></job>
"@
}
