<#
.SYNOPSIS
    Connects to the Keepit service and establishes authentication
.DESCRIPTION
    Creates and caches an authentication header for subsequent API calls to the Keepit platform.
    The connection remains active until Disconnect-KeepitService is called or the session ends.
.PARAMETER Credential
    PSCredential object containing Keepit username and password
.PARAMETER UserName
    Keepit username (email address; case-sensitive). Must be used together with Password parameter.
.PARAMETER Password
    Keepit password as SecureString. Must be used together with Username parameter.
.PARAMETER Environment
    Keepit data center environment. Valid values:
    Production: ws.keepit, au-sy, ca-tr, dk-co, de-fr, uk-ld, us-dc, ch-zh
    Testing: ws-test, ws-test-b, ws-test-c, staging, dev
.EXAMPLE
    $cred = Get-Credential
    Connect-KeepitService -Credential $cred -Environment "us-dc"

    Connects to the US data center using a PSCredential object
.EXAMPLE
    $password = ConvertTo-SecureString "MyPassword" -AsPlainText -Force
    Connect-KeepitService -UserName "user@example.com" -Password $password -Environment "ws-test"

    Connects to a test environment using username and password

.EXAMPLE
    $connection = Connect-KeepitService -Credential $cred -Environment "us-dc" | Format-List

    Connects and returns connection information object
.OUTPUTS
Returns PSCustomObject with properties:
        - Environment: The connected Keepit environment
        - UserId: The authenticated user's GUID
        - Connected: Boolean indicating connection status
        - ConnectedAt: Timestamp of connection
.NOTES
    The authentication header is stored in a module-scoped variable and used by other cmdlets.
    You must provide either -Credential OR both -UserName and -Password parameters.
#>
function Connect-KeepitService {
    [CmdletBinding(DefaultParameterSetName = 'Credential')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Credential')]
        [PSCredential]$Credential,

        [Parameter(Mandatory = $true, ParameterSetName = 'UserPassword')]
        [ValidateNotNullOrEmpty()]
        [string]$UserName,

        [Parameter(Mandatory = $true, ParameterSetName = 'UserPassword')]
        [ValidateNotNull()]
        [SecureString]$Password,

        [Parameter(Mandatory = $true)]
        [ValidateScript({ $_ -in $script:ValidKeepitEnvironments })]
        [string]$Environment
    )

    try {
        Write-Verbose "Connecting to Keepit environment: $Environment"

        # Build credential object if UserName/Password provided
        if ($PSCmdlet.ParameterSetName -eq 'UserPassword') {
            Write-Verbose "Creating credential from UserName and Password"
            $Credential = New-Object System.Management.Automation.PSCredential($UserName, $Password)
        }

        # Create and store authentication header
        $script:KeepitAuth = New-AuthHeader -Credential $Credential
        $script:KeepitRegion = $Environment

        # Test connection by getting user ID
        $baseUrl = Get-KeepitBaseUrl
        $uri = "$baseUrl/users/"

        $headers = @{
            'Authorization' = $script:KeepitAuth
            'Content-Type' = 'application/xml'
        }

        Write-Verbose "Testing connection to $uri"
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop

        # Extract and store user ID from response
        if ($response.user.id) {
            $script:KeepitUserId = $response.user.id
            Write-Verbose "Successfully connected. User ID: $($script:KeepitUserId)"
            Write-Host "Successfully connected to Keepit service ($Environment)" -ForegroundColor Green

            # Return connection info if PassThru is specified

                [PSCustomObject]@{
                    Environment = $Environment
                    UserId = $script:KeepitUserId
                    Connected = $true
                    ConnectedAt = [DateTime]::Now
                }
        }
        else {
            throw "Unable to retrieve user ID from response"
        }
    }
    catch {
        # Clean up on failure
        $script:KeepitAuth = $null
        $script:KeepitRegion = $null
        $script:KeepitUserId = $null

        throw "Failed to connect to Keepit service: $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Disconnects from the Keepit service
.DESCRIPTION
    Clears the cached authentication header and connection information.
    After disconnecting, you must call Connect-KeepitService again before using other cmdlets.
.EXAMPLE
    Disconnect-KeepitService

    Disconnects from the Keepit service
.OUTPUTS
    None
.NOTES
    This cmdlet clears module-scoped variables but does not invalidate the API token
#>
function Disconnect-KeepitService {
    [CmdletBinding()]
    param()

    try {
        if ($script:KeepitAuth) {
            Write-Verbose "Disconnecting from Keepit service"

            $script:KeepitAuth = $null
            $script:KeepitRegion = $null
            $script:KeepitUserId = $null

            Write-Host "Disconnected from Keepit service" -ForegroundColor Green
        }
        else {
            Write-Warning "Not currently connected to Keepit service"
        }
    }
    catch {
        throw "Error during disconnect: $($_.Exception.Message)"
    }
}
