#Requires -Version 7.0

<#
.SYNOPSIS
    Keepit Tools PowerShell Module
.DESCRIPTION
    Provides cmdlets for using the Keepit API from PowerShell scripts, including cmdlets to
    connect and disconnect from the service, get the status of backup jobs, start backup jobs,
    and get information about existing Microsoft 365 connectors.
.NOTES
    Author: Keepit
    Version: 0.7.7
#>

# Module-scoped variables
$script:KeepitAuth = $null
$script:KeepitRegion = $null
$script:KeepitUserId = $null

# Valid Keepit environments (used for parameter validation)
$script:ValidKeepitEnvironments = @(
    'ws.keepit', 'au-sy', 'ca-tr', 'dk-co', 'de-fr', 'uk-ld', 'us-dc', 'ch-zh',
    'ws-test', 'ws-test-b', 'ws-test-c', 'staging', 'dev'
)

# Keepit connector types mapping (internal name -> display name)
$script:ConnectorTypes = @{
    'o365-admin'  = 'Microsoft 365'
    'dynamics365' = 'Dynamics / Power Platform'
    'sforce'      = 'Salesforce'
    'gsuite'      = 'Google Workspace'
    'powerbi'     = 'Power BI'
    'zendesk'     = 'Zendesk'
    'azure-do'    = 'Azure DevOps'
    'azure-ad'    = 'Entra ID'
    'dsl'         = 'Keepit DSL'
    # DSL-based connectors (actual API type is 'dsl')
    'jira'        = 'Jira'
    'confluence'  = 'Confluence'
    'bamboohr'    = 'BambooHR'
    'docusign'    = 'Docusign'
    'jsm'         = 'Jira Service Management'
    'okta'        = 'Okta'
    'miro'        = 'Miro'
    'gitlab'      = 'GitLab'
    'monday'      = 'Monday'
}

# Maps user-friendly connector type names to actual API types
# Used for DSL-based connectors that share the same underlying API type
$script:ConnectorTypeApiMapping = @{
    'jira'       = 'dsl'
    'confluence' = 'dsl'
    'bamboohr'   = 'dsl'
    'docusign'   = 'dsl'
    'jsm'        = 'dsl'
    'okta'       = 'dsl'
    'miro'       = 'dsl'
    'gitlab'     = 'dsl'
    'monday'     = 'dsl'
}

# Valid connector type names for parameter validation
$script:ValidConnectorTypes = $script:ConnectorTypes.Keys

# Define valid workloads per connector type
$script:WorkloadsByConnectorType = @{
    'o365-admin'  = @('Exchange', 'ExO', 'OneDrive', 'ODB', 'SharePoint', 'Teams', 'UnifiedGroups')
    'dynamics365' = @('CRM', 'PowerApps', 'PowerAutomate')
}

# Map user-friendly workload names to JSON property names
$script:WorkloadToJsonKey = @{
    # M365 workloads
    'Exchange'      = 'Exchange'
    'ExO'           = 'Exchange'       # Alias for Exchange
    'OneDrive'      = 'OneDriveSP'
    'ODB'           = 'OneDriveSP'     # Alias for OneDrive
    'SharePoint'    = 'SharePointNG'
    'Teams'         = 'UnifiedGroups'
    'UnifiedGroups' = 'UnifiedGroups'  # Synonym for Teams
}

# Map workload aliases to canonical names (for internal comparison)
$script:WorkloadAliasToCanonical = @{
    'ExO' = 'Exchange'
    'ODB' = 'OneDrive'
}

$script:WorkloadToJsonKey += @{
    # Dynamics 365 workloads
    'CRM'           = 'CRM'
    'PowerApps'     = 'PowerApps'
    'PowerAutomate' = 'PowerAutomate'
}

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
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [hashtable]$FullConfig
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
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [hashtable]$FullConfig
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

#region Public Cmdlets

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
                    ConnectedAt = [DateTime]::UtcNow
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

<#
.SYNOPSIS
    Retrieves Keepit connectors for the authenticated user
.DESCRIPTION
    Gets a list of accessible connectors configured in Keepit. By default returns all connector
    types, but can be filtered to specific types using the -Type parameter, or to a specific
    connector using the -Identity parameter.
    Returns connector objects with details including GUID, name, type, and retention settings.
.PARAMETER Identity
    Optional connector name or GUID to retrieve a specific connector.
    If not specified, returns all connectors (optionally filtered by Type).
.PARAMETER Type
    Optional connector type(s) to filter. Can specify one or more types using either:
    - Internal keys: o365-admin, dynamics365, sforce, gsuite, powerbi, zendesk, azure-do, azure-ad,
                     dsl, jira, confluence, bamboohr, docusign, jsm, okta, miro, gitlab, monday
    - Display names: 'Microsoft 365', 'Entra ID', 'Jira Service Management', etc.
    If not specified, returns all connector types.
.PARAMETER IncludeDeleted
    When specified, includes deleted connectors in the response. Appends '?all=1' to the API request.
    Deleted connectors have a deletion-deadline set and will have Deleted = $true in the output.
.PARAMETER Raw
    When specified, returns the raw XML response from the API instead of parsed connector objects.
    Useful for debugging or when you need access to all XML elements.
.EXAMPLE
    Get-KeepitConnector

    Retrieves all connectors using cached connection
.EXAMPLE
    Get-KeepitConnector -Identity "Production M365"

    Retrieves the connector named "Production M365"
.EXAMPLE
    Get-KeepitConnector -Id "v25zn4-q77we0-0m4y7e"

    Retrieves a connector by its GUID (using the -Id alias)
.EXAMPLE
    Get-KeepitConnector -Type 'o365-admin'

    Retrieves only Microsoft 365 connectors using internal key
.EXAMPLE
    Get-KeepitConnector -Type 'Microsoft 365'

    Retrieves only Microsoft 365 connectors using display name
.EXAMPLE
    Get-KeepitConnector -Type 'o365-admin', 'dynamics365'

    Retrieves Microsoft 365 and Dynamics 365 connectors
.EXAMPLE
    Get-KeepitConnector -Type 'Jira Service Management', 'Confluence'

    Retrieves Jira Service Management and Confluence connectors using display names
.EXAMPLE
    $connectors = Get-KeepitConnector | Where-Object { $_.Name -like "*Production*" }

    Retrieves connectors and filters for production environments
.EXAMPLE
    Get-KeepitConnector -IncludeDeleted

    Retrieves all connectors including deleted ones (those with a deletion-deadline set)
.EXAMPLE
    Get-KeepitConnector -Raw

    Returns the raw XML response from the API
.EXAMPLE
    Get-KeepitConnector -Raw -IncludeDeleted | Out-File connectors.xml

    Saves raw XML including deleted connectors to a file
.OUTPUTS
    PSCustomObject[] - Array of connector objects with properties (default):
        - ConnectorGuid: Connector GUID (lowercase)
        - Name: Connector name (max 200 characters)
        - Type: Connector type (e.g., 'o365-admin')
        - TypeDisplayName: Human-readable connector type (e.g., 'Microsoft 365')
        - Created: Creation timestamp
        - BackupRetention: Backup retention period
        - RetentionUpdated: Last retention update timestamp
        - OrgLink: Organization link (if available)
        - Deleted: Boolean indicating if connector is marked for deletion (has deletion-deadline)

    String - Raw XML response from the API (when -Raw is specified)
.NOTES
    Only returns accessible connectors. Use -Type to filter by connector type.
    Use -IncludeDeleted to include connectors that have been marked for deletion.
#>
function Get-KeepitConnector {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true)]
        [Alias('Id')]
        [ValidateNotNullOrEmpty()]
        [string]$Identity,

        [Parameter(Mandatory = $false)]
        [ValidateScript({ Test-ConnectorTypeName -TypeName $_ })]
        [string[]]$Type,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDeleted,

        [Parameter(Mandatory = $false)]
        [switch]$Raw
    )

    try {
        Write-Verbose "Retrieving Keepit connectors"

        # Resolve type names to internal keys (handles both keys and display names)
        $resolvedTypes = if ($Type) {
            $Type | ForEach-Object { Resolve-ConnectorTypeName -TypeName $_ }
        } else {
            $null
        }

        # Get authentication header from cache
        $authHeader = Get-AuthHeader

        # Get base URL and user ID from cache
        $baseUrl = Get-KeepitBaseUrl
        $userId = $script:KeepitUserId

        if (-not $userId) {
            throw "Unable to determine user ID. Ensure you are connected using Connect-KeepitService."
        }

        Write-Verbose "User ID: $userId"

        # Build request
        $uri = "$baseUrl/users/$userId/devices"
        if ($IncludeDeleted) {
            $uri += '?all=1'
            Write-Verbose "Including deleted connectors (all=1)"
        }
        $headers = @{
            'Authorization' = $authHeader
            'Content-Type' = 'application/xml'
            'Accept' = 'application/vnd.keepit.v4+xml'  # v4+ required for DSL connector device-type
        }

        Write-Verbose "Fetching connectors from: $uri"

        # If -Raw is specified, return the raw XML response
        if ($Raw) {
            Write-Verbose "Returning raw XML response"
            $webResponse = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
            return $webResponse.Content
        }

        # Make API call
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop

        # Parse XML response
        if (-not $response.devices.cloud) {
            Write-Verbose "No connectors found in response"
            return
        }

        # Normalize to array (PowerShell XML may return single object or array)
        $devices = if ($response.devices.cloud -is [System.Array]) {
            $response.devices.cloud
        }
        else {
            @($response.devices.cloud)
        }

        Write-Verbose "Found $($devices.Count) total connectors"

        # Filter and transform devices
        $filteredCount = 0
        foreach ($device in $devices) {
            # Skip inaccessible devices
            if ($device.accessible -eq 'false') {
                Write-Verbose "Skipping inaccessible connector: $($device.name)"
                continue
            }

            # Validate required fields
            if (-not $device.guid -or -not $device.name) {
                Write-Verbose "Skipping connector with missing required fields"
                continue
            }

            # Determine device type (handle DSL connectors)
            $deviceType = if ($device.type -eq 'dsl') {
                $device.'agent-type'
            }
            else {
                $device.type
            }

            # Filter by type if specified
            if ($resolvedTypes -and $deviceType -notin $resolvedTypes) {
                Write-Verbose "Skipping connector: $($device.name) (type: $deviceType) - not in requested types"
                continue
            }

            # Filter by Identity if specified (match name or GUID)
            if ($Identity) {
                $guidMatch = $device.guid -eq $Identity -or $device.guid -eq $Identity.ToLower()
                $nameMatch = $device.name -eq $Identity
                if (-not $guidMatch -and -not $nameMatch) {
                    continue
                }
            }

            $filteredCount++

            # Determine if connector is marked for deletion
            $isDeleted = -not [string]::IsNullOrWhiteSpace($device.'deletion-deadline')

            # Create and output connector object
            [PSCustomObject]@{
                ConnectorGuid    = $device.guid.ToLower()
                Name             = $device.name.Substring(0, [Math]::Min(200, $device.name.Length))
                Type             = $deviceType
                TypeDisplayName  = Get-ConnectorTypeDisplayName -ConnectorType $deviceType
                Created          = $device.created
                BackupRetention  = ConvertFrom-ISO8601Duration -Duration $device.'backup-retention'
                RetentionUpdated = $device.'backup-retention-updated'
                OrgLink          = $device.orglink
                Deleted          = $isDeleted
            }
        }

        $typeDesc = if ($Type) { ($Type -join ', ') } else { 'all types' }
        Write-Verbose "Returned $filteredCount connectors ($typeDesc)"
    }
    catch {
        throw "Failed to retrieve connectors: $($_.Exception.Message)"
    }
}

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
    Maximum number of snapshots to return. Default is 99.
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
    Returns up to 99 snapshots by default. Use -ResultSize to change this limit or specify "unlimited".
#>
function Get-KeepitSnapshot {
    [CmdletBinding(DefaultParameterSetName = 'Latest')]
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
        $ResultSize = 99,

        [Parameter(Mandatory = $false, ParameterSetName = 'Range')]
        [switch]$Reverse
    )

    begin {
        Write-Verbose "Get-KeepitSnapshot: ParameterSetName = $($PSCmdlet.ParameterSetName)"

        # Validate date parameters if provided
        if ($PSCmdlet.ParameterSetName -in @('Range', 'Count')) {
            $today = [DateTime]::Today

            if ($StartTime.Date -gt $today) {
                throw "StartTime cannot be in the future. StartTime: $($StartTime.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)), Today: $($today.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture))"
            }

            if ($EndTime.Date -gt $today) {
                throw "EndTime cannot be in the future. EndTime: $($EndTime.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)), Today: $($today.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture))"
            }

            # When Reverse is specified, StartTime should be later than EndTime (we search backwards)
            if (-not $Reverse -and $StartTime -gt $EndTime) {
                throw "StartTime cannot be later than EndTime. StartTime: $($StartTime.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)), EndTime: $($EndTime.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture))"
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
            Write-Verbose "Date range (UTC): $($StartTime.ToString('yyyy-MM-ddTHH:mm:ssZ')) to $($EndTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        }

        # Get authentication header and base URL once for all pipeline items
        try {
            $authHeader = Get-AuthHeader
            $baseUrl = Get-KeepitBaseUrl
            $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl
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
            Write-Verbose "Processing connector: $($resolved.Name) ($connectorGuid)"

            switch ($PSCmdlet.ParameterSetName) {
                'Latest' {
                    # GET /users/{userId}/devices/{deviceId}/history/latest
                    $uri = "$baseUrl/users/$userId/devices/$connectorGuid/history/latest"
                    $headers = @{
                        'Authorization' = $authHeader
                        'Accept' = 'application/vnd.keepit.v1+xml'
                        'Content-Type' = 'application/xml'
                    }

                    Write-Verbose "Fetching latest snapshot from: $uri"
                    Write-Verbose "Request headers: $($headers | ConvertTo-Json -Compress)"
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
                    $maxIterations = if ($isUnlimited) { 10000 } else { [Math]::Ceiling($targetSize / 99) + 1 }

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

                        # Request items: use remaining needed if <= 99, otherwise 99 (API limit)
                        $apiCount = if ($isUnlimited) { 99 } else { [Math]::Min($targetSize - $allSnapshots.Count, 99) }
                        if ($apiCount -lt 1) { $apiCount = 99 }
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
                        if (-not $isUnlimited -and $targetSize -le 99) {
                            break
                        }
                        if ($retrievedCount -lt 99) {
                            break
                        }
                        if (-not $isUnlimited -and $allSnapshots.Count -ge $targetSize) {
                            break
                        }

                        # Get the timestamp of the last snapshot and use it + 1 second as new start
                        $lastTimestamp = $backups[-1].tstamp
                        if ($lastTimestamp) {
                            # Parse the timestamp and add 1 second for the next page
                            $parsedDate = [DateTime]::Parse($lastTimestamp, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
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

                    if (-not $isUnlimited -and $targetSize -le 99) {
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
                        $maxIterations = if ($isUnlimited) { 10000 } else { [Math]::Ceiling($targetSize / 99) + 1 }

                        do {
                            $iteration++
                            $targetDisplay = if ($isUnlimited) { 'unlimited' } else { $targetSize }
                            Write-Verbose "Count query iteration $iteration (counted: $totalCount, target: $targetDisplay)"

                            $startTimestamp = ConvertTo-KeepitTimestamp -DateTime $currentStartDate
                            # Add 1 day to make EndTime inclusive (P1D from Dec 30 only covers Dec 30)
                            $spanDays = [Math]::Ceiling(($EndTime - $currentStartDate).TotalDays) + 1
                            if ($spanDays -lt 1) { $spanDays = 1 }
                            $spanISO8601 = "P${spanDays}D"

                            $requestBody = "<range><start>$startTimestamp</start><span>$spanISO8601</span><count>99</count></range>"

                            Write-Verbose "Fetching snapshot range for counting from: $uri"
                            Write-Verbose "Query: start=$startTimestamp, span=$spanISO8601, count=99"
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
                            if ($retrievedCount -lt 99) {
                                break
                            }
                            if (-not $isUnlimited -and $totalCount -ge $targetSize) {
                                break
                            }

                            # Get the timestamp of the last snapshot and use it + 1 second as new start
                            $lastTimestamp = $backups[-1].tstamp
                            if ($lastTimestamp) {
                                $parsedDate = [DateTime]::Parse($lastTimestamp, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
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
            throw "Failed to retrieve snapshots for connector $connectorGuid : $($_.Exception.Message)"
        }
    }
}

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
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector,

        [Parameter(Mandatory = $false)]
        [ValidateSet('backup', 'restore')]
        [string]$Type,

        [Parameter(Mandatory = $false)]
        [DateTime]$StartTime,

        [Parameter(Mandatory = $false)]
        [DateTime]$EndTime,

        [Parameter(Mandatory = $false)]
        [switch]$Completed,

        [Parameter(Mandatory = $false)]
        [switch]$Scheduled,

        [Parameter(Mandatory = $false)]
        [switch]$Raw,

        [Parameter(Mandatory = $false)]
        [switch]$ActiveOnly
    )

    begin {
        Write-Verbose "Get-KeepitJobs"

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
            # Handle same-day search - expand to full day
            if ($StartTime.Date -eq $EndTime.Date) {
                Write-Verbose "StartTime and EndTime are the same date - expanding to full day"
                $StartTime = $StartTime.Date  # Midnight start
                $EndTime = $EndTime.Date.AddDays(1).AddSeconds(-1)  # 23:59:59
                Write-Verbose "Expanded range: $($StartTime.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)) to $($EndTime.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture))"
            }
            elseif ($StartTime -ge $EndTime) {
                throw "StartTime must be less than EndTime. StartTime: $StartTime, EndTime: $EndTime"
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
            $currentTime = [DateTime]::UtcNow
            Write-Verbose "No date range specified - filtering for active jobs and jobs scheduled in the future (after $currentTime)"
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
            throw "Failed to initialize: $($_.Exception.Message)"
        }
    }

    process {
        try {
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
                            $jobDateTime = [DateTime]::Parse($job.start)
                        }
                        elseif ($job.scheduled) {
                            $jobDateTime = [DateTime]::Parse($job.scheduled)
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
                        $jobDateTime = [DateTime]::Parse($job.start)
                    }
                    elseif ($job.scheduled) {
                        $jobDateTime = [DateTime]::Parse($job.scheduled)
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
                $jobObject
            }

            Write-Verbose "=== End Get-KeepitJobs ==="
        }
        catch {
            throw "Failed to retrieve jobs for connector $connectorGuid : $($_.Exception.Message)"
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
            throw "Failed to initialize: $($_.Exception.Message)"
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
                try { $jobsToCancel += @(Get-KeepitJobs -Connector $connectorGuid -ActiveOnly) } catch { }
                try { $jobsToCancel += @(Get-KeepitJobs -Connector $connectorGuid -Scheduled) } catch { }
                $jobsToCancel = $jobsToCancel | Where-Object { $_ -and $_.JobGuid }

                if ($jobsToCancel.Count -eq 0) {
                    Write-Verbose "No active or scheduled jobs found for connector '$connectorName'"
                    return
                }

                Write-Verbose "Found $($jobsToCancel.Count) job(s) to cancel"

                foreach ($job in $jobsToCancel) {
                    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
                    $cancelXml = "<job><cancelled>$timestamp</cancelled></job>"
                    $uri = "$baseUrl/users/$userId/devices/$connectorGuid/jobs/$($job.JobGuid)"

                    if ($PSCmdlet.ShouldProcess("$connectorName job $($job.JobGuid) ($($job.Type))", "Cancel")) {
                        $headers = @{
                            'Authorization' = $authHeader
                            'Content-Type'  = 'application/xml'
                        }
                        try {
                            Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $cancelXml -ErrorAction Stop | Out-Null
                            [PSCustomObject]@{
                                ConnectorGuid = $connectorGuid
                                ConnectorName = $connectorName
                                JobGuid       = $job.JobGuid
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
                            Write-Error "Failed to cancel job $($job.JobGuid): $errorMessage"
                            [PSCustomObject]@{
                                ConnectorGuid = $connectorGuid
                                ConnectorName = $connectorName
                                JobGuid       = $job.JobGuid
                                Status        = "Error: $errorMessage"
                                CancelledAt   = $null
                            }
                        }
                    }
                }
            }
            else {
                # Single job cancellation
                $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
                $cancelXml = "<job><cancelled>$timestamp</cancelled></job>"
                $uri = "$baseUrl/users/$userId/devices/$connectorGuid/jobs/$JobGuid"

                if ($PSCmdlet.ShouldProcess("$connectorName job $JobGuid", "Cancel")) {
                    $headers = @{
                        'Authorization' = $authHeader
                        'Content-Type'  = 'application/xml'
                    }
                    try {
                        Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $cancelXml -ErrorAction Stop | Out-Null
                        [PSCustomObject]@{
                            ConnectorGuid = $connectorGuid
                            ConnectorName = $connectorName
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
                        throw "Failed to cancel job $JobGuid on connector '$connectorName': $errorMessage"
                    }
                }
            }
        }
        catch {
            $errorGuid = if ($connectorGuid) { $connectorGuid } else { $Connector }
            throw "Failed to cancel job(s) on connector '$errorGuid': $($_.Exception.Message)"
        }
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector,

        [Parameter(Mandatory = $false)]
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
            throw "Failed to initialize: $($_.Exception.Message)"
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
            }

            Write-Verbose "=== Sending API Request ==="

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
                if ($apiError -and $apiError.Code -eq 'WAITING_JOB_TO_START') {
                    # Return a status object instead of throwing an error
                    Write-Verbose "Handling WAITING_JOB_TO_START gracefully"
                    Write-Warning "Cannot start backup for connector $connectorGuid - another backup job is already queued (scheduled for $($apiError.StartTime))"

                    $statusObject = [PSCustomObject]@{
                        ConnectorGuid = $connectorGuid
                        Type = 'backup'
                        Description = 'Job creation skipped'
                        Status = 'AlreadyQueued'
                        CreatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
                        ErrorCode = $apiError.Code
                        ErrorMessage = $apiError.Description
                        ExistingJobStartTime = $apiError.StartTime
                    }

                    Write-Verbose "=== Job Creation Skipped ==="
                    Write-Verbose "Reason: Another job already queued"
                    Write-Verbose "Existing job start time: $($apiError.StartTime)"
                    Write-Verbose "=== End Start-KeepitBackup ==="

                    return $statusObject
                }
                elseif ($apiError -and $apiError.Code -eq 'RUNNING_JOB') {
                    # Return a status object instead of throwing an error
                    Write-Verbose "Handling RUNNING_JOB gracefully"
                    Write-Warning "Cannot start backup for connector $connectorGuid - a backup job is already running (started $($apiError.StartTime))"

                    $statusObject = [PSCustomObject]@{
                        ConnectorGuid = $connectorGuid
                        Type = 'backup'
                        Description = 'Job creation skipped'
                        Status = 'AlreadyRunning'
                        CreatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
                        ErrorCode = $apiError.Code
                        ErrorMessage = $apiError.Description
                        ExistingJobStartTime = $apiError.StartTime
                    }

                    Write-Verbose "=== Job Creation Skipped ==="
                    Write-Verbose "Reason: Another job already running"
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
                if ($apiError.Code -eq 'WAITING_JOB_TO_START') {
                    Write-Verbose "Handling WAITING_JOB_TO_START gracefully"
                    Write-Warning "Cannot start backup for connector $connectorGuid - another backup job is already queued (scheduled for $($apiError.StartTime))"

                    $statusObject = [PSCustomObject]@{
                        ConnectorGuid = $connectorGuid
                        Type = 'backup'
                        Description = 'Job creation skipped'
                        Status = 'AlreadyQueued'
                        CreatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
                        ErrorCode = $apiError.Code
                        ErrorMessage = $apiError.Description
                        ExistingJobStartTime = $apiError.StartTime
                    }

                    Write-Verbose "=== Job Creation Skipped ==="
                    Write-Verbose "Reason: Another job already queued"
                    Write-Verbose "Existing job start time: $($apiError.StartTime)"
                    Write-Verbose "=== End Start-KeepitBackup ==="

                    return $statusObject
                }
                elseif ($apiError.Code -eq 'RUNNING_JOB') {
                    Write-Verbose "Handling RUNNING_JOB gracefully"
                    Write-Warning "Cannot start backup for connector $connectorGuid - a backup job is already running (started $($apiError.StartTime))"

                    $statusObject = [PSCustomObject]@{
                        ConnectorGuid = $connectorGuid
                        Type = 'backup'
                        Description = 'Job creation skipped'
                        Status = 'AlreadyRunning'
                        CreatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
                        ErrorCode = $apiError.Code
                        ErrorMessage = $apiError.Description
                        ExistingJobStartTime = $apiError.StartTime
                    }

                    Write-Verbose "=== Job Creation Skipped ==="
                    Write-Verbose "Reason: Another job already running"
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
        catch {
            throw "Failed to start backup job for connector $connectorGuid : $($_.Exception.Message)"
        }
    }
}

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

        # Validate that CountOnly and ResultSize are not both specified
        if ($CountOnly -and $PSBoundParameters.ContainsKey('ResultSize')) {
            throw "Cannot specify both -CountOnly and -ResultSize. Use -CountOnly to get just the count, or -ResultSize to get results."
        }

        # Validate that EndTime is not before StartTime
        if ($StartTime -and $EndTime -and $EndTime -lt $StartTime) {
            throw "EndTime ($($EndTime.ToString('yyyy-MM-dd'))) cannot be before StartTime ($($StartTime.ToString('yyyy-MM-dd')))"
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
            throw "Failed to initialize: $($_.Exception.Message)"
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
                    'Units',
                    'Applications',
                    'Devices',
                    'Groups',
                    'Policies',
                    'Roles',
                    'ServicePrincipals',
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

            while ($hasMoreResults) {
                # Calculate count for this request
                $requestCount = if ($isUnlimited) {
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
                Write-Verbose "Request Headers: $($headers | ConvertTo-Json -Compress)"
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
                    $published = $null
                    $size = $null
                    $contentType = $null
                    $isDeleted = $false
                    $detectedType = $null

                    # Helper function to safely get property value from XML or PSObject
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
                    try {
                        if ($entry.PSObject.Properties) {
                            foreach ($prop in $entry.PSObject.Properties) {
                                $propName = $prop.Name
                                if ($propName -and $propName -notin @('id', 'title', 'updated', 'published', 'kng:name', 'name', 'kng:size', 'size', 'kng:deleted', 'deleted', 'kng:class', 'class', 'content', 'link')) {
                                    $metadata[$propName] = $prop.Value
                                }
                            }
                        }
                        elseif ($entry -is [System.Xml.XmlElement]) {
                            # Handle XML element - iterate through child nodes
                            foreach ($childNode in $entry.ChildNodes) {
                                $nodeName = $childNode.LocalName
                                if ($nodeName -and $nodeName -notin @('id', 'title', 'updated', 'published', 'name', 'size', 'deleted', 'class', 'content', 'link')) {
                                    $metadata[$nodeName] = $childNode.InnerText
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
                Write-Warning "Search-KeepitSnapshot: No matching results found"
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
            throw "Failed to search connector $connectorGuid : $exceptionMessage"
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
function ConvertTo-MaskedPath {
    [CmdletBinding()]
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

<#
.SYNOPSIS
    Retrieves the configuration and attributes for a Keepit connector
.DESCRIPTION
    Gets the configuration JSON and/or custom attributes for a specified Keepit connector.
    The configuration contains connector-specific settings such as backup scope,
    included workloads, and other options. Supports pipeline input from Get-KeepitConnector
    for bulk operations.

    Default Configuration retrieval is supported for these connector types:
    - o365-admin (Microsoft 365)
    - dynamics365 (Dynamics / Power Platform)
    - azure-ad (Entra ID)
    - powerbi (Power BI)

    For other connector types, use the -Attributes parameter to fetch specific attributes.
    When -Attributes is specified, any connector type can be used.

    Use the -Workload parameter to filter and parse the configuration by specific workloads.
    This returns a parsed PSCustomObject containing only the requested workload sections.
.PARAMETER Connector
    The connector name or GUID. Can be piped from Get-KeepitConnector.
    Aliases: ConnectorGuid, Name
.PARAMETER Attributes
    Optional comma-separated list of attribute names to fetch, or "*" to fetch all
    attributes. When specified, the Attributes property of the output will contain
    a hashtable of key/value pairs. Attributes that don't exist or are empty will
    have null values.

    Examples:
    - "*" - Fetches all attributes
    - "ng_backup_config" - Fetches a single attribute
    - "ng_backup_config,backup_config" - Fetches multiple attributes
.PARAMETER Workload
    Optional array of workload names to filter the configuration by. When specified,
    the Configuration property will contain a parsed PSCustomObject with only the
    requested workloads. The RawConfiguration property still contains the full JSON.

    Valid workloads vary by connector type:
    - o365-admin: Exchange, OneDrive, SharePoint, Teams
    - dynamics365: CRM, PowerApps, PowerAutomate
    - azure-ad: Not supported (single configuration block)
    - powerbi: Not supported (single configuration block)

    An error is thrown if an invalid workload is specified for the connector type.
.PARAMETER Coverage
    Switch parameter that, when used with -Workload, returns parsed coverage information
    describing the scope of what is being backed up for the specified workload. Returns
    an array of PSCustomObjects with workload-specific properties.

    Requires exactly one -Workload value. Different workloads return different shapes:
    - SharePoint: Array of site objects with SiteUrl, AutoIncludeAllSubSites, SubSites,
      ExcludeSubSites. When AutoIncludeAllSiteCollections is true, includes a summary
      entry with SiteUrl='*' and exclusion lists.
    - Exchange: Single-element array with EnabledCategories and UserSelectionRules.
    - OneDrive: Single-element array with Options and UserSelectionRules.
    - Teams: Single-element array with AutoIncludeGroups, EnabledCategories,
      IncludeGroups, ExcludeGroups.
.EXAMPLE
    Get-KeepitConnectorConfiguration -Connector "abc123-def456"

    Gets the configuration for the specified connector by GUID.
.EXAMPLE
    Get-KeepitConnectorConfiguration -Connector "Production M365"

    Gets the configuration for a connector by name.
.EXAMPLE
    Get-KeepitConnectorConfiguration -Connector "Production M365" -Workload Exchange

    Gets only the Exchange workload configuration as a parsed object.
    Valid M365 workloads: Exchange, OneDrive, SharePoint, Teams
.EXAMPLE
    Get-KeepitConnectorConfiguration -Connector "Production M365" -Workload Exchange,OneDrive

    Gets Exchange and OneDrive workload configurations as parsed objects.
.EXAMPLE
    Get-KeepitConnectorConfiguration -Connector "Production M365" -Workload SharePoint,Teams

    Gets SharePoint and Teams workload configurations.
.EXAMPLE
    Get-KeepitConnectorConfiguration -Connector "Dynamics Prod" -Workload CRM,PowerApps

    Gets CRM and PowerApps workload configurations for a Dynamics 365 connector.
    Valid Dynamics 365 workloads: CRM, PowerApps, PowerAutomate
.EXAMPLE
    Get-KeepitConnector | Get-KeepitConnectorConfiguration

    Gets the configuration for all connectors via pipeline.
.EXAMPLE
    Get-KeepitConnectorConfiguration -Connector "abc123" | Select-Object -ExpandProperty RawConfiguration

    Gets just the raw JSON configuration string for a connector.
.EXAMPLE
    Get-KeepitConnectorConfiguration -Connector "abc123" -Attributes "*"

    Gets the configuration and all attributes for a connector.
.EXAMPLE
    Get-KeepitConnectorConfiguration -Connector "My Connector" -Attributes "ng_backup_config,custom_attr"

    Gets the configuration and specific attributes for a connector.
.EXAMPLE
    Get-KeepitConnector -Type google | Get-KeepitConnectorConfiguration -Attributes "*"

    Gets all attributes for Google connectors (which don't support default RawConfiguration).
.EXAMPLE
    Get-KeepitConnectorConfiguration -Connector "Production M365" -Workload SharePoint -Coverage

    Returns SharePoint coverage showing which sites are included/excluded from backup.
.EXAMPLE
    Get-KeepitConnectorConfiguration -Connector "Production M365" -Workload Exchange -Coverage

    Returns Exchange coverage showing enabled categories and user selection rules.
.EXAMPLE
    Get-KeepitConnectorConfiguration -Connector "Production M365" -Workload Teams -Coverage

    Returns Teams coverage showing auto-include groups setting and group include/exclude lists.
.OUTPUTS
    PSCustomObject with properties:
        - ConnectorGuid: The connector GUID (lowercase)
        - Name: The connector name
        - Type: The connector type (e.g., 'o365-admin')
        - TypeDisplayName: Human-readable connector type (e.g., 'Microsoft 365')
        - RawConfiguration: JSON string containing the full connector configuration (null for unsupported types)
        - Configuration: Parsed PSCustomObject filtered by -Workload (null if -Workload not specified)
        - Attributes: Hashtable of attribute key/value pairs (null if -Attributes not specified)
.NOTES
    Requires an active connection via Connect-KeepitService.
    RawConfiguration and attributes may contain sensitive information; handle accordingly.

    Workload names map to JSON property names as follows:
    - Exchange -> Exchange
    - OneDrive -> OneDriveSP
    - SharePoint -> SharePointNG
    - Teams -> UnifiedGroups
    - CRM -> CRM
    - PowerApps -> PowerApps
    - PowerAutomate -> PowerAutomate

    API endpoints used:
    - GET /users/{userId}/devices/{connectorGUID}/attributes/ng_backup_config
      (for o365-admin and dynamics365 connectors)
    - GET /users/{userId}/devices/{connectorGUID}/attributes/backup_config
      (for azure-ad and powerbi connectors)
    - GET /users/{userId}/devices/{connectorGUID}/attributes
      (when -Attributes "*" is specified)
    - GET /users/{userId}/devices/{connectorGUID}/attributes/{key}
      (when -Attributes specifies individual attribute names)
#>
function Get-KeepitConnectorConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$Attributes,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Workload,

        [Parameter(Mandatory = $false)]
        [switch]$Raw,

        [Parameter(Mandatory = $false)]
        [switch]$Coverage
    )

    begin {
        Write-Verbose "Get-KeepitConnectorConfiguration: Initializing"

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
            $connectorName = $resolved.Name
            $connectorType = $resolved.Type
            Write-Verbose "Connector: $connectorName ($connectorGuid, Type: $connectorType)"

            # If -Raw is specified, fetch raw XML from device endpoint and return immediately
            if ($Raw) {
                Write-Verbose "Fetching raw XML from device endpoint"
                $uri = "$baseUrl/users/$userId/devices/$connectorGuid"
                $headers = @{
                    'Authorization' = $authHeader
                    'Accept'        = 'application/vnd.keepit.v4+xml'
                }

                $webResponse = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
                $rawXml = if ($webResponse.Content -is [byte[]]) {
                    [System.Text.Encoding]::UTF8.GetString($webResponse.Content)
                }
                else {
                    $webResponse.Content
                }

                Write-Verbose "Raw XML retrieved: $($rawXml.Length) characters"
                return $rawXml
            }

            # Determine supported connector types for default configuration retrieval
            $supportedConfigTypes = @('o365-admin', 'dynamics365', 'azure-ad', 'powerbi')
            $isConfigSupported = $connectorType -in $supportedConfigTypes

            # Validate -Workload parameter against connector type
            if ($Workload) {
                Test-WorkloadParameter -Workload $Workload -ConnectorType $connectorType
            }

            # Validate -Coverage parameter requirements
            if ($Coverage) {
                if (-not $Workload) {
                    throw "The -Coverage parameter requires -Workload to be specified."
                }
                if ($Workload.Count -gt 1) {
                    throw "The -Coverage parameter requires exactly one workload. Specify a single -Workload value."
                }
            }

            # If -Attributes is not specified, require supported connector type
            if (-not $Attributes -and -not $isConfigSupported) {
                $displayName = Get-ConnectorTypeDisplayName -ConnectorType $connectorType
                throw "This connector type is not yet supported: $displayName ($connectorType). Use -Attributes to fetch specific attributes."
            }

            # Initialize result properties
            $configXml = $null
            $attributesResult = $null

            # Fetch default configuration for supported connector types
            if ($isConfigSupported) {
                # Determine the correct attribute endpoint based on connector type
                $configAttribute = switch ($connectorType) {
                    { $_ -in @('o365-admin', 'dynamics365') } { 'ng_backup_config' }
                    { $_ -in @('azure-ad', 'powerbi') } { 'backup_config' }
                }
                Write-Verbose "Using config attribute: $configAttribute for connector type: $connectorType"

                # Build request to get connector configuration
                $uri = "$baseUrl/users/$userId/devices/$connectorGuid/attributes/$configAttribute"
                $headers = @{
                    'Authorization' = $authHeader
                }

                Write-Verbose "Fetching configuration from: $uri (attribute: $configAttribute)"

                try {
                    # Make API call - use Invoke-WebRequest to get raw content since API returns octet-stream
                    $webResponse = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -ErrorAction Stop

                    Write-Verbose "Response Content-Type: $($webResponse.Headers.'Content-Type')"
                    Write-Verbose "Response length: $($webResponse.Content.Length) bytes"

                    # Get the raw content as a string
                    $configXml = if ($webResponse.Content -is [byte[]]) {
                        [System.Text.Encoding]::UTF8.GetString($webResponse.Content)
                    }
                    else {
                        $webResponse.Content
                    }

                    Write-Verbose "Configuration retrieved: $($configXml.Length) characters"
                }
                catch {
                    Write-Verbose "Failed to retrieve default configuration: $($_.Exception.Message)"
                    $configXml = $null
                }
            }

            # Fetch requested attributes if -Attributes is specified
            if ($Attributes) {
                $attributesResult = @{}
                $headers = @{
                    'Authorization' = $authHeader
                }

                if ($Attributes -eq '*') {
                    # Fetch all attributes - first get the list of attribute names, then fetch each value
                    Write-Verbose "Fetching all attributes for connector"
                    $uri = "$baseUrl/users/$userId/devices/$connectorGuid/attributes"

                    try {
                        $webResponse = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
                        $responseContent = if ($webResponse.Content -is [byte[]]) {
                            [System.Text.Encoding]::UTF8.GetString($webResponse.Content)
                        }
                        else {
                            $webResponse.Content
                        }

                        Write-Verbose "All attributes response: $($responseContent.Substring(0, [Math]::Min(200, $responseContent.Length)))"

                        # Parse the XML response to get attribute names
                        $attrNames = @()
                        if ($responseContent -match '^\s*<') {
                            $attrXml = [xml]$responseContent
                            # The response contains attribute elements with name attribute
                            foreach ($attr in $attrXml.attributes.attribute) {
                                $attrName = $attr.name
                                if ($attrName) {
                                    $attrNames += $attrName
                                    Write-Verbose "Found attribute name: $attrName"
                                }
                            }
                        }

                        # Now fetch each attribute value individually
                        Write-Verbose "Fetching values for $($attrNames.Count) attributes"
                        foreach ($attrName in $attrNames) {
                            $attrUri = "$baseUrl/users/$userId/devices/$connectorGuid/attributes/$attrName"
                            try {
                                $attrResponse = Invoke-WebRequest -Uri $attrUri -Method Get -Headers $headers -ErrorAction Stop
                                $attrValue = if ($attrResponse.Content -is [byte[]]) {
                                    [System.Text.Encoding]::UTF8.GetString($attrResponse.Content)
                                }
                                else {
                                    $attrResponse.Content
                                }

                                if ([string]::IsNullOrWhiteSpace($attrValue)) {
                                    $attributesResult[$attrName] = $null
                                }
                                else {
                                    $attributesResult[$attrName] = $attrValue
                                }
                            }
                            catch {
                                $attributesResult[$attrName] = $null
                                Write-Verbose "Failed to retrieve attribute '$attrName': $($_.Exception.Message)"
                            }
                        }
                    }
                    catch {
                        Write-Verbose "Failed to retrieve attribute list: $($_.Exception.Message)"
                    }
                }
                else {
                    # Fetch specific attributes from comma-separated list
                    $attrList = $Attributes -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                    Write-Verbose "Fetching specific attributes: $($attrList -join ', ')"

                    foreach ($attrName in $attrList) {
                        $uri = "$baseUrl/users/$userId/devices/$connectorGuid/attributes/$attrName"
                        Write-Verbose "Fetching attribute '$attrName' from: $uri"

                        try {
                            $webResponse = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
                            $attrValue = if ($webResponse.Content -is [byte[]]) {
                                [System.Text.Encoding]::UTF8.GetString($webResponse.Content)
                            }
                            else {
                                $webResponse.Content
                            }

                            # Check if the value is empty
                            if ([string]::IsNullOrWhiteSpace($attrValue)) {
                                $attributesResult[$attrName] = $null
                                Write-Verbose "Attribute '$attrName' has empty value"
                            }
                            else {
                                $attributesResult[$attrName] = $attrValue
                                Write-Verbose "Retrieved attribute '$attrName': $($attrValue.Substring(0, [Math]::Min(50, $attrValue.Length)))..."
                            }
                        }
                        catch {
                            # Return null for attributes that don't exist or have errors
                            $attributesResult[$attrName] = $null
                            Write-Verbose "Failed to retrieve attribute '$attrName': $($_.Exception.Message)"
                        }
                    }
                }
            }

            # Parse and filter configuration if -Workload is specified
            $parsedConfig = $null
            if ($Workload -and $configXml) {
                Write-Verbose "Parsing configuration JSON and filtering by workloads: $($Workload -join ', ')"
                try {
                    $fullConfig = $configXml | ConvertFrom-Json -AsHashtable

                    # If -Coverage is specified, dispatch to appropriate coverage helper
                    if ($Coverage) {
                        $w = $Workload[0]
                        $jsonKey = $script:WorkloadToJsonKey[$w]
                        if (-not $fullConfig.ContainsKey($jsonKey)) {
                            Write-Warning "Workload '$w' (JSON key: $jsonKey) not found in configuration"
                            return , @()
                        }
                        $workloadConfig = $fullConfig[$jsonKey]

                        $coverageResult = switch ($jsonKey) {
                            'SharePointNG'  { Get-SharePointCoverage -Config $workloadConfig -FullConfig $fullConfig }
                            'Exchange'      { Get-ExchangeCoverage -Config $workloadConfig -FullConfig $fullConfig }
                            'OneDriveSP'    { Get-OneDriveCoverage -Config $workloadConfig -FullConfig $fullConfig }
                            'UnifiedGroups' { Get-UnifiedGroupsCoverage -Config $workloadConfig -FullConfig $fullConfig }
                            default {
                                Write-Warning "Coverage is not supported for workload '$w'"
                                , @()
                            }
                        }
                        return $coverageResult
                    }

                    $filteredConfig = @{}

                    foreach ($w in $Workload) {
                        $jsonKey = $script:WorkloadToJsonKey[$w]
                        if ($fullConfig.ContainsKey($jsonKey)) {
                            $filteredConfig[$w] = $fullConfig[$jsonKey]
                            Write-Verbose "Added workload '$w' (JSON key: $jsonKey) to filtered configuration"
                        }
                        else {
                            Write-Verbose "Workload '$w' (JSON key: $jsonKey) not found in configuration - skipping"
                        }
                    }

                    # Convert hashtable to PSCustomObject for nicer output
                    $parsedConfig = [PSCustomObject]$filteredConfig
                }
                catch {
                    Write-Warning "Failed to parse configuration as JSON: $($_.Exception.Message)"
                    $parsedConfig = $null
                }
            }

            # Return result object
            [PSCustomObject]@{
                ConnectorGuid    = $connectorGuid
                Name             = $connectorName
                Type             = $connectorType
                TypeDisplayName  = Get-ConnectorTypeDisplayName -ConnectorType $connectorType
                RawConfiguration = $configXml
                Configuration    = $parsedConfig
                Attributes       = $attributesResult
            }
        }
        catch {
            $errorGuid = if ($connectorGuid) { $connectorGuid } else { $Connector }
            throw "Failed to retrieve configuration for connector '$errorGuid': $($_.Exception.Message)"
        }
    }
}

<#
.SYNOPSIS
    Updates the configuration for a Keepit connector
.DESCRIPTION
    Sets the configuration JSON for a specified Keepit connector using the device attributes API.
    The configuration is stored as the ng_backup_config attribute for M365 and Dynamics 365 connectors,
    or backup_config for Azure AD and Power BI connectors.

    Supports pipeline input from Get-KeepitConnector for the connector identity.

    You can either provide a complete -RawConfiguration JSON string, or use modification parameters
    to incrementally change specific settings (e.g., adding/removing sites, groups, or users).
.PARAMETER Connector
    The connector name or GUID. Can be piped from Get-KeepitConnector.
    Aliases: ConnectorGuid, Name
.PARAMETER RawConfiguration
    The JSON configuration string to set. Maximum 64K length. Optional.
    This should be a valid JSON structure matching the connector type's expected format.
    If not provided, the current configuration will be fetched and modification parameters
    (such as -AutoIncludeSites, -AddIncludedSites, etc.) will be applied to it.
.PARAMETER Workload
    The workload to target for modification. Required when using modification parameters.
    For Microsoft 365 connectors, valid values are: Exchange (alias: ExO), OneDrive (alias: ODB),
    SharePoint, Teams (alias: UnifiedGroups).
.PARAMETER AutoIncludeSites
    Controls the AutoIncludeAllSiteCollections setting for SharePoint configuration.
    Requires -Workload SharePoint.
    - $true: Enables automatic inclusion of all site collections
    - $false: Disables automatic inclusion (removes the setting if present)
.PARAMETER AddIncludedSites
    Array of SharePoint site URLs to add to the SiteCollections list.
    Requires -Workload SharePoint. Sites are added with AutoIncludeAllSubSites = true.
    Shows a warning if a site is already included.
.PARAMETER RemoveIncludedSites
    Array of SharePoint site URLs to remove from the SiteCollections list.
    Requires -Workload SharePoint. Shows a warning if a site is not found.
.PARAMETER AddExcludedSites
    Array of SharePoint site URLs to add to the ExcludedSiteCollections list.
    Requires -Workload SharePoint. Shows a warning if a site is already excluded.
.PARAMETER RemoveExcludedSites
    Array of SharePoint site URLs to remove from the ExcludedSiteCollections list.
    Requires -Workload SharePoint. Shows a warning if a site is not found.
.PARAMETER AutoIncludeGroups
    Controls the AutoIncludeGroups setting for Teams/UnifiedGroups configuration.
    Requires -Workload Teams (or UnifiedGroups).
    - $true: Enables automatic inclusion of all groups
    - $false: Disables automatic inclusion
.PARAMETER AddIncludedGroups
    Array of group GUIDs to add to include lists.
    For -Workload Teams: Adds to UnifiedGroups.IncludeGroups
    For -Workload Exchange or OneDrive: Adds to UserSelectionRules.IncludeGroups
    Shows a warning if a group is already included.
.PARAMETER RemoveIncludedGroups
    Array of group GUIDs to remove from include lists.
    For -Workload Teams: Removes from UnifiedGroups.IncludeGroups
    For -Workload Exchange or OneDrive: Removes from UserSelectionRules.IncludeGroups
    Shows a warning if a group is not found.
.PARAMETER AddExcludedGroups
    Array of group GUIDs to add to the ExcludeGroups list.
    Requires -Workload Teams (or UnifiedGroups). Shows a warning if a group is already excluded.
.PARAMETER RemoveExcludedGroups
    Array of group GUIDs to remove from the ExcludeGroups list.
    Requires -Workload Teams (or UnifiedGroups). Shows a warning if a group is not found.
.PARAMETER EnabledCategories
    Array of Exchange categories to enable for backup. Replaces existing EnabledCategories.
    Requires -Workload Exchange. Valid values: Tasks, Mail, Contacts, Calendar, InPlaceArchive.
    Category names are case-sensitive (use 'Tasks', not 'tasks').
    Shows a warning if the specified categories match the existing configuration.
.PARAMETER AddIncludedUsers
    Array of user GUIDs to add to UserSelectionRules.IncludeUsers.
    Requires -Workload Exchange or OneDrive. Shows a warning if user is already included.
.PARAMETER RemoveIncludedUsers
    Array of user GUIDs to remove from UserSelectionRules.IncludeUsers.
    Requires -Workload Exchange or OneDrive. Shows a warning if user is not found.
.PARAMETER AddExcludedUsers
    Array of user GUIDs to add to UserSelectionRules.ExcludeUsers.
    Requires -Workload Exchange or OneDrive. Shows a warning if user is already excluded.
.PARAMETER RemoveExcludedUsers
    Array of user GUIDs to remove from UserSelectionRules.ExcludeUsers.
    Requires -Workload Exchange or OneDrive. Shows a warning if user is not found.
.PARAMETER AddIncludedCategories
    Array of selection categories to add to UserSelectionRules.IncludeCategories.
    Requires -Workload Exchange or OneDrive. Valid values: AllUsers, AllGroups, UsersNotInGroups.
.PARAMETER RemoveIncludedCategories
    Array of selection categories to remove from UserSelectionRules.IncludeCategories.
    Requires -Workload Exchange or OneDrive. Valid values: AllUsers, AllGroups, UsersNotInGroups.
.EXAMPLE
    Set-KeepitConnectorConfiguration -Connector "abc123-def456" -RawConfiguration $jsonConfig

    Sets the configuration for the specified connector by GUID.
.EXAMPLE
    Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload SharePoint -AddIncludedSites "https://contoso.sharepoint.com/sites/Marketing"

    Adds a SharePoint site to the included sites list.
.EXAMPLE
    Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload SharePoint -RemoveIncludedSites "https://contoso.sharepoint.com/sites/OldSite"

    Removes a SharePoint site from the included sites list.
.EXAMPLE
    Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload Teams -AddExcludedGroups "0aa94c0a-c5e5-417f-8cfa-6744649e25da"

    Adds a group to the excluded groups list for Teams backup.
.EXAMPLE
    Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload ExO -EnabledCategories Mail,Calendar,Contacts

    Sets the Exchange enabled categories (using alias ExO for Exchange).
.EXAMPLE
    Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload Exchange -AddIncludedGroups "41e69f1d-d0a5-429a-9271-d114dd9294c3"

    Adds a group to Exchange UserSelectionRules to filter which users are backed up.
.EXAMPLE
    Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload Exchange -AddExcludedUsers "73e50895-f50f-48a9-b8ec-a09168fa9892"

    Excludes a specific user from Exchange backup.
.EXAMPLE
    Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload ODB -AddIncludedCategories UsersNotInGroups

    Adds UsersNotInGroups category to OneDrive backup (using alias ODB).
.EXAMPLE
    Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload SharePoint -AddIncludedSites $siteUrls -WhatIf

    Shows what configuration would be written without making changes.
.EXAMPLE
    # Read, modify, and save configuration
    $current = Get-KeepitConnectorConfiguration -Connector "abc123"
    $config = $current.RawConfiguration | ConvertFrom-Json
    $config.Exchange.EnabledCategories += "InPlaceArchive"
    $newJson = $config | ConvertTo-Json -Depth 10
    Set-KeepitConnectorConfiguration -Connector "abc123" -RawConfiguration $newJson

    Reads current configuration, modifies it, and saves it back.
.OUTPUTS
    PSCustomObject with properties:
        - ConnectorGuid: The connector GUID (lowercase)
        - Name: The connector name
        - Type: The connector type
        - TypeDisplayName: Human-readable connector type
        - Status: "Success" or error message
        - RawConfiguration: The JSON configuration that was written (on success)
.NOTES
    Requires an active connection via Connect-KeepitService.

    Workload aliases: ExO (Exchange), ODB (OneDrive), UnifiedGroups (Teams).

    When using -WhatIf with any workload, the raw configuration that would be written
    is displayed in cyan/yellow formatting.

    If no actual changes are made (e.g., adding a site that already exists), the cmdlet
    displays a message and skips the write operation.

    The -AddIncludedGroups/-RemoveIncludedGroups parameters work differently depending on workload:
    - Teams: Modifies UnifiedGroups.IncludeGroups
    - Exchange/OneDrive: Modifies UserSelectionRules.IncludeGroups

    API endpoint used:
    - PUT /users/{userId}/devices/{connectorGUID}/attributes/ng_backup_config
      (for o365-admin and dynamics365 connectors)
    - PUT /users/{userId}/devices/{connectorGUID}/attributes/backup_config
      (for azure-ad and powerbi connectors)
#>
function Set-KeepitConnectorConfiguration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            if ($_.Length -gt 65536) {
                throw "RawConfiguration exceeds maximum length of 64K"
            }
            # Basic JSON validation
            try {
                $null = $_ | ConvertFrom-Json
                $true
            }
            catch {
                throw "RawConfiguration must be valid JSON: $($_.Exception.Message)"
            }
        })]
        [string]$RawConfiguration,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$Workload,

        # SharePoint configuration parameters
        [Parameter(Mandatory = $false)]
        [bool]$AutoIncludeSites,

        [Parameter(Mandatory = $false)]
        [string[]]$AddIncludedSites,

        [Parameter(Mandatory = $false)]
        [string[]]$RemoveIncludedSites,

        [Parameter(Mandatory = $false)]
        [string[]]$AddExcludedSites,

        [Parameter(Mandatory = $false)]
        [string[]]$RemoveExcludedSites,

        # Teams/UnifiedGroups configuration parameters
        [Parameter(Mandatory = $false)]
        [bool]$AutoIncludeGroups,

        [Parameter(Mandatory = $false)]
        [string[]]$AddIncludedGroups,

        [Parameter(Mandatory = $false)]
        [string[]]$RemoveIncludedGroups,

        [Parameter(Mandatory = $false)]
        [string[]]$AddExcludedGroups,

        [Parameter(Mandatory = $false)]
        [string[]]$RemoveExcludedGroups,

        # Exchange configuration parameters
        [Parameter(Mandatory = $false)]
        [ValidateSet('Tasks', 'Mail', 'Contacts', 'Calendar', 'InPlaceArchive')]
        [string[]]$EnabledCategories,

        # UserSelectionRules parameters (for Exchange and OneDrive workloads)
        [Parameter(Mandatory = $false)]
        [string[]]$AddIncludedUsers,

        [Parameter(Mandatory = $false)]
        [string[]]$RemoveIncludedUsers,

        [Parameter(Mandatory = $false)]
        [string[]]$AddExcludedUsers,

        [Parameter(Mandatory = $false)]
        [string[]]$RemoveExcludedUsers,

        [Parameter(Mandatory = $false)]
        [ValidateSet('AllUsers', 'AllGroups', 'UsersNotInGroups')]
        [string[]]$AddIncludedCategories,

        [Parameter(Mandatory = $false)]
        [ValidateSet('AllUsers', 'AllGroups', 'UsersNotInGroups')]
        [string[]]$RemoveIncludedCategories
    )

    begin {
        Write-Verbose "Set-KeepitConnectorConfiguration: Initializing"

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
            $connectorName = $resolved.Name
            $connectorType = $resolved.Type
            Write-Verbose "Connector: $connectorName ($connectorGuid, Type: $connectorType)"

            # Handle connector type-specific logic
            $configAttribute = switch ($connectorType) {
                'o365-admin' {
                    # Microsoft 365 connectors - fully supported
                    'ng_backup_config'
                }
                'dynamics365' {
                    # Dynamics 365 - not yet supported for Set operations
                    throw "Currently this cmdlet only supports Microsoft 365 connectors."
                }
                'azure-ad' {
                    # Entra ID - not yet supported for Set operations
                    throw "Currently this cmdlet only supports Microsoft 365 connectors."
                }
                'powerbi' {
                    # Power BI - not yet supported for Set operations
                    throw "Currently this cmdlet only supports Microsoft 365 connectors."
                }
                default {
                    # All other connector types are not supported
                    throw "Currently this cmdlet only supports Microsoft 365 connectors."
                }
            }
            Write-Verbose "Using config attribute: $configAttribute for connector type: $connectorType"

            # Validate -Workload parameter if specified (single value only for Set-)
            if ($Workload) {
                Test-WorkloadParameter -Workload @($Workload) -ConnectorType $connectorType
                # Resolve workload alias to canonical name for internal comparisons
                $Workload = Resolve-WorkloadAlias -Workload $Workload
                Write-Verbose "Using workload: $Workload"
            }

            # Check if site list parameters are specified
            $hasSiteListParams = $PSBoundParameters.ContainsKey('AddIncludedSites') -or
                                 $PSBoundParameters.ContainsKey('RemoveIncludedSites') -or
                                 $PSBoundParameters.ContainsKey('AddExcludedSites') -or
                                 $PSBoundParameters.ContainsKey('RemoveExcludedSites')

            # Validate site list parameters require SharePoint workload
            if ($hasSiteListParams) {
                if ($Workload -ne 'SharePoint') {
                    throw "You can only modify included and excluded site lists when setting a SharePoint configuration"
                }

                # Validate all URLs in site list parameters
                $allUrls = @()
                if ($AddIncludedSites) { $allUrls += $AddIncludedSites }
                if ($RemoveIncludedSites) { $allUrls += $RemoveIncludedSites }
                if ($AddExcludedSites) { $allUrls += $AddExcludedSites }
                if ($RemoveExcludedSites) { $allUrls += $RemoveExcludedSites }

                foreach ($url in $allUrls) {
                    Test-SiteUrl -Url $url
                }
            }

            # Check if group list parameters are specified (for Teams/UnifiedGroups)
            $hasGroupListParams = $PSBoundParameters.ContainsKey('AddIncludedGroups') -or
                                  $PSBoundParameters.ContainsKey('RemoveIncludedGroups') -or
                                  $PSBoundParameters.ContainsKey('AddExcludedGroups') -or
                                  $PSBoundParameters.ContainsKey('RemoveExcludedGroups')

            # Check if UserSelectionRules parameters are specified (for Exchange/OneDrive)
            $hasUserSelectionRulesParams = $PSBoundParameters.ContainsKey('AddIncludedUsers') -or
                                           $PSBoundParameters.ContainsKey('RemoveIncludedUsers') -or
                                           $PSBoundParameters.ContainsKey('AddExcludedUsers') -or
                                           $PSBoundParameters.ContainsKey('RemoveExcludedUsers') -or
                                           $PSBoundParameters.ContainsKey('AddIncludedCategories') -or
                                           $PSBoundParameters.ContainsKey('RemoveIncludedCategories')

            # Check if any Teams/UnifiedGroups modification parameters are specified
            $hasTeamsParams = $PSBoundParameters.ContainsKey('AutoIncludeGroups') -or $hasGroupListParams

            # Validate group list parameters - different behavior for Teams vs Exchange/OneDrive
            if ($hasGroupListParams) {
                # -AddExcludedGroups and -RemoveExcludedGroups are Teams-only (UnifiedGroups.ExcludeGroups)
                if ($PSBoundParameters.ContainsKey('AddExcludedGroups') -or $PSBoundParameters.ContainsKey('RemoveExcludedGroups')) {
                    if ($Workload -notin @('Teams', 'UnifiedGroups')) {
                        throw "The -AddExcludedGroups and -RemoveExcludedGroups parameters are only valid when -Workload is Teams or UnifiedGroups"
                    }
                }

                # -AddIncludedGroups and -RemoveIncludedGroups work for both Teams and Exchange/OneDrive
                if ($PSBoundParameters.ContainsKey('AddIncludedGroups') -or $PSBoundParameters.ContainsKey('RemoveIncludedGroups')) {
                    if ($Workload -notin @('Teams', 'UnifiedGroups', 'Exchange', 'OneDrive')) {
                        throw "The -AddIncludedGroups and -RemoveIncludedGroups parameters are only valid when -Workload is Teams, Exchange, or OneDrive"
                    }
                }

                # Validate all GUIDs in group list parameters
                $allGuids = @()
                if ($AddIncludedGroups) { $allGuids += $AddIncludedGroups }
                if ($RemoveIncludedGroups) { $allGuids += $RemoveIncludedGroups }
                if ($AddExcludedGroups) { $allGuids += $AddExcludedGroups }
                if ($RemoveExcludedGroups) { $allGuids += $RemoveExcludedGroups }

                foreach ($guid in $allGuids) {
                    Test-GroupGuid -Guid $guid
                }
            }

            # Validate UserSelectionRules parameters require Exchange or OneDrive workload
            if ($hasUserSelectionRulesParams) {
                if ($Workload -notin @('Exchange', 'OneDrive')) {
                    throw "The UserSelectionRules parameters (-AddIncludedUsers, -RemoveIncludedUsers, -AddExcludedUsers, -RemoveExcludedUsers, -AddIncludedCategories, -RemoveIncludedCategories) are only valid when -Workload is Exchange or OneDrive"
                }

                # Validate all user GUIDs
                $allUserGuids = @()
                if ($AddIncludedUsers) { $allUserGuids += $AddIncludedUsers }
                if ($RemoveIncludedUsers) { $allUserGuids += $RemoveIncludedUsers }
                if ($AddExcludedUsers) { $allUserGuids += $AddExcludedUsers }
                if ($RemoveExcludedUsers) { $allUserGuids += $RemoveExcludedUsers }

                foreach ($guid in $allUserGuids) {
                    Test-GroupGuid -Guid $guid  # User GUIDs have the same format as group GUIDs
                }
            }

            # Validate AutoIncludeGroups requires Teams or UnifiedGroups workload
            if ($PSBoundParameters.ContainsKey('AutoIncludeGroups')) {
                if ($Workload -notin @('Teams', 'UnifiedGroups')) {
                    throw "The -AutoIncludeGroups parameter is only valid when -Workload is Teams or UnifiedGroups"
                }
            }

            # Check if Exchange configuration parameters are specified
            $hasExchangeParams = $PSBoundParameters.ContainsKey('EnabledCategories')

            # Validate EnabledCategories requires Exchange workload
            if ($hasExchangeParams) {
                if ($Workload -ne 'Exchange') {
                    throw "The -EnabledCategories parameter is only valid when -Workload is Exchange"
                }

                # Validate category names have proper casing (first letter uppercase)
                foreach ($category in $EnabledCategories) {
                    if ($category.Length -gt 0 -and [char]::IsLower($category[0])) {
                        throw "Category names are case-sensitive; e.g. use 'Tasks', not 'tasks.'"
                    }
                }
            }

            # Check if AddIncludedGroups/RemoveIncludedGroups is being used for Exchange/OneDrive UserSelectionRules
            $hasExchangeGroupParams = ($Workload -in @('Exchange', 'OneDrive')) -and
                                      ($PSBoundParameters.ContainsKey('AddIncludedGroups') -or $PSBoundParameters.ContainsKey('RemoveIncludedGroups'))

            # Check if any modification parameters were specified
            $hasModificationParams = $PSBoundParameters.ContainsKey('AutoIncludeSites') -or
                                     $hasSiteListParams -or
                                     $hasTeamsParams -or
                                     $hasExchangeParams -or
                                     $hasUserSelectionRulesParams -or
                                     $hasExchangeGroupParams

            # Determine if we need to fetch current configuration
            # This is needed when using modification parameters (e.g., AutoIncludeSites, site list changes)
            # rather than providing a complete RawConfiguration
            $effectiveRawConfig = $RawConfiguration
            if (-not $RawConfiguration) {
                # No RawConfiguration provided - check if we have modification parameters
                if (-not $hasModificationParams) {
                    throw "No configuration changes specified. Provide -RawConfiguration or use modification parameters."
                }

                # Fetch current configuration for modification
                Write-Verbose "No RawConfiguration provided - fetching current configuration for modification"

                $getParams = @{
                    Connector = $connectorGuid
                }

                try {
                    $currentConfig = Get-KeepitConnectorConfiguration @getParams
                    $effectiveRawConfig = $currentConfig.RawConfiguration

                    if (-not $effectiveRawConfig) {
                        throw "Failed to retrieve current configuration - no configuration data returned"
                    }

                    Write-Verbose "Retrieved current configuration: $($effectiveRawConfig.Length) characters"
                }
                catch {
                    throw "Failed to retrieve current configuration for connector '$connectorGuid': $($_.Exception.Message)"
                }
            }

            # Apply modification parameters if specified
            if ($hasModificationParams) {
                Write-Verbose "Applying modification parameters to configuration"

                # Save original config for comparison
                $originalRawConfig = $effectiveRawConfig

                # Parse configuration as JSON
                try {
                    $configObj = $effectiveRawConfig | ConvertFrom-Json -AsHashtable
                }
                catch {
                    throw "Failed to parse configuration as JSON: $($_.Exception.Message)"
                }

                # Check for INFO message when site list params used with AutoIncludeAllSiteCollections
                if ($hasSiteListParams) {
                    $spConfig = $configObj['SharePointNG']
                    if ($spConfig -and $spConfig['AutoIncludeAllSiteCollections'] -eq $true) {
                        Write-Information "INFO: this configuration has AutoIncludeAllSiteCollections set; this may have unexpected results when manually including or excluding sites." -InformationAction Continue
                    }
                }

                # Apply AutoIncludeSites modification
                if ($PSBoundParameters.ContainsKey('AutoIncludeSites')) {
                    Write-Verbose "Processing AutoIncludeSites parameter: $AutoIncludeSites"

                    # Ensure SharePointNG section exists
                    if (-not $configObj.ContainsKey('SharePointNG')) {
                        $configObj['SharePointNG'] = @{}
                    }

                    $spConfig = $configObj['SharePointNG']

                    # Always set the value explicitly to match the parameter
                    Write-Verbose "Setting AutoIncludeAllSiteCollections = $AutoIncludeSites"
                    $spConfig['AutoIncludeAllSiteCollections'] = $AutoIncludeSites
                }

                # Apply AddIncludedSites modification
                if ($PSBoundParameters.ContainsKey('AddIncludedSites') -and $AddIncludedSites.Count -gt 0) {
                    Write-Verbose "Processing AddIncludedSites parameter: $($AddIncludedSites.Count) sites"

                    # Ensure SharePointNG section exists
                    if (-not $configObj.ContainsKey('SharePointNG')) {
                        $configObj['SharePointNG'] = @{}
                    }

                    $spConfig = $configObj['SharePointNG']

                    # Get existing SiteCollections array or create new one
                    if (-not $spConfig.ContainsKey('SiteCollections')) {
                        $spConfig['SiteCollections'] = @()
                    }

                    $existingSites = [System.Collections.ArrayList]@($spConfig['SiteCollections'])

                    foreach ($siteUrl in $AddIncludedSites) {
                        $normalizedUrl = $siteUrl.Trim().TrimEnd('/').ToLowerInvariant()
                        $alreadyExists = $existingSites | Where-Object {
                            $_.SiteUrl.Trim().TrimEnd('/').ToLowerInvariant() -eq $normalizedUrl
                        }
                        if (-not $alreadyExists) {
                            $newSite = @{
                                SiteUrl = $siteUrl.Trim().TrimEnd('/')
                                AutoIncludeAllSubSites = $true
                            }
                            $null = $existingSites.Add($newSite)
                            Write-Verbose "Added site: $siteUrl"
                        }
                        else {
                            Write-Warning "Site already included, skipping: $siteUrl"
                        }
                    }

                    $spConfig['SiteCollections'] = @($existingSites)
                }

                # Apply RemoveIncludedSites modification
                if ($PSBoundParameters.ContainsKey('RemoveIncludedSites') -and $RemoveIncludedSites.Count -gt 0) {
                    Write-Verbose "Processing RemoveIncludedSites parameter: $($RemoveIncludedSites.Count) sites"

                    $spConfig = $configObj['SharePointNG']
                    if ($spConfig -and $spConfig.ContainsKey('SiteCollections')) {
                        $existingSites = [System.Collections.ArrayList]@($spConfig['SiteCollections'])

                        foreach ($siteUrl in $RemoveIncludedSites) {
                            $normalizedUrl = $siteUrl.Trim().TrimEnd('/').ToLowerInvariant()
                            $exists = $existingSites | Where-Object {
                                $_.SiteUrl.Trim().TrimEnd('/').ToLowerInvariant() -eq $normalizedUrl
                            }
                            if (-not $exists) {
                                Write-Warning "Site not found in included sites, skipping: $siteUrl"
                            }
                        }

                        $urlsToRemove = $RemoveIncludedSites | ForEach-Object { $_.Trim().TrimEnd('/').ToLowerInvariant() }
                        $remainingSites = $existingSites | Where-Object {
                            $_.SiteUrl.Trim().TrimEnd('/').ToLowerInvariant() -notin $urlsToRemove
                        }

                        $spConfig['SiteCollections'] = @($remainingSites)
                        Write-Verbose "Removed sites, remaining: $(@($remainingSites).Count)"
                    }
                    else {
                        foreach ($siteUrl in $RemoveIncludedSites) {
                            Write-Warning "Site not found in included sites, skipping: $siteUrl"
                        }
                    }
                }

                # Apply AddExcludedSites modification
                if ($PSBoundParameters.ContainsKey('AddExcludedSites') -and $AddExcludedSites.Count -gt 0) {
                    Write-Verbose "Processing AddExcludedSites parameter: $($AddExcludedSites.Count) sites"

                    # Ensure SharePointNG section exists
                    if (-not $configObj.ContainsKey('SharePointNG')) {
                        $configObj['SharePointNG'] = @{}
                    }

                    $spConfig = $configObj['SharePointNG']

                    # Get existing ExcludedSiteCollections array or create new one
                    if (-not $spConfig.ContainsKey('ExcludedSiteCollections')) {
                        $spConfig['ExcludedSiteCollections'] = @()
                    }

                    $existingSites = [System.Collections.ArrayList]@($spConfig['ExcludedSiteCollections'])

                    foreach ($siteUrl in $AddExcludedSites) {
                        $normalizedUrl = $siteUrl.Trim().TrimEnd('/').ToLowerInvariant()
                        $alreadyExists = $existingSites | Where-Object {
                            $_.Trim().TrimEnd('/').ToLowerInvariant() -eq $normalizedUrl
                        }
                        if (-not $alreadyExists) {
                            $null = $existingSites.Add($siteUrl.Trim().TrimEnd('/'))
                            Write-Verbose "Added excluded site: $siteUrl"
                        }
                        else {
                            Write-Warning "Site already excluded, skipping: $siteUrl"
                        }
                    }

                    $spConfig['ExcludedSiteCollections'] = @($existingSites)
                }

                # Apply RemoveExcludedSites modification
                if ($PSBoundParameters.ContainsKey('RemoveExcludedSites') -and $RemoveExcludedSites.Count -gt 0) {
                    Write-Verbose "Processing RemoveExcludedSites parameter: $($RemoveExcludedSites.Count) sites"

                    $spConfig = $configObj['SharePointNG']
                    if ($spConfig -and $spConfig.ContainsKey('ExcludedSiteCollections')) {
                        $existingSites = [System.Collections.ArrayList]@($spConfig['ExcludedSiteCollections'])

                        foreach ($siteUrl in $RemoveExcludedSites) {
                            $normalizedUrl = $siteUrl.Trim().TrimEnd('/').ToLowerInvariant()
                            $exists = $existingSites | Where-Object {
                                $_.Trim().TrimEnd('/').ToLowerInvariant() -eq $normalizedUrl
                            }
                            if (-not $exists) {
                                Write-Warning "Site not found in excluded sites, skipping: $siteUrl"
                            }
                        }

                        $urlsToRemove = $RemoveExcludedSites | ForEach-Object { $_.Trim().TrimEnd('/').ToLowerInvariant() }
                        $remainingSites = $existingSites | Where-Object {
                            $_.Trim().TrimEnd('/').ToLowerInvariant() -notin $urlsToRemove
                        }

                        $spConfig['ExcludedSiteCollections'] = @($remainingSites)
                        Write-Verbose "Removed excluded sites, remaining: $(@($remainingSites).Count)"
                    }
                    else {
                        foreach ($siteUrl in $RemoveExcludedSites) {
                            Write-Warning "Site not found in excluded sites, skipping: $siteUrl"
                        }
                    }
                }

                # Check for INFO message when group list params used with AutoIncludeGroups
                if ($hasGroupListParams) {
                    $ugConfig = $configObj['UnifiedGroups']
                    if ($ugConfig -and $ugConfig['AutoIncludeGroups'] -eq $true) {
                        Write-Information "INFO: this configuration has AutoIncludeGroups set to true; manually including groups may have unexpected results." -InformationAction Continue
                    }
                }

                # Apply AutoIncludeGroups modification
                if ($PSBoundParameters.ContainsKey('AutoIncludeGroups')) {
                    Write-Verbose "Processing AutoIncludeGroups parameter: $AutoIncludeGroups"

                    # Ensure UnifiedGroups section exists
                    if (-not $configObj.ContainsKey('UnifiedGroups')) {
                        $configObj['UnifiedGroups'] = @{}
                    }

                    $ugConfig = $configObj['UnifiedGroups']
                    $ugConfig['AutoIncludeGroups'] = $AutoIncludeGroups
                    Write-Verbose "Set AutoIncludeGroups = $AutoIncludeGroups"
                }

                # Apply AddIncludedGroups modification
                if ($PSBoundParameters.ContainsKey('AddIncludedGroups') -and $AddIncludedGroups.Count -gt 0) {
                    Write-Verbose "Processing AddIncludedGroups parameter: $($AddIncludedGroups.Count) groups"

                    # Ensure UnifiedGroups section exists
                    if (-not $configObj.ContainsKey('UnifiedGroups')) {
                        $configObj['UnifiedGroups'] = @{}
                    }

                    $ugConfig = $configObj['UnifiedGroups']

                    # Get existing IncludeGroups array or create new one
                    if (-not $ugConfig.ContainsKey('IncludeGroups')) {
                        $ugConfig['IncludeGroups'] = @()
                    }

                    $existingGroups = [System.Collections.ArrayList]@($ugConfig['IncludeGroups'])

                    foreach ($groupGuid in $AddIncludedGroups) {
                        $normalizedGuid = $groupGuid.ToLowerInvariant()
                        $alreadyExists = $existingGroups | Where-Object { $_.ToLowerInvariant() -eq $normalizedGuid }
                        if (-not $alreadyExists) {
                            $null = $existingGroups.Add($groupGuid)
                            Write-Verbose "Added group: $groupGuid"
                        }
                        else {
                            Write-Warning "Group already included, skipping: $groupGuid"
                        }
                    }

                    $ugConfig['IncludeGroups'] = @($existingGroups)
                }

                # Apply RemoveIncludedGroups modification
                if ($PSBoundParameters.ContainsKey('RemoveIncludedGroups') -and $RemoveIncludedGroups.Count -gt 0) {
                    Write-Verbose "Processing RemoveIncludedGroups parameter: $($RemoveIncludedGroups.Count) groups"

                    $ugConfig = $configObj['UnifiedGroups']
                    if ($ugConfig -and $ugConfig.ContainsKey('IncludeGroups')) {
                        $existingGroups = [System.Collections.ArrayList]@($ugConfig['IncludeGroups'])

                        foreach ($groupGuid in $RemoveIncludedGroups) {
                            $normalizedGuid = $groupGuid.ToLowerInvariant()
                            $exists = $existingGroups | Where-Object { $_.ToLowerInvariant() -eq $normalizedGuid }
                            if (-not $exists) {
                                Write-Warning "Group not found in included groups, skipping: $groupGuid"
                            }
                        }

                        $guidsToRemove = $RemoveIncludedGroups | ForEach-Object { $_.ToLowerInvariant() }
                        $remainingGroups = $existingGroups | Where-Object {
                            $_.ToLowerInvariant() -notin $guidsToRemove
                        }

                        $ugConfig['IncludeGroups'] = @($remainingGroups)
                        Write-Verbose "Removed groups, remaining: $($remainingGroups.Count)"
                    }
                    else {
                        foreach ($groupGuid in $RemoveIncludedGroups) {
                            Write-Warning "Group not found in included groups, skipping: $groupGuid"
                        }
                    }
                }

                # Apply AddExcludedGroups modification
                if ($PSBoundParameters.ContainsKey('AddExcludedGroups') -and $AddExcludedGroups.Count -gt 0) {
                    Write-Verbose "Processing AddExcludedGroups parameter: $($AddExcludedGroups.Count) groups"

                    # Ensure UnifiedGroups section exists
                    if (-not $configObj.ContainsKey('UnifiedGroups')) {
                        $configObj['UnifiedGroups'] = @{}
                    }

                    $ugConfig = $configObj['UnifiedGroups']

                    # Get existing ExcludeGroups array or create new one
                    if (-not $ugConfig.ContainsKey('ExcludeGroups')) {
                        $ugConfig['ExcludeGroups'] = @()
                    }

                    $existingGroups = [System.Collections.ArrayList]@($ugConfig['ExcludeGroups'])

                    foreach ($groupGuid in $AddExcludedGroups) {
                        $normalizedGuid = $groupGuid.ToLowerInvariant()
                        $alreadyExists = $existingGroups | Where-Object { $_.ToLowerInvariant() -eq $normalizedGuid }
                        if (-not $alreadyExists) {
                            $null = $existingGroups.Add($groupGuid)
                            Write-Verbose "Added excluded group: $groupGuid"
                        }
                        else {
                            Write-Warning "Group already excluded, skipping: $groupGuid"
                        }
                    }

                    $ugConfig['ExcludeGroups'] = @($existingGroups)
                }

                # Apply RemoveExcludedGroups modification
                if ($PSBoundParameters.ContainsKey('RemoveExcludedGroups') -and $RemoveExcludedGroups.Count -gt 0) {
                    Write-Verbose "Processing RemoveExcludedGroups parameter: $($RemoveExcludedGroups.Count) groups"

                    $ugConfig = $configObj['UnifiedGroups']
                    if ($ugConfig -and $ugConfig.ContainsKey('ExcludeGroups')) {
                        $existingGroups = [System.Collections.ArrayList]@($ugConfig['ExcludeGroups'])

                        foreach ($groupGuid in $RemoveExcludedGroups) {
                            $normalizedGuid = $groupGuid.ToLowerInvariant()
                            $exists = $existingGroups | Where-Object { $_.ToLowerInvariant() -eq $normalizedGuid }
                            if (-not $exists) {
                                Write-Warning "Group not found in excluded groups, skipping: $groupGuid"
                            }
                        }

                        $guidsToRemove = $RemoveExcludedGroups | ForEach-Object { $_.ToLowerInvariant() }
                        $remainingGroups = $existingGroups | Where-Object {
                            $_.ToLowerInvariant() -notin $guidsToRemove
                        }

                        $ugConfig['ExcludeGroups'] = @($remainingGroups)
                        Write-Verbose "Removed excluded groups, remaining: $($remainingGroups.Count)"
                    }
                    else {
                        foreach ($groupGuid in $RemoveExcludedGroups) {
                            Write-Warning "Group not found in excluded groups, skipping: $groupGuid"
                        }
                    }
                }

                # Apply EnabledCategories modification for Exchange workload
                if ($PSBoundParameters.ContainsKey('EnabledCategories') -and $EnabledCategories.Count -gt 0) {
                    Write-Verbose "Processing EnabledCategories parameter: $($EnabledCategories -join ', ')"

                    # Ensure Exchange section exists
                    if (-not $configObj.ContainsKey('Exchange')) {
                        $configObj['Exchange'] = @{}
                    }

                    $exConfig = $configObj['Exchange']

                    # Get existing EnabledCategories or empty array
                    $existingCategories = @()
                    if ($exConfig.ContainsKey('EnabledCategories')) {
                        $existingCategories = @($exConfig['EnabledCategories'])
                    }

                    # Compare sets (case-insensitive, order-independent)
                    $existingSet = [System.Collections.Generic.HashSet[string]]::new(
                        [System.StringComparer]::OrdinalIgnoreCase
                    )
                    foreach ($cat in $existingCategories) { $null = $existingSet.Add($cat) }

                    $newSet = [System.Collections.Generic.HashSet[string]]::new(
                        [System.StringComparer]::OrdinalIgnoreCase
                    )
                    foreach ($cat in $EnabledCategories) { $null = $newSet.Add($cat) }

                    if ($existingSet.SetEquals($newSet)) {
                        Write-Warning "EnabledCategories already matches the specified values. No change needed."
                    }
                    else {
                        # Update EnabledCategories with the new values
                        $exConfig['EnabledCategories'] = @($EnabledCategories)
                        Write-Verbose "Updated EnabledCategories from [$($existingCategories -join ', ')] to [$($EnabledCategories -join ', ')]"
                    }
                }

                # Apply UserSelectionRules modifications for Exchange/OneDrive workloads
                if ($Workload -in @('Exchange', 'OneDrive') -and ($hasUserSelectionRulesParams -or $hasExchangeGroupParams)) {
                    Write-Verbose "Processing UserSelectionRules modifications for $Workload workload"

                    # Ensure UserSelectionRules section exists
                    if (-not $configObj.ContainsKey('UserSelectionRules')) {
                        $configObj['UserSelectionRules'] = @{}
                    }

                    $usrConfig = $configObj['UserSelectionRules']

                    # Apply AddIncludedUsers modification
                    if ($PSBoundParameters.ContainsKey('AddIncludedUsers') -and $AddIncludedUsers.Count -gt 0) {
                        Write-Verbose "Processing AddIncludedUsers parameter: $($AddIncludedUsers.Count) users"

                        if (-not $usrConfig.ContainsKey('IncludeUsers')) {
                            $usrConfig['IncludeUsers'] = @()
                        }

                        $existingUsers = [System.Collections.ArrayList]@($usrConfig['IncludeUsers'])

                        foreach ($userGuid in $AddIncludedUsers) {
                            $normalizedGuid = $userGuid.ToLowerInvariant()
                            $alreadyExists = $existingUsers | Where-Object { $_.ToLowerInvariant() -eq $normalizedGuid }
                            if (-not $alreadyExists) {
                                $null = $existingUsers.Add($userGuid)
                                Write-Verbose "Added included user: $userGuid"
                            }
                            else {
                                Write-Warning "User already included, skipping: $userGuid"
                            }
                        }

                        $usrConfig['IncludeUsers'] = @($existingUsers)
                    }

                    # Apply RemoveIncludedUsers modification
                    if ($PSBoundParameters.ContainsKey('RemoveIncludedUsers') -and $RemoveIncludedUsers.Count -gt 0) {
                        Write-Verbose "Processing RemoveIncludedUsers parameter: $($RemoveIncludedUsers.Count) users"

                        if ($usrConfig.ContainsKey('IncludeUsers')) {
                            $existingUsers = [System.Collections.ArrayList]@($usrConfig['IncludeUsers'])

                            foreach ($userGuid in $RemoveIncludedUsers) {
                                $normalizedGuid = $userGuid.ToLowerInvariant()
                                $exists = $existingUsers | Where-Object { $_.ToLowerInvariant() -eq $normalizedGuid }
                                if (-not $exists) {
                                    Write-Warning "User not found in included users, skipping: $userGuid"
                                }
                            }

                            $guidsToRemove = $RemoveIncludedUsers | ForEach-Object { $_.ToLowerInvariant() }
                            $remainingUsers = $existingUsers | Where-Object {
                                $_.ToLowerInvariant() -notin $guidsToRemove
                            }

                            $usrConfig['IncludeUsers'] = @($remainingUsers)
                            Write-Verbose "Removed included users, remaining: $(@($remainingUsers).Count)"
                        }
                        else {
                            foreach ($userGuid in $RemoveIncludedUsers) {
                                Write-Warning "User not found in included users, skipping: $userGuid"
                            }
                        }
                    }

                    # Apply AddExcludedUsers modification
                    if ($PSBoundParameters.ContainsKey('AddExcludedUsers') -and $AddExcludedUsers.Count -gt 0) {
                        Write-Verbose "Processing AddExcludedUsers parameter: $($AddExcludedUsers.Count) users"

                        if (-not $usrConfig.ContainsKey('ExcludeUsers')) {
                            $usrConfig['ExcludeUsers'] = @()
                        }

                        $existingUsers = [System.Collections.ArrayList]@($usrConfig['ExcludeUsers'])

                        foreach ($userGuid in $AddExcludedUsers) {
                            $normalizedGuid = $userGuid.ToLowerInvariant()
                            $alreadyExists = $existingUsers | Where-Object { $_.ToLowerInvariant() -eq $normalizedGuid }
                            if (-not $alreadyExists) {
                                $null = $existingUsers.Add($userGuid)
                                Write-Verbose "Added excluded user: $userGuid"
                            }
                            else {
                                Write-Warning "User already excluded, skipping: $userGuid"
                            }
                        }

                        $usrConfig['ExcludeUsers'] = @($existingUsers)
                    }

                    # Apply RemoveExcludedUsers modification
                    if ($PSBoundParameters.ContainsKey('RemoveExcludedUsers') -and $RemoveExcludedUsers.Count -gt 0) {
                        Write-Verbose "Processing RemoveExcludedUsers parameter: $($RemoveExcludedUsers.Count) users"

                        if ($usrConfig.ContainsKey('ExcludeUsers')) {
                            $existingUsers = [System.Collections.ArrayList]@($usrConfig['ExcludeUsers'])

                            foreach ($userGuid in $RemoveExcludedUsers) {
                                $normalizedGuid = $userGuid.ToLowerInvariant()
                                $exists = $existingUsers | Where-Object { $_.ToLowerInvariant() -eq $normalizedGuid }
                                if (-not $exists) {
                                    Write-Warning "User not found in excluded users, skipping: $userGuid"
                                }
                            }

                            $guidsToRemove = $RemoveExcludedUsers | ForEach-Object { $_.ToLowerInvariant() }
                            $remainingUsers = $existingUsers | Where-Object {
                                $_.ToLowerInvariant() -notin $guidsToRemove
                            }

                            $usrConfig['ExcludeUsers'] = @($remainingUsers)
                            Write-Verbose "Removed excluded users, remaining: $(@($remainingUsers).Count)"
                        }
                        else {
                            foreach ($userGuid in $RemoveExcludedUsers) {
                                Write-Warning "User not found in excluded users, skipping: $userGuid"
                            }
                        }
                    }

                    # Apply AddIncludedCategories modification
                    if ($PSBoundParameters.ContainsKey('AddIncludedCategories') -and $AddIncludedCategories.Count -gt 0) {
                        Write-Verbose "Processing AddIncludedCategories parameter: $($AddIncludedCategories -join ', ')"

                        if (-not $usrConfig.ContainsKey('IncludeCategories')) {
                            $usrConfig['IncludeCategories'] = @()
                        }

                        $existingCategories = [System.Collections.ArrayList]@($usrConfig['IncludeCategories'])

                        foreach ($category in $AddIncludedCategories) {
                            $alreadyExists = $existingCategories | Where-Object { $_ -eq $category }
                            if (-not $alreadyExists) {
                                $null = $existingCategories.Add($category)
                                Write-Verbose "Added included category: $category"
                            }
                            else {
                                Write-Warning "Category already included, skipping: $category"
                            }
                        }

                        $usrConfig['IncludeCategories'] = @($existingCategories)
                    }

                    # Apply RemoveIncludedCategories modification
                    if ($PSBoundParameters.ContainsKey('RemoveIncludedCategories') -and $RemoveIncludedCategories.Count -gt 0) {
                        Write-Verbose "Processing RemoveIncludedCategories parameter: $($RemoveIncludedCategories -join ', ')"

                        if ($usrConfig.ContainsKey('IncludeCategories')) {
                            $existingCategories = [System.Collections.ArrayList]@($usrConfig['IncludeCategories'])

                            foreach ($category in $RemoveIncludedCategories) {
                                $exists = $existingCategories | Where-Object { $_ -eq $category }
                                if (-not $exists) {
                                    Write-Warning "Category not found in included categories, skipping: $category"
                                }
                            }

                            $remainingCategories = $existingCategories | Where-Object { $_ -notin $RemoveIncludedCategories }

                            $usrConfig['IncludeCategories'] = @($remainingCategories)
                            Write-Verbose "Removed included categories, remaining: $(@($remainingCategories).Count)"
                        }
                        else {
                            foreach ($category in $RemoveIncludedCategories) {
                                Write-Warning "Category not found in included categories, skipping: $category"
                            }
                        }
                    }

                    # Apply AddIncludedGroups modification for UserSelectionRules (Exchange/OneDrive)
                    if ($PSBoundParameters.ContainsKey('AddIncludedGroups') -and $AddIncludedGroups.Count -gt 0) {
                        Write-Verbose "Processing AddIncludedGroups parameter for UserSelectionRules: $($AddIncludedGroups.Count) groups"

                        if (-not $usrConfig.ContainsKey('IncludeGroups')) {
                            $usrConfig['IncludeGroups'] = @()
                        }

                        $existingGroups = [System.Collections.ArrayList]@($usrConfig['IncludeGroups'])

                        foreach ($groupGuid in $AddIncludedGroups) {
                            $normalizedGuid = $groupGuid.ToLowerInvariant()
                            $alreadyExists = $existingGroups | Where-Object { $_.ToLowerInvariant() -eq $normalizedGuid }
                            if (-not $alreadyExists) {
                                $null = $existingGroups.Add($groupGuid)
                                Write-Verbose "Added included group to UserSelectionRules: $groupGuid"
                            }
                            else {
                                Write-Warning "Group already included in UserSelectionRules, skipping: $groupGuid"
                            }
                        }

                        $usrConfig['IncludeGroups'] = @($existingGroups)
                    }

                    # Apply RemoveIncludedGroups modification for UserSelectionRules (Exchange/OneDrive)
                    if ($PSBoundParameters.ContainsKey('RemoveIncludedGroups') -and $RemoveIncludedGroups.Count -gt 0) {
                        Write-Verbose "Processing RemoveIncludedGroups parameter for UserSelectionRules: $($RemoveIncludedGroups.Count) groups"

                        if ($usrConfig.ContainsKey('IncludeGroups')) {
                            $existingGroups = [System.Collections.ArrayList]@($usrConfig['IncludeGroups'])

                            foreach ($groupGuid in $RemoveIncludedGroups) {
                                $normalizedGuid = $groupGuid.ToLowerInvariant()
                                $exists = $existingGroups | Where-Object { $_.ToLowerInvariant() -eq $normalizedGuid }
                                if (-not $exists) {
                                    Write-Warning "Group not found in UserSelectionRules included groups, skipping: $groupGuid"
                                }
                            }

                            $guidsToRemove = $RemoveIncludedGroups | ForEach-Object { $_.ToLowerInvariant() }
                            $remainingGroups = $existingGroups | Where-Object {
                                $_.ToLowerInvariant() -notin $guidsToRemove
                            }

                            $usrConfig['IncludeGroups'] = @($remainingGroups)
                            Write-Verbose "Removed groups from UserSelectionRules, remaining: $(@($remainingGroups).Count)"
                        }
                        else {
                            foreach ($groupGuid in $RemoveIncludedGroups) {
                                Write-Warning "Group not found in UserSelectionRules included groups, skipping: $groupGuid"
                            }
                        }
                    }
                }

                # Convert back to JSON
                $effectiveRawConfig = $configObj | ConvertTo-Json -Depth 10 -Compress
                Write-Verbose "Modified configuration: $($effectiveRawConfig.Length) characters"

                # Check if configuration actually changed
                if ($effectiveRawConfig -eq $originalRawConfig) {
                    Write-Host "No configuration changes requested; original configuration will remain untouched." -ForegroundColor Yellow
                    return
                }
            }

            # Build request URI
            $uri = "$baseUrl/users/$userId/devices/$connectorGuid/attributes/$configAttribute"
            Write-Verbose "PUT URI: $uri"

            # Prepare headers
            $headers = @{
                'Authorization' = $authHeader
                'Content-Type'  = 'application/octet-stream'
            }

            # Convert JSON string to bytes for the request body
            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($effectiveRawConfig)
            Write-Verbose "Request body size: $($bodyBytes.Length) bytes"
            Write-Verbose "Configuration preview: $($effectiveRawConfig.Substring(0, [Math]::Min(200, $effectiveRawConfig.Length)))..."

            # ShouldProcess check
            $displayName = Get-ConnectorTypeDisplayName -ConnectorType $connectorType

            # For SharePoint workload with -WhatIf, show the raw configuration that would be written
            if ($WhatIfPreference -and $Workload -eq 'SharePoint') {
                Write-Host "`nSharePoint configuration that would be written:" -ForegroundColor Cyan
                Write-Host $effectiveRawConfig -ForegroundColor Yellow
                Write-Host ""
            }

            # For Teams/UnifiedGroups workload with -WhatIf, show the raw configuration that would be written
            if ($WhatIfPreference -and $Workload -in @('Teams', 'UnifiedGroups')) {
                Write-Host "`nTeams configuration that would be written:" -ForegroundColor Cyan
                Write-Host $effectiveRawConfig -ForegroundColor Yellow
                Write-Host ""
            }

            # For Exchange workload with -WhatIf, show the raw configuration that would be written
            if ($WhatIfPreference -and $Workload -eq 'Exchange') {
                Write-Host "`nExchange configuration that would be written:" -ForegroundColor Cyan
                Write-Host $effectiveRawConfig -ForegroundColor Yellow
                Write-Host ""
            }

            # For OneDrive workload with -WhatIf, show the raw configuration that would be written
            if ($WhatIfPreference -and $Workload -eq 'OneDrive') {
                Write-Host "`nOneDrive configuration that would be written:" -ForegroundColor Cyan
                Write-Host $effectiveRawConfig -ForegroundColor Yellow
                Write-Host ""
            }

            if ($PSCmdlet.ShouldProcess("$connectorName ($connectorGuid)", "Set $displayName configuration")) {
                Write-Verbose "Making PUT request to set configuration..."

                try {
                    $response = Invoke-WebRequest -Uri $uri -Method Put -Headers $headers -Body $bodyBytes -ErrorAction Stop
                    Write-Verbose "Response status: $($response.StatusCode) $($response.StatusDescription)"

                    # Return success object
                    [PSCustomObject]@{
                        ConnectorGuid    = $connectorGuid
                        Name             = $connectorName
                        Type             = $connectorType
                        TypeDisplayName  = $displayName
                        Status           = 'Success'
                        RawConfiguration = $effectiveRawConfig
                    }
                }
                catch {
                    $errorMessage = $_.Exception.Message
                    if ($_.ErrorDetails.Message) {
                        $errorMessage = $_.ErrorDetails.Message
                    }
                    Write-Verbose "API Error: $errorMessage"
                    Write-Verbose "Response: $($_.Exception.Response)"

                    # Return error object
                    [PSCustomObject]@{
                        ConnectorGuid   = $connectorGuid
                        Name            = $connectorName
                        Type            = $connectorType
                        TypeDisplayName = $displayName
                        Status          = "Error: $errorMessage"
                    }
                }
            }
        }
        catch {
            $errorGuid = if ($connectorGuid) { $connectorGuid } else { $Connector }
            throw "Failed to set configuration for connector '$errorGuid': $($_.Exception.Message)"
        }
    }
}

<#
.SYNOPSIS
    Enables a Keepit connector by clearing the disable_backup attribute
.DESCRIPTION
    Enables a Keepit connector by removing the disable_backup attribute, allowing backup
    jobs to run on the connector. If the connector is already enabled (no disable_backup
    attribute), the cmdlet succeeds without making changes.

    Supports pipeline input from Get-KeepitConnector for bulk operations.
.PARAMETER Connector
    The connector name or GUID. Can be piped from Get-KeepitConnector.
    Aliases: ConnectorGuid, Name
.EXAMPLE
    Enable-KeepitConnector -Connector "abc123-def456"

    Enables the connector with the specified GUID.
.EXAMPLE
    Enable-KeepitConnector -Connector "Production M365"

    Enables the connector by name.
.EXAMPLE
    Get-KeepitConnector | Where-Object { $_.Name -like "*Test*" } | Enable-KeepitConnector

    Enables all connectors matching the name pattern.
.OUTPUTS
    PSCustomObject with properties:
        - ConnectorGuid: The connector GUID (lowercase)
        - Name: The connector name
        - Enabled: Boolean indicating the connector is now enabled ($true)
        - Status: "Success" or error message
.NOTES
    Requires an active connection via Connect-KeepitService.
    Enabling an already-enabled connector is a no-op and returns success.

    API endpoint used:
    - DELETE /users/{userId}/devices/{connectorGUID}/attributes/disable_backup
#>
function Enable-KeepitConnector {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector
    )

    begin {
        Write-Verbose "Enable-KeepitConnector: Initializing"

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
            $connectorName = $resolved.Name
            Write-Verbose "Connector: $connectorName ($connectorGuid)"

            # Check if disable_backup attribute exists
            $attrUri = "$baseUrl/users/$userId/devices/$connectorGuid/attributes/disable_backup"
            $headers = @{
                'Authorization' = $authHeader
            }

            $attributeExists = $false
            try {
                $response = Invoke-WebRequest -Uri $attrUri -Method Get -Headers $headers -ErrorAction Stop
                $attributeExists = $true
                Write-Verbose "disable_backup attribute exists, will delete it"
            }
            catch {
                # Attribute doesn't exist - connector is already enabled
                Write-Verbose "disable_backup attribute not found - connector is already enabled"
            }

            # Delete the attribute if it exists
            if ($attributeExists) {
                Write-Verbose "Deleting disable_backup attribute"
                try {
                    Invoke-RestMethod -Uri $attrUri -Method Delete -Headers $headers -ErrorAction Stop
                    Write-Verbose "Successfully deleted disable_backup attribute"
                }
                catch {
                    throw "Failed to delete disable_backup attribute: $($_.Exception.Message)"
                }
            }

            # Return result object
            [PSCustomObject]@{
                ConnectorGuid = $connectorGuid
                Name          = $connectorName
                Enabled       = $true
                Status        = 'Success'
            }
        }
        catch {
            Write-Error "Failed to enable connector '$Connector': $($_.Exception.Message)"

            [PSCustomObject]@{
                ConnectorGuid = $connectorGuid
                Name          = $connectorName
                Enabled       = $null
                Status        = $_.Exception.Message
            }
        }
    }
}

<#
.SYNOPSIS
    Disables a Keepit connector by setting the disable_backup attribute
.DESCRIPTION
    Disables a Keepit connector by setting the disable_backup attribute to TRUE,
    preventing backup jobs from running on the connector. If the connector is already
    disabled (disable_backup attribute exists), the cmdlet succeeds without making changes.

    Supports pipeline input from Get-KeepitConnector for bulk operations.
.PARAMETER Connector
    The connector name or GUID. Can be piped from Get-KeepitConnector.
    Aliases: ConnectorGuid, Name
.EXAMPLE
    Disable-KeepitConnector -Connector "abc123-def456"

    Disables the connector with the specified GUID.
.EXAMPLE
    Disable-KeepitConnector -Connector "Test Connector"

    Disables the connector by name.
.EXAMPLE
    Get-KeepitConnector | Where-Object { $_.Name -like "*Test*" } | Disable-KeepitConnector

    Disables all connectors matching the name pattern.
.OUTPUTS
    PSCustomObject with properties:
        - ConnectorGuid: The connector GUID (lowercase)
        - Name: The connector name
        - Enabled: Boolean indicating the connector is now disabled ($false)
        - Status: "Success" or error message
.NOTES
    Requires an active connection via Connect-KeepitService.
    Disabling an already-disabled connector is a no-op and returns success.
    Active backup jobs may continue running but will not be rescheduled.

    API endpoint used:
    - PUT /users/{userId}/devices/{connectorGUID}/attributes/disable_backup
#>
function Disable-KeepitConnector {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector
    )

    begin {
        Write-Verbose "Disable-KeepitConnector: Initializing"

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
            $connectorName = $resolved.Name
            Write-Verbose "Connector: $connectorName ($connectorGuid)"

            # Check if disable_backup attribute exists
            $attrUri = "$baseUrl/users/$userId/devices/$connectorGuid/attributes/disable_backup"
            $headers = @{
                'Authorization' = $authHeader
            }

            $attributeExists = $false
            try {
                $response = Invoke-WebRequest -Uri $attrUri -Method Get -Headers $headers -ErrorAction Stop
                $attributeExists = $true
                Write-Verbose "disable_backup attribute already exists - connector is already disabled"
            }
            catch {
                # Attribute doesn't exist - need to create it
                Write-Verbose "disable_backup attribute not found - will create it"
            }

            # Set the attribute if it doesn't exist
            if (-not $attributeExists) {
                Write-Verbose "Setting disable_backup attribute to 1"
                $putHeaders = @{
                    'Authorization' = $authHeader
                    'Content-Type'  = 'application/octet-stream'
                }

                try {
                    $body = [System.Text.Encoding]::UTF8.GetBytes("1")
                    Invoke-RestMethod -Uri $attrUri -Method Put -Headers $putHeaders -Body $body -ErrorAction Stop
                    Write-Verbose "Successfully set disable_backup attribute"
                }
                catch {
                    throw "Failed to set disable_backup attribute: $($_.Exception.Message)"
                }
            }

            # Return result object
            [PSCustomObject]@{
                ConnectorGuid = $connectorGuid
                Name          = $connectorName
                Enabled       = $false
                Status        = 'Success'
            }
        }
        catch {
            Write-Error "Failed to disable connector '$Connector': $($_.Exception.Message)"

            [PSCustomObject]@{
                ConnectorGuid = $connectorGuid
                Name          = $connectorName
                Enabled       = $null
                Status        = $_.Exception.Message
            }
        }
    }
}

<#
.SYNOPSIS
    Creates a new Keepit connector
.DESCRIPTION
    Creates a new Keepit connector of the specified type. Supports any Keepit connector type
    including Microsoft 365, Dynamics 365, Salesforce, Google Workspace, and others.

    Configuration can be provided as a JSON string via -Configuration or loaded from a file
    via -TemplateFile. Only one of these parameters can be specified.
.PARAMETER ConnectorType
    The type of connector to create. Valid values include: o365-admin, dynamics365, sforce,
    gsuite, powerbi, zendesk, azure-do, azure-ad, and other supported Keepit connector types.
.PARAMETER Name
    The connector name. Must be 1-255 characters.
.PARAMETER Configuration
    A JSON string containing the connector configuration. Maximum 64K length.
    Cannot be used together with -TemplateFile.
.PARAMETER TemplateFile
    Path to a file containing the JSON configuration. The file must exist and contain valid JSON.
    Cannot be used together with -Configuration.
.PARAMETER OrgLink
    ID of the orglink to use. This links the connector to a specific Microsoft 365 tenant.
    Required for M365 connectors to function properly. Get available orglinks from Get-KeepitConnector output.
.PARAMETER RetentionPeriod
    ISO 8601 duration value for the connector retention period (e.g., P1Y for 1 year, P6M for 6 months).
.EXAMPLE
    New-KeepitConnector -ConnectorType "o365-admin" -Name "Production M365"

    Creates a new Microsoft 365 connector with minimal configuration.
.EXAMPLE
    $config = '{"Exchange":{"EnabledCategories":["Mail","Calendar"]}}'
    New-KeepitConnector -ConnectorType "o365-admin" -Name "Production M365" -Configuration $config

    Creates a new Microsoft 365 connector with specific Exchange configuration.
.EXAMPLE
    New-KeepitConnector -ConnectorType "o365-admin" -Name "Test Connector" -TemplateFile "/tmp/o365-config.json"

    Creates a new connector using configuration from a template file.
.EXAMPLE
    New-KeepitConnector -ConnectorType "azure-ad" -Name "Entra ID Backup" -RetentionPeriod "P1Y"

    Creates a new Entra ID connector with 1 year retention period.
.OUTPUTS
    PSCustomObject with properties:
    - ConnectorGuid: The GUID of the newly created connector
    - Name: The connector name
    - Type: The connector type
    - CreatedAt: Creation timestamp (ISO8601 format)
    - RetentionPeriod: The retention period on the connector
.NOTES
    Requires an active connection via Connect-KeepitService.
    Connector names must be unique within an account.
#>
function New-KeepitConnector {
    [CmdletBinding(DefaultParameterSetName = 'NoConfig')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-ConnectorTypeName -TypeName $_ })]
        [string]$ConnectorType,

        [Parameter(Mandatory = $true)]
        [ValidateLength(1, 255)]
        [string]$Name,

        [Parameter(Mandatory = $false, ParameterSetName = 'ConfigString')]
        [ValidateScript({
            if ($_.Length -gt 65536) {
                throw "Configuration exceeds maximum length of 64K characters"
            }
            try {
                $null = $_ | ConvertFrom-Json
                $true
            }
            catch {
                throw "Configuration must be valid JSON: $($_.Exception.Message)"
            }
        })]
        [string]$Configuration,

        [Parameter(Mandatory = $false, ParameterSetName = 'ConfigFile')]
        [ValidateScript({
            if (-not (Test-Path -Path $_ -PathType Leaf)) {
                throw "Template file not found: $_"
            }
            $content = Get-Content -Path $_ -Raw
            if ($content.Length -gt 65536) {
                throw "Template file content exceeds maximum length of 64K characters"
            }
            try {
                $null = $content | ConvertFrom-Json
                $true
            }
            catch {
                throw "Template file must contain valid JSON: $($_.Exception.Message)"
            }
        })]
        [string]$TemplateFile,

        [Parameter(Mandatory = $false)]
        [string]$OrgLink,

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^P(\d+Y)?(\d+M)?(\d+W)?(\d+D)?$')]
        [string]$RetentionPeriod
    )

    try {
        Write-Verbose "=== New-KeepitConnector: Creating connector ==="
        Write-Verbose "Connector Type: $ConnectorType"
        Write-Verbose "Name: $Name"

        # Validate that either Configuration or TemplateFile is provided
        if (-not $Configuration -and -not $TemplateFile) {
            throw "Either -Configuration or -TemplateFile must be specified."
        }

        # Load configuration from template file if specified
        $configJson = $null
        if ($TemplateFile) {
            Write-Verbose "Loading configuration from template file: $TemplateFile"
            $configJson = Get-Content -Path $TemplateFile -Raw
        }
        elseif ($Configuration) {
            $configJson = $Configuration
        }

        # Get authentication header and base URL
        $authHeader = Get-AuthHeader
        $baseUrl = Get-KeepitBaseUrl
        $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl

        Write-Verbose "Base URL: $baseUrl"
        Write-Verbose "User ID: $userId"

        # Resolve the connector type to API type (handles DSL-based connectors)
        $apiConnectorType = $ConnectorType
        if ($script:ConnectorTypeApiMapping.ContainsKey($ConnectorType)) {
            $apiConnectorType = $script:ConnectorTypeApiMapping[$ConnectorType]
            Write-Verbose "Resolved connector type '$ConnectorType' to API type '$apiConnectorType'"
        }

        # Build XML request body
        # Escape special XML characters in the name
        $escapedName = [System.Security.SecurityElement]::Escape($Name)

        # Use <cloud> element for cloud-based connectors (per API schema)
        $xmlBody = "<cloud><type>$apiConnectorType</type><name>$escapedName</name>"

        # Add agent-type for DSL-based connectors (use 'agent' element per schema)
        if ($apiConnectorType -eq 'dsl' -and $ConnectorType -ne 'dsl') {
            $xmlBody += "<agent>$ConnectorType</agent>"
        }

        # Add retention period if specified
        if ($RetentionPeriod) {
            $xmlBody += "<backup-retention>$RetentionPeriod</backup-retention>"
        }

        # Add orglink if specified (required for M365 connectors to link to tenant)
        if ($OrgLink) {
            $xmlBody += "<orglink>$OrgLink</orglink>"
        }

        $xmlBody += "</cloud>"

        Write-Verbose "=== API Request Details ==="
        Write-Verbose "Method: POST"
        Write-Verbose "URI: $baseUrl/users/$userId/devices/"
        Write-Verbose "Content-Type: application/xml"
        Write-Verbose "Request Body:`n$xmlBody"

        # Build request headers
        $uri = "$baseUrl/users/$userId/devices/"
        $headers = @{
            'Authorization' = $authHeader
            'Content-Type'  = 'application/xml'
            'Accept'        = 'application/vnd.keepit.v4+xml'
        }

        Write-Verbose "=== Sending API Request ==="

        # Make API call using Invoke-WebRequest for better error handling
        $webResponse = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $xmlBody -SkipHttpErrorCheck

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
                throw "Failed to create connector: [$($apiError.Code)] $($apiError.Description)"
            }
            else {
                throw "Failed to create connector: HTTP $($webResponse.StatusCode) - $errorBody"
            }
        }

        # Parse successful response
        $response = $null
        if ($webResponse.Content) {
            try {
                $response = [xml]$webResponse.Content
            }
            catch {
                Write-Verbose "Could not parse response as XML: $($_.Exception.Message)"
                $response = $webResponse.Content
            }
        }

        # Parse response
        $connectorGuid = $null
        $createdAt = $null
        $responseRetention = $null

        # First, check Location header for the GUID (common REST pattern)
        $locationHeader = $null
        if ($webResponse.Headers -and $webResponse.Headers.ContainsKey('Location')) {
            # Headers may return an array, get first value
            $locationValue = $webResponse.Headers['Location']
            $locationHeader = if ($locationValue -is [System.Array]) { $locationValue[0] } else { $locationValue }
        }
        if ($locationHeader) {
            Write-Verbose "Location header: $locationHeader"
            # Extract GUID from Location URL (e.g., /users/xxx/devices/abc123-def456-ghi789)
            if ($locationHeader -match '/devices/([a-z0-9]{6}-[a-z0-9]{6}-[a-z0-9]{6})') {
                $connectorGuid = $Matches[1]
                Write-Verbose "Extracted GUID from Location header: $connectorGuid"
            }
        }

        if ($response -is [System.Xml.XmlDocument] -or $response -is [System.Xml.XmlElement]) {
            Write-Verbose "Response is XML"
            # Handle response as XML - the API returns the created device
            $deviceElement = if ($response -is [System.Xml.XmlDocument]) {
                $response.DocumentElement
            } else {
                $response
            }

            if ($deviceElement.LocalName -eq 'cloud' -or $deviceElement.LocalName -eq 'device') {
                $connectorGuid = $deviceElement.guid
                $createdAt = $deviceElement.created
                $responseRetention = $deviceElement.'backup-retention'
            }
            elseif ($deviceElement.cloud) {
                $connectorGuid = $deviceElement.cloud.guid
                $createdAt = $deviceElement.cloud.created
                $responseRetention = $deviceElement.cloud.'backup-retention'
            }

            Write-Verbose "Parsed GUID: $connectorGuid"
            Write-Verbose "Parsed Created: $createdAt"
        }
        elseif ($response -is [string] -and -not [string]::IsNullOrWhiteSpace($response)) {
            Write-Verbose "Response is string, attempting XML parse"
            try {
                $xml = [xml]$response
                $connectorGuid = $xml.cloud.guid ?? $xml.device.guid
                $createdAt = $xml.cloud.created ?? $xml.device.created
                $responseRetention = $xml.cloud.'backup-retention' ?? $xml.device.'backup-retention'
            }
            catch {
                Write-Verbose "Could not parse response as XML: $($_.Exception.Message)"
            }
        }

        # If we still don't have the GUID, look up the connector by name
        if (-not $connectorGuid) {
            Write-Verbose "No GUID in response or headers, looking up connector by name..."

            # Fetch all connectors and find the one we just created
            $lookupHeaders = @{
                'Authorization' = $authHeader
                'Content-Type'  = 'application/xml'
                'Accept'        = 'application/vnd.keepit.v4+xml'
            }
            $lookupUri = "$baseUrl/users/$userId/devices"
            $lookupResponse = Invoke-RestMethod -Uri $lookupUri -Method Get -Headers $lookupHeaders -ErrorAction Stop

            if ($lookupResponse.devices.cloud) {
                $devices = if ($lookupResponse.devices.cloud -is [System.Array]) {
                    $lookupResponse.devices.cloud
                } else {
                    @($lookupResponse.devices.cloud)
                }

                # Find connector by exact name match
                $matchingConnector = $devices | Where-Object { $_.name -eq $Name } | Select-Object -First 1
                if ($matchingConnector) {
                    $connectorGuid = $matchingConnector.guid
                    $createdAt = $matchingConnector.created
                    $responseRetention = $matchingConnector.'backup-retention'
                    Write-Verbose "Found connector by name lookup: $connectorGuid"
                }
            }
        }

        if (-not $connectorGuid) {
            throw "Connector was created (HTTP 201) but could not determine the GUID. Check Get-KeepitConnector for connector named '$Name'."
        }

        $connectorGuid = $connectorGuid.ToLower()
        Write-Verbose "Created connector GUID: $connectorGuid"

        # If configuration was provided, set it via the attributes API
        if ($configJson) {
            Write-Verbose "Setting connector configuration via attributes API"

            # Determine the attribute key based on connector type
            $attributeKey = switch ($apiConnectorType) {
                'o365-admin'  { 'ng_backup_config' }
                'dynamics365' { 'ng_backup_config' }
                'azure-ad'    { 'backup_config' }
                'powerbi'     { 'backup_config' }
                default       { 'ng_backup_config' }
            }

            $attrUri = "$baseUrl/users/$userId/devices/$connectorGuid/attributes/$attributeKey"
            $attrHeaders = @{
                'Authorization' = $authHeader
                'Content-Type'  = 'application/octet-stream'
            }

            Write-Verbose "Setting attribute '$attributeKey' at: $attrUri"

            $configBytes = [System.Text.Encoding]::UTF8.GetBytes($configJson)
            Invoke-RestMethod -Uri $attrUri -Method Put -Headers $attrHeaders -Body $configBytes -ErrorAction Stop

            Write-Verbose "Configuration set successfully"
        }

        # Build and return result object
        $result = [PSCustomObject]@{
            ConnectorGuid   = $connectorGuid
            Name            = $Name
            Type            = $ConnectorType
            CreatedAt       = $createdAt
            RetentionPeriod = if ($responseRetention) {
                ConvertFrom-ISO8601Duration -Duration $responseRetention
            } elseif ($RetentionPeriod) {
                ConvertFrom-ISO8601Duration -Duration $RetentionPeriod
            } else {
                "Unlimited"
            }
        }

        Write-Verbose "=== Connector Created Successfully ==="
        Write-Verbose "ConnectorGuid: $($result.ConnectorGuid)"
        Write-Verbose "Name: $($result.Name)"
        Write-Verbose "Type: $($result.Type)"
        Write-Verbose "CreatedAt: $($result.CreatedAt)"
        Write-Verbose "RetentionPeriod: $($result.RetentionPeriod)"

        return $result
    }
    catch {
        # Re-throw with context if not already a connector creation error
        $errorMessage = $_.Exception.Message
        if ($errorMessage -like "Failed to create connector:*") {
            throw
        }
        throw "Failed to create connector: $errorMessage"
    }
}

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
        - Token: Token used for the action (masked for security)
.NOTES
    Requires an active connection via Connect-KeepitService.
    Maximum 10,000 records returned per request. Token values are masked for security.
#>
function Get-KeepitAuditLog {
    [CmdletBinding()]
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
        $filterXml = "<filter><account>$userId</account>"

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
            $filterXml += "<area>$Area</area>"
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
        throw "Failed to retrieve audit logs: $($_.Exception.Message)"
    }
}

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
        throw "Failed to retrieve shares: $($_.Exception.Message)"
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ConnectorGuid', 'Name')]
        [string]$Connector,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^P(\d+Y)?(\d+M)?(\d+W)?(\d+D)?(T(\d+H)?(\d+M)?(\d+S)?)?$')]
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
            throw "Failed to initialize: $($_.Exception.Message)"
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

            Write-Verbose "=== API Request Details ==="
            Write-Verbose "Method: POST"
            Write-Verbose "URI: $baseUrl/share/"
            Write-Verbose "Content-Type: application/xml"
            Write-Verbose "Request Body:`n$xmlBody"

            # Build request
            $uri = "$baseUrl/share/"
            $headers = @{
                'Authorization' = $authHeader
                'Content-Type'  = 'application/xml'
            }

            Write-Verbose "=== Sending API Request ==="

            # Use Invoke-WebRequest to capture Location header
            $webResponse = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $xmlBody -SkipHttpErrorCheck

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
        catch {
            $errorMessage = $_.Exception.Message
            if ($errorMessage -like "Failed to create share:*") {
                throw
            }
            throw "Failed to create share: $errorMessage"
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
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ShareId,

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^P(\d+Y)?(\d+M)?(\d+W)?(\d+D)?(T(\d+H)?(\d+M)?(\d+S)?)?$')]
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
            throw "Failed to initialize: $($_.Exception.Message)"
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
            Write-Verbose "Request Body:`n$xmlBody"

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
            throw "Failed to update share: $errorMessage"
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
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
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
            throw "Failed to initialize: $($_.Exception.Message)"
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
            throw "Failed to delete share: $errorMessage"
        }
    }
}

#endregion

# Note: Function exports are defined in KeepitTools.psd1 (FunctionsToExport)
# Always import via the manifest (.psd1) to get correct version information
