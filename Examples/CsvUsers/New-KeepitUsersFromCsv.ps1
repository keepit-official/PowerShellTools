<#
.SYNOPSIS
    Bulk-creates Keepit LimitedSupport user accounts from a CSV of fake identities.
.DESCRIPTION
    Reads a CSV of user records (at minimum GivenName and Surname columns) and creates
    a corresponding Keepit user account for each row with the LimitedSupport role. The
    CSV has no email column, so an email/UPN is synthesized from GivenName and Surname
    plus the supplied -EmailDomain. Duplicate synthesized addresses are disambiguated
    with a numeric suffix.

    Intended for populating a test Keepit account with a large number of low-privilege
    users, e.g. for load or UI testing. If a user cannot be created, an error is
    displayed and processing continues with the remaining rows.
.PARAMETER CsvPath
    Path to the CSV file. Must contain at least GivenName and Surname columns.
.PARAMETER EmailDomain
    Domain to append to the synthesized email/UPN, e.g. "keepithybrid.com". Do not
    include the "@".
.PARAMETER KeepitCredential
    Credential for authenticating to the Keepit service.
.PARAMETER Environment
    Keepit data center environment (e.g. ws.keepit, us-dc, uk-ld).
.PARAMETER Connectors
    Either the single string "all" to grant access to all connectors, or one or more
    connector names or GUIDs.
.PARAMETER SendActivationEmail
    When specified, sends an activation email to each newly created user.
.PARAMETER NotificationsEnabled
    When specified, enables email notifications for each newly created user.
.PARAMETER Skip
    When specified, the first N rows of the CSV are skipped before any rows are
    processed. Applied before -First, so the two can be combined to page through
    a large CSV in batches. Useful for resuming a partially completed import.
.PARAMETER First
    When specified, only the first N rows remaining after -Skip are processed.
    Useful for a smoke test before running the full file.
.PARAMETER ThrottleMilliseconds
    Delay between user-creation calls, in milliseconds. Default is 100.
.EXAMPLE
    $kCred = Get-Credential
    .\New-KeepitUsersFromCsv.ps1 -CsvPath /Users/pro/source/keepit/SE-CS/entrabulk/csv/FakeCloudUsers.csv `
        -EmailDomain "keepithybrid.com" -KeepitCredential $kCred -Environment "ws-test" `
        -Connectors "all" -First 10

    Smoke-tests against the first 10 rows of the CSV before running the full import.
.EXAMPLE
    $kCred = Get-Credential
    .\New-KeepitUsersFromCsv.ps1 -CsvPath /Users/pro/source/keepit/SE-CS/entrabulk/csv/FakeCloudUsers.csv `
        -EmailDomain "keepithybrid.com" -KeepitCredential $kCred -Environment "ws-test" `
        -Connectors "all" -Skip 500 -First 500

    Resumes an import, processing rows 501-1000 of the CSV.
.EXAMPLE
    $kCred = Get-Credential
    $results = .\New-KeepitUsersFromCsv.ps1 -CsvPath /Users/pro/source/keepit/SE-CS/entrabulk/csv/FakeCloudUsers.csv `
        -EmailDomain "keepithybrid.com" -KeepitCredential $kCred -Environment "ws-test" `
        -Connectors "all"

    Creates a LimitedSupport user for every row in the CSV and captures the results.
.OUTPUTS
    PSCustomObject with properties:
        - Email:  The synthesized email address
        - Name:   The user's display name
        - Status: Created | AlreadyExists | Failed | WhatIf
        - Error:  Error message if Status is Failed; otherwise $null
.NOTES
    Requires:
        - PowerShell 7+
        - KeepitTools module at ../../src/KeepitTools.psd1 relative to this script

    Supports -WhatIf: connects to Keepit as normal but skips user creation. Each user
    that would have been created is emitted with Status = 'WhatIf'.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$EmailDomain,

    [Parameter(Mandatory = $true)]
    [PSCredential]$KeepitCredential,

    [Parameter(Mandatory = $true)]
    [string]$Environment,

    [Parameter(Mandatory = $true)]
    [string[]]$Connectors,

    [Parameter(Mandatory = $false)]
    [switch]$SendActivationEmail,

    [Parameter(Mandatory = $false)]
    [switch]$NotificationsEnabled,

    [Parameter(Mandatory = $false)]
    [int]$Skip,

    [Parameter(Mandatory = $false)]
    [int]$First,

    [Parameter(Mandatory = $false)]
    [int]$ThrottleMilliseconds = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Module loading -----------------------------------------------------------

$keepitManifest = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'src', 'KeepitTools.psd1'
if (-not (Test-Path $keepitManifest)) {
    throw "KeepitTools module not found at '$keepitManifest'. " +
        "Ensure the module is present at src/KeepitTools.psd1 relative to the repository root."
}
Write-Verbose "Loading KeepitTools from '$keepitManifest'"
Import-Module $keepitManifest -ErrorAction Stop

# --- Keepit authentication -----------------------------------------------------

Write-Verbose "Connecting to Keepit ($Environment)"
try {
    Connect-KeepitService -Credential $KeepitCredential -Environment $Environment -ErrorAction Stop | Out-Null
}
catch {
    throw "Failed to authenticate to Keepit: $($_.Exception.Message)"
}

# --- CSV import -----------------------------------------------------------------

Write-Verbose "Importing CSV from '$CsvPath'"
$rows = @(Import-Csv -Path $CsvPath)

if ($Skip -gt 0) {
    Write-Verbose "Skipping the first $Skip row(s) of $($rows.Count) total"
    $rows = if ($Skip -lt $rows.Count) { $rows[$Skip..($rows.Count - 1)] } else { @() }
}

if ($First -gt 0 -and $First -lt $rows.Count) {
    Write-Verbose "Limiting to the first $First row(s) of $($rows.Count) remaining"
    $rows = $rows[0..($First - 1)]
}

if ($rows.Count -eq 0) {
    Write-Warning "CSV '$CsvPath' contains no rows. Nothing to do."
    return
}

# --- User creation ---------------------------------------------------------------

$usedEmails = @{}

foreach ($row in $rows) {
    $givenName = $row.GivenName.Trim()
    $surname = $row.Surname.Trim()

    if ([string]::IsNullOrWhiteSpace($givenName) -or [string]::IsNullOrWhiteSpace($surname)) {
        Write-Error "Skipping row: missing GivenName or Surname." -ErrorAction Continue
        [PSCustomObject]@{
            Email  = $null
            Name   = $null
            Status = 'Failed'
            Error  = 'Missing GivenName or Surname in CSV row'
        }
        continue
    }

    $displayName = "$givenName $surname"

    # Build a mail-safe local part from the name; strip anything but letters, digits, dot and hyphen
    $localPart = ("$givenName.$surname" -replace '[^a-zA-Z0-9.\-]', '').ToLowerInvariant()

    $email = "$localPart@$EmailDomain"
    if ($usedEmails.ContainsKey($email)) {
        $suffix = ++$usedEmails[$email]
        $email = "$localPart$suffix@$EmailDomain"
    }
    else {
        $usedEmails[$email] = 1
    }

    Write-Verbose "Creating Keepit user: $displayName <$email>"

    $newUserParams = @{
        Name        = $displayName
        Email       = $email
        Role        = 'LimitedSupport'
        Connectors  = $Connectors
        ErrorAction = 'Stop'
    }
    if ($SendActivationEmail)              { $newUserParams['SendActivationEmail']  = $true }
    if ($NotificationsEnabled)             { $newUserParams['NotificationsEnabled'] = $true }
    if ($VerbosePreference -eq 'Continue') { $newUserParams['Verbose']              = $true }

    if ($PSCmdlet.ShouldProcess("$displayName <$email>", 'Create Keepit LimitedSupport user')) {
        try {
            New-KeepitUser @newUserParams | Out-Null

            [PSCustomObject]@{
                Email  = $email
                Name   = $displayName
                Status = 'Created'
                Error  = $null
            }
        }
        catch {
            $errMsg = $_.Exception.Message
            $status = if ($errMsg -like "*already exists*") { 'AlreadyExists' } else { 'Failed' }

            if ($status -eq 'Failed') {
                Write-Error "Failed to create user '$email': $errMsg" -ErrorAction Continue
            }
            else {
                Write-Warning "User '$email' already exists in Keepit; skipping."
            }

            [PSCustomObject]@{
                Email  = $email
                Name   = $displayName
                Status = $status
                Error  = if ($status -eq 'Failed') { $errMsg } else { $null }
            }
        }

        if ($ThrottleMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $ThrottleMilliseconds
        }
    }
    else {
        [PSCustomObject]@{
            Email  = $email
            Name   = $displayName
            Status = 'WhatIf'
            Error  = $null
        }
    }
}
