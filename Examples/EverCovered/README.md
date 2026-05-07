# EverCovered Scripts

Two scripts for reporting what has ever been backed up on Keepit Microsoft 365
connectors — including items and users that have since been removed from the
backup scope.

---

## EverCovered-Mailboxes.ps1

Produces a CSV report of every mailbox user that has ever had Exchange data
backed up on a Keepit Microsoft 365 connector.

### How it works

The script performs two BSearch API calls against the connector:

1. **Active Outlook folders** — users currently in backup scope
2. **Deleted Outlook folders** — users previously backed up but since removed

For each user found, it resolves the internal Keepit GUID back to a UPN using
`Convert-KeepitGuidToUPN` (two additional BSearch calls, regardless of user
count). Results are written to a CSV sorted by `LastSeenDate` descending.

### Prerequisites

- PowerShell 7+
- KeepitTools module v1.2.0+ (either present at `../../src/KeepitTools.psd1` or
  installed in the PowerShell module path).

### Parameters

| Parameter     | Required | Description                                                                                             |
|---------------|----------|---------------------------------------------------------------------------------------------------------|
| `Environment` | Yes      | Keepit data center region (e.g. `ws.keepit`, `us-dc`, `uk-ld`)                                          |
| `Credential`  | No       | PSCredential for the Keepit service; prompts if omitted                                                 |
| `Connector`   | No       | Name or GUID of an o365-admin connector; prompts with a list if omitted                                 |
| `OutputPath`  | No       | Full path for the CSV output file; defaults to `EverCovered-<ConnectorName>-<yyyy-MM-dd>.csv`           |

### Output

CSV file with one row per user:

| Column        | Description                                                                    |
|---------------|--------------------------------------------------------------------------------|
| `UserGUID`    | Keepit internal GUID (path-masked format)                                      |
| `UserUPN`     | User Principal Name resolved from the GUID; blank if resolution fails          |
| `LastSeenDate`| Timestamp of the most recent backup in which the user appeared                 |

### Examples

```powershell
# Interactive: prompts for credentials and connector selection
.\EverCovered-Mailboxes.ps1 -Environment us-dc
```

```powershell
# Non-interactive: all parameters supplied
$cred = Get-Credential
.\EverCovered-Mailboxes.ps1 -Environment us-dc `
    -Connector "Production M365" `
    -Credential $cred `
    -OutputPath C:\Reports\ever-covered.csv
```

```powershell
# Pipe the output into further processing
Import-Csv .\EverCovered-Mailboxes-Production-M365-2026-02-20.csv |
    Where-Object { $_.UserUPN -like "*@contoso.com" } |
    Select-Object UserUPN, LastSeenDate
```

### Notes

- A user is included only if an Outlook folder is (or was) present in their
  backup path. Users backed up for other workloads only (e.g. OneDrive, Teams)
  will not appear.
- `LastSeenDate` reflects the `Updated` timestamp from the BSearch API, which
  represents the last backup in which the user's Outlook folder was recorded.
- If UPN resolution fails for one or more users, a warning is written and the
  report still completes; affected rows will have a blank `UserUPN`.

---

## EverCovered-Sites.ps1

Produces a CSV report of every SharePoint site collection that has ever had
data backed up across one or all Keepit Microsoft 365 connectors.

### How it works

Two BSearch API calls are made per connector:

1. **Active sites** — site collections currently in backup scope
2. **Deleted sites** — site collections previously backed up but since removed

When scanning multiple connectors, results are deduplicated by site URL.
`Active` status always takes precedence over `Removed` for the same site;
for the same status, the most recent timestamp wins. The `Connector` column
records which connector provided the authoritative data for each site.

The script reuses an existing `Connect-KeepitService` session when one is
present, so no credentials are needed if you are already connected.

### Prerequisites

- PowerShell 7+
- KeepitTools module v1.3.3+ (either present at `../../src/KeepitTools.psd1` or
  installed in the PowerShell module path).

### Parameters

| Parameter     | Required                        | Description                                                                                                                                   |
|---------------|---------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------|
| `Environment` | Only when not already connected | Keepit data center region (e.g. `ws.keepit`, `us-dc`, `uk-ld`). Ignored when an active session already exists.                                |
| `Credential`  | No                              | PSCredential for the Keepit service; prompts if not connected and omitted. Ignored when an active session already exists.                     |
| `Connector`   | No                              | Name or GUID of a single o365-admin connector. If omitted, all o365-admin connectors in the tenant are scanned and results are deduplicated.  |
| `OutputPath`  | No                              | Full path for the CSV output file; defaults to `EverCovered-Sites-All-<date>.csv` or `EverCovered-Sites-<ConnectorName>-<date>.csv`.          |

### Output

CSV file with one row per unique site URL:

| Column        | Description                                                                                        |
|---------------|----------------------------------------------------------------------------------------------------|
| `SiteName`    | Display name of the site from the backup index                                                     |
| `SiteURL`     | Full SharePoint site URL                                                                           |
| `LastSeenDate`| Timestamp of the most recent backup in which this site appeared                                    |
| `Status`      | `Active` — currently in backup scope; `Removed` — previously backed up but no longer in scope      |
| `Connector`   | Name of the connector that provided the most recent (or authoritative) data for this site          |

### Examples

```powershell
# Connect and scan all M365 connectors in the tenant
.\EverCovered-Sites.ps1 -Environment us-dc
```

```powershell
# Connect with explicit credentials and scan all connectors
$cred = Get-Credential
.\EverCovered-Sites.ps1 -Environment us-dc -Credential $cred
```

```powershell
# Reuse an existing session and scope to a single connector
.\EverCovered-Sites.ps1 -Connector "Production M365" -OutputPath C:\Reports\sp.csv
```

```powershell
# Filter the output to show only removed sites
Import-Csv .\EverCovered-Sites-All-2026-05-07.csv |
    Where-Object { $_.Status -eq 'Removed' } |
    Select-Object SiteURL, LastSeenDate, Connector
```

### Notes

- Sites are deduplicated by URL (case-insensitive) across connectors. If a site
  appears on multiple connectors, `Active` always wins over `Removed` regardless
  of timestamp.
- `LastSeenDate` reflects the `Updated` timestamp from the BSearch API.
- Sites that appear in neither active nor deleted results for any connector will
  not appear in the report.
