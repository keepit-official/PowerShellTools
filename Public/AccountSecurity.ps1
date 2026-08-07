#region Account Security - Allowed IP Ranges (MFA trusted-IP allowlist)
#
# The account-level "trusted IP" allowlist is stored under the account MFA
# configuration, not connector configuration:
#
#   GET /users/{userId}/mfa   (read; works with normal credentials)
#   PUT /users/{userId}/mfa   (write; requires PRIMARY credentials whose role
#                              grants the "Enable and configure MFA" permission,
#                              e.g. Master Admin)
#
# The config looks like:
#   <mfa>
#     <enabled>true|false</enabled>
#     <rules>
#       <and|or>
#         <totp></totp>
#         <ip-range><from>10.20.0.0</from><to>10.20.255.255</to></ip-range>
#         <ip-range><cidr>10.20.0.0/16</cidr></ip-range>
#         <ip-range><ip>192.168.1.0</ip><mask>24</mask></ip-range>
#       </and|or>
#     </rules>
#   </mfa>
#
# An <ip-range> may be stored as <from>/<to>, as <cidr>, or as <ip>+<mask>. This
# module WRITES from/to only: the WebApp "IP Ranges" page hangs on CIDR-based
# rules (MR !44), so each input CIDR is converted to its from/to range on write.
# Get-KeepitAllowedIPRange reads all three forms and reports the equivalent CIDR
# whenever a from/to range is one aligned CIDR block.
#
# IP-range rules share the <rules> group with the MFA method (<totp>), so writes
# are read-modify-write: the group operator (<and>/<or>), <enabled>, and all
# non-ip rules are preserved; only the <ip-range> entries are managed here.

<#
.SYNOPSIS
    Converts a dotted-quad IPv4 string to its host-order UInt32 value.
#>
function ConvertTo-KeepitIPv4UInt32 {
    [CmdletBinding()]
    [OutputType([uint32])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address
    )
    $bytes = [System.Net.IPAddress]::Parse($Address).GetAddressBytes()
    [Array]::Reverse($bytes)
    return [System.BitConverter]::ToUInt32($bytes, 0)
}

<#
.SYNOPSIS
    Converts a host-order UInt32 value back to a dotted-quad IPv4 string.
#>
function ConvertFrom-KeepitIPv4UInt32 {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Value
    )
    $bytes = [System.BitConverter]::GetBytes($Value)
    [Array]::Reverse($bytes)
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

<#
.SYNOPSIS
    Validates an IPv4 CIDR string (a.b.c.d/nn with octets 0-255 and prefix 0-32).
#>
function Test-KeepitIPv4Cidr {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Cidr
    )
    if ($Cidr -notmatch '^\s*(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})\s*$') {
        return $false
    }
    $octets = $Matches[1], $Matches[2], $Matches[3], $Matches[4]
    foreach ($o in $octets) {
        if ([int]$o -gt 255) { return $false }
    }
    $prefix = [int]$Matches[5]
    if ($prefix -lt 0 -or $prefix -gt 32) { return $false }
    return $true
}

<#
.SYNOPSIS
    Computes the inclusive From/To address range for an IPv4 CIDR or ip+prefix.
.OUTPUTS
    PSCustomObject with From, To (dotted-quad strings) and PrefixLength (int).
#>
function Get-KeepitIPv4Range {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 32)]
        [int]$PrefixLength
    )

    $ipUint = ConvertTo-KeepitIPv4UInt32 -Address $Address
    $maskUint = if ($PrefixLength -eq 0) {
        [uint32]0
    } else {
        [uint32]((0xFFFFFFFFL -shl (32 - $PrefixLength)) -band 0xFFFFFFFFL)
    }
    $network = [uint32]($ipUint -band $maskUint)
    $broadcast = [uint32]($network -bor ((-bnot $maskUint) -band 0xFFFFFFFFL))

    return [PSCustomObject]@{
        From         = ConvertFrom-KeepitIPv4UInt32 -Value $network
        To           = ConvertFrom-KeepitIPv4UInt32 -Value $broadcast
        PrefixLength = $PrefixLength
    }
}

<#
.SYNOPSIS
    Derives the CIDR notation for an inclusive From/To range, when the range is
    exactly one aligned CIDR block.
.DESCRIPTION
    The account MFA endpoint stores IP-range rules as <from>/<to>. A from/to pair
    equals a single CIDR only when its size is a power of two and the start
    address is aligned to that size. Returns the CIDR string (e.g. '10.20.0.0/16')
    in that case, or $null when the range does not map to one CIDR block.
.OUTPUTS
    String CIDR, or $null.
#>
function ConvertTo-KeepitCidrFromRange {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$From,

        [Parameter(Mandatory = $true)]
        [string]$To
    )

    $fromU = [uint64](ConvertTo-KeepitIPv4UInt32 -Address $From)
    $toU = [uint64](ConvertTo-KeepitIPv4UInt32 -Address $To)
    if ($toU -lt $fromU) { return $null }

    $size = $toU - $fromU + 1        # inclusive count, as UInt64 to allow 2^32
    # Size must be a power of two.
    if (($size -band ($size - 1)) -ne 0) { return $null }

    $prefix = 32
    $s = $size
    while ($s -gt 1) { $s = $s -shr 1; $prefix-- }

    # Start address must be aligned to the block size.
    if (($fromU % $size) -ne 0) { return $null }

    return "$From/$prefix"
}

<#
.SYNOPSIS
    Retrieves the raw account MFA configuration element (<mfa>...</mfa>) as text.
.DESCRIPTION
    Internal helper. Returns a hashtable with the raw <mfa> string (declaration
    and trailing comment stripped) and the parsed [xml] document.
#>
function Get-KeepitMfaConfigInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AuthHeader,

        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$UserId
    )

    $headers = @{
        'Authorization' = $AuthHeader
        'Accept'        = 'application/vnd.keepit.v4+xml'
    }
    $uri = "$BaseUrl/users/$UserId/mfa"
    Write-Verbose "GET $uri"

    $raw = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
    if ($raw -is [System.Xml.XmlDocument]) {
        $rawText = $raw.OuterXml
    }
    elseif ($raw -is [byte[]]) {
        $rawText = [System.Text.Encoding]::UTF8.GetString($raw)
    }
    else {
        $rawText = [string]$raw
    }

    # Isolate just the <mfa>...</mfa> element (drop xml declaration / trailing comment)
    $match = [regex]::Match($rawText, '(?s)<mfa>.*</mfa>')
    if (-not $match.Success) {
        throw "Unexpected MFA response: could not locate an <mfa> element."
    }
    $mfaXml = $match.Value

    return @{
        Text = $mfaXml
        Xml  = [xml]$mfaXml
    }
}

<#
.SYNOPSIS
    Retrieves the account's allowed IP address ranges (trusted-IP allowlist).
.DESCRIPTION
    Reads the account MFA configuration (GET /users/{userId}/mfa) and returns the
    configured IP-range rules. Each rule is returned as an inclusive address range
    (From/To), regardless of whether the API stores it as <from>/<to>, <cidr>, or
    <ip>+<mask>. A range is the one representation common to all three, so
    Get-KeepitAllowedIPRange always returns a range. When a range is exactly one
    aligned CIDR block, the .Cidr and .PrefixLength properties are also populated;
    they are $null for an arbitrary range that is not a single CIDR.

    Note: Update-KeepitAllowedIPRange writes rules as <from>/<to> (the WebApp
    cannot render CIDR-based rules), so ranges written by this module read back
    with Notation 'range' and a derived .Cidr.

    Reading the allowlist works with normal (cached or -Credential) credentials.
    Changing it requires Update-KeepitAllowedIPRange with primary credentials.
.PARAMETER Credential
    Optional PSCredential used to build a fresh authentication header for this
    call. If omitted, the cached credentials from Connect-KeepitService are used.
.PARAMETER Environment
    Optional Keepit environment override (e.g. 'us-dc'). If omitted, the cached
    environment from Connect-KeepitService is used.
.PARAMETER Raw
    Return the raw <mfa> configuration XML instead of parsed range objects.
.EXAMPLE
    Get-KeepitAllowedIPRange

    Lists the account's configured allowed IP ranges as From/To range objects.
.EXAMPLE
    Get-KeepitAllowedIPRange -Raw

    Returns the raw MFA configuration XML, including the <enabled> flag and the
    rules group operator.
.OUTPUTS
    PSCustomObject[] - one object per IP-range rule with properties:
        - From: First address in the range (dotted-quad)
        - To: Last address in the range (dotted-quad)
        - Cidr: The CIDR string when the rule maps to one CIDR block (stored as
                <cidr>, or a from/to range that is a single aligned block),
                otherwise $null
        - PrefixLength: The prefix length (from CIDR or <mask>) if known
        - Notation: How the rule is stored ('cidr', 'ip-mask', or 'range')

    String - Raw <mfa> XML when -Raw is specified.
.NOTES
    Ranges are only enforced when account MFA is enabled and the account uses the
    trusted-IP rules for access control. Use -Raw to inspect the <enabled> flag
    and the rules group operator (<and>/<or>).
#>
function Get-KeepitAllowedIPRange {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [PSCredential]$Credential,

        [Parameter(Mandatory = $false)]
        [ValidateScript({ $_ -in $script:ValidKeepitEnvironments })]
        [string]$Environment,

        [switch]$Raw
    )

    try {
        Write-Verbose "=== Get-KeepitAllowedIPRange ==="

        $authHeader = Get-AuthHeader -Credential $Credential
        $baseUrl = Get-KeepitBaseUrl -Environment $Environment
        $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl
        Write-Verbose "User ID: $userId"

        $mfa = Get-KeepitMfaConfigInternal -AuthHeader $authHeader -BaseUrl $baseUrl -UserId $userId

        if ($Raw) {
            return $mfa.Text
        }

        # Locate the rules group (<and> or <or>) and its <ip-range> children
        $rulesNode = $mfa.Xml.mfa.rules
        if ($null -eq $rulesNode) {
            Write-Verbose "No <rules> element present; no IP ranges configured."
            return
        }

        $groupNode = $rulesNode.ChildNodes | Where-Object { $_.NodeType -eq 'Element' } | Select-Object -First 1
        if ($null -eq $groupNode) {
            Write-Verbose "Empty rules group; no IP ranges configured."
            return
        }

        $ipRangeNodes = $groupNode.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -eq 'ip-range' }
        foreach ($node in $ipRangeNodes) {
            $cidr = $null
            $prefix = $null
            $address = $null
            $notation = $null

            $cidrNode = $node.ChildNodes | Where-Object { $_.Name -eq 'cidr' } | Select-Object -First 1
            $ipNode = $node.ChildNodes | Where-Object { $_.Name -eq 'ip' } | Select-Object -First 1
            $maskNode = $node.ChildNodes | Where-Object { $_.Name -eq 'mask' } | Select-Object -First 1
            $fromNode = $node.ChildNodes | Where-Object { $_.Name -eq 'from' } | Select-Object -First 1
            $toNode = $node.ChildNodes | Where-Object { $_.Name -eq 'to' } | Select-Object -First 1

            if ($cidrNode) {
                $cidr = $cidrNode.InnerText.Trim()
                $address, $prefixStr = $cidr -split '/'
                $prefix = [int]$prefixStr
                $range = Get-KeepitIPv4Range -Address $address -PrefixLength $prefix
                $notation = 'cidr'
            }
            elseif ($ipNode -and $maskNode) {
                $address = $ipNode.InnerText.Trim()
                $prefix = [int]$maskNode.InnerText.Trim()
                $range = Get-KeepitIPv4Range -Address $address -PrefixLength $prefix
                $notation = 'ip-mask'
            }
            elseif ($fromNode -and $toNode) {
                $from = $fromNode.InnerText.Trim()
                $to = $toNode.InnerText.Trim()
                $range = [PSCustomObject]@{
                    From         = $from
                    To           = $to
                    PrefixLength = $null
                }
                $notation = 'range'
                # Rules written by this module are stored as from/to; surface the
                # equivalent CIDR when the range is one aligned block so callers
                # (and -Merge) still see .Cidr / .PrefixLength.
                $derivedCidr = ConvertTo-KeepitCidrFromRange -From $from -To $to
                if ($derivedCidr) {
                    $cidr = $derivedCidr
                    $prefix = [int]($derivedCidr -split '/')[1]
                }
            }
            else {
                Write-Warning "Skipping an <ip-range> rule in an unrecognised format: $($node.OuterXml)"
                continue
            }

            [PSCustomObject]@{
                From         = $range.From
                To           = $range.To
                Cidr         = $cidr
                PrefixLength = $prefix
                Notation     = $notation
            }
        }
    }
    catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new("Failed to retrieve allowed IP ranges: $($_.Exception.Message)", $_.Exception),
                'KeepitApiError',
                [System.Management.Automation.ErrorCategory]::ConnectionError,
                $null
            )
        )
    }
}

<#
.SYNOPSIS
    Sets the account's allowed IP address ranges (trusted-IP allowlist).
.DESCRIPTION
    Replaces the IP-range rules in the account MFA configuration
    (PUT /users/{userId}/mfa) with the supplied set of IPv4 CIDR ranges. This is a
    read-modify-write operation: the <enabled> flag, the rules group operator
    (<and>/<or>), and all non-IP rules (such as the <totp> MFA method) are
    preserved; only the <ip-range> entries are replaced.

    Each input CIDR is written as a <from>/<to> address range (the CIDR's network
    and broadcast addresses), not as a <cidr> element. The Keepit WebApp "IP
    Ranges" page hangs on CIDR-based rules, so from/to is the storage form the
    frontend renders safely. Get-KeepitAllowedIPRange reports the equivalent CIDR
    on read-back.

    Because -IPRange replaces the full allowlist, include every range you want to
    keep. To add to the existing list, read it first with Get-KeepitAllowedIPRange
    (see the BulkSiteConfig/IPAllowlist example). To remove every range and empty
    the allowlist, use -Clear instead of -IPRange; this removes all IP-range rules
    while preserving the <enabled> flag and non-IP rules such as TOTP.

    IMPORTANT: Writing MFA/security settings requires PRIMARY account credentials
    (a user login, not an API token) whose role grants the "Enable and configure
    MFA" permission (for example, Master Admin). A non-primary token is rejected
    with "Primary credentials required"; a primary login without the MFA
    permission is rejected with "Forbidden". Supply such credentials via
    -Credential.

    This cmdlet does NOT change the <enabled> flag or the rules group operator.
    On an enabled account whose rules use <and>, every rule must match, so a
    trusted-IP range that does not include the caller's address can deny access.
    Review the account's MFA state (Get-KeepitAllowedIPRange -Raw) before enabling
    enforcement.
.PARAMETER IPRange
    One or more IPv4 CIDR ranges (e.g. '10.20.0.0/16') that make up the complete
    desired allowlist. Replaces any existing IP-range rules.
.PARAMETER Clear
    Remove every IP-range rule, emptying the allowlist. Mutually exclusive with
    -IPRange. The <enabled> flag, the rules group operator, and non-IP rules
    (such as TOTP) are preserved.
.PARAMETER Credential
    PSCredential for a primary account whose role can configure MFA. Recommended
    for every call; if omitted, cached credentials are used and the write will
    fail unless the cached session is itself a primary, MFA-capable login.
.PARAMETER Environment
    Optional Keepit environment override (e.g. 'us-dc'). If omitted, the cached
    environment from Connect-KeepitService is used.
.PARAMETER PassThru
    Return the updated allowed IP ranges (as Get-KeepitAllowedIPRange would) after
    a successful update.
.EXAMPLE
    Update-KeepitAllowedIPRange -IPRange '203.0.113.0/24' -Credential $primaryCred

    Sets the allowlist to a single /24 range, replacing any existing ranges.
.EXAMPLE
    Update-KeepitAllowedIPRange -IPRange '10.20.0.0/16','10.30.0.0/16','10.40.0.0/16' -Credential $primaryCred -Confirm:$false

    Sets three /16 trusted ranges in one operation without prompting.
.EXAMPLE
    $keep = Get-KeepitAllowedIPRange | ForEach-Object { $_.Cidr } | Where-Object { $_ }
    Update-KeepitAllowedIPRange -IPRange (@($keep) + '198.51.100.0/24') -Credential $primaryCred

    Appends a range to the existing CIDR-defined allowlist.
.EXAMPLE
    Update-KeepitAllowedIPRange -Clear -Credential $primaryCred

    Removes every trusted-IP range, emptying the allowlist (TOTP and the enabled
    flag are left unchanged).
.OUTPUTS
    None by default. With -PassThru, the updated PSCustomObject range list.
.NOTES
    Requires primary credentials with the "Enable and configure MFA" permission.
    Supports -WhatIf and -Confirm (ConfirmImpact = High).
#>
function Update-KeepitAllowedIPRange {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Set')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Set')]
        [ValidateNotNullOrEmpty()]
        [string[]]$IPRange,

        [Parameter(Mandatory = $true, ParameterSetName = 'Clear')]
        [switch]$Clear,

        [Parameter(Mandatory = $false)]
        [PSCredential]$Credential,

        [Parameter(Mandatory = $false)]
        [ValidateScript({ $_ -in $script:ValidKeepitEnvironments })]
        [string]$Environment,

        [switch]$PassThru
    )

    try {
        Write-Verbose "=== Update-KeepitAllowedIPRange ==="

        $clearing = [bool]$Clear

        # Validate and normalise the requested ranges up front. In -Clear mode the
        # desired list is empty, which removes every IP-range rule from the group.
        $normalized = [System.Collections.Generic.List[string]]::new()
        if (-not $clearing) {
            foreach ($entry in $IPRange) {
                $candidate = $entry.Trim()
                if (-not (Test-KeepitIPv4Cidr -Cidr $candidate)) {
                    throw "Invalid IPv4 CIDR range '$entry'. Expected a.b.c.d/nn with octets 0-255 and a prefix of 0-32 (e.g. '10.20.0.0/16')."
                }
                if (-not $normalized.Contains($candidate)) {
                    $normalized.Add($candidate)
                }
            }
        }

        $authHeader = Get-AuthHeader -Credential $Credential
        $baseUrl = Get-KeepitBaseUrl -Environment $Environment
        $userId = Get-KeepitUserId -AuthHeader $authHeader -BaseUrl $baseUrl
        Write-Verbose "User ID: $userId"

        # Read current config so we can preserve enabled/operator/non-ip rules
        $mfa = Get-KeepitMfaConfigInternal -AuthHeader $authHeader -BaseUrl $baseUrl -UserId $userId

        $enabled = if ($mfa.Xml.mfa.enabled) { $mfa.Xml.mfa.enabled } else { 'false' }

        $rulesNode = $mfa.Xml.mfa.rules
        $groupNode = $null
        if ($null -ne $rulesNode) {
            $groupNode = $rulesNode.ChildNodes | Where-Object { $_.NodeType -eq 'Element' } | Select-Object -First 1
        }
        if ($groupNode) {
            $operator = $groupNode.Name    # 'and' or 'or'
        }
        else {
            # No existing group. Default to 'or' (least restrictive) to avoid
            # inadvertently locking access when enforcement is turned on.
            $operator = 'or'
            if (-not $clearing) {
                Write-Warning "No existing MFA rules group found; creating an <or> group for the IP ranges."
            }
        }

        # Preserve every non-ip-range rule (e.g. <totp>) verbatim
        $preserved = ''
        if ($groupNode) {
            foreach ($child in $groupNode.ChildNodes) {
                if ($child.NodeType -eq 'Element' -and $child.Name -ne 'ip-range') {
                    $preserved += $child.OuterXml
                }
            }
        }

        # Build the new ip-range entries as <from>/<to>. Each CIDR maps to a single
        # contiguous range (network address .. broadcast address). We store from/to
        # rather than <cidr> because the WebApp "IP Ranges" page hangs on CIDR-based
        # rules (MR !44); from/to is the representation the frontend renders safely.
        $ipRangeXml = ''
        foreach ($cidr in $normalized) {
            $address, $prefixStr = $cidr -split '/'
            $range = Get-KeepitIPv4Range -Address $address -PrefixLength ([int]$prefixStr)
            $ipRangeXml += "<ip-range><from>$($range.From)</from><to>$($range.To)</to></ip-range>"
        }

        $newMfa = "<mfa><enabled>$enabled</enabled><rules><$operator>$preserved$ipRangeXml</$operator></rules></mfa>"
        Write-Verbose "New MFA body: $newMfa"

        $rangeList = ($normalized -join ', ')
        $target = "account $userId MFA trusted-IP allowlist"
        $action = if ($clearing) {
            "Remove all allowed IP ranges (empty the allowlist)"
        }
        else {
            "Set allowed IP ranges to: $rangeList"
        }
        if (-not $PSCmdlet.ShouldProcess($target, $action)) {
            return
        }

        $headers = @{
            'Authorization' = $authHeader
            'Accept'        = 'application/vnd.keepit.v4+xml'
            'Content-Type'  = 'application/xml'
        }
        $uri = "$baseUrl/users/$userId/mfa"
        Write-Verbose "PUT $uri"

        try {
            $response = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $newMfa -ErrorAction Stop
            Write-Verbose "Update response: $response"
        }
        catch {
            $detail = $null
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $detail = $_.ErrorDetails.Message
            }
            else {
                $detail = $_.Exception.Message
            }

            if ($detail -match 'Primary credentials') {
                throw "Updating the IP allowlist requires primary account credentials (a user login), not an API token. Pass -Credential with your primary Keepit account credentials. (Server said: $detail)"
            }
            elseif ($detail -match 'Forbidden' -or $_.Exception.Response.StatusCode.value__ -eq 403) {
                throw "Access denied updating the IP allowlist. The credential's role must include the 'Enable and configure MFA' permission (for example, Master Admin); roles such as SSO Admin cannot modify MFA settings. (Server said: $detail)"
            }
            throw
        }

        if ($clearing) {
            Write-Verbose "Allowed IP ranges cleared (allowlist emptied)."
        }
        else {
            Write-Verbose "Allowed IP ranges updated: $rangeList"
        }

        if ($PassThru) {
            Get-KeepitAllowedIPRange -Credential $Credential -Environment $Environment
        }
    }
    catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new("Failed to update allowed IP ranges: $($_.Exception.Message)", $_.Exception),
                'KeepitApiError',
                [System.Management.Automation.ErrorCategory]::WriteError,
                $null
            )
        )
    }
}

#endregion
