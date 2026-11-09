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
  wgmesh.ps1 host init --network-name ID --node-id ID --transport tailscale|public --overlay-cidr CIDR --address CIDR --endpoint HOST:PORT [--no-autostart]
  wgmesh.ps1 node join --network-name ID --node-id ID --transport tailscale|public --overlay-cidr CIDR --address CIDR --hub-endpoint HOST:PORT --hub-public-key KEY [--no-autostart]
  wgmesh.ps1 host add-node --network-name ID --node-id ID --address CIDR --node-public-key KEY
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
    [IO.File]::WriteAllLines($temporary, $lines, (New-Object Text.UTF8Encoding($false)))
    Protect-Path $temporary
    [void](Move-Item -LiteralPath $temporary -Destination $Path -Force)
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
        if ($parts.Count -ne 3) {
            Fail "invalid peer state file: $Path"
        }
        [void]$peers.Add([pscustomobject]@{
            NodeId     = $parts[0]
            Address    = $parts[1]
            PublicKey  = $parts[2]
        })
    }
    return $peers
}

function Write-Peers([string]$Path, [object[]]$Peers) {
    $lines = New-Object Collections.Generic.List[string]
    foreach ($peer in ($Peers | Sort-Object NodeId)) {
        [void]$lines.Add("$($peer.NodeId)|$($peer.Address)|$($peer.PublicKey)")
    }
    $temporary = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllLines($temporary, $lines, (New-Object Text.UTF8Encoding($false)))
    Protect-Path $temporary
    [void](Move-Item -LiteralPath $temporary -Destination $Path -Force)
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
    if ($State.role -eq "host") {
        [void]$lines.Add("ListenPort = $($State.listen_port)")
        foreach ($peer in ($Peers | Sort-Object NodeId)) {
            [void]$lines.Add("")
            [void]$lines.Add("[Peer]")
            [void]$lines.Add("# wgmesh-node-id=$($peer.NodeId)")
            [void]$lines.Add("PublicKey = $($peer.PublicKey)")
            [void]$lines.Add("AllowedIPs = $($peer.Address)")
        }
    } else {
        [void]$lines.Add("")
        [void]$lines.Add("[Peer]")
        [void]$lines.Add("PublicKey = $($State.hub_public_key)")
        [void]$lines.Add("AllowedIPs = $($State.overlay_cidr)")
        [void]$lines.Add("Endpoint = $($State.hub_endpoint)")
        [void]$lines.Add("PersistentKeepalive = 25")
    }
    return (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Write-Config([string]$Path, [string]$Text) {
    $temporary = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
    Protect-Path $temporary
    [void](Move-Item -LiteralPath $temporary -Destination $Path -Force)
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
    return [pscustomobject]@{
        Values = $state
        Paths  = $paths
    }
}

function Compare-State([hashtable]$Existing, [hashtable]$Requested, [string[]]$Keys) {
    foreach ($key in $Keys) {
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
        "state=CONFIGURED",
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
    }
}

function Install-LocalNetwork([hashtable]$Requested) {
    Assert-Administrator
    Ensure-Tools @("wg.exe", "wireguard.exe", "sc.exe")
    Ensure-Storage

    $paths = Get-NetworkPaths $Requested.network_id
    $existing = Read-NetworkState $Requested.network_id
    if ($null -ne $existing) {
        $existingState = $existing.Values
        $keys = @("network_id", "role", "node_id", "transport", "overlay_cidr", "address", "interface", "config_path", "autostart")
        if ($Requested.role -eq "host") {
            $keys += @("endpoint", "listen_port")
        } else {
            $keys += @("hub_endpoint", "hub_public_key")
        }
        if (-not (Compare-State $existingState $Requested $keys)) {
            Fail "network '$($Requested.network_id)' is already configured with different parameters"
        }
        Assert-ManagedConfig $paths.ConfigPath $Requested.network_id
        [void](Ensure-TunnelService $existingState $paths.ConfigPath $false)
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
    $oldConfig = [IO.File]::ReadAllText($configPath)
    $privateKey = Get-ConfigPrivateKey $configPath
    $shouldRun = Test-TunnelActive $Loaded.Values.interface
    try {
        $newConfig = New-ConfigText $Loaded.Values $privateKey $NewPeers
        Write-Config $configPath $newConfig
        Write-Peers $Loaded.Paths.PeersPath $NewPeers
        Refresh-TunnelService $Loaded.Values $configPath $shouldRun
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

    $peers = @(Read-Peers $loaded.Paths.PeersPath)
    $sameNode = @($peers | Where-Object { $_.NodeId -eq $node })
    if ($sameNode.Count -gt 0) {
        if ($sameNode[0].Address -eq $address.Text -and $sameNode[0].PublicKey -eq $publicKey) {
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

    $newPeer = [pscustomobject]@{
        NodeId = $node
        Address = $address.Text
        PublicKey = $publicKey
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

function Get-StatusRecord($loaded) {
    $state = $loaded.Values
    $active = (Invoke-Tool "wg.exe" @("show", $state.interface) -AllowFailure).ExitCode -eq 0
    $record = [ordered]@{
        network_id = $state.network_id
        role = $state.role
        node_id = $state.node_id
        transport = $state.transport
        interface = $state.interface
        address = $state.address
        autostart = ($state.autostart -eq "true")
        state = if ($active) { "ACTIVE" } else { "CONFIGURED" }
        handshake = Get-Handshake $state.interface
    }
    if ($state.role -eq "host") {
        $record.hub_public_key = $state.public_key
        $record.peer_count = @(Read-Peers $loaded.Paths.PeersPath).Count
    } else {
        $record.node_public_key = $state.public_key
        $record.hub_public_key = $state.hub_public_key
    }
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
        if ($options.ContainsKey($name)) {
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
        $options[$name] = $Tokens[$index + 1]
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
                @("--network-name", "--node-id", "--transport", "--overlay-cidr", "--address", "--endpoint", "--no-autostart") `
                @("network", "node_id", "transport", "overlay_cidr", "address", "endpoint")
            Invoke-HostInit $options
            break
        }
        "node join" {
            $options = Parse-Options $remaining `
                @("--network-name", "--node-id", "--transport", "--overlay-cidr", "--address", "--hub-endpoint", "--hub-public-key", "--no-autostart") `
                @("network", "node_id", "transport", "overlay_cidr", "address", "hub_endpoint", "hub_public_key")
            Invoke-NodeJoin $options
            break
        }
        "host add-node" {
            $options = Parse-Options $remaining `
                @("--network-name", "--node-id", "--address", "--node-public-key") `
                @("network", "node_id", "address", "node_public_key")
            Invoke-HostAddNode $options
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
