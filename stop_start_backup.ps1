<#
.SYNOPSIS
    Directly interacts with Keepit APIs to manage backup states.
    
.DESCRIPTION
    1. Prompts for Credentials.
    2. Asks user to "Stop" or "Start" operations.
    3. Finds the account via email search across all DCs.
    4. Iterates through all devices.
    5. IF STOPPING:
       - Sets 'disable_backup' attribute to '1'.
       - Cancels any scheduled, running, or queued jobs.
    6. IF STARTING:
       - Deletes the 'disable_backup' attribute.
       - Starts a new backup job immediately.
#>

# --- Configuration ---
$DataCenters = @("us-dc", "de-fr", "dk-co", "ca-tr", "ch-zh", "au-sy", "uk-ld", "ws-test")

# --- 1. Prompt for Credentials ---
Write-Host "Please enter your Keepit credentials..." -ForegroundColor Cyan
$Creds = Get-Credential
$UserEmail = $Creds.UserName
$Password = $Creds.GetNetworkCredential().Password

# Encode Credentials
$Bytes = [System.Text.Encoding]::ASCII.GetBytes("${UserEmail}:${Password}")
$Base64 = [Convert]::ToBase64String($Bytes)
$AuthHeader = @{ "Authorization" = "Basic $Base64" }

# --- 2. Prompt for Action ---
do {
    $Action = Read-Host "`nDo you want to STOP jobs (disable backup) or START jobs (enable backup)? (Enter 'Stop' or 'Start')"
} until ($Action -in @("Stop", "Start", "stop", "start"))

$IsStopping = $Action.ToLower() -eq "stop"
$ActionLabel = if ($IsStopping) { "STOPPING (Disable & Cancel)" } else { "STARTING (Enable & Backup)" }

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
        if ($_.Exception.Response) {
            $StatusCode = $_.Exception.Response.StatusCode
        }
        throw $_
    }
}

function Search-KeepitAccount {
    param ([string]$Email)
    Write-Host "Searching for account '$Email' across all dc's..." -ForegroundColor Yellow

    foreach ($dc in $DataCenters) {
        if ($dc -eq "ws-test") {
            $BaseUrl = "https://${dc}.keepitqa.com"
        } else {
            $BaseUrl = "https://${dc}.keepit.com"
        }
        
        # Method: Try to authenticate directly (WhoAmI check) as this is more reliable for finding "my" account
        $Url = "$BaseUrl/users"
        
        try {
            $Response = Invoke-KeepitApiCall -Uri $Url -Method Get -Headers $AuthHeader -ContentType "application/xml"
            
            # Check if we got a user back
            $User = if ($Response.users -and $Response.users.user) { $Response.users.user } 
                    elseif ($Response.user) { $Response.user }
                    else { $null }

            if ($User) {
                # Handle array vs single object
                if ($User -is [array]) { $User = $User[0] }
                
                $AccountId = $User.id
                if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
                     Write-Host "  Found via direct login on $dc" -ForegroundColor Green
                     return @{ AccountId = $AccountId; DcCode = $dc; BaseUrl = $BaseUrl }
                }
            }
        } catch {
            # 401 means wrong DC or wrong creds. 404 means endpoint not found.
            # We silently continue to next DC.
             if ($_.Exception.Response.StatusCode -ne "Unauthorized" -and $_.Exception.Response.StatusCode -ne "NotFound") {
                Write-Host "Error checking ${dc}: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    return $null
}

# --- Main Execution ---

try {
    # 3. Find Account
    $AccountInfo = Search-KeepitAccount -Email $UserEmail

    if (-not $AccountInfo) {
        Write-Error "Account not found for email '$UserEmail'."
        exit
    }

    $AccountId = $AccountInfo.AccountId
    $BaseUrl = $AccountInfo.BaseUrl
    Write-Host "Found Account ID: $AccountId in $($AccountInfo.DcCode)" -ForegroundColor Green

    # 4. Get Devices
    Write-Host "Fetching devices..." -ForegroundColor Yellow
    $DevicesUrl = "$BaseUrl/users/$AccountId/devices?all=1"
    
    # Using wrapper
    try {
        $DevicesResponse = Invoke-KeepitApiCall -Uri $DevicesUrl -Method Get -Headers $AuthHeader -ContentType "application/xml"
    } catch {
        Write-Error "Failed to fetch devices. Exiting."
        exit
    }

    $Devices = @()
    if ($DevicesResponse.devices) {
        if ($DevicesResponse.devices.cloud) { $Devices = $DevicesResponse.devices.cloud }
        elseif ($DevicesResponse.devices.device) { $Devices = $DevicesResponse.devices.device }
    }

    if ($Devices.Count -eq 0) { Write-Warning "No devices found."; exit }

    Write-Host "Found $($Devices.Count) device(s). Processing..." -ForegroundColor Green

    # 5. Loop Devices
    foreach ($Dev in $Devices) {
        $DevGuid = $Dev.guid
        $DevName = $Dev.name
        Write-Host "`nDevice: $DevName ($DevGuid)" -ForegroundColor Cyan

        if ($IsStopping) {
            # ==========================
            # STOP LOGIC
            # ==========================

            # A. Set 'disable_backup' = 1
            $AttrUrl = "$BaseUrl/users/$AccountId/devices/$DevGuid/attributes/disable_backup"
            try {
                Write-Host "  -> Setting disable_backup=1..." -NoNewline
                Invoke-KeepitApiCall -Uri $AttrUrl -Method Put -Headers $AuthHeader -Body "1" -ContentType "text/plain" | Out-Null
                Write-Host " Done." -ForegroundColor Green
            } catch {
                Write-Host " Failed. $($_.Exception.Message)" -ForegroundColor Red
            }

            # B. Cancel Active Jobs
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

                if ($ActiveJobs) {
                    foreach ($Job in $ActiveJobs) {
                        $JobId = $Job.guid
                        Write-Host "  -> Cancelling job $JobId ($($Job.status))..." -NoNewline
                        $CancelUrl = "$BaseUrl/users/$AccountId/devices/$DevGuid/jobs/$JobId"
                        $Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                        $CancelXml = "<job><cancelled>$Timestamp</cancelled></job>"
                        try {
                            Invoke-KeepitApiCall -Uri $CancelUrl -Method Put -Headers $AuthHeader -Body $CancelXml -ContentType "application/xml" | Out-Null
                            Write-Host " Success." -ForegroundColor Green
                        } catch {
                            Write-Host " Failed. $($_.Exception.Message)" -ForegroundColor Red
                        }
                    }
                } else {
                    Write-Host "  -> No active jobs to cancel." -ForegroundColor Gray
                }
            } catch {
                Write-Host "  -> Error fetching jobs: $($_.Exception.Message)" -ForegroundColor Red
            }

        } else {
            # ==========================
            # START LOGIC
            # ==========================

            # A. Delete 'disable_backup' attribute
            # Based on server.js: DELETE .../attributes/{attributeName}
            $AttrUrl = "$BaseUrl/users/$AccountId/devices/$DevGuid/attributes/disable_backup"
            try {
                Write-Host "  -> Removing 'disable_backup' attribute..." -NoNewline
                Invoke-KeepitApiCall -Uri $AttrUrl -Method Delete -Headers $AuthHeader -ContentType "application/xml" | Out-Null
                Write-Host " Done." -ForegroundColor Green
            } catch {
                # 404 means it's already gone, which is fine
                if ($_.Exception.Response.StatusCode -eq "NotFound") {
                    Write-Host " Not found (already enabled)." -ForegroundColor Gray
                } else {
                    Write-Host " Failed. $($_.Exception.Message)" -ForegroundColor Red
                }
            }

            # B. Start a Backup Job
            # Based on server.js: POST .../jobs with specific XML body
            $StartJobUrl = "$BaseUrl/users/$AccountId/devices/$DevGuid/jobs"
            $StartXml = '<job><description>User-requested backup</description><type>backup</type><immediate/><commands><backup/></commands></job>'
            
            try {
                Write-Host "  -> Starting backup job..." -NoNewline
                Invoke-KeepitApiCall -Uri $StartJobUrl -Method Post -Headers $AuthHeader -Body $StartXml -ContentType "application/xml" | Out-Null
                Write-Host " Initiated." -ForegroundColor Green
            } catch {
                Write-Host " Failed. $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    Write-Host "`nOperation Complete." -ForegroundColor Green

} catch {
    Write-Error "Critical Error: $($_.Exception.Message)"
}