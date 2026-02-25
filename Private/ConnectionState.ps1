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
    Version: 1.2.0
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
