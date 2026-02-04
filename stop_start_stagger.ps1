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
if (-not $IsStopping) {
    $DoStagger = Read-Host "`nDo you want to stagger the start of these jobs? (y/n)"
    if ($DoStagger -eq 'y') {
        $StaggerInterval = [int](Read-Host "Enter stagger interval in minutes (e.g., 15)")
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

    # --- Device Selection Logic ---
    $SelectedDevices = $Devices | Select-Object name, guid, type | 
        Out-GridView -Title "Select Connectors to $Action" -PassThru

    if (-not $SelectedDevices) { Write-Warning "No connectors selected. Exiting."; exit }

    $Results = @()
    $DeviceIndex = 0
    # Safety buffer: Start first job 2 minutes from now to avoid "time in the past" errors
    $BaseStartTime = (Get-Date).AddMinutes(2)

    # 6. Loop Devices
    foreach ($Dev in $SelectedDevices) {
        $DevGuid = $Dev.guid
        $DevName = $Dev.name
        $Status = "Success"
        Write-Host "`nDevice: $DevName ($DevGuid)" -ForegroundColor Cyan

        if ($IsStopping) {
            # --- STOP LOGIC ---
            $AttrUrl = "$BaseUrl/users/$AccountId/devices/$DevGuid/attributes/disable_backup"
            try {
                Write-Host "  -> Setting disable_backup=1..." -NoNewline
                Invoke-KeepitApiCall -Uri $AttrUrl -Method Put -Headers $AuthHeader -Body "1" -ContentType "text/plain" | Out-Null
                Write-Host " Done." -ForegroundColor Green
            } catch {
                Write-Host " Failed. $($_.Exception.Message)" -ForegroundColor Red
                $Status = "Attr Failed"
            }

            $JobsUrl = "$BaseUrl/users/$AccountId/devices/$DevGuid/jobs"
            try {
                $JobsResponse = Invoke-KeepitApiCall -Uri $JobsUrl -Method Get -Headers $AuthHeader -ContentType "application/xml"
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
                    Invoke-KeepitApiCall -Uri $CancelUrl -Method Put -Headers $AuthHeader -Body $CancelXml -ContentType "application/xml" | Out-Null
                }
            } catch { $Status = "Cancel Error" }

        } else {
            # --- START LOGIC ---
            # A. Enable
            $AttrUrl = "$BaseUrl/users/$AccountId/devices/$DevGuid/attributes/disable_backup"
            try {
                Invoke-KeepitApiCall -Uri $AttrUrl -Method Delete -Headers $AuthHeader -ContentType "application/xml" | Out-Null
            } catch {
                if (-not ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq "NotFound")) { $Status = "Enable Failed" }
            }

            # B. Start Job with Retry Logic
            $StartJobUrl = "$BaseUrl/users/$AccountId/devices/$DevGuid/jobs"
            $JobSuccess = $false
            $RetryCount = 0
            $CurrentStaggerOffset = $DeviceIndex * $StaggerInterval
            
            while (-not $JobSuccess -and $RetryCount -lt $MaxRetries) {
                $ScheduledTime = $BaseStartTime.AddMinutes($CurrentStaggerOffset).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                
                $StartXml = if ($StaggerInterval -gt 0) {
                    "<job><start>$ScheduledTime</start><description>User-requested backup</description><type>backup</type><commands><backup /></commands></job>"
                } else {
                    "<job><description>User-requested backup</description><type>backup</type><immediate/><commands><backup/></commands></job>"
                }

                try {
                    Write-Host "  -> Attempt $($RetryCount + 1): Starting backup (Target: $ScheduledTime)..." -NoNewline
                    Invoke-KeepitApiCall -Uri $StartJobUrl -Method Post -Headers $AuthHeader -Body $StartXml -ContentType "application/xml" | Out-Null
                    Write-Host " Success." -ForegroundColor Green
                    $JobSuccess = $true
                } catch {
                    $RetryCount++
                    $ErrorMsg = $_.Exception.Message
                    if ($RetryCount -lt $MaxRetries) {
                        Write-Host " Failed (400/Other). Retrying with +2 minute shift..." -ForegroundColor Yellow
                        $CurrentStaggerOffset += 2 # Shift time forward to resolve "past" issues
                        Start-Sleep -Seconds 2
                    } else {
                        Write-Host " Failed after $MaxRetries attempts: $ErrorMsg" -ForegroundColor Red
                        $Status = "Job Start Failed"
                    }
                }
            }
            $DeviceIndex++
        }
        $Results += [PSCustomObject]@{ Device = $DevName; Action = $Action; Status = $Status }
    }

    Write-Host "`n--- Final Summary ---" -ForegroundColor Cyan
    $Results | Format-Table -AutoSize
    Write-Host "Operation Complete." -ForegroundColor Green

} catch {
    Write-Error "Critical Error: $($_.Exception.Message)"
}