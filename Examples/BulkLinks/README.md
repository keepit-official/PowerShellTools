# New-BulkShareLinks.ps1

Creates personalized Keepit secure shared links for multiple
users and exports the results to a CSV file. Designed for
large-scale disaster recovery scenarios where an admin needs
to give every user a direct link to their own mailbox,
OneDrive, or both.

## Prerequisites

- PowerShell 7.0 or later (Linux, macOS, or Windows)
- The KeepitTools module loaded and connected:

```powershell
Import-Module ./src/KeepitTools.psd1
Connect-KeepitService -Region US-DC -Credential (Get-Credential)
```

## Parameters

| Parameter            | Required | Description              |
|----------------------|----------|--------------------------|
| `-UserPrincipalName` | Yes      | UPN(s) to create links   |
| `-Connector`         | Yes      | Connector name or GUID   |
| `-OutputPath`        | Yes      | Path to output CSV file  |
| `-Workload`          | No       | `Exchange`, `OneDrive`,  |
|                      |          | or `Both` (default)      |
| `-Password`          | No       | SecureString for links   |
| `-Lifetime`          | No       | ISO 8601 duration, e.g., |
|                      |          | `P30D` for 30 days       |

## Pipeline input

The `-UserPrincipalName` parameter accepts pipeline input
in two forms:

- **Bare strings** piped directly
  (e.g., from `Get-Content`)
- **Objects with a `UserPrincipalName` property**
  (e.g., from `Import-Csv` or `Get-Mailbox`)

## Workload paths

The `-Workload` parameter controls what each share link
points to:

| Workload   | Share path               | User sees     |
|------------|--------------------------|---------------|
| `Exchange` | `/Users/{guid}/Outlook/` | Mailbox       |
| `OneDrive` | `/Users/{guid}/OneDrive/`| OneDrive      |
| `Both`     | `/Users/{guid}/`         | All workloads |

## Snapshot pinning

All share links are pinned to the latest snapshot at the
time the script runs. This ensures every user receives a
link to the same point-in-time backup, which is critical
for disaster recovery consistency.

## Examples

### Exchange share links for a few users

```powershell
"user1@contoso.com", "user2@contoso.com" |
    ./app/New-BulkShareLinks.ps1 `
        -Connector "Production M365" `
        -Workload Exchange `
        -OutputPath "./share-links.csv"
```

### Links from a CSV with a UserPrincipalName column

```powershell
Import-Csv ./users.csv |
    ./app/New-BulkShareLinks.ps1 `
        -Connector "Production M365" `
        -OutputPath "./share-links.csv" `
        -Lifetime "P30D"
```

The input CSV must have a `UserPrincipalName` column:

```csv
UserPrincipalName
user1@contoso.com
user2@contoso.com
```

### Links from a plain text file of UPNs

```powershell
Get-Content ./upn-list.txt |
    ./app/New-BulkShareLinks.ps1 `
        -Connector "Production M365" `
        -OutputPath "./share-links.csv"
```

### Password-protected links with expiry

```powershell
$pw = Read-Host -AsSecureString "Enter share password"
Get-Content ./upn-list.txt |
    ./app/New-BulkShareLinks.ps1 `
        -Connector "Production M365" `
        -Workload OneDrive `
        -OutputPath "./onedrive-links.csv" `
        -Password $pw `
        -Lifetime "P14D"
```

## Output

The script produces a CSV file with two columns:

```csv
UserPrincipalName,Link
user1@contoso.com,https://us-dc.keepit.com/s/abc123
user2@contoso.com,https://us-dc.keepit.com/s/def456
```

Only successfully created links are written to the CSV.
Users that failed (not found in backup, API error) are
reported via `Write-Error` and excluded from the output.

## Error handling

- If a UPN cannot be resolved or a share fails to create,
  the script logs the error and continues to the next user.
- A summary at the end reports how many users failed.
- The script never stops on individual user failures,
  making it safe for large batch runs.

## Verbose output

Use `-Verbose` to see detailed progress for each user,
including GUID resolution and share creation:

```powershell
Get-Content ./upns.txt |
    ./app/New-BulkShareLinks.ps1 `
        -Connector "Production M365" `
        -OutputPath "./links.csv" `
        -Verbose
```