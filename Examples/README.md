# Examples

- **`EverCovered/EverCovered.ps1`** — Produces a CSV report of every mailbox user who has ever had Exchange data backed up on a Keepit M365 connector, including users since removed from the backup scope. It searches for both active and deleted Outlook folders via two BSearch API calls, then resolves each user's internal GUID to a UPN and writes the results sorted by most recent backup date.

- **`GroupSync/Copy-EntraGroupToKeepit.ps1`** — Creates Keepit user accounts for every member of a Microsoft Entra (Azure AD) security or distribution group, including transitive members of nested groups. Each discovered user is provisioned in Keepit with a specified role and connector access, making it easy to onboard an entire team at once.

- **`BulkLinks/New-BulkShareLinks.ps1`** — Generates personalized Keepit secure shared links for a list of users and exports them to a CSV. Intended for large-scale disaster recovery scenarios where an admin needs to hand each user a direct link to their own mailbox, OneDrive, or both in one operation.

- **`StartStop/experimental-stop_start_stagger_v2.ps1`** — An earlier, raw-API version of the stop/start script that calls the Keepit REST API directly without the KeepitTools module. It locates a target account across all data centers, lets the admin select connectors via an interactive UI, then either disables backup and cancels jobs, or re-enables backup and starts jobs with optional staggering.

- **`StartStop/stop_start_stagger.ps1`** — The current KeepitTools-based version of the stop/start script. It uses module cmdlets (`Disable-KeepitConnector`, `Stop-KeepitJob`, `Enable-KeepitConnector`, `Start-KeepitBackup`) to pause or resume backup activity across selected connectors, with an option to stagger job start times to avoid hammering the platform all at once.
