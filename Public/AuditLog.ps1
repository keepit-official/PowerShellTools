<#
.SYNOPSIS
    Retrieves audit log entries from the Keepit platform
.DESCRIPTION
    Gets audit log records from the Keepit platform with optional filtering by date range.
    Audit logs contain the history of actions made by Keepit users and are never cleared.
    Returns human-readable audit log entries with action details, user information, and metadata.
.PARAMETER StartTime
    Start of the time window for audit log entries. If not specified along with EndTime,
    defaults to the last 14 days.
.PARAMETER EndTime
    End of the time window for audit log entries. If not specified along with StartTime,
    defaults to the last 14 days.
.PARAMETER ResultSize
    Maximum number of audit log entries to return. Default is 100. Maximum is 10000.
.PARAMETER Area
    Filter by audit log area. Valid values: 'User events', 'Backup/Restore', 'Account events', 'Subaccount events'.
.EXAMPLE
    Get-KeepitAuditLog

    Retrieves the last 100 audit log entries from the past 14 days
.EXAMPLE
    Get-KeepitAuditLog -ResultSize 500

    Retrieves up to 500 audit log entries from the past 14 days
.EXAMPLE
    Get-KeepitAuditLog -StartTime (Get-Date).AddDays(-7) -EndTime (Get-Date)

    Retrieves audit log entries from the last 7 days
.EXAMPLE
    Get-KeepitAuditLog -Area 'Backup/Restore' -ResultSize 50

    Retrieves the last 50 backup/restore audit log entries
.OUTPUTS
    PSCustomObject[] - Array of audit log entry objects with properties:
        - Time: Timestamp of the action
        - Account: Account ID
        - Message: Human-readable description of the action
        - Area: Category of the action (e.g., 'User events', 'Backup/Restore')
        - Company: Company name
        - Acl: ACL name for the action
        - Method: HTTP method used
        - Allowed: Whether the action was allowed
        - Succeeded: Whether the action succeeded (based on HTTP return code)
        - ClientIP: IP address of the client
        - Device: Device/connector GUID (if applicable)
        - Token: UPN or name of the API token that performed the action
.NOTES
    Requires an active connection via Connect-KeepitService.
    Maximum 10,000 records returned per request.
#>
function Get-KeepitAuditLog {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [DateTime]$StartTime,

        [Parameter(Mandatory = $false)]
        [DateTime]$EndTime,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 10000)]
        [int]$ResultSize = 100,

        [Parameter(Mandatory = $false)]
        [ValidateSet('User events', 'Backup/Restore', 'Account events', 'Subaccount events')]
        [string]$Area
    )

    try {
        Write-Verbose "=== Get-KeepitAuditLog ==="

        # Validate date parameters
        $hasStartTime = $PSBoundParameters.ContainsKey('StartTime')
        $hasEndTime = $PSBoundParameters.ContainsKey('EndTime')

        if ($hasStartTime -and -not $hasEndTime) {
            throw "StartTime specified without EndTime. Both StartTime and EndTime must be provided together, or neither."
        }

        if ($hasEndTime -and -not $hasStartTime) {
            throw "EndTime specified without StartTime. Both StartTime and EndTime must be provided together, or neither."
        }

        if ($hasStartTime -and $hasEndTime -and $StartTime -ge $EndTime) {
            throw "StartTime must be less than EndTime. StartTime: $StartTime, EndTime: $EndTime"
        }

        # Get authentication header and base URL
        $authHeader = Get-AuthHeader
        $baseUrl = Get-KeepitBaseUrl
        Write-Verbose "Base URL: $baseUrl"

        $userId = $script:KeepitUserId
        if (-not $userId) {
            throw "Unable to determine user ID. Ensure you are connected using Connect-KeepitService."
        }
        Write-Verbose "User ID: $userId"

        # Build request URI with pagination parameters
        # Note: API returns 2 fewer records than requested, so add 2 to compensate
        $apiLimit = [Math]::Min($ResultSize + 2, 10000)
        $uri = "$baseUrl/audit/filter/pretty?limit=$apiLimit&offset=0"
        $headers = @{
            'Authorization' = $authHeader
            'Content-Type'  = 'application/xml'
            'Accept'        = 'application/vnd.keepit.v4+xml'
        }

        # Build filter XML
        $escapedUserId = [System.Security.SecurityElement]::Escape($userId)
        $filterXml = "<filter><account>$escapedUserId</account>"

        if ($hasStartTime -and $hasEndTime) {
            $fromTimestamp = $StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
            $toTimestamp = $EndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
            $filterXml += "<from>$fromTimestamp</from><to>$toTimestamp</to>"
            Write-Verbose "Date range filter: $fromTimestamp to $toTimestamp"
        }
        else {
            Write-Verbose "No date range specified - API will default to last 14 days"
        }

        if ($PSBoundParameters.ContainsKey('Area')) {
            $escapedArea = [System.Security.SecurityElement]::Escape($Area)
            $filterXml += "<area>$escapedArea</area>"
            Write-Verbose "Area filter: $Area"
        }

        $filterXml += "</filter>"

        Write-Verbose "=== API Request Details ==="
        Write-Verbose "Method: PUT"
        Write-Verbose "URI: $uri"
        Write-Verbose "Request Body: $filterXml"

        # Make API call
        $response = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $filterXml -ErrorAction Stop

        Write-Verbose "=== API Response Received ==="
        Write-Verbose "Response Type: $($response.GetType().FullName)"

        # Parse response
        $records = @()
        if ($response.audit.record) {
            # Normalize to array
            if ($response.audit.record -is [System.Array]) {
                $records = $response.audit.record
                Write-Verbose "Found $($records.Count) audit log records"
            }
            else {
                $records = @($response.audit.record)
                Write-Verbose "Found 1 audit log record"
            }
        }
        else {
            Write-Verbose "No audit log records found in response"
            return
        }

        # Process and output each record
        foreach ($record in $records) {
            [PSCustomObject]@{
                Time      = if ($record.time) { $record.time } else { $null }
                Account   = if ($record.account) { $record.account } else { $null }
                Message   = if ($record.message) { $record.message } else { '' }
                Area      = if ($record.area) { $record.area } else { $null }
                Company   = if ($record.company) { $record.company } else { $null }
                Acl       = if ($record.acl) { $record.acl } else { $null }
                Method    = if ($record.method) { $record.method } else { $null }
                Allowed   = if ($record.allowed -eq 'true' -or $record.allowed -eq $true) { $true } else { $false }
                Succeeded = if ($record.succeeded -eq 'true' -or $record.succeeded -eq $true) { $true } else { $false }
                ClientIP  = if ($record.'client-ip') { $record.'client-ip' } else { $null }
                Device    = if ($record.device) { $record.device } else { $null }
                Token     = if ($record.token) { $record.token } else { $null }
            }
        }

        Write-Verbose "=== End Get-KeepitAuditLog ==="
    }
    catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new("Failed to retrieve audit logs: $($_.Exception.Message)", $_.Exception),
                'KeepitApiError',
                [System.Management.Automation.ErrorCategory]::ConnectionError,
                $null
            )
        )
    }
}
