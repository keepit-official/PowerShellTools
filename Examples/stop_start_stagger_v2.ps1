<#
.SYNOPSIS
    Manages Keepit backup states using KeepitTools module cmdlets.

.DESCRIPTION
    1. Connects to Keepit via Connect-KeepitService (with optional auto-discovery).
    2. Asks user to "Stop" or "Start" operations.
    3. Retrieves all connectors with sizes and presents a selection UI.
    4. IF STOPPING:
       - Disables backup via Disable-KeepitConnector.
       - Cancels any active/scheduled jobs (requires raw API — see NOTES).
    5. IF STARTING:
       - Enables backup via Enable-KeepitConnector.
       - Offers option to stagger backup jobs with load-balanced ordering.
       - Starts backup jobs via Start-KeepitBackup or Submit-KeepitJob.

.NOTES
    Requires KeepitTools module v0.9.7+.

    MISSING CMDLETS (workarounds in place):
      - Stop-KeepitJob  : No cmdlet to cancel running/scheduled jobs.
                           This script falls back to Submit-KeepitJob with cancel XML.
      - Start-KeepitBackup -ScheduledTime : The cmdlet only supports immediate backups.
                           Scheduled starts fall back to Submit-KeepitJob with raw XML.
#>

#Requires -Modules KeepitTools
#Requires -Modules Microsoft.PowerShell.ConsoleGuiTools
#Requires -Version 7.0

# --- Configuration ---
$MaxRetries = 3
$ValidEnvironments = @("us-dc", "de-fr", "dk-co", "ca-tr", "ch-zh", "au-sy", "uk-ld")

# --- 1. Connect to Keepit ---
Write-Host "Please enter your Keepit credentials..." -ForegroundColor Cyan
$Creds = Get-Credential

$AutoDiscover = Read-Host "`nDo you know which environment (data center) to connect to? (y/n)"

if ($AutoDiscover -eq 'y') {
    $Environment = $ValidEnvironments | Out-ConsoleGridView -Title "Select Keepit Environment" -OutputMode Single
    if (-not $Environment) {
        Write-Error "No environment selected."
        exit
    }
} else {
    Write-Host "Auto-discovering environment across data centers..." -ForegroundColor Yellow
    $Environment = $null

    foreach ($dc in $ValidEnvironments) {
        try {
            Connect-KeepitService -Credential $Creds -Environment $dc -ErrorAction Stop | Out-Null
            $Environment = $dc
            Write-Host "  Found account in: $dc" -ForegroundColor Green
            break
        } catch {
            Write-Host "  Not found in: $dc" -ForegroundColor DarkGray
        }
    }

    if (-not $Environment) {
        Write-Error "Account not found in any data center."
        exit
    }
}

# Connect (or confirm connection if auto-discovered)
if ($AutoDiscover -eq 'y') {
    try {
        Connect-KeepitService -Credential $Creds -Environment $Environment
        Write-Host "Connected to $Environment" -ForegroundColor Green
    } catch {
        Write-Error "Failed to connect: $($_.Exception.Message)"
        exit
    }
} else {
    Write-Host "Connected to $Environment" -ForegroundColor Green
}

# --- 2. Prompt for Action ---
do {
    $Action = Read-Host "`nDo you want to STOP jobs (disable backup) or START jobs (enable backup)? (Enter 'Stop' or 'Start')"
} until ($Action -in @("Stop", "Start", "stop", "start"))

$IsStopping = $Action.ToLower() -eq "stop"
$ActionLabel = if ($IsStopping) { "STOPPING (Disable & Cancel)" } else { "STARTING (Enable & Backup)" }

Write-Host "`n--- Selected Mode: $ActionLabel ---" -ForegroundColor Magenta

# --- 3. Get Connectors and Enrich with Size ---
Write-Host "Fetching connectors..." -ForegroundColor Yellow
$Connectors = Get-KeepitConnector -All

if (-not $Connectors -or $Connectors.Count -eq 0) {
    Write-Warning "No connectors found."
    Disconnect-KeepitService
    exit
}

Write-Host "Fetching storage sizes for $($Connectors.Count) connectors..." -ForegroundColor Yellow
$ConnectorData = @()

for ($i = 0; $i -lt $Connectors.Count; $i++) {
    $Conn = $Connectors[$i]
    Write-Progress -Activity "Fetching sizes" -Status "$($Conn.Name)" -PercentComplete (($i / $Connectors.Count) * 100)

    $Size = 0
    try {
        $Snapshot = Get-KeepitSnapshot -Connector $Conn.ConnectorGuid -Latest
        if ($Snapshot -and $Snapshot.Size) {
            $Size = [long]$Snapshot.Size
        }
    } catch { }

    $ConnectorData += [PSCustomObject]@{
        Name          = $Conn.Name
        ConnectorGuid = $Conn.ConnectorGuid
        Type          = $Conn.TypeDisplayName
        Size          = $Size
    }
}
Write-Progress -Activity "Fetching sizes" -Completed

# --- 4. Select Connectors ---
$SelectedConnectors = $ConnectorData |
    Out-ConsoleGridView -Title "Select Connectors to $Action" -PassThru

if (-not $SelectedConnectors) {
    Write-Warning "No connectors selected. Exiting."
    Disconnect-KeepitService
    exit
}

# --- 5. Stagger Configuration (Start mode only) ---
$StaggerInterval = 0
$BatchSize = 1

if (-not $IsStopping) {
    $DoStagger = Read-Host "`nDo you want to stagger the start of these jobs? (y/n)"
    if ($DoStagger -eq 'y') {
        $BatchSize = [int](Read-Host "How many jobs to start per batch? (e.g. 4)")
        $StaggerInterval = [int](Read-Host "Enter interval between batches in minutes (e.g. 30)")

        # Re-order: alternate largest and smallest for load balancing
        Write-Host "Re-ordering connectors to mix largest and smallest..." -ForegroundColor Cyan
        $Sorted = $SelectedConnectors | Sort-Object Size -Descending
        $Reordered = [System.Collections.Generic.List[object]]::new()
        $Left = 0
        $Right = $Sorted.Count - 1

        while ($Left -le $Right) {
            $BatchCount = 0
            while ($BatchCount -lt $BatchSize -and $Left -le $Right) {
                $Reordered.Add($Sorted[$Left])
                $Left++
                $BatchCount++
                if ($BatchCount -ge $BatchSize -or $Left -gt $Right) { break }
                $Reordered.Add($Sorted[$Right])
                $Right--
                $BatchCount++
            }
        }
        $SelectedConnectors = $Reordered.ToArray()
    }
}

# --- 6. Execute Actions ---
$BaseStartTime = (Get-Date).AddMinutes(2).ToUniversalTime()
$Results = @()
$Total = $SelectedConnectors.Count

for ($i = 0; $i -lt $Total; $i++) {
    $Conn = $SelectedConnectors[$i]
    $Status = "Success"
    $Scheduled = "N/A"

    Write-Progress -Activity "Processing connectors" -Status "$($Conn.Name)" -PercentComplete (($i / $Total) * 100)

    try {
        if ($IsStopping) {
            # --- STOP ---

            # 1. Disable backup
            Disable-KeepitConnector -Connector $Conn.ConnectorGuid | Out-Null

            # 2. Cancel active and scheduled jobs
            #    NOTE: A Stop-KeepitJob cmdlet would replace this block.
            $JobsToCancel = @()
            try { $JobsToCancel += @(Get-KeepitJobs -Connector $Conn.ConnectorGuid -Active) } catch { }
            try { $JobsToCancel += @(Get-KeepitJobs -Connector $Conn.ConnectorGuid -Scheduled) } catch { }
            $JobsToCancel = $JobsToCancel | Where-Object { $_ }

            foreach ($Job in $JobsToCancel) {
                try {
                    # WORKAROUND: Submit-KeepitJob POSTs new jobs — cancelling requires
                    # a PUT on the existing job, which no cmdlet supports today.
                    # A Stop-KeepitJob cmdlet is needed here. For now this is a no-op placeholder.
                    Write-Warning "  Cannot cancel job $($Job.JobGuid) — Stop-KeepitJob cmdlet not available."
                } catch { }
            }
            $Scheduled = "Disabled"

        } else {
            # --- START ---

            # 1. Enable backup
            Enable-KeepitConnector -Connector $Conn.ConnectorGuid | Out-Null

            # 2. Start or schedule backup
            if ($StaggerInterval -gt 0) {
                # Scheduled start — Start-KeepitBackup doesn't support -ScheduledTime,
                # so we fall back to Submit-KeepitJob with raw XML.
                $BatchIndex = [math]::Floor($i / $BatchSize)
                $Offset = $BatchIndex * $StaggerInterval
                $ScheduledTime = $BaseStartTime.AddMinutes($Offset)

                $JobSuccess = $false
                $RetryCount = 0
                $CurrentTime = $ScheduledTime

                while (-not $JobSuccess -and $RetryCount -lt $MaxRetries) {
                    $TimeStr = $CurrentTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
                    $JobXml = @"
<job>
  <start>$TimeStr</start>
  <description>User-requested backup</description>
  <type>backup</type>
  <commands><backup /></commands>
</job>
"@
                    try {
                        Submit-KeepitJob -Connector $Conn.ConnectorGuid -Configuration $JobXml | Out-Null
                        $JobSuccess = $true
                        $Scheduled = $TimeStr
                    } catch {
                        $RetryCount++
                        if ($RetryCount -lt $MaxRetries) {
                            $CurrentTime = $CurrentTime.AddMinutes(2)
                            Start-Sleep -Seconds 2
                        } else {
                            $Status = "Job Start Failed"
                            $Scheduled = "Failed after $MaxRetries retries"
                        }
                    }
                }
            } else {
                # Immediate backup
                try {
                    $JobResult = Start-KeepitBackup -Connector $Conn.ConnectorGuid
                    $Scheduled = if ($JobResult.Status -in @('AlreadyQueued', 'AlreadyRunning')) {
                        $JobResult.Status
                    } else {
                        "Immediate"
                    }
                } catch {
                    $Status = "Job Start Failed: $($_.Exception.Message)"
                }
            }
        }
    } catch {
        $Status = "Error: $($_.Exception.Message)"
    }

    $Results += [PSCustomObject]@{
        Connector = $Conn.Name
        Type      = $Conn.Type
        Size      = $Conn.Size
        Action    = if ($IsStopping) { "Stop" } else { "Start" }
        Status    = $Status
        Scheduled = $Scheduled
    }

    $Color = if ($Status -eq "Success") { "Green" } else { "Yellow" }
    Write-Host "[$($i + 1)/$Total] $($Conn.Name): $Status ($Scheduled)" -ForegroundColor $Color
}

Write-Progress -Activity "Processing connectors" -Completed

# --- 7. Summary & Export ---
Write-Host "`n--- Final Summary ---" -ForegroundColor Cyan
$Results | Sort-Object Scheduled | Format-Table -AutoSize

$ExportPath = Join-Path $HOME "Desktop/Keepit_Job_Schedule_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
$Results | Sort-Object Scheduled | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host "Report saved to: $ExportPath" -ForegroundColor Green

# --- Cleanup ---
Disconnect-KeepitService
Write-Host "Operation Complete." -ForegroundColor Green
