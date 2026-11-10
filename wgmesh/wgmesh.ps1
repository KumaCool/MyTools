Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ProgramDataRoot = if ([string]::IsNullOrWhiteSpace($env:ProgramData)) {
    "C:\ProgramData"
} else {
    $env:ProgramData
}
$script:Root = Join-Path $script:ProgramDataRoot "wgmesh"
$script:ConfigDir = Join-Path $script:Root "configs"
$script:StateDir = Join-Path $script:Root "state"
$script:ToolCache = @{}

function Fail([string]$Message) {
    throw $Message
}

function Show-Usage {
    @"
wgmesh manages a single-Hub WireGuard network.

Usage:
  wgmesh.ps1 host init --network-name ID --node-id ID --transport tailscale|public --overlay-cidr CIDR --address CIDR --endpoint HOST:PORT [--mtu BYTES] [--forward-firewall external] [--no-autostart]
  wgmesh.ps1 node join --network-name ID --node-id ID --transport tailscale|public --overlay-cidr CIDR --address CIDR --hub-endpoint HOST:PORT --hub-public-key KEY [--mtu BYTES] [--no-autostart]
  wgmesh.ps1 host add-node --network-name ID --node-id ID --address CIDR --node-public-key KEY [--peer-address IPv4/32 ...]
  wgmesh.ps1 host set-routes --network-name ID --node-id ID [--peer-address IPv4/32 ...]
  wgmesh.ps1 node set-routes --network-name ID [--peer-address IPv4/32 ...]
  wgmesh.ps1 host remove-node --network-name ID --node-id ID
  wgmesh.ps1 node uninstall --network-name ID --node-id ID
  wgmesh.ps1 host uninstall --network-name ID
  wgmesh.ps1 status [--network-name ID] [--json]
"@
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-IsAdministrator)) {
        Fail "administrator privileges are required"
    }
}

function Get-ToolPath([string]$Name) {
    if ($script:ToolCache.ContainsKey($Name)) {
        return $script:ToolCache[$Name]
    }

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $script:ToolCache[$Name] = $command.Source
        return $command.Source
    }

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates += (Join-Path $env:ProgramFiles ("WireGuard\" + $Name))
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} ("WireGuard\" + $Name))
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $script:ToolCache[$Name] = $candidate
            return $candidate
        }
    }

    Fail "required tool '$Name' was not found"
}

function Assert-Tools([string[]]$Names) {
    foreach ($name in $Names) {
        [void](Get-ToolPath $name)
    }
}

function Assert-HostForwardingTools {
    $setCommand = Get-Command "Set-NetIPInterface" -ErrorAction SilentlyContinue
    $getCommand = Get-Command "Get-NetIPInterface" -ErrorAction SilentlyContinue
    if ($null -eq $setCommand -or $null -eq $getCommand) {
        Fail "Hub forwarding requires Set-NetIPInterface and Get-NetIPInterface"
    }
    if (-not $setCommand.Parameters.ContainsKey("PolicyStore")) {
        Fail "Hub forwarding requires Set-NetIPInterface PolicyStore support"
    }
}

function Test-ToolAvailable([string]$Name) {
    try {
        [void](Get-ToolPath $Name)
        return $true
    } catch {
        return $false
    }
}

function Install-WireGuardPackage {
    $winget = Get-Command "winget.exe" -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        Fail "WireGuard tools are missing and winget.exe is unavailable; install WireGuard for Windows or App Installer/WinGet manually, then rerun"
    }

    $output = @(
        & $winget.Source install `
            --id WireGuard.WireGuard `
            --exact `
            --silent `
            --accept-source-agreements `
            --accept-package-agreements `
            2>&1
    )
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $text = (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            Fail "winget failed to install WireGuard for Windows with exit code $exitCode"
        }
        Fail "winget failed to install WireGuard for Windows with exit code ${exitCode}: $text"
    }
    $script:ToolCache = @{}
}

function Ensure-Tools([string[]]$Names) {
    $missing = @(
        foreach ($name in $Names) {
            if (-not (Test-ToolAvailable $name)) {
                $name
            }
        }
    )
    $wireguardMissing = @($missing | Where-Object { $_ -in @("wg.exe", "wireguard.exe") })
    if ($wireguardMissing.Count -gt 0) {
        Install-WireGuardPackage
    }
    Assert-Tools $Names
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$InputText,
        [switch]$AllowFailure
    )

    $path = Get-ToolPath $Name
    if ($PSBoundParameters.ContainsKey("InputText")) {
        $output = @($InputText | & $path @Arguments 2>&1)
    } else {
        $output = @(& $path @Arguments 2>&1)
    }
    $exitCode = $LASTEXITCODE
    $text = (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            Fail "$Name failed with exit code $exitCode"
        }
        Fail "$Name failed with exit code $exitCode`: $text"
    }
    return [pscustomobject]@{
        Output   = $text
        ExitCode = $exitCode
    }
}

function New-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $Path -Force)
        return $true
    }
    return $false
}

function Protect-Path([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRule($rule)
    }

    $inheritance = [System.Security.AccessControl.InheritanceFlags]::None
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    }
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    foreach ($sid in @("S-1-5-18", "S-1-5-32-544")) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            $fullControl,
            $inheritance,
            $propagation,
            $allow
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Ensure-Storage {
    if (New-Directory $script:Root) {
        Protect-Path $script:Root
    }
    if (New-Directory $script:ConfigDir) {
        Protect-Path $script:ConfigDir
    }
    if (New-Directory $script:StateDir) {
        Protect-Path $script:StateDir
    }
}

function Validate-Id([string]$Value, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 48 -or
        $Value -notmatch "^[a-z0-9][a-z0-9_-]*$") {
        Fail "$Name must start with a lowercase letter or digit, contain only lowercase letters, digits, '_' or '-', and be at most 48 characters"
    }
    return $Value
}

function Validate-Transport([string]$Value) {
    if ($Value -ne "tailscale" -and $Value -ne "public") {
        Fail "transport must be tailscale or public"
    }
    return $Value
}

function Validate-Mtu([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value -notmatch "^[0-9]+$") {
        Fail "mtu must be a decimal integer between 576 and 65535"
    }
    $mtu = 0
    if (-not [int]::TryParse($Value, [ref]$mtu) -or $mtu -lt 576 -or $mtu -gt 65535) {
        Fail "mtu must be a decimal integer between 576 and 65535"
    }
    return "$mtu"
}

function Get-OptionValues([hashtable]$Options, [string]$Name) {
    if (-not $Options.ContainsKey($Name)) {
        return @()
    }
    return @($Options[$Name] | ForEach-Object { "$_" })
}

function Validate-PeerAddresses([object[]]$Values, [string]$OverlayText, [string]$OwnAddress) {
    $overlay = Parse-Cidr $OverlayText "overlay-cidr" $false
    $seen = New-Object Collections.Generic.HashSet[string]
    $result = New-Object Collections.Generic.List[string]
    foreach ($value in @($Values)) {
        $cidr = Parse-Cidr "$value" "peer-address" $true
        if (-not [string]::IsNullOrWhiteSpace($OwnAddress) -and
            $cidr.IP.Equals(([Net.IPAddress]::Parse(($OwnAddress -split "/")[0])))) {
            Fail "peer-address '$value' conflicts with the local address"
        }
        if ($cidr.Prefix -ne 32) {
            Fail "peer-address must use /32"
        }
        if (Test-AddressInCidr $cidr.IP $overlay) {
            Fail "peer-address '$value' overlaps overlay-cidr '$OverlayText'"
        }
        $canonical = "$($cidr.IP)/32"
        if (-not $seen.Add($canonical)) {
            Fail "peer-address '$value' is duplicated"
        }
        [void]$result.Add($canonical)
    }
    return @($result)
}

function Get-EndpointIpv4Addresses([string]$EndpointText) {
    $endpoint = Parse-Endpoint $EndpointText "endpoint"
    $literal = $null
    if ([Net.IPAddress]::TryParse($endpoint.Host, [ref]$literal)) {
        if ($literal.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
            return @($literal.ToString())
        }
        return @()
    }
    try {
        return @([Net.Dns]::GetHostAddresses($endpoint.Host) |
            Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } |
            ForEach-Object { $_.ToString() })
    } catch {
        Fail "cannot resolve endpoint '$($endpoint.Host)' to verify underlay routing"
    }
}

function Get-EndpointAddresses([string]$EndpointText) {
    $endpoint = Parse-Endpoint $EndpointText "endpoint"
    $literal = $null
    if ([Net.IPAddress]::TryParse($endpoint.Host, [ref]$literal)) {
        return @([pscustomobject]@{
            Address = $literal.ToString()
            AddressFamily = $literal.AddressFamily
        })
    }
    try {
        return @([Net.Dns]::GetHostAddresses($endpoint.Host) |
            ForEach-Object {
                [pscustomobject]@{
                    Address = $_.ToString()
                    AddressFamily = $_.AddressFamily
                }
            })
    } catch {
        Fail "cannot resolve Endpoint '$($endpoint.Host)'"
    }
}

function Get-EndpointPathRecord([string]$EndpointText, [string]$WireGuardInterface) {
    $paths = New-Object Collections.Generic.List[object]
    $details = New-Object Collections.Generic.List[string]
    $hasWireGuardRoute = $false
    try {
        $addresses = @(Get-EndpointAddresses $EndpointText)
        if ($addresses.Count -eq 0) {
            throw "Endpoint resolved to no addresses"
        }
        foreach ($address in $addresses) {
            $routeObjects = @(
                Find-NetRoute -RemoteIPAddress $address.Address -ErrorAction Stop |
                    Where-Object {
                        $_.PSObject.Properties["DestinationPrefix"] -and
                            -not [string]::IsNullOrWhiteSpace($_.DestinationPrefix)
                    }
            )
            if ($routeObjects.Count -eq 0) {
                throw "no selected route was returned for $($address.Address)"
            }
            $route = $routeObjects[$routeObjects.Count - 1]
            $interfaceAlias = [string]$route.InterfaceAlias
            if ([string]::IsNullOrWhiteSpace($interfaceAlias) -and
                $route.PSObject.Properties["InterfaceIndex"]) {
                $interface = @(
                    Get-NetIPInterface -InterfaceIndex $route.InterfaceIndex `
                        -AddressFamily $address.AddressFamily -ErrorAction Stop
                ) | Select-Object -First 1
                if ($null -eq $interface) {
                    throw "selected route interface could not be resolved"
                }
                $interfaceAlias = [string]$interface.InterfaceAlias
            }
            if ([string]::IsNullOrWhiteSpace($interfaceAlias)) {
                throw "selected route has no interface identity"
            }
            $routeState = if ($interfaceAlias -ieq $WireGuardInterface) {
                $hasWireGuardRoute = $true
                "CONFIG_DRIFT"
            } else {
                "UNDERLAY"
            }
            $nextHop = if ($route.PSObject.Properties["NextHop"]) {
                [string]$route.NextHop
            } else {
                ""
            }
            [void]$paths.Add([pscustomobject]@{
                address = $address.Address
                destination_prefix = [string]$route.DestinationPrefix
                interface = $interfaceAlias
                next_hop = $nextHop
                state = $routeState
            })
        }
    } catch {
        [void]$details.Add($_.Exception.Message)
    }
    $state = if ($hasWireGuardRoute) {
        "CONFIG_DRIFT"
    } elseif ($details.Count -gt 0 -or $paths.Count -eq 0) {
        "UNKNOWN"
    } else {
        "UNDERLAY"
    }
    return [pscustomobject]@{
        endpoint = $EndpointText
        state = $state
        paths = @($paths.ToArray())
        details = @($details.ToArray())
    }
}

function Assert-EndpointUnderlaySafe([string]$EndpointText, [object[]]$Routes) {
    if (@($Routes).Count -eq 0) {
        return
    }
    $endpoint = Parse-Endpoint $EndpointText "endpoint"
    $literal = $null
    if (-not [Net.IPAddress]::TryParse($endpoint.Host, [ref]$literal) -and
        $endpoint.Host -notmatch ":") {
        Fail "Windows cannot pin a DNS Endpoint underlay route for peer-address routes; use a fixed IPv4 Endpoint or leave peer-addresses empty"
    }
    $endpointAddresses = @(Get-EndpointIpv4Addresses $EndpointText)
    foreach ($route in @($Routes)) {
        $routeIp = "$route" -replace "/32$", ""
        if ($endpointAddresses -contains $routeIp) {
            Fail "peer-address '$route' conflicts with the WireGuard Endpoint; refusing an unverified Windows underlay route"
        }
    }
}

function Assert-HostPeerEndpointRoutesSafe([string]$Interface, [object[]]$Peers, [object[]]$Routes) {
    if (@($Routes).Count -eq 0) {
        return
    }
    $endpointOutput = Invoke-Tool "wg.exe" @("show", $Interface, "endpoints") -AllowFailure
    if ($endpointOutput.ExitCode -ne 0) {
        Fail "cannot verify peer Endpoint underlay routes; refusing Windows peer-address routes"
    }
    $known = @{}
    foreach ($line in ($endpointOutput.Output -split "`r?`n")) {
        $parts = $line.Trim() -split "\s+", 2
        if ($parts.Count -eq 2) {
            $known[$parts[0]] = $parts[1]
        }
    }
    foreach ($peer in @($Peers)) {
        if (-not $known.ContainsKey($peer.PublicKey) -or
            [string]::IsNullOrWhiteSpace($known[$peer.PublicKey]) -or
            $known[$peer.PublicKey] -eq "(none)") {
            Fail "peer '$($peer.NodeId)' has no learned Endpoint; refusing Windows peer-address routes until its underlay path is verifiable"
        }
        $endpoint = Parse-Endpoint $known[$peer.PublicKey] "peer endpoint"
        $endpointAddresses = @(Get-EndpointIpv4Addresses $endpoint.Text)
        if ($endpointAddresses.Count -eq 0) {
            Fail "peer '$($peer.NodeId)' Endpoint has no IPv4 underlay address; refusing Windows peer-address routes"
        }
        foreach ($route in @($Routes)) {
            $routeIp = "$route" -replace "/32$", ""
            if ($endpointAddresses -contains $routeIp) {
                Fail "peer-address '$route' matches peer '$($peer.NodeId)' Endpoint; refusing a WireGuard route loop"
            }
        }
    }
}

function Get-ConfiguredMtu([string]$ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return $null
    }
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
        if ($line -match "^\s*MTU\s*=\s*([0-9]+)\s*(?:#.*)?$") {
            return Validate-Mtu $Matches[1]
        }
    }
    return $null
}

function Get-EffectiveMtu([string]$Interface) {
    try {
        $interfaces = @(Get-NetIPInterface -InterfaceAlias $Interface `
            -AddressFamily IPv4 -ErrorAction Stop)
        if ($interfaces.Count -gt 0 -and $interfaces[0].NlMtu -gt 0) {
            return [int]$interfaces[0].NlMtu
        }
    } catch {
        # Report UNKNOWN when the platform cannot return the live interface MTU.
    }
    return "UNKNOWN"
}

function Join-AddressList([string]$Primary, [object[]]$Additional) {
    $values = New-Object Collections.Generic.List[string]
    [void]$values.Add($Primary)
    foreach ($value in @($Additional)) {
        if (-not [string]::IsNullOrWhiteSpace("$value")) {
            [void]$values.Add("$value")
        }
    }
    return ($values -join ", ")
}

function Parse-Cidr([string]$Value, [string]$Name, [bool]$HostOnly) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch "^(.+)/([0-9]{1,3})$") {
        Fail "$Name must be an IP address with a CIDR prefix"
    }
    $ip = $null
    try {
        $ip = [Net.IPAddress]::Parse($Matches[1])
    } catch {
        Fail "$Name contains an invalid IP address"
    }
    if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        Fail "$Name must use an IPv4 address"
    }
    $prefix = [int]$Matches[2]
    $maxPrefix = if ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { 32 } else { 128 }
    if ($prefix -lt 1 -or $prefix -gt $maxPrefix) {
        Fail "$Name has an invalid prefix length"
    }
    if ($HostOnly -and $prefix -ne $maxPrefix) {
        Fail "$Name must use /$maxPrefix"
    }
    return [pscustomobject]@{
        Text       = $Value
        IP         = $ip
        Prefix     = $prefix
        MaxPrefix  = $maxPrefix
        AddressFamily = $ip.AddressFamily
    }
}

function Test-AddressInCidr($Address, $Cidr) {
    if ($Address.AddressFamily -ne $Cidr.AddressFamily) {
        return $false
    }
    $addressBytes = $Address.GetAddressBytes()
    $networkBytes = $Cidr.IP.GetAddressBytes()
    $wholeBytes = [int][Math]::Floor($Cidr.Prefix / 8)
    $remainingBits = $Cidr.Prefix % 8
    for ($index = 0; $index -lt $wholeBytes; $index++) {
        if ($addressBytes[$index] -ne $networkBytes[$index]) {
            return $false
        }
    }
    if ($remainingBits -gt 0) {
        $mask = (255 -shl (8 - $remainingBits)) -band 255
        if (($addressBytes[$wholeBytes] -band $mask) -ne ($networkBytes[$wholeBytes] -band $mask)) {
            return $false
        }
    }
    return $true
}

function Test-CidrOverlap($Left, $Right) {
    return ((Test-AddressInCidr $Left.IP $Right) -or
        (Test-AddressInCidr $Right.IP $Left))
}

function Get-LocalIpv4Networks {
    $networks = New-Object Collections.Generic.List[string]
    try {
        foreach ($address in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)) {
            if ($address.PrefixLength -gt 0 -and $address.PrefixLength -le 32) {
                [void]$networks.Add("$($address.IPAddress)/$($address.PrefixLength)")
            }
        }
        foreach ($route in @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace($route.DestinationPrefix) -or
                $route.DestinationPrefix -eq "0.0.0.0/0") {
                continue
            }
            [void]$networks.Add([string]$route.DestinationPrefix)
        }
    } catch {
        Fail "cannot inspect local IPv4 addresses/routes for overlay-cidr conflicts: $($_.Exception.Message)"
    }
    return $networks
}

function Assert-OverlayAvailable([string]$NetworkId, [string]$OverlayText, [string]$IgnoredStatePath) {
    $overlay = Parse-Cidr $OverlayText "overlay-cidr" $false
    $stateFiles = @()
    if (Test-Path -LiteralPath $script:StateDir -PathType Container) {
        $stateFiles = @(Get-ChildItem -LiteralPath $script:StateDir -Filter "*.state" -File)
    }
    foreach ($stateFile in $stateFiles) {
        if ([IO.Path]::GetFullPath($stateFile.FullName) -eq
            [IO.Path]::GetFullPath($IgnoredStatePath)) {
            continue
        }
        $values = Read-KeyValueFile $stateFile.FullName
        if (-not $values.ContainsKey("overlay_cidr")) {
            continue
        }
        $existing = Parse-Cidr $values.overlay_cidr "stored overlay-cidr" $false
        if (Test-CidrOverlap $overlay $existing) {
            Fail "overlay-cidr '$OverlayText' overlaps existing wgmesh network state '$($values.network_id)' ($($values.overlay_cidr))"
        }
    }

    foreach ($networkText in @(Get-LocalIpv4Networks)) {
        if ([string]::IsNullOrWhiteSpace($networkText) -or $networkText -match "/0$") {
            continue
        }
        $existing = Parse-Cidr $networkText "local IPv4 network" $false
        if (Test-CidrOverlap $overlay $existing) {
            Fail "overlay-cidr '$OverlayText' overlaps existing local IPv4 network '$networkText'"
        }
    }
}

function Validate-PublicKey([string]$Value, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch "^[A-Za-z0-9+/]{43}=$") {
        Fail "$Name must be a WireGuard public key"
    }
    return $Value
}

function Parse-Endpoint([string]$Value, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        Fail "$Name is required"
    }
    $endpointHost = ""
    $portText = ""
    if ($Value.StartsWith("[")) {
        if ($Value -notmatch "^\[([^\]]+)\]:([0-9]+)$") {
            Fail "$Name must be HOST:PORT or [IPv6]:PORT"
        }
        $endpointHost = $Matches[1]
        $parsedHost = $null
        if (-not [Net.IPAddress]::TryParse($endpointHost, [ref]$parsedHost) -or
            $parsedHost.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetworkV6) {
            Fail "$Name must use a valid bracketed IPv6 address"
        }
        $portText = $Matches[2]
    } else {
        $separator = $Value.LastIndexOf(":")
        if ($separator -le 0 -or $separator -eq ($Value.Length - 1)) {
            Fail "$Name must be HOST:PORT"
        }
        $endpointHost = $Value.Substring(0, $separator)
        $portText = $Value.Substring($separator + 1)
        if ($endpointHost.Contains(":")) {
            Fail "$Name must bracket an IPv6 host"
        }
        if ($endpointHost -notmatch "^[A-Za-z0-9.-]+$") {
            Fail "$Name host contains invalid characters"
        }
    }
    $port = 0
    if (-not [int]::TryParse($portText, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        Fail "$Name has an invalid UDP port"
    }
    return [pscustomobject]@{
        Text = $Value
        Host = $endpointHost
        Port = $port
    }
}

function Get-InterfaceName([string]$NetworkId) {
    $prefix = "wgmesh-"
    if ($NetworkId.Length -le 8) {
        return $prefix + $NetworkId
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($NetworkId)
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    $hex = ([BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
    return $prefix + $hex.Substring(0, 8)
}

function Get-NetworkPaths([string]$NetworkId) {
    $interface = Get-InterfaceName $NetworkId
    return [pscustomobject]@{
        NetworkId  = $NetworkId
        Interface  = $interface
        ConfigPath = Join-Path $script:ConfigDir ($interface + ".conf")
        StatePath  = Join-Path $script:StateDir ($NetworkId + ".state")
        PeersPath  = Join-Path $script:StateDir ($NetworkId + ".peers")
    }
}

function Read-KeyValueFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "state file not found: $Path"
    }
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $separator = $line.IndexOf("=")
        if ($separator -le 0) {
            Fail "invalid state file: $Path"
        }
        $key = $line.Substring(0, $separator)
        $value = $line.Substring($separator + 1)
        if ($values.ContainsKey($key)) {
            Fail "duplicate state key '$key' in $Path"
        }
        $values[$key] = $value
    }
    return $values
}

function Write-KeyValueFile([string]$Path, [hashtable]$Values) {
    $lines = New-Object Collections.Generic.List[string]
    foreach ($key in ($Values.Keys | Sort-Object)) {
        [void]$lines.Add("$key=$($Values[$key])")
    }
    $temporary = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllLines($temporary, $lines, (New-Object Text.UTF8Encoding($false)))
        Protect-Path $temporary
        Commit-AtomicFile $temporary $Path
    } catch {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Commit-AtomicFile([string]$Temporary, [string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        [IO.File]::Replace($Temporary, $Path, $null)
    } else {
        [IO.File]::Move($Temporary, $Path)
    }
}

function Read-Peers([string]$Path) {
    $peers = New-Object Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $peers
    }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $parts = $line.Split("|")
        if ($parts.Count -lt 3 -or $parts.Count -gt 4) {
            Fail "invalid peer state file: $Path"
        }
        $routes = if ($parts.Count -eq 4 -and $parts[3] -ne "") {
            @($parts[3] -split ",")
        } else {
            @()
        }
        [void]$peers.Add([pscustomobject]@{
            NodeId     = $parts[0]
            Address    = $parts[1]
            PublicKey  = $parts[2]
            Routes     = $routes
        })
    }
    return $peers
}

function Get-CanonicalPeerAssignment([string]$PublicKey, [object[]]$AllowedIPs) {
    if ([string]::IsNullOrWhiteSpace($PublicKey)) {
        Fail "peer record has no public key"
    }
    $addresses = @(
        foreach ($address in @($AllowedIPs)) {
            if (-not [string]::IsNullOrWhiteSpace("$address")) {
                "$address".Trim()
            }
        }
    ) | Sort-Object -CaseSensitive
    return "$PublicKey|$($addresses -join ',')"
}

function Get-StatePeerAssignments([object[]]$Peers) {
    $assignments = New-Object Collections.Generic.List[string]
    foreach ($peer in @($Peers)) {
        $allowed = @($peer.Address) + @($peer.Routes)
        [void]$assignments.Add(
            (Get-CanonicalPeerAssignment $peer.PublicKey $allowed)
        )
    }
    return @($assignments.ToArray() | Sort-Object -CaseSensitive)
}

function Get-ConfigPeerAssignments([string]$ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Fail "managed WireGuard config is missing: $ConfigPath"
    }
    $assignments = New-Object Collections.Generic.List[string]
    $inPeer = $false
    $publicKey = ""
    $allowedIPs = @()
    $sawAllowedIPs = $false
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }
        if ($trimmed -match "^\[([^\]]+)\]$") {
            if ($inPeer) {
                if ([string]::IsNullOrWhiteSpace($publicKey) -or -not $sawAllowedIPs) {
                    Fail "managed WireGuard config contains an incomplete peer section"
                }
                [void]$assignments.Add(
                    (Get-CanonicalPeerAssignment $publicKey $allowedIPs)
                )
            }
            switch -Regex ($Matches[1]) {
                "^Interface$" {
                    $inPeer = $false
                    $publicKey = ""
                    $allowedIPs = @()
                    $sawAllowedIPs = $false
                }
                "^Peer$" {
                    $inPeer = $true
                    $publicKey = ""
                    $allowedIPs = @()
                    $sawAllowedIPs = $false
                }
                default {
                    Fail "managed WireGuard config contains an unknown section"
                }
            }
            continue
        }
        if (-not $inPeer) {
            continue
        }
        if ($trimmed -match "^PublicKey\s*=\s*(\S+)\s*$") {
            if (-not [string]::IsNullOrWhiteSpace($publicKey)) {
                Fail "managed WireGuard config contains duplicate peer PublicKey fields"
            }
            $publicKey = $Matches[1]
        } elseif ($trimmed -match "^AllowedIPs\s*=\s*(.*?)\s*$") {
            if ($sawAllowedIPs) {
                Fail "managed WireGuard config contains duplicate peer AllowedIPs fields"
            }
            $allowedIPs = @(
                foreach ($address in ($Matches[1] -split ",")) {
                    if (-not [string]::IsNullOrWhiteSpace($address)) {
                        $address.Trim()
                    }
                }
            )
            $sawAllowedIPs = $true
        }
    }
    if ($inPeer) {
        if ([string]::IsNullOrWhiteSpace($publicKey) -or -not $sawAllowedIPs) {
            Fail "managed WireGuard config contains an incomplete peer section"
        }
        [void]$assignments.Add(
            (Get-CanonicalPeerAssignment $publicKey $allowedIPs)
        )
    }
    return @($assignments.ToArray() | Sort-Object -CaseSensitive)
}

function Get-RuntimePeerAssignments([string]$Dump) {
    $lines = @(
        $Dump -split "`r?`n" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($lines.Count -eq 0 -or @($lines[0] -split "`t").Count -ne 4) {
        Fail "WireGuard runtime dump has an invalid interface record"
    }
    $assignments = New-Object Collections.Generic.List[string]
    for ($index = 1; $index -lt $lines.Count; $index++) {
        $fields = @($lines[$index] -split "`t")
        if ($fields.Count -ne 8) {
            Fail "WireGuard runtime dump has an invalid peer record"
        }
        $allowedIPs = if ([string]::IsNullOrWhiteSpace($fields[3])) {
            @()
        } else {
            @($fields[3] -split ",")
        }
        [void]$assignments.Add(
            (Get-CanonicalPeerAssignment $fields[0] $allowedIPs)
        )
    }
    return @($assignments.ToArray() | Sort-Object -CaseSensitive)
}

function Get-RuntimePeerEndpointRecords([string]$Dump) {
    $lines = @(
        $Dump -split "`r?`n" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($lines.Count -eq 0 -or @($lines[0] -split "`t").Count -ne 4) {
        Fail "WireGuard runtime dump has an invalid interface record"
    }
    $records = New-Object Collections.Generic.List[object]
    for ($index = 1; $index -lt $lines.Count; $index++) {
        $fields = @($lines[$index] -split "`t")
        if ($fields.Count -ne 8) {
            Fail "WireGuard runtime dump has an invalid peer record"
        }
        [void]$records.Add([pscustomobject]@{
            public_key = $fields[0]
            endpoint = $fields[2]
        })
    }
    return @($records.ToArray())
}

function Get-RegisteredPeerIdentities([object[]]$Peers) {
    $identities = New-Object Collections.Generic.List[string]
    foreach ($peer in @($Peers)) {
        $routes = if ($null -ne $peer.Routes) { @($peer.Routes) -join "," } else { "" }
        [void]$identities.Add(
            "$($peer.NodeId)|$($peer.Address)|$($peer.PublicKey)|$routes"
        )
    }
    return @($identities.ToArray() | Sort-Object -CaseSensitive)
}

function Test-StringSetEqual([string[]]$Left, [string[]]$Right) {
    if (@($Left).Count -ne @($Right).Count) {
        return $false
    }
    $leftSorted = @($Left | Sort-Object -CaseSensitive)
    $rightSorted = @($Right | Sort-Object -CaseSensitive)
    for ($index = 0; $index -lt $leftSorted.Count; $index++) {
        if ($leftSorted[$index] -cne $rightSorted[$index]) {
            return $false
        }
    }
    return $true
}

function Get-HostPeerDrift($Loaded, [object[]]$StatePeers, [bool]$RuntimeActive) {
    $details = New-Object Collections.Generic.List[string]
    $unknown = $false
    $drifted = $false
    try {
        $expected = @(Get-StatePeerAssignments $StatePeers)
    } catch {
        [void]$details.Add("registered peer state is invalid")
        $drifted = $true
        $expected = @()
    }
    try {
        $configText = [IO.File]::ReadAllText($Loaded.Paths.ConfigPath)
        if ($configText -notmatch "(?m)^# wgmesh-managed=true\s*$" -or
            $configText -notmatch "(?m)^# wgmesh-network=$([regex]::Escape($Loaded.Values.network_id))\s*$") {
            throw "managed config ownership markers are missing"
        }
        $configured = @(Get-ConfigPeerAssignments $Loaded.Paths.ConfigPath)
        if (-not (Test-StringSetEqual $expected $configured)) {
            [void]$details.Add("managed config peer/AllowedIPs set differs from registered state")
            $drifted = $true
        }
    } catch {
        [void]$details.Add("managed config peer sections cannot be verified")
        $drifted = $true
    }
    if ($RuntimeActive) {
        $runtime = Invoke-Tool "wg.exe" @("show", $Loaded.Values.interface, "dump") -AllowFailure
        if ($runtime.ExitCode -ne 0) {
            [void]$details.Add("running WireGuard peer state cannot be read")
            $unknown = $true
        } else {
            try {
                $running = @(Get-RuntimePeerAssignments $runtime.Output)
                if (-not (Test-StringSetEqual $expected $running)) {
                    [void]$details.Add("running peer/AllowedIPs set differs from registered state")
                    $drifted = $true
                }
            } catch {
                [void]$details.Add("running WireGuard peer dump cannot be verified")
                $unknown = $true
            }
        }
    }
    return [pscustomobject]@{
        Drifted = $drifted
        Unknown = $unknown
        Details = @($details.ToArray())
    }
}

function Get-NodePeerDrift($Loaded, [bool]$RuntimeActive) {
    $state = $Loaded.Values
    $details = New-Object Collections.Generic.List[string]
    $unknown = $false
    $drifted = $false
    $routes = if ($state.ContainsKey("peer_addresses") -and
        -not [string]::IsNullOrWhiteSpace("$($state.peer_addresses)")) {
        @("$($state.peer_addresses)" -split "," |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } else {
        @()
    }
    try {
        $expected = @(
            Get-CanonicalPeerAssignment $state.hub_public_key `
                (@($state.overlay_cidr) + @($routes))
        )
    } catch {
        [void]$details.Add("node Hub peer state is invalid")
        $drifted = $true
        $expected = @()
    }
    try {
        $configText = [IO.File]::ReadAllText($Loaded.Paths.ConfigPath)
        if ($configText -notmatch "(?m)^# wgmesh-managed=true\s*$" -or
            $configText -notmatch "(?m)^# wgmesh-network=$([regex]::Escape($state.network_id))\s*$") {
            throw "managed config ownership markers are missing"
        }
        $configured = @(Get-ConfigPeerAssignments $Loaded.Paths.ConfigPath)
        if (-not (Test-StringSetEqual $expected $configured)) {
            [void]$details.Add("managed config Hub peer/AllowedIPs set differs from node state")
            $drifted = $true
        }
        $configEndpoint = $null
        foreach ($line in [IO.File]::ReadAllLines($Loaded.Paths.ConfigPath)) {
            if ($line -match "^\s*Endpoint\s*=\s*(.*?)\s*$") {
                $configEndpoint = $Matches[1]
                break
            }
        }
        if ($configEndpoint -ne $state.hub_endpoint) {
            [void]$details.Add("managed config Hub Endpoint differs from node state")
            $drifted = $true
        }
    } catch {
        [void]$details.Add("managed node config cannot be verified")
        $drifted = $true
    }
    if ($RuntimeActive) {
        $runtime = Invoke-Tool "wg.exe" @("show", $state.interface, "dump") -AllowFailure
        if ($runtime.ExitCode -ne 0) {
            [void]$details.Add("running WireGuard peer state cannot be read")
            $unknown = $true
        } else {
            try {
                $running = @(Get-RuntimePeerAssignments $runtime.Output)
                if (-not (Test-StringSetEqual $expected $running)) {
                    [void]$details.Add("running Hub peer/AllowedIPs set differs from node state")
                    $drifted = $true
                }
            } catch {
                [void]$details.Add("running WireGuard peer dump cannot be verified")
                $unknown = $true
            }
        }
    } else {
        $unknown = $true
        [void]$details.Add("running WireGuard peer state cannot be verified while the interface is inactive")
    }
    return [pscustomobject]@{
        Drifted = $drifted
        Unknown = $unknown
        Details = @($details.ToArray())
    }
}

function Get-HostEndpointPathRecord([string]$Interface, [bool]$RuntimeActive) {
    $endpointRecords = New-Object Collections.Generic.List[object]
    $pathRecords = New-Object Collections.Generic.List[object]
    $details = New-Object Collections.Generic.List[string]
    $hasDrift = $false
    $hasUnknown = $false
    if (-not $RuntimeActive) {
        [void]$details.Add("running peer Endpoint state cannot be verified while the interface is inactive")
        $hasUnknown = $true
    } else {
        $runtime = Invoke-Tool "wg.exe" @("show", $Interface, "dump") -AllowFailure
        if ($runtime.ExitCode -ne 0) {
            [void]$details.Add("running peer Endpoint state cannot be read")
            $hasUnknown = $true
        } else {
            try {
                $runtimeEndpoints = @(Get-RuntimePeerEndpointRecords $runtime.Output)
                if ($runtimeEndpoints.Count -eq 0) {
                    [void]$details.Add("running peer Endpoint state is empty")
                    $hasUnknown = $true
                }
                foreach ($runtimeEndpoint in $runtimeEndpoints) {
                    $endpointText = [string]$runtimeEndpoint.endpoint
                    if ([string]::IsNullOrWhiteSpace($endpointText) -or
                        $endpointText -eq "(none)") {
                        [void]$details.Add("peer '$($runtimeEndpoint.public_key)' has no learned Endpoint")
                        $hasUnknown = $true
                        [void]$endpointRecords.Add([pscustomobject]@{
                            public_key = $runtimeEndpoint.public_key
                            endpoint = $endpointText
                            state = "UNKNOWN"
                            paths = @()
                            details = @("Endpoint is not learned")
                        })
                        continue
                    }
                    $path = Get-EndpointPathRecord $endpointText $Interface
                    [void]$endpointRecords.Add([pscustomobject]@{
                        public_key = $runtimeEndpoint.public_key
                        endpoint = $endpointText
                        state = $path.state
                        paths = @($path.paths)
                        details = @($path.details)
                    })
                    foreach ($item in @($path.paths)) {
                        [void]$pathRecords.Add([pscustomobject]@{
                            public_key = $runtimeEndpoint.public_key
                            endpoint = $endpointText
                            address = $item.address
                            destination_prefix = $item.destination_prefix
                            interface = $item.interface
                            next_hop = $item.next_hop
                            state = $item.state
                        })
                    }
                    if ($path.state -eq "CONFIG_DRIFT") {
                        $hasDrift = $true
                        [void]$details.Add("peer '$($runtimeEndpoint.public_key)' Endpoint route resolves through the WireGuard interface")
                    } elseif ($path.state -eq "UNKNOWN") {
                        $hasUnknown = $true
                    }
                    foreach ($message in @($path.details)) {
                        if (-not [string]::IsNullOrWhiteSpace("$message")) {
                            [void]$details.Add("peer '$($runtimeEndpoint.public_key)': $message")
                        }
                    }
                }
            } catch {
                [void]$details.Add("running peer Endpoint state cannot be verified")
                $hasUnknown = $true
            }
        }
    }
    $state = if ($hasDrift) {
        "CONFIG_DRIFT"
    } elseif ($hasUnknown -or $pathRecords.Count -eq 0) {
        "UNKNOWN"
    } else {
        "UNDERLAY"
    }
    return [pscustomobject]@{
        state = $state
        endpoints = @($endpointRecords.ToArray())
        paths = @($pathRecords.ToArray())
        details = @($details.ToArray())
    }
}

function Write-Peers([string]$Path, [object[]]$Peers) {
    $lines = New-Object Collections.Generic.List[string]
    foreach ($peer in ($Peers | Sort-Object NodeId)) {
        $routes = if ($null -ne $peer.Routes) {
            (@($peer.Routes) -join ",")
        } else {
            ""
        }
        [void]$lines.Add("$($peer.NodeId)|$($peer.Address)|$($peer.PublicKey)|$routes")
    }
    $temporary = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllLines($temporary, $lines, (New-Object Text.UTF8Encoding($false)))
        Protect-Path $temporary
        Commit-AtomicFile $temporary $Path
    } catch {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Get-ConfigPrivateKey([string]$Path) {
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match "^\s*PrivateKey\s*=\s*(\S+)\s*$") {
            return $Matches[1]
        }
    }
    Fail "managed WireGuard config has no private key: $Path"
}

function New-ConfigText([hashtable]$State, [string]$PrivateKey, [object[]]$Peers) {
    $lines = New-Object Collections.Generic.List[string]
    [void]$lines.Add("# wgmesh-managed=true")
    [void]$lines.Add("# wgmesh-network=$($State.network_id)")
    [void]$lines.Add("[Interface]")
    [void]$lines.Add("PrivateKey = $PrivateKey")
    [void]$lines.Add("Address = $($State.address)")
    if ($State.ContainsKey("mtu_configured") -and
        $State.mtu_configured -ne "UNSET" -and
        -not [string]::IsNullOrWhiteSpace("$($State.mtu_configured)")) {
        [void]$lines.Add("MTU = $($State.mtu_configured)")
    }
    if ($State.role -eq "host") {
        [void]$lines.Add("ListenPort = $($State.listen_port)")
        foreach ($peer in ($Peers | Sort-Object NodeId)) {
            [void]$lines.Add("")
            [void]$lines.Add("[Peer]")
            [void]$lines.Add("# wgmesh-node-id=$($peer.NodeId)")
            [void]$lines.Add("PublicKey = $($peer.PublicKey)")
            [void]$lines.Add("AllowedIPs = $(Join-AddressList $peer.Address $peer.Routes)")
        }
    } else {
        [void]$lines.Add("")
        [void]$lines.Add("[Peer]")
        [void]$lines.Add("PublicKey = $($State.hub_public_key)")
        $extra = @()
        if ($State.ContainsKey("peer_addresses") -and
            -not [string]::IsNullOrWhiteSpace("$($State.peer_addresses)")) {
            $extra = @("$($State.peer_addresses)" -split ",")
        }
        [void]$lines.Add("AllowedIPs = $(Join-AddressList $State.overlay_cidr $extra)")
        [void]$lines.Add("Endpoint = $($State.hub_endpoint)")
        [void]$lines.Add("PersistentKeepalive = 25")
    }
    return (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Write-Config([string]$Path, [string]$Text) {
    $temporary = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
        Protect-Path $temporary
        Commit-AtomicFile $temporary $Path
    } catch {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Assert-ManagedConfig([string]$Path, [string]$NetworkId) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "managed WireGuard config is missing: $Path"
    }
    $text = [IO.File]::ReadAllText($Path)
    if ($text -notmatch "(?m)^# wgmesh-managed=true\s*$" -or
        $text -notmatch "(?m)^# wgmesh-network=$([regex]::Escape($NetworkId))\s*$") {
        Fail "existing config is not managed by wgmesh: $Path"
    }
}

function Get-ServiceName([string]$Interface) {
    return "WireGuardTunnel`$$Interface"
}

function Get-ServiceExists([string]$ServiceName) {
    $result = Invoke-Tool "sc.exe" @("query", $ServiceName) -AllowFailure
    return $result.ExitCode -eq 0
}

function Assert-TunnelServiceOwned([string]$Interface, [string]$ConfigPath) {
    $serviceName = Get-ServiceName $Interface
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        Fail "WireGuard tunnel service '$serviceName' was not found"
    }
    $wireguard = [IO.Path]::GetFullPath((Get-ToolPath "wireguard.exe"))
    $command = [string]$service.PathName
    $commandPattern = '^\s*(?:"' + [regex]::Escape($wireguard) + '"|' +
        [regex]::Escape($wireguard) + ')\s+/tunnelservice\s+'
    $configNamePattern = '(?i)(?:^|[\\/])' + [regex]::Escape($Interface) +
        '(?:\.conf(?:\.dpapi)?)?"?\s*$'
    if ($command -notmatch $commandPattern -or
        $command -notmatch $configNamePattern) {
        Fail "WireGuard tunnel service '$serviceName' is not a wgmesh tunnel"
    }
}

function Wait-ServiceAbsent([string]$ServiceName) {
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (-not (Get-ServiceExists $ServiceName)) {
            return
        }
        Start-Sleep -Milliseconds 250
    }
    Fail "WireGuard tunnel service '$ServiceName' did not stop being present"
}

function Ensure-TunnelService([hashtable]$State, [string]$ConfigPath, [bool]$StartNow = $true) {
    $service = Get-ServiceName $State.interface
    $created = $false
    if (Get-ServiceExists $service) {
        Assert-TunnelServiceOwned $State.interface $ConfigPath
    } else {
        [void](Invoke-Tool "wireguard.exe" @("/installtunnelservice", $ConfigPath))
        $created = $true
    }
    try {
        $startMode = if ($State.autostart -eq "true") { "auto" } else { "demand" }
        [void](Invoke-Tool "sc.exe" @("config", $service, "start=", $startMode))
        if ($StartNow -or $created) {
            $status = Invoke-Tool "sc.exe" @("query", $service) -AllowFailure
            if ($status.Output -notmatch "RUNNING") {
                [void](Invoke-Tool "sc.exe" @("start", $service))
            }
        }
    } catch {
        if ($created) {
            [void](Invoke-Tool "wireguard.exe" @("/uninstalltunnelservice", $State.interface) -AllowFailure)
            Wait-ServiceAbsent $service
        }
        throw
    }
    return $created
}

function Ensure-HostForwarding([hashtable]$State) {
    if ($State.role -ne "host") {
        return
    }
    Assert-HostForwardingTools
    $interfaces = @()
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            $interfaces = @(Get-NetIPInterface `
                -InterfaceAlias $State.interface `
                -AddressFamily IPv4 `
                -ErrorAction Stop)
        } catch {
            $interfaces = @()
        }
        if ($interfaces.Count -gt 0) {
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if ($interfaces.Count -eq 0) {
        Fail "WireGuard Hub interface '$($State.interface)' was not found for IPv4 forwarding"
    }

    try {
        Set-NetIPInterface `
            -InterfaceAlias $State.interface `
            -AddressFamily IPv4 `
            -Forwarding Enabled `
            -PolicyStore PersistentStore `
            -ErrorAction Stop
    } catch {
        Fail "cannot enable IPv4 forwarding on Hub interface '$($State.interface)': $($_.Exception.Message)"
    }

    try {
        $interfaces = @(Get-NetIPInterface `
            -InterfaceAlias $State.interface `
            -AddressFamily IPv4 `
            -ErrorAction Stop)
    } catch {
        Fail "cannot verify IPv4 forwarding on Hub interface '$($State.interface)': $($_.Exception.Message)"
    }
    if (@($interfaces | Where-Object { [string]$_.Forwarding -eq "Enabled" }).Count -eq 0) {
        Fail "IPv4 forwarding is not enabled on Hub interface '$($State.interface)'"
    }
}

function Remove-TunnelService([string]$Interface, [string]$ConfigPath) {
    $service = Get-ServiceName $Interface
    if (Get-ServiceExists $service) {
        Assert-TunnelServiceOwned $Interface $ConfigPath
        [void](Invoke-Tool "wireguard.exe" @("/uninstalltunnelservice", $Interface))
        Wait-ServiceAbsent $service
    }
}

function Test-TunnelActive([string]$Interface) {
    return (Invoke-Tool "wg.exe" @("show", $Interface) -AllowFailure).ExitCode -eq 0
}

function Refresh-TunnelService([hashtable]$State, [string]$ConfigPath, [bool]$ShouldRun) {
    $service = Get-ServiceName $State.interface
    if (Get-ServiceExists $service) {
        Assert-TunnelServiceOwned $State.interface $ConfigPath
        [void](Invoke-Tool "wireguard.exe" @("/uninstalltunnelservice", $State.interface))
        Wait-ServiceAbsent $service
    }
    $installed = $false
    try {
        [void](Invoke-Tool "wireguard.exe" @("/installtunnelservice", $ConfigPath))
        $installed = $true
        $startMode = if ($State.autostart -eq "true") { "auto" } else { "demand" }
        [void](Invoke-Tool "sc.exe" @("config", $service, "start=", $startMode))
        if ($ShouldRun) {
            $status = Invoke-Tool "sc.exe" @("query", $service) -AllowFailure
            if ($status.Output -notmatch "RUNNING") {
                [void](Invoke-Tool "sc.exe" @("start", $service))
            }
        } else {
            [void](Invoke-Tool "sc.exe" @("stop", $service) -AllowFailure)
        }
    } catch {
        if ($installed -and (Get-ServiceExists $service)) {
            [void](Invoke-Tool "wireguard.exe" @("/uninstalltunnelservice", $State.interface) -AllowFailure)
            Wait-ServiceAbsent $service
        }
        throw
    }
}

function Get-WireGuardPublicKey([string]$PrivateKey) {
    $result = Invoke-Tool "wg.exe" @("pubkey") -InputText $PrivateKey
    $key = $result.Output.Trim()
    Validate-PublicKey $key "generated public key"
    return $key
}

function New-WireGuardKeyPair {
    $result = Invoke-Tool "wg.exe" @("genkey")
    $private = $result.Output.Trim()
    Validate-PublicKey $private "generated private key"
    $public = Get-WireGuardPublicKey $private
    return [pscustomobject]@{
        PrivateKey = $private
        PublicKey  = $public
    }
}

function Read-NetworkState([string]$NetworkId) {
    $paths = Get-NetworkPaths $NetworkId
    if (-not (Test-Path -LiteralPath $paths.StatePath -PathType Leaf)) {
        return $null
    }
    $state = Read-KeyValueFile $paths.StatePath
    foreach ($required in @("network_id", "role", "node_id", "transport", "overlay_cidr", "address", "interface", "config_path", "autostart", "public_key")) {
        if (-not $state.ContainsKey($required)) {
            Fail "state file is missing '$required': $($paths.StatePath)"
        }
    }
    if ($state.network_id -ne $NetworkId -or $state.interface -ne $paths.Interface -or
        $state.config_path -ne $paths.ConfigPath -or $state.role -notin @("host", "node") -or
        $state.autostart -notin @("true", "false")) {
        Fail "state file does not match network '$NetworkId'"
    }
    if ($state.role -eq "host" -and
        (-not $state.ContainsKey("endpoint") -or -not $state.ContainsKey("listen_port"))) {
        Fail "host state file is missing endpoint fields: $($paths.StatePath)"
    }
    if ($state.role -eq "node" -and
        (-not $state.ContainsKey("hub_endpoint") -or -not $state.ContainsKey("hub_public_key"))) {
        Fail "node state file is missing Hub fields: $($paths.StatePath)"
    }
    $migrated = $false
    if ($state.ContainsKey("schema_version") -and
        $state.schema_version -notin @("1", "2")) {
        Fail "unsupported state schema version '$($state.schema_version)': $($paths.StatePath)"
    }
    if (-not $state.ContainsKey("schema_version")) {
        $state.schema_version = "1"
        $migrated = $true
    }
    if ($state.schema_version -ne "2") {
        $migrated = $true
    }
    if (-not $state.ContainsKey("firewall_mode")) {
        $state.firewall_mode = "external"
        $migrated = $true
    }
    if (-not $state.ContainsKey("mtu_configured")) {
        $configuredMtu = Get-ConfiguredMtu $paths.ConfigPath
        $state.mtu_configured = if ($null -ne $configuredMtu) { $configuredMtu } else { "UNSET" }
        $migrated = $true
    }
    if (-not $state.ContainsKey("peer_addresses")) {
        $state.peer_addresses = ""
        $migrated = $true
    }
    if ($state.firewall_mode -notin @("external", "managed")) {
        Fail "state file has an invalid firewall_mode: $($paths.StatePath)"
    }
    if ($state.role -eq "host" -and $state.firewall_mode -ne "external") {
        Fail "Windows managed firewall state is unsupported; use the external firewall mode"
    }
    if ($state.mtu_configured -ne "UNSET") {
        $state.mtu_configured = Validate-Mtu "$($state.mtu_configured)"
    }
    if ($state.role -eq "node") {
        $storedRoutes = if ([string]::IsNullOrWhiteSpace("$($state.peer_addresses)")) {
            @()
        } else {
            @("$($state.peer_addresses)" -split ",")
        }
        $state.peer_addresses = @(
            Validate-PeerAddresses $storedRoutes $state.overlay_cidr $state.address
        ) -join ","
    }
    if ($migrated) {
        $state.schema_version = "2"
        Write-KeyValueFile $paths.StatePath $state
    }
    return [pscustomobject]@{
        Values = $state
        Paths  = $paths
    }
}

function Compare-State([hashtable]$Existing, [hashtable]$Requested, [string[]]$Keys) {
    foreach ($key in $Keys) {
        if ($key -eq "mtu_configured" -and
            $Requested.ContainsKey($key) -and $Requested[$key] -eq "UNSET") {
            continue
        }
        if (-not $Existing.ContainsKey($key) -or $Existing[$key] -ne $Requested[$key]) {
            return $false
        }
    }
    return $true
}

function Write-InstallOutput([hashtable]$State, [string]$StateName) {
    $fields = @(
        "network_id=$($State.network_id)",
        "role=$($State.role)",
        "node_id=$($State.node_id)",
        "transport=$($State.transport)",
        "interface=$($State.interface)",
        "address=$($State.address)",
        "autostart=$(if ($State.autostart -eq 'true') { 'enabled' } else { 'disabled' })",
        "mtu_configured=$(if ($State.ContainsKey('mtu_configured')) { $State.mtu_configured } else { 'UNSET' })",
        "interface_state=$(if (Test-TunnelActive $State.interface) { 'ACTIVE' } else { 'CONFIGURED' })",
        "result=$(if ($StateName -eq 'NOOP') { 'NOOP' } else { 'CREATED' })"
    )
    if ($State.role -eq "host") {
        $fields += "endpoint=$($State.endpoint)"
        $fields += "hub_public_key=$($State.public_key)"
    } else {
        $fields += "endpoint=$($State.hub_endpoint)"
        $fields += "node_public_key=$($State.public_key)"
    }
    $fields -join [Environment]::NewLine
}

function Write-SimpleOutput([hashtable]$Fields) {
    ($Fields.Keys | Sort-Object | ForEach-Object { "$_=$($Fields[$_])" }) -join [Environment]::NewLine
}

function Get-HostStateRequest([hashtable]$Options) {
    $network = Validate-Id $Options.network "network-name"
    $node = Validate-Id $Options.node_id "node-id"
    $transport = Validate-Transport $Options.transport
    $overlay = Parse-Cidr $Options.overlay_cidr "overlay-cidr" $false
    if ($overlay.Prefix -eq 0) {
        Fail "overlay-cidr must not be a default route"
    }
    $address = Parse-Cidr $Options.address "address" $false
    if (-not (Test-AddressInCidr $address.IP $overlay)) {
        Fail "address must be inside overlay-cidr"
    }
    $endpoint = Parse-Endpoint $Options.endpoint "endpoint"
    $mtu = if ($Options.ContainsKey("mtu")) { Validate-Mtu "$($Options.mtu)" } else { "UNSET" }
    $firewallMode = if ($Options.ContainsKey("forward_firewall")) {
        "$($Options.forward_firewall)"
    } else {
        "external"
    }
    if ($firewallMode -notin @("external", "managed")) {
        Fail "forward-firewall must be external or managed"
    }
    if ($firewallMode -eq "managed") {
        Fail "Windows managed firewall forwarding is not supported; use --forward-firewall external"
    }
    $paths = Get-NetworkPaths $network
    return @{
        network_id  = $network
        role        = "host"
        node_id     = $node
        transport   = $transport
        overlay_cidr = $overlay.Text
        address     = $address.Text
        endpoint    = $endpoint.Text
        listen_port = "$($endpoint.Port)"
        interface   = $paths.Interface
        config_path = $paths.ConfigPath
        autostart   = if ($Options.ContainsKey("no_autostart") -and $Options.no_autostart) { "false" } else { "true" }
        schema_version = "2"
        mtu_configured = $mtu
        firewall_mode = $firewallMode
    }
}

function Get-NodeStateRequest([hashtable]$Options) {
    $network = Validate-Id $Options.network "network-name"
    $node = Validate-Id $Options.node_id "node-id"
    $transport = Validate-Transport $Options.transport
    $overlay = Parse-Cidr $Options.overlay_cidr "overlay-cidr" $false
    if ($overlay.Prefix -eq 0) {
        Fail "overlay-cidr must not be a default route"
    }
    $address = Parse-Cidr $Options.address "address" $true
    if (-not (Test-AddressInCidr $address.IP $overlay)) {
        Fail "address must be inside overlay-cidr"
    }
    $endpoint = Parse-Endpoint $Options.hub_endpoint "hub-endpoint"
    $hubKey = Validate-PublicKey $Options.hub_public_key "hub-public-key"
    $mtu = if ($Options.ContainsKey("mtu")) { Validate-Mtu "$($Options.mtu)" } else { "UNSET" }
    foreach ($endpointAddress in @(Get-EndpointIpv4Addresses $endpoint.Text)) {
        if (Test-AddressInCidr ([Net.IPAddress]::Parse($endpointAddress)) $overlay) {
            Fail "hub-endpoint '$endpointAddress' overlaps overlay-cidr; refusing a WireGuard Endpoint route through its own tunnel"
        }
    }
    $paths = Get-NetworkPaths $network
    return @{
        network_id   = $network
        role         = "node"
        node_id      = $node
        transport    = $transport
        overlay_cidr = $overlay.Text
        address      = $address.Text
        hub_endpoint = $endpoint.Text
        hub_public_key = $hubKey
        interface    = $paths.Interface
        config_path  = $paths.ConfigPath
        autostart    = if ($Options.ContainsKey("no_autostart") -and $Options.no_autostart) { "false" } else { "true" }
        schema_version = "2"
        mtu_configured = $mtu
        peer_addresses = ""
    }
}

function Install-LocalNetwork([hashtable]$Requested) {
    Assert-Administrator
    Ensure-Tools @("wg.exe", "wireguard.exe", "sc.exe")
    if ($Requested.role -eq "host") {
        Assert-HostForwardingTools
    }
    Ensure-Storage

    $paths = Get-NetworkPaths $Requested.network_id
    $existing = Read-NetworkState $Requested.network_id
    if ($null -ne $existing) {
        $existingState = $existing.Values
        $keys = @("network_id", "role", "node_id", "transport", "overlay_cidr", "address", "interface", "config_path", "autostart", "mtu_configured")
        if ($Requested.role -eq "host") {
            $keys += @("endpoint", "listen_port", "firewall_mode")
        } else {
            $keys += @("hub_endpoint", "hub_public_key")
        }
        if (-not (Compare-State $existingState $Requested $keys)) {
            Fail "network '$($Requested.network_id)' is already configured with different parameters"
        }
        Assert-ManagedConfig $paths.ConfigPath $Requested.network_id
        if ($Requested.mtu_configured -eq "UNSET" -and
            $existingState.ContainsKey("mtu_configured")) {
            $Requested.mtu_configured = $existingState.mtu_configured
        }
        $startExisting = $Requested.role -eq "host" -and $existingState.autostart -eq "true"
        [void](Ensure-TunnelService $existingState $paths.ConfigPath $startExisting)
        if ($Requested.role -eq "host" -and (Test-TunnelActive $existingState.interface)) {
            Ensure-HostForwarding $existingState
        }
        $Requested.public_key = $existingState.public_key
        return @{
            State  = $Requested
            Status = "NOOP"
        }
    }

    if (Test-Path -LiteralPath $paths.ConfigPath -PathType Leaf) {
        Fail "existing config conflicts with network '$($Requested.network_id)'"
    }
    if (Test-Path -LiteralPath $paths.PeersPath -PathType Leaf) {
        Fail "existing peer state conflicts with network '$($Requested.network_id)'"
    }

    Assert-OverlayAvailable $Requested.network_id $Requested.overlay_cidr $paths.StatePath

    $keyPair = New-WireGuardKeyPair
    $Requested.public_key = $keyPair.PublicKey
    $peers = @()
    $configText = New-ConfigText $Requested $keyPair.PrivateKey $peers
    $createdService = $false
    try {
        Write-Config $paths.ConfigPath $configText
        Write-KeyValueFile $paths.StatePath $Requested
        Write-Peers $paths.PeersPath $peers
        $createdService = Ensure-TunnelService $Requested $paths.ConfigPath $true
        if ($Requested.role -eq "host") {
            Ensure-HostForwarding $Requested
        }
    } catch {
        if ($createdService) {
            [void](Invoke-Tool "wireguard.exe" @("/uninstalltunnelservice", $Requested.interface) -AllowFailure)
        }
        foreach ($path in @($paths.ConfigPath, $paths.StatePath, $paths.PeersPath)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        throw
    }
    return @{
        State  = $Requested
        Status = "CONFIGURED"
    }
}

function Invoke-HostInit([hashtable]$Options) {
    $requested = Get-HostStateRequest $Options
    $result = Install-LocalNetwork $requested
    Write-InstallOutput $result.State $result.Status
}

function Invoke-NodeJoin([hashtable]$Options) {
    $requested = Get-NodeStateRequest $Options
    $result = Install-LocalNetwork $requested
    Write-InstallOutput $result.State $result.Status
}

function Assert-HostState([string]$NetworkId) {
    $loaded = Read-NetworkState $NetworkId
    if ($null -eq $loaded) {
        return $null
    }
    if ($loaded.Values.role -ne "host") {
        Fail "network '$NetworkId' is not a host installation"
    }
    Assert-ManagedConfig $loaded.Paths.ConfigPath $NetworkId
    return $loaded
}

function Commit-HostPeers($Loaded, [object[]]$OldPeers, [object[]]$NewPeers) {
    $configPath = $Loaded.Paths.ConfigPath
    $shouldRun = Test-TunnelActive $Loaded.Values.interface
    $serviceState = Get-ServiceState $Loaded.Values.interface
    $runtimeActive = $shouldRun -or
        $serviceState -in @("ACTIVE", "STARTING", "STOPPING", "PAUSED")
    if ($shouldRun -and $serviceState -eq "ABSENT") {
        Fail "CONFIG_DRIFT: active WireGuard interface has no wgmesh-owned tunnel service"
    }
    if ($serviceState -ne "ABSENT") {
        try {
            Assert-TunnelServiceOwned $Loaded.Values.interface $configPath
        } catch {
            Fail "CONFIG_DRIFT: tunnel service ownership cannot be verified: $($_.Exception.Message)"
        }
    }
    try {
        $currentPeers = @(Read-Peers $Loaded.Paths.PeersPath)
    } catch {
        Fail "CONFIG_DRIFT: registered peer state cannot be read"
    }
    if (-not (Test-StringSetEqual `
        (Get-RegisteredPeerIdentities $OldPeers) `
        (Get-RegisteredPeerIdentities $currentPeers))) {
        Fail "CONFIG_DRIFT: registered peer state changed during the update"
    }
    try {
        $drift = Get-HostPeerDrift $Loaded $OldPeers $runtimeActive
    } catch {
        Fail "CONFIG_DRIFT: peer/config verification failed: $($_.Exception.Message)"
    }
    $driftUnknown = $drift.PSObject.Properties["Unknown"] -and [bool]$drift.Unknown
    if ($drift.Drifted -or $driftUnknown) {
        Fail "CONFIG_DRIFT: $($drift.Details -join '; ')"
    }

    $oldConfig = [IO.File]::ReadAllText($configPath)
    $privateKey = Get-ConfigPrivateKey $configPath
    try {
        if ($shouldRun) {
            Assert-HostForwardingTools
        }
        $newConfig = New-ConfigText $Loaded.Values $privateKey $NewPeers
        Write-Config $configPath $newConfig
        Write-Peers $Loaded.Paths.PeersPath $NewPeers
        Refresh-TunnelService $Loaded.Values $configPath $shouldRun
        if ($shouldRun) {
            Ensure-HostForwarding $Loaded.Values
        }
    } catch {
        $failure = $_
        $rollbackFailures = New-Object Collections.Generic.List[string]
        try {
            Write-Config $configPath $oldConfig
        } catch {
            [void]$rollbackFailures.Add("config rollback failed")
        }
        try {
            Write-Peers $Loaded.Paths.PeersPath $OldPeers
        } catch {
            [void]$rollbackFailures.Add("peer state rollback failed")
        }
        try {
            Refresh-TunnelService $Loaded.Values $configPath $shouldRun
            if ($shouldRun) {
                Ensure-HostForwarding $Loaded.Values
            }
        } catch {
            [void]$rollbackFailures.Add("tunnel service rollback failed")
        }
        if ($rollbackFailures.Count -gt 0) {
            Fail "peer update failed; $($rollbackFailures -join ', ')"
        }
        throw $failure
    }
}

function Invoke-HostAddNode([hashtable]$Options) {
    Assert-Administrator
    Ensure-Tools @("wg.exe", "wireguard.exe", "sc.exe")
    Ensure-Storage
    $network = Validate-Id $Options.network "network-name"
    $node = Validate-Id $Options.node_id "node-id"
    $address = Parse-Cidr $Options.address "address" $true
    $publicKey = Validate-PublicKey $Options.node_public_key "node-public-key"
    $loaded = Assert-HostState $network
    if ($null -eq $loaded) {
        Fail "host network '$network' is not configured"
    }
    $overlay = Parse-Cidr $loaded.Values.overlay_cidr "stored overlay-cidr" $false
    if (-not (Test-AddressInCidr $address.IP $overlay)) {
        Fail "address must be inside overlay-cidr"
    }
    if ($address.IP.Equals(([Net.IPAddress]::Parse(($loaded.Values.address -split "/")[0])))) {
        Fail "address conflicts with the Hub address"
    }
    if ($publicKey -eq $loaded.Values.public_key) {
        Fail "public key conflicts with the Hub key"
    }
    $requestedRoutes = @(Validate-PeerAddresses (Get-OptionValues $Options "peer_address") `
        $loaded.Values.overlay_cidr $loaded.Values.address)
    if ($requestedRoutes.Count -gt 0) {
        Fail "Windows cannot verify the new peer Endpoint before its first handshake; add the peer without --peer-address, wait for a handshake, then use host set-routes"
    }

    $peers = @(Read-Peers $loaded.Paths.PeersPath)
    $sameNode = @($peers | Where-Object { $_.NodeId -eq $node })
    if ($sameNode.Count -gt 0) {
        $sameRoutes = (@($sameNode[0].Routes) -join ",") -eq ($requestedRoutes -join ",")
        if ($sameNode[0].Address -eq $address.Text -and
            $sameNode[0].PublicKey -eq $publicKey -and $sameRoutes) {
            Write-SimpleOutput @{
                network_id = $network
                node_id = $node
                peer = "committed"
                allowed_ips = $address.Text
                state = "CONFIGURED"
                result = "NOOP"
            }
            return
        }
        Fail "node '$node' is already registered with different peer parameters"
    }
    if (@($peers | Where-Object { $_.Address -eq $address.Text }).Count -gt 0) {
        Fail "address '$($address.Text)' is already registered"
    }
    if (@($peers | Where-Object { $_.PublicKey -eq $publicKey }).Count -gt 0) {
        Fail "public key is already registered"
    }
    foreach ($route in $requestedRoutes) {
        if (@($peers | Where-Object {
            $_.Address -eq $route -or @($_.Routes) -contains $route
        }).Count -gt 0) {
            Fail "peer-address '$route' is already registered"
        }
    }

    $newPeer = [pscustomobject]@{
        NodeId = $node
        Address = $address.Text
        PublicKey = $publicKey
        Routes = $requestedRoutes
    }
    $newPeers = @($peers + $newPeer)
    Commit-HostPeers $loaded $peers $newPeers
    Write-SimpleOutput @{
        network_id = $network
        node_id = $node
        peer = "committed"
        allowed_ips = $address.Text
        state = "CONFIGURED"
        result = "CREATED"
    }
}

function Invoke-HostRemoveNode([hashtable]$Options) {
    Assert-Administrator
    Ensure-Tools @("wg.exe", "wireguard.exe", "sc.exe")
    Ensure-Storage
    $network = Validate-Id $Options.network "network-name"
    $node = Validate-Id $Options.node_id "node-id"
    $loaded = Assert-HostState $network
    if ($null -eq $loaded) {
        Write-SimpleOutput @{
            network_id = $network
            node_id = $node
            peer_revoked = "absent"
            state = "NOOP"
            changed = "false"
        }
        return
    }

    $peers = @(Read-Peers $loaded.Paths.PeersPath)
    $peer = @($peers | Where-Object { $_.NodeId -eq $node }) | Select-Object -First 1
    if ($null -eq $peer) {
        Write-SimpleOutput @{
            network_id = $network
            node_id = $node
            peer_revoked = "none"
            state = "CONFIGURED"
            result = "NOOP"
        }
        return
    }

    $newPeers = @($peers | Where-Object { $_.NodeId -ne $node })
    Commit-HostPeers $loaded $peers $newPeers
    Write-SimpleOutput @{
        network_id = $network
        node_id = $node
        peer_revoked = "done"
        state = "CONFIGURED"
        result = "REMOVED"
    }
}

function Invoke-HostSetRoutes([hashtable]$Options) {
    Assert-Administrator
    Ensure-Tools @("wg.exe", "wireguard.exe", "sc.exe")
    Ensure-Storage
    $network = Validate-Id $Options.network "network-name"
    $node = Validate-Id $Options.node_id "node-id"
    $loaded = Assert-HostState $network
    if ($null -eq $loaded) {
        Fail "host network '$network' is not configured"
    }
    $peers = @(Read-Peers $loaded.Paths.PeersPath)
    $peer = @($peers | Where-Object { $_.NodeId -eq $node }) | Select-Object -First 1
    if ($null -eq $peer) {
        Fail "node '$node' is not registered"
    }
    $routes = @(Validate-PeerAddresses (Get-OptionValues $Options "peer_address") `
        $loaded.Values.overlay_cidr $loaded.Values.address)
    Assert-HostPeerEndpointRoutesSafe `
        -Interface $loaded.Values.interface `
        -Peers @($peer) `
        -Routes $routes
    foreach ($route in $routes) {
        if (@($peers | Where-Object {
            $_.NodeId -ne $node -and
            ($_.Address -eq $route -or @($_.Routes) -contains $route)
        }).Count -gt 0) {
            Fail "peer-address '$route' is already registered to another peer"
        }
    }
    $newPeers = @(
        foreach ($item in $peers) {
            if ($item.NodeId -eq $node) {
                [pscustomobject]@{
                    NodeId = $item.NodeId
                    Address = $item.Address
                    PublicKey = $item.PublicKey
                    Routes = $routes
                }
            } else {
                $item
            }
        }
    )
    if ((@($peer.Routes) -join ",") -eq ($routes -join ",")) {
        Write-SimpleOutput @{
            network_id = $network
            node_id = $node
            state = "CONFIGURED"
            result = "NOOP"
        }
        return
    }
    Commit-HostPeers $loaded $peers $newPeers
    Write-SimpleOutput @{
        network_id = $network
        node_id = $node
        peer_addresses = ($routes -join ",")
        state = "CONFIGURED"
        result = "UPDATED"
    }
}

function Commit-NodeState([pscustomobject]$Loaded, [hashtable]$NewState) {
    $configPath = $Loaded.Paths.ConfigPath
    $oldConfig = [IO.File]::ReadAllText($configPath)
    $oldState = @{}
    foreach ($key in $Loaded.Values.Keys) {
        $oldState[$key] = $Loaded.Values[$key]
    }
    $privateKey = Get-ConfigPrivateKey $configPath
    $shouldRun = Test-TunnelActive $Loaded.Values.interface
    try {
        $newConfig = New-ConfigText $NewState $privateKey @()
        Write-Config $configPath $newConfig
        Write-KeyValueFile $Loaded.Paths.StatePath $NewState
        Refresh-TunnelService $NewState $configPath $shouldRun
    } catch {
        $failure = $_
        $rollbackFailures = New-Object Collections.Generic.List[string]
        try { Write-Config $configPath $oldConfig } catch { [void]$rollbackFailures.Add("config rollback failed") }
        try { Write-KeyValueFile $Loaded.Paths.StatePath $oldState } catch { [void]$rollbackFailures.Add("state rollback failed") }
        try { Refresh-TunnelService $oldState $configPath $shouldRun } catch { [void]$rollbackFailures.Add("tunnel service rollback failed") }
        if ($rollbackFailures.Count -gt 0) {
            Fail "node route update failed; $($rollbackFailures -join ', ')"
        }
        throw $failure
    }
}

function Invoke-NodeSetRoutes([hashtable]$Options) {
    Assert-Administrator
    Ensure-Tools @("wg.exe", "wireguard.exe", "sc.exe")
    Ensure-Storage
    $network = Validate-Id $Options.network "network-name"
    $loaded = Read-NetworkState $network
    if ($null -eq $loaded) {
        Fail "node network '$network' is not configured"
    }
    if ($loaded.Values.role -ne "node") {
        Fail "network '$network' is not a node installation"
    }
    Assert-ManagedConfig $loaded.Paths.ConfigPath $network
    $routes = @(Validate-PeerAddresses (Get-OptionValues $Options "peer_address") `
        $loaded.Values.overlay_cidr $loaded.Values.address)
    Assert-EndpointUnderlaySafe $loaded.Values.hub_endpoint $routes
    $oldRoutes = if ($loaded.Values.ContainsKey("peer_addresses") -and
        -not [string]::IsNullOrWhiteSpace("$($loaded.Values.peer_addresses)")) {
        @("$($loaded.Values.peer_addresses)" -split ",")
    } else {
        @()
    }
    if (($oldRoutes -join ",") -eq ($routes -join ",")) {
        Write-SimpleOutput @{
            network_id = $network
            state = "CONFIGURED"
            result = "NOOP"
        }
        return
    }
    $newState = @{}
    foreach ($key in $loaded.Values.Keys) {
        $newState[$key] = $loaded.Values[$key]
    }
    $newState.schema_version = "2"
    $newState.peer_addresses = ($routes -join ",")
    Commit-NodeState $loaded $newState
    Write-SimpleOutput @{
        network_id = $network
        peer_addresses = ($routes -join ",")
        state = "CONFIGURED"
        result = "UPDATED"
    }
}

function Get-Handshake([string]$Interface) {
    $result = Invoke-Tool "wg.exe" @("show", $Interface, "latest-handshakes") -AllowFailure
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) {
        return $null
    }
    $latest = 0L
    foreach ($line in ($result.Output -split "`r?`n")) {
        $parts = $line.Trim() -split "\s+"
        if ($parts.Count -eq 2) {
            $timestamp = 0L
            if ([long]::TryParse($parts[1], [ref]$timestamp) -and $timestamp -gt $latest) {
                $latest = $timestamp
            }
        }
    }
    if ($latest -le 0) {
        return $null
    }
    return $latest
}

function Get-ServiceState([string]$Interface) {
    $service = Get-Service -Name (Get-ServiceName $Interface) -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        return "ABSENT"
    }
    switch ($service.Status.ToString()) {
        "Running" { return "ACTIVE" }
        "Stopped" { return "INACTIVE" }
        "StartPending" { return "STARTING" }
        "StopPending" { return "STOPPING" }
        "Paused" { return "PAUSED" }
        default { return "UNKNOWN" }
    }
}

function Get-StatusRecord($loaded) {
    $state = $loaded.Values
    $active = (Invoke-Tool "wg.exe" @("show", $state.interface) -AllowFailure).ExitCode -eq 0
    $serviceState = Get-ServiceState $state.interface
    $serviceActive = $serviceState -in @("ACTIVE", "STARTING", "STOPPING", "PAUSED")
    $consistency = if ($state.autostart -eq "true") {
        if ($active -and $serviceState -eq "ACTIVE") { "CONSISTENT" } else { "DEGRADED" }
    } elseif ($active) {
        "EXPECTED_NO_AUTOSTART"
    } elseif ($serviceActive) {
        "DEGRADED"
    } else {
        "CONSISTENT"
    }
    $endpoint = if ($state.role -eq "host") {
        $state.endpoint
    } else {
        $state.hub_endpoint
    }
    $record = [ordered]@{
        network_id = $state.network_id
        role = $state.role
        node_id = $state.node_id
        transport = $state.transport
        interface = $state.interface
        address = $state.address
        endpoint = $endpoint
        autostart = ($state.autostart -eq "true")
        service_state = $serviceState
        consistency_state = $consistency
        state = if ($active) { "ACTIVE" } else { "CONFIGURED" }
        handshake = Get-Handshake $state.interface
        mtu_configured = if ($state.ContainsKey("mtu_configured")) { $state.mtu_configured } else { "UNSET" }
        mtu_effective = Get-EffectiveMtu $state.interface
        endpoint_path = @()
        endpoint_path_state = "UNKNOWN"
        endpoint_path_details = @()
    }
    $configDetails = New-Object Collections.Generic.List[string]
    $configDrifted = $false
    $configUnknown = -not $active
    if ($state.role -eq "host") {
        $record.hub_public_key = $state.public_key
        $peers = @()
        $peerStateError = $null
        try {
            $peers = @(Read-Peers $loaded.Paths.PeersPath)
        } catch {
            $peerStateError = $_.Exception.Message
        }
        $drift = if ($null -ne $peerStateError) {
            [pscustomobject]@{
                Drifted = $true
                Unknown = $false
                Details = @("registered peer state cannot be read: $peerStateError")
            }
        } else {
            Get-HostPeerDrift $loaded $peers ($active -or $serviceActive)
        }
        $record.peer_count = $peers.Count
        $record.peer_routes = @(
            foreach ($peer in $peers) {
                [pscustomobject]@{
                    node_id = $peer.NodeId
                    address = $peer.Address
                    peer_addresses = (@($peer.Routes) -join ",")
                }
            }
        )
        $record.firewall = if ($state.ContainsKey("firewall_mode")) { $state.firewall_mode.ToUpperInvariant() } else { "EXTERNAL" }
        $record.firewall_check = "NOT_CHECKED"
        $configDrifted = [bool]$drift.Drifted
        $driftUnknown = $drift.PSObject.Properties["Unknown"] -and [bool]$drift.Unknown
        $configUnknown = $configUnknown -or $driftUnknown
        foreach ($detail in @($drift.Details)) {
            if (-not [string]::IsNullOrWhiteSpace("$detail")) {
                [void]$configDetails.Add("$detail")
            }
        }
        $endpointPath = Get-HostEndpointPathRecord $state.interface $active
        $record.peer_endpoints = @($endpointPath.endpoints)
        $record.endpoint_path = @($endpointPath.paths)
        $record.endpoint_path_state = $endpointPath.state
        $record.endpoint_path_details = @($endpointPath.details)
        if ($endpointPath.state -eq "CONFIG_DRIFT") {
            $configDrifted = $true
            [void]$configDetails.Add("Endpoint path resolves through the WireGuard interface")
        } elseif ($endpointPath.state -eq "UNKNOWN") {
            $configUnknown = $true
        }
        foreach ($detail in @($endpointPath.details)) {
            if (-not [string]::IsNullOrWhiteSpace("$detail")) {
                [void]$configDetails.Add("$detail")
            }
        }
    } else {
        $record.node_public_key = $state.public_key
        $record.hub_public_key = $state.hub_public_key
        $record.peer_addresses = if ($state.ContainsKey("peer_addresses")) { $state.peer_addresses } else { "" }
        $drift = Get-NodePeerDrift $loaded $active
        $configDrifted = [bool]$drift.Drifted
        $driftUnknown = $drift.PSObject.Properties["Unknown"] -and [bool]$drift.Unknown
        $configUnknown = $configUnknown -or $driftUnknown
        foreach ($detail in @($drift.Details)) {
            if (-not [string]::IsNullOrWhiteSpace("$detail")) {
                [void]$configDetails.Add("$detail")
            }
        }
        $endpointPath = Get-EndpointPathRecord $state.hub_endpoint $state.interface
        if (-not $active) {
            $endpointPath = [pscustomobject]@{
                endpoint = $state.hub_endpoint
                state = "UNKNOWN"
                paths = @($endpointPath.paths)
                details = @($endpointPath.details) + @("WireGuard interface is inactive")
            }
        }
        $record.endpoint_path = @($endpointPath.paths)
        $record.endpoint_path_state = $endpointPath.state
        $record.endpoint_path_details = @($endpointPath.details)
        if ($endpointPath.state -eq "CONFIG_DRIFT") {
            $configDrifted = $true
            [void]$configDetails.Add("Endpoint path resolves through the WireGuard interface")
        } elseif ($endpointPath.state -eq "UNKNOWN") {
            $configUnknown = $true
        }
        foreach ($detail in @($endpointPath.details)) {
            if (-not [string]::IsNullOrWhiteSpace("$detail")) {
                [void]$configDetails.Add("$detail")
            }
        }
    }
    $record.config_consistency = if ($configDrifted) {
        "CONFIG_DRIFT"
    } elseif ($configUnknown) {
        "UNKNOWN"
    } else {
        "CONSISTENT"
    }
    $record.config_drift = @($configDetails.ToArray())
    return $record
}

function Invoke-Status([hashtable]$Options) {
    $records = New-Object Collections.Generic.List[object]
    if ($Options.ContainsKey("network")) {
        $loaded = Read-NetworkState (Validate-Id $Options.network "network-name")
        if ($null -eq $loaded) {
            Fail "network state not found: $($Options.network)"
        }
        Assert-Tools @("wg.exe")
        [void]$records.Add((Get-StatusRecord $loaded))
    } else {
        $stateFiles = @()
        if (Test-Path -LiteralPath $script:StateDir -PathType Container) {
            $stateFiles = @(Get-ChildItem -LiteralPath $script:StateDir -Filter "*.state" -File | Sort-Object Name)
        }
        if ($stateFiles.Count -gt 0) {
            Assert-Tools @("wg.exe")
            foreach ($path in $stateFiles) {
                $loaded = Read-NetworkState $path.BaseName
                if ($null -ne $loaded) {
                    [void]$records.Add((Get-StatusRecord $loaded))
                }
            }
        }
    }

    if ($Options.ContainsKey("json") -and $Options.json) {
        if ($Options.ContainsKey("network")) {
            $records[0] | ConvertTo-Json -Depth 4
        } else {
            ConvertTo-Json -InputObject @($records.ToArray()) -Depth 4
        }
        return
    }
    foreach ($record in $records) {
        $record.autostart = if ($record.autostart) { "enabled" } else { "disabled" }
        if ($record.Contains("config_drift")) {
            $record.config_drift = @($record.config_drift) -join "; "
        }
        $record.GetEnumerator() | ForEach-Object {
            "$($_.Key)=$($_.Value)"
        }
        if ($records.Count -gt 1) {
            ""
        }
    }
    if ($records.Count -eq 0) {
        "state=ABSENT"
    }
}

function Invoke-Uninstall([hashtable]$Options, [string]$Role) {
    Assert-Administrator
    Ensure-Storage
    $network = Validate-Id $Options.network "network-name"
    if ($Role -eq "node") {
        $node = Validate-Id $Options.node_id "node-id"
    }
    $loaded = Read-NetworkState $network
    if ($null -eq $loaded) {
        Write-SimpleOutput @{
            network_id = $network
            role = $Role
            state = "ABSENT"
            result = "NOOP"
        }
        return
    }
    Ensure-Tools @("wireguard.exe", "sc.exe")
    if ($loaded.Values.role -ne $Role) {
        Fail "network '$network' is a $($loaded.Values.role) installation"
    }
    if ($Role -eq "node" -and $loaded.Values.node_id -ne $node) {
        Fail "node-id '$node' does not match the installed node '$($loaded.Values.node_id)'"
    }
    Assert-ManagedConfig $loaded.Paths.ConfigPath $network
    Remove-TunnelService $loaded.Values.interface $loaded.Paths.ConfigPath
    foreach ($path in @($loaded.Paths.ConfigPath, $loaded.Paths.StatePath, $loaded.Paths.PeersPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    Write-SimpleOutput @{
        network_id = $network
        role = $Role
        interface_removed = "true"
        autostart_removed = "true"
        state = "ABSENT"
        result = "REMOVED"
    }
}

function Parse-Options([string[]]$Tokens, [string[]]$Allowed, [string[]]$Required) {
    $options = @{}
    $boolean = @("--no-autostart", "--json")
    $repeatable = @("--peer-address")
    $index = 0
    while ($index -lt $Tokens.Count) {
        $token = $Tokens[$index]
        if ($token -notmatch "^--[a-z0-9-]+$") {
            Fail "unexpected argument '$token'"
        }
        if ($Allowed -notcontains $token) {
            Fail "unsupported option '$token'"
        }
        $name = if ($token -eq "--network-name") {
            "network"
        } else {
            $token.Substring(2).Replace("-", "_")
        }
        if ($options.ContainsKey($name) -and $repeatable -notcontains $token) {
            Fail "duplicate option '$token'"
        }
        if ($boolean -contains $token) {
            $options[$name] = $true
            $index++
            continue
        }
        if (($index + 1) -ge $Tokens.Count -or $Tokens[$index + 1] -match "^--") {
            Fail "option '$token' requires a value"
        }
        if ($repeatable -contains $token) {
            if (-not $options.ContainsKey($name)) {
                $options[$name] = New-Object Collections.Generic.List[string]
            }
            [void]$options[$name].Add($Tokens[$index + 1])
        } else {
            $options[$name] = $Tokens[$index + 1]
        }
        $index += 2
    }
    foreach ($requiredOption in $Required) {
        if (-not $options.ContainsKey($requiredOption)) {
            $displayName = if ($requiredOption -eq "network") {
                "network-name"
            } else {
                $requiredOption.Replace("_", "-")
            }
            Fail "missing required option '--$displayName'"
        }
    }
    return $options
}

function Main([string[]]$Arguments) {
    if ($Arguments.Count -eq 0 -or $Arguments[0] -in @("help", "--help", "-h")) {
        Show-Usage
        return
    }
    if ($Arguments.Count -lt 1) {
        Fail "a command is required"
    }

    $role = $Arguments[0]
    $action = ""
    $remaining = @()
    if ($role -eq "status") {
        $action = "status"
        if ($Arguments.Count -gt 1) {
            $remaining = @($Arguments[1..($Arguments.Count - 1)])
        }
    } elseif ($Arguments.Count -ge 2) {
        $action = "$role $($Arguments[1])"
        if ($Arguments.Count -gt 2) {
            $remaining = @($Arguments[2..($Arguments.Count - 1)])
        }
    } else {
        Fail "command '$role' requires an action"
    }

    switch ($action) {
        "host init" {
            $options = Parse-Options $remaining `
                @("--network-name", "--node-id", "--transport", "--overlay-cidr", "--address", "--endpoint", "--forward-firewall", "--mtu", "--no-autostart") `
                @("network", "node_id", "transport", "overlay_cidr", "address", "endpoint")
            Invoke-HostInit $options
            break
        }
        "node join" {
            $options = Parse-Options $remaining `
                @("--network-name", "--node-id", "--transport", "--overlay-cidr", "--address", "--hub-endpoint", "--hub-public-key", "--mtu", "--no-autostart") `
                @("network", "node_id", "transport", "overlay_cidr", "address", "hub_endpoint", "hub_public_key")
            Invoke-NodeJoin $options
            break
        }
        "host add-node" {
            $options = Parse-Options $remaining `
                @("--network-name", "--node-id", "--address", "--node-public-key", "--peer-address") `
                @("network", "node_id", "address", "node_public_key")
            Invoke-HostAddNode $options
            break
        }
        "host set-routes" {
            $options = Parse-Options $remaining `
                @("--network-name", "--node-id", "--peer-address") `
                @("network", "node_id")
            Invoke-HostSetRoutes $options
            break
        }
        "node set-routes" {
            $options = Parse-Options $remaining `
                @("--network-name", "--peer-address") `
                @("network")
            Invoke-NodeSetRoutes $options
            break
        }
        "host remove-node" {
            $options = Parse-Options $remaining @("--network-name", "--node-id") @("network", "node_id")
            Invoke-HostRemoveNode $options
            break
        }
        "node uninstall" {
            $options = Parse-Options $remaining @("--network-name", "--node-id") @("network", "node_id")
            Invoke-Uninstall $options "node"
            break
        }
        "host uninstall" {
            $options = Parse-Options $remaining @("--network-name") @("network")
            Invoke-Uninstall $options "host"
            break
        }
        "status" {
            $options = Parse-Options $remaining @("--network-name", "--json") @()
            Invoke-Status $options
            break
        }
        default {
            Fail "unsupported command '$action'"
        }
    }
}

try {
    Main $args
} catch {
    [Console]::Error.WriteLine("wgmesh: " + $_.Exception.Message)
    exit 1
}
