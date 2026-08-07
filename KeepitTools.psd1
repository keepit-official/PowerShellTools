@{
    # Script module or binary module file associated with this manifest
    RootModule = 'KeepitTools.psm1'

    # Version number of this module
    ModuleVersion = '1.7.0'

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
    Description = 'PowerShell module for the Keepit backup platform. Provides cmdlets to connect to the Keepit API; manage connectors, backup jobs, and users; search and bulk-restore deleted Exchange email and OneDrive files with job coalescing by snapshot; and work with audit logs and secure sharing links.'

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
        'Restore-KeepitFailedItems',
        'Save-KeepitFailedItems',
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
        'Get-KeepitJobHistory',
        'Get-KeepitAllowedIPRange',
        'Update-KeepitAllowedIPRange'
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
Version 1.7.0
- Get-KeepitAllowedIPRange: New cmdlet to read the account trusted-IP allowlist (allowed IP address ranges) from the account MFA configuration (GET /users/{userId}/mfa)
- Get-KeepitAllowedIPRange: Always returns each rule as an inclusive From/To range, whether it is stored as from/to, CIDR, or address plus prefix; a range that is one aligned CIDR block also reports Cidr/PrefixLength. -Raw returns the underlying MFA XML
- Update-KeepitAllowedIPRange: New cmdlet to set the allowlist using IPv4 CIDR ranges (PUT /users/{userId}/mfa). Writes each CIDR as a from/to range, not a cidr element, because the Keepit WebApp IP Ranges page hangs on CIDR-based rules; read-modify-write preserves the MFA enabled flag, the rules group operator, and non-IP rules such as TOTP
- Update-KeepitAllowedIPRange: Supports -Clear to empty the allowlist (removes all ranges, preserving the enabled flag, the rules operator, and non-IP rules such as TOTP); -Clear and -IPRange are mutually exclusive
- Update-KeepitAllowedIPRange: Requires primary account credentials whose role grants "Enable and configure MFA" (e.g. Master Admin); distinguishes the "Primary credentials required" and "Forbidden" errors; supports -WhatIf/-Confirm (ConfirmImpact High) and -PassThru
- Add BulkIPAllowlist example (Set-KeepitAllowedIPRanges.ps1) to bulk-set trusted IP ranges from a text or CSV file

Version 1.6.2
- Add GitHub as a supported connector type for Get-KeepitConnector and New-KeepitConnector; GitHub is DSL-based, so the API type is 'dsl' with a 'github' agent type
- Add Autodesk Forma as a supported connector type ('autodesk-forma'), also DSL-based

Version 1.6.1
- Add -Notify switch to Restore-KeepitBulkDeletedItems, Start-KeepitExpressRestore, Search-KeepitSnapshot, and Start-KeepitBackup to send a non-blocking desktop notification when each operation completes
- Add Show-KeepitNotification private helper that selects the platform-appropriate notification mechanism (Windows balloon tip, macOS osascript, Linux notify-send, Write-Host fallback)

Version 1.6.0
- Save-KeepitFailedItems: New cmdlet to download the items that failed in a previous restore job as a ZIP, instead of restoring them back into Microsoft 365
- Save-KeepitFailedItems: Reads the skipped-item list from the job log (or a Job Report CSV via -ReportPath), locates each failed file in the backup snapshot, and downloads the backed-up contents
- Save-KeepitFailedItems: Matches failed items to their backup by workload (SharePoint / Teams / OneDrive) and path tail
- Save-KeepitFailedItems: Lays downloaded files out in a folder tree mirroring their original location; non-file failures are reported as skipped
- Save-KeepitFailedItems: Supports -IncludeCause / -ExcludeCause, -OutputPath, -TimeoutSec, and -WhatIf / -Confirm; reads only from the backup and makes no changes to Microsoft 365

Version 1.5.0
- Restore-KeepitFailedItems: New cmdlet to retry the items that failed in a previous restore job; recovers the snapshot and restore settings from the original job and resubmits only the failed items
- Restore-KeepitFailedItems: Reads the failed-item list from the job log, or from a Job Report CSV via -ReportPath
- Restore-KeepitFailedItems: Supports -IncludeCause / -ExcludeCause, -ShowJobs, and -WhatIf / -Confirm; resolves the submitted retry job's real GUID from job history
- Restore-KeepitFailedItems: Retries whole-scope restores that have no per-item paths (e.g. SharePoint site, Salesforce, whole-mailbox) by re-running the job's own restore configuration; declines relocated whole-site restores
- Restore-KeepitBulkDeletedItems: Harden snapshot resolution so a snapshot stamped exactly at an item's timestamp is included
- Get-KeepitJobHistory: Add -FailReason switch to surface the job-level fail_reason as a FailReason property on failed jobs
Version 1.4.5
- Set-KeepitConnectorConfiguration / New-KeepitConnector: Raise the connector config size guard from 64K to the real 1GB backend limit (measured as UTF-8 bytes)
- Add BulkSiteConfig example (Add-KeepitSharePointSites.ps1) to bulk-add SharePoint sites to a connector from a text or CSV file, with single-connector or per-row CSV routing

Version 1.4.4
- EverCovered-Sites.ps1 (example): Add a Protected column exposing the SharePoint protected flag from Search-KeepitSnapshot metadata
- EverCovered-Sites.ps1 (example): Fix the Status column reporting deleted or removed sites as Active; status now derives from each entry's IsDeleted flag

Version 1.4.3
- Get-KeepitUser: Fix 400 Bad Request by changing the /tokens Accept header from v4 to v2 (v4 is documented as incompatible with the /tokens endpoint)

Version 1.4.2
- Fix all remaining PSScriptAnalyzer warnings for a clean PSGallery listing
- Remove unused parameters: JobStatus (Invoke-JobCancellation), UserPrincipalName (Submit-ExpressRestoreJobs), FullConfig (Get-SharePointCoverage, Get-UnifiedGroupsCoverage)
- Add ConnectorName to New-AlreadyQueuedResult output object
- Suppress PSAvoidUsingWriteHost on WhatIf/diagnostic output functions (intentional colored console output)
- Suppress PSReviewUnusedParameter on Get-KeepitSnapshot switches used via ParameterSetName
- Add UTF-8 BOM to Restore.ps1, Snapshots.ps1, and Connectors.ps1

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
