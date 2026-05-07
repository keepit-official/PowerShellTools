<#
.DESCRIPTION
    Interactive Keepit O365 Backup Config Manager — pull, bulk-update, and resolve
    O365 connector configs via guided terminal menus. Supports enterprise-scale
    operations with progress tracking, ETA estimates, and audit logging.
    Requires Microsoft.PowerShell.ConsoleGuiTools for interactive account selection.
    No command-line arguments needed.
.USAGE
    .\keepit-o365-config-manager.ps1
.AUTHOR
    Austin
.LASTTESTED
    2026-03-31
#>

#Requires -Modules Microsoft.PowerShell.ConsoleGuiTools

# ============================================================
#  CONSTANTS
# ============================================================
$O365Types = @("o365-admin", "sharepoint", "onedrive", "teams")
$KnownDCs  = @("us-dc", "ca-tr", "au-sy", "uk-ld", "dk-co", "de-fr", "ch-zh")

# Accounts at or below this count get per-device console output;
# above it, only Write-Progress + error summary is shown.
$DetailThreshold = 25

# ============================================================
#  UI HELPER FUNCTIONS
# ============================================================

function Show-Banner {
    $w = 62
    $border = "=" * ($w - 2)

    $lines = @(
        @{ Text = "";                                          Color = "Cyan"     }
        @{ Text = "KEEPIT  O365  CONFIG  MANAGER";             Color = "White"    }
        @{ Text = "";                                          Color = "Cyan"     }
        @{ Text = "Pull, update, and resolve O365 backup";     Color = "Gray"     }
        @{ Text = "connector configurations across accounts";  Color = "Gray"     }
        @{ Text = "";                                          Color = "Cyan"     }
        @{ Text = "v2.1  //  Interactive Mode";                Color = "DarkCyan" }
        @{ Text = "";                                          Color = "Cyan"     }
    )

    Write-Host ""
    Write-Host ("  +" + ("-" * ($w - 2)) + "+") -ForegroundColor Cyan
    foreach ($line in $lines) {
        $t   = $line.Text
        $pad = $w - 2
        if ($t.Length -eq 0) {
            Write-Host ("  |" + (" " * $pad) + "|") -ForegroundColor Cyan
        } else {
            $left  = [math]::Floor(($pad - $t.Length) / 2)
            $right = $pad - $left - $t.Length
            Write-Host "  |" -ForegroundColor Cyan -NoNewline
            Write-Host (" " * $left) -NoNewline
            Write-Host $t -ForegroundColor $line.Color -NoNewline
            Write-Host (" " * $right) -NoNewline
            Write-Host "|" -ForegroundColor Cyan
        }
    }
    Write-Host ("  +" + ("-" * ($w - 2)) + "+") -ForegroundColor Cyan
    Write-Host ""
}

function Show-Step {
    param([int]$Number, [int]$Total, [string]$Title, [string]$Description = "")

    Write-Host ""
    Write-Host "  STEP $Number of $Total" -ForegroundColor DarkCyan -NoNewline
    Write-Host " -- " -ForegroundColor DarkGray -NoNewline
    Write-Host $Title -ForegroundColor White
    Write-Host ("  " + ("-" * 54)) -ForegroundColor DarkGray
    if ($Description) {
        Write-Host "  $Description" -ForegroundColor Gray
        Write-Host ""
    }
}

function Show-Menu {
    param([string]$Title, [string[]]$Options, [string]$Hint = "")

    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("  " + ("-" * $Title.Length)) -ForegroundColor DarkGray
    if ($Hint) {
        Write-Host "  $Hint" -ForegroundColor DarkGray
        Write-Host ""
    }
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  [$($i + 1)] " -ForegroundColor Yellow -NoNewline
        Write-Host $Options[$i]
    }
    Write-Host ""

    while ($true) {
        Write-Host "  > " -ForegroundColor Cyan -NoNewline
        $choice = Read-Host
        if ($choice -match '^\d+$') {
            $n = [int]$choice
            if ($n -ge 1 -and $n -le $Options.Count) { return $n }
        }
        Write-Host "  Invalid choice. Enter 1-$($Options.Count)." -ForegroundColor Red
    }
}

function Read-Input {
    param([string]$Prompt, [string]$Default = "", [switch]$Required)

    $msg = "  $Prompt"
    if ($Default) { $msg += " [default: $Default]" }
    Write-Host $msg -ForegroundColor Cyan

    while ($true) {
        Write-Host "  > " -ForegroundColor Cyan -NoNewline
        $val = Read-Host
        if ([string]::IsNullOrWhiteSpace($val)) {
            if ($Default) { return $Default }
            if ($Required) { Write-Host "  This field is required." -ForegroundColor Red; continue }
            return ""
        }
        return $val.Trim()
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)

    $hint = if ($Default) { "[Y/n]" } else { "[y/N]" }
    Write-Host "  $Prompt $hint" -ForegroundColor Cyan

    while ($true) {
        Write-Host "  > " -ForegroundColor Cyan -NoNewline
        $val = Read-Host
        if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
        if ($val -match '^[Yy]') { return $true }
        if ($val -match '^[Nn]') { return $false }
        Write-Host "  Enter Y or N." -ForegroundColor Red
    }
}

function Show-SummaryBox {
    param([string]$Title, $Stats)

    $lines = @()
    foreach ($key in $Stats.Keys) {
        $lines += "  $key : $($Stats[$key])"
    }

    $maxLen = 0
    foreach ($l in $lines) { if ($l.Length -gt $maxLen) { $maxLen = $l.Length } }
    $w = [math]::Max($maxLen + 4, $Title.Length + 6)

    Write-Host ""
    Write-Host ("  +" + ("=" * ($w - 2)) + "+") -ForegroundColor Green

    $tl = [math]::Floor(($w - 2 - $Title.Length) / 2)
    $tr = $w - 2 - $tl - $Title.Length
    Write-Host ("  |" + (" " * $tl) + $Title + (" " * $tr) + "|") -ForegroundColor Green

    Write-Host ("  +" + ("-" * ($w - 2)) + "+") -ForegroundColor Green

    foreach ($l in $lines) {
        $pr = $w - 2 - $l.Length
        if ($pr -lt 0) { $pr = 0 }
        Write-Host ("  |" + $l + (" " * $pr) + "|") -ForegroundColor White
    }

    Write-Host ("  +" + ("=" * ($w - 2)) + "+") -ForegroundColor Green
    Write-Host ""
}

function Format-Duration {
    param([System.Diagnostics.Stopwatch]$Stopwatch)
    $ts = $Stopwatch.Elapsed
    if ($ts.TotalHours -ge 1) {
        return "{0}h {1}m {2}s" -f [math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds
    }
    if ($ts.TotalMinutes -ge 1) {
        return "{0}m {1}s" -f [math]::Floor($ts.TotalMinutes), $ts.Seconds
    }
    return "{0:N1}s" -f $ts.TotalSeconds
}

function Format-ETA {
    param([System.Diagnostics.Stopwatch]$Stopwatch, [int]$Done, [int]$Total)
    if ($Done -eq 0) { return "calculating..." }
    $avgMs      = $Stopwatch.ElapsedMilliseconds / $Done
    $remainMs   = $avgMs * ($Total - $Done)
    $eta        = [TimeSpan]::FromMilliseconds($remainMs)
    if ($eta.TotalMinutes -ge 1) {
        return "{0}m {1}s remaining" -f [math]::Floor($eta.TotalMinutes), $eta.Seconds
    }
    return "{0}s remaining" -f [math]::Floor($eta.TotalSeconds)
}

function Show-ErrorSummary {
    param([string[]]$Errors, [int]$MaxShow = 10)
    if ($Errors.Count -eq 0) { return }
    Write-Host ""
    Write-Host "  ! $($Errors.Count) error(s) encountered:" -ForegroundColor Yellow
    $Errors | Select-Object -First $MaxShow | ForEach-Object {
        Write-Host "    $_" -ForegroundColor DarkYellow
    }
    if ($Errors.Count -gt $MaxShow) {
        Write-Host "    ... and $($Errors.Count - $MaxShow) more (see audit log)" -ForegroundColor DarkGray
    }
}

# ============================================================
#  CORE HELPER FUNCTIONS
# ============================================================

function Get-BaseUrl([string]$Dc) {
    if ($Dc -eq "ws-test") { return "https://ws-test.keepitqa.com" }
    return "https://$Dc.keepit.com"
}

function Find-AccountDc {
    param([string]$AccountId)

    $checkScript = {
        param($DcCode, $AcctId, $Headers)
        try {
            $null = Invoke-WebRequest -Uri "https://$DcCode.keepit.com/users/$AcctId" `
                                       -Method Get -Headers $Headers -UseBasicParsing -ErrorAction Stop
            return $DcCode
        } catch {
            return $null
        }
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, 7)
    $pool.Open()
    $jobs = @()

    foreach ($dc in $KnownDCs) {
        $ps = [powershell]::Create().AddScript($checkScript)
        $ps.RunspacePool = $pool
        [void]$ps.AddArgument($dc)
        [void]$ps.AddArgument($AccountId)
        [void]$ps.AddArgument($AuthHeader)
        $jobs += @{ PS = $ps; Handle = $ps.BeginInvoke() }
    }

    $found = $null
    foreach ($job in $jobs) {
        $res = $job.PS.EndInvoke($job.Handle)
        $job.PS.Dispose()
        if ($res) { $found = $res }
    }

    $pool.Close()
    $pool.Dispose()
    return $found
}

function Get-SubAccounts {
    param([string]$Dc, [string]$PartnerId)

    $baseUrl = Get-BaseUrl $Dc
    $headers = @{
        "Authorization" = $AuthHeader["Authorization"]
        "Accept"        = "application/vnd.keepit.v1+xml"
    }

    $webResp = Invoke-WebRequest -Uri "$baseUrl/users/$PartnerId/users?max_depth=1" `
                                  -Method Get -Headers $headers -UseBasicParsing -ErrorAction Stop
    $body = $webResp.Content

    if ([string]::IsNullOrWhiteSpace($body)) {
        Write-Host "    (API returned empty body)" -ForegroundColor DarkGray
        return @()
    }

    [xml]$xml = $body

    $subs = @()
    if ($xml.users.user) {
        foreach ($u in @($xml.users.user)) {
            $subs += [PSCustomObject]@{
                dc           = $Dc
                account_id   = [string]$u.id
                company_name = [string]$u.company_name
                email        = [string]$u.email
            }
        }
    }

    # Fallback: if XML dot-access found nothing, try SelectNodes
    if ($subs.Count -eq 0 -and $body -match '<user>') {
        Write-Host "    (dot-access missed elements, falling back to SelectNodes)" -ForegroundColor DarkGray
        $nodes = $xml.SelectNodes("//user")
        foreach ($u in $nodes) {
            $subs += [PSCustomObject]@{
                dc           = $Dc
                account_id   = [string]$u.id
                company_name = [string]$u.company_name
                email        = [string]$u.email
            }
        }
    }

    return $subs
}

function Resolve-GroupIdsForAccounts {
    param([string]$GroupName)

    $showDetail = $Accounts.Count -le $DetailThreshold

    Write-Host "`n  Resolving group '$GroupName' across $($Accounts.Count) account(s)..." -ForegroundColor Cyan

    $pool = [runspacefactory]::CreateRunspacePool(1, 10)
    $pool.Open()
    $jobs = @()

    for ($i = 0; $i -lt $Accounts.Count; $i++) {
        $acct    = $Accounts[$i]
        $baseUrl = Get-BaseUrl $acct.dc

        $ps = [powershell]::Create().AddScript($ResolveGroupScript)
        $ps.RunspacePool = $pool
        [void]$ps.AddArgument($baseUrl)
        [void]$ps.AddArgument($acct.account_id)
        [void]$ps.AddArgument($GroupName)
        [void]$ps.AddArgument($AuthHeader)
        $jobs += @{ PS = $ps; Handle = $ps.BeginInvoke(); Index = $i }
    }

    $resolved = 0
    $counter  = 0
    $sw       = [System.Diagnostics.Stopwatch]::StartNew()
    $errors   = @()

    foreach ($job in $jobs) {
        $res = $job.PS.EndInvoke($job.Handle)
        $job.PS.Dispose()
        $counter++

        $acct = $Accounts[$job.Index]

        if (-not $showDetail) {
            $eta = Format-ETA -Stopwatch $sw -Done $counter -Total $jobs.Count
            Write-Progress -Activity "Resolving group IDs" `
                           -Status "Account $counter of $($jobs.Count) -- $eta" `
                           -PercentComplete ([math]::Floor(($counter / $jobs.Count) * 100))
        }

        if ($res.Status -eq "Resolved") {
            if ($acct.PSObject.Properties.Name -contains 'group_id') {
                $acct.group_id = $res.GroupId
            } else {
                $acct | Add-Member -NotePropertyName 'group_id' -NotePropertyValue $res.GroupId
            }
            $resolved++
            if ($showDetail) {
                Write-Host "    [$counter/$($jobs.Count)] $($acct.account_id) -- $($res.GroupId)" -ForegroundColor Green
            }
        } else {
            $label = if ($res.Error) { "$($res.Status) -- $($res.Error)" } else { $res.Status }
            if ($showDetail) {
                Write-Host "    [$counter/$($jobs.Count)] $($acct.account_id) -- $label" -ForegroundColor Yellow
            }
            if ($res.Error) {
                $errors += "$($acct.account_id): $($res.Error)"
            }
        }
    }

    if (-not $showDetail) {
        Write-Progress -Activity "Resolving group IDs" -Completed
    }

    $pool.Close()
    $pool.Dispose()
    $sw.Stop()

    Show-ErrorSummary -Errors $errors

    $color = if ($resolved -eq $Accounts.Count) { "Green" } else { "Yellow" }
    Write-Host "`n  Resolved $resolved/$($Accounts.Count) account(s) in $(Format-Duration $sw)." -ForegroundColor $color
    return $resolved
}

# ============================================================
#  RUNSPACE SCRIPT BLOCKS
# ============================================================

# --- Fetch one device's attributes (Pull mode) ---
$FetchAttrScript = {
    param($BaseUrl, $AccountId, $DevGuid, $AuthHeaders)

    $result = @{
        Guid           = $DevGuid
        Attributes     = @{}
        NgBackupConfig = $null
        Error          = $null
    }

    try {
        $resp  = Invoke-RestMethod -Uri "$BaseUrl/users/$AccountId/devices/$DevGuid/attributes" `
                                   -Method Get -Headers $AuthHeaders -ContentType "application/xml" -ErrorAction Stop
        $attrs = @()
        if ($resp.attributes -and $resp.attributes.attribute) {
            $attrs = @($resp.attributes.attribute)
        }

        foreach ($attr in $attrs) {
            $name  = [string]$attr.name
            $value = [string]$attr.value

            if ($name -eq "ng_backup_config") {
                try   { $result.NgBackupConfig = $value | ConvertFrom-Json }
                catch { $result.NgBackupConfig = $value }
            }

            $result.Attributes[$name] = $value
        }
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 404) {
            $result.Error = $_.Exception.Message
        }
    }

    return $result
}

# --- Update one device's ExcludeGroups (Update mode) ---
$UpdateDeviceScript = {
    param($BaseUrl, $AccountId, $DevGuid, $DevName, $GroupId, $AuthHeaders, $IsWhatIf, $Action)

    $result = @{
        DeviceGuid = $DevGuid
        DeviceName = $DevName
        Result     = $null
        Error      = $null
    }

    $attrUri = "$BaseUrl/users/$AccountId/devices/$DevGuid/attributes/ng_backup_config"

    try {
        $rawResponse = $null
        try {
            $rawResponse = Invoke-RestMethod -Uri $attrUri -Method Get -Headers $AuthHeaders -ErrorAction Stop
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            if ($statusCode -eq 404) {
                $result.Result = "Skipped-NoConfig"
                return $result
            }
            throw
        }

        if ($rawResponse -is [string]) {
            $config = $rawResponse | ConvertFrom-Json
        } else {
            $config = $rawResponse
        }

        if ($null -eq $config.UserSelectionRules) {
            $config | Add-Member -NotePropertyName 'UserSelectionRules' `
                                 -NotePropertyValue ([PSCustomObject]@{}) -Force
        }
        if ($null -eq $config.UserSelectionRules.ExcludeGroups) {
            $config.UserSelectionRules | Add-Member -NotePropertyName 'ExcludeGroups' `
                                                    -NotePropertyValue @() -Force
        }

        $existing = @($config.UserSelectionRules.ExcludeGroups)

        if ($Action -eq "Remove") {
            if ($existing -notcontains $GroupId) {
                $result.Result = "Skipped-NotPresent"
                return $result
            }
            if ($IsWhatIf) {
                $result.Result = "WouldRemove"
                return $result
            }
            $config.UserSelectionRules.ExcludeGroups = $existing | Where-Object { $_ -ne $GroupId }
        } else {
            if ($existing -contains $GroupId) {
                $result.Result = "Skipped-AlreadyPresent"
                return $result
            }
            if ($IsWhatIf) {
                $result.Result = "WouldAdd"
                return $result
            }
            $config.UserSelectionRules.ExcludeGroups = $existing + @($GroupId)
        }

        $body = $config | ConvertTo-Json -Depth 15 -Compress

        Invoke-RestMethod -Uri $attrUri -Method Put -Headers $AuthHeaders `
                          -Body $body -ContentType "text/plain" -ErrorAction Stop

        $result.Result = "Success"

    } catch {
        $result.Result = "Failed"
        $result.Error  = $_.Exception.Message
    }

    return $result
}

# --- Resolve a group name to ID (Resolve mode) ---
$ResolveGroupScript = {
    param($BaseUrl, $AccountId, $GroupName, $AuthHeaders)

    $result = @{
        GroupId   = $null
        GroupName = $null
        Status    = $null
        Error     = $null
    }

    try {
        $devResp = Invoke-RestMethod -Uri "$BaseUrl/users/$AccountId/devices?all=1" `
                                     -Method Get -Headers $AuthHeaders -ContentType "application/xml" -ErrorAction Stop

        $allDevices = @()
        if ($devResp.devices.cloud) { $allDevices = @($devResp.devices.cloud) }

        $adminDev = $allDevices | Where-Object { $_.type -eq 'o365-admin' } | Select-Object -First 1
        if (-not $adminDev) {
            $result.Status = "Skipped-NoO365Admin"
            return $result
        }

        $groupResp = Invoke-RestMethod -Uri "$BaseUrl/users/$AccountId/devices/$($adminDev.guid)/o365/groups" `
                                       -Method Get -Headers $AuthHeaders -ContentType "application/xml" -ErrorAction Stop

        $groups = @()
        if ($groupResp.groups.group) { $groups = @($groupResp.groups.group) }

        $match = $groups | Where-Object { $_.title -ieq $GroupName } | Select-Object -First 1
        if ($match) {
            $result.GroupId   = [string]$match.id
            $result.GroupName = [string]$match.title
            $result.Status    = "Resolved"
        } else {
            $result.Status = "Skipped-GroupNotFound"
        }
    } catch {
        $result.Status = "Failed"
        $result.Error  = $_.Exception.Message
    }

    return $result
}

# ============================================================
#  PULL MODE
# ============================================================
function Invoke-Pull {
    $sw           = [System.Diagnostics.Stopwatch]::StartNew()
    $allResults   = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    $totalDevices = 0
    $accountIdx   = 0
    $errors       = @()
    $showDetail   = $Accounts.Count -le $DetailThreshold

    if (-not $showDetail) {
        Write-Host "`n  Processing $($Accounts.Count) accounts (progress bar active)..." -ForegroundColor Gray
    }

    foreach ($acct in $Accounts) {
        $dc        = $acct.dc
        $accountId = $acct.account_id
        $baseUrl   = Get-BaseUrl $dc
        $accountIdx++

        if (-not $showDetail) {
            $eta = Format-ETA -Stopwatch $sw -Done ($accountIdx - 1) -Total $Accounts.Count
            Write-Progress -Activity "Pulling O365 configs" `
                           -Status "Account $accountIdx of $($Accounts.Count) ($accountId) -- $eta" `
                           -PercentComplete ([math]::Floor(($accountIdx / $Accounts.Count) * 100))
        } else {
            Write-Host "`n  Account $accountId ($dc)" -ForegroundColor Cyan
        }

        try {
            $devResp = Invoke-RestMethod -Uri "$baseUrl/users/$accountId/devices?all=1" `
                                         -Method Get -Headers $AuthHeader -ContentType "application/xml" -ErrorAction Stop
        } catch {
            $errors += "$accountId ($dc): $($_.Exception.Message)"
            if ($showDetail) { Write-Warning "  Could not fetch devices: $($_.Exception.Message)" }
            continue
        }

        $allDevices = @()
        if ($devResp.devices.cloud) { $allDevices = @($devResp.devices.cloud) }
        if ($allDevices.Count -eq 0) {
            if ($showDetail) { Write-Host "    No devices found." }
            continue
        }

        $o365Devices = $allDevices | Where-Object { $O365Types -contains $_.type }
        if ($o365Devices.Count -eq 0) {
            if ($showDetail) { Write-Host "    No O365 devices found." }
            continue
        }

        if ($showDetail) {
            Write-Host "    $($o365Devices.Count) O365 device(s) -- fetching attributes..." -ForegroundColor Yellow
        }

        # --- Concurrent attribute fetch ---
        $pool    = [runspacefactory]::CreateRunspacePool(1, 10)
        $pool.Open()
        $pending = @()

        foreach ($dev in $o365Devices) {
            $ps = [powershell]::Create().AddScript($FetchAttrScript)
            $ps.RunspacePool = $pool
            [void]$ps.AddArgument($baseUrl)
            [void]$ps.AddArgument($accountId)
            [void]$ps.AddArgument($dev.guid)
            [void]$ps.AddArgument($AuthHeader)
            $pending += @{ PS = $ps; Handle = $ps.BeginInvoke(); Device = $dev }
        }

        foreach ($job in $pending) {
            $attrResult = $job.PS.EndInvoke($job.Handle)
            $job.PS.Dispose()
            $dev = $job.Device

            if ($attrResult.Error) {
                $errors += "$accountId / $($dev.guid): $($attrResult.Error)"
                if ($showDetail) { Write-Warning "    Attr fetch error for $($dev.guid): $($attrResult.Error)" }
            }

            $backupRetention  = if ($dev.'backup-retention')  { ($dev.'backup-retention'  | Out-String).Trim() } else { $null }
            $deletionDeadline = if ($dev.'deletion-deadline') { ($dev.'deletion-deadline' | Out-String).Trim() } else { $null }
            $agentType        = if ($dev.'agent-type')        { ($dev.'agent-type'        | Out-String).Trim() } else { $null }

            $entry = [ordered]@{
                dc                = $dc
                account_id        = $accountId
                device_guid       = [string]$dev.guid
                device_name       = [string]$dev.name
                device_type       = [string]$dev.type
                orglink           = [string]$dev.orglink
                accessible        = [string]$dev.accessible
                backup_retention  = $backupRetention
                deletion_deadline = $deletionDeadline
                agent_type        = $agentType
                ng_backup_config  = $attrResult.NgBackupConfig
                all_attributes    = $attrResult.Attributes
            }
            $allResults.Add($entry)
            $totalDevices++
            if ($showDetail) { Write-Host "      $($dev.name) [$($dev.type)] -- done" -ForegroundColor Green }
        }

        $pool.Close()
        $pool.Dispose()
    }

    if (-not $showDetail) {
        Write-Progress -Activity "Pulling O365 configs" -Completed
    }

    $sw.Stop()

    # --- Save JSON ---
    $allResults | ConvertTo-Json -Depth 15 | Out-File -FilePath $OutputPath -Encoding utf8

    Show-ErrorSummary -Errors $errors

    Show-SummaryBox -Title "Pull Complete" -Stats ([ordered]@{
        "Accounts processed" = $Accounts.Count
        "O365 devices saved" = $totalDevices
        "Errors"             = $errors.Count
        "Duration"           = Format-Duration $sw
        "Output file"        = $OutputPath
    })
}

# ============================================================
#  UPDATE MODE
# ============================================================
function Invoke-Update {
    $sw         = [System.Diagnostics.Stopwatch]::StartNew()
    $timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $auditPath  = if ($IsWhatIf) { "keepit_whatif_$timestamp.csv" } else { "keepit_update_audit_$timestamp.csv" }
    $auditRows  = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    $totalDone  = 0
    $accountIdx = 0
    $errors     = @()
    $showDetail = $Accounts.Count -le $DetailThreshold

    if ($IsWhatIf) {
        Write-Host "`n  [UPDATE -- WHATIF -- $Action] No changes will be made." -ForegroundColor Magenta
    } else {
        Write-Host "`n  [UPDATE -- $Action]" -ForegroundColor Cyan
    }

    if (-not $showDetail) {
        Write-Host "  Processing $($Accounts.Count) accounts (progress bar active)..." -ForegroundColor Gray
    }

    foreach ($acct in $Accounts) {
        $dc        = $acct.dc
        $accountId = $acct.account_id
        $groupId   = $acct.group_id
        $baseUrl   = Get-BaseUrl $dc
        $accountIdx++

        if ([string]::IsNullOrWhiteSpace($groupId)) {
            if ($showDetail) { Write-Warning "  Account $accountId -- no group_id, skipping." }
            continue
        }

        if (-not $showDetail) {
            $eta = Format-ETA -Stopwatch $sw -Done ($accountIdx - 1) -Total $Accounts.Count
            Write-Progress -Activity "Updating O365 configs ($Action)" `
                           -Status "Account $accountIdx of $($Accounts.Count) ($accountId) -- $eta" `
                           -PercentComplete ([math]::Floor(($accountIdx / $Accounts.Count) * 100))
        } else {
            Write-Host "`n  Account $accountId ($dc)  group=$groupId" -ForegroundColor Cyan
        }

        # --- Fetch device list ---
        try {
            $devResp = Invoke-RestMethod -Uri "$baseUrl/users/$accountId/devices?all=1" `
                                         -Method Get -Headers $AuthHeader -ContentType "application/xml" -ErrorAction Stop
        } catch {
            $errors += "$accountId ($dc): $($_.Exception.Message)"
            if ($showDetail) { Write-Warning "  Could not fetch devices: $($_.Exception.Message)" }
            continue
        }

        $allDevices = @()
        if ($devResp.devices.cloud) { $allDevices = @($devResp.devices.cloud) }

        $o365Devices = $allDevices | Where-Object { $O365Types -contains $_.type }
        if ($o365Devices.Count -eq 0) {
            if ($showDetail) { Write-Host "    No O365 devices found." }
            continue
        }

        if ($showDetail) {
            Write-Host "    $($o365Devices.Count) O365 device(s) -- $(if ($IsWhatIf) { 'checking...' } else { 'updating...' })" -ForegroundColor Yellow
        }

        # --- Concurrent update ---
        $pool    = [runspacefactory]::CreateRunspacePool(1, 10)
        $pool.Open()
        $pending = @()

        foreach ($dev in $o365Devices) {
            $ps = [powershell]::Create().AddScript($UpdateDeviceScript)
            $ps.RunspacePool = $pool
            [void]$ps.AddArgument($baseUrl)
            [void]$ps.AddArgument($accountId)
            [void]$ps.AddArgument($dev.guid)
            [void]$ps.AddArgument($dev.name)
            [void]$ps.AddArgument($groupId)
            [void]$ps.AddArgument($AuthHeader)
            [void]$ps.AddArgument([bool]$IsWhatIf)
            [void]$ps.AddArgument($Action)
            $pending += @{ PS = $ps; Handle = $ps.BeginInvoke(); Device = $dev }
        }

        foreach ($job in $pending) {
            $updateResult = $job.PS.EndInvoke($job.Handle)
            $job.PS.Dispose()
            $dev = $job.Device

            if ($showDetail) {
                $color = switch ($updateResult.Result) {
                    "Success"                { "Green"      }
                    "Skipped-AlreadyPresent" { "DarkGray"   }
                    "Skipped-NotPresent"     { "DarkGray"   }
                    "WouldAdd"               { "Yellow"     }
                    "WouldRemove"            { "Yellow"     }
                    "Skipped-NoConfig"       { "DarkYellow" }
                    default                  { "Red"        }
                }
                $label = if ($updateResult.Error) {
                    "$($updateResult.Result) -- $($updateResult.Error)"
                } else {
                    $updateResult.Result
                }
                Write-Host "      $($dev.name) [$($dev.type)] -- $label" -ForegroundColor $color
            }

            if ($updateResult.Error) {
                $errors += "$accountId / $($dev.name): $($updateResult.Error)"
            }

            $auditRows.Add([PSCustomObject]@{
                dc          = $dc
                account_id  = $accountId
                device_guid = [string]$dev.guid
                device_name = [string]$dev.name
                group_id    = $groupId
                result      = $updateResult.Result
                error       = $updateResult.Error
            })
            $totalDone++
        }

        $pool.Close()
        $pool.Dispose()
    }

    if (-not $showDetail) {
        Write-Progress -Activity "Updating O365 configs ($Action)" -Completed
    }

    $sw.Stop()

    # --- Write audit CSV ---
    $auditRows | Export-Csv -Path $auditPath -NoTypeInformation -Encoding utf8

    # --- WhatIf summary table ---
    if ($IsWhatIf) {
        $wouldChange = @($auditRows | Where-Object { $_.result -eq "WouldAdd" -or $_.result -eq "WouldRemove" })
        if ($wouldChange.Count -gt 0) {
            Write-Host "`n  Devices that WOULD be changed ($Action):" -ForegroundColor Yellow
            if ($wouldChange.Count -le 50) {
                $wouldChange | Format-Table dc, account_id, device_name, group_id, result -AutoSize
            } else {
                $wouldChange | Select-Object -First 20 | Format-Table dc, account_id, device_name, group_id, result -AutoSize
                Write-Host "    ... and $($wouldChange.Count - 20) more (see audit CSV)" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "`n  No devices require changes (already in desired state or no config found)." -ForegroundColor Gray
        }
    }

    # --- Stats ---
    $succeeded   = @($auditRows | Where-Object { $_.result -eq "Success" }).Count
    $skipped     = @($auditRows | Where-Object { $_.result -like "Skipped*" }).Count
    $failed      = @($auditRows | Where-Object { $_.result -eq "Failed" }).Count
    $wouldCount  = @($auditRows | Where-Object { $_.result -like "Would*" }).Count

    Show-ErrorSummary -Errors $errors

    if ($IsWhatIf) {
        Show-SummaryBox -Title "WhatIf Preview Complete" -Stats ([ordered]@{
            "Action"          = $Action
            "Devices checked" = $totalDone
            "Would change"    = $wouldCount
            "Already correct" = $skipped
            "Duration"        = Format-Duration $sw
            "Audit log"       = $auditPath
        })
    } else {
        Show-SummaryBox -Title "Update Complete" -Stats ([ordered]@{
            "Action"            = $Action
            "Devices processed" = $totalDone
            "Succeeded"         = $succeeded
            "Skipped"           = $skipped
            "Failed"            = $failed
            "Duration"          = Format-Duration $sw
            "Audit log"         = $auditPath
        })
    }
}

# ============================================================
#  FETCH GROUP IDS MODE
# ============================================================
function Invoke-Resolve {
    $sw          = [System.Diagnostics.Stopwatch]::StartNew()
    $outPath     = "keepit_resolved_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $showDetail  = $Accounts.Count -le $DetailThreshold

    Write-Host "`n  [FETCH GROUP IDS] Looking up group: '$Group'" -ForegroundColor Cyan

    if (-not $showDetail) {
        Write-Host "  Processing $($Accounts.Count) accounts (progress bar active)..." -ForegroundColor Gray
    }

    $pool    = [runspacefactory]::CreateRunspacePool(1, 10)
    $pool.Open()
    $pending = @()
    $idx     = 0

    foreach ($acct in $Accounts) {
        $baseUrl = Get-BaseUrl $acct.dc

        $ps = [powershell]::Create().AddScript($ResolveGroupScript)
        $ps.RunspacePool = $pool
        [void]$ps.AddArgument($baseUrl)
        [void]$ps.AddArgument($acct.account_id)
        [void]$ps.AddArgument($Group)
        [void]$ps.AddArgument($AuthHeader)
        $pending += @{ PS = $ps; Handle = $ps.BeginInvoke(); Dc = $acct.dc; AccountId = $acct.account_id; Index = $idx }
        $idx++
    }

    $rows     = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    $total    = 0
    $resolved = 0
    $errors   = @()

    foreach ($job in $pending) {
        $res = $job.PS.EndInvoke($job.Handle)
        $job.PS.Dispose()
        $total++

        if (-not $showDetail) {
            $eta = Format-ETA -Stopwatch $sw -Done $total -Total $pending.Count
            Write-Progress -Activity "Resolving group IDs" `
                           -Status "Account $total of $($pending.Count) -- $eta" `
                           -PercentComplete ([math]::Floor(($total / $pending.Count) * 100))
        } else {
            $color = switch ($res.Status) {
                "Resolved"              { "Green"    }
                "Skipped-NoO365Admin"   { "DarkGray" }
                "Skipped-GroupNotFound" { "Yellow"   }
                default                 { "Red"      }
            }
            $label = if ($res.Error) { "$($res.Status) -- $($res.Error)" } else { $res.Status }
            Write-Host "    [$total/$($pending.Count)] $($job.AccountId) -- $label" -ForegroundColor $color
        }

        if ($res.Error) {
            $errors += "$($job.AccountId): $($res.Error)"
        }

        # Populate group_id on the in-memory account so subsequent modes can use it
        if ($res.Status -eq "Resolved") {
            $acct = $Accounts[$job.Index]
            if ($acct.PSObject.Properties.Name -contains 'group_id') {
                $acct.group_id = $res.GroupId
            } else {
                $acct | Add-Member -NotePropertyName 'group_id' -NotePropertyValue $res.GroupId
            }
            $resolved++
        }

        $rows.Add([PSCustomObject]@{
            dc         = $job.Dc
            account_id = $job.AccountId
            group_id   = $res.GroupId
            group_name = $res.GroupName
            status     = $res.Status
            error      = $res.Error
        })
    }

    if (-not $showDetail) {
        Write-Progress -Activity "Resolving group IDs" -Completed
    }

    $pool.Close()
    $pool.Dispose()
    $sw.Stop()

    $rows | Export-Csv -Path $outPath -NoTypeInformation -Encoding utf8

    Show-ErrorSummary -Errors $errors

    Show-SummaryBox -Title "Fetch Group IDs Complete" -Stats ([ordered]@{
        "Group searched"   = $Group
        "Accounts matched" = "$resolved / $total"
        "Duration"         = Format-Duration $sw
        "Output file"      = $outPath
    })

    if ($resolved -lt $total) {
        Write-Host "  $($total - $resolved) account(s) did not match (no o365-admin connector or group not found)." -ForegroundColor Yellow
    }

    if ($resolved -gt 0) {
        Write-Host "  Fetched group IDs are loaded in the current session -- available for Update mode." -ForegroundColor Green
    }
}

# ============================================================
#  MAIN INTERACTIVE FLOW
# ============================================================

Show-Banner

# -- Step 1: Authentication -----------------------------------------------
Show-Step -Number 1 -Total 4 -Title "Authentication" `
          -Description "Enter your Keepit portal credentials."
$Creds      = Get-Credential -Message "Enter Keepit credentials"
$UserEmail  = $Creds.UserName
$Password   = $Creds.GetNetworkCredential().Password
$Base64     = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("${UserEmail}:${Password}"))
$AuthHeader = @{ "Authorization" = "Basic $Base64" }
Write-Host "  Authenticated as $UserEmail" -ForegroundColor Green

# -- Step 2: Load Accounts -------------------------------------------------
Show-Step -Number 2 -Total 4 -Title "Load Accounts" `
          -Description "Enter partner account ID, then select which sub-accounts to process."

$Accounts = @()

while ($true) {
    $partnerId = Read-Input -Prompt "Partner account ID" -Required

    Write-Host "`n  Locating account across datacenters..." -ForegroundColor Yellow
    $matchedDc = Find-AccountDc -AccountId $partnerId

    if (-not $matchedDc) {
        Write-Host "  Account not found on any datacenter. Check the ID and try again." -ForegroundColor Red
        continue
    }

    Write-Host "  Account found on $matchedDc.keepit.com" -ForegroundColor Green
    Write-Host "`n  Fetching sub-accounts..." -ForegroundColor Yellow

    try {
        $subs = Get-SubAccounts -Dc $matchedDc -PartnerId $partnerId
    } catch {
        Write-Host "  Error fetching sub-accounts: $($_.Exception.Message)" -ForegroundColor Red
        continue
    }

    if ($subs.Count -eq 0) {
        Write-Host "  No sub-accounts found under this partner." -ForegroundColor Yellow
        continue
    }

    Write-Host "  Found $($subs.Count) sub-account(s) -- opening selection grid..." -ForegroundColor Green
    Write-Host ""
    Write-Host "  Use the grid to filter and select accounts." -ForegroundColor Gray
    Write-Host "  Type to filter  |  SPACE = select  |  ENTER = confirm  |  ESC = cancel" -ForegroundColor DarkGray

    $gridDisplay = foreach ($sub in $subs) {
        [PSCustomObject][ordered]@{
            DC         = [string]$sub.dc
            Account_ID = [string]$sub.account_id
            Company    = [string]$sub.company_name
            Email      = [string]$sub.email
        }
    }

    $selected = $gridDisplay | Out-ConsoleGridView -Title "Select accounts to process ($($subs.Count) available)"

    if (-not $selected -or @($selected).Count -eq 0) {
        Write-Host "  No accounts selected." -ForegroundColor Yellow
        if (Read-YesNo -Prompt "Try a different partner ID?") { continue }
        Write-Host "  Exiting." -ForegroundColor Red
        exit 1
    }

    # Map grid selection back to the original sub-account objects
    $selectedIds = @($selected | ForEach-Object { $_.Account_ID })
    $Accounts = $subs | Where-Object { $selectedIds -contains $_.account_id }

    Write-Host "  Selected $($Accounts.Count) of $($subs.Count) account(s)" -ForegroundColor Green
    break
}

if ($Accounts.Count -eq 0) {
    Write-Host "  No accounts to process." -ForegroundColor Red
    exit 1
}

# -- Mode selection -> config -> execute loop -------------------------------
$runAgain = $true
while ($runAgain) {

    # -- Step 3: Operation Mode ---
    Show-Step -Number 3 -Total 4 -Title "Operation Mode" `
              -Description "Select what you'd like to do with the $($Accounts.Count) loaded account(s)."

    $modeChoice = Show-Menu -Title "Select mode" -Options @(
        "Pull           -- Export all O365 connector configs to JSON"
        "Update         -- Add or remove a security group from ExcludeGroups"
        "Fetch Group IDs -- Look up a group ID by display name across accounts"
    ) -Hint "Typical workflow: Pull to audit, then Fetch Group IDs -> Update"

    $Mode = @("Pull", "Update", "Fetch Group IDs")[$modeChoice - 1]

    # -- Step 4: Mode Configuration ---
    Show-Step -Number 4 -Total 4 -Title "Configuration" `
              -Description "Configure the $Mode operation before execution."

    switch ($Mode) {
        "Pull" {
            $OutputPath = "keepit_o365_configs_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
            Write-Host "  Output will be saved to: $OutputPath" -ForegroundColor Gray
        }
        "Update" {
            $actionChoice = Show-Menu -Title "Update Action" -Options @(
                "Add a group to ExcludeGroups"
                "Remove a group from ExcludeGroups"
            )
            $Action = @("Add", "Remove")[$actionChoice - 1]

            $IsWhatIf = Read-YesNo -Prompt "Run in WhatIf mode (preview only, no changes)?"

            # Check if accounts already have group_id (from prior Fetch Group IDs)
            $hasGroupId = ($Accounts | Where-Object {
                $_.PSObject.Properties.Name -contains 'group_id' -and
                -not [string]::IsNullOrWhiteSpace($_.group_id)
            }).Count -gt 0

            if (-not $hasGroupId) {
                Write-Host ""
                Write-Host "  Accounts don't have group IDs yet -- looking them up by display name." -ForegroundColor Yellow

                $groupName = Read-Input -Prompt "Group display name to search for" -Required
                $resolveCount = Resolve-GroupIdsForAccounts -GroupName $groupName

                if ($resolveCount -eq 0) {
                    Write-Host "  No accounts resolved. Cannot proceed with Update." -ForegroundColor Red
                    Write-Host ""
                    continue   # back to mode selection
                }

                $unresolved = @($Accounts | Where-Object {
                    -not ($_.PSObject.Properties.Name -contains 'group_id') -or
                    [string]::IsNullOrWhiteSpace($_.group_id)
                }).Count

                if ($unresolved -gt 0) {
                    Write-Host "  $unresolved account(s) have no group_id and will be skipped during update." -ForegroundColor Yellow
                }

                if (-not (Read-YesNo -Prompt "Proceed with Update using fetched group IDs?" -Default $true)) {
                    Write-Host ""
                    continue   # back to mode selection
                }
            } else {
                $sampleGid = ($Accounts | Where-Object {
                    $_.PSObject.Properties.Name -contains 'group_id' -and
                    -not [string]::IsNullOrWhiteSpace($_.group_id)
                } | Select-Object -First 1).group_id
                $gidCount = ($Accounts | Where-Object {
                    $_.PSObject.Properties.Name -contains 'group_id' -and
                    -not [string]::IsNullOrWhiteSpace($_.group_id)
                }).Count
                Write-Host "  Using group ID $sampleGid on $gidCount account(s)" -ForegroundColor Green
            }
        }
        "Fetch Group IDs" {
            $Group = Read-Input -Prompt "Group display name to search for" -Required
        }
    }

    # -- Execute ---------------------------------------------------------------
    Write-Host ""
    Write-Host ("  " + ("=" * 54)) -ForegroundColor DarkGray
    Write-Host "  Executing $Mode mode on $($Accounts.Count) account(s)..." -ForegroundColor Cyan
    Write-Host ("  " + ("=" * 54)) -ForegroundColor DarkGray

    switch ($Mode) {
        "Pull"    { Invoke-Pull }
        "Update"  { Invoke-Update }
        "Fetch Group IDs" { Invoke-Resolve }
    }

    # -- Continue? --------------------------------------------------------------
    Write-Host ""
    $runAgain = Read-YesNo -Prompt "Run another operation with the current $($Accounts.Count) account(s)?"
    if ($runAgain) { Write-Host "" }
}

Write-Host "  Done. Goodbye.`n" -ForegroundColor Cyan
