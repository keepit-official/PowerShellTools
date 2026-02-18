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

