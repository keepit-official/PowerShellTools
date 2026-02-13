<#
.SYNOPSIS
    Creates bulk secure shared links for Keepit backup users.

.DESCRIPTION
    Generates personalized Keepit secure shared links for multiple users and
    exports the results to a CSV file. Designed for large-scale disaster recovery
    scenarios where an admin needs to give every user a link to their own
    mailbox, OneDrive, or both.

    Requires an active KeepitTools module connection (Connect-KeepitService).

.PARAMETER UserPrincipalName
    One or more user principal names (UPNs) to create links for. Accepts
    pipeline input as bare strings or objects with a UserPrincipalName property.

.PARAMETER Connector
    Name or GUID of the Keepit connector to use.

.PARAMETER Workload
    Which workload to generate links for: Exchange, OneDrive, or Both.
    When Both is selected, a single link to the user root is created.
    Default: Both.

.PARAMETER OutputPath
    Path to the output CSV file. The file will contain UserPrincipalName and
    Link columns.

.PARAMETER Password
    Optional SecureString password to protect all generated links.

.PARAMETER Lifetime
    Optional ISO 8601 duration for link expiry (e.g., P30D for 30 days).

.EXAMPLE
    "user1@contoso.com", "user2@contoso.com" | ./app/New-BulkShareLinks.ps1 `
        -Connector "Production M365" `
        -Workload Exchange `
        -OutputPath "./share-links.csv"

    Creates Exchange-only share links for two users.

.EXAMPLE
    Import-Csv ./users.csv | ./app/New-BulkShareLinks.ps1 `
        -Connector "Production M365" `
        -OutputPath "./share-links.csv" `
        -Lifetime "P30D"

    Creates share links from a CSV file with a UserPrincipalName column,
    with links expiring after 30 days.

.EXAMPLE
    $pw = Read-Host -AsSecureString "Enter share password"
    Get-Content ./upn-list.txt | ./app/New-BulkShareLinks.ps1 `
        -Connector "Production M365" `
        -Workload OneDrive `
        -OutputPath "./onedrive-links.csv" `
        -Password $pw `
        -Lifetime "P14D"

    Creates password-protected OneDrive share links from a text file of UPNs.
#>

#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [ValidateNotNullOrEmpty()]
    [Alias('UPN', 'Email')]
    [string]$UserPrincipalName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Connector,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Exchange', 'OneDrive', 'Both')]
    [string]$Workload = 'Both',

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [SecureString]$Password,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^P(\d+Y)?(\d+M)?(\d+W)?(\d+D)?(T(\d+H)?(\d+M)?(\d+S)?)?$')]
    [string]$Lifetime
)

begin {
    # Verify the KeepitTools module is loaded and connected
    try {
        $null = Get-Command -Name 'New-KeepitShare' -ErrorAction Stop
    }
    catch {
        throw "KeepitTools module is not loaded. Run 'Import-Module ./src/KeepitTools.psd1' and 'Connect-KeepitService' first."
    }

    # Resolve the connector once up front
    Write-Verbose "Resolving connector: $Connector"
    try {
        $resolvedConnector = Get-KeepitConnector | Where-Object {
            $_.ConnectorGuid -eq $Connector -or $_.Name -eq $Connector
        } | Select-Object -First 1

        if (-not $resolvedConnector) {
            throw "Connector '$Connector' not found."
        }
        $connectorGuid = $resolvedConnector.ConnectorGuid
        Write-Verbose "Resolved connector: $($resolvedConnector.Name) ($connectorGuid)"
    }
    catch {
        throw "Failed to resolve connector '$Connector': $($_.Exception.Message)"
    }

    # Get the latest snapshot and pin all shares to it
    Write-Verbose "Fetching latest snapshot for connector $connectorGuid"
    try {
        $latestSnapshot = Get-KeepitSnapshot -Connector $connectorGuid -Latest
        if (-not $latestSnapshot) {
            throw "No snapshots found for connector '$($resolvedConnector.Name)'. A backup must exist before shares can be created."
        }
        # If multiple snapshots returned, take the first
        if ($latestSnapshot -is [System.Array]) {
            $latestSnapshot = $latestSnapshot[0]
        }
        $snapshotId = $latestSnapshot.Id
        Write-Verbose "Pinning all shares to snapshot: $snapshotId (timestamp: $($latestSnapshot.Timestamp))"
    }
    catch {
        throw "Failed to get latest snapshot: $($_.Exception.Message)"
    }

    # Build the common parameters for New-KeepitShare
    $shareParams = @{
        Connector = $connectorGuid
        Snapshot  = $snapshotId
    }
    if ($PSBoundParameters.ContainsKey('Password')) {
        $shareParams['Password'] = $Password
    }
    if ($PSBoundParameters.ContainsKey('Lifetime')) {
        $shareParams['Lifetime'] = $Lifetime
    }

    # Collect results for CSV export
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $errorCount = 0
    $processedCount = 0

    # Collect all UPNs for progress reporting (we need total count)
    $upnBuffer = [System.Collections.Generic.List[string]]::new()
}

process {
    # Buffer UPNs during pipeline processing
    $upnBuffer.Add($UserPrincipalName)
}

end {
    $totalCount = $upnBuffer.Count
    if ($totalCount -eq 0) {
        Write-Warning "No UPNs were provided. Nothing to process."
        return
    }

    Write-Host "Processing $totalCount user(s) for '$Workload' share links on connector '$($resolvedConnector.Name)'..."

    foreach ($upn in $upnBuffer) {
        $processedCount++

        # Progress bar
        $percentComplete = [math]::Floor(($processedCount / $totalCount) * 100)
        Write-Progress -Activity "Creating share links" `
            -Status "Processing user $processedCount of ${totalCount}: $upn" `
            -PercentComplete $percentComplete

        # Resolve UPN to GUID
        $userGuid = $null
        try {
            $guidResult = Convert-KeepitUPNToGuid -UserPrincipalName $upn -Connector $connectorGuid -ErrorAction Stop
            if ($guidResult -and $guidResult.Guid) {
                $userGuid = $guidResult.Guid
                Write-Verbose "Resolved '$upn' to GUID: $userGuid"
            }
            else {
                Write-Error "User '$upn' was not found in the backup for connector '$($resolvedConnector.Name)'."
                $errorCount++
                continue
            }
        }
        catch {
            Write-Error "Failed to resolve UPN '$upn': $($_.Exception.Message)"
            $errorCount++
            continue
        }

        # Construct the share path based on workload
        $sharePath = switch ($Workload) {
            'Exchange' { "/Users/$userGuid/Outlook/" }
            'OneDrive' { "/Users/$userGuid/OneDrive/" }
            'Both'     { "/Users/$userGuid/" }
        }
        Write-Verbose "Share path for '$upn': $sharePath"

        # Create the share
        try {
            $shareResult = New-KeepitShare @shareParams -Path $sharePath -ErrorAction Stop

            if ($shareResult -and $shareResult.ShareUrl) {
                $results.Add([PSCustomObject]@{
                    UserPrincipalName = $upn
                    Link              = $shareResult.ShareUrl
                })
                Write-Verbose "Created share for '$upn': $($shareResult.ShareUrl)"
            }
            else {
                Write-Error "Share creation for '$upn' returned no URL."
                $errorCount++
            }
        }
        catch {
            Write-Error "Failed to create share for '$upn' (path: $sharePath): $($_.Exception.Message)"
            $errorCount++
        }
    }

    Write-Progress -Activity "Creating share links" -Completed

    # Export results to CSV
    if ($results.Count -gt 0) {
        $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Host "Exported $($results.Count) share link(s) to '$OutputPath'."
    }
    else {
        Write-Warning "No share links were successfully created. CSV file was not written."
    }

    # Summary
    if ($errorCount -gt 0) {
        Write-Warning "$errorCount of $totalCount user(s) failed. Review the errors above for details."
    }
}
