<#
.SYNOPSIS
    Lists all shared secure links for the authenticated user
.DESCRIPTION
    Retrieves all share links created by the authenticated Keepit user. Each share represents
    a secure link to a file or folder hierarchy from a backup snapshot. Returns share metadata
    including expiration, password protection status, and associated connector.
.EXAMPLE
    Get-KeepitShare

    Lists all active shares for the connected user
.EXAMPLE
    Get-KeepitShare | Where-Object { $_.HasPassword -eq $false }

    Lists all shares that are not password-protected
.OUTPUTS
    PSCustomObject[] - Array of share objects with properties:
        - ShareId: The share GUID
        - Path: The shared path
        - Created: Creation timestamp
        - Expires: Expiration timestamp
        - ConnectorGuid: The connector GUID
        - Snapshot: The snapshot ID (if pinned to a specific snapshot)
        - HasPassword: Whether the share is password-protected
        - DisplayName: Human-readable alias
        - Size: Size of shared data
.NOTES
    Requires an active connection via Connect-KeepitService.
#>
function Get-KeepitShare {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    try {
        Write-Verbose "=== Get-KeepitShare ==="

        # Get authentication header and base URL
        $authHeader = Get-AuthHeader
        $baseUrl = Get-KeepitBaseUrl
        Write-Verbose "Base URL: $baseUrl"

        # Build request
        $uri = "$baseUrl/share/"
        $headers = @{
            'Authorization' = $authHeader
            'Content-Type'  = 'application/xml'
        }

        Write-Verbose "=== API Request Details ==="
        Write-Verbose "Method: GET"
        Write-Verbose "URI: $uri"

        # Make API call
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop

        Write-Verbose "=== API Response Received ==="
        Write-Verbose "Response Type: $($response.GetType().FullName)"

        # Parse response
        $shares = @()
        if ($response.shares.share) {
            # Normalize to array
            if ($response.shares.share -is [System.Array]) {
                $shares = $response.shares.share
                Write-Verbose "Found $($shares.Count) shares"
            }
            else {
                $shares = @($response.shares.share)
                Write-Verbose "Found 1 share"
            }
        }
        else {
            Write-Verbose "No shares found"
            return
        }

        # Process and output each share
        foreach ($share in $shares) {
            [PSCustomObject]@{
                ShareId       = if ($share.guid) { $share.guid } else { $null }
                Path          = if ($share.path) { $share.path } else { $null }
                Created       = if ($share.created) { $share.created } else { $null }
                Expires       = if ($share.expires) { $share.expires } else { $null }
                ConnectorGuid = if ($share.device) { $share.device } else { $null }
                Snapshot      = if ($share.snapshot -and $share.snapshot -ne '') { $share.snapshot } else { $null }
                HasPassword   = if ($share.password -and $share.password -ne '') { $true } else { $false }
                DisplayName   = if ($share.dname) { $share.dname } else { $null }
                Size          = if ($share.size) { [long]$share.size } else { $null }
            }
        }

        Write-Verbose "=== End Get-KeepitShare ==="
    }
    catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new("Failed to retrieve shares: $($_.Exception.Message)", $_.Exception),
                'KeepitApiError',
                [System.Management.Automation.ErrorCategory]::ConnectionError,
                $null
            )
        )
    }
}

<#
.SYNOPSIS
    Creates a new shared secure link for a backup path
.DESCRIPTION
    Generates a share link for a file or folder hierarchy from a Keepit backup.
    The share can optionally be password-protected and set to expire after a given period.
    If no snapshot is specified, the latest snapshot is used.
.PARAMETER Connector
    Name or GUID of the Keepit connector. Accepts pipeline input by property name.
.PARAMETER Path
    The path to share. Must start with /. Directory paths must end with /.
    File paths must end with the filename.
.PARAMETER Lifetime
    ISO 8601 duration for how long the share should remain active (e.g., P30D for 30 days,
    PT1H for 1 hour). If not specified, the share does not expire.
.PARAMETER Snapshot
    Specific snapshot ID to pin the share to. If not specified, the latest snapshot is used.
.PARAMETER Password
    SecureString password to protect the share. Recipients will need to provide this password
    to access the shared content.
.EXAMPLE
     New-KeepitShare -Connector "ExO Only" -Path "/Users/pro@keepit.com/Outlook/" -Lifetime "P30D"

    Creates an unprotected share of the user's folder hierarchy using the latest snapshot, expiring in 30 days.
.EXAMPLE
    $pw = Read-Host -AsSecureString "Share password"
    New-KeepitShare -Connector "abc123-def456-ghi789" -Path "/Users/pro@keepit.com/OneDrive/data/report.pdf" -Password $pw

    Creates a password-protected share for a single file
.OUTPUTS
    PSCustomObject with properties:
        - ShareId: The GUID of the newly created share
        - ShareUrl: The full URL to access the share
        - ConnectorGuid: The connector GUID
        - Path: The shared path
        - Lifetime: The share lifetime (if specified)
.NOTES
    Requires an active connection via Connect-KeepitService.
    Path rules: must start with /, directories end with /, files end with filename.
#>
function New-KeepitShare {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^P(?=\d|T\d)(\d+Y)?(\d+M)?(\d+W)?(\d+D)?(T(\d+H)?(\d+M)?(\d+S)?)?$')]
        [string]$Lifetime,

        [Parameter(Mandatory = $false)]
        [string]$Snapshot,

        [Parameter(Mandatory = $false)]
        [SecureString]$Password
    )

    begin {
        Write-Verbose "=== New-KeepitShare: Initialization ==="

        # Get authentication header and base URL once for all pipeline items
        try {
            $authHeader = Get-AuthHeader
            $baseUrl = Get-KeepitBaseUrl
            Write-Verbose "Base URL: $baseUrl"
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
            Write-Verbose "=== New-KeepitShare: Processing Connector ==="
            Write-Verbose "Connector: $($resolved.Name) ($connectorGuid)"

            # Ensure trailing slash (directory share)
            if (-not $Path.EndsWith('/')) {
                $Path = $Path + '/'
            }

            # XML-escape the path
            $escapedPath = [System.Security.SecurityElement]::Escape($Path)

            # Build XML request body
            $xmlBody = "<share><device>$connectorGuid</device><path>$escapedPath</path>"

            if ($PSBoundParameters.ContainsKey('Lifetime')) {
                $xmlBody += "<lifetime>$Lifetime</lifetime>"
            }

            if ($PSBoundParameters.ContainsKey('Snapshot')) {
                $escapedSnapshot = [System.Security.SecurityElement]::Escape($Snapshot)
                $xmlBody += "<snapshot>$escapedSnapshot</snapshot>"
            }

            if ($PSBoundParameters.ContainsKey('Password')) {
                # Convert SecureString to plain text
                $tempCred = New-Object System.Management.Automation.PSCredential('unused', $Password)
                $plainPassword = $tempCred.GetNetworkCredential().Password
                $escapedPassword = [System.Security.SecurityElement]::Escape($plainPassword)
                $xmlBody += "<password>$escapedPassword</password>"
            }

            $xmlBody += "</share>"
            $plainPassword = $null

            Write-Verbose "=== API Request Details ==="
            Write-Verbose "Method: POST"
            Write-Verbose "URI: $baseUrl/share/"
            Write-Verbose "Content-Type: application/xml"
            Write-Verbose "Request Body:`n$($xmlBody -replace '<password>[^<]*</password>', '<password>***</password>')"

            # Build request
            $uri = "$baseUrl/share/"
            $headers = @{
                'Authorization' = $authHeader
                'Content-Type'  = 'application/xml'
            }

            Write-Verbose "=== Sending API Request ==="

            if ($PSCmdlet.ShouldProcess("$Path on connector $connectorGuid", 'Create share')) {
                # Use Invoke-WebRequest to capture Location header
                $webResponse = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $xmlBody -SkipHttpErrorCheck -ErrorAction Stop

                Write-Verbose "=== API Response Received ==="
                Write-Verbose "Status Code: $($webResponse.StatusCode)"

                # Check for HTTP errors
                if ($webResponse.StatusCode -ge 400) {
                    $errorBody = $webResponse.Content
                    Write-Verbose "Error response body: $errorBody"

                    $apiError = $null
                    if ($errorBody) {
                        try {
                            $errorXml = [xml]$errorBody
                            $apiError = [PSCustomObject]@{
                                Code        = $errorXml.error.code
                                Description = $errorXml.error.description
                            }
                            Write-Verbose "Parsed API Error - Code: $($apiError.Code), Description: $($apiError.Description)"
                        }
                        catch {
                            Write-Verbose "Could not parse error response as XML: $($_.Exception.Message)"
                        }
                    }

                    if ($apiError -and $apiError.Code) {
                        throw "Failed to create share: [$($apiError.Code)] $($apiError.Description)"
                    }
                    else {
                        throw "Failed to create share: HTTP $($webResponse.StatusCode) - $errorBody"
                    }
                }

                # Extract share GUID from Location header
                $shareId = $null
                $shareUrl = $null
                $locationHeader = $null
                if ($webResponse.Headers -and $webResponse.Headers.ContainsKey('Location')) {
                    $locationValue = $webResponse.Headers['Location']
                    $locationHeader = if ($locationValue -is [System.Array]) { $locationValue[0] } else { $locationValue }
                }

                if ($locationHeader) {
                    Write-Verbose "Location header: $locationHeader"

                    # Build full URL: if the Location header is a relative path, prepend the base URL
                    if ($locationHeader -match '^https?://') {
                        $shareUrl = $locationHeader
                    }
                    else {
                        $shareUrl = $baseUrl + $locationHeader
                    }

                    # Extract GUID from Location URL (e.g., /share/{guid}/ or https://host/share/{guid}/)
                    if ($locationHeader -match '/share/([0-9a-fA-F-]+)') {
                        $shareId = $Matches[1]
                        Write-Verbose "Extracted share GUID from Location header: $shareId"
                    }
                }

                # Build and return result object
                [PSCustomObject]@{
                    ShareId       = $shareId
                    ShareUrl      = $shareUrl
                    ConnectorGuid = $connectorGuid
                    Path          = $Path
                    Lifetime      = if ($PSBoundParameters.ContainsKey('Lifetime')) { $Lifetime } else { $null }
                }

                Write-Verbose "=== Share Created Successfully ==="
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            if ($errorMessage -like "Failed to create share:*") {
                throw
            }
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Failed to create share: $errorMessage", $_.Exception),
                    'KeepitApiError',
                    [System.Management.Automation.ErrorCategory]::ConnectionError,
                    $connectorGuid
                )
            )
        }
    }
}

<#
.SYNOPSIS
    Updates properties of an existing shared secure link
.DESCRIPTION
    Modifies the lifetime, password, or snapshot of an existing share. Only specified
    properties are updated; unspecified properties remain unchanged. Use -ClearPassword
    to remove password protection, and -ClearSnapshot to unpin from a specific snapshot.
.PARAMETER ShareId
    The GUID of the share to update. Accepts pipeline input by property name.
.PARAMETER Lifetime
    New ISO 8601 duration for the share (e.g., P7D for 7 days). Empty string means never expire.
.PARAMETER Password
    New SecureString password for the share.
.PARAMETER ClearPassword
    Switch to remove password protection from the share.
.PARAMETER Snapshot
    New snapshot ID to pin the share to.
.PARAMETER ClearSnapshot
    Switch to unpin the share from a specific snapshot (reverts to latest).
.EXAMPLE
    Set-KeepitShare -ShareId "abc123-def456" -Lifetime "P7D"

    Updates the share to expire in 7 days
.EXAMPLE
    Get-KeepitShare | Set-KeepitShare -Lifetime "P7D"

    Updates all shares to expire in 7 days via pipeline
.EXAMPLE
    Set-KeepitShare -ShareId "abc123-def456" -ClearPassword

    Removes password protection from the share
.EXAMPLE
    Set-KeepitShare -ShareId "abc123-def456" -Lifetime "P7D" -WhatIf

    Shows what would happen without making changes
.OUTPUTS
    PSCustomObject with properties:
        - ShareId: The share GUID
        - Status: "Success" or error message
.NOTES
    Requires an active connection via Connect-KeepitService.
    Supports -WhatIf and -Confirm.
    If -Password and -ClearPassword are both specified, -Password takes precedence.
    If -Snapshot and -ClearSnapshot are both specified, -Snapshot takes precedence.
#>
function Set-KeepitShare {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[a-zA-Z0-9\-]+$')]
        [string]$ShareId,

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^P(?=\d|T\d)(\d+Y)?(\d+M)?(\d+W)?(\d+D)?(T(\d+H)?(\d+M)?(\d+S)?)?$')]
        [string]$Lifetime,

        [Parameter(Mandatory = $false)]
        [SecureString]$Password,

        [Parameter(Mandatory = $false)]
        [switch]$ClearPassword,

        [Parameter(Mandatory = $false)]
        [string]$Snapshot,

        [Parameter(Mandatory = $false)]
        [switch]$ClearSnapshot
    )

    begin {
        Write-Verbose "=== Set-KeepitShare: Initialization ==="

        # Get authentication header and base URL once for all pipeline items
        try {
            $authHeader = Get-AuthHeader
            $baseUrl = Get-KeepitBaseUrl
            Write-Verbose "Base URL: $baseUrl"
            Write-Verbose "Initialization completed successfully"
        }
        catch {
            throw
        }
    }

    process {
        try {
            Write-Verbose "=== Set-KeepitShare: Processing Share $ShareId ==="

            # Check if any changes were specified
            $hasChanges = $PSBoundParameters.ContainsKey('Lifetime') -or
                          $PSBoundParameters.ContainsKey('Password') -or
                          $ClearPassword.IsPresent -or
                          $PSBoundParameters.ContainsKey('Snapshot') -or
                          $ClearSnapshot.IsPresent

            if (-not $hasChanges) {
                Write-Warning "No changes specified for share $ShareId. Use -Lifetime, -Password, -ClearPassword, -Snapshot, or -ClearSnapshot."
                return
            }

            # Build XML body with only specified elements
            $xmlBody = "<share>"

            if ($PSBoundParameters.ContainsKey('Lifetime')) {
                $xmlBody += "<lifetime>$Lifetime</lifetime>"
            }

            if ($PSBoundParameters.ContainsKey('Password')) {
                # -Password takes precedence over -ClearPassword
                $tempCred = New-Object System.Management.Automation.PSCredential('unused', $Password)
                $plainPassword = $tempCred.GetNetworkCredential().Password
                $escapedPassword = [System.Security.SecurityElement]::Escape($plainPassword)
                $xmlBody += "<password>$escapedPassword</password>"
            }
            elseif ($ClearPassword.IsPresent) {
                $xmlBody += "<password></password>"
            }

            if ($PSBoundParameters.ContainsKey('Snapshot')) {
                # -Snapshot takes precedence over -ClearSnapshot
                $escapedSnapshot = [System.Security.SecurityElement]::Escape($Snapshot)
                $xmlBody += "<snapshot>$escapedSnapshot</snapshot>"
            }
            elseif ($ClearSnapshot.IsPresent) {
                $xmlBody += "<snapshot></snapshot>"
            }

            $xmlBody += "</share>"

            Write-Verbose "=== API Request Details ==="
            Write-Verbose "Method: PUT"
            Write-Verbose "URI: $baseUrl/share/$ShareId"
            Write-Verbose "Content-Type: application/xml"
            Write-Verbose "Request Body:`n$($xmlBody -replace '<password>[^<]*</password>', '<password>***</password>')"

            if ($PSCmdlet.ShouldProcess("Share $ShareId", "Update share")) {
                # Build request
                $uri = "$baseUrl/share/$ShareId"
                $headers = @{
                    'Authorization' = $authHeader
                    'Content-Type'  = 'application/xml'
                }

                Write-Verbose "=== Sending API Request ==="

                $null = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $xmlBody -ErrorAction Stop

                Write-Verbose "=== Share Updated Successfully ==="

                [PSCustomObject]@{
                    ShareId = $ShareId
                    Status  = 'Success'
                }
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            if ($errorMessage -like "Failed to update share:*") {
                throw
            }
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Failed to update share: $errorMessage", $_.Exception),
                    'KeepitApiError',
                    [System.Management.Automation.ErrorCategory]::WriteError,
                    $ShareId
                )
            )
        }
    }
}

<#
.SYNOPSIS
    Deletes a shared secure link
.DESCRIPTION
    Permanently removes a share link. The share URL will no longer be accessible.
    Only shares owned by the authenticated user can be deleted.
.PARAMETER ShareId
    The GUID of the share to delete. Accepts pipeline input by property name.
.EXAMPLE
    Remove-KeepitShare -ShareId "abc123-def456"

    Deletes the specified share
.EXAMPLE
    Get-KeepitShare | Remove-KeepitShare

    Deletes all shares for the connected user
.EXAMPLE
    Get-KeepitShare | Where-Object ConnectorGuid -eq $guid | Remove-KeepitShare

    Deletes all shares for a specific connector
.EXAMPLE
    Get-KeepitShare | Remove-KeepitShare -WhatIf

    Shows which shares would be deleted without actually deleting them
.OUTPUTS
    PSCustomObject with properties:
        - ShareId: The share GUID
        - Status: "Success" or error message
.NOTES
    Requires an active connection via Connect-KeepitService.
    Supports -WhatIf and -Confirm.
#>
function Remove-KeepitShare {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[a-zA-Z0-9\-]+$')]
        [string]$ShareId
    )

    begin {
        Write-Verbose "=== Remove-KeepitShare: Initialization ==="

        # Get authentication header and base URL once for all pipeline items
        try {
            $authHeader = Get-AuthHeader
            $baseUrl = Get-KeepitBaseUrl
            Write-Verbose "Base URL: $baseUrl"
            Write-Verbose "Initialization completed successfully"
        }
        catch {
            throw
        }
    }

    process {
        try {
            Write-Verbose "=== Remove-KeepitShare: Processing Share $ShareId ==="

            if ($PSCmdlet.ShouldProcess("Share $ShareId", "Delete share")) {
                # Build request
                $uri = "$baseUrl/share/$ShareId"
                $headers = @{
                    'Authorization' = $authHeader
                    'Content-Type'  = 'application/xml'
                }

                Write-Verbose "=== API Request Details ==="
                Write-Verbose "Method: DELETE"
                Write-Verbose "URI: $uri"

                Write-Verbose "=== Sending API Request ==="

                $null = Invoke-RestMethod -Uri $uri -Method Delete -Headers $headers -ErrorAction Stop

                Write-Verbose "=== Share Deleted Successfully ==="

                [PSCustomObject]@{
                    ShareId = $ShareId
                    Status  = 'Success'
                }
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            if ($errorMessage -like "Failed to delete share:*") {
                throw
            }
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Failed to delete share: $errorMessage", $_.Exception),
                    'KeepitApiError',
                    [System.Management.Automation.ErrorCategory]::WriteError,
                    $ShareId
                )
            )
        }
    }
}
