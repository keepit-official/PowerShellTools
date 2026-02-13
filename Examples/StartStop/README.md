# Examples

This folder contains scripts that show practical usage of the Keepit PowerShell APIs and tools.

## Stop_Start_Stagger.ps1

Interactively stops or starts backup jobs across Keepit connectors using direct API calls.

**Note**: the v2 version of this script, which is marked as "experimental", uses the Keepit PowerShell tools module exclusively, but it doesn't correctly handle stopping some types of scheduled jobs.

### What it does

1. Prompts for credentials and a target Account ID.
2. Auto-discovers which data center the account lives in.
3. Asks whether to **Stop** (disable backups and cancel jobs) or **Start** (enable backups and kick off jobs).
4. Fetches all connectors and their storage sizes using concurrent threads (20 workers).
5. Presents an `Out-ConsoleGridView` selector to pick which connectors to act on.
6. Executes the chosen action concurrently across all selected connectors:
   - **Stop** — Sets the `disable_backup` attribute and cancels any running, scheduled, or queued jobs.
   - **Start** — Removes the `disable_backup` attribute and starts backup jobs. Optionally staggers them in batches at a configurable interval, with load-balanced ordering that alternates between the largest and smallest connectors.
7. Displays a summary table and exports results to a CSV on the Desktop.

### Requirements

- PowerShell 5.1+
- [Microsoft.PowerShell.ConsoleGuiTools](https://github.com/PowerShell/GraphicalTools) module (`Install-Module Microsoft.PowerShell.ConsoleGuiTools`)
- Valid Keepit credentials with access to the target account
