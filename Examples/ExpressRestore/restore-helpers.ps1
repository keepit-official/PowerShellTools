#Requires -Version 7.0

<#
.SYNOPSIS
    Shared helper functions for the restore wizard apps.

.DESCRIPTION
    Provides interactive connection, shared prompt steps, and validation
    utilities used by restore-bulk.ps1 and restore-express.ps1.
    Uses PwshSpectreConsole for all interactive prompts.
#>

# ---------------------------------------------------------------------------
# Connect-KeepitInteractive
# ---------------------------------------------------------------------------

function Connect-KeepitInteractive {
    <#
    .SYNOPSIS
        Establishes a KeepitTools session, prompting for credentials and
        auto-discovering the environment when not supplied.

    .OUTPUTS
        [string] The resolved environment name (e.g. 'us-dc').
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [PSCredential]$Credential,

        [ValidateSet(
            'ws.keepit', 'au-sy', 'ca-tr', 'dk-co', 'de-fr', 'uk-ld', 'us-dc', 'ch-zh',
            'ws-test', 'ws-test-b', 'ws-test-c', 'staging', 'dev'
        )]
        [string]$Environment
    )

    if (-not $Credential) {
        Write-Host 'Please enter your Keepit credentials...' -ForegroundColor Cyan
        $Credential = Get-Credential
        if (-not $Credential) { throw 'No credential supplied.' }
    }

    if ($Environment) {
        Write-Host "Connecting to specified environment: $Environment" -ForegroundColor Yellow
        try {
            Connect-KeepitService -Credential $Credential -Environment $Environment -ErrorAction Stop | Out-Null
            Write-Host "  Successfully connected to: $Environment" -ForegroundColor Green
            return $Environment
        }
        catch {
            throw "Failed to connect to ${Environment}: $($_.Exception.Message)"
        }
    }

    # Auto-discover across production data centres
    $ProductionDCs = @('us-dc', 'de-fr', 'dk-co', 'ca-tr', 'ch-zh', 'au-sy', 'uk-ld')
    Write-Host 'Auto-discovering environment...' -ForegroundColor Yellow

    foreach ($dc in $ProductionDCs) {
        try {
            Connect-KeepitService -Credential $Credential -Environment $dc -ErrorAction Stop | Out-Null
            Write-Host "  Found account in: $dc" -ForegroundColor Green
            return $dc
        }
        catch { continue }
    }

    throw 'Account not found in any production environment.'
}

# ---------------------------------------------------------------------------
# Select-Connector
# ---------------------------------------------------------------------------

function Select-Connector {
    <#
    .SYNOPSIS
        Prompts the user to select a connector from a searchable list.

    .PARAMETER Connectors
        Array of connector objects from Get-KeepitConnector.

    .OUTPUTS
        The selected connector object, or $null if cancelled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Connectors
    )

    $selected = Read-SpectreSelection `
        -Message 'Select a connector' `
        -Choices $Connectors `
        -ChoiceLabelProperty { "$($_.Name) ($($_.TypeDisplayName)) [[$($_.ConnectorGuid)]]" } `
        -EnableSearch `
        -PageSize 15

    return $selected
}

# ---------------------------------------------------------------------------
# Read-UserPrincipalName
# ---------------------------------------------------------------------------

function Read-UserPrincipalName {
    <#
    .SYNOPSIS
        Prompts for a UPN and validates it against the Keepit API.

    .PARAMETER ConnectorGuid
        The GUID of the selected connector for UPN lookup.

    .OUTPUTS
        PSCustomObject with UPN and Guid properties, or $null if cancelled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConnectorGuid
    )

    $upn = Read-SpectreText -Message 'Enter User Principal Name (email)'
    if ([string]::IsNullOrWhiteSpace($upn)) { return $null }

    $result = Invoke-SpectreCommandWithStatus -Title "Validating '$upn'..." -Spinner 'Dots2' -ScriptBlock {
        Convert-KeepitUPNToGuid -UserPrincipalName $upn -Connector $ConnectorGuid -ErrorAction Stop
    }

    if (-not $result -or -not $result.Guid) {
        Write-SpectreHost "[red]User '$upn' not found in backup.[/]"
        return $null
    }

    Write-SpectreHost "[green]Validated:[/] $upn ($($result.Guid))"
    return [PSCustomObject]@{
        UPN  = $upn
        Guid = $result.Guid
    }
}

# ---------------------------------------------------------------------------
# Read-DateRange
# ---------------------------------------------------------------------------

function Read-DateRange {
    <#
    .SYNOPSIS
        Prompts for start and end dates with validation.

    .OUTPUTS
        PSCustomObject with StartDate and EndDate, or $null if cancelled.
    #>
    [CmdletBinding()]
    param(
        [DateTime]$DefaultStart = [DateTime]::Today.AddDays(-7),
        [DateTime]$DefaultEnd   = [DateTime]::Today
    )

    $startStr = Read-SpectreText `
        -Message "Start date (yyyy-MM-dd)" `
        -DefaultAnswer $DefaultStart.ToString('yyyy-MM-dd')
    if ([string]::IsNullOrWhiteSpace($startStr)) { return $null }

    $endStr = Read-SpectreText `
        -Message "End date (yyyy-MM-dd)" `
        -DefaultAnswer $DefaultEnd.ToString('yyyy-MM-dd')
    if ([string]::IsNullOrWhiteSpace($endStr)) { return $null }

    $startDate = [DateTime]::MinValue
    $endDate   = [DateTime]::MinValue

    if (-not [DateTime]::TryParseExact($startStr, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$startDate)) {
        Write-SpectreHost "[red]Invalid start date format. Use yyyy-MM-dd.[/]"
        return $null
    }
    if (-not [DateTime]::TryParseExact($endStr, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$endDate)) {
        Write-SpectreHost "[red]Invalid end date format. Use yyyy-MM-dd.[/]"
        return $null
    }

    if ($endDate -le $startDate) {
        Write-SpectreHost "[red]End date must be after start date.[/]"
        return $null
    }

    return [PSCustomObject]@{
        StartDate = $startDate
        EndDate   = $endDate
    }
}

# ---------------------------------------------------------------------------
# Test-DateRange
# ---------------------------------------------------------------------------

function Test-DateRange {
    <#
    .SYNOPSIS
        Validates that EndDate is strictly after StartDate.

    .OUTPUTS
        [bool] $true if valid; $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [DateTime]$StartDate,

        [Parameter(Mandatory)]
        [DateTime]$EndDate,

        [ref]$ErrorMessage
    )

    if ($EndDate -le $StartDate) {
        if ($ErrorMessage) {
            $ErrorMessage.Value = 'End date must be after start date.'
        }
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------------
# ConvertTo-RestoreTimespan
# ---------------------------------------------------------------------------

function ConvertTo-RestoreTimespan {
    <#
    .SYNOPSIS
        Parses an ISO 8601 duration string (e.g. "P3D", "PT12H") into a
        [TimeSpan].

    .OUTPUTS
        [TimeSpan] on success; $null on failure.
    #>
    [CmdletBinding()]
    [OutputType([TimeSpan])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Duration,

        [ref]$ErrorMessage
    )

    if ([string]::IsNullOrWhiteSpace($Duration)) {
        if ($ErrorMessage) { $ErrorMessage.Value = 'Duration string is empty.' }
        return $null
    }

    try {
        return [System.Xml.XmlConvert]::ToTimeSpan($Duration)
    }
    catch {
        if ($ErrorMessage) {
            $ErrorMessage.Value = "Invalid ISO 8601 duration: '$Duration'."
        }
        return $null
    }
}

# ---------------------------------------------------------------------------
# Show-ReviewTable
# ---------------------------------------------------------------------------

function Show-ReviewTable {
    <#
    .SYNOPSIS
        Displays a review summary as a formatted Spectre table.

    .PARAMETER Rows
        Array of hashtables with Label and Value keys.

    .PARAMETER Title
        Title for the table panel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable[]]$Rows,

        [string]$Title = 'Configuration'
    )

    $data = $Rows | ForEach-Object {
        [PSCustomObject]@{ Setting = $_.Label; Value = $_.Value }
    }

    $data | Format-SpectreTable `
        -Property Setting, Value `
        -Border Rounded `
        -Color 'Cyan1' `
        -Title $Title
}
