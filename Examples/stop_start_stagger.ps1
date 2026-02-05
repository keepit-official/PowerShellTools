<#
.SYNOPSIS
    Directly interacts with Keepit APIs to manage backup states with device filtering.
    
.DESCRIPTION
    1. Prompts for Credentials (for authentication).
    2. Prompts for a Target Account ID (the account to operate on).
    3. Asks user to "Stop" or "Start" operations.
    4. Finds the target account across all DCs.
    5. Iterates through all devices and provides a selection UI.
    6. IF STOPPING:
       - Sets 'disable_backup' attribute to '1'.
       - Cancels any scheduled, running, or queued jobs.
    7. IF STARTING:
       - Deletes the 'disable_backup' attribute.
       - Offers option to stagger backup jobs.
       - Starts backup jobs with built-in retry logic and time-shifting for robustness.
#>

#Requires -Modules Microsoft.PowerShell.ConsoleGuiTools

# --- Configuration ---
$DataCenters = @("us-dc", "de-fr", "dk-co", "ca-tr", "ch-zh", "au-sy", "uk-ld", "ws-test")
$MaxRetries = 3

# --- 1. Prompt for Credentials ---
Write-Host "Please enter your Keepit credentials (for authentication)..." -ForegroundColor Cyan
$Creds = Get-Credential
$UserEmail = $Creds.UserName
$Password = $Creds.GetNetworkCredential().Password

# Encode Credentials
$Bytes = [System.Text.Encoding]::ASCII.GetBytes("${UserEmail}:${Password}")
$Base64 = [Convert]::ToBase64String($Bytes)
$AuthHeader = @{ "Authorization" = "Basic $Base64" }

# --- 2. Prompt for Target Account ID ---
$TargetAccountId = Read-Host "`nEnter the Target Account ID to operate on"
if ([string]::IsNullOrWhiteSpace($TargetAccountId)) {
    Write-Error "Target Account ID is required."
    exit
}

# --- 3. Prompt for Action ---
do {
    $Action = Read-Host "`nDo you want to STOP jobs (disable backup) or START jobs (enable backup)? (Enter 'Stop' or 'Start')"
} until ($Action -in @("Stop", "Start", "stop", "start"))

$IsStopping = $Action.ToLower() -eq "stop"
$ActionLabel = if ($IsStopping) { "STOPPING (Disable & Cancel)" } else { "STARTING (Enable & Backup)" }

$StaggerInterval = 0
$BatchSize = 1
if (-not $IsStopping) {
    $DoStagger = Read-Host "`nDo you want to stagger the start of these jobs? (y/n)"
    if ($DoStagger -eq 'y') {
        $BatchSize = [int](Read-Host "How many jobs to start per batch? (e.g. 4)")
        $StaggerInterval = [int](Read-Host "Enter interval between batches in minutes (e.g. 30)")

        # --- Mixing Logic (Large/Small) ---
        Write-Host "Re-ordering devices to mix largest and smallest..." -ForegroundColor Cyan
        
        $SortedDevices = $SelectedDevices | Sort-Object { [long]$_.size } -Descending
        $OrderedList = @()
        $LeftIndex = 0
        $RightIndex = $SortedDevices.Count - 1
        $ItemsProcessed = 0
        $TotalItems = $SortedDevices.Count

        while ($ItemsProcessed -lt $TotalItems) {
            $CurrentBatchCount = 0
            while ($CurrentBatchCount -lt $BatchSize -and $ItemsProcessed -lt $TotalItems) {
                # Take 1 from Largest (Left)
                if ($ItemsProcessed -lt $TotalItems) {
                    $OrderedList += $SortedDevices[$LeftIndex]
                    $LeftIndex++
                    $ItemsProcessed++
                    $CurrentBatchCount++
                }
                if ($CurrentBatchCount -ge $BatchSize) { break }
                # Take 1 from Smallest (Right)
                if ($ItemsProcessed -lt $TotalItems) {
                    $OrderedList += $SortedDevices[$RightIndex]
                    $RightIndex--
                    $ItemsProcessed++
                    $CurrentBatchCount++
                }
            }
        }
        $SelectedDevices = $OrderedList
    }
}

Write-Host "`n--- Selected Mode: $ActionLabel ---" -ForegroundColor Magenta

# --- Helper Functions ---

function Invoke-KeepitApiCall {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][string]$Method,
        [hashtable]$Headers,
        [string]$Body,
        [string]$ContentType = "application/xml"
    )

    try {
        $Response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -Body $Body -ContentType $ContentType -ErrorAction Stop
        return $Response
    } catch {
        throw $_
    }
}

function Find-KeepitAccountDC {
    param ([string]$AccountId)
    Write-Host "Locating account '$AccountId' across data centers..." -ForegroundColor Yellow

    foreach ($dc in $DataCenters) {
        $BaseUrl = if ($dc -eq "ws-test") { "https://${dc}.keepitqa.com" } else { "https://${dc}.keepit.com" }
        $Url = "$BaseUrl/users/$AccountId"
        
        try {
            Invoke-KeepitApiCall -Uri $Url -Method Get -Headers $AuthHeader -ContentType "application/xml" | Out-Null
            return @{ AccountId = $AccountId; DcCode = $dc; BaseUrl = $BaseUrl }
        } catch { }
    }
    return $null
}

# --- Main Execution ---

try {
    # 4. Find Account
    $AccountInfo = Find-KeepitAccountDC -AccountId $TargetAccountId
    if (-not $AccountInfo) {
        Write-Error "Account '$TargetAccountId' not found or inaccessible."
        exit
    }

    $AccountId = $AccountInfo.AccountId
    $BaseUrl = $AccountInfo.BaseUrl
    Write-Host "Target Account ID: $AccountId verified in $($AccountInfo.DcCode)" -ForegroundColor Green

    # 5. Get Devices
    Write-Host "Fetching devices..." -ForegroundColor Yellow
    $DevicesUrl = "$BaseUrl/users/$AccountId/devices?all=1"
    $DevicesResponse = Invoke-KeepitApiCall -Uri $DevicesUrl -Method Get -Headers $AuthHeader -ContentType "application/xml"

    $Devices = @()
    if ($DevicesResponse.devices) {
        if ($DevicesResponse.devices.cloud) { $Devices = $DevicesResponse.devices.cloud }
        elseif ($DevicesResponse.devices.device) { $Devices = $DevicesResponse.devices.device }
    }

    if ($Devices.Count -eq 0) { Write-Warning "No devices found."; exit }

    # --- Enrich with Size ---
    Write-Host "Fetching storage size for $($Devices.Count) devices (this ensures proper mixing)..." -ForegroundColor Yellow
    $HistoryHeaders = $AuthHeader.Clone()
    $HistoryHeaders["Accept"] = "application/vnd.keepit.v1+xml"

    # --- Concurrent Size Fetching (20 Workers) ---
    $RunspacePool = [runspacefactory]::CreateRunspacePool(1, 20)
    $RunspacePool.Open()
    $Jobs = @()

    $ScriptBlock = {
        param($BaseUrl, $AccountId, $DevGuid, $Headers)
        $Size = 0
        try {
            $HistUrl = "$BaseUrl/users/$AccountId/devices/$DevGuid/history/latest_imported"
            $HistRes = Invoke-RestMethod -Uri $HistUrl -Method Get -Headers $Headers -ContentType "application/xml" -ErrorAction Stop
            if ($HistRes.history -and $HistRes.history.backup -and $HistRes.history.backup.size) {
                $Size = [long]$HistRes.history.backup.size
            }
        } catch {}
        return @{ Guid = $DevGuid; Size = $Size }
    }

    foreach ($Dev in $Devices) {
        $PSInstance = [powershell]::Create().AddScript($ScriptBlock).AddArgument($BaseUrl).AddArgument($AccountId).AddArgument($Dev.guid).AddArgument($HistoryHeaders)
        $PSInstance.RunspacePool = $RunspacePool
        $Jobs += [PSCustomObject]@{ Pipe = $PSInstance; Status = $PSInstance.BeginInvoke() }
    }

    Write-Host "Waiting for $($Jobs.Count) threads to complete..." -NoNewline
    while ($Jobs.Status.IsCompleted -contains $false) { Start-Sleep -Milliseconds 200 }
    Write-Host " Done." -ForegroundColor Green

    $SizeMap = @{}
    foreach ($Job in $Jobs) {
        try {
            $Res = $Job.Pipe.EndInvoke($Job.Status)
            if ($Res) { $SizeMap[$Res.Guid] = $Res.Size }
        } catch { }
        $Job.Pipe.Dispose()
    }
    
    $RunspacePool.Close()
    $RunspacePool.Dispose()

    foreach ($Dev in $Devices) {
        $s = if ($SizeMap.ContainsKey($Dev.guid)) { $SizeMap[$Dev.guid] } else { 0 }
        $Dev | Add-Member -MemberType NoteProperty -Name "real_size" -Value $s -Force
    }

    # --- Device Selection Logic ---
    $SelectedDevices = $Devices | Select-Object name, guid, type, @{Name='size';Expression={$_.real_size}} | 
        Out-ConsoleGridView -Title "Select Connectors to $Action"

    if (-not $SelectedDevices) { Write-Warning "No connectors selected. Exiting."; exit }

    $Results = @()
    $DeviceIndex = 0
    # Safety buffer: Start first job 2 minutes from now to avoid "time in the past" errors
    $BaseStartTime = (Get-Date).AddMinutes(2)

    # 6. Concurrent Processing (Action Phase)
    Write-Host "Preparing $($SelectedDevices.Count) concurrent operations (20 threads)..." -ForegroundColor Yellow
    
    $ActionRunspacePool = [runspacefactory]::CreateRunspacePool(1, 20)
    $ActionRunspacePool.Open()
    $ActionJobs = @()
    
    # Define the worker logic
    $ActionScriptBlock = {
        param($BaseUrl, $AccountId, $AuthHeader, $DevGuid, $DevName, $DevSize, $IsStopping, $ScheduledTimeStr, $StaggerInterval, $MaxRetries)
        
        $Status = "Success"
        $FinalSched = "N/A"
        $ActionStr = if ($IsStopping) { "Stop" } else { "Start" }

        # Helper for REST calls inside the runspace
        function Call-Api {
            param($Uri, $Method, $Body=$null)
            return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $AuthHeader -Body $Body -ContentType "application/xml" -ErrorAction Stop
        }

        try {
            if ($IsStopping) {
                # --- STOP ---
                # 1. Disable Attribute
                $AttrUrl = "$BaseUrl/users/$AccountId/devices/$DevGuid/attributes/disable_backup"
                try {
                    Invoke-RestMethod -Uri $AttrUrl -Method Put -Headers $AuthHeader -Body "1" -ContentType "text/plain" -ErrorAction Stop | Out-Null
                } catch {
                    $Status = "Attr Failed"
                    throw "Attribute Set Failed: $($_.Exception.Message)"
                }

                # 2. Cancel Jobs
                $JobsUrl = "$BaseUrl/users/$AccountId/devices/$DevGuid/jobs"
                try {
                    $JobsResponse = Call-Api -Uri $JobsUrl -Method Get
                    $Jobs = @()
                    if ($JobsResponse.jobs -and $JobsResponse.jobs.job) { $Jobs = $JobsResponse.jobs.job }
                    
                    $ActiveJobs = $Jobs | Where-Object { 
                        $s = if ($_.status) { "$($_.status)".ToLower() } else { "" }
                        $isActive = if ($_.active) { "$($_.active)".ToLower() -eq "true" } else { $false }
                        ($s -eq 'scheduled' -or $s -eq 'running' -or $s -eq 'queued' -or $s -eq 'in_progress') -or $isActive
                    }

                    foreach ($Job in $ActiveJobs) {
                        $JobId = $Job.guid
                        $CancelUrl = "$BaseUrl/users/$AccountId/devices/$DevGuid/jobs/$JobId"
                        $Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                        $CancelXml = "<job><cancelled>$Timestamp</cancelled></job>"
                        Call-Api -Uri $CancelUrl -Method Put -Body $CancelXml | Out-Null
                    }
                    $FinalSched = "Cancelled"
                } catch {
                     $Status = "Cancel Error" 
                }

            } else {
                # --- START ---
                # 1. Enable Attribute
                $AttrUrl = "$BaseUrl/users/$AccountId/devices/$DevGuid/attributes/disable_backup"
                try {
                    Call-Api -Uri $AttrUrl -Method Delete | Out-Null
                } catch {
                    if (-not ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq "NotFound")) { 
                        $Status = "Enable Failed" 
                    }
                }

                # 2. Schedule Job (with Retry)
                $StartJobUrl = "$BaseUrl/users/$AccountId/devices/$DevGuid/jobs"
                $JobSuccess = $false
                $RetryCount = 0
                
                # Parse the time string back to object for manipulation if needed
                $CurrentTargetTime = [DateTime]::ParseExact($ScheduledTimeStr, "yyyy-MM-ddTHH:mm:ssZ", $null).ToUniversalTime()
                $FinalSched = $ScheduledTimeStr

                while (-not $JobSuccess -and $RetryCount -lt $MaxRetries) {
                    $TimeStr = $CurrentTargetTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
                    $FinalSched = $TimeStr # Update final sched in case we shifted

                    $StartXml = if ($StaggerInterval -gt 0) {
                        "<job><start>$TimeStr</start><description>User-requested backup</description><type>backup</type><commands><backup /></commands></job>"
                    } else {
                        "<job><description>User-requested backup</description><type>backup</type><immediate/><commands><backup/></commands></job>"
                    }

                    try {
                        Call-Api -Uri $StartJobUrl -Method Post -Body $StartXml | Out-Null
                        $JobSuccess = $true
                    } catch {
                        $RetryCount++
                        if ($RetryCount -lt $MaxRetries) {
                            # Shift forward 2 mins and retry
                            $CurrentTargetTime = $CurrentTargetTime.AddMinutes(2)
                            Start-Sleep -Seconds 2
                        } else {
                            $Status = "Job Start Failed"
                        }
                    }
                }
            }
        } catch {
            if ($Status -eq "Success") { $Status = "Error: $($_.Exception.Message)" }
        }

        return [PSCustomObject]@{
            Device = $DevName
            Size = $DevSize
            Action = $ActionStr
            Status = $Status
            Scheduled = $FinalSched
        }
    }

    # Safety buffer: Start first job 2 minutes from now
    $BaseStartTime = (Get-Date).AddMinutes(2)
    
    for ($i=0; $i -lt $SelectedDevices.Count; $i++) {
        $Dev = $SelectedDevices[$i]
        
        # Pre-calculate Stagger Time
        $SchedTimeStr = "N/A"
        if (-not $IsStopping) {
             $BatchIndex = [math]::Floor($i / $BatchSize)
             $Offset = $BatchIndex * $StaggerInterval
             $SchedTimeStr = $BaseStartTime.AddMinutes($Offset).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }

        $PS = [powershell]::Create().AddScript($ActionScriptBlock)
        [void]$PS.AddArgument($BaseUrl)
        [void]$PS.AddArgument($AccountId)
        [void]$PS.AddArgument($AuthHeader)
        [void]$PS.AddArgument($Dev.guid)
        [void]$PS.AddArgument($Dev.name)
        [void]$PS.AddArgument($Dev.size)
        [void]$PS.AddArgument($IsStopping)
        [void]$PS.AddArgument($SchedTimeStr)
        [void]$PS.AddArgument($StaggerInterval)
        [void]$PS.AddArgument($MaxRetries)
        
        $PS.RunspacePool = $ActionRunspacePool
        $ActionJobs += [PSCustomObject]@{ Pipe = $PS; Status = $PS.BeginInvoke() }
    }

    Write-Host "Jobs dispatched. Waiting for completion..." -NoNewline
    
    # Wait loop
    while ($ActionJobs.Status.IsCompleted -contains $false) {
        Start-Sleep -Milliseconds 500
    }
    Write-Host " Done." -ForegroundColor Green

    # Collect Results
    $Results = @()
    foreach ($Job in $ActionJobs) {
        try {
            $Res = $Job.Pipe.EndInvoke($Job.Status)
            $Results += $Res
        } catch {
            Write-Host "Thread Error: $($_.Exception.Message)" -ForegroundColor Red
        }
        $Job.Pipe.Dispose()
    }
    
    $ActionRunspacePool.Close()
    $ActionRunspacePool.Dispose()

    Write-Host "`n--- Final Summary ---" -ForegroundColor Cyan
    $Results | Sort-Object Scheduled | Format-Table -AutoSize
    
    $ExportPath = "$HOME\Desktop\Keepit_Job_Schedule_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
    $Results | Sort-Object Scheduled | Export-Csv -Path $ExportPath -NoTypeInformation
    Write-Host "Report saved to: $ExportPath" -ForegroundColor Green
    Write-Host "Operation Complete." -ForegroundColor Green

} catch {
    Write-Error "Critical Error: $($_.Exception.Message)"
}