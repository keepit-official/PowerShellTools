@{
    # Script module or binary module file associated with this manifest
    RootModule = 'KeepitTools.psm1'

    # Version number of this module
    ModuleVersion = '1.8.0'

    # Supported PSEditions
    CompatiblePSEditions = @('Desktop', 'Core')

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
    PowerShellVersion = '5.1'

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
            Tags = @('Keepit', 'Backup', 'Restore', 'Email', 'Exchange', 'M365', 'Office365', 'PSEdition_Desktop', 'PSEdition_Core', 'Windows', 'Linux', 'MacOS')

            # A URL to the license for this module.
            LicenseUri = 'https://github.com/keepit-official/PowerShellTools/blob/main/LICENSE.md'

            # A URL to the main website for this project.
            ProjectUri = 'https://github.com/keepit-official/PowerShellTools'

            # A URL to an icon representing this module.
            # IconUri = ''

            # ReleaseNotes of this module
            ReleaseNotes = @'
Version 1.8.0
- Add support for Windows PowerShell 5.1. The manifest now requires PowerShell 5.1 and declares the Desktop and Core editions (TAC-349)
- Replace the PowerShell 7-only constructs in the module: the ?? operator, Join-String, ConvertFrom-Json -AsHashtable, Invoke-WebRequest -SkipHttpErrorCheck, and the $IsWindows and $IsMacOS variables (TAC-351, TAC-352, TAC-353)
- Read every response body as UTF-8 on both versions, so non-ASCII characters in names and paths are kept on Windows PowerShell 5.1, which decodes a response without a charset as ISO-8859-1 (TAC-354)
- Add -UseBasicParsing to every web request and enable TLS 1.2 when the module loads on Windows PowerShell (TAC-354)
- Add tests/Compatibility.Tests.ps1, which checks the manifest, scans the source for constructs that 5.1 does not support, and tests the compatibility helpers (TAC-355)
- Add ci/run-tests.ps1 and a GitLab test stage that runs the suite and the PSScriptAnalyzer 5.1 compatibility rules under PowerShell 7, with a manual job for Windows PowerShell 5.1 (TAC-355)
- app/restore-helpers.ps1: Run on Windows PowerShell 5.1, and prompt with a message that names the credentials (TAC-350)

For the full release history, see the bundled CHANGELOG or https://github.com/keepit-official/PowerShellTools/blob/main/CHANGELOG.
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
