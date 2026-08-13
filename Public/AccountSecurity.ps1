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
#       <and>
#         <totp></totp>
#         <or>
#           <ip-range><from>10.20.0.0</from><to>10.20.255.255</to></ip-range>
#           <ip-range><cidr>10.20.0.0/16</cidr></ip-range>
#           <ip-range><ip>192.168.1.0</ip><mask>24</mask></ip-range>
#         </or>
#       </and>
#     </rules>
#   </mfa>
#
# GROUP NESTING IS SIGNIFICANT (TAC-342). Every rule in an <and> group must match.
# Two or more <ip-range> rules as direct <and> siblings can never all match the
# one source address of a request, so such an allowlist denies access to everyone
# once MFA enforcement is on. Trusted-IP ranges are therefore alternatives and
# must share an <or> group, which the WebApp nests inside the outer <and> next to
# the MFA method. This module writes the same shape and reads <ip-range> rules at
# any depth.
#
# An <ip-range> may be stored as <from>/<to>, as <cidr>, or as <ip>+<mask>. This
# module WRITES from/to only: the WebApp "IP Ranges" page hangs on CIDR-based
# rules (MR !44), so each input CIDR is converted to its from/to range on write.
# Get-KeepitAllowedIPRange reads all three forms and reports the equivalent CIDR
# whenever a from/to range is one aligned CIDR block.
#
# IP-range rules share the <rules> group with the MFA method (<totp>), so writes
# are read-modify-write: <enabled>, the outer group operator, and all non-ip rules
# are preserved; only the <ip-range> entries are managed here.

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
    Converts one <ip-range> XML element to a From/To range object.
.DESCRIPTION
    Internal helper. Reads the three storage forms the API accepts (<cidr>,
    <ip>+<mask>, and <from>/<to>) and returns the equivalent inclusive range.
    Returns $null for an element in none of those forms.
.OUTPUTS
    PSCustomObject with From, To, Cidr, PrefixLength and Notation, or $null.
#>
function ConvertFrom-KeepitIPRangeNode {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlElement]$Node
    )

    $cidr = $null
    $prefix = $null

    $cidrNode = $Node.ChildNodes | Where-Object { $_.Name -eq 'cidr' } | Select-Object -First 1
    $ipNode = $Node.ChildNodes | Where-Object { $_.Name -eq 'ip' } | Select-Object -First 1
    $maskNode = $Node.ChildNodes | Where-Object { $_.Name -eq 'mask' } | Select-Object -First 1
    $fromNode = $Node.ChildNodes | Where-Object { $_.Name -eq 'from' } | Select-Object -First 1
    $toNode = $Node.ChildNodes | Where-Object { $_.Name -eq 'to' } | Select-Object -First 1

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
        $range = [PSCustomObject]@{
            From = $fromNode.InnerText.Trim()
            To   = $toNode.InnerText.Trim()
        }
        $notation = 'range'
        # Rules written by this module are stored as from/to; surface the
        # equivalent CIDR when the range is one aligned block so callers
        # still see .Cidr / .PrefixLength.
        $derivedCidr = ConvertTo-KeepitCidrFromRange -From $range.From -To $range.To
        if ($derivedCidr) {
            $cidr = $derivedCidr
            $prefix = [int]($derivedCidr -split '/')[1]
        }
    }
    else {
        return $null
    }

    return [PSCustomObject]@{
        From         = $range.From
        To           = $range.To
        Cidr         = $cidr
        PrefixLength = $prefix
        Notation     = $notation
    }
}

<#
.SYNOPSIS
    Enumerates the <ip-range> rules in an MFA configuration, at any depth.
.DESCRIPTION
    Internal helper. The rules group nests: the WebApp stores trusted-IP ranges in
    an <or> group inside the outer <and> group, so IP-range rules are not always
    direct children of the outer group. This walks every <ip-range> element under
    <rules> and reports the operator of the group that holds each one.
.OUTPUTS
    PSCustomObject[] with From, To, Cidr, PrefixLength, Notation and Operator.
#>
function Get-KeepitIPRangeRuleInternal {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [xml]$MfaXml
    )

    $rulesNode = $MfaXml.SelectSingleNode('/mfa/rules')
    if ($null -eq $rulesNode) {
        Write-Verbose "No <rules> element present; no IP ranges configured."
        return
    }

    foreach ($node in $rulesNode.SelectNodes('.//ip-range')) {
        $range = ConvertFrom-KeepitIPRangeNode -Node $node
        if ($null -eq $range) {
            Write-Warning "Skipping an <ip-range> rule in an unrecognised format: $($node.OuterXml)"
            continue
        }

        [PSCustomObject]@{
            From         = $range.From
            To           = $range.To
            Cidr         = $range.Cidr
            PrefixLength = $range.PrefixLength
            Notation     = $range.Notation
            Operator     = $node.ParentNode.Name
        }
    }
}

<#
.SYNOPSIS
    Warns when the IP-range rules in an MFA configuration deny access to everyone.
.DESCRIPTION
    Internal helper. Two or more <ip-range> rules in the same <and> group must all
    match the one source address of a request. When their ranges do not overlap,
    no address can match, so an enabled allowlist locks out every user (TAC-342).
#>
function Write-KeepitIPRangeRuleWarning {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [xml]$MfaXml
    )

    $rulesNode = $MfaXml.SelectSingleNode('/mfa/rules')
    if ($null -eq $rulesNode) { return }

    foreach ($group in $rulesNode.SelectNodes('.//and')) {
        $nodes = @($group.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -eq 'ip-range' })
        if ($nodes.Count -lt 2) { continue }

        $ranges = @($nodes | ForEach-Object { ConvertFrom-KeepitIPRangeNode -Node $_ } | Where-Object { $_ })
        if ($ranges.Count -lt 2) { continue }

        $widestFrom = ($ranges | ForEach-Object { ConvertTo-KeepitIPv4UInt32 -Address $_.From } | Measure-Object -Maximum).Maximum
        $narrowestTo = ($ranges | ForEach-Object { ConvertTo-KeepitIPv4UInt32 -Address $_.To } | Measure-Object -Minimum).Minimum

        if ($widestFrom -gt $narrowestTo) {
            Write-Warning ("The allowlist cannot be satisfied: $($ranges.Count) IP-range rules are combined with AND, and the ranges do not overlap, " +
                "so no address matches all of them. While MFA enforcement is on, this denies access to every user. " +
                "Run Update-KeepitAllowedIPRange to rewrite the ranges as alternatives (an OR group).")
        }
        else {
            Write-Warning ("$($ranges.Count) IP-range rules are combined with AND, so only addresses inside every one of them are allowed. " +
                "Run Update-KeepitAllowedIPRange to rewrite the ranges as alternatives (an OR group).")
        }
    }
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

    Rules are reported at any depth in the rules group, so ranges added in the
    Keepit WebApp (which nests them in an <or> group) are listed too. The .Operator
    property names the group that holds each rule: 'or' means the ranges are
    alternatives, and any address in any range is allowed. Several rules with
    Operator 'and' must all match one source address, which usually cannot happen;
    this cmdlet warns when it finds such a set.

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
        - Operator: The operator of the group holding the rule ('or' = the ranges
                    are alternatives; 'and' = every rule in the group must match)

    String - Raw <mfa> XML when -Raw is specified.
.NOTES
    Ranges are only enforced when account MFA is enabled and the account uses the
    trusted-IP rules for access control. Use -Raw to inspect the <enabled> flag
    and the full rules structure.
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

        # Report every <ip-range> rule, at whatever depth it sits in the rules
        # group, and warn when the combination denies access to everyone.
        Write-KeepitIPRangeRuleWarning -MfaXml $mfa.Xml
        Get-KeepitIPRangeRuleInternal -MfaXml $mfa.Xml
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
    read-modify-write operation: the <enabled> flag, the outer rules group operator,
    and all non-IP rules (such as the <totp> MFA method) are preserved; every
    existing <ip-range> entry, at any depth, is replaced.

    The ranges are written as alternatives, in one <or> group inside the outer rules
    group, which is the structure the Keepit WebApp uses. Any address in any of the
    ranges is then allowed.

    Each input CIDR is written as a <from>/<to> address range (the CIDR's network
    and broadcast addresses), not as a <cidr> element. The Keepit WebApp "IP
    Ranges" page hangs on CIDR-based rules, so from/to is the storage form the
    frontend renders safely. Get-KeepitAllowedIPRange reports the equivalent CIDR
    on read-back.

    Because -IPRange replaces the full allowlist, include every range you want to
    keep. To add to the existing list, read it first with Get-KeepitAllowedIPRange
    (see the BulkSiteConfig/IPAllowlist example). To remove every range and empty
    the allowlist, use -Clear instead of -IPRange; this removes all IP-range rules,
    including ranges added in the WebApp, while preserving the <enabled> flag and
    non-IP rules such as TOTP.

    IMPORTANT: Writing MFA/security settings requires PRIMARY account credentials
    (a user login, not an API token) whose role grants the "Enable and configure
    MFA" permission (for example, Master Admin). A non-primary token is rejected
    with "Primary credentials required"; a primary login without the MFA
    permission is rejected with "Forbidden". Supply such credentials via
    -Credential.

    This cmdlet does NOT change the <enabled> flag. On an account with enforcement
    on, an allowlist that does not include your own public IP address denies you
    access, so review the account's MFA state (Get-KeepitAllowedIPRange -Raw) before
    you enable enforcement.
.PARAMETER IPRange
    One or more IPv4 CIDR ranges (e.g. '10.20.0.0/16') that make up the complete
    desired allowlist. Replaces any existing IP-range rules. The ranges are written
    as alternatives (an <or> group), so an address in any one of them is allowed.
.PARAMETER Clear
    Remove every IP-range rule, emptying the allowlist. Mutually exclusive with
    -IPRange. The <enabled> flag, the outer rules group operator, and non-IP rules
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

    Sets three /16 trusted ranges in one operation without prompting. The ranges are
    alternatives: an address in any one of the three is allowed.
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

        # Edit the returned document in place, so anything this module does not
        # manage (the <enabled> flag, the MFA method, any future element) survives.
        $doc = $mfa.Xml
        $root = $doc.DocumentElement

        $enabledNode = $root.SelectSingleNode('enabled')
        if ($null -eq $enabledNode) {
            $enabledNode = $doc.CreateElement('enabled')
            $enabledNode.InnerText = 'false'
            [void]$root.PrependChild($enabledNode)
        }
        $enabled = $enabledNode.InnerText.Trim()

        $rulesNode = $root.SelectSingleNode('rules')
        if ($null -eq $rulesNode) {
            $rulesNode = $doc.CreateElement('rules')
            [void]$root.AppendChild($rulesNode)
        }

        # The outer group holds the MFA method and the trusted-IP group. Keep its
        # operator: rewriting <or> to <and> would start requiring TOTP *and* a
        # trusted IP. A missing group is created as <and>, the shape the WebApp
        # writes; with only IP ranges inside it, <and> of one <or> group means the
        # same thing as <or> on its own.
        $groupNode = $rulesNode.ChildNodes |
            Where-Object { $_.NodeType -eq 'Element' -and $_.Name -in @('and', 'or') } |
            Select-Object -First 1
        if ($null -eq $groupNode) {
            $groupNode = $doc.CreateElement('and')
            [void]$rulesNode.AppendChild($groupNode)
            Write-Verbose "No existing MFA rules group found; created an <and> group."
        }

        # Drop every existing <ip-range> rule at any depth. Ranges added in the
        # WebApp sit in a nested <or> group, so a shallow sweep of the outer group
        # left them in place and -Clear did not clear them (TAC-342).
        $existing = @($rulesNode.SelectNodes('.//ip-range'))
        foreach ($old in $existing) {
            [void]$old.ParentNode.RemoveChild($old)
        }
        Write-Verbose "Removed $($existing.Count) existing ip-range rule(s)."

        # Remove nested groups the sweep left empty, deepest first, so no <or></or>
        # husk remains. The outer group is kept even when empty.
        $nestedGroups = @($rulesNode.SelectNodes('.//and | .//or'))
        [Array]::Reverse($nestedGroups)
        foreach ($nested in $nestedGroups) {
            if ([object]::ReferenceEquals($nested, $groupNode)) { continue }
            if (-not ($nested.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
                [void]$nested.ParentNode.RemoveChild($nested)
            }
        }

        # Write the new entries as <from>/<to>. Each CIDR maps to a single contiguous
        # range (network address .. broadcast address). We store from/to rather than
        # <cidr> because the WebApp "IP Ranges" page hangs on CIDR-based rules
        # (MR !44); from/to is the representation the frontend renders safely.
        #
        # Trusted-IP ranges are alternatives, so they must share an <or> group. As
        # direct <and> siblings they could never all match one source address, and
        # enabling enforcement locked out every user (TAC-342).
        if ($normalized.Count -gt 0) {
            $ipParent = if ($groupNode.Name -eq 'or') {
                # The outer group already ORs its rules; nesting another <or> would
                # add nothing.
                $groupNode
            }
            else {
                $orGroup = $doc.CreateElement('or')
                [void]$groupNode.AppendChild($orGroup)
                $orGroup
            }

            foreach ($cidr in $normalized) {
                $address, $prefixStr = $cidr -split '/'
                $range = Get-KeepitIPv4Range -Address $address -PrefixLength ([int]$prefixStr)
                $rangeNode = $doc.CreateElement('ip-range')
                $fromNode = $doc.CreateElement('from')
                $fromNode.InnerText = $range.From
                $toNode = $doc.CreateElement('to')
                $toNode.InnerText = $range.To
                [void]$rangeNode.AppendChild($fromNode)
                [void]$rangeNode.AppendChild($toNode)
                [void]$ipParent.AppendChild($rangeNode)
            }
        }

        $newMfa = $root.OuterXml
        Write-Verbose "New MFA body: $newMfa"

        $rangeList = ($normalized -join ', ')
        if ($enabled -eq 'true' -and $normalized.Count -gt 0) {
            Write-Warning ("Account MFA enforcement is on, so this allowlist takes effect at once. Confirm that your own public IP address " +
                "is inside one of these ranges before you continue: $rangeList")
        }
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
