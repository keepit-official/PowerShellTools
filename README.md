# Keepit PowerShell Tools

## Description

This project covers building a self-contained PowerShell module containing cmdlets that allow an administrator to connect to the Keepit service and perform various tasks. It is based on the structure of the Bohr and Keepit MCP tools, and is meant to provdie an alternative for customers who can't or don't want to run MCP tooling.

In addition, this module provides cmdlets to perform restores of large numbers of deleted email items and OneDrive files. It uses the Keepit platform API to find items matching the search criteria, identify what Keepit snapshots they are in, collect items in the same snapshot into restore jobs (a process known as "coalescing" the jobs), and then submits the jobs for action.

## Requirements

- PowerShell 7.0 or later on Windows, macOS, and Linux

## Installation and Usage

### Installation

The module is published on the [PowerShell Gallery](https://www.powershellgallery.com/packages/KeepitTools) as `KeepitTools`. It can also be installed by copying the module files to a PowerShell module path or by importing directly from the source directory.

#### Option 1: Install from PowerShell Gallery

This is the recommended method for most users:

```powershell
# Using PowerShellGet
Install-Module -Name KeepitTools -Scope CurrentUser

# Or using PSResourceGet
Install-PSResource -Name KeepitTools -Scope CurrentUser

# Import the module
Import-Module KeepitTools
```

#### Option 2: Import from Source Directory

This is the recommended method for development and testing:

```powershell
# Import the module from the src directory
# Depending on what you downloaded, it may not be in the current folder so adjust as necessary.
Import-Module ./KeepitTools.psd1 -Force

# Verify the module is loaded
Get-Module KeepitTools
```

#### Option 3: Install to User Module Path

For permanent installation, copy the module to your PowerShell modules directory:

**Windows:**

```powershell
# Create module directory
$modulePath = "$env:USERPROFILE\Documents\PowerShell\Modules\KeepitTools"
New-Item -ItemType Directory -Path $modulePath -Force

# Copy module files
Copy-Item -Path ./src/* -Destination $modulePath -Recurse

# Import the module
Import-Module KeepitTools
```

**macOS/Linux:**

```powershell
# Create module directory; edit this path as desired depending on your machine config
$modulePath = "~/.local/share/powershell/Modules/KeepitTools"
New-Item -ItemType Directory -Path $modulePath -Force

# Copy module files
Copy-Item -Path ./src/* -Destination $modulePath -Recurse

# Import the module
Import-Module KeepitTools
```

### Verifying Installation

After importing the module, verify that the module is loaded and the cmdlets are available:

```powershell
# List all available cmdlets in the module
Get-Command -Module KeepitTools

# View help for a specific cmdlet
Get-Help Connect-KeepitService -Full

# Check module version
Get-Module KeepitTools | Select-Object Name, Version
```

### Basic Usage

```powershell
# Connect to Keepit service using PSCredential
# Best practice: create an access token in the Keepit admin center just for these tools
# Don't use your normal username/password!
$cred = Get-Credential
Connect-KeepitService -Credential $cred -Environment "us-dc"

# OR connect using username and password
$password = Read-Host "Enter password" -AsSecureString
Connect-KeepitService -UserName "admin@example.com" -Password $password -Environment "us-dc"

# Get all M365 connectors
$connectors = Get-KeepitConnector -type "o365-admin"
$connectors | Format-Table ConnectorGuid, Name, Type, BackupRetention

# Disconnect when done
Disconnect-KeepitService
```

### Unloading the Module

To remove the module from your session:

```powershell
Remove-Module KeepitTools
```

## Available Cmdlets

| Cmdlet                             | Description                                                        |
| ---------------------------------- | ------------------------------------------------------------------ |
| `Connect-KeepitService`            | Establishes authenticated connection to Keepit platform            |
| `Disconnect-KeepitService`         | Closes connection and clears cached credentials                    |
| `Get-KeepitConnector`              | Retrieves accessible connectors, optionally filtered by type       |
| `Get-KeepitConnectorConfiguration` | Retrieves connector configuration, workload filtering, and coverage|
| `Set-KeepitConnectorConfiguration` | Updates connector configuration to add/remove objects or attributes|
| `New-KeepitConnector`              | Creates a new Keepit connector with specified type and config      |
| `Get-KeepitSnapshot`               | Retrieves snapshot information (latest, range, or count)           |
| `Get-KeepitJobs`                   | Retrieves active and future backup/restore jobs for a connector    |
| `Get-KeepitJobHistory`             | Retrieves historical job records for a connector by time range     |
| `Stop-KeepitJob`                   | Cancels running or scheduled backup/restore jobs                   |
| `Start-KeepitBackup`               | Starts immediate or scheduled backup job on a connector            |
| `Search-KeepitSnapshot`            | Searches backup data using the BSearch API                         |
| `Convert-KeepitUPNToGuid`          | Converts a User Principal Name to Keepit backup GUID               |
| `Enable-KeepitConnector`           | Enables a disabled connector                                       |
| `Disable-KeepitConnector`          | Disables a connector                                               |
| `Submit-KeepitJob`                 | Submits backup/restore jobs with raw XML configuration             |
| `Restore-KeepitBulkDeletedItems`   | Bulk restores deleted email items from Keepit backups              |
| `Start-KeepitExpressRestore`       | Express restore of recent user data by time window (Experimental)  |
| `Get-KeepitAuditLog`               | Retrieves audit log entries with optional date and area filtering  |
| `Get-KeepitShare`                  | Lists all shared secure links for the authenticated user           |
| `New-KeepitShare`                  | Creates a shared secure link with optional password and expiry     |
| `Set-KeepitShare`                  | Updates properties of an existing shared secure link               |
| `Remove-KeepitShare`               | Permanently deletes a shared secure link                           |
| `Get-KeepitUser`                   | Lists all user accounts on the Keepit platform                     |
| `New-KeepitUser`                   | Creates a new Keepit user account with role and connector access   |
| `Remove-KeepitUser`                | Removes a Keepit user account                                      |
| `Get-KeepitRoles`                  | Lists available roles and their capabilities                       |
| `Convert-KeepitGuidToUPN`          | Resolves Keepit backup GUIDs to User Principal Names               |
| `Get-KeepitItemAttributes`         | Retrieves metadata attributes from the snapshot content API        |

## General Examples

All cmdlets support pipeline input and output, allowing you to chain operations together efficiently.

You can use pipelining
with CSV files for operations that take a user principal name or GUID, too, such as `Search-KeepitSnapshot`. However, note that your CSV file must contain a header, and the columm that has the UPN / email address / GUID must have the proper label (e.g. if you are feeding a list of users to a cmdlet using their UPNs, make sure the CSV column with the users has the label of `userPrincipalName`.)

### Get Connection Info

```powershell
# Connect and capture connection information
$connection = Connect-KeepitService -Credential $cred -Environment "us-dc"
$connection | Format-List
```

### Get Latest Snapshots for All Connectors

```powershell
# Pipeline from connectors to snapshots
Get-KeepitConnector | Get-KeepitSnapshot -Latest
```

### Get Snapshot Counts for All Connectors

```powershell
# Get snapshot counts for the last 30 days across all connectors
Get-KeepitConnector | Get-KeepitSnapshot -StartTime (Get-Date).AddDays(-30) -EndTime (Get-Date) -CountOnly
```

### Get Snapshots in a Date Range

```powershell
# Get all snapshots for a specific connector in the last week
Get-KeepitSnapshot -Connector "your-connector-guid" -StartTime (Get-Date).AddDays(-7) -EndTime (Get-Date)
```

### Get Jobs

```powershell
# Get active and future jobs for a specific connector (default behavior)
Get-KeepitJobs -Connector "your-connector-guid"

# Get only active and future backup jobs
Get-KeepitJobs -Connector "your-connector-guid" -Type backup

# Get all jobs (past and future) from the last 7 days
Get-KeepitJobs -Connector "your-connector-guid" -StartTime (Get-Date).AddDays(-7) -EndTime (Get-Date)

# Get all backup jobs from December 2025
Get-KeepitJobs -Connector "your-connector-guid" -Type backup -StartTime "2025-12-01" -EndTime "2025-12-31"

# Get active and future jobs for all connectors via pipeline
Get-KeepitConnector | Get-KeepitJobs

# Get all active restore jobs across all connectors
Get-KeepitConnector | Get-KeepitJobs -Type restore | Where-Object { $_.Active -eq $true }

# Get job details for a specific connector
$jobs = Get-KeepitJobs -Connector "your-connector-guid"
$jobs | Format-Table JobGuid, Type, Active, Scheduled, Start
```

### Start Backup Jobs

```powershell
# Start an immediate backup for a single connector
Start-KeepitBackup -Connector "your-connector-guid"

# Start immediate backups for all connectors via pipeline
Get-KeepitConnector | Start-KeepitBackup

# Start backup and view job details
$job = Start-KeepitBackup -Connector "your-connector-guid"
$job | Format-List ConnectorGuid, Type, Status, CreatedAt, ScheduledTime

# Schedule a backup 30 minutes from now
Start-KeepitBackup -Connector "your-connector-guid" -ScheduledTime (Get-Date).AddMinutes(30)

# Schedule a backup for a specific date and time
Start-KeepitBackup -Connector "Production M365" -ScheduledTime "2026-06-15T14:00:00"
```

**Note:** If a backup job is already queued for a connector, `Start-KeepitBackup` will display a warning and return a status object with `Status = 'AlreadyQueued'` instead of creating a duplicate job.

### Cancel Jobs

```powershell
# Cancel a specific job
Stop-KeepitJob -Connector "your-connector-guid" -JobGuid "job-guid-here"

# Cancel all active and scheduled jobs on a connector
Stop-KeepitJob -Connector "Production M365" -All

# Cancel active jobs via pipeline from Get-KeepitJobs
Get-KeepitJobs -Connector "Production M365" -ActiveOnly | Stop-KeepitJob

# Preview cancellations without actually cancelling
Stop-KeepitJob -Connector "Production M365" -All -WhatIf
```

### Full Pipeline Example

```powershell
# Complete workflow: connect, get connectors, filter, get snapshots
$cred = Get-Credential
Connect-KeepitService -Credential $cred -Environment "us-dc"

Get-KeepitConnector |
    Where-Object { $_.Name -like "*Exchange*" } |
    Get-KeepitSnapshot -Latest |
    Select-Object ConnectorGuid, Timestamp, Type, Size

Disconnect-KeepitService
```

### Filter Connectors by Type

```powershell
# Get only Microsoft 365 connectors
Get-KeepitConnector -Type 'o365-admin'

# Get Microsoft 365 and Dynamics 365 connectors
Get-KeepitConnector -Type 'o365-admin', 'dynamics365'

# Get all Google Workspace connectors
Get-KeepitConnector -Type 'gsuite'

# Include deleted connectors in results
Get-KeepitConnector -IncludeDeleted
```

### Get Connector Configuration and Attributes

```powershell
# Get configuration by connector name
Get-KeepitConnectorConfiguration -Connector "Production M365"

# Get only Exchange workload configuration as a parsed object
Get-KeepitConnectorConfiguration -Connector "Production M365" -Workload Exchange

# Access parsed workload configuration properties
$result = Get-KeepitConnectorConfiguration -Connector "Production M365" -Workload Exchange
$result.Configuration.Exchange.EnabledCategories

# Get configuration and all attributes
Get-KeepitConnectorConfiguration -Connector "your-connector-guid" -Attributes "*"

# Get specific attributes
Get-KeepitConnectorConfiguration -Connector "Production M365" -Attributes "ng_backup_config"

# Get SharePoint coverage (which sites are included/excluded)
Get-KeepitConnectorConfiguration -Connector "Production M365" -Workload SharePoint -Coverage

# Get Exchange coverage (enabled categories and user selection rules)
Get-KeepitConnectorConfiguration -Connector "Production M365" -Workload Exchange -Coverage

# Get Teams coverage (auto-include groups, include/exclude lists)
Get-KeepitConnectorConfiguration -Connector "Production M365" -Workload Teams -Coverage

# Get OneDrive coverage (options and user selection rules)
Get-KeepitConnectorConfiguration -Connector "Production M365" -Workload OneDrive -Coverage
```

#### Workload Parameter

When working with connector configurations, you will often want to use the `-Workload` parameter to filter / parse the configuration by specific workloads, returning a PSCustomObject. Valid workloads vary by connector type:

| Connector Type             | Valid Workloads                                          |
| -------------------------- | -------------------------------------------------------- |
| o365-admin (Microsoft 365) | Exchange (ExO), OneDrive (ODB), SharePoint, Teams        |
| dynamics365                | CRM, PowerApps, PowerAutomate                            |
| azure-ad, powerbi          | Not supported (single config block)                      |
| DSL-based connectors       | Not supported yet                                        |

### Set Connector Configuration

Use the `Set-KeepitConnectorConfiguration` cmdlet to modify connector backup settings. You can either provide a complete JSON configuration (which isn't recomnended) or use parameters to incrementally add/remove sites or groups.

Note that these configuration changes do _not_ affect running backup jobs. If you have the connector configuration dialog open in the Keepit admin center
while running these cmdlets, the cmdlet configuration changes may be overwritten when you click the "Save" button.

**SharePoint site management:**

These parameters require you to specify `-workload SharePoint`. Site URLs must be complete FQDNs. If you specify a site that already exists in the configuration,
e.g. trying to add a site that's already included for backup, that site will be skipped.

```powershell
# Add a SharePoint site to backup
Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload SharePoint -AddIncludedSites "https://contoso.sharepoint.com/sites/Marketing"

# Remove a site from backup
Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload SharePoint -RemoveIncludedSites "https://contoso.sharepoint.com/sites/OldSite"

# Add multiple sites at once
$sites = @("https://contoso.sharepoint.com/sites/HR", "https://contoso.sharepoint.com/sites/Finance")
Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload SharePoint -AddIncludedSites $sites

# Exclude a site from backup
Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload SharePoint -AddExcludedSites "https://contoso.sharepoint.com/sites/Archive"
```

**Teams/Microsoft 365 Groups management:**

These parameters require you to specify `-workload Teams`. You need to provide the Microsoft GUID for the Team/Group object that you want to add or remove.
```powershell
# Exclude a group from Teams backup
Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload Teams -AddExcludedGroups "0aa94c0a-c5e5-417f-8cfa-6744649e25da"

# Remove a group from the exclusion list
Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload Teams -RemoveExcludedGroups "0aa94c0a-c5e5-417f-8cfa-6744649e25da"

# Include specific groups (when AutoIncludeGroups is false)
Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload Teams -AddIncludedGroups "abc123-def456-789012"
```

**Exchange configuration:**

Use `-Workload Exchange` (or the alias `ExO`) to manage Exchange Online backup settings.

```powershell
# Set which Exchange categories to back up
Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload Exchange -EnabledCategories Mail,Calendar,Contacts

# Same command using the ExO alias
Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload ExO -EnabledCategories Mail,Calendar,Contacts,Tasks,InPlaceArchive
```

**Exchange/OneDrive user selection (UserSelectionRules):**

Use these parameters to control which users are included in Exchange or OneDrive backups. Requires `-Workload Exchange` or `-Workload OneDrive` (aliases: `ExO`, `ODB`). All of the group and user arguments accept Entra ID GUIDs, which aren't checked. You can get these
GUIDs by using Graph PowerShell.

```powershell
# Add the 'SSOTest' group to the backup configuration
$groupId = (Get-MgGroup -Filter "DisplayName eq 'SSOTest'").id
Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload Exchange -AddIncludedGroups $groupId

# Include users not in any specified groups
Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload Exchange -AddIncludedCategories UsersNotInGroups

# Remove a user from the exclusion list
Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload Exchange -RemoveExcludedUsers "73e50895-f50f-48a9-b8ec-a09168fa9892"
```

**Preview changes with -WhatIf:**
The `-WhatIf` flag will show you what changes would be made to the configuration but doesn't actually write the changes to the Keepit service. It's a good idea
to use this first to make sure you'll get the expected set of sites/groups in the resulting configuration.

```powershell
# See the configuration that would be written without making changes
Set-KeepitConnectorConfiguration -Connector "Production M365" -Workload SharePoint -AddIncludedSites $sites -WhatIf
```

The cmdlet shows warnings when adding items that already exist or removing items that don't exist, and skips the write if no actual changes were made.

### Create a New Connector

Use `New-KeepitConnector` to create new Keepit connectors programmatically. The cmdlet supports all connector types including Microsoft 365, Dynamics 365, Google Workspace, and DSL-based connectors (Jira, Confluence, etc.).

**Important:** For Microsoft 365 connectors, you must specify the `-OrgLink` parameter to link the connector to your M365 tenant. You can get the OrgLink value from an existing working connector.

```powershell
# Get the OrgLink from an existing connector
$orgLink = (Get-KeepitConnector -Identity "Production M365").OrgLink

# Create a new M365 connector using a configuration file
New-KeepitConnector -ConnectorType o365-admin -Name "New M365 Backup" -OrgLink $orgLink -TemplateFile "./config/m365-config.json"

# Create a connector with inline JSON configuration
$config = '{"Exchange":{"EnabledCategories":["Mail","Calendar"]}}'
New-KeepitConnector -ConnectorType o365-admin -Name "Exchange Only" -OrgLink $orgLink -Configuration $config

# Create a connector with a specific retention period (ISO 8601 duration)
New-KeepitConnector -ConnectorType o365-admin -Name "Short Retention" -OrgLink $orgLink -TemplateFile "./config.json" -RetentionPeriod "P6M"

# Create a DSL-based connector (e.g., Jira)
New-KeepitConnector -ConnectorType jira -Name "Jira Backup" -TemplateFile "./jira-config.json"
```

The cmdlet returns an object with the new connector's GUID, name, type, and retention period. You can pipe this to other cmdlets like `Start-KeepitBackup` to immediately start a backup.

### Search Backup Data

Note that the -SearchTerms parameter allows you to specify fuzzy or exact search terms that are applied _to the item names and metadata_. There is no search for message or attachment _content_.

```powershell
# Search for a user by UPN in the Users folder
Search-KeepitSnapshot -Connector "Entra ID HSV" -RootPath "/Users" -SearchTerms "test01"

# Search for mail messages in a user's Inbox
Search-KeepitSnapshot -Connector "your-connector-guid" -RootPath "/Users/user@example.com/Outlook/Inbox" -ItemType Message

# Search within a date range
Search-KeepitSnapshot -Connector "your-connector-guid" -RootPath "/Users/user@example.com/Outlook" -StartTime "2024-01-01" -EndTime "2024-12-31"
```

### Bulk Restore Deleted Items

```powershell
# Restore deleted email items for a single user
Restore-KeepitBulkDeletedItems -UserPrincipalName "user@example.com" -Connector "your-connector-guid" -RootPath "Inbox" -StartTime "2024-01-01" -EndTime "2024-12-31"

# Restore only deleted items matching a sender or recipient
Restore-KeepitBulkDeletedItems -UserPrincipalName "user@example.com" -Connector "your-connector-guid" -RootPath "Inbox" -StartTime "2024-01-01" -EndTime "2024-12-31" -SearchTerms '"ceo@example.com"'

# Restore deleted items for multiple users from a CSV file
# CSV should have columns like UPN, Email, or UserPrincipalName
Import-Csv users.csv | Restore-KeepitBulkDeletedItems -Connector "your-connector-guid" -RootPath "Inbox" -StartTime "2024-01-01" -EndTime "2024-12-31"

# Restore deleted OneDrive files for a user
Restore-KeepitBulkDeletedItems -UserPrincipalName "user@example.com" -Connector "your-odb-connector" -RootPath "OneDrive" -Type OneDrive -StartTime "2024-01-01" -EndTime "2024-12-31" -Recursive

# Preview what would be restored without actually restoring
Restore-KeepitBulkDeletedItems -UserPrincipalName "user@example.com" -Connector "your-connector-guid" -RootPath "Deleted Items" -StartTime (Get-Date).AddDays(-30) -EndTime (Get-Date) -WhatIf
```

### Express Restore (Experimental)

The `Start-KeepitExpressRestore` cmdlet provides a streamlined way to restore a subset of recent user data from Keepit backups. During a disaster
recovery, you might want to give selected users fast access to, say, 3 days of mail first, then backfill their mailboxes with older mail. 
Instead of manually selecting items and submitting restore jobs, or restoring entire mailboxes, you specify a time window and the cmdlet handles item discovery, snapshot grouping, and job submission automatically.

Express restore searches by the source-system received date (when Exchange received the email) rather than by Keepit snapshot time, so it finds items regardless of which snapshot they ended up in.

Consider a disaster that happened on 2026-02-23. You want to quickly recover mail for your CEO for the preceding 3-day period:

```powershell
Start-KeepitExpressRestore -UserPrincipalName "ceo@example.com" -Connector "Production M365" -Workload Exchange -Timespan "P3D" -StartTime "2026-02-23"
```

The `-StartTime` parameter sets the end of the restore window (defaults to now). Items received between `(StartTime - Timespan)` and `StartTime` are restored.

As with many other cmdlets, the `-WhatIf` switch will show you what the cmdlet _would_ do so you can judge whether it will restore the desired data.

You may provide a set of UPNs as a pipeline for batch processing.

The `-PrioritizeCalendar` switch will create a separate, higher-priority, job to restore calendar data first; this is a common request for DR for
executives.

For now, this cmdlet doesn't restore items in subfolders, and it doesn't yet support restores in OneDrive. Both are planned.

### View Audit Logs

```powershell
# Get the last 100 audit log entries (default)
Get-KeepitAuditLog

# Get up to 500 audit log entries
Get-KeepitAuditLog -ResultSize 500

# Get audit logs from the last 7 days
Get-KeepitAuditLog -StartTime (Get-Date).AddDays(-7) -EndTime (Get-Date)

# Get only backup/restore related audit entries
Get-KeepitAuditLog -Area 'Backup/Restore' -ResultSize 50

# Get audit logs and filter for specific actions
Get-KeepitAuditLog -ResultSize 200 | Where-Object { $_.Message -like "*restore*" }
```

### Manage Shared Links

```powershell
# List all shared links
Get-KeepitShare

# Find password-protected shares
Get-KeepitShare | Where-Object { $_.HasPassword -eq $true }

# Create an unprotected share for a user's backup folder
New-KeepitShare -Connector "Production M365" -Path "/user@example.com/"

# Create a share with a 30-day expiry
New-KeepitShare -Connector "Production M365" -Path "/user@example.com/" -Lifetime "P30D"

# Create a password-protected share
$pw = Read-Host -AsSecureString "Share password"
New-KeepitShare -Connector "Production M365" -Path "/data/report.pdf" -Password $pw

# Update a share's lifetime
Set-KeepitShare -ShareId "abc123-def456" -Lifetime "P7D"

# Remove password protection from a share
Set-KeepitShare -ShareId "abc123-def456" -ClearPassword

# Delete a specific share
Remove-KeepitShare -ShareId "abc123-def456"

# Delete all shares for a specific connector
Get-KeepitShare | Where-Object ConnectorGuid -eq $guid | Remove-KeepitShare

# Preview deletions without actually deleting
Get-KeepitShare | Remove-KeepitShare -WhatIf
```

### Manage Users

```powershell
# List all users
Get-KeepitUser

# List users in a table
Get-KeepitUser | Format-Table UserName, Acl, PrimaryToken

# List available roles and their capabilities
Get-KeepitRoles

# Show capabilities for a specific role
Get-KeepitRoles | Where-Object Name -eq 'BackupAdmin' | Select-Object -ExpandProperty Capabilities

# Create a new user with BackupAdmin role and access to all connectors
New-KeepitUser -Name "Jane Doe" -Email "jane@example.com" -Role BackupAdmin -Connectors all

# Create a user with access to specific connectors only
New-KeepitUser -Name "John Smith" -Email "john@example.com" -Role StandardSupport -Connectors "Production M365", "Entra ID"

# Create a user and send an activation email
New-KeepitUser -Name "New Admin" -Email "newadmin@example.com" -Role MasterAdmin -Connectors all -SendActivationEmail

# Remove a user (prompts for confirmation)
Remove-KeepitUser -Identity "jane@example.com"

# Remove a user without confirmation prompt
Remove-KeepitUser -Identity "jane@example.com" -Confirm:$false

# Preview removal without actually removing
Remove-KeepitUser -Identity "jane@example.com" -WhatIf
```

## Example Scripts

The `Examples/` directory contains standalone PowerShell scripts that demonstrate common workflows using the KeepitTools module.

### GroupSync — Copy-EntraGroupToKeepit.ps1

Connects to Microsoft Entra ID, expands the transitive membership of a security or distribution group (including nested groups), and creates each member as a Keepit user with a specified role and connector access. Supports `-WhatIf` to preview changes without creating any users.

```powershell
# Create all members of an Entra group as BackupAdmins with access to all connectors
$kCred = Get-Credential
.\Examples\GroupSync\Copy-EntraGroupToKeepit.ps1 `
    -GroupName "Keepit Admins" `
    -KeepitCredential $kCred `
    -Environment "us-dc" `
    -Connectors "all" `
    -Role "BackupAdmin" `
    -SendActivationEmail
```

See `Examples/GroupSync/README.md` for full parameter reference and examples.

## Searching snapshots

The `Search-KeepitSnapshot` cmdlet allows you to search a set of snapshots looking for items that match your search criteria. This doesn't do a full-text content search, but it does allow you to quickly find deleted items, or to enumerate items in a snapshot. For example, if you want to know what mailboxes were backed up ins the most recent snapshot you can do this:

```
# get the time of the most recent snapshot from the desired connector
Get-KeepitSnapshot -connector "ExO Only" -StartTime 2026-01-13 -EndTime 2026-01-13 -Reverse -ResultSize 1

Id            : 464eb1bee279152deadbeef7d06de5439172d1258008553fd247f75671a6636f
Timestamp     : 2026-01-12T08:07:10Z
Type          : c
Size          : 3774744689677
Account       : abcdef-04223f-abcdef
ConnectorGuid : zwu9lv-pdq123-abcdef
ConnectorName : ExO Only

# use the timestamp value to limit the search
Search-KeepitSnapshot -connector "ExO Only" -pathroot "/Users" -recursive:$false -starttime 2026-01-12T23:27:46Z -endtime 2026-01-12T23:27:46Z | ft title

Title
-----
02Test User - test02@blackdotpub.com
Admin - Admin@blackdotpub.com
...
Tom Robichaux - tom@blackdotpub.com
```
It's important to note that when you're specifying a search path, *the trailing slash matters*. Using a RootPath of "/Users", for example, on a OneDrive connector won't find anything. Using "/Users/" will find what you're looking for. This is a result of the way bsearch is implemented.

## Restoring items in bulk

Restoring items in bulk works slightly differently depending on whether you're restoring Entra users, OneDrive files, or email. In all cases, it's important to understand that _only deleted items will be restored_, and they will be restored _only to their original location_. The Keepit platform tags deleted items with a special label; when you click the "Deleted Items" button in the Keepit admin center's snapshot viewer, you're toggling this view.

### A note about CSV files

CSV files are always supposed to have a header that specifies the names of the columns. All of the Keepit PowerShell tools that can use CSV files require this header. A simple CSV file to specify 3 users would thus look like this:

```
userPrincipalName
user1@example.com
user2@example.com
user3@example.com
```

### Restoring deleted email

Here's a simple example of bulk-restoring deleted mail for a single user:

```
Restore-KeepitBulkDeletedItems -connector "ExO Only" -UserPrincipalName paulr@blackdotpub.com `
  -StartTime 2026-01-10 -EndTime 2026-01-13 -RootPath "Inbox"
```

That tells the tool to find deleted email messages in the Inbox folder of the user `paulr@blackdotpub.com` that were deleted between midnight 10th January and midnight 13th January (that is, from 00:00Z on 10/01 until 23:59Z on 13/01). To restore messages in any folder below the Inbox, you would add the `-recursive` switch. But if you only wanted to restore messages in the "Travel" folder under Inbox, you wouldn't use `-recursive`; instead, you'd use `-RootPath Inbox\Travel`.

You can use pipelining to fill the `-UserPrincipalName` value. If you wanted to restore all email deleted from the Inbox for a set of users, you'd create a CSV file containing their addresses and then do something like this:

```
Import-CSV ./usersToRestore.csv | Restore-KeepitBulkDeletedItems -Connector "ExO Only" -rootPath "Inbox" -startTime 2026-01-01 -endTime 2026-01-10
```

You can also use the `-SearchTerms` parameter to narrow the restore to items matching specific metadata (sender, recipient, or subject line). This uses the same server-side bsearch filtering as `Search-KeepitSnapshot`. Use quoted strings for exact match:

```
Restore-KeepitBulkDeletedItems -Connector "ExO Only" -UserPrincipalName paulr@blackdotpub.com `
  -RootPath "Inbox" -StartTime 2026-01-10 -EndTime 2026-01-13 -SearchTerms '"ceo@blackdotpub.com"'
```

When `-SearchTerms` is omitted, all deleted items in the date range are restored.

### Restoring deleted files
Currently OneDrive restores require you to specify the `-Type OneDrive` flag as well as a `RootPath` value. Due to a change in the way Microsoft creates OneDrives, older Keepit snapshots will have user OneDrive documents stored at a path of `/Users/_guid_/OneDrive/Documents`, but newer snapshots will use a path of `/Users/_guid_/OneDriveSP/DocLibs/Documents/Content`. The cmdlet is smart enough to use the new-style path if it doesn't find any deleted items at the old-style path _if you specify it_. It's probably best to default to use `-RootPath /OneDrive/` and let the cmdlet figure out what to do.

Here's an example of finding what files would be restored from a user:

```
restore-keepitbulkdeleteditems -UserPrincipalName orphan01@blackdotpub.com -connector "PSTools ODB" -RootPath "/OneDrive/" `
   -StartTime 2026-01-01 -EndTime 2026-01-13T18:00 -whatif -Type onedrive
WARNING: Search-KeepitSnapshot: No matching results found
WhatIf: Would restore 2 items in 1 restore job(s)
  Snapshot 2026-01-13T16:49:10Z : 2 items
    + Change Log 2026 Edition.docx
    + Production tracking.xlsx

TotalItems JobCount ItemsBySnapshot
---------- -------- ---------------
         2        1 {[2026-01-13T16:49:10Z, 2]}
```
The extra "WARNING" message is Search-KeepitSnapshot saying it didn't find anything at the original /OneDrive/ path; this is expected. In this case, the tool found 2 deleted files that were deleted within a single snapshot period, so they could be restored in a single job. To actually restore them, you'd run the same cmdlet again without the `-WhatIf` switch.         


