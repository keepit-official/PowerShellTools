# Bulk SharePoint Site Configuration

`Add-KeepitSharePointSites.ps1` adds a large list of SharePoint site collections
to the **manually included sites** of Keepit Microsoft 365 connectors, reading the
list from a file instead of clicking through the UI.

## When to use this

Keepit M365 connectors back up SharePoint in one of two ways:

- **Automatically**, by matching a naming convention (an attribute picks up every
  site whose URL has a given prefix), or
- **Manually**, where an admin hand-picks individual site collections. These
  connectors have `AutoIncludeAllSiteCollections = false` and a `SiteCollections`
  list.

Adding sites to a manual connector one at a time in the UI does not scale to
hundreds or thousands of sites. This script does it in a single API call per
connector.

## Choosing the target connector

There are two ways to say which connector each site goes to:

- **Single connector** (`-Connector`) — every site in the file is added to one
  connector. Works with a plain-text file or a CSV.
- **Per-row routing** (`-TargetConnector`, CSV only) — each CSV row names its own
  connector, in the column you pass to `-TargetConnector`; that row's site is
  added to that connector. This lets one CSV distribute thousands of sites across
  several connectors in a single run.

`-Connector` and `-TargetConnector` are mutually exclusive. A plain-text file can
only be used with `-Connector` (it has no columns to route by).

### Does a big list fit?

Yes. The connector configuration attribute supports payloads up to **1 GB**. A
`SiteCollections` entry is roughly 100 bytes, so **4000 sites is only about
400 KB** — a single update per connector is fine. There is no need to split the
list across connectors or across multiple runs.

> Note: the module's `Set-KeepitConnectorConfiguration -RawConfiguration`
> parameter has a conservative 64 KB guard, but this script uses the
> `-AddIncludedSites` path, which is not subject to that guard.

## Input file

The `-SitesFile` may be either:

- **Plain text** — one site URL per line. Blank lines and lines starting with `#`
  are ignored.
- **CSV** — pass `-SiteUrlColumn` to name the URL column, or let the script
  auto-detect a column named `SiteUrl`, `SiteURL`, `URL`, `Url`, `Site`, or
  `SiteCollection`.

For per-row routing, the CSV also needs the column named by `-TargetConnector`
holding each row's connector name or GUID. Rows with an empty connector value are
skipped with a warning.

URLs must start with `http://` or `https://`. The script trims whitespace and
trailing slashes, drops anything that is not a URL (with a warning), and
de-duplicates case-insensitively (per connector) before contacting the API.

Example inputs are included: [`sites.sample.txt`](sites.sample.txt) (plain text)
and [`sites-routed.sample.csv`](sites-routed.sample.csv) (per-row routing).

## Prerequisites

- PowerShell 7+
- KeepitTools module v1.4.0+ (present at `../../src/KeepitTools.psd1` or installed
  in the PowerShell module path).
- The target connectors must be Microsoft 365 (`o365-admin`) connectors.

## Parameters

| Parameter         | Required                        | Description                                                                                                      |
|-------------------|---------------------------------|------------------------------------------------------------------------------------------------------------------|
| `Connector`       | One targeting mode              | Single connector name or GUID; every site is added to it. Mutually exclusive with `-TargetConnector`.            |
| `TargetConnector` | One targeting mode              | CSV column whose value routes each row's site to that connector. CSV only. Mutually exclusive with `-Connector`. |
| `SitesFile`       | Yes                             | Path to the file of site URLs (plain text or CSV).                                                               |
| `SiteUrlColumn`   | No                              | CSV column holding the URLs. Omit to auto-detect a common column name. Ignored for plain text.                   |
| `Environment`     | Only when not already connected | Keepit data center region (e.g. `us-dc`). Ignored when a session already exists.                                 |
| `Credential`      | No                              | PSCredential for the Keepit service; prompts if not connected and omitted. Ignored when connected.               |

Provide exactly one of `-Connector` or `-TargetConnector`.

The script also supports the common `-WhatIf` and `-Confirm` risk-mitigation
parameters.

## Output

One object per target connector:

| Property         | Description                                                     |
|------------------|-----------------------------------------------------------------|
| `Connector`      | Connector name or GUID as supplied                              |
| `ConnectorGuid`  | Resolved connector GUID                                         |
| `SitesRequested` | Unique valid URLs targeted at this connector                    |
| `AlreadyPresent` | How many of those were already in the connector's included list |
| `Added`          | How many new sites were added (0 under `-WhatIf`)               |
| `TotalAfter`     | `SiteCollections` count after the operation                     |
| `Status`         | `Success`, `Skipped`, `WhatIf`, or `Failed`                     |

## Examples

```powershell
# Preview first — reports how many sites would be added, writes nothing
.\Add-KeepitSharePointSites.ps1 -Connector "Production M365" -SitesFile .\sites.txt -Environment us-dc -WhatIf
```

```powershell
# Single connector: add every site in the file to one connector (text or CSV)
.\Add-KeepitSharePointSites.ps1 -Connector abc -SitesFile .\junk.csv
```

```powershell
# Per-row routing: each row's "whichOne" column names the connector to add that row's site to
.\Add-KeepitSharePointSites.ps1 -SitesFile .\4000.csv -TargetConnector "whichOne"
```

```powershell
# Capture the per-connector summary
$report = .\Add-KeepitSharePointSites.ps1 -Connector "Production M365" -SitesFile .\sites.txt
$report | Format-Table -Auto
```

## Notes

- **Additive and idempotent.** Existing sites are preserved. Sites already present
  are skipped and counted under `AlreadyPresent`; re-running with the same input
  adds nothing new.
- **Sub-sites.** Sites are added with `AutoIncludeAllSubSites = true`, matching
  the UI default.
- **Auto-include connectors are skipped.** If a target connector has
  `AutoIncludeAllSiteCollections = true`, every site is already in scope, so the
  script warns and makes no change.
- **Performance.** The module de-duplicates each incoming site against the existing
  list, which is O(n²). For multi-thousand-site lists the single update call can
  take a while — this is expected. The script pre-de-duplicates its input to keep
  that cost as low as possible.
- **Resolving the list.** To bulk *remove* sites, or to discover which sites a
  connector has ever covered, see [`../EverCovered`](../EverCovered).
