@{
    # Script module or binary module file associated with this manifest
    RootModule = 'KeepitTools.psm1'

    # Version number of this module
    ModuleVersion = '1.4.1'

    # Supported PSEditions
    CompatiblePSEditions = @('Core')

    # ID used to uniquely identify this module
    GUID = 'a7b3c4d5-e6f7-8a9b-0c1d-2e3f4a5b6c7d'

    # Author of this module
    Author = 'Keepit'

    # Company or vendor of this module
    CompanyName = 'Keepit'

    # Copyright statement for this module
    Copyright = '(c) 2026 Keepit. All rights reserved.'

    # Description of the functionality provided by this module
    Description = 'PowerShell module for mass restore of deleted email items from Keepit backups. Provides cmdlets to connect to the Keepit platform API, search for deleted items within a date range, and perform bulk restore operations with job coalescing by snapshot.'

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '7.0'

    # Name of the PowerShell host required by this module
    # PowerShellHostName = ''

    # Minimum version of the PowerShell host required by this module
    # PowerShellHostVersion = ''

    # Minimum version of Microsoft .NET Framework required by this module
    # DotNetFrameworkVersion = ''

    # Minimum version of the common language runtime (CLR) required by this module
    # ClrVersion = ''

    # Processor architecture (None, X86, Amd64) required by this module
    # ProcessorArchitecture = ''

    # Modules that must be imported into the global environment prior to importing this module
    # RequiredModules = @()

    # Assemblies that must be loaded prior to importing this module
    # RequiredAssemblies = @()

    # Script files (.ps1) that are run in the caller's environment prior to importing this module
    # ScriptsToProcess = @()

    # Type files (.ps1xml) to be loaded when importing this module
    # TypesToProcess = @()

    # Format files (.ps1xml) to be loaded when importing this module
    # FormatsToProcess = @()

    # Modules to import as nested modules of the module specified in RootModule/ModuleToProcess
    # NestedModules = @()

    # Functions to export from this module, for best performance, do not use wildcards and do not delete the entry
    FunctionsToExport = @(
        'Connect-KeepitService',
        'Disconnect-KeepitService',
        'Get-KeepitConnector',
        'Get-KeepitConnectorConfiguration',
        'Set-KeepitConnectorConfiguration',
        'Get-KeepitSnapshot',
        'Get-KeepitJobs',
        'Stop-KeepitJob',
        'Start-KeepitBackup',
        'Search-KeepitSnapshot',
        'Convert-KeepitUPNToGuid',
        'Convert-KeepitGuidToUPN',
        'Submit-KeepitJob',
        'Restore-KeepitBulkDeletedItems',
        'New-KeepitConnector',
        'Get-KeepitAuditLog',
        'Get-KeepitShare',
        'New-KeepitShare',
        'New-KeepitUser',
        'Get-KeepitUser',
        'Get-KeepitRoles',
        'Remove-KeepitUser',
        'Set-KeepitShare',
        'Remove-KeepitShare',
        'Start-KeepitExpressRestore',
        'Get-KeepitItemAttributes',
        'Get-KeepitJobHistory'
    )

    # Cmdlets to export from this module, for best performance, do not use wildcards and do not delete the entry
    CmdletsToExport = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module, for best performance, do not use wildcards and do not delete the entry
    AliasesToExport = @(
        'Get-KeepitJob',
        'Get-KeepitRole',
        'Find-KeepitSnapshot'
    )

    # DSC resources to export from this module
    # DscResourcesToExport = @()

    # List of all modules packaged with this module
    # ModuleList = @()

    # List of all files packaged with this module
    # FileList = @()

    # Private data to pass to the module specified in RootModule/ModuleToProcess. This may also contain a PSData hashtable with additional module metadata used by PowerShell.
    PrivateData = @{
        PSData = @{
            # Tags applied to this module. These help with module discovery in online galleries.
            Tags = @('Keepit', 'Backup', 'Restore', 'Email', 'Exchange', 'M365', 'Office365')

            # A URL to the license for this module.
            LicenseUri = 'https://github.com/keepit-official/PowerShellTools/blob/main/LICENSE.md'

            # A URL to the main website for this project.
            ProjectUri = 'https://github.com/keepit-official/PowerShellTools'

            # A URL to an icon representing this module.
            # IconUri = ''

            # ReleaseNotes of this module
            ReleaseNotes = @'
Version 1.4.1
- Fix PSScriptAnalyzer PSGallery warnings across module source files
- Add LicenseUri and ProjectUri to module manifest
- Update copyright year to 2026

Version 1.4.0
- Get-KeepitJobHistory: New cmdlet to retrieve historical job records using the PUT /jobs API
- Get-KeepitJobHistory: Supports -StartTime (required), -EndTime, -Type, -Limit, -FailedOnly, and -Raw parameters
- Get-KeepitJobHistory: Output includes Succeeded, Failed, Status, and Progress properties distinct from Get-KeepitJobs
- Get-KeepitJobHistory: Accepts pipeline input from Get-KeepitConnector

Version 1.3.3
- Get-KeepitItemAttributes: New cmdlet to retrieve metadata attributes (e.g. SharePoint protected flag) from the snapshot content API
- Search-KeepitSnapshot: Improve kng:meta element parsing to extract key/value pairs and boolean flags
- New-KeepitConnector: Fix connector creation to embed required standard attributes in create XML and enable via PUT instead of POST
- New-KeepitConnector: Fix attribute Content-Type from application/octet-stream to text/plain
- New-KeepitConnector: Reinforce attributes via individual PUT calls after enable
- New-KeepitConnector: Refactor standard attributes to single ordered hashtable (eliminates duplicate definition)
- New-KeepitConnector: Replace Invoke-WebRequest enable call with Invoke-RestMethod
- Get-KeepitItemAttributes: Collapse duplicate XML parsing branches; normalise string response to [xml] before dispatch

Version 1.3.2
- Restore-KeepitBulkDeletedItems: Add -SearchTerms parameter for filtering deleted items by sender, recipient, or content before restoring
- Search-KeepitSnapshot: Update Entra ID RootPath validation to use display names instead of old API-style short names
- Move Enable-KeepitConnector and Disable-KeepitConnector to ConnectorState.ps1; excluded from public module per support team request
- Fix security audit findings SEC-1 through SEC-5

Version 1.3.1
- Convert-KeepitUPNToGuid: Fix double-dash GUID bug where dashes were pre-escaped before ConvertTo-MaskedPath, resulting in quadruple dashes and failed searches

Version 1.3.0
- Start-KeepitExpressRestore: New cmdlet for express restore of recent user data by time window (Experimental)
- Start-KeepitExpressRestore: Support Exchange workload with -PrioritizeCalendar and -InboxOnly switches
- Start-KeepitExpressRestore: Accept both PowerShell TimeSpan and ISO 8601 duration strings
- Start-KeepitExpressRestore: Automatic job batching when XML exceeds 60 KB threshold
- Start-KeepitExpressRestore: Pipeline support for multiple users via -UserPrincipalName
- Search-KeepitSnapshot: Add -ReceivedTime and -ReceivedEndTime parameters for source-system date filtering

Version 1.1.0
- New-KeepitUser: New cmdlet to create Keepit user accounts with role assignment and connector access
- New-KeepitUser: Support -Connectors parameter with "all" shorthand or specific connector names/GUIDs
- New-KeepitUser: Support -SendActivationEmail and -NotificationsEnabled switches
- Remove-KeepitUser: New cmdlet to remove Keepit user accounts
- Remove-KeepitUser: Support -WhatIf and -Confirm with ConfirmImpact High
- Get-KeepitUser: New cmdlet to list all user accounts on the platform
- Get-KeepitRoles: New cmdlet to list available roles and their capabilities
- Refactor module from monolithic .psm1 into dot-sourced script files (Private/ and Public/ directories)

Version 1.0.0
- New-KeepitShare: Prepend base URL to relative Location headers so ShareUrl returns a full URL
- New-KeepitShare: Append trailing slash to paths that lack one (directory share)
- Convert-KeepitUPNToGuid: Escape GUIDs with double dashes for Keepit path format
- ConvertTo-MaskedPath: Make dash escaping idempotent so pre-escaped GUIDs are not re-doubled

Version 0.9.9
- Stop-KeepitJob: New cmdlet to cancel running, scheduled, and queued jobs
- Stop-KeepitJob: Support -All switch to cancel every active/scheduled job on a connector
- Stop-KeepitJob: Support pipeline input from Get-KeepitJobs
- Stop-KeepitJob: Support -WhatIf and -Confirm
- Start-KeepitBackup: Add -ScheduledTime parameter for scheduling future backups
- Get-KeepitConnectorConfiguration: Add -Coverage parameter to return parsed backup scope per workload

Version 0.9.8
- Get-KeepitShare: New cmdlet to list all shared secure links for the authenticated user
- New-KeepitShare: New cmdlet to create shared secure links with optional password and expiry
- Set-KeepitShare: New cmdlet to update share properties (lifetime, password, snapshot)
- Remove-KeepitShare: New cmdlet to delete shared secure links

Version 0.9.7
- Get-KeepitJobs: Add -Active switch to show only currently running jobs
- Get-KeepitJobs: Add -Completed switch to show only finished jobs
- Get-KeepitJobs: Add -Scheduled switch to show only pending scheduled jobs

Version 0.9.6
- Get-KeepitAuditLog: New cmdlet to retrieve audit log entries from the Keepit platform
- Get-KeepitAuditLog: Support date range filtering with -StartTime and -EndTime
- Get-KeepitAuditLog: Support -ResultSize parameter (default 100, max 10000)
- Get-KeepitAuditLog: Support -Area filter for event categories

Version 0.9.5
- Get-KeepitConnector: Add -All switch to include all connectors in API response

Version 0.9.4
- Restore-KeepitBulkDeletedItems: Add job batching for large item sets exceeding 64KB XML limit
- Restore-KeepitBulkDeletedItems: Jobs output now includes BatchNumber and TotalBatches when batching occurs
- Restore-KeepitBulkDeletedItems: WhatIf output shows accurate job counts including batched jobs

Version 0.9.2
- New-KeepitConnector: Create new Keepit connectors with configurable type, name, and retention
- New-KeepitConnector: Support Configuration parameter for inline JSON or TemplateFile for file-based config
- New-KeepitConnector: Support DSL-based connectors (Jira, Confluence, etc.) with automatic agent-type handling
- New-KeepitConnector: Implement OrgLink parameter for linking M365 connectors to tenants
- Get-KeepitConnectorConfiguration: Add -Raw switch to return raw XML from device endpoint

Version 0.8.2
- Set-KeepitConnectorConfiguration: Fix -AutoIncludeSites to always set value explicitly
- Set-KeepitConnectorConfiguration: Fix -AutoIncludeSites:$false to set AutoIncludeAllSiteCollections to false instead of removing the key

Version 0.8.0
- Set-KeepitConnectorConfiguration: Show raw configuration with -WhatIf for SharePoint and Teams workloads
- Set-KeepitConnectorConfiguration: Fix missing implementation for -AddIncludedSites, -RemoveIncludedSites, -AddExcludedSites, -RemoveExcludedSites
- Set-KeepitConnectorConfiguration: Add -AddExcludedGroups and -RemoveExcludedGroups parameters for Teams workload
- Set-KeepitConnectorConfiguration: Add warnings for duplicate add/missing remove operations
- Set-KeepitConnectorConfiguration: Skip write if no configuration changes were made
- Set-KeepitConnectorConfiguration: Include RawConfiguration in success output
- Set-KeepitConnectorConfiguration: Fix URL whitespace handling in site comparisons
- Restore-KeepitBulkDeletedItems: Show restore job XML with -WhatIf and improved -ShowJobs formatting

Version 0.7.8
- Rename StartDate/EndDate to StartTime/EndTime in Get-KeepitSnapshot, Get-KeepitJobs, Restore-KeepitBulkDeletedItems
- Get-KeepitConnector: BackupRetention now shows human-readable values (e.g., "3 months", "Unlimited") instead of ISO 8601
- Fix module version display: remove Export-ModuleMember, use manifest FunctionsToExport only

Version 0.7.7
- Add Set-KeepitConnectorConfiguration cmdlet for updating connector configuration via JSON
- Get-KeepitConnectorConfiguration: Add -Workload parameter for filtering by workload type
- Get-KeepitConnectorConfiguration: Rename Configuration to RawConfiguration for clarity
- Get-KeepitConnectorConfiguration: Add parsed Configuration property when -Workload specified

Version 0.7.6
- Search-KeepitSnapshot: Simplify response parsing, remove 76 lines of dead code
- Search-KeepitSnapshot: Reduce parsing branches from 14 to 4 (Array, XmlEntry, XmlFeed, Fallback)
- Search-KeepitSnapshot: Remove unused JSON and regex fallback parsing paths

Version 0.7.5
- Restore-KeepitBulkDeletedItems: Add OneDrive for Business file restore support
- New-RestoreJobXml: Add OneDrive type with DeltaAppend FolderRestoreMode
- Search-KeepitSnapshot: Add user-not-found validation with clear error message
- Search-KeepitSnapshot: Add EndTime/StartTime validation (EndTime cannot be before StartTime)
- Search-KeepitSnapshot: Add ItemType detection for OneDrive (folder/file from contentType)
- Search-KeepitSnapshot: Extract Size from meta element for OneDrive items
- Search-KeepitSnapshot: Remove Published property from output

Version 0.7.1
- Fix culture-sensitive date formatting that caused API failures in non-US locales
- All DateTime.ToString() calls now use InvariantCulture for consistent ISO 8601 output
- Add unit tests for ConvertTo-KeepitTimestamp culture-invariant behavior

Version 0.7.0
- Restore-KeepitBulkDeletedItems: Add Entra ID user restore support with correct XML configuration
- Restore-KeepitBulkDeletedItems: Fix CSV pipeline to correctly restore each user (not just first)
- Restore-KeepitBulkDeletedItems: Handle recreated users by filtering on UPN instead of GUID
- Start-KeepitBackup: Replace Scheduled with CreatedAt in output
- Start-KeepitBackup: Remove Priority and JobGuid from output
- Start-KeepitBackup: Gracefully handle Entra connectors returning empty response
- Start-KeepitBackup: Gracefully handle RUNNING_JOB error when backup already in progress
- Search-KeepitSnapshot: Fix DeletedOnly for Entra connectors (client-side filtering)
- Search-KeepitSnapshot: Add ItemType derivation from contentType
- Search-KeepitSnapshot: Fix IsDeleted detection for empty XML tags
- Search-KeepitSnapshot: Add Entra ID pathroot validation
- Search-KeepitSnapshot: Change -Recursive to switch parameter (default false)
- Get-KeepitSnapshot: Add ConnectorName to output
- Get-KeepitJobs: Add ConnectorName to output
- Standardize path parameter naming to RootPath across all cmdlets
- Standardize connector parameter naming to Connector across all cmdlets

Version 0.5.6
- Search-KeepitSnapshot: Fixed DateTime parsing to treat ISO8601 timestamps as UTC
- Search-KeepitSnapshot: Renamed SnaptimeFrom/SnaptimeTo to StartTime/EndTime
- Search-KeepitSnapshot: Same-date StartTime/EndTime now searches entire day

Version 0.5.5
- Get-KeepitSnapshot: Fixed date range query to make EndDate inclusive

Version 0.5.0
- Submit-KeepitJob: Low-level cmdlet to submit backup/restore jobs with raw XML configuration
- Restore-KeepitBulkDeletedItems: High-level cmdlet for bulk restore of deleted email items
- Search-KeepitSnapshot: Added -DeletedOnly parameter, changed -Recursive default to $true
- Get-KeepitSnapshot: Added ResultSize parameter with pagination support

Version 0.0.4
- Get-KeepitConnectorConfiguration: Retrieve connector configuration and custom attributes
- Enable-KeepitConnector: Enable a disabled connector
- Disable-KeepitConnector: Disable a connector
- Get-KeepitConnector: Added display name support for -Type parameter

Version 0.0.3 (Initial Release)
- Connect-KeepitService: Establish authenticated connection to Keepit platform
- Disconnect-KeepitService: Clean up session and cached credentials
- Get-KeepitConnector: Retrieve all accessible Office 365 connectors
- Get-KeepitSnapshot: Retrieve snapshot information (latest, range, or count)
- Get-KeepitJobs: Retrieve backup and restore jobs for connectors
- Start-KeepitBackup: Start immediate or scheduled backup jobs on connectors

Features:
- Cross-platform support (Windows, macOS, Linux)
- Secure credential handling using PSCredential
- Support for all Keepit data center environments
- Flexible authentication (cached or per-call credentials)
- Full pipeline support for efficient workflows
- Immediate and scheduled backup job creation
- Job monitoring and filtering by type
- Bulk restore with job coalescing by snapshot
'@

            # Prerelease string of this module
            # Prerelease = 'alpha'

            # Flag to indicate whether the module requires explicit user acceptance for install/update/save
            # RequireLicenseAcceptance = $false

            # External dependent modules of this module
            # ExternalModuleDependencies = @()
        }
    }

    # HelpInfo URI of this module
    # HelpInfoURI = ''

    # Default prefix for commands exported from this module. Override the default prefix using Import-Module -Prefix.
    # DefaultCommandPrefix = ''
}
