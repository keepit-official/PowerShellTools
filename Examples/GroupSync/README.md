# Copy-EntraGroupToKeepit.ps1

This script accepts an Entra security or distribution group name or GUID, connects to
Entra ID, and recursively resolves its membership into a flat list of users. It then
creates each user in Keepit with the specified role and connector access.

## Prerequisites

- PowerShell 7+
- Microsoft.Graph.Groups module: `Install-Module Microsoft.Graph.Groups`
- KeepitTools module (present at `../../src/KeepitTools.psd1`)

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `GroupName` | Yes | Display name or GUID of the Entra group to expand |
| `KeepitCredential` | Yes | Credential for the Keepit service |
| `Environment` | Yes | Keepit data center (e.g. `ws.keepit`, `us-dc`, `uk-ld`) |
| `Connectors` | Yes | `"all"` or one or more connector names/GUIDs |
| `Role` | Yes | Keepit role: `BackupAdmin`, `MasterAdmin`, `FullSupport`, `StandardSupport`, `ComplianceAdmin`, `LimitedSupport`, `Audit`, `SsoAdmin` |
| `EntraCredential` | No | Credential for Microsoft Graph; omit to use browser auth |
| `SendActivationEmail` | No | Send an activation email to each newly created user |
| `NotificationsEnabled` | No | Enable email notifications for each newly created user |

## Output

One `PSCustomObject` per group member attempted:

| Property | Description |
|---|---|
| `Email` | User's email / UPN |
| `Name` | User's display name |
| `Status` | `Created`, `AlreadyExists`, or `Failed` |
| `Error` | Error message when `Status` is `Failed`; otherwise `$null` |

## Examples

```powershell
# Browser auth for Entra, all connectors
$kCred = Get-Credential
.\Copy-EntraGroupToKeepit.ps1 `
    -GroupName "Keepit Admins" `
    -KeepitCredential $kCred `
    -Environment "us-dc" `
    -Connectors "all" `
    -Role "BackupAdmin" `
    -SendActivationEmail
```

```powershell
# Credential-based Entra auth, specific connectors, capture results
$eCred = Get-Credential
$kCred = Get-Credential
$results = .\Copy-EntraGroupToKeepit.ps1 `
    -GroupName "a1b2c3d4-1234-1234-1234-a1b2c3d4e5f6" `
    -EntraCredential $eCred `
    -KeepitCredential $kCred `
    -Environment "ws.keepit" `
    -Connectors "M365 Prod", "Exchange" `
    -Role "LimitedSupport"

$results | Format-Table -AutoSize
```
