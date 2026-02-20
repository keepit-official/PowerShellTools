# EverCovered.ps1

Produces a CSV report of every mailbox user that has ever had Exchange data
backed up on a Keepit Microsoft 365 connector — including users who have since
been removed from the backup scope. You could easily extend or modify this to 
provide a similar report for OneDrive usage.

## How it works

The script performs four BSearch API calls against the connector:

1. **Active Outlook folders** — users currently in backup scope
2. **Deleted Outlook folders** — users previously backed up but since removed

For each user found, it resolves the internal Keepit GUID back to a UPN using
`Convert-KeepitGuidToUPN` (two additional BSearch calls, regardless of user
count). Results are written to a CSV sorted by `LastSeenDate` descending.

## Prerequisites

- PowerShell 7+
- KeepitTools module v1.2.0+ (either present at `../../src/KeepitTools.psd1` or
  installed in the PowerShell module path).

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `Environment` | Yes | Keepit data center region (e.g. `ws.keepit`, `us-dc`, `uk-ld`) |
| `Credential` | No | PSCredential for the Keepit service; prompts if omitted |
| `Connector` | No | Name or GUID of an o365-admin connector; prompts with a list if omitted |
| `OutputPath` | No | Full path for the CSV output file; defaults to `EverCovered-<ConnectorName>-<yyyy-MM-dd>.csv` in the current directory |

## Output

CSV file with one row per user:

| Column | Description |
|---|---|
| `UserGUID` | Keepit internal GUID (path-masked format) |
| `UserUPN` | User Principal Name resolved from the GUID; blank if resolution fails |
| `LastSeenDate` | Timestamp of the most recent backup in which the user appeared |

## Examples

```powershell
# Interactive: prompts for credentials and connector selection
.\EverCovered.ps1 -Environment us-dc
```

```powershell
# Non-interactive: all parameters supplied
$cred = Get-Credential
.\EverCovered.ps1 -Environment us-dc `
    -Connector "Production M365" `
    -Credential $cred `
    -OutputPath C:\Reports\ever-covered.csv
```

```powershell
# Pipe the output into further processing
Import-Csv .\EverCovered-Production-M365-2026-02-20.csv |
    Where-Object { $_.UserUPN -like "*@contoso.com" } |
    Select-Object UserUPN, LastSeenDate
```

## Notes

- A user is included only if an Outlook folder is (or was) present in their
  backup path. Users backed up for other workloads only (e.g. OneDrive, Teams)
  will not appear.
- `LastSeenDate` reflects the `Updated` timestamp from the BSearch API, which
  represents the last backup in which the user's Outlook folder was recorded.
- If UPN resolution fails for one or more users, a warning is written and the
  report still completes; affected rows will have a blank `UserUPN`.
