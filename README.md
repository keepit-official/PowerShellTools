# Keepit PowerShell Tools

## Description

This project covers building a self-contained PowerShell module containing cmdlets that allow an administrator to connect to the Keepit service and perform various tasks. It is based on the structure of the Bohr and Keepit MCP tools, and is meant to provdie an alternative for customers who can't or don't want to run MCP tooling.

In addition, this module provides cmdlets to perform restores of large numbers of deleted email items. It uses the Keepit platform API to find items matching the search criteria, identify what Keepit snapshots they are in, collect items in the same snapshot into restore jobs (a process known as "coalescing" the jobs), and then submits the jobs for action.

## Requirements

- PowerShell 7.0 or later on Windows, macOS, and Linux

## Installation and Usage

### Installation

The module can be installed by copying the module files to a PowerShell module path or by importing directly from the source directory. (it will eventually be in the PowerShell gallery!)

> **Note:** `Install-Module` only works with modules published to PowerShell repositories (like the PowerShell Gallery). For local module files, use `Import-Module` or manually copy to your module path as shown below.

#### Option 1: Import from Source Directory

This is the recommended method for development and testing:

```powershell
# Import the module from the src directory
Import-Module ./src/KeepitTools.psd1 -Force

# Verify the module is loaded
Get-Module KeepitTools
```

#### Option 2: Install to User Module Path

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
# Create module directory
$modulePath = "~/.local/share/powershell/Modules/KeepitTools"
New-Item -ItemType Directory -Path $modulePath -Force

# Copy module files
Copy-Item -Path ./src/* -Destination $modulePath -Recurse

# Import the module
Import-Module KeepitTools
```

### Verifying Installation

After importing the module, verify that all cmdlets are available:

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
$cred = Get-Credential
Connect-KeepitService -Credential $cred -Environment "us-dc"

# OR connect using username and password
$password = Read-Host "Enter password" -AsSecureString
Connect-KeepitService -UserName "admin@example.com" -Password $password -Environment "us-dc"

# Get all O365 connectors
$connectors = Get-KeepitConnector
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

| Cmdlet | Description |
|--------|-------------|
| `Connect-KeepitService` | Establishes authenticated connection to Keepit platform |
| `Disconnect-KeepitService` | Closes connection and clears cached credentials |
| `Get-KeepitConnector` | Retrieves accessible connectors, optionally filtered by type |
| `Get-KeepitConnectorConfiguration` | Retrieves connector configuration and custom attributes |
| `Get-KeepitSnapshot` | Retrieves snapshot information (latest, range, or count) |
| `Get-KeepitJobs` | Retrieves active and future backup/restore jobs for a connector |
| `Start-KeepitBackup` | Starts immediate or scheduled backup job on a connector |
| `Search-KeepitSnapshot` | Searches backup data using the BSearch API |
| `Convert-KeepitUPNToGuid` | Converts a User Principal Name to Keepit backup GUID |
| `Enable-KeepitConnector` | Enables a disabled connector |
| `Disable-KeepitConnector` | Disables a connector |
| `Submit-KeepitJob` | Submits backup/restore jobs with raw XML configuration |
| `Restore-KeepitBulkDeletedItems` | Bulk restores deleted email items from Keepit backups |

## Examples

All cmdlets support pipeline input and output, allowing you to chain operations together efficiently.

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
Get-KeepitConnector | Get-KeepitSnapshot -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) -CountOnly
```

### Get Snapshots in a Date Range

```powershell
# Get all snapshots for a specific connector in the last week
Get-KeepitSnapshot -Connector "your-connector-guid" -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date)
```

### Get Jobs

```powershell
# Get active and future jobs for a specific connector (default behavior)
Get-KeepitJobs -Connector "your-connector-guid"

# Get only active and future backup jobs
Get-KeepitJobs -Connector "your-connector-guid" -Type backup

# Get all jobs (past and future) from the last 7 days
Get-KeepitJobs -Connector "your-connector-guid" -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date)

# Get all backup jobs from December 2025
Get-KeepitJobs -Connector "your-connector-guid" -Type backup -StartDate "2025-12-01" -EndDate "2025-12-31"

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
$job | Format-List JobGuid, Type, Status, Scheduled
```

**Note:** If a backup job is already queued for a connector, `Start-KeepitBackup` will display a warning and return a status object with `Status = 'AlreadyQueued'` instead of creating a duplicate job.

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
```

### Get Connector Configuration and Attributes

```powershell
# Get configuration for a specific connector by GUID
Get-KeepitConnectorConfiguration -Connector "your-connector-guid"

# Get configuration by connector name
Get-KeepitConnectorConfiguration -Connector "Production M365"

# Get configuration and all attributes
Get-KeepitConnectorConfiguration -Connector "your-connector-guid" -Attributes "*"

# Get specific attributes
Get-KeepitConnectorConfiguration -Connector "Production M365" -Attributes "ng_backup_config,backup_config"

# Get attributes for connectors that don't support default configuration
Get-KeepitConnector -Type 'gsuite' | Get-KeepitConnectorConfiguration -Attributes "*"
```

### Search Backup Data

```powershell
# Search for a user by UPN in the Users folder
Search-KeepitSnapshot -Connector "Entra ID HSV" -PathRoot "/Users" -SearchTerms "test01"

# Search for mail messages in a user's Inbox
Search-KeepitSnapshot -Connector "your-connector-guid" -PathRoot "/Users/user@example.com/Outlook/Inbox" -ItemType Message

# Search within a date range
Search-KeepitSnapshot -Connector "your-connector-guid" -PathRoot "/Users/user@example.com/Outlook" -StartTime "2024-01-01" -EndTime "2024-12-31"
```

### Convert UPN to Keepit GUID

```powershell
# Look up a user's Keepit GUID by their email address
Convert-KeepitUPNToGuid -UserPrincipalName "user@example.com" -Connector "your-connector-guid"

# Look up GUIDs for multiple users via pipeline
"user1@example.com", "user2@example.com" | Convert-KeepitUPNToGuid -Connector "your-connector-guid"

# Look up GUIDs from a CSV file (with UPN, Email, or UserPrincipalName column)
Import-Csv users.csv | Convert-KeepitUPNToGuid -Connector "your-connector-guid"

# Use the GUID in a search path
$user = Convert-KeepitUPNToGuid -UserPrincipalName "user@example.com" -Connector "your-connector-guid"
Search-KeepitSnapshot -Connector "your-connector-guid" -PathRoot "/Users/$($user.Guid)/Outlook/Inbox"
```

### Bulk Restore Deleted Items

```powershell
# Restore deleted items for a single user
Restore-KeepitBulkDeletedItems -UserPrincipalName "user@example.com" -Connector "your-connector-guid" -RootPath "Inbox" -StartDate "2024-01-01" -EndDate "2024-12-31"

# Restore deleted items for multiple users from a CSV file
# CSV should have columns like UPN, Email, or UserPrincipalName
Import-Csv users.csv | Restore-KeepitBulkDeletedItems -Connector "your-connector-guid" -RootPath "Inbox" -StartDate "2024-01-01" -EndDate "2024-12-31"

# Preview what would be restored without actually restoring
Restore-KeepitBulkDeletedItems -UserPrincipalName "user@example.com" -Connector "your-connector-guid" -RootPath "Deleted Items" -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) -WhatIf
```

## Design principles

The code and artifacts in this project should be designed and built using the following principles.

* This project uses the Keepit APIs described in the "api-endpoints.md" file.
* This project will be structured as a [PowerShell script module](https://learn.microsoft.com/en-us/powershell/scripting/developer/module/how-to-write-a-powershell-script-module?view=powershell-7.5) that can be packaged and installed as a single unit.
* It will contain multiple PowerShell [cmdlets](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/cmdlet-overview?view=powershell-7.5).
* The project code itself will be written in PowerShell, using only constructs and assemblies that can be loaded and run on Linux, macOS, and Windows.
* Follow the [Microsoft required development guidelines for all PowerShell cmdlets](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/required-development-guidelines?view=powershell-7.5).
* This project follows the [Microsoft recommended guidelines](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/strongly-encouraged-development-guidelines?view=powershell-7.5) for all PowerShell cmdlets.
* This project follows the [Microsoft advisory guidelines](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/advisory-development-guidelines?view=powershell-7.5) for all PowerShell cmdlets.
* All cmdlets use structured exception handling.
* All cmdlets have correct and complete help that works with _Get-Help_.

## implementation considerations

* Because the Keepit API uses basic HTTP authentication, each API call must include an authentication header that contains the global "Auth" string created when Connect-KeepitService is run.

