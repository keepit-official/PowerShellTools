# restore-bulk.ps1

Interactive wizard for bulk-restoring deleted email items from a Keepit
Microsoft 365 connector. Uses PwshSpectreConsole for a step-by-step guided
prompt flow that collects parameters, previews the restore operation with
`-WhatIf`, and submits the restore jobs.

## How it works

The wizard walks through four steps:

1. **Select Connector** — fetches all `o365-admin` connectors and presents a
   searchable list.
2. **Enter User** — prompts for a User Principal Name and validates it against
   the Keepit API via `Convert-KeepitUPNToGuid`.
3. **Configure Search** — collects date range, folder path, item type
   (email/user/OneDrive), and recursive flag.
4. **Review and Confirm** — displays a summary table, runs a `-WhatIf` preview,
   and asks for final confirmation before submitting.

## Prerequisites

- PowerShell 7+
- KeepitTools module (either present at `../../src/KeepitTools.psd1` or
  installed in the PowerShell module path)
- [PwshSpectreConsole](https://pwshspectreconsole.com/) module (`Install-Module PwshSpectreConsole`)

## Files

| File | Description |
|---|---|
| `restore-bulk.ps1` | Main wizard script |
| `restore-helpers.ps1` | Shared helper functions (connection, prompts, validation) |

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `Credential` | No | PSCredential for the Keepit service; prompts if omitted |
| `Environment` | No | Keepit data center region (e.g. `us-dc`, `uk-ld`); auto-discovers if omitted |

## Examples

```powershell
# Interactive: prompts for credentials and auto-discovers environment
./restore-bulk.ps1
```

```powershell
# Non-interactive credentials with explicit environment
$cred = Get-Credential
./restore-bulk.ps1 -Credential $cred -Environment 'us-dc'
```

## Notes

- The preview step uses `-WhatIf` so no restore jobs are submitted until you
  explicitly confirm.
- If the preview returns no items, the wizard exits without prompting to submit.
- The helpers file (`restore-helpers.ps1`) is also used by `restore-express.ps1`
  in the `app/` directory.
