$ErrorActionPreference = "Stop"

$scriptPath = [IO.Path]::GetFullPath(
    (Join-Path (Split-Path -Parent $PSScriptRoot) "wgmesh.ps1")
)
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    foreach ($parseError in $parseErrors) {
        [Console]::Error.WriteLine(
            "{0}:{1}: {2}",
            $parseError.Extent.StartLineNumber,
            $parseError.Extent.StartColumnNumber,
            $parseError.Message
        )
    }
    exit 1
}

function Get-FunctionDefinition([string]$Name) {
    $definition = $ast.Find(
        {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
        },
        $true
    )
    if ($null -eq $definition) {
        throw "$Name function was not found"
    }
    return $definition
}

foreach ($name in @(
    "Parse-Endpoint",
    "Get-EndpointAddresses",
    "Get-EndpointPathRecord",
    "Get-CanonicalPeerAssignment",
    "Get-StatePeerAssignments",
    "Get-ConfigPeerAssignments",
    "Get-RuntimePeerAssignments",
    "Get-RuntimePeerEndpointRecords",
    "Get-RegisteredPeerIdentities",
    "Test-StringSetEqual",
    "Get-HostPeerDrift",
    "Get-NodePeerDrift",
    "Get-HostEndpointPathRecord",
    "Get-StatusRecord"
)) {
    Invoke-Expression (Get-FunctionDefinition $name).Extent.Text
}

$script:TestTunnelActive = $false
$script:TestServiceState = "INACTIVE"
$script:TestRuntimeDump = ""
function Invoke-Tool([string]$Name, [string[]]$Arguments, [switch]$AllowFailure) {
    if ($Arguments.Count -eq 3 -and $Arguments[0] -eq "show" -and
        $Arguments[2] -eq "dump") {
        return [pscustomobject]@{
            ExitCode = if ([string]::IsNullOrWhiteSpace($script:TestRuntimeDump)) { 1 } else { 0 }
            Output = $script:TestRuntimeDump
        }
    }
    return [pscustomobject]@{
        ExitCode = if ($script:TestTunnelActive) { 0 } else { 1 }
        Output = ""
    }
}
function Get-ServiceState([string]$Interface) {
    return $script:TestServiceState
}
function Get-Handshake([string]$Interface) {
    return $null
}
function Get-EffectiveMtu([string]$Interface) {
    return "UNKNOWN"
}
function Read-Peers([string]$Path) {
    return @($script:TestPeer)
}
$script:TestRouteInterface = "Ethernet"
$script:TestRouteFailure = $false
$script:TestRouteEmpty = $false
$script:TestRouteIndexOnly = $false
function Get-EndpointAddresses([string]$EndpointText) {
    return @([pscustomobject]@{
        Address = "192.0.2.1"
        AddressFamily = [Net.Sockets.AddressFamily]::InterNetwork
    })
}
function Find-NetRoute {
    [CmdletBinding()]
    param([string]$RemoteIPAddress)
    if ($script:TestRouteFailure) {
        throw "mock route lookup failed"
    }
    if ($script:TestRouteEmpty) {
        return @()
    }
    if ($script:TestRouteIndexOnly) {
        return [pscustomobject]@{
            DestinationPrefix = "0.0.0.0/0"
            InterfaceIndex = 7
            NextHop = "192.0.2.254"
        }
    }
    return [pscustomobject]@{
        DestinationPrefix = "0.0.0.0/0"
        InterfaceAlias = $script:TestRouteInterface
        NextHop = "192.0.2.254"
    }
}
function Get-NetIPInterface {
    [CmdletBinding()]
    param(
        [int]$InterfaceIndex,
        [object]$AddressFamily
    )
    return [pscustomobject]@{
        InterfaceAlias = $script:TestRouteInterface
        NlMtu = 1400
    }
}

function Assert-Consistency(
    [bool]$Autostart,
    [bool]$TunnelActive,
    [string]$ServiceState,
    [string]$Expected
) {
    $script:TestTunnelActive = $TunnelActive
    $script:TestServiceState = $ServiceState
    $autostartValue = if ($Autostart) { "true" } else { "false" }
    $state = @{
        network_id = "test"
        role = "node"
        node_id = "test"
        transport = "public"
        interface = "wgtest"
        address = "10.0.0.2/32"
        overlay_cidr = "10.0.0.0/24"
        hub_endpoint = "192.0.2.1:51820"
        autostart = $autostartValue
        public_key = "test"
        hub_public_key = "test"
        peer_addresses = ""
        mtu_configured = "UNSET"
    }
    $loaded = [pscustomobject]@{
        Values = $state
        Paths = $null
    }
    $record = Get-StatusRecord $loaded
    if ($record.consistency_state -ne $Expected) {
        throw "status consistency mismatch: autostart=$autostartValue tunnel=$TunnelActive service=$ServiceState expected=$Expected actual=$($record.consistency_state)"
    }
}

Assert-Consistency $true $true "ACTIVE" "CONSISTENT"
Assert-Consistency $true $true "INACTIVE" "DEGRADED"
Assert-Consistency $true $false "ACTIVE" "DEGRADED"
Assert-Consistency $false $true "ACTIVE" "EXPECTED_NO_AUTOSTART"
Assert-Consistency $false $true "INACTIVE" "EXPECTED_NO_AUTOSTART"
Assert-Consistency $false $false "ACTIVE" "DEGRADED"
Assert-Consistency $false $false "INACTIVE" "CONSISTENT"

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("wgmesh-powershell-parser-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
try {
    $configPath = Join-Path $tmpRoot "demo.conf"
    $statePath = Join-Path $tmpRoot "demo.state"
    $peer = [pscustomobject]@{
        NodeId = "node-a"
        Address = "10.0.0.2/32"
        PublicKey = "peer-a"
        Routes = @("198.51.100.10/32")
    }
    $configText = @"
# wgmesh-managed=true
# wgmesh-network=demo
[Interface]
PrivateKey = private
Address = 10.0.0.1/24

[Peer]
PublicKey = peer-a
AllowedIPs = 10.0.0.2/32, 198.51.100.10/32
"@
    [IO.File]::WriteAllText($configPath, $configText)
    [IO.File]::WriteAllText($statePath, "node-a|10.0.0.2/32|peer-a|198.51.100.10/32`n")
    $loaded = [pscustomobject]@{
        Values = @{
            network_id = "demo"
            interface = "wgtest"
            role = "host"
        }
        Paths = @{
            ConfigPath = $configPath
            PeersPath = $statePath
        }
    }
    $runtimeFields = @(
        "peer-a", "psk-a", "endpoint", "10.0.0.2/32,198.51.100.10/32",
        "0", "0", "0", "0"
    )
    $script:TestRuntimeDump = @(
        "private`tpublic`t51820`t0"
        ($runtimeFields -join "`t")
    ) -join "`n"
    $drift = Get-HostPeerDrift $loaded @($peer) $true
    if ($drift.Drifted) {
        throw "clean peer/config/runtime fixture was reported as drift: $($drift.Details -join '; ')"
    }
    $script:TestRuntimeDump = @(
        "private`tpublic`t51820`t0"
        "peer-a`tpsk-a`tendpoint`t10.0.0.2/32,198.51.100.10/32`t0`t0`t0`t0"
        "peer-unknown`tpsk-b`tendpoint`t203.0.113.50/32`t0`t0`t0`t0"
    ) -join "`n"
    $drift = Get-HostPeerDrift $loaded @($peer) $true
    if (-not $drift.Drifted -or
        ($drift.Details -notmatch "running peer/AllowedIPs set differs")) {
        throw "unknown runtime peer was not reported as CONFIG_DRIFT"
    }
    $configText = @"
# wgmesh-managed=true
# wgmesh-network=demo
[Interface]
PrivateKey = private
Address = 10.0.0.1/24

[Peer]
PublicKey = peer-a
AllowedIPs = 10.0.0.2/32
"@
    [IO.File]::WriteAllText($configPath, $configText)
    $script:TestRuntimeDump = ""
    $drift = Get-HostPeerDrift $loaded @($peer) $false
    if (-not $drift.Drifted -or
        ($drift.Details -notmatch "managed config peer/AllowedIPs set differs")) {
        throw "managed config drift was not detected"
    }
    $script:TestPeer = $peer
    $script:TestTunnelActive = $false
    $script:TestServiceState = "INACTIVE"
    $hostLoaded = [pscustomobject]@{
        Values = @{
            network_id = "demo"
            role = "host"
            node_id = "hub"
            transport = "public"
            interface = "wgtest"
            address = "10.0.0.1/24"
            endpoint = "192.0.2.10:51820"
            autostart = "false"
            public_key = "hub"
            mtu_configured = "UNSET"
        }
        Paths = @{
            ConfigPath = $configPath
            PeersPath = $statePath
        }
    }
    $status = Get-StatusRecord $hostLoaded
    if ($status.config_consistency -ne "CONFIG_DRIFT") {
        throw "host status did not expose CONFIG_DRIFT"
    }

    $cleanHostConfigText = @"
# wgmesh-managed=true
# wgmesh-network=demo
[Interface]
PrivateKey = private
Address = 10.0.0.1/24

[Peer]
PublicKey = peer-a
AllowedIPs = 10.0.0.2/32, 198.51.100.10/32
"@
    [IO.File]::WriteAllText($configPath, $cleanHostConfigText)
    $script:TestRuntimeDump = @(
        "private`tpublic`t51820`t0"
        "peer-a`tpsk-a`t192.0.2.20:51820`t10.0.0.2/32,198.51.100.10/32`t0`t0`t0`t0"
    ) -join "`n"
    $script:TestTunnelActive = $true
    $script:TestServiceState = "ACTIVE"
    $script:TestRouteInterface = "Ethernet"
    $script:TestRouteFailure = $false
    $script:TestRouteEmpty = $false
    $script:TestRouteIndexOnly = $false
    $status = Get-StatusRecord $hostLoaded
    if ($status.config_consistency -ne "CONSISTENT" -or
        $status.endpoint_path_state -ne "UNDERLAY" -or
        $status.peer_endpoints[0].endpoint -ne "192.0.2.20:51820") {
        throw "host status did not read runtime peer Endpoint underlay state"
    }

    $nodeConfigPath = Join-Path $tmpRoot "node.conf"
    $nodeStatePath = Join-Path $tmpRoot "node.state"
    $nodeConfigText = @"
# wgmesh-managed=true
# wgmesh-network=node-demo
[Interface]
PrivateKey = private
Address = 10.0.0.2/32

[Peer]
PublicKey = hub-key
AllowedIPs = 10.0.0.0/24, 198.51.100.10/32
Endpoint = 192.0.2.1:51820
"@
    [IO.File]::WriteAllText($nodeConfigPath, $nodeConfigText)
    $nodeLoaded = [pscustomobject]@{
        Values = @{
            network_id = "node-demo"
            role = "node"
            node_id = "node-a"
            transport = "tailscale"
            interface = "wgtest"
            address = "10.0.0.2/32"
            overlay_cidr = "10.0.0.0/24"
            hub_endpoint = "192.0.2.1:51820"
            hub_public_key = "hub-key"
            public_key = "node-key"
            peer_addresses = "198.51.100.10/32"
            autostart = "true"
            mtu_configured = "UNSET"
        }
        Paths = @{
            ConfigPath = $nodeConfigPath
            StatePath = $nodeStatePath
        }
    }
    $script:TestRuntimeDump = @(
        "private`tpublic`t51820`t0"
        "hub-key`tpsk`t192.0.2.1:51820`t10.0.0.0/24,198.51.100.10/32`t0`t0`t0`t0"
    ) -join "`n"
    $script:TestTunnelActive = $true
    $nodeDrift = Get-NodePeerDrift $nodeLoaded $true
    if ($nodeDrift.Drifted -or $nodeDrift.Unknown) {
        throw "clean node peer/config/runtime fixture was reported as drift: $($nodeDrift.Details -join '; ')"
    }
    $script:TestRuntimeDump = @(
        "private`tpublic`t51820`t0"
        "hub-key`tpsk`t192.0.2.1:51820`t10.0.0.0/24,198.51.100.11/32`t0`t0`t0`t0"
    ) -join "`n"
    $nodeDrift = Get-NodePeerDrift $nodeLoaded $true
    if (-not $nodeDrift.Drifted -or
        ($nodeDrift.Details -notmatch "running Hub peer/AllowedIPs set differs")) {
        throw "node runtime peer drift was not detected"
    }
    $script:TestRuntimeDump = @(
        "private`tpublic`t51820`t0"
        "hub-key`tpsk`t192.0.2.1:51820`t10.0.0.0/24,198.51.100.10/32`t0`t0`t0`t0"
    ) -join "`n"
    $script:TestRouteInterface = "Ethernet"
    $script:TestRouteFailure = $false
    $nodeStatus = Get-StatusRecord $nodeLoaded
    if ($nodeStatus.config_consistency -ne "CONSISTENT" -or
        $nodeStatus.endpoint_path_state -ne "UNDERLAY" -or
        $nodeStatus.endpoint -ne "192.0.2.1:51820") {
        throw "node status did not expose a consistent Endpoint underlay path"
    }
    $script:TestTunnelActive = $false
    $script:TestServiceState = "INACTIVE"
    $nodeStatus = Get-StatusRecord $nodeLoaded
    if ($nodeStatus.config_consistency -ne "UNKNOWN" -or
        $nodeStatus.endpoint_path_state -ne "UNKNOWN") {
        throw "inactive node status was not reported as UNKNOWN"
    }
    $script:TestTunnelActive = $true
    $script:TestRouteInterface = "wgtest"
    $nodeStatus = Get-StatusRecord $nodeLoaded
    if ($nodeStatus.config_consistency -ne "CONFIG_DRIFT" -or
        $nodeStatus.endpoint_path_state -ne "CONFIG_DRIFT") {
        throw "Endpoint route through the WireGuard interface was not reported as CONFIG_DRIFT"
    }
    $script:TestRouteInterface = "Ethernet"
    $script:TestRouteFailure = $true
    $endpointPath = Get-EndpointPathRecord "192.0.2.1:51820" "wgtest"
    if ($endpointPath.state -ne "UNKNOWN") {
        throw "Endpoint route lookup failure was not reported as UNKNOWN"
    }
    $script:TestRouteFailure = $false
    $script:TestRouteIndexOnly = $true
    $endpointPath = Get-EndpointPathRecord "192.0.2.1:51820" "wgtest"
    if ($endpointPath.state -ne "UNDERLAY" -or
        $endpointPath.paths[0].interface -ne "Ethernet") {
        throw "Endpoint route interface-index fallback was not resolved"
    }
    $script:TestRouteIndexOnly = $false
    $script:TestRouteEmpty = $true
    $endpointPath = Get-EndpointPathRecord "192.0.2.1:51820" "wgtest"
    if ($endpointPath.state -ne "UNKNOWN") {
        throw "missing Endpoint route was not reported as UNKNOWN"
    }
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$commitText = (Get-FunctionDefinition "Commit-HostPeers").Extent.Text
if ($commitText -notmatch "Get-HostPeerDrift" -or
    $commitText -notmatch "CONFIG_DRIFT") {
    throw "Commit-HostPeers is missing fail-closed CONFIG_DRIFT protection"
}
Invoke-Expression $commitText
function Fail([string]$Message) {
    throw $Message
}
function Test-TunnelActive([string]$Interface) {
    return $false
}
function Get-ServiceState([string]$Interface) {
    return "INACTIVE"
}
function Assert-TunnelServiceOwned([string]$Interface, [string]$ConfigPath) {
    return
}
function Get-HostPeerDrift($Loaded, [object[]]$StatePeers, [bool]$RuntimeActive) {
    return [pscustomobject]@{
        Drifted = $true
        Details = @("mock runtime peer drift")
    }
}
$commitLoaded = [pscustomobject]@{
    Values = @{
        interface = "wgtest"
    }
    Paths = @{
        ConfigPath = (Join-Path ([IO.Path]::GetTempPath()) "wgmesh-parser-missing.conf")
        PeersPath = (Join-Path ([IO.Path]::GetTempPath()) "wgmesh-parser-missing.state")
    }
}
$commitFailedClosed = $false
try {
    Commit-HostPeers $commitLoaded @($peer) @($peer)
} catch {
    $commitFailedClosed = $_.Exception.Message -match "CONFIG_DRIFT"
}
if (-not $commitFailedClosed) {
    throw "Commit-HostPeers did not fail closed on mocked CONFIG_DRIFT"
}

Write-Output "wgmesh PowerShell parser, status, and drift behavior: PASS"
