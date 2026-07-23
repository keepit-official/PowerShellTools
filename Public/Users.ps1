<#
.SYNOPSIS
    Creates a new Keepit user account
.DESCRIPTION
    Creates a new user account in Keepit with the specified role and connector access.
    Validates that the user does not already exist and that the role is valid for the
    account. Generates a random password, creates the user token, optionally sends an
    activation email and enables notifications, and grants access to specified connectors.
.PARAMETER Name
    Display name for the new user
.PARAMETER Email
    UPN/email address for the new user
.PARAMETER Role
    Role name to assign. Validated at runtime against the account's available roles.
.PARAMETER Connectors
    Either the string "all" to grant access to all connectors, or an array of connector
    names or GUIDs identifying the connectors the user should have access to.
.PARAMETER SendActivationEmail
    When specified, sends an activation email to the user after creation
.PARAMETER NotificationsEnabled
    When specified, enables email notifications for the user
.EXAMPLE
    New-KeepitUser -Name "John Doe" -Email "john.doe@contoso.com" -Role "BackupAdmin" -Connectors "all"

    Creates a new BackupAdmin user with access to all connectors
.EXAMPLE
    New-KeepitUser -Name "Jane Smith" -Email "jane@contoso.com" -Role "LimitedSupport" -Connectors "Production M365" -SendActivationEmail

    Creates a new LimitedSupport user with access to one connector and sends activation email
.OUTPUTS
    PSCustomObject with properties:
        - Email: The user's email address
        - Name: The user's display name
        - Role: The assigned role
        - ConnectorsGranted: Number of connectors granted access
        - ActivationEmailSent: Boolean
        - NotificationsEnabled: Boolean
.NOTES
    Requires an active connection via Connect-KeepitService.
#>
function New-KeepitUser {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[^@]+@[^@]+\.[^@]+$', ErrorMessage = "Email must be a valid email address")]
        [string]$Email,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Role,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Connectors,

        [Parameter(Mandatory = $false)]
        [switch]$SendActivationEmail,

        [Parameter(Mandatory = $false)]
        [switch]$NotificationsEnabled
    )

    try {
        Write-Verbose "=== New-KeepitUser: Creating user account ==="
        Write-Verbose "Name: $Name"
        Write-Verbose "Email: $Email"
        Write-Verbose "Role: $Role"

        # Get auth and connection info
        $authHeader = Get-AuthHeader
        $baseUrl = Get-KeepitBaseUrl
        $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl

        Write-Verbose "Base URL: $baseUrl"
        Write-Verbose "User ID: $userId"

        $headers = @{
            'Authorization' = $authHeader
            'Content-Type'  = 'application/xml'
        }

        # Step 1: Check if user already exists via HEAD
        # API returns 202 Accepted if the user does not exist, 409 Conflict if they do
        $checkUri = "$baseUrl/users/$userId/tokens?aname=$([System.Uri]::EscapeDataString($Email))"
        Write-Verbose "Checking user existence: HEAD $checkUri"
        $headResponse = Invoke-WebRequest -Uri $checkUri -Method Head -Headers $headers -SkipHttpErrorCheck
        if ($headResponse.StatusCode -eq 409) {
            throw "User '$Email' already exists."
        }
        elseif ($headResponse.StatusCode -ne 202) {
            throw "Failed to check user existence: HTTP $($headResponse.StatusCode)"
        }
        Write-Verbose "User does not exist (202 Accepted); proceeding with creation"

        # Step 2: Validate role against account roles
        $rolesUri = "$baseUrl/users/$userId/permissions/roles/"
        Write-Verbose "Fetching available roles: GET $rolesUri"
        $rolesResponse = Invoke-RestMethod -Uri $rolesUri -Method Get -Headers $headers -ErrorAction Stop

        $availableRoles = @()
        if ($rolesResponse.roles.role) {
            $roleNodes = if ($rolesResponse.roles.role -is [System.Array]) {
                $rolesResponse.roles.role
            } else {
                @($rolesResponse.roles.role)
            }
            $availableRoles = $roleNodes | ForEach-Object { $_.name }
        }

        Write-Verbose "Available roles: $($availableRoles -join ', ')"

        $canonicalRole = $availableRoles | Where-Object { $_ -ieq $Role } | Select-Object -First 1
        if (-not $canonicalRole) {
            throw "Invalid role '$Role'. Available roles: $($availableRoles -join ', ')"
        }
        $Role = $canonicalRole

        # Step 3: Generate 16-character random password using cryptographic RNG
        $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^*'
        $maxUnbiased = 256 - (256 % $chars.Length)
        $passwordChars = @()
        while ($passwordChars.Count -lt 16) {
            $byte = [byte[]]::new(1)
            [System.Security.Cryptography.RandomNumberGenerator]::Fill($byte)
            if ($byte[0] -lt $maxUnbiased) {
                $passwordChars += $chars[$byte[0] % $chars.Length]
            }
        }
        $password = -join $passwordChars
        Write-Verbose "Generated random password (16 chars)"

        # Step 4: Create user token via POST
        if ($PSCmdlet.ShouldProcess($Email, 'Create user')) {
            $escapedRole = [System.Security.SecurityElement]::Escape($Role)
            $escapedName = [System.Security.SecurityElement]::Escape($Name)
            $escapedEmail = [System.Security.SecurityElement]::Escape($Email)
            $escapedPassword = [System.Security.SecurityElement]::Escape($password)

            $tokenXml = "<token><acl>$escapedRole</acl><descr>$escapedName</descr><aname>$escapedEmail</aname><apass>$escapedPassword</apass><primary>true</primary></token>"

            $createUri = "$baseUrl/users/$userId/tokens/"
            Write-Verbose "Creating user token: POST $createUri"
            Write-Verbose "Request body: $($tokenXml -replace '<apass>[^<]*</apass>', '<apass>***</apass>')"

            $createResponse = Invoke-WebRequest -Uri $createUri -Method Post -Headers $headers -Body $tokenXml -SkipHttpErrorCheck
            Write-Verbose "Create token response: HTTP $($createResponse.StatusCode)"
            if ($createResponse.StatusCode -eq 409) {
                throw "User '$Email' already exists."
            }
            elseif ($createResponse.StatusCode -ge 400) {
                Write-Verbose "Response body: $($createResponse.Content)"
                throw "Failed to create user token: HTTP $($createResponse.StatusCode) $($createResponse.StatusDescription) - $($createResponse.Content)"
            }

            Write-Verbose "User token created successfully"
            $password = $null

            # Step 5: Send activation email if requested
            $activationSent = $false
            if ($SendActivationEmail) {
                try {
                    $activateUri = "$baseUrl/users/$userId/activate"
                    $activateXml = "<activate><token>$escapedEmail</token></activate>"
                    Write-Verbose "Sending activation email: POST $activateUri"
                    Invoke-RestMethod -Uri $activateUri -Method Post -Headers $headers -Body $activateXml -ErrorAction Stop | Out-Null
                    $activationSent = $true
                    Write-Verbose "Activation email sent"
                }
                catch {
                    Write-Warning "Failed to send activation email for '$Email': $($_.Exception.Message)"
                    $activationSent = $false
                }
            }

            # Step 6: Enable notifications if requested
            $notificationsSet = $false
            if ($NotificationsEnabled) {
                try {
                    $notifyUri = "$baseUrl/users/$userId/tokens/$([System.Uri]::EscapeDataString($Email))/attributes/enable-notification"
                    Write-Verbose "Enabling notifications: POST $notifyUri"
                    Invoke-RestMethod -Uri $notifyUri -Method Post -Headers $headers -ErrorAction Stop | Out-Null
                    $notificationsSet = $true
                    Write-Verbose "Notifications enabled"
                }
                catch {
                    Write-Warning "Failed to enable notifications for '$Email': $($_.Exception.Message)"
                    $notificationsSet = $false
                }
            }

            # Step 7: Grant connector access
            $connectorGuids = @()
            if ($Connectors.Count -eq 1 -and $Connectors[0] -eq 'all') {
                Write-Verbose "Resolving all connectors"
                $allConnectors = Get-KeepitConnector
                if ($allConnectors) {
                    $connectorGuids = @($allConnectors | ForEach-Object { $_.ConnectorGuid })
                }
            }
            else {
                foreach ($conn in $Connectors) {
                    try {
                        $resolved = Resolve-KeepitConnectorIdentity -Identity $conn
                        $connectorGuids += $resolved.ConnectorGuid
                    }
                    catch {
                        Write-Warning "Failed to resolve connector '$conn': $($_.Exception.Message)"
                    }
                }
            }

            Write-Verbose "Granting access to $($connectorGuids.Count) connector(s)"

            $grantedCount = 0
            $failedConnectors = @()
            $accessXml = "<member><aname>$escapedEmail</aname></member>"

            foreach ($guid in $connectorGuids) {
                $accessUri = "$baseUrl/users/$userId/devices/$guid/access_list"
                Write-Verbose "Granting access: POST $accessUri"
                try {
                    Invoke-RestMethod -Uri $accessUri -Method Post -Headers $headers -Body $accessXml -ErrorAction Stop | Out-Null
                    $grantedCount++
                }
                catch {
                    Write-Warning "Failed to grant access to connector '$guid': $($_.Exception.Message)"
                    $failedConnectors += $guid
                }
            }

            Write-Verbose "Granted access to $grantedCount connector(s)"

            # Return result - always output even if secondary steps failed
            [PSCustomObject]@{
                Email                = $Email
                Name                 = $Name
                Role                 = $Role
                ConnectorsGranted    = $grantedCount
                ConnectorsRequested  = $connectorGuids.Count
                ConnectorsFailed     = $failedConnectors.Count
                ActivationEmailSent  = $activationSent
                NotificationsEnabled = $notificationsSet
            }
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        if ($errorMessage -like "Failed to create user:*" -or
            $errorMessage -like "User '*' already exists*" -or
            $errorMessage -like "Invalid role '*'*") {
            throw
        }
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new("Failed to create user: $errorMessage", $_.Exception),
                'KeepitUserError',
                [System.Management.Automation.ErrorCategory]::ConnectionError,
                $Email
            )
        )
    }
}

<#
.SYNOPSIS
    Removes a Keepit user account
.DESCRIPTION
    Removes a user account from Keepit by deleting their token. Verifies the user
    exists before attempting deletion and supports -WhatIf and -Confirm for safe
    operation.
.PARAMETER Identity
    The UPN/email address of the user to remove
.EXAMPLE
    Remove-KeepitUser -Identity "john.doe@contoso.com"

    Removes the specified user account (prompts for confirmation)
.EXAMPLE
    Remove-KeepitUser -Identity "john.doe@contoso.com" -WhatIf

    Shows what would happen without actually removing the user
.OUTPUTS
    PSCustomObject with properties:
        - Identity: The user's email address
        - Status: "Removed" on success
.NOTES
    Requires an active connection via Connect-KeepitService.
    ConfirmImpact is High, so -Confirm is implicit unless $ConfirmPreference is set to None.
#>
function Remove-KeepitUser {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[^@]+@[^@]+\.[^@]+$', ErrorMessage = "Identity must be a valid email address")]
        [Alias('Email', 'UserPrincipalName')]
        [string]$Identity
    )

    try {
        Write-Verbose "=== Remove-KeepitUser: Removing user account ==="
        Write-Verbose "Identity: $Identity"

        # Get auth and connection info
        $authHeader = Get-AuthHeader
        $baseUrl = Get-KeepitBaseUrl
        $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl

        Write-Verbose "Base URL: $baseUrl"
        Write-Verbose "User ID: $userId"

        $headers = @{
            'Authorization' = $authHeader
            'Content-Type'  = 'application/xml'
        }

        # Verify user exists before prompting for confirmation
        $checkUri = "$baseUrl/users/$userId/tokens?aname=$([System.Uri]::EscapeDataString($Identity))"
        Write-Verbose "Checking user existence: HEAD $checkUri"
        $headResponse = Invoke-WebRequest -Uri $checkUri -Method Head -Headers $headers -SkipHttpErrorCheck
        if ($headResponse.StatusCode -eq 202) {
            throw "User '$Identity' not found."
        }
        elseif ($headResponse.StatusCode -ne 409) {
            throw "Failed to check user existence: HTTP $($headResponse.StatusCode)"
        }
        Write-Verbose "User exists (409 Conflict); proceeding with removal"

        # Delete user token
        if ($PSCmdlet.ShouldProcess($Identity, "Remove Keepit user")) {
            $deleteUri = "$baseUrl/users/$userId/tokens/$([System.Uri]::EscapeDataString($Identity))"
            Write-Verbose "Deleting user token: DELETE $deleteUri"
            $deleteResponse = Invoke-WebRequest -Uri $deleteUri -Method Delete -Headers $headers -SkipHttpErrorCheck
            if ($deleteResponse.StatusCode -eq 404) {
                throw "User '$Identity' not found."
            }
            elseif ($deleteResponse.StatusCode -ge 400) {
                throw "Failed to remove user: HTTP $($deleteResponse.StatusCode) $($deleteResponse.StatusDescription)"
            }

            Write-Verbose "User removed successfully"

            [PSCustomObject]@{
                Identity = $Identity
                Status   = 'Removed'
            }
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        if ($errorMessage -like "Failed to remove user:*" -or
            $errorMessage -like "User '*' not found*") {
            throw
        }
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new("Failed to remove user: $errorMessage", $_.Exception),
                'KeepitUserError',
                [System.Management.Automation.ErrorCategory]::ConnectionError,
                $Identity
            )
        )
    }
}

<#
.SYNOPSIS
    Retrieves Keepit user accounts
.DESCRIPTION
    Returns one PSCustomObject per user token from GET /users/{userId}/tokens.
    When a token is primary, PrimaryAName is set to null.
.EXAMPLE
    Get-KeepitUser

    Lists all user accounts on the Keepit platform
.EXAMPLE
    Get-KeepitUser | Format-Table Aname, Acl, Primary

    Lists users with their email, role, and primary status
.NOTES
    Requires an active connection via Connect-KeepitService.
#>
function Get-KeepitUser {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    try {
        $authHeader = Get-AuthHeader
        $baseUrl = Get-KeepitBaseUrl
        $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl

        $headers = @{
            'Authorization' = $authHeader
            # v4 is incompatible with the /tokens endpoint and returns 400 Bad Request.
            'Accept'        = 'application/vnd.keepit.v2'
        }

        $uri = "$baseUrl/users/$userId/tokens"
        Write-Verbose "GET $uri"

        [xml]$response = (Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -ErrorAction Stop).Content

        if ($response.tokens.token) {
            $tokenNodes = if ($response.tokens.token -is [System.Array]) {
                $response.tokens.token
            } else {
                @($response.tokens.token)
            }
        } else {
            $tokenNodes = @()
        }

        foreach ($token in $tokenNodes) {
            $isPrimary = $token.primary -eq 'true'

            [PSCustomObject]@{
                Descr        = $token.descr
                UserName     = $token.aname
                Guid         = $token.guid
                Created      = $token.created
                LastUsed     = $token.lastuse
                PrimaryToken = $isPrimary
                Acl          = $token.acl
                PrimaryAName = if ($isPrimary) { $null } else { $token.primary_aname }
            }
        }
    }
    catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new("Failed to retrieve users: $($_.Exception.Message)", $_.Exception),
                'KeepitUserError',
                [System.Management.Automation.ErrorCategory]::ConnectionError,
                $null
            )
        )
    }
}

<#
.SYNOPSIS
    Retrieves available Keepit account roles
.DESCRIPTION
    Returns the list of roles defined for the account by calling
    GET /users/{userId}/permissions/roles/. Each role includes its name
    and the list of capabilities it grants.
.EXAMPLE
    Get-KeepitRoles

    Lists all available roles and their capabilities
.EXAMPLE
    Get-KeepitRoles | Where-Object Name -eq 'BackupAdmin' | Select-Object -ExpandProperty Capabilities

    Shows the capabilities granted by the BackupAdmin role
.OUTPUTS
    PSCustomObject with properties:
        - Name: Role display name (e.g., MasterAdmin, BackupAdmin)
        - Capabilities: String array of capability names
.NOTES
    Requires an active connection via Connect-KeepitService.
#>
function Get-KeepitRoles {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Public API name; renaming would be a breaking change')]
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    try {
        $authHeader = Get-AuthHeader
        $baseUrl = Get-KeepitBaseUrl
        $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl

        $headers = @{
            'Authorization' = $authHeader
            'Accept'        = 'application/vnd.keepit.v4+xml'
        }

        $uri = "$baseUrl/users/$userId/permissions/roles/"
        Write-Verbose "GET $uri"

        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop

        if ($response.roles.role) {
            $roleNodes = if ($response.roles.role -is [System.Array]) {
                $response.roles.role
            } else {
                @($response.roles.role)
            }
        } else {
            $roleNodes = @()
        }

        foreach ($role in $roleNodes) {
            [PSCustomObject]@{
                Name         = $role.name
                Capabilities = $role.acl -split ':'
            }
        }
    }
    catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new("Failed to retrieve roles: $($_.Exception.Message)", $_.Exception),
                'KeepitApiError',
                [System.Management.Automation.ErrorCategory]::ConnectionError,
                $null
            )
        )
    }
}
