#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'KeepitTools'; ModuleVersion = '1.7.0' }

<#
.SYNOPSIS
    Bulk-sets a Keepit account's trusted-IP allowlist from a list of IPv4 CIDR ranges.

.DESCRIPTION
    Reads a list of IPv4 CIDR ranges from a plain-text or CSV file and applies them
    to the account's trusted-IP allowlist (the MFA "Trusted IPs" configuration) using
    Update-KeepitAllowedIPRange.

    This is the field workaround for the console limitation where the trusted-IP UI
    cannot express arbitrary CIDR prefixes (for example, a /16 with a fixed third
    octet). The Keepit API accepts CIDR notation directly, so this script lets an
    administrator apply many ranges in one operation.

    By default the supplied ranges REPLACE the existing allowlist (matching the
    Get/Update model of the module). Use -Merge to instead add the file's ranges to
    whatever is already configured.

    IMPORTANT: Writing MFA/security settings requires PRIMARY account credentials (a
    user login, not an API token) whose role grants the "Enable and configure MFA"
    permission, for example Master Admin. Supply these with -Credential.

    File formats:
      * .txt  - one CIDR per line; blank lines and lines beginning with '#' are ignored.
      * .csv  - a column of CIDRs (default column name 'Cidr', override with -CidrColumn).

.PARAMETER RangesFile
    Path to the .txt or .csv file containing the IPv4 CIDR ranges.

.PARAMETER Credential
    PSCredential for a primary account whose role can configure MFA (e.g. Master Admin).

.PARAMETER Environment
    Optional Keepit environment (e.g. 'us-dc'). If omitted, the cached environment
    from a prior Connect-KeepitService call is used.

.PARAMETER CidrColumn
    For CSV input, the column holding the CIDR values. Defaults to 'Cidr'.

.PARAMETER Merge
    Add the file's ranges to the existing allowlist instead of replacing it.

.EXAMPLE
    $cred = Get-Credential   # primary Master Admin login
    ./Set-KeepitAllowedIPRanges.ps1 -RangesFile ./ranges.txt -Credential $cred -Environment us-dc

    Replaces the account allowlist with the ranges listed in ranges.txt.

.EXAMPLE
    ./Set-KeepitAllowedIPRanges.ps1 -RangesFile ./ranges.csv -CidrColumn Range -Credential $cred -Merge -WhatIf

    Shows what the allowlist would become if the CSV's ranges were added to the
    existing configuration, without applying anything.

.NOTES
    Depends on the KeepitTools module (Get-KeepitAllowedIPRange, Update-KeepitAllowedIPRange).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$RangesFile,

    [Parameter(Mandatory = $true)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$Environment,

    [Parameter(Mandatory = $false)]
    [string]$CidrColumn = 'Cidr',

    [switch]$Merge
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Read the CIDR ranges from the file (text or CSV) ---------------------------
$extension = [System.IO.Path]::GetExtension($RangesFile).ToLowerInvariant()
$fileRanges = [System.Collections.Generic.List[string]]::new()

if ($extension -eq '.csv') {
    $rows = Import-Csv -Path $RangesFile
    if (-not $rows) {
        throw "CSV file '$RangesFile' contained no rows."
    }
    if (-not ($rows[0].PSObject.Properties.Name -contains $CidrColumn)) {
        throw "CSV file '$RangesFile' has no '$CidrColumn' column. Columns present: $($rows[0].PSObject.Properties.Name -join ', ')."
    }
    foreach ($row in $rows) {
        $value = "$($row.$CidrColumn)".Trim()
        if ($value) { $fileRanges.Add($value) }
    }
}
else {
    foreach ($line in (Get-Content -Path $RangesFile)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $fileRanges.Add($trimmed)
    }
}

if ($fileRanges.Count -eq 0) {
    throw "No CIDR ranges found in '$RangesFile'."
}

# De-duplicate the file's ranges, preserving order
$desired = [System.Collections.Generic.List[string]]::new()
foreach ($r in $fileRanges) {
    if (-not $desired.Contains($r)) { $desired.Add($r) }
}

Write-Host "Read $($desired.Count) range(s) from $RangesFile" -ForegroundColor Cyan

# --- Optionally merge with the existing allowlist -------------------------------
if ($Merge) {
    Write-Host "Merging with the existing allowlist..." -ForegroundColor Cyan
    $existing = Get-KeepitAllowedIPRange -Credential $Credential -Environment $Environment |
        ForEach-Object { $_.Cidr } |
        Where-Object { $_ }

    $existingCount = @($existing).Count
    foreach ($cidr in $existing) {
        if (-not $desired.Contains($cidr)) { $desired.Insert(0, $cidr) }
    }
    Write-Host "  Existing ranges that map to a single CIDR: $existingCount" -ForegroundColor Cyan
    Write-Host "  Note: an existing range that does not map to a single CIDR block cannot be preserved by -Merge and would be dropped; review with Get-KeepitAllowedIPRange first." -ForegroundColor Yellow
}

Write-Host "Applying $($desired.Count) trusted IP range(s):" -ForegroundColor Cyan
$desired | ForEach-Object { Write-Host "  $_" }

# --- Apply -----------------------------------------------------------------------
# This script declares SupportsShouldProcess, so -WhatIf/-Confirm set the
# preference variables for this scope and are inherited automatically by the
# Update-KeepitAllowedIPRange call below (which also honours ShouldProcess).
$updateParams = @{
    IPRange    = $desired.ToArray()
    Credential = $Credential
}
if ($Environment) { $updateParams.Environment = $Environment }

Update-KeepitAllowedIPRange @updateParams -PassThru |
    Format-Table From, To, Cidr, Notation, Operator -AutoSize
