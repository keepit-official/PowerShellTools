<#
.SYNOPSIS
    Creates Keepit user accounts for all members of an Entra group.
.DESCRIPTION
    Connects to Microsoft Entra ID and resolves the transitive membership of the
    specified security or distribution group into a flat list of users. Each user is
    then created in Keepit with the specified role and connector access.

    Nested groups are fully expanded. If a user cannot be created, an error is
    displayed and processing continues with the remaining users.
.PARAMETER GroupName
    Display name or object GUID of the Entra group to expand.
.PARAMETER EntraCredential
    Credential for authenticating to Microsoft Graph. If omitted, browser-based
    interactive authentication is used.
.PARAMETER KeepitCredential
    Credential for authenticating to the Keepit service.
.PARAMETER Environment
    Keepit data center environment (e.g. ws.keepit, us-dc, uk-ld).
.PARAMETER Connectors
    Either the single string "all" to grant access to all connectors, or one or more
    connector names or GUIDs.
.PARAMETER Role
    Keepit role to assign to each new user. Must be one of: BackupAdmin, MasterAdmin,
    FullSupport, StandardSupport, ComplianceAdmin, LimitedSupport, Audit, SsoAdmin.
.PARAMETER SendActivationEmail
    When specified, sends an activation email to each newly created user.
.PARAMETER NotificationsEnabled
    When specified, enables email notifications for each newly created user.
.EXAMPLE
    $kCred = Get-Credential
    .\Copy-EntraGroupToKeepit.ps1 -GroupName "Keepit Admins" -KeepitCredential $kCred `
        -Environment "us-dc" -Connectors "all" -Role "BackupAdmin" -SendActivationEmail

    Expands the "Keepit Admins" group using browser auth for Entra and creates each
    member as a BackupAdmin with access to all connectors.
.EXAMPLE
    $eCred = Get-Credential
    $kCred = Get-Credential
    .\Copy-EntraGroupToKeepit.ps1 -GroupName "a1b2c3d4-1234-1234-1234-a1b2c3d4e5f6" `
        -EntraCredential $eCred -KeepitCredential $kCred -Environment "ws.keepit" `
        -Connectors "M365 Prod","Exchange" -Role "LimitedSupport"

    Uses a GUID to identify the group and restricts connector access to two named connectors.
.OUTPUTS
    PSCustomObject with properties:
        - Email:   The user's email address
        - Name:    The user's display name
        - Status:  Created | AlreadyExists | Failed
        - Error:   Error message if Status is Failed; otherwise $null
.NOTES
    Requires:
        - PowerShell 7+
        - Microsoft.Graph.Groups module (Install-Module Microsoft.Graph.Groups)
        - KeepitTools module at ../../src/KeepitTools.psd1 relative to this script

    Supports -WhatIf: connects to both services and expands the group as normal, but
    skips user creation. Each user that would have been created is emitted with
    Status = 'WhatIf'.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $true)]
    [string]$GroupName,

    [Parameter(Mandatory = $false)]
    [PSCredential]$EntraCredential,

    [Parameter(Mandatory = $true)]
    [PSCredential]$KeepitCredential,

    [Parameter(Mandatory = $true)]
    [string]$Environment,

    [Parameter(Mandatory = $true)]
    [string[]]$Connectors,

    [Parameter(Mandatory = $true)]
    [ValidateSet('BackupAdmin', 'MasterAdmin', 'FullSupport', 'StandardSupport',
        'ComplianceAdmin', 'LimitedSupport', 'Audit', 'SsoAdmin')]
    [string]$Role,

    [Parameter(Mandatory = $false)]
    [switch]$SendActivationEmail,

    [Parameter(Mandatory = $false)]
    [switch]$NotificationsEnabled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Module loading -----------------------------------------------------------

Write-Verbose "Checking for Microsoft.Graph.Groups module"
if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Groups')) {
    throw "Required module 'Microsoft.Graph.Groups' is not installed. " +
        "Run: Install-Module Microsoft.Graph.Groups"
}
Import-Module Microsoft.Graph.Groups -ErrorAction Stop

$keepitManifest = Join-Path $PSScriptRoot '..' '..' 'src' 'KeepitTools.psd1'
if (-not (Test-Path $keepitManifest)) {
    throw "KeepitTools module not found at '$keepitManifest'. " +
        "Ensure the module is present at src/KeepitTools.psd1 relative to the repository root."
}
Write-Verbose "Loading KeepitTools from '$keepitManifest'"
Import-Module $keepitManifest -ErrorAction Stop

# --- Entra authentication -----------------------------------------------------

Write-Verbose "Connecting to Microsoft Graph"
try {
    if ($EntraCredential) {
        Connect-MgGraph -Credential $EntraCredential -NoWelcome -ErrorAction Stop | Out-Null
    }
    else {
        Connect-MgGraph -NoWelcome -ErrorAction Stop | Out-Null
    }
}
catch {
    throw "Failed to authenticate to Microsoft Graph: $($_.Exception.Message)"
}

# --- Keepit authentication ----------------------------------------------------

Write-Verbose "Connecting to Keepit ($Environment)"
try {
    Connect-KeepitService -Credential $KeepitCredential -Environment $Environment -ErrorAction Stop | Out-Null
}
catch {
    throw "Failed to authenticate to Keepit: $($_.Exception.Message)"
}

# --- Group resolution ---------------------------------------------------------

Write-Verbose "Resolving group '$GroupName'"
try {
    $isGuid = [System.Guid]::TryParse($GroupName, [ref]([System.Guid]::Empty))

    if ($isGuid) {
        $group = Get-MgGroup -GroupId $GroupName -ErrorAction Stop
    }
    else {
        $escapedName = $GroupName.Replace("'", "''")
        $matchingGroups = @(Get-MgGroup -Filter "displayName eq '$escapedName'" `
            -ConsistencyLevel eventual -CountVariable groupCount -All -ErrorAction Stop)

        if ($matchingGroups.Count -eq 0) {
            throw "Group '$GroupName' was not found in Entra ID."
        }
        if ($matchingGroups.Count -gt 1) {
            $ids = ($matchingGroups | ForEach-Object { $_.Id }) -join ', '
            throw "Multiple groups match the name '$GroupName'. Use one of these GUIDs instead: $ids"
        }
        $group = $matchingGroups[0]
    }
}
catch {
    throw "Failed to resolve group: $($_.Exception.Message)"
}

Write-Verbose "Found group: $($group.DisplayName) ($($group.Id))"

# --- Transitive member expansion ----------------------------------------------

Write-Verbose "Expanding transitive membership of '$($group.DisplayName)'"
try {
    $allMembers = Get-MgGroupTransitiveMember -GroupId $group.Id -All `
        -Property 'id', 'displayName', 'userPrincipalName', 'mail' -ErrorAction Stop
}
catch {
    throw "Failed to expand group membership: $($_.Exception.Message)"
}

$users = @($allMembers | Where-Object {
        $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.user'
    })

Write-Verbose "Found $($users.Count) user(s) after recursive expansion"

if ($users.Count -eq 0) {
    Write-Warning "Group '$($group.DisplayName)' has no user members. Nothing to do."
    return
}

# --- User creation ------------------------------------------------------------

foreach ($member in $users) {
    $displayName = $member.AdditionalProperties['displayName']

    # Prefer mail (primary SMTP address) over UPN — they differ when the UPN domain
    # doesn't match the mailbox domain (e.g. user@corp.onmicrosoft.com vs user@corp.com)
    $email = $member.AdditionalProperties['mail']
    if ([string]::IsNullOrWhiteSpace($email)) {
        $email = $member.AdditionalProperties['userPrincipalName']
    }

    if ([string]::IsNullOrWhiteSpace($email) -or [string]::IsNullOrWhiteSpace($displayName)) {
        Write-Error "Skipping member '$($member.Id)': missing displayName or email." -ErrorAction Continue
        [PSCustomObject]@{
            Email  = $email
            Name   = $displayName
            Status = 'Failed'
            Error  = 'Missing displayName or email in Entra'
        }
        continue
    }

    Write-Verbose "Creating Keepit user: $displayName <$email>"

    $newUserParams = @{
        Name        = $displayName
        Email       = $email
        Role        = $Role
        Connectors  = $Connectors
        ErrorAction = 'Stop'
    }
    if ($SendActivationEmail)                   { $newUserParams['SendActivationEmail']  = $true }
    if ($NotificationsEnabled)                  { $newUserParams['NotificationsEnabled'] = $true }
    if ($VerbosePreference -eq 'Continue')      { $newUserParams['Verbose']              = $true }

    if ($PSCmdlet.ShouldProcess("$displayName <$email>", 'Create Keepit user')) {
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
