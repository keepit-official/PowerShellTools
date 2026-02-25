#Requires -Version 7.0

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
