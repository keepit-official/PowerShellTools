# Bulk-set the trusted-IP allowlist

`Set-KeepitAllowedIPRanges.ps1` applies a list of IPv4 CIDR ranges to a Keepit
account's trusted-IP allowlist (the MFA "Trusted IPs" configuration) in one
operation, reading the ranges from a plain-text or CSV file.

## Why this exists

The Keepit console's trusted-IP UI cannot yet handle arbitrary CIDR prefixes — for
example a `/16` where the third octet is fixed (the field is greyed out). The
Keepit API, however, accepts CIDR notation directly. This script is a short-term
workaround: give it a file of CIDR ranges and it configures them through the API.

## Requirements

- The **KeepitTools** module, version **1.7.0** or newer.
- **Primary** account credentials (a user login, not an API token) whose role
  grants the **"Enable and configure MFA"** permission — for example **Master
  Admin**. Lesser roles (e.g. SSO Admin) can *read* the allowlist but not change
  it, and the API rejects the write with `Forbidden`. A non-primary API token is
  rejected with `Primary credentials required`. You may create a custom role that
  grants the needed permission instead of using a **Master Admin** role holder.

## File formats

**Text (`.txt`)** — one CIDR per line; blank lines and lines starting with `#`
are ignored:

```text
10.20.0.0/16
10.30.0.0/16
10.40.0.0/16
```

**CSV (`.csv`)** — a column of CIDRs (default column name `Cidr`, override with
`-CidrColumn`). Extra columns are ignored:

```csv
Cidr,Description
10.20.0.0/16,HQ outbound range
10.30.0.0/16,Branch office range
```

Sample files `ranges.sample.txt` and `ranges.sample.csv` are included.

## Usage

Replace the allowlist with the ranges in a file:

```powershell
$cred = Get-Credential          # primary Master Admin login
Connect-KeepitService -Environment us-dc -Credential $cred

./Set-KeepitAllowedIPRanges.ps1 -RangesFile ./ranges.txt -Credential $cred -Environment us-dc
```

Preview without applying (`-WhatIf`), adding to the existing list (`-Merge`):

```powershell
./Set-KeepitAllowedIPRanges.ps1 -RangesFile ./ranges.csv -Credential $cred -Merge -WhatIf
```

Use a non-default CSV column:

```powershell
./Set-KeepitAllowedIPRanges.ps1 -RangesFile ./ranges.csv -CidrColumn Range -Credential $cred
```

## Behavior notes

- **How ranges are stored.** The cmdlet writes each CIDR as a `from`/`to`
  address range, not as a `cidr` element. The Keepit WebApp "IP Ranges" page
  hangs on CIDR-based rules, so `from`/`to` is the form the console renders
  safely. `Get-KeepitAllowedIPRange` reports the equivalent CIDR on read-back.
- **Replace vs. merge.** By default the file's ranges *replace* the existing
  allowlist. `-Merge` adds them to what is already configured. `-Merge` can
  preserve any existing range that resolves to a single CIDR block, but not an
  arbitrary range that does not map to one CIDR; review the current state with
  `Get-KeepitAllowedIPRange` first.
- **The script never enables enforcement.** It only manages the IP ranges; it
  does not change the MFA `enabled` flag or the rules operator. On an account
  where MFA is enabled with an `and` rule, a trusted-IP range that does not
  include your own address can lock you out — verify with
  `Get-KeepitAllowedIPRange -Raw` before enabling enforcement in the console.
- The underlying cmdlet validates every CIDR (octets 0–255, prefix /0–/32) and
  de-duplicates before writing.
- **Emptying the allowlist.** This script always writes at least the ranges in
  the file. To remove every range, call the cmdlet directly:
  `Update-KeepitAllowedIPRange -Clear -Credential $cred`. That preserves the MFA
  `enabled` flag and any TOTP rule; it only drops the IP ranges.
