# Keepit API page size limit. The API returns pagesize-1 results, so we request 99+1=100 to get 99 results per page.
$script:ApiPageSize = 99

<#
.SYNOPSIS
    Retrieves snapshot information for a Keepit connector
.DESCRIPTION
    Gets snapshot data for a specified connector. Supports three modes:
    - Latest: Returns the most recent snapshot
    - Range: Returns all snapshots within a date range
    - Count: Returns the count of snapshots within a date range

.PARAMETER Connector
    The connector name or GUID to query snapshots for.
    Can be piped from Get-KeepitConnector.
.PARAMETER Latest
    Switch to retrieve only the most recent snapshot
.PARAMETER StartTime
    Start date / time for the snapshot range query (inclusive)
.PARAMETER EndTime
    End date / time for the snapshot range query (inclusive)
.PARAMETER CountOnly
    Switch to return only the count of snapshots in the specified range
.PARAMETER Reverse
    Search backwards from StartTime instead of forwards. Useful for finding the most recent snapshot
    at or before a specific timestamp. Use with -ResultSize 1 to get just the closest snapshot.
.PARAMETER ResultSize
    Maximum number of snapshots to return. Default matches the API page size.
    Use "unlimited" to retrieve all matching snapshots (may require multiple API calls).
    Only applicable with Range and Count parameter sets.
.EXAMPLE
    Get-KeepitSnapshot -Connector "Production M365" -Latest

    Gets the most recent snapshot for the connector named "Production M365"
.EXAMPLE
    Get-KeepitSnapshot -Connector "abc123-def456" -Latest

    Gets the most recent snapshot for the specified connector GUID
.EXAMPLE
    Get-KeepitConnector | Get-KeepitSnapshot -Latest

    Gets the most recent snapshot for all connectors
.EXAMPLE
    Get-KeepitSnapshot -Connector "abc123" -StartTime (Get-Date).AddDays(-30) -EndTime (Get-Date)

    Gets all snapshots from the last 30 days
.EXAMPLE
    Get-KeepitSnapshot -Connector "abc123" -StartTime "2024-01-01" -EndTime "2024-12-31" -CountOnly

    Returns the count of snapshots for the year 2024
.EXAMPLE
    Get-KeepitSnapshot -Connector "abc123" -StartTime "2025-12-28T03:16:10Z" -EndTime (Get-Date).AddYears(-1) -Reverse -ResultSize 1

    Gets the most recent snapshot at or before the specified timestamp by searching backwards up to 1 year
.OUTPUTS
    PSCustomObject[] - Array of snapshot objects (for Latest and Range modes) with properties:
        - Root: Snapshot root path
        - Timestamp: Snapshot timestamp
        - Type: Snapshot type
        - Size: Snapshot size
        - Account: Account GUID
        - ConnectorGuid: The connector GUID this snapshot belongs to
    Int32 - Count of snapshots (for CountOnly mode)
.NOTES
    Requires an active connection via Connect-KeepitService.
    Returns up to $script:ApiPageSize snapshots by default. Use -ResultSize to change this limit or specify "unlimited".
#>
function Get-KeepitSnapshot {
    [CmdletBinding(DefaultParameterSetName = 'Latest')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, ParameterSetName = 'Latest')]
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, ParameterSetName = 'Range')]
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, ParameterSetName = 'Count')]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector,

        [Parameter(Mandatory = $true, ParameterSetName = 'Latest')]
        [switch]$Latest,

        [Parameter(Mandatory = $true, ParameterSetName = 'Range')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Count')]
        [DateTime]$StartTime,

        [Parameter(Mandatory = $true, ParameterSetName = 'Range')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Count')]
        [DateTime]$EndTime,

        [Parameter(Mandatory = $true, ParameterSetName = 'Count')]
        [switch]$CountOnly,

        [Parameter(Mandatory = $false, ParameterSetName = 'Range')]
        [Parameter(Mandatory = $false, ParameterSetName = 'Count')]
        [ValidateScript({
            if ($_ -eq 'unlimited') { return $true }
            if ($_ -is [int] -and $_ -ge 1) { return $true }
            if ($_ -match '^\d+$' -and [int]$_ -ge 1) { return $true }
            throw "ResultSize must be a positive integer or 'unlimited'"
        })]
        $ResultSize = $script:ApiPageSize,

        [Parameter(Mandatory = $false, ParameterSetName = 'Range')]
        [switch]$Reverse
    )

    begin {
        Write-Verbose "Get-KeepitSnapshot: ParameterSetName = $($PSCmdlet.ParameterSetName)"

        # Validate date parameters if provided
        if ($PSCmdlet.ParameterSetName -in @('Range', 'Count')) {
            # Normalize times to UTC first, before any comparisons.
            # If Kind is Unspecified, treat as UTC (consistent with API behavior)
            # If Kind is Local, convert to UTC
            if ($StartTime.Kind -eq [DateTimeKind]::Unspecified) {
                $StartTime = [DateTime]::SpecifyKind($StartTime, [DateTimeKind]::Utc)
            }
            elseif ($StartTime.Kind -eq [DateTimeKind]::Local) {
                $StartTime = $StartTime.ToUniversalTime()
            }
            if ($EndTime.Kind -eq [DateTimeKind]::Unspecified) {
                $EndTime = [DateTime]::SpecifyKind($EndTime, [DateTimeKind]::Utc)
            }
            elseif ($EndTime.Kind -eq [DateTimeKind]::Local) {
                $EndTime = $EndTime.ToUniversalTime()
            }

            # Future-date validation uses UTC to avoid local-time-zone edge cases
            $utcToday = [DateTime]::UtcNow.Date

            if ($StartTime.Date -gt $utcToday) {
                throw "StartTime cannot be in the future. StartTime: $($StartTime.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)), Today (UTC): $($utcToday.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture))"
            }

            if ($EndTime.Date -gt $utcToday) {
                throw "EndTime cannot be in the future. EndTime: $($EndTime.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)), Today (UTC): $($utcToday.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture))"
            }

            # When Reverse is specified, StartTime should be later than EndTime (we search backwards)
            if (-not $Reverse -and $StartTime -gt $EndTime) {
                throw "StartTime cannot be later than EndTime. StartTime: $($StartTime.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)), EndTime: $($EndTime.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture))"
            }

            Write-Verbose "Date range (UTC): $($StartTime.ToString('yyyy-MM-ddTHH:mm:ssZ')) to $($EndTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        }

        # Get authentication header and base URL once for all pipeline items
        try {
            $authHeader = Get-AuthHeader
            $baseUrl = Get-KeepitBaseUrl
            $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl
        }
        catch {
            throw
        }
    }

    process {
        try {
            # Resolve connector identity to GUID
            $resolved = Resolve-KeepitConnectorIdentity -Identity $Connector
            $connectorGuid = $resolved.ConnectorGuid
            Write-Verbose "Processing connector: $($resolved.Name) ($connectorGuid)"

            switch ($PSCmdlet.ParameterSetName) {
                'Latest' {
                    # GET /users/{userId}/devices/{deviceId}/history/latest
                    $uri = "$baseUrl/users/$userId/devices/$connectorGuid/history/latest"
                    # Standardized to v4 for all parameter sets (required for DSL connector types)
                    $headers = @{
                        'Authorization' = $authHeader
                        'Accept' = 'application/vnd.keepit.v4+xml'
                        'Content-Type' = 'application/xml'
                    }

                    Write-Verbose "Fetching latest snapshot from: $uri"
                    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop

                    # Parse response - API returns <backup> elements
                    $backups = $null
                    if ($response.history.backup) {
                        $backups = $response.history.backup
                    }
                    elseif ($response.DocumentElement.backup) {
                        $backups = $response.DocumentElement.backup
                    }

                    if (-not $backups) {
                        Write-Verbose "No snapshots found for connector $connectorGuid"
                        return
                    }

                    # Normalize to array
                    if ($backups -isnot [System.Array]) {
                        $backups = @($backups)
                    }

                    foreach ($backup in $backups) {
                        # Use id if present, otherwise fall back to root
                        $snapshotId = if ($backup.id) { $backup.id } else { $backup.root }
                        [PSCustomObject]@{
                            Id = $snapshotId
                            Timestamp = $backup.tstamp
                            Type = $backup.type
                            Size = [long]$backup.size
                            Account = $backup.account
                            ConnectorGuid = $connectorGuid
                            ConnectorName = $resolved.Name
                        }
                    }
                }

                'Range' {
                    # PUT /users/{userId}/devices/{deviceId}/history/range
                    $uri = "$baseUrl/users/$userId/devices/$connectorGuid/history/range"
                    $headers = @{
                        'Authorization' = $authHeader
                        'Accept' = 'application/vnd.keepit.v4+xml'
                        'Content-Type' = 'application/xml'
                    }

                    # Handle "unlimited" vs numeric ResultSize
                    $isUnlimited = $ResultSize -eq 'unlimited'
                    $targetSize = if ($isUnlimited) { [int]::MaxValue } else { [int]$ResultSize }

                    $allSnapshots = [System.Collections.ArrayList]::new()
                    $currentStartDate = $StartTime
                    $iteration = 0
                    $maxIterations = if ($isUnlimited) { 10000 } else { [Math]::Ceiling($targetSize / $script:ApiPageSize) + 1 }

                    do {
                        $iteration++
                        $targetDisplay = if ($isUnlimited) { 'unlimited' } else { $targetSize }
                        Write-Verbose "Range query iteration $iteration (collected: $($allSnapshots.Count), target: $targetDisplay)"

                        $startTimestamp = ConvertTo-KeepitTimestamp -DateTime $currentStartDate
                        # API expects span as ISO8601 duration (e.g., P1D for 1 day)
                        # Add 1 day to make EndTime inclusive (P1D from Dec 30 only covers Dec 30)
                        $spanDays = [Math]::Ceiling(($EndTime - $currentStartDate).TotalDays) + 1
                        if ($spanDays -lt 1) { $spanDays = 1 }
                        $spanISO8601 = "P${spanDays}D"

                        # Request items: use remaining needed if <= page size, otherwise full page (API limit)
                        $apiCount = if ($isUnlimited) { $script:ApiPageSize } else { [Math]::Min($targetSize - $allSnapshots.Count, $script:ApiPageSize) }
                        if ($apiCount -lt 1) { $apiCount = $script:ApiPageSize }
                        $reverseElement = if ($Reverse) { '<reverse/>' } else { '' }
                        $requestBody = "<range><start>$startTimestamp</start><span>$spanISO8601</span><count>$apiCount</count>$reverseElement</range>"

                        Write-Verbose "Fetching snapshot range from: $uri"
                        Write-Verbose "Query: start=$startTimestamp, span=$spanISO8601, count=$apiCount, reverse=$Reverse"
                        $response = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $requestBody -ErrorAction Stop

                        # Parse response - API returns <backup> elements
                        $backups = $null
                        if ($response.history.backup) {
                            $backups = $response.history.backup
                        }
                        elseif ($response.DocumentElement.backup) {
                            $backups = $response.DocumentElement.backup
                        }

                        if (-not $backups) {
                            Write-Verbose "No more snapshots found in range for connector $connectorGuid"
                            break
                        }

                        # Normalize to array
                        if ($backups -isnot [System.Array]) {
                            $backups = @($backups)
                        }

                        $retrievedCount = $backups.Count
                        Write-Verbose "Retrieved $retrievedCount snapshots in this iteration"

                        # Add snapshots to collection
                        foreach ($backup in $backups) {
                            if (-not $isUnlimited -and $allSnapshots.Count -ge $targetSize) {
                                break
                            }
                            # Use id if present, otherwise fall back to root
                            $snapshotId = if ($backup.id) { $backup.id } else { $backup.root }
                            [void]$allSnapshots.Add([PSCustomObject]@{
                                Id = $snapshotId
                                Timestamp = $backup.tstamp
                                Type = $backup.type
                                Size = [long]$backup.size
                                Account = $backup.account
                                ConnectorGuid = $connectorGuid
                                ConnectorName = $resolved.Name
                            })
                        }

                        # Check if we need to continue pagination
                        if (-not $isUnlimited -and $targetSize -le $script:ApiPageSize) {
                            break
                        }
                        if ($retrievedCount -lt $script:ApiPageSize) {
                            break
                        }
                        if (-not $isUnlimited -and $allSnapshots.Count -ge $targetSize) {
                            break
                        }

                        # Get the timestamp of the last snapshot and use it + 1 second as new start
                        $lastTimestamp = $backups[-1].tstamp
                        if ($lastTimestamp) {
                            # Parse the timestamp and add 1 second for the next page
                            $parsedDate = [DateTime]::Parse($lastTimestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                            $currentStartDate = $parsedDate.AddSeconds(1)
                            Write-Verbose "Next page starts at: $(ConvertTo-KeepitTimestamp -DateTime $currentStartDate)"

                            # Stop if we've walked past the end time
                            if ($currentStartDate -gt $EndTime) {
                                Write-Verbose "Reached end time, stopping pagination"
                                break
                            }
                        }
                        else {
                            Write-Verbose "Could not determine last timestamp, stopping pagination"
                            break
                        }

                    } while ($iteration -lt $maxIterations)

                    Write-Verbose "Total snapshots collected: $($allSnapshots.Count)"

                    # Output all collected snapshots
                    foreach ($snapshot in $allSnapshots) {
                        $snapshot
                    }
                }

                'Count' {
                    $headers = @{
                        'Authorization' = $authHeader
                        'Accept' = 'application/vnd.keepit.v4+xml'
                        'Content-Type' = 'application/xml'
                    }

                    # Handle "unlimited" vs numeric ResultSize
                    $isUnlimited = $ResultSize -eq 'unlimited'
                    $targetSize = if ($isUnlimited) { [int]::MaxValue } else { [int]$ResultSize }

                    if (-not $isUnlimited -and $targetSize -le $script:ApiPageSize) {
                        # Simple case: single API call to count endpoint
                        $uri = "$baseUrl/users/$userId/devices/$connectorGuid/history/count"

                        $startTimestamp = ConvertTo-KeepitTimestamp -DateTime $StartTime
                        # Add 1 day to make EndTime inclusive (P1D from Dec 30 only covers Dec 30)
                        $spanDays = [Math]::Ceiling(($EndTime - $StartTime).TotalDays) + 1
                        if ($spanDays -lt 1) { $spanDays = 1 }
                        $spanISO8601 = "P${spanDays}D"

                        $requestBody = "<range><start>$startTimestamp</start><span>$spanISO8601</span><count>$targetSize</count></range>"

                        Write-Verbose "Fetching snapshot count from: $uri"
                        Write-Verbose "Query: start=$startTimestamp, span=$spanISO8601, count=$targetSize"
                        $response = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $requestBody -ErrorAction Stop

                        $count = if ($response.history.count) {
                            [int]$response.history.count
                        }
                        elseif ($response.count) {
                            [int]$response.count
                        }
                        else {
                            0
                        }

                        [PSCustomObject]@{
                            ConnectorGuid = $connectorGuid
                            ConnectorName = $resolved.Name
                            StartTime = $StartTime
                            EndTime = $EndTime
                            Count = $count
                        }
                    }
                    else {
                        # Pagination required: use range endpoint to count
                        $uri = "$baseUrl/users/$userId/devices/$connectorGuid/history/range"
                        $totalCount = 0
                        $currentStartDate = $StartTime
                        $iteration = 0
                        $maxIterations = if ($isUnlimited) { 10000 } else { [Math]::Ceiling($targetSize / $script:ApiPageSize) + 1 }

                        do {
                            $iteration++
                            $targetDisplay = if ($isUnlimited) { 'unlimited' } else { $targetSize }
                            Write-Verbose "Count query iteration $iteration (counted: $totalCount, target: $targetDisplay)"

                            $startTimestamp = ConvertTo-KeepitTimestamp -DateTime $currentStartDate
                            # Add 1 day to make EndTime inclusive (P1D from Dec 30 only covers Dec 30)
                            $spanDays = [Math]::Ceiling(($EndTime - $currentStartDate).TotalDays) + 1
                            if ($spanDays -lt 1) { $spanDays = 1 }
                            $spanISO8601 = "P${spanDays}D"

                            $requestBody = "<range><start>$startTimestamp</start><span>$spanISO8601</span><count>$($script:ApiPageSize)</count></range>"

                            Write-Verbose "Fetching snapshot range for counting from: $uri"
                            Write-Verbose "Query: start=$startTimestamp, span=$spanISO8601, count=$($script:ApiPageSize)"
                            $response = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $requestBody -ErrorAction Stop

                            # Parse response
                            $backups = $null
                            if ($response.history.backup) {
                                $backups = $response.history.backup
                            }
                            elseif ($response.DocumentElement.backup) {
                                $backups = $response.DocumentElement.backup
                            }

                            if (-not $backups) {
                                Write-Verbose "No more snapshots found for counting"
                                break
                            }

                            # Normalize to array
                            if ($backups -isnot [System.Array]) {
                                $backups = @($backups)
                            }

                            $retrievedCount = $backups.Count
                            # For unlimited, count everything; otherwise limit to remaining needed
                            $countToAdd = if ($isUnlimited) {
                                $retrievedCount
                            } else {
                                $remainingNeeded = $targetSize - $totalCount
                                [Math]::Min($retrievedCount, $remainingNeeded)
                            }
                            $totalCount += $countToAdd

                            Write-Verbose "Retrieved $retrievedCount snapshots, added $countToAdd to count (total: $totalCount)"

                            # Check if we need to continue
                            if ($retrievedCount -lt $script:ApiPageSize) {
                                break
                            }
                            if (-not $isUnlimited -and $totalCount -ge $targetSize) {
                                break
                            }

                            # Get the timestamp of the last snapshot and use it + 1 second as new start
                            $lastTimestamp = $backups[-1].tstamp
                            if ($lastTimestamp) {
                                $parsedDate = [DateTime]::Parse($lastTimestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                $currentStartDate = $parsedDate.AddSeconds(1)
                                Write-Verbose "Next page starts at: $(ConvertTo-KeepitTimestamp -DateTime $currentStartDate)"

                                if ($currentStartDate -gt $EndTime) {
                                    Write-Verbose "Reached end time, stopping pagination"
                                    break
                                }
                            }
                            else {
                                Write-Verbose "Could not determine last timestamp, stopping pagination"
                                break
                            }

                        } while ($iteration -lt $maxIterations)

                        Write-Verbose "Total count: $totalCount"

                        [PSCustomObject]@{
                            ConnectorGuid = $connectorGuid
                            ConnectorName = $resolved.Name
                            StartTime = $StartTime
                            EndTime = $EndTime
                            Count = $totalCount
                        }
                    }
                }
            }
        }
        catch {
            # Use $Connector (input parameter) as fallback if $connectorGuid was never assigned
            $connectorIdentifier = if ($connectorGuid) { $connectorGuid } else { $Connector }
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Failed to retrieve snapshots for connector $connectorIdentifier : $($_.Exception.Message)", $_.Exception),
                    'KeepitApiError',
                    [System.Management.Automation.ErrorCategory]::ConnectionError,
                    $connectorIdentifier
                )
            )
        }
    }
}


<#
.SYNOPSIS
    Searches backup data using the Keepit BSearch API
.DESCRIPTION
    Performs searches against backup snapshots using the Keepit BSearch API v2.
    Supports searching for items by path, text terms, item type, date range, and various filters.

    Common use cases:
    - Search for mail items in a user's mailbox
    - Browse folder contents at a specific point in time
    - Find deleted items
    - Search across all users on a connector
.PARAMETER Connector
    The connector name or GUID to search.
    Can be piped from Get-KeepitConnector.
.PARAMETER RootPath
    The folder path to search within. Paths are automatically masked for the API.
    UPN support: If the path contains a UPN (e.g., /Users/user@example.com/...), it will be
    automatically converted to the internal GUID using Convert-KeepitUPNToGuid.
    Examples: "/Users", "/Users/user@example.com/Outlook/Inbox", "/SharePoint/SiteName"
.PARAMETER SearchTerms
    Text terms to search for (fuzzy search, case insensitive).
    Use quotes for exact match: '"exact phrase"'
    Multiple terms are space-separated.
.PARAMETER ItemName
    Exact filename to match. Use for retrieving history of a specific item.
.PARAMETER ItemType
    Filter by item type. Valid values: Audio, Video, Image, Message, Document, Folder.
    Can specify multiple types.
.PARAMETER FilterExpression
    Raw filter expression for advanced filtering.
    Format: "AND:criterion1,criterion2;OR:criterion3,criterion4"
    Examples:
        "AND:!deleted,!sys" - exclude deleted and system items
        "AND:!deleted,!sys;OR:message,document" - non-deleted messages or documents
.PARAMETER FilterMode
    How filter groups are combined. Valid values: And, Or.
    Default: And (uses filterAnd parameter)
.PARAMETER IncludeDeleted
    Include deleted items in results. By default, deleted items are excluded.
    Cannot be used with -DeletedOnly.
.PARAMETER DeletedOnly
    Return only deleted items. By default, deleted items are excluded.
    Cannot be used with -IncludeDeleted.
.PARAMETER StartTime
    Start of snapshot date range (ISO8601 or DateTime).
    When StartTime and EndTime are the same date, the search covers the entire day.
.PARAMETER EndTime
    End of snapshot date range (ISO8601 or DateTime).
    When StartTime and EndTime are the same date, the search covers the entire day.
.PARAMETER ReceivedTime
    Filter by source-system received date (start). Uses range(received:...) filter
    instead of snaptimeFrom, filtering by when the email was received in Exchange
    rather than when Keepit took the snapshot. Dates are sent as date-only ISO 8601
    (YYYY-MM-DD) to avoid colon collision with the range() delimiter syntax.
.PARAMETER ReceivedEndTime
    Filter by source-system received date (end). Used with ReceivedTime.
.PARAMETER Recursive
    Search recursively in subfolders of RootPath.
    By default, searches only the immediate RootPath. Use -Recursive to include subfolders.
.PARAMETER ResultSize
    Maximum number of results to return. Default is 100.
    Use "Unlimited" to retrieve all matching results (may require multiple API calls).
    Cannot be used with -CountOnly.
.PARAMETER CountOnly
    Return only the count of matching items, without returning item details.
    Cannot be used with -ResultSize.
.PARAMETER StartIndex
    Index of first result for pagination. Default is 0.
.EXAMPLE
    Search-KeepitSnapshot -Connector "Production M365" -RootPath "/Users/user@example.com/Outlook/Inbox" -StartTime "2026-01-01" -EndTime "2026-01-31"

    Find all mail messages in a user's Inbox from January 2026
.EXAMPLE
    Search-KeepitSnapshot -Connector "abc123-def456" -RootPath "/Users" -SearchTerms "'pro@keepit.com'"

    Search for exact match "pro@keepit.com" in immediate /Users folder only (non-recursive by default)
.EXAMPLE
    Search-KeepitSnapshot -Connector "abc123" -RootPath "/Users/user@example.com/Outlook/Inbox" -ItemType Message -DeletedOnly -StartTime "2026-01-01" -EndTime "2026-01-05"

    Search for all deleted messages for the specified user's Inbox folder during the period 1-5 January 2026
.EXAMPLE
    Get-KeepitConnector | Search-KeepitSnapshot -RootPath "/Users" -ItemType Folder

    Search for folders in /Users path across all connectors
.EXAMPLE
    Search-KeepitSnapshot -Connector "abc123" -RootPath "/Users/user@example.com/Outlook" -ItemType folder -Recursive

    Recursively list all folders below the specified RootPath
.EXAMPLE
    Search-KeepitSnapshot -Connector "abc123" -RootPath "/Users/user@example.com/Outlook" -ItemType Message -CountOnly

    Get the count of messages without returning item details
.OUTPUTS
    Default mode - PSCustomObject[] - Array of search result objects with properties:
        - Id: Item identifier (kng:// path)
        - Name: Item name/filename
        - Path: Human-readable path (if resolveIds was used)
        - Title: Item title/subject
        - Updated: Last update timestamp
        - Published: Published/created timestamp
        - Size: Item size in bytes
        - ContentType: MIME content type
        - ItemType: Detected item type (message, document, folder, etc.)
        - IsDeleted: Whether the item is deleted
        - ConnectorGuid: The connector GUID
        - Metadata: Hashtable of additional metadata

    CountOnly mode - PSCustomObject with properties:
        - ConnectorGuid: The connector GUID
        - RootPath: The search path
        - SearchTerms: The search terms used (if any)
        - Count: Total number of matching items
.NOTES
    Requires an active connection via Connect-KeepitService.

    PATH MASKING: Paths are automatically masked for the API where special characters
    are escaped (: -> -c, / -> -s, - -> --). You can provide normal paths.

    RESULT SIZE: When using -ResultSize Unlimited, the cmdlet makes multiple API calls
    to retrieve all results. This may take time for large result sets.

    FILTERS: The BSearch API uses a Polish notation filter syntax. Use -FilterExpression
    for advanced filtering, or use -ItemType, -IncludeDeleted, and -DeletedOnly for common cases.

    UPN CONVERSION: When RootPath contains a user path with a UPN (email address) like
    /Users/user@example.com/Outlook, the UPN is automatically converted to the internal GUID
    using the BSearch API. If the UPN cannot be resolved, a warning is displayed and the
    search continues with the original path (which may return no results).
#>
function Search-KeepitSnapshot {
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector,

        [Parameter(Mandatory = $false)]
        [Alias('PathRoot')]
        [string]$RootPath,

        [Parameter(Mandatory = $false)]
        [string]$SearchTerms,

        [Parameter(Mandatory = $false)]
        [string]$ItemName,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Audio', 'Video', 'Image', 'Message', 'Document', 'Folder')]
        [string[]]$ItemType,

        [Parameter(Mandatory = $false)]
        [string]$FilterExpression,

        [Parameter(Mandatory = $false)]
        [ValidateSet('And', 'Or')]
        [string]$FilterMode = 'And',

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDeleted,

        [Parameter(Mandatory = $false)]
        [switch]$DeletedOnly,

        [Parameter(Mandatory = $false)]
        [DateTime]$StartTime,

        [Parameter(Mandatory = $false)]
        [DateTime]$EndTime,

        [Parameter(Mandatory = $false)]
        [DateTime]$ReceivedTime,

        [Parameter(Mandatory = $false)]
        [DateTime]$ReceivedEndTime,

        [Parameter(Mandatory = $false)]
        [switch]$Recursive,

        [Parameter(Mandatory = $false)]
        [switch]$FullHistory,

        [Parameter(Mandatory = $false)]
        [ValidateScript({
            if ($_ -is [int] -and $_ -gt 0) { return $true }
            if ($_ -is [string] -and $_.ToLower() -eq 'unlimited') { return $true }
            if ($_ -is [int] -and $_ -le 0) { throw "ResultSize must be a positive integer or 'Unlimited'" }
            throw "ResultSize must be a positive integer or 'Unlimited'"
        })]
        $ResultSize = 100,

        [Parameter(Mandatory = $false)]
        [switch]$CountOnly,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$StartIndex = 0
    )

    begin {
        Write-Verbose "Search-KeepitSnapshot: Initializing"

        # Validate that at least RootPath or SearchTerms is provided
        if (-not $RootPath -and -not $SearchTerms) {
            throw "At least one of RootPath or SearchTerms must be specified."
        }

        # Validate that IncludeDeleted and DeletedOnly are not both specified
        if ($IncludeDeleted -and $DeletedOnly) {
            throw "Cannot specify both -IncludeDeleted and -DeletedOnly. Use -IncludeDeleted to include deleted items in results, or -DeletedOnly to return only deleted items."
        }

        # Validate RootPath starts with a slash
        if ($RootPath -and -not $RootPath.StartsWith('/')) {
            throw "RootPath must start with a forward slash (/). Received: '$RootPath'"
        }

        # Normalize RootPath segment casing: the API is case-sensitive and expects initial caps
        # on named path elements (e.g., 'Users', 'Devices', 'Outlook').
        # Leave GUIDs (contain hyphens matching the GUID pattern) and UPNs (contain @) unchanged.
        if ($RootPath) {
            $guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            $normalizedSegments = ($RootPath -split '/') | ForEach-Object {
                if ($_ -eq '' -or $_ -match '@' -or $_ -match $guidPattern) {
                    $_
                }
                else {
                    $_.Substring(0, 1).ToUpper() + $_.Substring(1)
                }
            }
            $RootPath = $normalizedSegments -join '/'
            Write-Verbose "Normalized RootPath: $RootPath"
        }

        # Validate that CountOnly and ResultSize are not both specified
        if ($CountOnly -and $PSBoundParameters.ContainsKey('ResultSize')) {
            throw "Cannot specify both -CountOnly and -ResultSize. Use -CountOnly to get just the count, or -ResultSize to get results."
        }

        # Validate that EndTime is not before StartTime
        if ($StartTime -and $EndTime -and $EndTime -lt $StartTime) {
            throw "EndTime ($($EndTime.ToString('yyyy-MM-dd'))) cannot be before StartTime ($($StartTime.ToString('yyyy-MM-dd')))"
        }

        # Validate that ReceivedEndTime is not before ReceivedTime
        if ($ReceivedTime -and $ReceivedEndTime -and $ReceivedEndTime -lt $ReceivedTime) {
            throw "ReceivedEndTime cannot be before ReceivedTime."
        }

        # Determine if we're doing unlimited results
        $isUnlimited = $ResultSize -is [string] -and $ResultSize.ToLower() -eq 'unlimited'
        $pageSize = if ($isUnlimited) { 100 } else { [int]$ResultSize }

        Write-Verbose "ResultSize: $(if ($CountOnly) { 'CountOnly' } elseif ($isUnlimited) { 'Unlimited' } else { $pageSize })"

        # Get authentication header and base URL once for all pipeline items
        try {
            $authHeader = Get-AuthHeader
            $baseUrl = Get-KeepitBaseUrl
            $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl
            Write-Verbose "Base URL: $baseUrl, User ID: $userId"
        }
        catch {
            throw
        }

        # Helper function to safely get property value from XML or PSObject
        # Defined in begin block so it is created once, not on every pipeline iteration
        function Get-SafeValue {
            param($obj, $propName)
            if ($null -eq $obj) { return $null }

            try {
                $val = $null

                # For XML elements, try multiple access methods
                if ($obj -is [System.Xml.XmlElement]) {
                    # Try direct property access first
                    $val = $obj.$propName

                    # If that didn't work and propName has a colon (namespace), try without namespace
                    if ($null -eq $val -and $propName -match ':') {
                        $localName = $propName -replace '^.*:', ''
                        $val = $obj.$localName
                    }

                    # Try SelectSingleNode for namespaced elements
                    if ($null -eq $val) {
                        $localName = $propName -replace '^.*:', ''
                        $node = $obj.SelectSingleNode("*[local-name()='$localName']")
                        if ($node) { $val = $node }
                    }

                    # Try GetElementsByTagName
                    if ($null -eq $val) {
                        $localName = $propName -replace '^.*:', ''
                        $nodes = $obj.GetElementsByTagName($localName)
                        if ($nodes -and $nodes.Count -gt 0) { $val = $nodes[0] }
                    }
                }
                else {
                    # Standard property access for non-XML objects
                    $val = $obj.$propName
                }

                # Extract text value from the result
                if ($val -is [System.Xml.XmlElement]) {
                    return $val.InnerText
                }
                elseif ($val -is [System.Xml.XmlNode]) {
                    return $val.InnerText
                }
                elseif ($val -is [PSCustomObject] -and $val.'#text') {
                    return $val.'#text'
                }
                elseif ($null -ne $val -and $val -isnot [System.Array]) {
                    $strVal = $val.ToString()
                    if ($strVal -and $strVal -ne $val.GetType().FullName) {
                        return $strVal
                    }
                }
            }
            catch { }
            return $null
        }
    }

    process {
        try {
            # Resolve connector identity to GUID
            $resolved = Resolve-KeepitConnectorIdentity -Identity $Connector
            $connectorGuid = $resolved.ConnectorGuid
            Write-Verbose "=== Processing Connector ==="
            Write-Verbose "Connector: $($resolved.Name) ($connectorGuid)"
            Write-Verbose "RootPath: $(if ($RootPath) { $RootPath } else { '(not specified)' })"
            Write-Verbose "SearchTerms: $(if ($SearchTerms) { $SearchTerms } else { '(not specified)' })"
            Write-Verbose "ItemType: $(if ($ItemType) { $ItemType -join ', ' } else { '(not specified)' })"
            Write-Verbose "IncludeDeleted: $IncludeDeleted"
            Write-Verbose "DeletedOnly: $DeletedOnly"
            Write-Verbose "Recursive: $Recursive"

            # Note about Entra connector and DeletedOnly - API filter doesn't work, using client-side filtering
            if ($resolved.Type -eq 'azure-ad' -and $DeletedOnly) {
                Write-Verbose "Entra connector with DeletedOnly: using client-side filtering (API 'deleted' filter not supported)"
            }

            # Validate Entra ID (azure-ad) pathroot prefixes
            if ($resolved.Type -eq 'azure-ad' -and $RootPath) {
                $validEntraIdPaths = @(
                    'Administrative units',
                    'App registrations',
                    'Devices',
                    'Groups',
                    'Policies',
                    'Roles',
                    'Service principals',
                    'Users'
                )

                # Extract first path element (after optional leading slash)
                $pathToCheck = $RootPath.TrimStart('/')
                $firstElement = ($pathToCheck -split '/')[0]

                if ($firstElement -and $firstElement -notin $validEntraIdPaths) {
                    $validPathsList = $validEntraIdPaths -join ', '
                    throw "Invalid RootPath for Entra ID connector. The first path element must be one of: $validPathsList. Received: '$firstElement'"
                }
                Write-Verbose "Entra ID RootPath validation passed: '$firstElement'"
            }

            # Check if RootPath contains a UPN and convert it to a GUID
            if ($RootPath) {
                $pathSegments = $RootPath -split '/'
                # Path format: /Users/{identifier}/... - check if identifier (segment 2) contains @
                if ($pathSegments.Count -ge 3 -and $pathSegments[1] -eq 'Users' -and $pathSegments[2] -match '@') {
                    $upn = $pathSegments[2]
                    Write-Verbose "Detected UPN in RootPath: $upn - converting to GUID"

                    try {
                        $guidResult = Convert-KeepitUPNToGuid -UserPrincipalName $upn -Connector $connectorGuid -ErrorAction SilentlyContinue 2>$null
                        if ($guidResult -and $guidResult.Guid) {
                            Write-Verbose "Converted UPN '$upn' to GUID '$($guidResult.Guid)'"
                            $pathSegments[2] = $guidResult.Guid
                            $RootPath = $pathSegments -join '/'
                            Write-Verbose "Updated RootPath: $RootPath"
                        }
                        else {
                            Write-Error "User '$upn' was not found on connector '$($resolved.Name)'. Please verify the user or path and connector."
                            return
                        }
                    }
                    catch {
                        # Check if this is a 404 (user not found) error
                        if ($_.Exception.Message -match '404') {
                            Write-Error "User '$upn' was not found on connector '$($resolved.Name)'. Please verify the user or path and connector."
                            return
                        }
                        # For other errors, provide context but still stop
                        Write-Error "Failed to resolve user '$upn' on connector '$($resolved.Name)': $($_.Exception.Message)"
                        return
                    }
                }
            }

            # Build query parameters
            $queryParams = @()
            $queryParams += "apiVersion=2"

            # Device (connector)
            $queryParams += "device=$connectorGuid"

            # RootPath (with masking)
            if ($RootPath) {
                $maskedPath = ConvertTo-MaskedPath -Path $RootPath
                Write-Verbose "RootPath: $RootPath -> Masked: $maskedPath"
                $queryParams += "pathRoot=$([System.Uri]::EscapeDataString($maskedPath))"
            }

            # SearchTerms
            if ($SearchTerms) {
                $queryParams += "searchTerms=$([System.Uri]::EscapeDataString($SearchTerms))"
            }

            # ItemName (exact match)
            if ($ItemName) {
                $queryParams += "itemName=$([System.Uri]::EscapeDataString($ItemName))"
            }

            # Recursive
            if ($Recursive) {
                $queryParams += "recursive=1"
            }

            # FullHistory
            if ($FullHistory) {
                $queryParams += "fullHistory=1"
            }

            # CountOnly - set includeBody=0 to get just the count
            if ($CountOnly) {
                $queryParams += "includeBody=0"
                Write-Verbose "CountOnly mode: includeBody=0"
            }

            if ($StartTime -and $EndTime) {
                # Check if StartTime and EndTime are the same date (whole-day search)
                if ($StartTime.Date -eq $EndTime.Date) {
                    Write-Verbose "StartTime and EndTime are the same date - expanding to full day"
                    $startTimeStr = ConvertTo-KeepitTimestamp -DateTime $StartTime.Date
                    $endTimeStr = ConvertTo-KeepitTimestamp -DateTime $EndTime.Date.AddDays(1).AddSeconds(-1)
                }
                else {
                    $startTimeStr = ConvertTo-KeepitTimestamp -DateTime $StartTime
                    $endTimeStr = ConvertTo-KeepitTimestamp -DateTime $EndTime
                }
                $queryParams += "snaptimeFrom=$startTimeStr"
                $queryParams += "snaptimeTo=$endTimeStr"
            }
            elseif ($StartTime) {
                $startTimeStr = ConvertTo-KeepitTimestamp -DateTime $StartTime
                $queryParams += "snaptimeFrom=$startTimeStr"
            }
            elseif ($EndTime) {
                $endTimeStr = ConvertTo-KeepitTimestamp -DateTime $EndTime
                $queryParams += "snaptimeTo=$endTimeStr"
            }

            # Build filter expression; we always exclude system items but we need to include / exclude deleted items based on the parameters
            # Model URL: filterOr=AND:deleted,!sys;
            $filterParts = @()

            # When DeletedOnly is set, we need 'deleted' first to match model URL
            # Note: The API 'deleted' filter doesn't work for Entra (azure-ad) connectors,
            # so we skip the API filter and rely on client-side filtering for those
            if ($DeletedOnly -and $resolved.Type -ne 'azure-ad') {
                $filterParts += 'deleted'
            }
            $filterParts += '!sys'

            # Add range(received:...) filter for source-system received date
            # Uses date-only ISO 8601 format (YYYY-MM-DD) to avoid colon
            # collision with range(key:from:to) delimiter syntax.
            if ($ReceivedTime -or $ReceivedEndTime) {
                $lower = if ($ReceivedTime) {
                    $ReceivedTime.ToUniversalTime().ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
                } else {
                    '1970-01-01'
                }
                $upper = if ($ReceivedEndTime) {
                    $ReceivedEndTime.ToUniversalTime().ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
                } else {
                    [DateTime]::UtcNow.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
                }
                $filterParts += "range(received:$($lower):$($upper))"
            }

            # Add item type filters
            $itemTypeFilters = @()
            if ($ItemType) {
                foreach ($type in $ItemType) {
                    $itemTypeFilters += $type.ToLower()
                }
            }

            # Build the final filter string
            $filterString = ''
            if ($FilterExpression) {
                # User provided custom filter - use it directly
                $filterString = $FilterExpression
            }
            elseif ($filterParts.Count -gt 0 -or $itemTypeFilters.Count -gt 0) {
                # Build filter from components
                $groups = @()

                if ($filterParts.Count -gt 0) {
                    $groups += "AND:$($filterParts -join ',')"
                }

                if ($itemTypeFilters.Count -gt 0) {
                    $groups += "OR:$($itemTypeFilters -join ',')"
                }

                $filterString = $groups -join ';'
            }

            if ($filterString) {
                # Add trailing semicolon to match model URL format
                if (-not $filterString.EndsWith(';')) {
                    $filterString += ';'
                }
                # Use filterOr when DeletedOnly is set (matches model URL), otherwise respect FilterMode
                $filterParam = if ($DeletedOnly -or $FilterMode -eq 'Or') { 'filterOr' } else { 'filterAnd' }
                $queryParams += "$filterParam=$([System.Uri]::EscapeDataString($filterString))"
                Write-Verbose "Filter ($filterParam): $filterString"
            }

            # Show all query parameters
            Write-Verbose "=== Query Parameters (before pagination) ==="
            foreach ($param in $queryParams) {
                Write-Verbose "  $param"
            }

            # Headers for the request
            $headers = @{
                'Authorization' = $authHeader
                'Content-Type'  = 'application/json'
                'Accept'        = 'application/json'
            }

            # Handle CountOnly mode separately - just one request to get the count
            if ($CountOnly) {
                $countParams = $queryParams + @("count=1", "startIndex=0")
                $queryString = $countParams -join '&'
                $uri = "$baseUrl/users/$userId/bsearch?$queryString"

                Write-Verbose "=== CountOnly API Request ==="
                Write-Verbose "Request URI: $uri"

                # Use Invoke-WebRequest for raw response to avoid PowerShell's unpredictable XML deserialization
                $webResponse = $null
                try {
                    $webResponse = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
                }
                catch {
                    # Handle 404 errors gracefully
                    $exMsg = $_.Exception.Message
                    if ($exMsg -match '404' -or $exMsg -match 'path does not exist') {
                        $pathInfo = if ($RootPath) { "'$RootPath'" } else { "specified path" }
                        Write-Warning "Path not found: $pathInfo does not exist on connector '$($resolved.Name)'. Count: 0"
                        [PSCustomObject]@{
                            ConnectorGuid = $connectorGuid
                            RootPath      = $RootPath
                            SearchTerms   = $SearchTerms
                            Count         = 0
                        }
                        return
                    }
                    # Re-throw other errors to be handled by the outer catch block
                    throw
                }
                $rawContent = $webResponse.Content

                # Handle byte array response (PowerShell 7 may return byte[] for some content types)
                if ($rawContent -is [byte[]]) {
                    $rawContent = [System.Text.Encoding]::UTF8.GetString($rawContent)
                }

                Write-Verbose "CountOnly Response Status: $($webResponse.StatusCode)"
                Write-Verbose "CountOnly Response Content-Type: $($webResponse.Headers.'Content-Type')"
                if ($rawContent) {
                    Write-Verbose "CountOnly Raw Content (first 500 chars): $($rawContent.Substring(0, [Math]::Min(500, $rawContent.Length)))"
                }
                else {
                    Write-Verbose "CountOnly Raw Content: (empty)"
                }

                # Extract total count from XML response
                # API consistently returns application/atom+xml with opensearch:totalResults
                $totalCount = 0
                try {
                    $xmlDoc = [xml]$rawContent
                    $totalNode = $xmlDoc.SelectSingleNode("//*[local-name()='totalResults']")
                    if ($null -ne $totalNode) {
                        $totalCount = [int]$totalNode.InnerText
                        Write-Verbose "[COUNT-BRANCH] Found XML totalResults: $totalCount"
                    }
                }
                catch {
                    Write-Verbose "XML parsing failed: $($_.Exception.Message)"
                }

                Write-Verbose "Total count from API: $totalCount"

                # Return count object
                [PSCustomObject]@{
                    ConnectorGuid = $connectorGuid
                    RootPath      = $RootPath
                    SearchTerms   = $SearchTerms
                    Count         = $totalCount
                }

                return
            }

            # Pagination - will be updated in loop
            $currentIndex = $StartIndex
            $totalReturned = 0
            $hasMoreResults = $true
            # When client-side filtering is active (Entra connector + DeletedOnly),
            # always request full page from the API so that filtered-out items don't
            # cause the shrinking $requestCount to terminate pagination early.
            $clientSideFiltering = ($resolved.Type -eq 'azure-ad' -and $DeletedOnly)

            while ($hasMoreResults) {
                # Calculate count for this request
                $requestCount = if ($isUnlimited -or $clientSideFiltering) {
                    $pageSize
                }
                else {
                    [Math]::Min($pageSize - $totalReturned, 100)
                }

                if ($requestCount -le 0) {
                    break
                }

                # Build final query string with pagination
                $paginatedParams = $queryParams + @("count=$requestCount", "startIndex=$currentIndex")
                $queryString = $paginatedParams -join '&'
                $uri = "$baseUrl/users/$userId/bsearch?$queryString"

                Write-Verbose "=== API Request ==="
                Write-Verbose "Request URI: $uri"
                Write-Verbose "Fetching results $currentIndex to $($currentIndex + $requestCount - 1)"

                # Make API call
                $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop

                # Debug: Show response structure
                Write-Verbose "=== API Response ==="
                if ($null -eq $response) {
                    Write-Verbose "Response is null"
                }
                else {
                    $responseType = if ($response) { $response.GetType().FullName } else { 'null' }
                    Write-Verbose "Response Type: $responseType"

                    if ($response -is [System.Xml.XmlDocument]) {
                        Write-Verbose "Response is XmlDocument"
                        if ($response.DocumentElement) {
                            Write-Verbose "Root element: $($response.DocumentElement.LocalName)"
                            if ($response.DocumentElement.ChildNodes) {
                                Write-Verbose "Child elements: $($response.DocumentElement.ChildNodes | ForEach-Object { $_.LocalName } | Join-String -Separator ', ')"
                            }
                        }
                    }
                    elseif ($response -is [System.Xml.XmlElement]) {
                        Write-Verbose "Response is XmlElement: $($response.LocalName)"
                    }
                    elseif ($response -is [PSCustomObject] -or $response -is [hashtable]) {
                        Write-Verbose "Response is Object/Hashtable"
                        Write-Verbose "Top-level properties: $($response.PSObject.Properties.Name -join ', ')"
                        if ($response.feed) {
                            Write-Verbose "feed properties: $($response.feed.PSObject.Properties.Name -join ', ')"
                            if ($response.feed.entry) {
                                $entryCount = if ($response.feed.entry -is [System.Array]) { $response.feed.entry.Count } else { 1 }
                                Write-Verbose "feed.entry count: $entryCount"
                            }
                            if ($response.feed.'opensearch:totalResults') {
                                Write-Verbose "Total results (opensearch): $($response.feed.'opensearch:totalResults')"
                            }
                        }
                    }
                    elseif ($response -is [string]) {
                        Write-Verbose "Response is string (first 500 chars): $($response.Substring(0, [Math]::Min(500, $response.Length)))"
                    }
                    else {
                        Write-Verbose "Response is other type"
                    }
                }

                # Parse response - API returns application/atom+xml
                # PowerShell converts multiple results to System.Array, single result to XmlDocument
                $entries = @()

                if ($null -eq $response) {
                    # Null response means empty feed - no results found
                    Write-Verbose "[PARSE-NULL] Response is null - no results in this page"
                    # $entries stays empty, loop will exit
                }
                elseif ($response -is [System.Array]) {
                    # Multiple results: PowerShell unpacked the XML into an array
                    Write-Verbose "[PARSE-ARRAY] Direct array with $($response.Count) items"
                    $entries = $response
                }
                elseif ($response -is [System.Xml.XmlDocument] -or $response -is [System.Xml.XmlElement]) {
                    # XML response - could be single entry or feed with entries
                    $root = if ($response -is [System.Xml.XmlDocument]) { $response.DocumentElement } else { $response }
                    if ($root.LocalName -eq 'entry') {
                        # Single result: root element is the entry itself
                        Write-Verbose "[PARSE-XML] Single entry (XmlElement)"
                        $entries = @($root)
                    }
                    elseif ($root.LocalName -eq 'feed') {
                        # Feed with entries: extract entry elements
                        $entryNodes = $root.SelectNodes("//*[local-name()='entry']")
                        if ($entryNodes -and $entryNodes.Count -gt 0) {
                            Write-Verbose "[PARSE-XML] Feed with $($entryNodes.Count) entries"
                            $entries = @($entryNodes)
                        }
                        else {
                            Write-Verbose "[PARSE-XML] Feed with no entries"
                        }
                    }
                    else {
                        Write-Verbose "[PARSE-XML] Unexpected root element: $($root.LocalName)"
                    }
                }
                else {
                    # Fallback for unexpected response formats
                    Write-Verbose "[PARSE-FALLBACK] Unexpected response type: $($response.GetType().FullName)"
                    try {
                        $responseJson = $response | ConvertTo-Json -Depth 3 -Compress -ErrorAction SilentlyContinue
                        if ($responseJson) {
                            Write-Verbose "Response (first 2000 chars): $($responseJson.Substring(0, [Math]::Min(2000, $responseJson.Length)))"
                        }
                    }
                    catch {
                        Write-Verbose "Could not convert response to JSON: $($_.Exception.Message)"
                    }
                }

                # Filter out null entries that can occur from @($null)
                $entries = @($entries | Where-Object { $null -ne $_ })
                Write-Verbose "Parsed $($entries.Count) entries from response"

                if ($entries.Count -eq 0) {
                    $hasMoreResults = $false
                    break
                }

                # Process and output each entry
                $entryIndex = 0
                foreach ($entry in $entries) {
                    # Skip null entries
                    if ($null -eq $entry) {
                        Write-Verbose "Skipping null entry at index $entryIndex"
                        $entryIndex++
                        continue
                    }

                    # Debug first entry structure
                    if ($entryIndex -eq 0) {
                        Write-Verbose "=== First Entry Structure ==="
                        try {
                            Write-Verbose "Entry type: $($entry.GetType().FullName)"
                            if ($entry -is [System.Xml.XmlElement]) {
                                Write-Verbose "Entry is XmlElement, LocalName: $($entry.LocalName)"
                                Write-Verbose "Child elements: $($entry.ChildNodes | ForEach-Object { $_.LocalName } | Where-Object { $_ } | Join-String -Separator ', ')"
                            }
                            else {
                                $entryProps = $entry.PSObject.Properties.Name -join ', '
                                Write-Verbose "Entry properties: $entryProps"
                            }
                        }
                        catch {
                            Write-Verbose "Could not enumerate entry properties: $($_.Exception.Message)"
                        }
                    }
                    $entryIndex++

                    # Extract metadata into a hashtable
                    $metadata = @{}

                    # Handle different response structures
                    $id = $null
                    $name = $null
                    $title = $null
                    $updated = $null
                    $size = $null
                    $contentType = $null
                    $isDeleted = $false
                    $detectedType = $null

                    # Try to extract standard Atom fields
                    $id = Get-SafeValue $entry 'id'
                    $title = Get-SafeValue $entry 'title'
                    $updated = Get-SafeValue $entry 'updated'
                    $published = Get-SafeValue $entry 'published'

                    # Try to extract Keepit-specific fields (kng namespace)
                    # PowerShell XML converts namespaced elements - try both with and without namespace
                    $name = Get-SafeValue $entry 'kng:name'
                    if (-not $name) { $name = Get-SafeValue $entry 'name' }

                    $sizeStr = Get-SafeValue $entry 'kng:size'
                    if (-not $sizeStr) { $sizeStr = Get-SafeValue $entry 'size' }
                    if ($sizeStr) {
                        try { $size = [long]$sizeStr } catch { $size = $null }
                    }

                    # Check for deleted status - the <deleted/> tag may be empty (self-closing)
                    # or contain 'true'/'1'. If the element exists at all, the item is deleted.
                    $isDeleted = $false
                    if ($entry -is [System.Xml.XmlElement]) {
                        # Check for kng:deleted or deleted element existence
                        $deletedNode = $entry.SelectSingleNode("*[local-name()='deleted']")
                        if ($deletedNode) {
                            $isDeleted = $true
                        }
                    }
                    else {
                        # For non-XML (PSCustomObject), check for property existence
                        # If the 'deleted' or 'kng:deleted' property exists, the item is deleted
                        $hasDeletedProp = ($entry.PSObject.Properties.Name -contains 'deleted') -or
                                          ($entry.PSObject.Properties.Name -contains 'kng:deleted')
                        if ($hasDeletedProp) {
                            $isDeleted = $true
                        }
                        else {
                            # Fallback: check for value 'true' or '1'
                            $deletedStr = Get-SafeValue $entry 'kng:deleted'
                            if (-not $deletedStr) { $deletedStr = Get-SafeValue $entry 'deleted' }
                            if ($deletedStr -eq 'true' -or $deletedStr -eq '1') {
                                $isDeleted = $true
                            }
                        }
                    }

                    $detectedType = Get-SafeValue $entry 'kng:class'
                    if (-not $detectedType) { $detectedType = Get-SafeValue $entry 'class' }

                    # Content type from link or content element
                    try {
                        if ($entry.content) {
                            $contentType = if ($entry.content -is [System.Xml.XmlElement]) {
                                $entry.content.GetAttribute('type')
                            }
                            elseif ($entry.content.type) {
                                $entry.content.type
                            }
                            else { $null }
                        }
                        if (-not $contentType -and $entry.link) {
                            $links = if ($entry.link -is [System.Array]) { $entry.link } else { @($entry.link) }
                            foreach ($link in $links) {
                                $linkType = if ($link -is [System.Xml.XmlElement]) {
                                    $link.GetAttribute('type')
                                }
                                elseif ($link.type) {
                                    $link.type
                                }
                                else { $null }
                                if ($linkType) {
                                    $contentType = $linkType
                                    break
                                }
                            }
                        }
                    }
                    catch {
                        Write-Verbose "Warning: Could not extract content type: $($_.Exception.Message)"
                    }

                    # Derive ItemType from contentType if not already set
                    if (-not $detectedType) {
                        # Mail messages: contentType contains 'message/rfc822'
                        if ($contentType -and $contentType -like '*message/rfc822*') {
                            $detectedType = 'Message'
                        }
                        # Entra ID users: connector is azure-ad, item is folder-like, and path contains /Users
                        elseif ($resolved.Type -eq 'azure-ad' -and $contentType -like '*folder*' -and $RootPath -like '*/Users*') {
                            $detectedType = 'user'
                        }
                        # OneDrive/file items: folder contentType
                        elseif ($contentType -eq 'folder') {
                            $detectedType = 'folder'
                        }
                        # OneDrive/file items: application/* or image/* contentType
                        elseif ($contentType -and ($contentType -like 'application/*' -or $contentType -like 'image/*')) {
                            $detectedType = 'file'
                        }
                    }

                    # Collect all other properties as metadata
                    # Known fields already extracted above — skip them when building the metadata hashtable
                    $skipFields = @('id', 'title', 'updated', 'published', 'name', 'size', 'deleted', 'class', 'content', 'link', 'category')
                    try {
                        if ($entry -is [System.Xml.XmlElement]) {
                            # Iterate XML child elements, with special handling for kng:meta
                            foreach ($childNode in $entry.ChildNodes) {
                                $nodeName = $childNode.LocalName
                                if (-not $nodeName -or $nodeName -in $skipFields) { continue }

                                if ($nodeName -eq 'meta') {
                                    # kng:meta elements use the 'key' attribute as the field name
                                    $metaKey = $childNode.GetAttribute('key')
                                    if (-not $metaKey) { continue }
                                    if ($metaKey -in $skipFields) { continue }
                                    # Empty elements (e.g. <kng:meta key="protected"/>) are boolean flags
                                    $metaValue = $childNode.InnerText
                                    $metadata[$metaKey] = if ($metaValue) { $metaValue } else { $true }
                                }
                                else {
                                    # Other namespaced elements — store InnerText or $true for empty
                                    $nodeValue = $childNode.InnerText
                                    $metadata[$nodeName] = if ($nodeValue) { $nodeValue } else { $true }
                                }
                            }
                        }
                        elseif ($entry.PSObject.Properties) {
                            foreach ($prop in $entry.PSObject.Properties) {
                                $propName = $prop.Name
                                if ($propName -and $propName -notin $skipFields -and $propName -notin @('kng:name', 'kng:size', 'kng:deleted', 'kng:class')) {
                                    $metadata[$propName] = $prop.Value
                                }
                            }
                        }
                    }
                    catch {
                        Write-Verbose "Warning: Could not extract metadata from entry: $($_.Exception.Message)"
                    }

                    # Extract size from kng:meta elements if Size not already set
                    if (-not $size) {
                        try {
                            if ($entry -is [System.Xml.XmlElement]) {
                                foreach ($childNode in $entry.ChildNodes) {
                                    if ($childNode.LocalName -eq 'meta' -and $childNode.GetAttribute('key') -eq 'size') {
                                        $size = $childNode.InnerText
                                        break
                                    }
                                }
                            }
                        }
                        catch {
                            Write-Verbose "Warning: Could not extract size from meta: $($_.Exception.Message)"
                        }
                    }

                    # Client-side filtering for DeletedOnly (API filter doesn't work for all connector types)
                    if ($DeletedOnly -and -not $isDeleted) {
                        Write-Verbose "Skipping non-deleted item: $name"
                        continue
                    }

                    # Create and output result object
                    [PSCustomObject]@{
                        Id            = $id
                        Name          = $name
                        Title         = $title
                        Updated       = $updated
                        Published     = $published
                        Size          = $size
                        ContentType   = $contentType
                        ItemType      = $detectedType
                        IsDeleted     = $isDeleted
                        ConnectorGuid = $connectorGuid
                        Metadata      = $metadata
                    }

                    $totalReturned++

                    # Check if we've reached the requested count
                    if (-not $isUnlimited -and $totalReturned -ge $pageSize) {
                        $hasMoreResults = $false
                        break
                    }
                }

                # Check if we should continue pagination
                if ($entries.Count -lt $requestCount) {
                    # Received fewer results than requested - no more results
                    Write-Verbose "Received fewer entries ($($entries.Count)) than requested ($requestCount) - no more results"
                    $hasMoreResults = $false
                }
                elseif ($isUnlimited) {
                    # Continue to next page for unlimited
                    $currentIndex += $entries.Count
                    Write-Verbose "Unlimited mode: advancing to index $currentIndex"
                }
                elseif ($totalReturned -lt $pageSize) {
                    # Continue to next page until we reach requested ResultSize
                    $currentIndex += $entries.Count
                    Write-Verbose "Pagination: advancing to index $currentIndex (have $totalReturned of $pageSize)"
                }
                else {
                    Write-Verbose "Reached requested ResultSize ($pageSize)"
                    $hasMoreResults = $false
                }
            }

            Write-Verbose "Total results returned: $totalReturned"

            if ($totalReturned -eq 0) {
                Write-Verbose "Search-KeepitSnapshot: No matching results found"
            }
        }
        catch {
            # Handle specific HTTP errors with cleaner messages
            $statusCode = $null
            $errorDetail = $null
            $exceptionMessage = $_.Exception.Message

            # Try multiple methods to extract status code
            if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
                $statusCode = $_.Exception.Response.StatusCode.value__
            }
            elseif ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = $_.Exception.Response.StatusCode.value__
            }

            # Fallback: extract status code from exception message (e.g., "404 (Not Found)")
            if (-not $statusCode -and $exceptionMessage -match '\b(4\d{2}|5\d{2})\b') {
                $statusCode = [int]$Matches[1]
            }

            # Try to extract error details from ErrorDetails
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $errorDetail = $_.ErrorDetails.Message
            }

            # Handle 404 Not Found - path doesn't exist
            if ($statusCode -eq 404 -or $exceptionMessage -match 'path does not exist') {
                $pathInfo = if ($RootPath) { "'$RootPath'" } else { "specified path" }
                Write-Warning "Path not found: $pathInfo does not exist on connector '$($resolved.Name)'. No results returned."
                return
            }

            # Default error handling for other errors
            # Use $Connector (input parameter) as fallback if $connectorGuid was never assigned
            $connectorIdentifier = if ($connectorGuid) { $connectorGuid } else { $Connector }
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Failed to search connector $connectorIdentifier : $exceptionMessage", $_.Exception),
                    'KeepitApiError',
                    [System.Management.Automation.ErrorCategory]::ConnectionError,
                    $connectorIdentifier
                )
            )
        }
    }
}

<#
.SYNOPSIS
    Converts a path to Keepit masked path format
.DESCRIPTION
    Masks special characters in paths for the BSearch API:
    - : becomes -c
    - / becomes -s (within path segments, not the segment separator)
    - - becomes --
.PARAMETER Path
    The path to mask
.OUTPUTS
    String - The masked path
#>
function Get-KeepitItemAttributes {
    <#
    .SYNOPSIS
        Retrieves metadata attributes for an item in the Keepit backup snapshot tree.
    .DESCRIPTION
        Queries the snapshot content API to return container-level metadata attributes
        that are not available through the bsearch API, such as the 'protected' flag
        on SharePoint site collections.

        By default, uses the latest snapshot. Specify -SnapshotId to query a specific
        snapshot.
    .PARAMETER Connector
        The connector name or GUID to query.
    .PARAMETER Path
        The path within the backup tree. For SharePoint sites, use the full URL path,
        e.g. '/SharePoint/https://tenant.sharepoint.com/sites/MySite'.
    .PARAMETER SnapshotId
        Optional snapshot ID. If omitted, the latest snapshot is used.
    .PARAMETER Credential
        Optional PSCredential for authentication. If omitted, uses the cached
        authentication from Connect-KeepitService.
    .EXAMPLE
        Get-KeepitItemAttributes -Connector 'SharePoint' -Path '/SharePoint'

        Lists top-level attributes of the SharePoint root container.
    .EXAMPLE
        Get-KeepitItemAttributes -Connector 'SharePoint' -Path '/SharePoint/https://tenant.sharepoint.com/sites/Retail'

        Retrieves all metadata attributes for the specified SharePoint site,
        including the 'protected' flag if present.
    .EXAMPLE
        Get-KeepitConnector | Get-KeepitItemAttributes -Path '/SharePoint'

        Retrieves SharePoint root attributes for all connectors via pipeline.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('ConnectorGuid', 'Name')]
        [ValidateNotNullOrEmpty()]
        [string]$Connector,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter()]
        [string]$SnapshotId,

        [Parameter()]
        [PSCredential]$Credential
    )

    begin {
        Write-Verbose "Get-KeepitItemAttributes: Retrieving item attributes from snapshot content API"
        $authHeader = Get-AuthHeader -Credential $Credential
        $baseUrl = Get-KeepitBaseUrl
        $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl
    }

    process {
        try {
            # Resolve connector identity to GUID
            $resolved = Resolve-KeepitConnectorIdentity -Identity $Connector
            $connectorGuid = $resolved.ConnectorGuid
            Write-Verbose "Connector: $($resolved.Name) ($connectorGuid)"

            # Get latest snapshot ID if not provided
            $snapshotIdToUse = $SnapshotId
            if (-not $snapshotIdToUse) {
                Write-Verbose "No SnapshotId provided, fetching latest snapshot"
                $snapshotUri = "$baseUrl/users/$userId/devices/$connectorGuid/history/latest"
                $snapshotHeaders = @{
                    'Authorization' = $authHeader
                    'Accept'        = 'application/vnd.keepit.v4+xml'
                    'Content-Type'  = 'application/xml'
                }
                $snapshotResponse = Invoke-RestMethod -Uri $snapshotUri -Method Get -Headers $snapshotHeaders -ErrorAction Stop

                $backup = $null
                if ($snapshotResponse.history.backup) {
                    $backup = $snapshotResponse.history.backup
                }
                elseif ($snapshotResponse.DocumentElement.backup) {
                    $backup = $snapshotResponse.DocumentElement.backup
                }
                if (-not $backup) {
                    throw "No snapshots found for connector '$($resolved.Name)' ($connectorGuid)"
                }
                if ($backup -is [System.Array]) {
                    $backup = $backup[0]
                }
                $snapshotIdToUse = if ($backup.id) { $backup.id } else { $backup.root }
                Write-Verbose "Using latest snapshot: $snapshotIdToUse"
            }

            # Mask the path for the content API
            # Unlike bsearch (where pathRoot is URL-encoded in a query parameter),
            # the content API embeds the path in the URL. URL-containing node names
            # (e.g., SharePoint site URLs) must have internal / escaped to -s.
            if ($Path -match '^(/[^/]+)/(https?://.+)$') {
                # Path contains a URL (SharePoint site) — mask prefix normally,
                # then mask the entire URL as a single tree-node segment
                $pathPrefix = $Matches[1]
                $urlSegment = $Matches[2]

                # Mask prefix segment: - → --, : → -c
                $maskedPrefix = $pathPrefix -replace '(?<!-)-(?!-)', '--'
                $maskedPrefix = $maskedPrefix -replace ':', '-c'

                # Mask URL as one segment: - → --, : → -c, / → -s
                $maskedUrl = $urlSegment -replace '(?<!-)-(?!-)', '--'
                $maskedUrl = $maskedUrl -replace ':', '-c'
                $maskedUrl = $maskedUrl -replace '/', '-s'

                $maskedPath = "$maskedPrefix/$maskedUrl"
            }
            else {
                # No embedded URL — standard per-segment masking
                $maskedPath = ConvertTo-MaskedPath -Path $Path
            }
            Write-Verbose "Path: $Path -> Masked: $maskedPath"

            # Build the snapshot tree API URL
            # Endpoint: /history/{snapshotId}/{maskedPath} (no /content segment)
            $uri = "$baseUrl/users/$userId/devices/$connectorGuid/history/$snapshotIdToUse$maskedPath"
            Write-Verbose "Request URI: $uri"

            $headers = @{
                'Authorization' = $authHeader
                'Accept'        = 'application/xml'
            }

            $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop

            # Parse the response into a clean attributes object
            $attributes = [ordered]@{
                ConnectorGuid = $connectorGuid
                ConnectorName = $resolved.Name
                SnapshotId    = $snapshotIdToUse
                Path          = $Path
            }

            # Normalise: if REST returned a raw string, parse it now so the XML branch handles it.
            if ($response -is [string]) {
                try   { $response = [xml]$response }
                catch {
                    Write-Verbose "Response is not parseable XML, returning raw content"
                    $attributes['RawContent'] = $response
                    [PSCustomObject]$attributes
                    return
                }
            }

            if ($response -is [System.Xml.XmlDocument] -or $response -is [System.Xml.XmlElement]) {
                $root = if ($response -is [System.Xml.XmlDocument]) { $response.DocumentElement } else { $response }

                foreach ($attr in $root.Attributes) {
                    $attributes[$attr.LocalName] = $attr.Value
                }

                foreach ($node in $root.ChildNodes) {
                    $name = $node.LocalName
                    if (-not $name -or $name -eq '#text') { continue }

                    if ($node.IsEmpty -or [string]::IsNullOrEmpty($node.InnerText)) {
                        $attributes[$name] = $true
                    }
                    elseif ($node.HasChildNodes -and $node.ChildNodes.Count -gt 1) {
                        $childAttrs = [ordered]@{}
                        foreach ($child in $node.ChildNodes) {
                            if ($child.LocalName -and $child.LocalName -ne '#text') {
                                $childAttrs[$child.LocalName] = if ($child.IsEmpty) { $true } else { $child.InnerText }
                            }
                        }
                        $attributes[$name] = $childAttrs
                    }
                    else {
                        $attributes[$name] = $node.InnerText
                    }
                }
            }
            else {
                # PSObject or other type — enumerate properties
                foreach ($prop in $response.PSObject.Properties) {
                    $attributes[$prop.Name] = $prop.Value
                }
            }

            [PSCustomObject]$attributes
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }
}

function ConvertTo-MaskedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # Split path into segments, mask each segment, then rejoin
    $segments = $Path -split '/'
    $maskedSegments = @()

    foreach ($segment in $segments) {
        if ([string]::IsNullOrEmpty($segment)) {
            $maskedSegments += ''
            continue
        }

        # Order matters: escape - first (to --), then : (to -c), then internal / (to -s)
        # Use lookaround to skip dashes that are already doubled
        $masked = $segment -replace '(?<!-)-(?!-)', '--'
        $masked = $masked -replace ':', '-c'
        # Note: / within segment names (like URLs) need to be escaped to -s
        # But since we split on /, segments shouldn't contain / unless it's part of a URL
        # URLs like https://site.sharepoint.com would be: https-c-s-ssite.sharepoint.com

        $maskedSegments += $masked
    }

    return $maskedSegments -join '/'
}

