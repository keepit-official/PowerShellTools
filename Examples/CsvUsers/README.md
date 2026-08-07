# New-KeepitUsersFromCsv.ps1

This script imports a CSV of fake/test identities (GivenName, Surname, and related
profile fields — no email column) and creates a Keepit **LimitedSupport** user for
each row. Since the CSV has no email/UPN column, one is synthesized from
`GivenName.Surname@<EmailDomain>`; duplicates are disambiguated with a numeric suffix.

Intended for populating a test Keepit account with a large number of low-privilege
users, e.g. for load or UI testing.

## Prerequisites

- PowerShell 7+
- KeepitTools module (present at `../../src/KeepitTools.psd1`)

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `CsvPath` | Yes | Path to the CSV file; must contain `GivenName` and `Surname` columns |
| `EmailDomain` | Yes | Domain to append to the synthesized email, e.g. `keepithybrid.com` (no `@`) |
| `KeepitCredential` | Yes | Credential for the Keepit service |
| `Environment` | Yes | Keepit data center (e.g. `ws.keepit`, `us-dc`, `uk-ld`) |
| `Connectors` | Yes | `"all"` or one or more connector names/GUIDs |
| `SendActivationEmail` | No | Send an activation email to each newly created user |
| `NotificationsEnabled` | No | Enable email notifications for each newly created user |
| `Skip` | No | Skip the first N rows before processing — applied before `First` |
| `First` | No | Only process the first N remaining rows — useful for a smoke test |
| `ThrottleMilliseconds` | No | Delay between creations, in ms (default `100`) |

## Output

One `PSCustomObject` per CSV row attempted:

| Property | Description |
|---|---|
| `Email` | Synthesized email / UPN |
| `Name` | `GivenName Surname` |
| `Status` | `Created`, `AlreadyExists`, `Failed`, or `WhatIf` |
| `Error` | Error message when `Status` is `Failed`; otherwise `$null` |

## Examples

```powershell
# Smoke-test with the first 10 rows before running the full file
$kCred = Get-Credential
.\New-KeepitUsersFromCsv.ps1 `
    -CsvPath /Users/pro/source/keepit/SE-CS/entrabulk/csv/FakeCloudUsers.csv `
    -EmailDomain "keepithybrid.com" `
    -KeepitCredential $kCred `
    -Environment "ws-test" `
    -Connectors "all" `
    -First 10
```

```powershell
# Full import, capture results
$kCred = Get-Credential
$results = .\New-KeepitUsersFromCsv.ps1 `
    -CsvPath /Users/pro/source/keepit/SE-CS/entrabulk/csv/FakeCloudUsers.csv `
    -EmailDomain "keepithybrid.com" `
    -KeepitCredential $kCred `
    -Environment "ws-test" `
    -Connectors "all"

$results | Group-Object Status | Select-Object Name, Count
```

```powershell
# Resume an import, processing rows 501-1000 of the CSV
$kCred = Get-Credential
.\New-KeepitUsersFromCsv.ps1 `
    -CsvPath /Users/pro/source/keepit/SE-CS/entrabulk/csv/FakeCloudUsers.csv `
    -EmailDomain "keepithybrid.com" `
    -KeepitCredential $kCred `
    -Environment "ws-test" `
    -Connectors "all" `
    -Skip 500 -First 500
```
