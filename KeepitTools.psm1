<#
.SYNOPSIS
    Keepit Tools PowerShell Module
.DESCRIPTION
    Provides cmdlets for using the Keepit API from PowerShell scripts, including cmdlets to
    connect and disconnect from the service, get the status of backup jobs, start backup jobs,
    and get information about existing Microsoft 365 connectors.
.NOTES
    Author: Keepit
#>

# KeepitTools.psm1 - Module loader

# Windows PowerShell 5.1 runs on .NET Framework, where the default protocol
# list can leave out TLS 1.2 on older Windows builds. The Keepit API requires
# TLS 1.2 or later. PowerShell 7 negotiates it by default.
if ($PSVersionTable.PSEdition -ne 'Core') {
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
}
# Dot-source private helpers first (order matters: state before helpers)
. "$PSScriptRoot/Private/ConnectionState.ps1"
. "$PSScriptRoot/Private/Helpers.ps1"

# Dot-source public cmdlets (order does not matter)
foreach ($script in (Get-ChildItem -Path "$PSScriptRoot/Public" -Filter '*.ps1' -ErrorAction Stop)) {
    . $script.FullName
}

# Aliases for PowerShell naming convention compliance (A15, A16)
# Singular-noun aliases for plural-noun cmdlets
New-Alias -Name 'Get-KeepitJob'  -Value 'Get-KeepitJobs'  -Scope Script
New-Alias -Name 'Get-KeepitRole' -Value 'Get-KeepitRoles' -Scope Script
# Approved-verb alias for Search-KeepitSnapshot
New-Alias -Name 'Find-KeepitSnapshot' -Value 'Search-KeepitSnapshot' -Scope Script
