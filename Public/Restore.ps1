<#
.SYNOPSIS
    Submits a backup or restore job to a Keepit connector
.DESCRIPTION
    Submits a job to the Keepit API using an XML configuration blob. This is a low-level
    cmdlet that accepts raw XML job configuration, allowing full control over job parameters.
    For common backup operations, consider using Start-KeepitBackup instead.
.PARAMETER Connector
    The connector name or GUID to submit the job against.
    Can be piped from Get-KeepitConnector.
.PARAMETER Configuration
    An XML blob specifying the job contents. The XML structure depends on the job type.
    Maximum 64K length.

    Example for a restore job:
    <job>
        <description>Restore deleted items</description>
        <type>restore</type>
        <immediate />
        <commands>
            <restore>
                <source path="/Users/guid/Outlook/Inbox" snaptime="20241201T120000Z" />
                <destination path="/Users/guid/Outlook/Restored" />
            </restore>
        </commands>
    </job>
.EXAMPLE
    $xml = '<job><description>Test restore</description><type>restore</type><immediate /><commands><restore /></commands></job>'
    Submit-KeepitJob -Connector "abc123-def456" -Configuration $xml

    Submits a restore job with the specified XML configuration
.EXAMPLE
    $config = Get-Content -Path "restore-job.xml" -Raw
    Submit-KeepitJob -Connector "Production M365" -Configuration $config

    Submits a job using configuration from a file
.EXAMPLE
    Get-KeepitConnector -Connector "Production" | Submit-KeepitJob -Configuration $xml

    Submits a job to a connector found by name via pipeline
.OUTPUTS
    PSCustomObject containing job details with properties:
        - JobGuid: The GUID of the created job
        - ConnectorGuid: The connector GUID
        - Status: Job status (e.g., "created", "pending", "active")
        - CreatedAt: Timestamp when the job was created
        - EstimatedItems: Estimated number of items (if available)
.NOTES
    Requires an active connection via Connect-KeepitService.
    This cmdlet posts to the jobs API endpoint using application/xml content type.
    The API response is parsed to extract job details from either job or jobs.job structure.
#>
function Submit-KeepitJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            if ($_.Length -gt 65536) {
                throw "Configuration XML exceeds maximum length of 64K"
            }
            # Basic XML validation
            try {
                [xml]$_ | Out-Null
                return $true
            }
            catch {
                throw "Configuration must be valid XML: $($_.Exception.Message)"
            }
        })]
        [string]$Configuration
    )

    begin {
        Write-Verbose "=== Submit-KeepitJob: Initialization ==="

        # Get authentication header and base URL once for all pipeline items
        try {
            $authHeader = Get-AuthHeader
            $baseUrl = Get-KeepitBaseUrl
            $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl
            Write-Verbose "Base URL: $baseUrl, User ID: $userId"
        }
        catch {
            throw "Failed to initialize: $($_.Exception.Message)"
        }
    }

    process {
        try {
            # Resolve connector identity to GUID
            $resolved = Resolve-KeepitConnectorIdentity -Identity $Connector
            $connectorGuid = $resolved.ConnectorGuid

            Write-Verbose "=== Submit-KeepitJob: Processing ==="
            Write-Verbose "Connector: $($resolved.Name) ($connectorGuid)"
            Write-Verbose "Configuration length: $($Configuration.Length) characters"

            # Build request URI (matches Bohr's getRestoreJobSettings)
            $uri = "$baseUrl/users/$userId/devices/$connectorGuid/jobs/"

            # Headers matching Bohr implementation
            $headers = @{
                'Authorization' = $authHeader
                'Content-Type'  = 'application/xml'
                'Accept'        = 'application/vnd.keepit.v4+xml'
            }

            Write-Verbose "=== API Request ==="
            Write-Verbose "Method: POST"
            Write-Verbose "URI: $uri"
            Write-Verbose "Content-Type: application/xml"
            Write-Verbose "Accept: application/vnd.keepit.v4+xml"
            Write-Verbose "Request Body:`n$Configuration"

            # Make API call using Invoke-WebRequest for raw response handling
            $webResponse = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $Configuration -ErrorAction Stop
            $rawContent = $webResponse.Content

            Write-Verbose "=== API Response ==="
            Write-Verbose "Status Code: $($webResponse.StatusCode)"
            Write-Verbose "Content-Type: $($webResponse.Headers.'Content-Type')"
            Write-Verbose "Response Body:`n$rawContent"

            # Parse response - try XML first (matching Bohr's applyDataCallback logic)
            $jobGuid = $null
            $status = 'created'
            $createdAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
            $estimatedItems = 0

            try {
                $responseXml = [xml]$rawContent

                # Check for job structure (matches Bohr: jsonData?.job)
                if ($responseXml.job) {
                    $job = $responseXml.job
                    $jobGuid = if ($job.guid) { $job.guid } else { $null }
                    $status = if ($job.status) { $job.status } else { 'created' }
                    $createdAt = if ($job.created) { $job.created } else { $createdAt }
                    if ($job.'estimated-items') {
                        $estimatedItems = [int]$job.'estimated-items'
                    }
                    Write-Verbose "Parsed job from response.job"
                }
                # Check for jobs.job structure (matches Bohr: jsonData?.jobs?.job)
                elseif ($responseXml.jobs.job) {
                    $jobNode = $responseXml.jobs.job
                    # Handle array case
                    $job = if ($jobNode -is [System.Array]) { $jobNode[0] } else { $jobNode }
                    $jobGuid = if ($job.guid) { $job.guid } else { $null }
                    $status = if ($job.status) { $job.status } else { 'created' }
                    $createdAt = if ($job.created) { $job.created } else { $createdAt }
                    if ($job.'estimated-items') {
                        $estimatedItems = [int]$job.'estimated-items'
                    }
                    Write-Verbose "Parsed job from response.jobs.job"
                }
                else {
                    Write-Verbose "Could not find job or jobs.job in response, using defaults"
                }
            }
            catch {
                Write-Verbose "Could not parse response as XML: $($_.Exception.Message)"
            }

            # If we still don't have a job GUID, generate a placeholder
            if (-not $jobGuid) {
                $jobGuid = "job-$(Get-Date -Format 'yyyyMMddHHmmss')"
                Write-Verbose "Generated placeholder job GUID: $jobGuid"
            }

            # Create output object
            $result = [PSCustomObject]@{
                JobGuid        = $jobGuid
                ConnectorGuid  = $connectorGuid
                Status         = $status
                CreatedAt      = $createdAt
                EstimatedItems = $estimatedItems
            }

            Write-Verbose "=== Job Submitted Successfully ==="
            Write-Verbose "JobGuid: $($result.JobGuid)"
            Write-Verbose "Status: $($result.Status)"
            Write-Verbose "CreatedAt: $($result.CreatedAt)"
            Write-Verbose "EstimatedItems: $($result.EstimatedItems)"

            $result
        }
        catch {
            # Handle HTTP errors
            $errorMessage = $_.Exception.Message
            $errorBody = $null

            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $errorBody = $_.ErrorDetails.Message
                Write-Verbose "Error response body: $errorBody"

                # Try to parse error XML for better error message
                try {
                    $errorXml = [xml]$errorBody
                    if ($errorXml.error) {
                        $errorMessage = "API Error: $($errorXml.error.code) - $($errorXml.error.description)"
                    }
                }
                catch {
                    Write-Verbose "Could not parse error response as XML"
                }
            }

            throw "Failed to submit job for connector $connectorGuid : $errorMessage"
        }
    }
}

<#
.SYNOPSIS
    Calculates the estimated XML size for a set of restore items
.DESCRIPTION
    Internal helper function that estimates the XML job configuration size for a given
    set of items. Used to determine if job batching is needed to stay under the 64KB limit.
.PARAMETER Items
    Array of items to calculate size for. Each item must have an Id property.
.OUTPUTS
    Integer representing the estimated XML size in bytes.
.NOTES
    This is an internal helper function not exported from the module.
#>
function Get-RestoreItemsXmlSize {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [array]$Items
    )

    # Static XML overhead (job wrapper, description, config elements, etc.)
    # This is approximately 400 characters for the XML structure
    $staticOverhead = 400

    # Calculate the size of path elements
    # Each path element is: <Path>/path/to/item</Path> = 13 chars + path length
    $pathElementsSize = 0
    foreach ($item in $Items) {
        $itemPath = $item.Id -replace '^kng://[^/]+', ''
        $pathElementsSize += 13 + $itemPath.Length  # <Path></Path> = 13 chars
    }

    return $staticOverhead + $pathElementsSize
}

<#
.SYNOPSIS
    Splits items into batches that fit within the XML size limit
.DESCRIPTION
    Internal helper function that divides a large set of restore items into multiple
    batches, ensuring each batch's XML configuration stays under the 60KB threshold.
.PARAMETER Items
    Array of items to split into batches. Each item must have an Id property.
.PARAMETER MaxSizeBytes
    Maximum XML size in bytes per batch. Defaults to 60KB (61440 bytes).
.OUTPUTS
    Array of arrays, where each inner array is a batch of items.
.NOTES
    This is an internal helper function not exported from the module.
#>
function Split-RestoreItemsBatches {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [array]$Items,

        [Parameter(Mandatory = $false)]
        [int]$MaxSizeBytes = 61440  # 60KB
    )

    # Static XML overhead
    $staticOverhead = 400

    $batches = [System.Collections.ArrayList]::new()
    $currentBatch = [System.Collections.ArrayList]::new()
    $currentSize = $staticOverhead

    foreach ($item in $Items) {
        $itemPath = $item.Id -replace '^kng://[^/]+', ''
        $itemSize = 13 + $itemPath.Length  # <Path></Path> = 13 chars

        # Check if adding this item would exceed the limit
        if (($currentSize + $itemSize) -gt $MaxSizeBytes -and $currentBatch.Count -gt 0) {
            # Save current batch and start a new one
            [void]$batches.Add($currentBatch.ToArray())
            $currentBatch = [System.Collections.ArrayList]::new()
            $currentSize = $staticOverhead
        }

        [void]$currentBatch.Add($item)
        $currentSize += $itemSize
    }

    # Add the final batch if it has items
    if ($currentBatch.Count -gt 0) {
        [void]$batches.Add($currentBatch.ToArray())
    }

    return , $batches.ToArray()
}

<#
.SYNOPSIS
    Generates XML job configuration for restore operations
.DESCRIPTION
    Internal helper function that creates the XML job definition for restore operations,
    selecting the appropriate configuration based on the item type being restored.

    Different item types require different FolderRestoreMode settings:
    - email: Uses DeltaAppend mode
    - user: Uses DeltaRestore mode (for Entra ID user objects)
    - OneDrive: Uses DeltaAppend mode (for OneDrive for Business files)
.PARAMETER Type
    The type of items being restored. Valid values: email, user, OneDrive
.PARAMETER SnapshotId
    The snapshot ID to restore from.
.PARAMETER Items
    Array of items to restore. Each item must have an Id property containing the kng:// path.
.OUTPUTS
    String containing the XML job configuration.
.NOTES
    This is an internal helper function not exported from the module.
#>
function New-RestoreJobXml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('email', 'user', 'OneDrive')]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SnapshotId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [array]$Items
    )

    # Select FolderRestoreMode based on item type
    $folderRestoreMode = switch ($Type) {
        'email'    { 'DeltaAppend' }
        'user'     { 'DeltaRestore' }
        'OneDrive' { 'DeltaAppend' }
    }

    # Build RestorePaths element with one Path per item
    # Strip kng://connector-guid prefix from item ID to get just the path
    $pathElements = ($Items | ForEach-Object {
        $itemPath = $_.Id -replace '^kng://[^/]+', ''
        "<Path>$itemPath</Path>"
    }) -join ''

    # Generate the XML job configuration
    $xmlConfig = @"
<job><description>[srestore] [KeepitPSTools][$Type] Bulk restore of $($Items.Count) items</description><type>srestore</type><immediate/><priority>1</priority><commands><restore><RestoreConfig><SnapshotId>$SnapshotId</SnapshotId><Rules><Mode><FolderRestoreMode>$folderRestoreMode</FolderRestoreMode><FileConflictResolutionMode>Restore</FileConflictResolutionMode><Method>InPlace</Method></Mode><RestorePaths>$pathElements</RestorePaths></Rules></RestoreConfig></restore></commands></job>
"@

    return $xmlConfig
}

<#
.SYNOPSIS
    Restores bulk deleted items from Keepit backups
.DESCRIPTION
    Searches for deleted items in a specified date range and submits restore jobs to recover them.
    Items are grouped by their snapshot timestamp, and one restore job is submitted per snapshot.
    Currently supports email and user item types.

.PARAMETER UserPrincipalName
    The User Principal Name (UPN) or GUID of the user whose account or items should be restored.
    If a UPN is provided, it will be converted to a GUID using Convert-KeepitUPNToGuid.
    Accepts pipeline input by property name.
    Aliases: UPN, Email, UserId
.PARAMETER Connector
    The connector name or GUID to use for the restore operation.
    Can be piped from Get-KeepitConnector.
.PARAMETER RootPath
    The folder path to search from deleted items, relative to the user's Outlook folder.
    Examples: "Inbox", "Calendar", "Deleted Items"
    This will be expanded to: /Users/{userGuid}/Outlook/{RootPath} for mail items
.PARAMETER RestorePath
    The folder path to restore items to. Currently not implemented - items are restored
    in-place to their original location. A warning will be displayed if this parameter is used.
.PARAMETER StartTime
    The start of the date range for searching deleted items.
.PARAMETER EndTime
    The end of the date range for searching deleted items. Must be after StartTime. If you specify StartTime and EndTime as equal, the restore will include items from midnight on the start date until midnight on the following day.
.PARAMETER Type
    The type of items to restore. Valid values: email, user, OneDrive.
    Default is "email".
.PARAMETER Recursive
    Search recursively in subfolders of RootPath.
    By default, searches only the immediate RootPath. Use -Recursive to include subfolders. Not available when restoring mail.
.PARAMETER ShowJobs
    When specified, prints the XML job configuration blob for each restore job.
    Works with both -WhatIf (to see what would be submitted) and normal execution (to see what was submitted).
.EXAMPLE
    Restore-KeepitBulkDeletedItems -UserPrincipalName "user@example.com" -Connector "Production M365" -RootPath "Inbox" -StartTime "2026-01-01" -EndTime "2026-01-15"

    Restores all deleted items from the user's Inbox for the period 1-15 January 2026
.EXAMPLE
    Import-Csv users.csv | Restore-KeepitBulkDeletedItems -Connector "abc123-def456" -RootPath "Inbox" -StartTime "2026-01-01" -EndTime "2026-01-15"

    Restores deleted items for multiple users from a CSV file with UserPrincipalName, UPN, or Email column
.EXAMPLE
    Restore-KeepitBulkDeletedItems -UPN "user@example.com" -Connector "Production M365" -RootPath "Deleted Items" -StartTime (Get-Date).AddDays(-30) -EndTime (Get-Date) -WhatIf

    Shows what would be restored from the Deleted Items folder for the last 30 days without actually restoring
.OUTPUTS
    With -WhatIf: PSCustomObject with properties (jobs are NOT submitted):
        - TotalItems: Total number of items that would be restored
        - JobCount: Number of restore jobs that would be created
        - ItemsBySnapshot: Hashtable showing item counts per snapshot timestamp

    Without -WhatIf: Array of PSCustomObjects containing job results (jobs ARE submitted):
        - JobGuid: The GUID of the created restore job
        - ConnectorGuid: The connector GUID
        - SnapshotId: The snapshot ID used for this restore
        - SnapshotTime: The snapshot timestamp
        - ItemCount: Number of items in this restore job
        - Status: Job status
        - CreatedAt: Timestamp when the job was created
.NOTES
    Requires an active connection via Connect-KeepitService.
    Items are restored in-place to their original location.
    One restore job is created per unique snapshot timestamp to optimize the restore process.
#>
function Restore-KeepitBulkDeletedItems {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('UPN', 'Email', 'UserId')]
        [string]$UserPrincipalName,

        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RootPath,

        [Parameter(Mandatory = $false)]
        [string]$RestorePath,

        [Parameter(Mandatory = $true)]
        [DateTime]$StartTime,

        [Parameter(Mandatory = $true)]
        [DateTime]$EndTime,

        [Parameter(Mandatory = $false)]
        [ValidateSet('email', 'user', 'OneDrive')]
        [string]$Type = 'email',

        [Parameter(Mandatory = $false)]
        [switch]$Recursive,

        [Parameter(Mandatory = $false)]
        [switch]$ShowJobs
    )

    begin {
        Write-Verbose "=== Restore-KeepitBulkDeletedItems: Initialization ==="

        # Validate date range (allow same-day for whole-day searches)
        if ($EndTime -lt $StartTime) {
            throw "EndTime cannot be before StartTime. StartTime: $($StartTime.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)), EndTime: $($EndTime.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture))"
        }

        # Handle same-day search - expand to full day
        if ($StartTime.Date -eq $EndTime.Date) {
            Write-Verbose "StartTime and EndTime are the same date - expanding to full day"
            $StartTime = $StartTime.Date  # Midnight start
            $EndTime = $EndTime.Date.AddDays(1).AddSeconds(-1)  # 23:59:59
            Write-Verbose "Expanded range: $($StartTime.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)) to $($EndTime.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture))"
        }

        # Warn about RestorePath not being implemented
        if ($RestorePath) {
            Write-Warning "RestorePath parameter is not yet implemented. Items will be restored in-place to their original location."
        }

        # Validate Type; for now we only support email, ODB, and user
        if ($Type -notin @('email', 'user', 'OneDrive')) {
            throw "Only 'email', 'OneDrive', and 'user' types are currently supported. "
        }

        # Get authentication header and base URL
        try {
            $authHeader = Get-AuthHeader
            $baseUrl = Get-KeepitBaseUrl
            $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl
            Write-Verbose "Base URL: $baseUrl, User ID: $userId"
        }
        catch {
            throw "Failed to initialize: $($_.Exception.Message)"
        }
    }

    process {
        try {
            # Resolve connector identity to GUID
            $resolved = Resolve-KeepitConnectorIdentity -Identity $Connector
            $connectorGuid = $resolved.ConnectorGuid

            Write-Verbose "=== Restore-KeepitBulkDeletedItems: Processing ==="
            Write-Verbose "UserPrincipalName: $UserPrincipalName"
            Write-Verbose "Connector: $($resolved.Name) ($connectorGuid)"
            Write-Verbose "RootPath: $RootPath"
            Write-Verbose "StartTime: $StartTime"
            Write-Verbose "EndTime: $EndTime"
            Write-Verbose "Type: $Type"

            # Step 1: Convert UserPrincipalName to GUID if needed (for email type only)
            # For user type, we filter by UPN in the Title field instead, since the user may have been
            # recreated with a new GUID after deletion
            $userGuid = $UserPrincipalName
            if ($Type -ne 'user' -and $UserPrincipalName -match '@') {
                Write-Verbose "UserPrincipalName appears to be a UPN, converting to GUID..."
                $guidResult = Convert-KeepitUPNToGuid -UserPrincipalName $UserPrincipalName -Connector $connectorGuid
                if (-not $guidResult -or -not $guidResult.Guid) {
                    throw "Failed to convert UPN '$UserPrincipalName' to GUID. User may not exist in the backup."
                }
                $userGuid = $guidResult.Guid
                Write-Verbose "Converted UPN to GUID: $userGuid"
            }

            # Step 2: Construct the pathroot, removing leading/trailing slashes
            # If the type is 'email', as it will be by default, we can use this path. For other types, we'll have to construct the path differently.
            $cleanRootPath = $RootPath.Trim('/')

            if ($Type -eq 'email') {
                # For email items, the path is under Outlook
                $pathRoot = "/Users/$userGuid/Outlook/$cleanRootPath"
            } elseif ($Type -eq 'user') {
                # For user items, search at /Users level to find user objects
                # Results will be filtered by UPN after search
                $pathRoot = "/Users"
            } elseif ($Type -eq 'OneDrive') {
                # this is a little tricky. Some devices will have a path of /Users/{userGuid}/OneDrive, others /users/{userGuid}/OneDriveSP/DocLibs/Documents/Content
                # there's no way for us to tell in advance which path the device / user combo will have so we will have to check both
                # Start with the user-provided path under the user's folder
                $pathRoot = "/Users/$userGuid/$cleanRootPath"
            }
            Write-Verbose "Constructed RootPath: $cleanRootPath"

            # Step 3: Search for deleted items
            Write-Verbose "Searching for deleted items..."
            $searchParams = @{
                Connector   = $connectorGuid
                RootPath    = $pathRoot
                DeletedOnly = $true
                ResultSize  = 'Unlimited'
                StartTime   = $StartTime
                EndTime     = $EndTime
            }
            if ($Type -eq 'user') {
                $searchParams.Recursive = $false
            } else {
                if ($Recursive) {
                    $searchParams.Recursive = $true
                }
            }

            $deletedItems = @(Search-KeepitSnapshot @searchParams)

            # if we're doing OneDrive, and there were no results, this might be becaue of the path issue.
            # if those are both true, check the path the user supplied, swap to the other style, and search again
            if ($Type -eq 'OneDrive' -and $deletedItems.Count -eq 0) {
                Write-Verbose "No deleted items found for OneDrive - trying alternate path format..."
                if ($cleanRootPath -like 'OneDrive*') {
                    # user supplied /OneDrive*, try /OneDriveSP/DocLibs/Documents/Content
                    $altPathRoot = "/Users/$userGuid/OneDriveSP/DocLibs/Documents/Content"
                } else {
                    # user supplied /OneDriveSP/DocLibs/Documents/Content, try /OneDrive
                    $altPathRoot = "/Users/$userGuid/OneDrive"
                }
                Write-Verbose "Trying alternate RootPath: $altPathRoot"
                $searchParams.RootPath = $altPathRoot
                $deletedItems = @(Search-KeepitSnapshot @searchParams)
            }
            Write-Verbose "Found $($deletedItems.Count) deleted items"

            # For user type, filter results by UPN in the Title field
            # This handles cases where a user was recreated with a new GUID after deletion
            if ($Type -eq 'user') {
                # Filter by UPN in Title (format: "Display Name - user@domain.com")
                $deletedItems = @($deletedItems | Where-Object { $_.Title -like "*$UserPrincipalName*" })
                Write-Verbose "After filtering for UPN '$UserPrincipalName' in Title: $($deletedItems.Count) items"
            }

            if ($deletedItems.Count -eq 0) {
                Write-Warning "No deleted items found for user '$UserPrincipalName' in the specified date range."
                return
            }

            # Step 4: Group items by their <updated> timestamp
            Write-Verbose "Grouping items by snapshot timestamp..."
            $itemsByTimestamp = @{}
            foreach ($item in $deletedItems) {
                # Get the updated timestamp from the item
                $updated = $item.Updated
                if (-not $updated) {
                    Write-Verbose "Item $($item.Id) has no Updated timestamp, skipping"
                    continue
                }

                if (-not $itemsByTimestamp.ContainsKey($updated)) {
                    $itemsByTimestamp[$updated] = [System.Collections.ArrayList]::new()
                }
                [void]$itemsByTimestamp[$updated].Add($item)
            }

            Write-Verbose "Grouped items into $($itemsByTimestamp.Count) snapshot groups"

            # Step 5: Handle WhatIf
            if ($WhatIfPreference) {
                $maxSizeBytes = 61440  # 60KB threshold
                $itemCounts = @{}
                $batchCounts = @{}
                $totalJobCount = 0

                foreach ($key in $itemsByTimestamp.Keys) {
                    $groupItems = $itemsByTimestamp[$key]
                    $itemCounts[$key] = $groupItems.Count

                    # Calculate if batching would be needed
                    $estimatedSize = Get-RestoreItemsXmlSize -Items $groupItems
                    if ($estimatedSize -gt $maxSizeBytes) {
                        $batches = Split-RestoreItemsBatches -Items $groupItems -MaxSizeBytes $maxSizeBytes
                        $batchCounts[$key] = $batches.Count
                        $totalJobCount += $batches.Count
                    } else {
                        $batchCounts[$key] = 1
                        $totalJobCount += 1
                    }
                }

                $whatIfResult = [PSCustomObject]@{
                    TotalItems        = $deletedItems.Count
                    SnapshotGroups    = $itemsByTimestamp.Count
                    TotalJobCount     = $totalJobCount
                    ItemsBySnapshot   = $itemCounts
                    BatchesBySnapshot = $batchCounts
                }

                Write-Host "WhatIf: Would restore $($deletedItems.Count) items in $totalJobCount restore job(s) across $($itemsByTimestamp.Count) snapshot group(s)"
                foreach ($key in $itemsByTimestamp.Keys | Sort-Object) {
                    $batchInfo = if ($batchCounts[$key] -gt 1) { " ($($batchCounts[$key]) batches due to size limit)" } else { "" }
                    Write-Host "  Snapshot $key : $($itemsByTimestamp[$key].Count) items$batchInfo"
                    foreach ($item in $itemsByTimestamp[$key]) {
                        $title = if ($item.Title) { $item.Title } else { $item.Id }
                        Write-Host "    + $title"
                    }
                }

                # Generate and display XML blobs for WhatIf only if ShowJobs is specified
                if ($ShowJobs) {
                    Write-Host ""
                    Write-Host "XML job configurations that would be submitted:"
                    foreach ($timestamp in $itemsByTimestamp.Keys | Sort-Object) {
                        $items = $itemsByTimestamp[$timestamp]

                        # Find the matching snapshot
                        try {
                            $snapshotTime = [DateTime]::Parse($timestamp)
                        }
                        catch {
                            Write-Warning "Could not parse timestamp '$timestamp', skipping group"
                            continue
                        }

                        # Search backwards from item timestamp to find the snapshot at or before this time
                        $snapshotParams = @{
                            Connector   = $connectorGuid
                            StartTime   = $snapshotTime
                            EndTime     = $snapshotTime.AddYears(-1)
                            Reverse     = $true
                            ResultSize  = 1
                        }

                        $snapshot = Get-KeepitSnapshot @snapshotParams | Select-Object -First 1

                        if (-not $snapshot) {
                            Write-Warning "Could not find snapshot for timestamp '$timestamp', skipping group"
                            continue
                        }

                        $snapshotId = $snapshot.Id

                        # Check if batching is needed and generate XML for each batch
                        $estimatedSize = Get-RestoreItemsXmlSize -Items $items
                        if ($estimatedSize -gt $maxSizeBytes) {
                            $batches = Split-RestoreItemsBatches -Items $items -MaxSizeBytes $maxSizeBytes
                            $batchIndex = 0
                            foreach ($batch in $batches) {
                                $batchIndex++
                                $xmlConfig = New-RestoreJobXml -Type $Type -SnapshotId $snapshotId -Items $batch
                                Write-Host ""
                                Write-Host "Job XML for snapshot $timestamp (batch $batchIndex of $($batches.Count)):"
                                $xmlConfig | Out-Host
                            }
                        } else {
                            $xmlConfig = New-RestoreJobXml -Type $Type -SnapshotId $snapshotId -Items $items
                            Write-Host ""
                            Write-Host "Job XML for snapshot $timestamp :"
                            $xmlConfig | Out-Host
                        }
                    }
                }

                return $whatIfResult
            }

            # Step 6: For each group, find the matching snapshot and create restore job
            $jobResults = [System.Collections.ArrayList]::new()

            foreach ($timestamp in $itemsByTimestamp.Keys) {
                $items = $itemsByTimestamp[$timestamp]
                Write-Verbose "Processing snapshot group: $timestamp with $($items.Count) items"

                # Find the matching snapshot
                # Parse the timestamp and search backwards to find snapshot at or before this time
                try {
                    $snapshotTime = [DateTime]::Parse($timestamp)
                }
                catch {
                    Write-Warning "Could not parse timestamp '$timestamp', skipping group"
                    continue
                }

                $snapshotParams = @{
                    Connector   = $connectorGuid
                    StartTime   = $snapshotTime
                    EndTime     = $snapshotTime.AddYears(-1)
                    Reverse     = $true
                    ResultSize  = 1
                }

                $snapshot = Get-KeepitSnapshot @snapshotParams | Select-Object -First 1

                if (-not $snapshot) {
                    Write-Warning "Could not find snapshot for timestamp '$timestamp', skipping group"
                    continue
                }

                $snapshotId = $snapshot.Id
                Write-Verbose "Found snapshot ID: $snapshotId"

                # Step 7: Check if items need to be batched due to XML size limits
                $maxSizeBytes = 61440  # 60KB threshold
                $estimatedSize = Get-RestoreItemsXmlSize -Items $items
                Write-Verbose "Estimated XML size for $($items.Count) items: $estimatedSize bytes"

                if ($estimatedSize -gt $maxSizeBytes) {
                    # Split items into batches
                    $batches = Split-RestoreItemsBatches -Items $items -MaxSizeBytes $maxSizeBytes
                    $batchCount = $batches.Count
                    $avgItemSize = [math]::Round($estimatedSize / $items.Count, 1)
                    Write-Verbose "Items exceed $maxSizeBytes bytes - splitting into $batchCount batches (avg item size: $avgItemSize bytes)"
                } else {
                    # Single batch with all items
                    $batches = @(, $items)
                    $batchCount = 1
                }

                # Process each batch
                $batchIndex = 0
                foreach ($batch in $batches) {
                    $batchIndex++
                    $batchLabel = if ($batchCount -gt 1) { " (batch $batchIndex of $batchCount)" } else { "" }

                    # Generate XML job configuration using helper function
                    $xmlConfig = New-RestoreJobXml -Type $Type -SnapshotId $snapshotId -Items $batch

                    Write-Verbose "Created XML configuration for snapshot $snapshotId$batchLabel - $($batch.Count) items"
                    Write-Verbose "XML Config:`n$xmlConfig"

                    # Show XML blob if ShowJobs is specified
                    if ($ShowJobs) {
                        Write-Host "`nJob XML for snapshot ${timestamp}${batchLabel}:" -ForegroundColor Cyan
                        Write-Host $xmlConfig -ForegroundColor Yellow
                        Write-Host ""
                    }

                    # Show XML configuration with -WhatIf
                    if ($WhatIfPreference) {
                        Write-Host "`nRestore job XML that would be submitted${batchLabel}:" -ForegroundColor Cyan
                        Write-Host $xmlConfig -ForegroundColor Yellow
                        Write-Host ""
                    }

                    # Step 8: Submit the job
                    if ($PSCmdlet.ShouldProcess("Connector $connectorGuid", "Submit restore job for $($batch.Count) items from snapshot $timestamp$batchLabel")) {
                        $submitParams = @{
                            Connector     = $connectorGuid
                            Configuration = $xmlConfig
                        }

                        $jobResult = Submit-KeepitJob @submitParams

                        # Enhance result with additional info
                        $enhancedResult = [PSCustomObject]@{
                            JobGuid       = $jobResult.JobGuid
                            ConnectorGuid = $jobResult.ConnectorGuid
                            SnapshotId    = $snapshotId
                            SnapshotTime  = $timestamp
                            ItemCount     = $batch.Count
                            BatchNumber   = if ($batchCount -gt 1) { $batchIndex } else { $null }
                            TotalBatches  = if ($batchCount -gt 1) { $batchCount } else { $null }
                            Status        = $jobResult.Status
                            CreatedAt     = $jobResult.CreatedAt
                        }

                        [void]$jobResults.Add($enhancedResult)
                        Write-Verbose "Submitted job $($jobResult.JobGuid) for $($batch.Count) items$batchLabel"
                    }
                }
            }

            Write-Verbose "=== Restore-KeepitBulkDeletedItems: Complete ==="
            Write-Verbose "Submitted $($jobResults.Count) restore jobs"

            # Return job results
            $jobResults.ToArray()
        }
        catch {
            throw "Failed to restore deleted items: $($_.Exception.Message)"
        }
    }
}


<#
.SYNOPSIS
    Converts a User Principal Name (UPN) to a Keepit backup GUID
.DESCRIPTION
    Uses the Keepit BSearch API to look up a user by their UPN (email address) and
    returns the corresponding GUID used in backup paths. Keepit snapshots use GUIDs
    to refer to users (e.g., /Users/xxxxx-yy-zzzzzz/Outlook/Inbox) for anonymization.
    This cmdlet allows you to convert a human-readable UPN to the internal GUID.
.PARAMETER UserPrincipalName
    The User Principal Name (UPN) to look up, typically an email address.
    Accepts pipeline input directly or by property name.
    Aliases: UPN, Id, Email, Identity
    Example: user@example.com
.PARAMETER Connector
    The name or GUID of the Keepit connector (device) to search within.
    Can be piped from Get-KeepitConnector. Aliases: ConnectorGuid, Name
.EXAMPLE
    Convert-KeepitUPNToGuid -UserPrincipalName "paulr@blackdotpub.com" -Connector "abc123-def456"

    Looks up the GUID for paulr@blackdotpub.com in the specified connector
.EXAMPLE
    "user1@example.com", "user2@example.com" | Convert-KeepitUPNToGuid -Connector "ExO Only"

    Looks up GUIDs for multiple users via pipeline using connector name
.EXAMPLE
    Import-Csv users.csv | Convert-KeepitUPNToGuid -Connector "abc123-def456"

    Looks up GUIDs for users from a CSV file with UPN, Email, or UserPrincipalName column
.EXAMPLE
    Get-KeepitConnector | ForEach-Object { Convert-KeepitUPNToGuid -UserPrincipalName "user@example.com" -Connector $_.ConnectorGuid }

    Searches for a user across all connectors
.EXAMPLE
    $result = Convert-KeepitUPNToGuid -UserPrincipalName "user@example.com" -Connector "Production M365"
    $result.Guid

    Gets just the GUID value from the result
.OUTPUTS
    PSCustomObject with properties:
        - UserPrincipalName: The input UPN
        - Guid: The Keepit backup GUID for the user
    Returns $null if the UPN is not found.
.NOTES
    Requires an active connection via Connect-KeepitService.
    The search is performed against the /Users path root in the backup.
#>
function Convert-KeepitUPNToGuid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('UPN', 'Id', 'Email', 'Identity')]
        [string]$UserPrincipalName,

        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector
    )

    begin {
        Write-Verbose "Convert-KeepitUPNToGuid: Initializing"

        # Resolve connector identity and get auth info once for all pipeline items
        try {
            $resolved = Resolve-KeepitConnectorIdentity -Identity $Connector
            $connectorGuid = $resolved.ConnectorGuid
            Write-Verbose "Connector: $($resolved.Name) ($connectorGuid)"

            $authHeader = Get-AuthHeader
            $baseUrl = Get-KeepitBaseUrl
            $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl
            Write-Verbose "Base URL: $baseUrl, User ID: $userId"
        }
        catch {
            throw "Failed to initialize: $($_.Exception.Message)"
        }
    }

    process {
        try {
            Write-Verbose "Looking up GUID for UPN: $UserPrincipalName in connector: $connectorGuid"

            # Build bsearch query parameters matching Bohr's implementation
            # URL: /users/{userId}/bsearch?apiVersion=2&count=1&startIndex=0&pathRoot=/Users&device={connectorGUID}&filterOr=AND:!sys;&searchTerms="{upn}"
            $encodedUPN = [System.Uri]::EscapeDataString("`"$UserPrincipalName`"")
            $queryParams = @(
                "apiVersion=2",
                "count=1",
                "startIndex=0",
                "pathRoot=/Users",
                "device=$connectorGuid",
                "filterOr=AND:!sys;",
                "searchTerms=$encodedUPN"
            )
            $queryString = $queryParams -join '&'
            $uri = "$baseUrl/users/$userId/bsearch?$queryString"

            Write-Verbose "Request URI: $uri"

            # Headers for the request
            $headers = @{
                'Authorization' = $authHeader
                'Content-Type'  = 'application/json'
                'Accept'        = 'application/json'
            }

            # Make API call - use Invoke-WebRequest for raw response
            $webResponse = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
            $rawContent = $webResponse.Content

            # Handle byte array response (PowerShell 7 may return byte[] for some content types)
            if ($rawContent -is [byte[]]) {
                $rawContent = [System.Text.Encoding]::UTF8.GetString($rawContent)
            }

            Write-Verbose "Response Status: $($webResponse.StatusCode)"
            Write-Verbose "Response Content-Type: $($webResponse.Headers.'Content-Type')"
            if ($rawContent) {
                Write-Verbose "Raw Content (first 500 chars): $($rawContent.Substring(0, [Math]::Min(500, $rawContent.Length)))"
            }
            else {
                Write-Verbose "Raw Content: (empty)"
            }

            # Extract GUID from <kng:name> tag using regex (matching Bohr's approach)
            $guid = $null

            if ($rawContent -match '<kng:name>([^<]+)</kng:name>') {
                $guid = $Matches[1]
                Write-Verbose "Found GUID: $guid"
            }

            if (-not $guid) {
                Write-Warning "No GUID found for UPN '$UserPrincipalName' in connector '$connectorGuid'"
                return $null
            }

            # Escape single dashes to double dashes for Keepit path format
            $guid = $guid -replace '(?<!-)-(?!-)', '--'
            Write-Verbose "Path-escaped GUID: $guid"

            # Return result object
            [PSCustomObject]@{
                UserPrincipalName = $UserPrincipalName
                Guid              = $guid
            }
        }
        catch {
            throw "Failed to look up UPN '$UserPrincipalName' in connector '$connectorGuid': $($_.Exception.Message)"
        }
    }
}

