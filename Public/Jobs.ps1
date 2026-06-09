<#
.SYNOPSIS
    Gets backup and restore jobs for a Keepit connector
.DESCRIPTION
    Retrieves jobs (backup and restore) for a specified Keepit connector.
    By default, shows active jobs (currently running) and future jobs (scheduled to run).
    Completed jobs from the past are excluded unless an explicit date range is specified. If a date range
    is specified, the cmdlet will return the job history for the specified time range and connector.
    Results can be optionally filtered by job type and date range.
.PARAMETER Connector
    The connector name or GUID to retrieve jobs for.
    Can be piped from Get-KeepitConnector.
.PARAMETER Type
    Optional job type filter. Valid values: 'backup', 'restore'.
    If not specified, returns all job types.
.PARAMETER StartTime
    Optional start date for filtering jobs. If specified, EndTime must also be provided.
    When StartTime and EndTime are provided, the default future-only filter is disabled
    and all jobs within the date range are returned.
    Jobs are filtered based on their Start time (or Scheduled time if Start is not available).
    Only jobs with dates on or after StartTime are included.
.PARAMETER EndTime
    Optional end date for filtering jobs. If specified, StartTime must also be provided.
    When StartTime and EndTime are provided, the default future-only filter is disabled
    and all jobs within the date range are returned.
    Jobs are filtered based on their Start time (or Scheduled time if Start is not available).
    Only jobs with dates on or before EndTime are included.
.PARAMETER Completed
    Shows only jobs that have finished (End time has a value).
    Can be combined with -Scheduled using OR logic.
.PARAMETER Scheduled
    Shows only pending scheduled jobs (Scheduled has a value, Active = False, and no End value).
    Can be combined with -Completed using OR logic.
.PARAMETER Raw
    Returns the raw XML response from the API instead of parsed PowerShell objects.
    Useful for debugging or when you need the complete API response.
.PARAMETER ActiveOnly
    Adds the active-only filter to the API request, causing the server to return only
    jobs that are currently active (running). This is more efficient than client-side
    filtering when you only need active jobs, as the filtering is done server-side.
.EXAMPLE
    Get-KeepitJobs -Connector "Production M365"

    Gets active and future jobs for the connector named "Production M365"
.EXAMPLE
    Get-KeepitJobs -Connector "abc123-def456" -Type backup

    Gets only active and future backup jobs for the connector
.EXAMPLE
    Get-KeepitJobs -Connector "abc123" -StartTime (Get-Date).AddDays(-7) -EndTime (Get-Date)

    Gets all jobs from the last 7 days
.EXAMPLE
    Get-KeepitJobs -Connector "abc123" -Type restore -StartTime "2025-12-01" -EndTime "2025-12-21"

    Gets only restore jobs between December 1 and December 21, 2025
.EXAMPLE
    Get-KeepitJobs -Connector "abc123" -StartTime "2025-12-15" -EndTime "2025-12-15"

    Gets all jobs for a single day (December 15, 2025). The range is automatically expanded to cover 00:00:00 to 23:59:59.
.EXAMPLE
    Get-KeepitConnector | Get-KeepitJobs

    Gets all jobs for all connectors
.EXAMPLE
    Get-KeepitJobs -Connector "Production M365" -Completed

    Gets only completed jobs for the connector
.EXAMPLE
    Get-KeepitJobs -Connector "Production M365" -Scheduled

    Gets only scheduled (pending) jobs for the connector
.EXAMPLE
    Get-KeepitJobs -Connector "Production M365" -Raw

    Returns the raw XML response from the API for debugging purposes
.EXAMPLE
    Get-KeepitJobs -Connector "Production M365" -ActiveOnly

    Gets only active jobs using server-side filtering.
.OUTPUTS
    PSCustomObject containing job details with properties:
        - JobGuid: The job GUID
        - ConnectorGuid: The connector GUID
        - Type: Job type (backup or restore)
        - Description: Job description
        - Active: Boolean indicating if job is active
        - Priority: Job priority
        - Scheduled: Scheduled start time
        - Start: Actual start time
        - End: Completion time (if completed)

    When -Raw is specified, returns the raw XML response as a string.
.NOTES
    Requires an active connection via Connect-KeepitService.
    Accepts connector objects from Get-KeepitConnector via pipeline.
    DEFAULT BEHAVIOR: Shows active jobs (currently running) and future jobs (scheduled to run).
    - Active jobs are always included regardless of when they started
    - Future jobs are included if Start or Scheduled time is greater than current time
    - Completed jobs from the past are excluded
    To see all jobs including completed past jobs, specify a date range using StartTime and EndTime.
    Date filtering uses Start time if available, falls back to Scheduled time.
    Jobs without Start or Scheduled times are excluded by the default filter.
    StartTime and EndTime must be provided together - one cannot be specified without the other.
    If StartTime and EndTime are the same day, the range is expanded to cover the full day (00:00:00 to 23:59:59).
#>
function Get-KeepitJobs {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector,

        [ValidateSet('backup', 'restore')]
        [string]$Type,

        [DateTime]$StartTime,

        [DateTime]$EndTime,

        [switch]$Completed,

        [switch]$Scheduled,

        [switch]$Raw,

        [switch]$ActiveOnly
    )

    begin {
        Write-Verbose "Get-KeepitJobs"
        $totalJobsReturned = 0

        # Check if any status filters are specified
        $hasStatusFilter = $Completed -or $Scheduled
        if ($hasStatusFilter) {
            Write-Verbose "Status filter(s) specified: Completed=$Completed, Scheduled=$Scheduled"
        }

        # Validate date parameters
        $hasStartTime = $PSBoundParameters.ContainsKey('StartTime')
        $hasEndTime = $PSBoundParameters.ContainsKey('EndTime')

        if ($hasStartTime -and -not $hasEndTime) {
            throw "StartTime specified without EndTime. Both StartTime and EndTime must be provided together."
        }

        if ($hasEndTime -and -not $hasStartTime) {
            throw "EndTime specified without StartTime. Both StartTime and EndTime must be provided together."
        }

        if ($hasStartTime -and $hasEndTime) {
            # Validate dates first - catch inverted ranges before same-day expansion
            if ($StartTime -ge $EndTime -and $StartTime.Date -ne $EndTime.Date) {
                throw "StartTime must be less than EndTime. StartTime: $StartTime, EndTime: $EndTime"
            }

            # Handle same-day search - expand to full day
            if ($StartTime.Date -eq $EndTime.Date) {
                Write-Verbose "StartTime and EndTime are the same date - expanding to full day"
                $StartTime = $StartTime.Date  # Midnight start
                $EndTime = $EndTime.Date.AddDays(1).AddSeconds(-1)  # 23:59:59
                Write-Verbose "Expanded range: $($StartTime.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)) to $($EndTime.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture))"
            }

            # Normalize times to UTC for consistent comparison with API times (which are UTC)
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

            Write-Verbose "Date range filter (UTC): $($StartTime.ToString('yyyy-MM-ddTHH:mm:ssZ')) to $($EndTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
            $useFutureFilter = $false
        }
        else {
            # No dates specified - default to showing active jobs and future jobs
            $useFutureFilter = $true
            Write-Verbose "No date range specified - will filter for active jobs and jobs scheduled in the future"
        }

        # Get authentication header and base URL once for all pipeline items
        try {
            $authHeader = Get-AuthHeader
            $baseUrl = Get-KeepitBaseUrl
            Write-Verbose "Base URL: $baseUrl"

            $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl
            Write-Verbose "User ID: $userId"
            Write-Verbose "Initialization completed successfully"
        }
        catch {
            throw
        }
    }

    process {
        try {
            # Capture current time fresh for each pipeline item
            if ($useFutureFilter) {
                $currentTime = [DateTime]::UtcNow
                Write-Verbose "Current UTC time for future filter: $($currentTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
            }

            # Resolve connector identity to GUID
            $resolved = Resolve-KeepitConnectorIdentity -Identity $Connector
            $connectorGuid = $resolved.ConnectorGuid
            Write-Verbose "=== Get-KeepitJobs: Processing Connector ==="
            Write-Verbose "Connector: $($resolved.Name) ($connectorGuid)"
            if ($PSBoundParameters.ContainsKey('Type')) {
                Write-Verbose "Job Type Filter: $Type"
            }
            else {
                Write-Verbose "Job Type Filter: None (all types)"
            }
            if ($hasStartTime -and $hasEndTime) {
                Write-Verbose "Date Range Filter: $StartTime to $EndTime"
            }

            # Build request
            $uri = "$baseUrl/users/$userId/devices/$connectorGuid/jobs"
            $activeJobsOnlyValue = if ($ActiveOnly) { 'true' } else { 'false' }
            $headers = @{
                'Authorization' = $authHeader
                'Content-Type' = 'application/xml'
                'Accept' = 'application/vnd.keepit.v4+xml'
                'active-jobs-only' = $activeJobsOnlyValue
            }

            Write-Verbose "=== API Request Details ==="
            Write-Verbose "Method: GET"
            Write-Verbose "URI: $uri"
            Write-Verbose "active-jobs-only: $activeJobsOnlyValue"

            Write-Verbose "=== Sending API Request ==="

            # If -Raw is specified, return the raw XML response
            if ($Raw) {
                Write-Verbose "Returning raw XML response"
                $webResponse = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
                $webResponse.Content
                return
            }

            # Make API call
            $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop

            Write-Verbose "=== API Response Received ==="
            Write-Verbose "Response Type: $($response.GetType().FullName)"

            # Parse response
            Write-Verbose "Parsing jobs from response..."
            $jobs = @()

            if ($response.jobs.job) {
                # Normalize to array
                if ($response.jobs.job -is [System.Array]) {
                    $jobs = $response.jobs.job
                    Write-Verbose "Found $($jobs.Count) jobs"
                }
                else {
                    $jobs = @($response.jobs.job)
                    Write-Verbose "Found 1 job"
                }
            }
            else {
                Write-Verbose "No jobs found in response"
            }

            # Process and output each job
            foreach ($job in $jobs) {
                # Apply type filter if specified
                if ($PSBoundParameters.ContainsKey('Type') -and $job.type -ne $Type) {
                    Write-Verbose "Skipping job $($job.guid) - type '$($job.type)' does not match filter '$Type'"
                    continue
                }

                # Apply future filter (default behavior when no dates specified)
                if ($useFutureFilter) {
                    # Always include active jobs (currently running)
                    $isActive = $job.active -eq 'true' -or $job.active -eq $true
                    if ($isActive) {
                        Write-Verbose "Including job $($job.guid) - job is active (currently running)"
                    }
                    else {
                        # For non-active jobs, only include if scheduled for the future
                        # Use Start time if available, fall back to Scheduled time
                        $jobDateTime = $null
                        if ($job.start) {
                            $jobDateTime = [DateTime]::Parse($job.start, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                        }
                        elseif ($job.scheduled) {
                            $jobDateTime = [DateTime]::Parse($job.scheduled, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                        }

                        if ($jobDateTime) {
                            # Ensure job time is UTC for comparison
                            if ($jobDateTime.Kind -ne [DateTimeKind]::Utc) {
                                $jobDateTime = $jobDateTime.ToUniversalTime()
                            }
                            # Only include jobs scheduled for the future
                            if ($jobDateTime -le $currentTime) {
                                Write-Verbose "Skipping job $($job.guid) - date '$($jobDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))' is not in the future (current time: $($currentTime.ToString('yyyy-MM-ddTHH:mm:ssZ')))"
                                continue
                            }
                        }
                        else {
                            # No date available - skip jobs without scheduled times when using future filter
                            Write-Verbose "Skipping job $($job.guid) - no Start or Scheduled date available for future filtering"
                            continue
                        }
                    }
                }
                # Apply date range filter if specified
                elseif ($hasStartTime -and $hasEndTime) {
                    # Use Start time if available, fall back to Scheduled time
                    $jobDateTime = $null
                    if ($job.start) {
                        $jobDateTime = [DateTime]::Parse($job.start, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                    }
                    elseif ($job.scheduled) {
                        $jobDateTime = [DateTime]::Parse($job.scheduled, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                    }

                    if ($jobDateTime) {
                        # Ensure job time is UTC for comparison
                        if ($jobDateTime.Kind -ne [DateTimeKind]::Utc) {
                            $jobDateTime = $jobDateTime.ToUniversalTime()
                        }
                        if ($jobDateTime -lt $StartTime -or $jobDateTime -gt $EndTime) {
                            Write-Verbose "Skipping job $($job.guid) - date '$($jobDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))' is outside range $($StartTime.ToString('yyyy-MM-ddTHH:mm:ssZ')) to $($EndTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
                            continue
                        }
                    }
                    else {
                        # No date available to filter on, skip this job
                        Write-Verbose "Skipping job $($job.guid) - no Start or Scheduled date available for filtering"
                        continue
                    }
                }

                $jobObject = [PSCustomObject]@{
                    JobGuid = if ($job.guid) { $job.guid } else { $null }
                    ConnectorGuid = $connectorGuid
                    ConnectorName = $resolved.Name
                    Type = if ($job.type) { $job.type } else { 'unknown' }
                    Description = if ($job.description) { $job.description } else { '' }
                    Active = if ($job.active -eq $true -or $job.active -eq 'true') { $true } else { $false }
                    Priority = if ($job.priority) { $job.priority } else { $null }
                    Scheduled = if ($job.scheduled) { $job.scheduled } else { $null }
                    Start = if ($job.start) { $job.start } else { $null }
                    End = if ($job.end) { $job.end } else { $null }
                }

                # Apply status filters if specified (OR logic - match any specified filter)
                if ($hasStatusFilter) {
                    $matchesFilter = $false

                    # -Completed: jobs where End has a value
                    if ($Completed -and $null -ne $jobObject.End -and $jobObject.End -ne '') {
                        $matchesFilter = $true
                        Write-Verbose "Job $($jobObject.JobGuid) matches -Completed filter"
                    }

                    # -Scheduled: jobs where Scheduled has a value AND Active is False AND End is empty (pending, not completed)
                    if ($Scheduled -and ($null -ne $jobObject.Scheduled -and $jobObject.Scheduled -ne '') -and $jobObject.Active -eq $false -and ($null -eq $jobObject.End -or $jobObject.End -eq '')) {
                        $matchesFilter = $true
                        Write-Verbose "Job $($jobObject.JobGuid) matches -Scheduled filter"
                    }

                    if (-not $matchesFilter) {
                        Write-Verbose "Skipping job $($jobObject.JobGuid) - does not match any status filter"
                        continue
                    }
                }

                Write-Verbose "Outputting job: $($jobObject.JobGuid) (Type: $($jobObject.Type), Active: $($jobObject.Active))"
                $totalJobsReturned++
                $jobObject
            }

            Write-Verbose "=== End Get-KeepitJobs ==="
        }
        catch {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Failed to retrieve jobs for connector $connectorGuid : $($_.Exception.Message)", $_.Exception),
                    'KeepitJobError',
                    [System.Management.Automation.ErrorCategory]::ConnectionError,
                    $connectorGuid
                )
            )
        }
    }

    end {
        Write-Verbose "Total jobs returned: $totalJobsReturned"
    }
}

<#
.SYNOPSIS
    Retrieves historical job records for a Keepit connector
.DESCRIPTION
    Retrieves completed and past backup/restore jobs for a specified Keepit connector
    using the Keepit job history API (PUT /jobs). Unlike Get-KeepitJobs which returns
    active and future jobs, this cmdlet is designed for querying the historical record.

    Results can be filtered by type, limited in count, or restricted to failed jobs only.
.PARAMETER Connector
    The connector name or GUID to retrieve job history for.
    Can be piped from Get-KeepitConnector.
.PARAMETER StartTime
    Start of the time range for job history. Required by the API.
.PARAMETER EndTime
    Optional end of the time range. If omitted, defaults to the current time.
.PARAMETER Type
    Optional job type filter. Valid values: 'backup', 'restore'.
    If not specified, returns all job types.
.PARAMETER Limit
    Maximum number of records to return. Valid range: 1-10000.
    If not specified, the API returns its default limit.
.PARAMETER FailedOnly
    Returns only failed jobs. Cannot be combined with other status filters.
.PARAMETER Raw
    Returns the raw XML response from the API instead of parsed PowerShell objects.
    Useful for debugging or when you need the complete API response.
.EXAMPLE
    Get-KeepitJobHistory -Connector "Production M365" -StartTime (Get-Date).AddDays(-30)

    Gets all job history for the last 30 days.
.EXAMPLE
    Get-KeepitJobHistory -Connector "Production M365" -StartTime "2026-01-01" -EndTime "2026-06-01" -Type backup

    Gets only backup jobs between January 1 and June 1, 2026.
.EXAMPLE
    Get-KeepitJobHistory -Connector "abc123" -StartTime (Get-Date).AddDays(-7) -FailedOnly

    Gets only failed jobs from the last 7 days.
.EXAMPLE
    Get-KeepitJobHistory -Connector "abc123" -StartTime (Get-Date).AddDays(-30) -Limit 50

    Gets the most recent 50 job history records for the last 30 days.
.EXAMPLE
    Get-KeepitConnector | Get-KeepitJobHistory -StartTime (Get-Date).AddDays(-7)

    Gets job history for all connectors over the last 7 days.
.OUTPUTS
    PSCustomObject containing job details with properties:
        - JobGuid: The job GUID
        - ConnectorGuid: The connector GUID
        - ConnectorName: The connector name
        - Type: Job type (backup or restore)
        - Description: Job description
        - Active: Boolean indicating if the job is still active
        - Priority: Job priority
        - Scheduled: Scheduled start time
        - Start: Actual start time
        - Succeeded: Completion time when the job succeeded (null if failed or in progress)
        - Failed: Completion time when the job failed (null if succeeded or in progress)
        - Status: Human-readable status: Succeeded, Failed, Active, or Pending
        - Progress: Job progress as a float (0.0-1.0)

    When -Raw is specified, returns the raw XML response as a string.
.NOTES
    Requires an active connection via Connect-KeepitService.
    Accepts connector objects from Get-KeepitConnector via pipeline.
    The API requires StartTime (from-time). EndTime defaults to current time if omitted.
#>
function Get-KeepitJobHistory {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector,

        [Parameter(Mandatory = $true)]
        [DateTime]$StartTime,

        [DateTime]$EndTime,

        [ValidateSet('backup', 'restore')]
        [string]$Type,

        [ValidateRange(1, 10000)]
        [int]$Limit,

        [switch]$FailedOnly,

        [switch]$Raw
    )

    begin {
        Write-Verbose "Get-KeepitJobHistory: Initializing"

        # Normalize StartTime to UTC
        if ($StartTime.Kind -eq [DateTimeKind]::Unspecified) {
            $StartTime = [DateTime]::SpecifyKind($StartTime, [DateTimeKind]::Utc)
        }
        elseif ($StartTime.Kind -eq [DateTimeKind]::Local) {
            $StartTime = $StartTime.ToUniversalTime()
        }

        # Normalize EndTime to UTC (default to now if not specified)
        $hasEndTime = $PSBoundParameters.ContainsKey('EndTime')
        if ($hasEndTime) {
            if ($EndTime.Kind -eq [DateTimeKind]::Unspecified) {
                $EndTime = [DateTime]::SpecifyKind($EndTime, [DateTimeKind]::Utc)
            }
            elseif ($EndTime.Kind -eq [DateTimeKind]::Local) {
                $EndTime = $EndTime.ToUniversalTime()
            }
            if ($EndTime -le $StartTime) {
                throw "EndTime must be greater than StartTime. StartTime: $StartTime, EndTime: $EndTime"
            }
        }

        try {
            $authHeader = Get-AuthHeader
            $baseUrl = Get-KeepitBaseUrl
            $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl
            Write-Verbose "Base URL: $baseUrl, User ID: $userId"
        }
        catch {
            throw
        }
    }

    process {
        try {
            $resolved = Resolve-KeepitConnectorIdentity -Identity $Connector
            $connectorGuid = $resolved.ConnectorGuid
            Write-Verbose "Connector: $($resolved.Name) ($connectorGuid)"

            # Build filter XML body
            $fromTimeStr = $StartTime.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
            $filterXml = "<filter><from-time>$fromTimeStr</from-time>"

            if ($hasEndTime) {
                $toTimeStr = $EndTime.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
                $filterXml += "<to-time>$toTimeStr</to-time>"
            }
            if ($PSBoundParameters.ContainsKey('Type')) {
                $filterXml += "<type>$Type</type>"
            }
            if ($PSBoundParameters.ContainsKey('Limit')) {
                $filterXml += "<limit>$Limit</limit>"
            }
            if ($FailedOnly) {
                $filterXml += "<failed-only>true</failed-only>"
            }
            $filterXml += "</filter>"

            $uri = "$baseUrl/users/$userId/devices/$connectorGuid/jobs"
            $headers = @{
                'Authorization' = $authHeader
                'Content-Type'  = 'application/xml'
                'Accept'        = 'application/vnd.keepit.v4+xml'
            }

            Write-Verbose "Method: PUT, URI: $uri"
            Write-Verbose "Filter XML: $filterXml"

            if ($Raw) {
                $webResponse = Invoke-WebRequest -Uri $uri -Method Put -Headers $headers -Body $filterXml -ErrorAction Stop
                $webResponse.Content
                return
            }

            $response = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $filterXml -ErrorAction Stop

            $jobs = @()
            if ($response.jobs.job) {
                $jobs = if ($response.jobs.job -is [System.Array]) { $response.jobs.job } else { @($response.jobs.job) }
            }
            Write-Verbose "Found $($jobs.Count) job(s)"

            foreach ($job in $jobs) {
                $isActive = $job.active -eq 'true' -or $job.active -eq $true
                $status = if ($job.succeeded) { 'Succeeded' }
                           elseif ($job.failed) { 'Failed' }
                           elseif ($isActive) { 'Active' }
                           else { 'Pending' }

                [PSCustomObject]@{
                    JobGuid       = if ($job.guid) { $job.guid } else { $null }
                    ConnectorGuid = $connectorGuid
                    ConnectorName = $resolved.Name
                    Type          = if ($job.type) { $job.type } else { 'unknown' }
                    Description   = if ($job.description) { $job.description } else { '' }
                    Active        = $isActive
                    Priority      = if ($job.priority) { $job.priority } else { $null }
                    Scheduled     = if ($job.scheduled) { $job.scheduled } else { $null }
                    Start         = if ($job.start) { $job.start } else { $null }
                    Succeeded     = if ($job.succeeded) { $job.succeeded } else { $null }
                    Failed        = if ($job.failed) { $job.failed } else { $null }
                    Status        = $status
                    Progress      = if ($job.progress) { [double]$job.progress } else { $null }
                }
            }
        }
        catch {
            $errorGuid = if ($connectorGuid) { $connectorGuid } else { $Connector }
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Failed to retrieve job history for connector '$errorGuid': $($_.Exception.Message)", $_.Exception),
                    'KeepitJobHistoryError',
                    [System.Management.Automation.ErrorCategory]::ConnectionError,
                    $errorGuid
                )
            )
        }
    }
}

function Invoke-JobCancellation {
    <#
    .SYNOPSIS
        Sends a cancellation request for a single job. Used internally by Stop-KeepitJob.
    #>
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$ConnectorGuid,
        [string]$ConnectorName,
        [string]$JobGuid,
        [string]$JobStatus
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    $cancelXml = "<job><cancelled>$timestamp</cancelled></job>"

    try {
        Invoke-RestMethod -Uri $Uri -Method Put -Headers $Headers -Body $cancelXml -ErrorAction Stop | Out-Null
        [PSCustomObject]@{
            ConnectorGuid = $ConnectorGuid
            ConnectorName = $ConnectorName
            JobGuid       = $JobGuid
            Status        = 'Cancelled'
            CancelledAt   = $timestamp
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try {
                $errorXml = [xml]$_.ErrorDetails.Message
                $errorMessage = "$($errorXml.error.code): $($errorXml.error.description)"
            }
            catch { }
        }
        # Return error info; let the caller decide whether to Write-Error or throw
        [PSCustomObject]@{
            ConnectorGuid = $ConnectorGuid
            ConnectorName = $ConnectorName
            JobGuid       = $JobGuid
            Status        = "Error: $errorMessage"
            CancelledAt   = $null
            _Exception    = $_.Exception
            _ErrorMessage = $errorMessage
        }
    }
}

<#
.SYNOPSIS
    Cancels one or more running or scheduled jobs on a Keepit connector
.DESCRIPTION
    Cancels backup or restore jobs by sending a cancellation timestamp to the Keepit API.
    Can cancel a single job by GUID, or all active and scheduled jobs on a connector
    using the -All switch.

    Supports pipeline input from Get-KeepitJobs for targeted cancellation.
.PARAMETER Connector
    The connector name or GUID. Can be piped from Get-KeepitConnector or Get-KeepitJobs.
    Aliases: ConnectorGuid, Name
.PARAMETER JobGuid
    The GUID of the specific job to cancel. Accepts pipeline input from Get-KeepitJobs.
.PARAMETER All
    Cancel all active and scheduled jobs on the connector.
.EXAMPLE
    Stop-KeepitJob -Connector "Production M365" -JobGuid "abc123-def456-ghi789"

    Cancels a specific job on the connector.
.EXAMPLE
    Stop-KeepitJob -Connector "Production M365" -All

    Cancels all active and scheduled jobs on the connector.
.EXAMPLE
    Get-KeepitJobs -Connector "Production M365" -ActiveOnly | Stop-KeepitJob

    Cancels all active jobs via pipeline.
.EXAMPLE
    Stop-KeepitJob -Connector "Production M365" -All -WhatIf

    Shows what jobs would be cancelled without actually cancelling them.
.OUTPUTS
    PSCustomObject with properties:
        - ConnectorGuid: The connector GUID
        - ConnectorName: The connector name
        - JobGuid: The job GUID
        - Status: "Cancelled" or error message
        - CancelledAt: UTC timestamp of the cancellation
.NOTES
    Requires an active connection via Connect-KeepitService.
    Supports -WhatIf and -Confirm via ShouldProcess.
#>
function Stop-KeepitJob {
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Single')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true,
                   ParameterSetName = 'Single')]
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true,
                   ParameterSetName = 'All')]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector,

        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true,
                   ParameterSetName = 'Single')]
        [ValidateNotNullOrEmpty()]
        [string]$JobGuid,

        [Parameter(Mandatory = $true, ParameterSetName = 'All')]
        [switch]$All
    )

    begin {
        Write-Verbose "Stop-KeepitJob: Initializing"

        try {
            $authHeader = Get-AuthHeader
            $baseUrl = Get-KeepitBaseUrl
            $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl
            Write-Verbose "Base URL: $baseUrl, User ID: $userId"
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
            $connectorName = $resolved.Name
            Write-Verbose "Connector: $connectorName ($connectorGuid)"

            if ($All) {
                # Fetch active + scheduled jobs
                $jobsToCancel = @()
                try { $jobsToCancel += @(Get-KeepitJobs -Connector $connectorGuid -ActiveOnly) } catch {
                    Write-Warning "Failed to retrieve active jobs for connector '$connectorName': $($_.Exception.Message)"
                }
                try { $jobsToCancel += @(Get-KeepitJobs -Connector $connectorGuid -Scheduled) } catch {
                    Write-Warning "Failed to retrieve scheduled jobs for connector '$connectorName': $($_.Exception.Message)"
                }
                $jobsToCancel = $jobsToCancel | Where-Object { $_ -and $_.JobGuid }

                if ($jobsToCancel.Count -eq 0) {
                    Write-Verbose "No active or scheduled jobs found for connector '$connectorName'"
                    return
                }

                Write-Verbose "Found $($jobsToCancel.Count) job(s) to cancel"

                foreach ($job in $jobsToCancel) {
                    $uri = "$baseUrl/users/$userId/devices/$connectorGuid/jobs/$($job.JobGuid)"

                    if ($PSCmdlet.ShouldProcess("$connectorName job $($job.JobGuid) ($($job.Type))", "Cancel")) {
                        $headers = @{
                            'Authorization' = $authHeader
                            'Content-Type'  = 'application/xml'
                            'Accept'        = 'application/vnd.keepit.v4+xml'
                        }
                        $result = Invoke-JobCancellation -Uri $uri -Headers $headers `
                            -ConnectorGuid $connectorGuid -ConnectorName $connectorName `
                            -JobGuid $job.JobGuid -JobStatus $job.Type
                        if ($result._Exception) {
                            Write-Error "Failed to cancel job $($job.JobGuid): $($result._ErrorMessage)"
                            # Remove internal properties before outputting
                            $result.PSObject.Properties.Remove('_Exception')
                            $result.PSObject.Properties.Remove('_ErrorMessage')
                        }
                        $result
                    }
                }
            }
            else {
                # Single job cancellation
                $uri = "$baseUrl/users/$userId/devices/$connectorGuid/jobs/$JobGuid"

                if ($PSCmdlet.ShouldProcess("$connectorName job $JobGuid", "Cancel")) {
                    $headers = @{
                        'Authorization' = $authHeader
                        'Content-Type'  = 'application/xml'
                        'Accept'        = 'application/vnd.keepit.v4+xml'
                    }
                    $result = Invoke-JobCancellation -Uri $uri -Headers $headers `
                        -ConnectorGuid $connectorGuid -ConnectorName $connectorName `
                        -JobGuid $JobGuid -JobStatus 'single'
                    if ($result._Exception) {
                        $ex = $result._Exception
                        $msg = $result._ErrorMessage
                        $result.PSObject.Properties.Remove('_Exception')
                        $result.PSObject.Properties.Remove('_ErrorMessage')
                        $PSCmdlet.ThrowTerminatingError(
                            [System.Management.Automation.ErrorRecord]::new(
                                [System.Exception]::new("Failed to cancel job $JobGuid on connector '$connectorName': $msg", $ex),
                                'KeepitJobError',
                                [System.Management.Automation.ErrorCategory]::ConnectionError,
                                $JobGuid
                            )
                        )
                    }
                    $result
                }
            }
        }
        catch {
            $errorGuid = if ($connectorGuid) { $connectorGuid } else { $Connector }
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Failed to cancel job(s) on connector '$errorGuid': $($_.Exception.Message)", $_.Exception),
                    'KeepitJobError',
                    [System.Management.Automation.ErrorCategory]::ConnectionError,
                    $errorGuid
                )
            )
        }
    }
}

function New-AlreadyQueuedResult {
    <#
    .SYNOPSIS
        Creates a status object for WAITING_JOB_TO_START or RUNNING_JOB API errors.
        Used internally by Start-KeepitBackup.
    #>
    param(
        [string]$ConnectorGuid,
        [string]$ConnectorName,
        [string]$Status,
        [string]$ErrorCode,
        [string]$ErrorDescription,
        [string]$StartTime
    )

    [PSCustomObject]@{
        ConnectorGuid        = $ConnectorGuid
        Type                 = 'backup'
        Description          = 'Job creation skipped'
        Status               = $Status
        CreatedAt            = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        ErrorCode            = $ErrorCode
        ErrorMessage         = $ErrorDescription
        ExistingJobStartTime = $StartTime
    }
}

<#
.SYNOPSIS
    Starts a backup job on a Keepit connector
.DESCRIPTION
    Initiates a backup job for a specified Keepit connector. The backup can be started
    immediately or scheduled for a future time using the -ScheduledTime parameter.
.PARAMETER Connector
    The connector name or GUID to back up.
    Can be piped from Get-KeepitConnector.
.PARAMETER ScheduledTime
    Optional DateTime for scheduling the backup at a future time.
    Must be in the future. Times are converted to UTC for the API.
    If not specified, the backup starts immediately.
.EXAMPLE
    Start-KeepitBackup -Connector "Production M365"

    Starts an immediate backup for the connector named "Production M365"
.EXAMPLE
    Start-KeepitBackup -Connector "abc123-def456"

    Starts an immediate backup for the specified connector GUID
.EXAMPLE
    Get-KeepitConnector | Start-KeepitBackup

    Starts immediate backups for all connectors
.EXAMPLE
    Start-KeepitBackup -Connector "Production M365" -ScheduledTime (Get-Date).AddMinutes(30)

    Schedules a backup to run 30 minutes from now
.EXAMPLE
    Start-KeepitBackup -Connector "Production M365" -ScheduledTime "2026-06-15T14:00:00"

    Schedules a backup for a specific date and time
.OUTPUTS
    PSCustomObject containing backup job details with properties:
        - ConnectorGuid: The connector GUID
        - Type: Job type (backup)
        - Description: Job description
        - Status: Job status ("Active", "Pending", "Scheduled", "AlreadyQueued", or "AlreadyRunning")
        - CreatedAt: Timestamp when the job was created
        - ScheduledTime: Scheduled start time (when -ScheduledTime is used)

    When Status is "AlreadyQueued" or "AlreadyRunning", additional properties are included:
        - ErrorCode: The API error code ("WAITING_JOB_TO_START" or "RUNNING_JOB")
        - ErrorMessage: The API error description
        - ExistingJobStartTime: When the existing job started or is scheduled to start
.NOTES
    Requires an active connection via Connect-KeepitService.
    Accepts connector objects from Get-KeepitConnector via pipeline.

    ERROR HANDLING: If another backup job is already queued or running on the connector,
    the cmdlet displays a warning and returns a status object with Status = 'AlreadyQueued'
    or 'AlreadyRunning' instead of throwing an error. This allows graceful handling when
    automating backup operations across multiple connectors.
#>
function Start-KeepitBackup {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector,

        [DateTime]$ScheduledTime
    )

    begin {
        Write-Verbose "=== Start-KeepitBackup: Initialization ==="
        Write-Verbose "Initializing backup job operation"

        # Get authentication header and base URL once for all pipeline items
        try {
            $authHeader = Get-AuthHeader
            $baseUrl = Get-KeepitBaseUrl
            Write-Verbose "Base URL: $baseUrl"

            $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl
            Write-Verbose "User ID: $userId"
            Write-Verbose "Initialization completed successfully"
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
            Write-Verbose "=== Start-KeepitBackup: Processing Connector ==="
            Write-Verbose "Connector: $($resolved.Name) ($connectorGuid)"

            # Validate ScheduledTime if provided
            if ($PSBoundParameters.ContainsKey('ScheduledTime')) {
                if ($ScheduledTime.ToUniversalTime() -lt (Get-Date).ToUniversalTime()) {
                    Write-Error "ScheduledTime must be in the future."
                    return
                }
            }

            # Build XML request body
            if ($PSBoundParameters.ContainsKey('ScheduledTime')) {
                $timeStr = $ScheduledTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
                Write-Verbose "Scheduling backup for $timeStr"
                $xmlBody = "<job><start>$timeStr</start><description>User-requested backup</description><type>backup</type><commands><backup /></commands></job>"
            }
            else {
                $xmlBody = '<job><description>User-requested backup</description><type>backup</type><immediate /><commands><backup /></commands></job>'
            }

            Write-Verbose "=== API Request Details ==="
            Write-Verbose "Method: POST"
            Write-Verbose "URI: $baseUrl/users/$userId/devices/$connectorGuid/jobs/"
            Write-Verbose "Content-Type: application/xml"
            Write-Verbose "Request Body:`n$xmlBody"

            # Build request
            $uri = "$baseUrl/users/$userId/devices/$connectorGuid/jobs/"
            $headers = @{
                'Authorization' = $authHeader
                'Content-Type' = 'application/xml'
                'Accept' = 'application/vnd.keepit.v4+xml'
            }

            Write-Verbose "=== Sending API Request ==="

            if ($PSCmdlet.ShouldProcess("connector $($resolved.Name) ($connectorGuid)", 'Start backup')) {
                # Make API call with error handling
                try {
                    $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $xmlBody -ErrorAction Stop
                }
                catch {
                    # Handle HTTP error responses
                    $errorMessage = $_.Exception.Message
                    $statusCode = $null
                    $apiError = $null
                    $errorBody = $null

                    # Try to extract the error response body
                    if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
                        $statusCode = $_.Exception.Response.StatusCode.value__
                        Write-Verbose "HTTP Status Code: $statusCode"
                    }
                    elseif ($_.Exception.Response) {
                        $statusCode = $_.Exception.Response.StatusCode.value__
                        Write-Verbose "HTTP Status Code: $statusCode"
                    }

                    # Try to get error response body from ErrorDetails
                    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                        $errorBody = $_.ErrorDetails.Message
                        Write-Verbose "Error response body from ErrorDetails:`n$errorBody"
                    }
                    elseif ($errorMessage -match '(?s)<error>.*?</error>') {
                        # Fall back to extracting from error message with single-line mode
                        $errorBody = $matches[0]
                        Write-Verbose "Error response body from exception message:`n$errorBody"
                    }

                    # Try to parse error response as XML
                    if ($errorBody) {
                        Write-Verbose "Attempting to parse error response as XML"
                        try {
                            $errorXml = [xml]$errorBody
                            $apiError = [PSCustomObject]@{
                                Code = $errorXml.error.code
                                Description = $errorXml.error.description
                                StartTime = $errorXml.error.'start-time'
                            }
                            Write-Verbose "Parsed API Error - Code: $($apiError.Code), Description: $($apiError.Description)"
                        }
                        catch {
                            Write-Verbose "Could not parse error XML: $($_.Exception.Message)"
                        }
                    }

                    # Handle specific error cases gracefully
                    if ($apiError -and ($apiError.Code -eq 'WAITING_JOB_TO_START' -or $apiError.Code -eq 'RUNNING_JOB')) {
                        $status = if ($apiError.Code -eq 'WAITING_JOB_TO_START') { 'AlreadyQueued' } else { 'AlreadyRunning' }
                        $reason = if ($apiError.Code -eq 'WAITING_JOB_TO_START') { 'another backup job is already queued' } else { 'a backup job is already running' }
                        Write-Verbose "Handling $($apiError.Code) gracefully"
                        Write-Warning "Cannot start backup for connector $connectorGuid - $reason (start time: $($apiError.StartTime))"

                        $statusObject = New-AlreadyQueuedResult `
                            -ConnectorGuid $connectorGuid -ConnectorName $resolved.Name `
                            -Status $status -ErrorCode $apiError.Code `
                            -ErrorDescription $apiError.Description -StartTime $apiError.StartTime

                        Write-Verbose "=== Job Creation Skipped ==="
                        Write-Verbose "Reason: $reason"
                        Write-Verbose "Existing job start time: $($apiError.StartTime)"
                        Write-Verbose "=== End Start-KeepitBackup ==="

                        return $statusObject
                    }
                    elseif ($apiError) {
                        # Build user-friendly error message for other API errors
                        $friendlyMessage = "API Error [$($apiError.Code)]: $($apiError.Description)"
                        if ($apiError.StartTime) {
                            $friendlyMessage += " (Start time: $($apiError.StartTime))"
                        }
                        throw $friendlyMessage
                    }
                    else {
                        # Re-throw original error if we couldn't parse it
                        throw
                    }
                }

                # Debug: Show raw response
                Write-Verbose "=== API Response Received ==="

                # Handle empty response (some connector types return 201 Created with no body)
                if ($null -eq $response -or ($response -is [string] -and [string]::IsNullOrWhiteSpace($response))) {
                    Write-Verbose "API returned empty response - treating as successful job submission"

                    $jobObject = [PSCustomObject]@{
                        ConnectorGuid = $connectorGuid
                        Type = 'backup'
                        Description = 'User-requested backup'
                        Status = 'Submitted'
                        CreatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
                    }

                    Write-Verbose "=== Backup Job Submitted ==="
                    Write-Verbose "Connector: $connectorGuid"
                    Write-Verbose "Note: API did not return job details"
                    Write-Verbose "=== End Start-KeepitBackup ==="

                    return $jobObject
                }

                Write-Verbose "Response Type: $($response.GetType().FullName)"

                if ($response -is [System.Xml.XmlDocument]) {
                    Write-Verbose "Response is XML Document"
                    Write-Verbose "Response XML Content:"
                    Write-Verbose $response.OuterXml
                }
                elseif ($response -is [System.Xml.XmlElement]) {
                    Write-Verbose "Response is XML Element"
                    Write-Verbose "Root Element Name: $($response.LocalName)"
                    Write-Verbose "Response XML Content:"
                    Write-Verbose $response.OuterXml
                }
                else {
                    Write-Verbose "Response is Object (not XML)"
                    try {
                        Write-Verbose "Response Object (JSON):"
                        Write-Verbose ($response | ConvertTo-Json -Depth 5)
                    }
                    catch {
                        Write-Verbose "Could not convert response to JSON: $($_.Exception.Message)"
                        Write-Verbose "Response String: $($response | Out-String)"
                    }
                }

                # Check if response is an error (in case Invoke-RestMethod didn't throw)
                if ($response.error) {
                    Write-Verbose "Response contains error element - handling as API error"
                    $apiError = [PSCustomObject]@{
                        Code = $response.error.code
                        Description = $response.error.description
                        StartTime = $response.error.'start-time'
                    }
                    Write-Verbose "API Error - Code: $($apiError.Code), Description: $($apiError.Description)"

                    # Handle specific error cases gracefully
                    if ($apiError.Code -eq 'WAITING_JOB_TO_START' -or $apiError.Code -eq 'RUNNING_JOB') {
                        $status = if ($apiError.Code -eq 'WAITING_JOB_TO_START') { 'AlreadyQueued' } else { 'AlreadyRunning' }
                        $reason = if ($apiError.Code -eq 'WAITING_JOB_TO_START') { 'another backup job is already queued' } else { 'a backup job is already running' }
                        Write-Verbose "Handling $($apiError.Code) gracefully"
                        Write-Warning "Cannot start backup for connector $connectorGuid - $reason (start time: $($apiError.StartTime))"

                        $statusObject = New-AlreadyQueuedResult `
                            -ConnectorGuid $connectorGuid -ConnectorName $resolved.Name `
                            -Status $status -ErrorCode $apiError.Code `
                            -ErrorDescription $apiError.Description -StartTime $apiError.StartTime

                        Write-Verbose "=== Job Creation Skipped ==="
                        Write-Verbose "Reason: $reason"
                        Write-Verbose "Existing job start time: $($apiError.StartTime)"
                        Write-Verbose "=== End Start-KeepitBackup ==="

                        return $statusObject
                    }
                    else {
                        # Build user-friendly error message for other API errors
                        $friendlyMessage = "API Error [$($apiError.Code)]: $($apiError.Description)"
                        if ($apiError.StartTime) {
                            $friendlyMessage += " (Start time: $($apiError.StartTime))"
                        }
                        throw $friendlyMessage
                    }
                }

                # Parse response
                Write-Verbose "Attempting to parse response structure..."
                $job = if ($response.job) {
                    Write-Verbose "Found response.job element"
                    $response.job
                }
                elseif ($response.jobs.job) {
                    Write-Verbose "Found response.jobs.job element"
                    if ($response.jobs.job -is [System.Array]) {
                        Write-Verbose "response.jobs.job is an array, taking first element"
                        $response.jobs.job[0]
                    }
                    else {
                        Write-Verbose "response.jobs.job is a single object"
                        $response.jobs.job
                    }
                }
                else {
                    Write-Verbose "ERROR: Could not find job in response. Available properties:"
                    $response | Get-Member -MemberType Properties | ForEach-Object {
                        Write-Verbose "  - $($_.Name): $($response.($_.Name))"
                    }
                    throw "Unexpected response structure from API. Expected 'job' or 'jobs.job' element. See verbose output for details."
                }

                Write-Verbose "Successfully parsed job. JobGuid: $($job.guid)"

                # Create and output job object
                $statusValue = if ($PSBoundParameters.ContainsKey('ScheduledTime')) {
                    'Scheduled'
                } elseif ($job.active -eq $true -or $job.active -eq 'true') {
                    'Active'
                } else {
                    'Pending'
                }
                $scheduledTimeValue = if ($PSBoundParameters.ContainsKey('ScheduledTime')) { $timeStr } else { $null }

                $jobObject = [PSCustomObject]@{
                    ConnectorGuid = $connectorGuid
                    Type = if ($job.type) { $job.type } else { 'backup' }
                    Description = if ($job.description) { $job.description } else { 'User-requested backup' }
                    Status = $statusValue
                    CreatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
                    ScheduledTime = $scheduledTimeValue
                }

                Write-Verbose "=== Job Created Successfully ==="
                Write-Verbose "Type: $($jobObject.Type)"
                Write-Verbose "Status: $($jobObject.Status)"
                if ($scheduledTimeValue) { Write-Verbose "ScheduledTime: $scheduledTimeValue" }
                Write-Verbose "CreatedAt: $($jobObject.CreatedAt)"
                Write-Verbose "=== End Start-KeepitBackup ==="

                $jobObject
            }
        }
        catch {
            $errorIdentifier = if ($connectorGuid) { $connectorGuid } else { $Connector }
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Failed to start backup job for connector $errorIdentifier : $($_.Exception.Message)", $_.Exception),
                    'KeepitJobError',
                    [System.Management.Automation.ErrorCategory]::ConnectionError,
                    $errorIdentifier
                )
            )
        }
    }

    end {
        Write-Verbose "Start-KeepitBackup completed"
    }
}

