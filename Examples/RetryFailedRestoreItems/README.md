# retry-failed.ps1

Interactive wizard for retrying the items that failed in a previous Keepit
restore job. Uses PwshSpectreConsole for a step-by-step guided prompt flow that
identifies the failed job, previews the retry with `-WhatIf`, and submits a new
restore job containing only the failed items.

## How it works

The wizard walks through these steps:

1. **Choose Retry Source** — either pick a recent restore job from history, or
   point at a Job Report CSV exported from the admin center.
2. **Select Connector / Restore Job** — when using a job source, presents a
   searchable connector list and then the recent restore jobs on it.
3. **Filter by Cause (optional)** — restrict the retry to a specific failure
   cause, e.g. `CODE:507` (Microsoft "Insufficient Storage").
4. **Review, Preview, Confirm** — shows a summary, runs a `-WhatIf` preview of
   exactly what would be resubmitted, and asks for final confirmation before
   submitting.

`Restore-KeepitFailedItems` recovers the snapshot and restore settings from the
original job, reads the failed-item list (from the job log, or the CSV), and
resubmits only the failed items to their original location.

## Prerequisites

- PowerShell 7+
- KeepitTools module (either present at `../../src/KeepitTools.psd1` or
  installed in the PowerShell module path)
- [PwshSpectreConsole](https://pwshspectreconsole.com/) module (`Install-Module PwshSpectreConsole`)

## Files

| File | Description |
|---|---|
| `retry-failed.ps1` | Main wizard script |
| `restore-helpers.ps1` | Shared helper functions (connection, connector/job selection, review table) |

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `Credential` | No | PSCredential for the Keepit service; prompts if omitted |
| `Environment` | No | Keepit data center region (e.g. `us-dc`, `uk-ld`); auto-discovers if omitted |

## Examples

```powershell
# Interactive: prompts for credentials and auto-discovers environment
./retry-failed.ps1
```

```powershell
# Non-interactive credentials with explicit environment
$cred = Get-Credential
./retry-failed.ps1 -Credential $cred -Environment 'us-dc'
```

The same operation, run directly against the cmdlet without the wizard:

```powershell
# Preview, then submit, a retry of the failed items in a restore job
Restore-KeepitFailedItems -Connector 'Production M365' -JobGuid '41uuom-csg9bg-zu01hz-r8apss' -WhatIf
Restore-KeepitFailedItems -Connector 'Production M365' -JobGuid '41uuom-csg9bg-zu01hz-r8apss'

# Retry only the items that failed with a specific cause, from a CSV export
Restore-KeepitFailedItems -ReportPath ./Job_Report.csv -IncludeCause 'CODE:507'
```

## Notes

- The preview step uses `-WhatIf`, so no restore job is submitted until you
  explicitly confirm.
- If the selected job had no failed items, the wizard exits without prompting to
  submit.
- The job picker uses `Get-KeepitJobHistory -FailReason` (the PUT `/jobs` history
  filter with the `fail_reason` stat), so it reaches back the full window and shows
  why each failed job failed — failed jobs are marked `[failed: <reason>]` and
  listed first. `Restore-KeepitFailedItems` still confirms the actual failed items
  for the chosen job.
- **Retries are only possible within about 30 days of the failure.** Keepit
  retains the skipped-items log (the source of the failed-item list) for roughly
  30 days, so the job picker looks back 30 days by default. Beyond that window the
  failed-item list is gone even if the job and snapshot still exist, and the
  cmdlet reports that the log has expired.
- A common, retry-friendly cause is `CODE:507` (Microsoft "Insufficient
  Storage") — once the underlying condition (for example a destination over
  quota) is fixed, retrying completes the restore.
