#region Helper Functions

<#
.SYNOPSIS
    Creates a Basic authentication header from credentials
.PARAMETER Credential
    PSCredential object containing username and password
.OUTPUTS
    String - Base64 encoded authentication header value
#>
function New-AuthHeader {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal helper; constructs an in-memory auth string only')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCredential]$Credential
    )

    $username = $Credential.UserName
    $password = $Credential.GetNetworkCredential().Password
    $authString = "${username}:${password}"
    $authBytes = [System.Text.Encoding]::UTF8.GetBytes($authString)
    $authBase64 = [System.Convert]::ToBase64String($authBytes)

    return "Basic $authBase64"
}

<#
.SYNOPSIS
    Gets the authentication header to use for API calls
.PARAMETER Credential
    Optional PSCredential to generate a new auth header
.OUTPUTS
    String - Authentication header value
#>
function Get-AuthHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [PSCredential]$Credential
    )

    if ($Credential) {
        return New-AuthHeader -Credential $Credential
    }

    if (-not $script:KeepitAuth) {
        throw "Not connected to Keepit service. Run Connect-KeepitService first or provide Credential parameter."
    }

    return $script:KeepitAuth
}

<#
.SYNOPSIS
    Constructs the base URL for Keepit API calls
.PARAMETER Environment
    Optional environment override. If not provided, uses cached environment.
.OUTPUTS
    String - Base URL for the configured environment
#>
function Get-KeepitBaseUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Environment
    )

    $env = if ($Environment) { $Environment } else { $script:KeepitRegion }

    if (-not $env) {
        throw "Keepit environment not configured. Run Connect-KeepitService first or provide Environment parameter."
    }

    return "https://$env.keepit.com"
}

<#
.SYNOPSIS
    Gets the user ID, either from cache or by querying the API
.PARAMETER AuthHeader
    The authentication header to use for API calls
.PARAMETER BaseUrl
    The base URL for API calls
.OUTPUTS
    String - User GUID
#>
function Get-KeepitUserId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AuthHeader,

        [Parameter(Mandatory = $true)]
        [string]$BaseUrl
    )

    # If we have a cached user ID and are using cached auth, return it
    if ($script:KeepitUserId -and $AuthHeader -eq $script:KeepitAuth) {
        return $script:KeepitUserId
    }

    # Otherwise, query the API
    Write-Verbose "Getting user ID from API"
    $headers = @{
        'Authorization' = $AuthHeader
        'Content-Type' = 'application/xml'
    }
    $userResponse = Invoke-RestMethod -Uri "$BaseUrl/users/" -Method Get -Headers $headers -ErrorAction Stop

    if (-not $userResponse.user.id) {
        throw "Unable to retrieve user ID from response"
    }

    return $userResponse.user.id
}

<#
.SYNOPSIS
    Converts a DateTime to ISO 8601 format for API requests
.PARAMETER DateTime
    The DateTime to convert
.OUTPUTS
    String - ISO 8601 formatted timestamp
.NOTES
    DateTimeKind handling:
    - Utc: Used as-is
    - Local: Converted to UTC
    - Unspecified: Treated as UTC (for ISO8601 strings without timezone indicator)
#>
function ConvertTo-KeepitTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [DateTime]$DateTime
    )

    # If Kind is Unspecified (e.g., from ISO8601 string without Z suffix), treat as UTC
    # This allows users to specify times like "2025-12-04T09:50:00" and have them
    # interpreted as UTC rather than local time
    if ($DateTime.Kind -eq [System.DateTimeKind]::Unspecified) {
        $DateTime = [DateTime]::SpecifyKind($DateTime, [System.DateTimeKind]::Utc)
    }

    return $DateTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

<#
.SYNOPSIS
    Gets the display name for a connector type
.PARAMETER ConnectorType
    The internal connector type name (e.g., 'o365-admin')
.OUTPUTS
    String - The display name (e.g., 'Microsoft 365'), or the original type if not found
#>
function Get-ConnectorTypeDisplayName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConnectorType
    )

    if ($script:ConnectorTypes.ContainsKey($ConnectorType)) {
        return $script:ConnectorTypes[$ConnectorType]
    }
    # Return original type if not in mapping (for forward compatibility)
    return $ConnectorType
}

<#
.SYNOPSIS
    Resolves a connector type name (key or display name) to the internal key
.PARAMETER TypeName
    The connector type name, which can be either:
    - An internal key (e.g., 'o365-admin', 'azure-ad', 'jsm')
    - A display name (e.g., 'Microsoft 365', 'Entra ID', 'Jira Service Management')
.OUTPUTS
    String - The internal key if found, or $null if not recognized
#>
function Resolve-ConnectorTypeName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TypeName
    )

    # Check if it's already an internal key
    if ($script:ConnectorTypes.ContainsKey($TypeName)) {
        return $TypeName
    }

    # Check if it's a display name (case-insensitive)
    foreach ($key in $script:ConnectorTypes.Keys) {
        if ($script:ConnectorTypes[$key] -eq $TypeName) {
            return $key
        }
    }

    # Not found
    return $null
}

<#
.SYNOPSIS
    Validates a connector type name (key or display name)
.PARAMETER TypeName
    The connector type name to validate
.OUTPUTS
    Boolean - $true if valid, $false otherwise
#>
function Test-ConnectorTypeName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TypeName
    )

    return $null -ne (Resolve-ConnectorTypeName -TypeName $TypeName)
}

<#
.SYNOPSIS
    Validates workload parameter values against connector type
.DESCRIPTION
    Validates that the specified workloads are valid for the given connector type.
    Throws an error if the connector type does not support workloads or if invalid
    workload names are specified.
.PARAMETER Workload
    Array of workload names to validate
.PARAMETER ConnectorType
    The connector type to validate against (e.g., 'o365-admin', 'dynamics365')
.OUTPUTS
    None. Throws an error if validation fails.
.EXAMPLE
    Test-WorkloadParameter -Workload @('Exchange', 'Teams') -ConnectorType 'o365-admin'

    Validates that Exchange and Teams are valid workloads for o365-admin connectors.
#>
function Test-WorkloadParameter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Workload,

        [Parameter(Mandatory = $true)]
        [string]$ConnectorType
    )

    $validWorkloads = $script:WorkloadsByConnectorType[$ConnectorType]
    if (-not $validWorkloads) {
        $displayName = Get-ConnectorTypeDisplayName -ConnectorType $ConnectorType
        throw "The -Workload parameter is not supported for $displayName ($ConnectorType) connectors. This connector type has a single configuration block."
    }

    foreach ($w in $Workload) {
        if ($w -notin $validWorkloads) {
            $displayName = Get-ConnectorTypeDisplayName -ConnectorType $ConnectorType
            throw "Invalid workload '$w' for $displayName ($ConnectorType) connectors. Valid workloads are: $($validWorkloads -join ', ')"
        }
    }

    Write-Verbose "Validated workloads: $($Workload -join ', ')"
}

function Resolve-WorkloadAlias {
    <#
    .SYNOPSIS
        Resolves a workload alias to its canonical name
    .DESCRIPTION
        Resolves workload aliases (ExO, ODB) to their canonical names (Exchange, OneDrive).
        If the workload is not an alias, returns it unchanged.
    .PARAMETER Workload
        The workload name or alias to resolve
    .OUTPUTS
        The canonical workload name
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Workload
    )

    if ($script:WorkloadAliasToCanonical.ContainsKey($Workload)) {
        $canonical = $script:WorkloadAliasToCanonical[$Workload]
        Write-Verbose "Resolved workload alias '$Workload' to '$canonical'"
        return $canonical
    }

    return $Workload
}

<#
.SYNOPSIS
    Validates that a string is a valid URL
.DESCRIPTION
    Validates that the specified string is a valid URL with at minimum a scheme and host.
    Used for validating SharePoint site URLs in configuration management.
.PARAMETER Url
    The URL string to validate
.OUTPUTS
    None. Throws an error if validation fails.
.EXAMPLE
    Test-SiteUrl -Url "https://contoso.sharepoint.com/sites/Marketing"

    Validates that the string is a valid URL.
#>
function Test-SiteUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    try {
        $uri = [System.Uri]::new($Url)
        if (-not $uri.IsAbsoluteUri) {
            throw "URL must be absolute (include scheme like https://)"
        }
        if ([string]::IsNullOrWhiteSpace($uri.Host)) {
            throw "URL must include a host"
        }
        if ($uri.Scheme -notin @('http', 'https')) {
            throw "URL scheme must be http or https"
        }
        Write-Verbose "Validated URL: $Url"
    }
    catch [System.UriFormatException] {
        throw "Invalid URL format '$Url': $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Validates that a string is a valid GUID format
.DESCRIPTION
    Validates that the specified string is a valid GUID (globally unique identifier).
    Used for validating group GUIDs in Teams/UnifiedGroups configuration management.
.PARAMETER Guid
    The GUID string to validate
.OUTPUTS
    None. Throws an error if validation fails.
.EXAMPLE
    Test-GroupGuid -Guid "0aa94c0a-c5e5-417f-8cfa-6744649e25da"

    Validates that the string is a valid GUID.
#>
function Test-GroupGuid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Guid
    )

    $guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if ($Guid -notmatch $guidPattern) {
        throw "Invalid GUID format '$Guid'. Expected format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    }
    Write-Verbose "Validated GUID: $Guid"
}

<#
.SYNOPSIS
    Extracts SharePoint coverage information from connector configuration
.PARAMETER Config
    The SharePointNG section of the connector configuration (hashtable)
.PARAMETER FullConfig
    The full connector configuration (hashtable), used for top-level properties
.OUTPUTS
    Array of PSCustomObjects describing SharePoint site coverage
#>
function Get-SharePointCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $results = @()

    $autoInclude = if ($Config.ContainsKey('AutoIncludeAllSiteCollections')) {
        $Config['AutoIncludeAllSiteCollections']
    } else {
        $false
    }

    if ($autoInclude) {
        # When auto-include is on, report a summary entry with exclusions
        $excludeSites = if ($Config.ContainsKey('ExcludeSiteCollections')) {
            @($Config['ExcludeSiteCollections'])
        } else {
            @()
        }
        $excludePrefixes = if ($Config.ContainsKey('ExcludeSiteCollectionsWithPrefixes')) {
            @($Config['ExcludeSiteCollectionsWithPrefixes'])
        } else {
            @()
        }

        $results += [PSCustomObject]@{
            SiteUrl                  = '*'
            AutoIncludeAllSubSites   = $true
            SubSites                 = @()
            ExcludeSubSites          = @()
            ExcludeSiteCollections   = $excludeSites
            ExcludeSiteCollectionsWithPrefixes = $excludePrefixes
        }
    }

    # Include explicit site collections
    if ($Config.ContainsKey('SiteCollections')) {
        foreach ($site in $Config['SiteCollections']) {
            $siteUrl = if ($site -is [hashtable] -and $site.ContainsKey('SiteUrl')) {
                $site['SiteUrl']
            } elseif ($site.PSObject -and $site.PSObject.Properties['SiteUrl']) {
                $site.SiteUrl
            } else {
                $null
            }

            $autoSubSites = if ($site -is [hashtable] -and $site.ContainsKey('AutoIncludeAllSubSites')) {
                $site['AutoIncludeAllSubSites']
            } elseif ($site.PSObject -and $site.PSObject.Properties['AutoIncludeAllSubSites']) {
                $site.AutoIncludeAllSubSites
            } else {
                $false
            }

            $subSites = if ($site -is [hashtable] -and $site.ContainsKey('SubSites')) {
                @($site['SubSites'])
            } elseif ($site.PSObject -and $site.PSObject.Properties['SubSites']) {
                @($site.SubSites)
            } else {
                @()
            }

            $excludeSubSites = if ($site -is [hashtable] -and $site.ContainsKey('ExcludeSubSites')) {
                @($site['ExcludeSubSites'])
            } elseif ($site.PSObject -and $site.PSObject.Properties['ExcludeSubSites']) {
                @($site.ExcludeSubSites)
            } else {
                @()
            }

            $results += [PSCustomObject]@{
                SiteUrl                  = $siteUrl
                AutoIncludeAllSubSites   = $autoSubSites
                SubSites                 = $subSites
                ExcludeSubSites          = $excludeSubSites
                ExcludeSiteCollections   = $null
                ExcludeSiteCollectionsWithPrefixes = $null
            }
        }
    }

    return , $results
}

<#
.SYNOPSIS
    Extracts Exchange coverage information from connector configuration
.PARAMETER Config
    The Exchange section of the connector configuration (hashtable)
.PARAMETER FullConfig
    The full connector configuration (hashtable), used for top-level UserSelectionRules
.OUTPUTS
    Array containing a single PSCustomObject describing Exchange coverage
#>
function Get-ExchangeCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [hashtable]$FullConfig
    )

    $enabledCategories = if ($Config.ContainsKey('EnabledCategories')) {
        @($Config['EnabledCategories'])
    } else {
        @()
    }

    $userSelectionRules = if ($FullConfig.ContainsKey('UserSelectionRules')) {
        $FullConfig['UserSelectionRules']
    } elseif ($Config.ContainsKey('UserSelectionRules')) {
        $Config['UserSelectionRules']
    } else {
        $null
    }

    return , @([PSCustomObject]@{
        EnabledCategories  = $enabledCategories
        UserSelectionRules = $userSelectionRules
    })
}

<#
.SYNOPSIS
    Extracts OneDrive coverage information from connector configuration
.PARAMETER Config
    The OneDriveSP section of the connector configuration (hashtable)
.PARAMETER FullConfig
    The full connector configuration (hashtable), used for top-level UserSelectionRules
.OUTPUTS
    Array containing a single PSCustomObject describing OneDrive coverage
#>
function Get-OneDriveCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [hashtable]$FullConfig
    )

    $options = if ($Config.ContainsKey('Options')) {
        $Config['Options']
    } else {
        $null
    }

    $userSelectionRules = if ($FullConfig.ContainsKey('UserSelectionRules')) {
        $FullConfig['UserSelectionRules']
    } elseif ($Config.ContainsKey('UserSelectionRules')) {
        $Config['UserSelectionRules']
    } else {
        $null
    }

    return , @([PSCustomObject]@{
        Options            = $options
        UserSelectionRules = $userSelectionRules
    })
}

<#
.SYNOPSIS
    Extracts Teams/UnifiedGroups coverage information from connector configuration
.PARAMETER Config
    The UnifiedGroups section of the connector configuration (hashtable)
.PARAMETER FullConfig
    The full connector configuration (hashtable)
.OUTPUTS
    Array containing a single PSCustomObject describing Teams/UnifiedGroups coverage
#>
function Get-UnifiedGroupsCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $autoInclude = if ($Config.ContainsKey('AutoIncludeGroups')) {
        $Config['AutoIncludeGroups']
    } else {
        $false
    }

    $enabledCategories = if ($Config.ContainsKey('EnabledCategories')) {
        @($Config['EnabledCategories'])
    } else {
        @()
    }

    $includeGroups = if ($Config.ContainsKey('IncludeGroups')) {
        @($Config['IncludeGroups'])
    } else {
        @()
    }

    $excludeGroups = if ($Config.ContainsKey('ExcludeGroups')) {
        @($Config['ExcludeGroups'])
    } else {
        @()
    }

    return , @([PSCustomObject]@{
        AutoIncludeGroups = $autoInclude
        EnabledCategories = $enabledCategories
        IncludeGroups     = $includeGroups
        ExcludeGroups     = $excludeGroups
    })
}

<#
.SYNOPSIS
    Resolves a connector identity (name or GUID) to a GUID
.DESCRIPTION
    Takes a connector identity that can be either a connector name or a GUID,
    and returns the corresponding GUID. If a GUID is provided, it validates
    that the connector exists. If a name is provided, it looks up the connector
    and returns its GUID.

    Uses cached authentication from Connect-KeepitService.
.PARAMETER Identity
    The connector name or GUID to resolve
.OUTPUTS
    PSCustomObject with properties:
        - ConnectorGuid: The resolved GUID
        - Name: The connector name
        - Type: The connector type
#>
function Resolve-KeepitConnectorIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Identity
    )

    Write-Verbose "Resolving connector identity: $Identity"

    # Get authentication and connection info
    $authHeader = Get-AuthHeader
    $baseUrl = Get-KeepitBaseUrl
    $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl

    # Check if Identity looks like a GUID (three groups of 6 alphanumeric chars)
    $isGuid = $Identity -match '^[a-z0-9]{6}-[a-z0-9]{6}-[a-z0-9]{6}$'

    # Get all connectors
    $headers = @{
        'Authorization' = $authHeader
        'Content-Type' = 'application/xml'
        'Accept' = 'application/vnd.keepit.v4+xml'
    }

    $uri = "$baseUrl/users/$userId/devices"
    Write-Verbose "Fetching connectors from: $uri"

    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop

    if (-not $response.devices.cloud) {
        throw "No connectors found"
    }

    # Normalize to array
    $devices = if ($response.devices.cloud -is [System.Array]) {
        $response.devices.cloud
    } else {
        @($response.devices.cloud)
    }

    # Find matching connector
    $matchingConnector = $null

    if ($isGuid) {
        # Look up by GUID (case-insensitive)
        $matchingConnector = $devices | Where-Object {
            $_.guid -eq $Identity -or $_.guid -eq $Identity.ToLower()
        } | Select-Object -First 1
    }

    if (-not $matchingConnector) {
        # Look up by name (case-insensitive)
        $matchingConnector = $devices | Where-Object {
            $_.name -eq $Identity
        } | Select-Object -First 1
    }

    if (-not $matchingConnector) {
        throw "Connector '$Identity' not found"
    }

    # Determine device type (handle DSL connectors)
    $deviceType = if ($matchingConnector.type -eq 'dsl') {
        $matchingConnector.'agent-type'
    } else {
        $matchingConnector.type
    }

    return [PSCustomObject]@{
        ConnectorGuid = $matchingConnector.guid.ToLower()
        Name = $matchingConnector.name
        Type = $deviceType
    }
}

<#
.SYNOPSIS
    Converts an ISO 8601 duration to human-readable English text
.DESCRIPTION
    Parses ISO 8601 duration format (e.g., P3M, P1Y, P1Y6M, P30D) and converts
    to readable English text (e.g., "3 months", "1 year", "1 year, 6 months", "30 days").
    Returns "Unlimited" for null/empty input.
.PARAMETER Duration
    ISO 8601 duration string (e.g., "P3M", "P1Y6M", "P30D")
.OUTPUTS
    String - Human-readable duration text
.EXAMPLE
    ConvertFrom-ISO8601Duration -Duration "P3M"
    # Returns: "3 months"
.EXAMPLE
    ConvertFrom-ISO8601Duration -Duration "P1Y6M"
    # Returns: "1 year, 6 months"
.EXAMPLE
    ConvertFrom-ISO8601Duration -Duration $null
    # Returns: "Unlimited"
#>
function ConvertFrom-ISO8601Duration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Duration
    )

    # Handle null/empty as unlimited retention
    if ([string]::IsNullOrWhiteSpace($Duration)) {
        return "Unlimited"
    }

    # ISO 8601 duration format: P[n]Y[n]M[n]D or P[n]W
    # Examples: P3M (3 months), P1Y (1 year), P1Y6M (1 year 6 months), P30D (30 days), P2W (2 weeks)
    if ($Duration -notmatch '^P') {
        Write-Verbose "Invalid ISO 8601 duration format: $Duration"
        return $Duration  # Return as-is if not valid ISO 8601
    }

    $parts = @()

    # Extract years
    if ($Duration -match '(\d+)Y') {
        $years = [int]$Matches[1]
        $parts += if ($years -eq 1) { "1 year" } else { "$years years" }
    }

    # Extract months
    if ($Duration -match '(\d+)M(?![A-Z])') {
        $months = [int]$Matches[1]
        $parts += if ($months -eq 1) { "1 month" } else { "$months months" }
    }

    # Extract weeks
    if ($Duration -match '(\d+)W') {
        $weeks = [int]$Matches[1]
        $parts += if ($weeks -eq 1) { "1 week" } else { "$weeks weeks" }
    }

    # Extract days
    if ($Duration -match '(\d+)D') {
        $days = [int]$Matches[1]
        $parts += if ($days -eq 1) { "1 day" } else { "$days days" }
    }

    if ($parts.Count -eq 0) {
        Write-Verbose "Could not parse ISO 8601 duration: $Duration"
        return $Duration  # Return as-is if nothing was parsed
    }

    return $parts -join ', '
}

#endregion
