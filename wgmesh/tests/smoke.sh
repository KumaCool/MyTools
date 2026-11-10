#!/bin/sh
set -eu

SCRIPT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/wgmesh.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wgmesh.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

mkdir -p "$TMP/state" "$TMP/config" "$TMP/bin" "$TMP/platform/darwin" "$TMP/platform/linux"

cat > "$TMP/platform/darwin/uname" <<'EOF'
#!/bin/sh
printf '%s\n' Darwin
EOF

cat > "$TMP/platform/linux/uname" <<'EOF'
#!/bin/sh
printf '%s\n' Linux
EOF

cat > "$TMP/bin/wg" <<'EOF'
#!/bin/sh
case "$1" in
    genkey)
        printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
        ;;
    pubkey)
        printf '%s\n' 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB='
        ;;
    show)
        if [ "${3:-}" = dump ]; then
            [ -f "$WGMESH_TEST_WG_DUMP_FILE" ] || exit 1
            cat "$WGMESH_TEST_WG_DUMP_FILE"
            exit 0
        fi
        if [ -f "$WGMESH_TEST_WG_REAL_INTERFACE_FILE" ]; then
            [ "$2" = "$(cat "$WGMESH_TEST_WG_REAL_INTERFACE_FILE")" ] &&
                [ -f "$WGMESH_TEST_ACTIVE" ]
        else
            [ -f "$WGMESH_TEST_ACTIVE" ]
        fi
        ;;
    set)
        printf '%s\n' "$*" >> "$WGMESH_TEST_WG_SET_LOG"
        exit 0
        ;;
    *)
        exit 2
        ;;
esac
EOF

cat > "$TMP/bin/wg-quick" <<'EOF'
#!/bin/sh
case "$1" in
    up) touch "$WGMESH_TEST_ACTIVE" ;;
    down) rm -f "$WGMESH_TEST_ACTIVE" ;;
    *) exit 2 ;;
esac
EOF

cat > "$TMP/bin/wireguard-go" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$TMP/bin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$WGMESH_TEST_SYSTEMCTL_LOG"
case "$1" in
    is-active)
        [ "$2" = --quiet ] || exit 2
        [ -f "$WGMESH_TEST_SYSTEM_ACTIVE" ]
        ;;
    enable)
        touch "$WGMESH_TEST_SYSTEM_ENABLED"
        if [ "${2:-}" = --now ]; then
            touch "$WGMESH_TEST_ACTIVE" "$WGMESH_TEST_SYSTEM_ACTIVE"
        fi
        ;;
    restart) touch "$WGMESH_TEST_ACTIVE" "$WGMESH_TEST_SYSTEM_ACTIVE" ;;
    disable)
        [ "$2" = --now ] || exit 2
        rm -f "$WGMESH_TEST_SYSTEM_ENABLED" "$WGMESH_TEST_SYSTEM_ACTIVE"
        ;;
    *) exit 2 ;;
esac
EOF

cat > "$TMP/bin/launchctl" <<'EOF'
#!/bin/sh
case "$1" in
    enable) touch "$WGMESH_TEST_LAUNCHD_ENABLED" ;;
    bootstrap)
        touch "$WGMESH_TEST_LAUNCHD_LOADED" "$WGMESH_TEST_ACTIVE"
        ;;
    bootout) rm -f "$WGMESH_TEST_LAUNCHD_LOADED" ;;
    print) [ -f "$WGMESH_TEST_LAUNCHD_LOADED" ] ;;
    *) exit 2 ;;
esac
EOF

cat > "$TMP/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
    "-4 route replace "*)
        printf '%s\n' "$*" >> "$WGMESH_TEST_IP_MUTATIONS"
        ;;
    "-4 route add "*)
        destination=$4
        [ "${WGMESH_TEST_FAIL_IP_ROUTE_ADD:-}" != "$destination" ] || exit 2
        if awk -v target="$destination" '$1 == target { found = 1 } END { exit !found }' "$WGMESH_TEST_IP_ROUTE_STATE"; then
            exit 2
        fi
        printf '%s\n' "$*" >> "$WGMESH_TEST_IP_MUTATIONS"
        printf '%s dev %s\n' "$destination" "$6" >> "$WGMESH_TEST_IP_ROUTE_STATE"
        ;;
    "-4 route del "*)
        printf '%s\n' "$*" >> "$WGMESH_TEST_IP_MUTATIONS"
        destination=$4
        device=$6
        awk -v target="$destination" -v dev="$device" '
            !($1 == target && $2 == "dev" && $3 == dev) { print }
        ' "$WGMESH_TEST_IP_ROUTE_STATE" > "$WGMESH_TEST_IP_ROUTE_STATE.tmp"
        mv "$WGMESH_TEST_IP_ROUTE_STATE.tmp" "$WGMESH_TEST_IP_ROUTE_STATE"
        ;;
    "-4 route show exact "*)
        destination=$5
        awk -v target="$destination" '$1 == target { print }' "$WGMESH_TEST_IP_ROUTE_STATE"
        ;;
    "-4 route get "*)
        if [ -f "$WGMESH_TEST_ENDPOINT_INTERFACE_FILE" ]; then
            endpoint_device=$(cat "$WGMESH_TEST_ENDPOINT_INTERFACE_FILE")
        else
            endpoint_device=eth0
        fi
        printf '%s dev %s src 192.0.2.10\n' "$4" "$endpoint_device"
        ;;
    "-4 route show")
        cat "$WGMESH_TEST_IP_ROUTES"
        ;;
    "-4 -o addr show")
        cat "$WGMESH_TEST_IP_ADDRS"
        ;;
    "-o link show dev "*)
        printf '%s\n' '5: wgmesh-demo: <POINTOPOINT> mtu 1280 state UNKNOWN'
        ;;
    *)
        exit 2
        ;;
esac
EOF

cat > "$TMP/bin/route" <<'EOF'
#!/bin/sh
case "$1:$2:$3" in
    -n:get:*)
        if [ -f "$WGMESH_TEST_ENDPOINT_INTERFACE_FILE" ]; then
            endpoint_device=$(cat "$WGMESH_TEST_ENDPOINT_INTERFACE_FILE")
        else
            endpoint_device=tailscale0
        fi
        printf '   route to: %s\ninterface: %s\n' "$3" "$endpoint_device"
        exit 0
        ;;
    -n:add:-host)
        [ "${WGMESH_TEST_FAIL_ROUTE_ADD:-}" != "$4" ] || exit 2
        route_interface=wgmesh-demo
        if [ -f "$WGMESH_TEST_WG_REAL_INTERFACE_FILE" ]; then
            route_interface=$(cat "$WGMESH_TEST_WG_REAL_INTERFACE_FILE")
        fi
        printf '%s link#9 UCS %s\n' "$4" "$route_interface" >> "$WGMESH_TEST_NETSTAT"
        ;;
    -n:delete:-host)
        target=$4
        awk -v target="$target" '$1 != target { print }' "$WGMESH_TEST_NETSTAT" \
            > "$WGMESH_TEST_NETSTAT.tmp"
        mv "$WGMESH_TEST_NETSTAT.tmp" "$WGMESH_TEST_NETSTAT"
        ;;
esac
printf '%s\n' "$*" >> "$WGMESH_TEST_ROUTE_MUTATIONS"
exit 0
EOF

cat > "$TMP/bin/ifconfig" <<'EOF'
#!/bin/sh
[ "$1" = -a ] || exit 2
cat "$WGMESH_TEST_IFCONFIG"
EOF

cat > "$TMP/bin/netstat" <<'EOF'
#!/bin/sh
[ "$1" = -rn ] && [ "$2" = -f ] && [ "$3" = inet ] || exit 2
cat "$WGMESH_TEST_NETSTAT"
EOF

cat > "$TMP/bin/sysctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$WGMESH_TEST_SYSCTL_LOG"
case "$1:$2" in
    -w:net.ipv4.ip_forward=1)
        printf '1\n' > "$WGMESH_TEST_SYSCTL_LINUX_STATE"
        ;;
    -w:net.inet.ip.forwarding=1)
        printf '1\n' > "$WGMESH_TEST_SYSCTL_MACOS_STATE"
        ;;
    -n:net.ipv4.ip_forward)
        [ -f "$WGMESH_TEST_SYSCTL_LINUX_STATE" ] || exit 1
        printf '1\n'
        ;;
    -n:net.inet.ip.forwarding)
        [ -f "$WGMESH_TEST_SYSCTL_MACOS_STATE" ] || exit 1
        printf '1\n'
        ;;
    *)
        exit 2
        ;;
esac
EOF

cat > "$TMP/ip.routes" <<'EOF'
default via 192.0.2.1 dev eth0
192.0.2.0/24 dev eth0 proto kernel scope link src 192.0.2.10
203.0.113.128/25 dev tailscale0 proto kernel scope link src 203.0.113.129
EOF

cat > "$TMP/ip.addrs" <<'EOF'
1: lo    inet 127.0.0.1/8 scope host lo
2: eth0    inet 192.0.2.10/24 scope global eth0
3: tailscale0    inet 203.0.113.129/32 scope global tailscale0
EOF

cat > "$TMP/ifconfig.txt" <<'EOF'
en0: flags=8863
	inet 192.0.2.10 netmask 0xffffff00 broadcast 192.0.2.255
tailscale0: flags=8863
	inet 203.0.113.129 netmask 0xffffffff
EOF

cat > "$TMP/netstat.txt" <<'EOF'
Routing tables

Internet:
Destination        Gateway            Flags        Netif
default            192.0.2.1          UGSc         en0
192.0.2            link#4             UCS          en0
203.0.113.128      link#5             UCS          tailscale0
EOF

touch "$TMP/ip.route-state"

chmod 700 "$TMP/bin/wg" "$TMP/bin/wg-quick" "$TMP/bin/wireguard-go" \
    "$TMP/bin/systemctl" "$TMP/bin/launchctl" "$TMP/bin/ip" \
    "$TMP/bin/route" "$TMP/bin/ifconfig" "$TMP/bin/netstat" \
    "$TMP/bin/sysctl" \
    "$TMP/platform/darwin/uname" "$TMP/platform/linux/uname"

run() {
    WGMESH_TEST_MODE=1 \
    PATH="$TEST_PLATFORM_BIN:$PATH" \
    WGMESH_STATE_ROOT="$TMP/state" \
    WGMESH_CONFIG_ROOT="$TMP/config" \
    WGMESH_SYSTEMCTL="$TMP/bin/systemctl" \
    WGMESH_LAUNCHCTL="$TMP/bin/launchctl" \
    WGMESH_WG="$TMP/bin/wg" \
    WGMESH_WG_QUICK="$TMP/bin/wg-quick" \
    WGMESH_WIREGUARD_GO="$TMP/bin/wireguard-go" \
    WGMESH_IP="$TMP/bin/ip" \
    WGMESH_ROUTE="$TMP/bin/route" \
    WGMESH_IFCONFIG="$TMP/bin/ifconfig" \
    WGMESH_NETSTAT="$TMP/bin/netstat" \
    WGMESH_SYSCTL="$TMP/bin/sysctl" \
    WGMESH_TEST_IP_ROUTES="$TMP/ip.routes" \
    WGMESH_TEST_IP_ROUTE_STATE="$TMP/ip.route-state" \
    WGMESH_TEST_ENDPOINT_INTERFACE_FILE="$TMP/endpoint-interface" \
    WGMESH_TEST_FAIL_IP_ROUTE_ADD="${TEST_FAIL_IP_ROUTE_ADD:-}" \
    WGMESH_TEST_IP_ADDRS="$TMP/ip.addrs" \
    WGMESH_TEST_IP_MUTATIONS="$TMP/ip-mutations.log" \
    WGMESH_TEST_ROUTE_MUTATIONS="$TMP/route-mutations.log" \
    WGMESH_TEST_FAIL_ROUTE_ADD="${TEST_FAIL_ROUTE_ADD:-}" \
    WGMESH_TEST_IFCONFIG="$TMP/ifconfig.txt" \
    WGMESH_TEST_NETSTAT="$TMP/netstat.txt" \
    WGMESH_TEST_SYSCTL_LOG="$TMP/sysctl.log" \
    WGMESH_TEST_SYSCTL_LINUX_STATE="$TMP/sysctl-linux.state" \
    WGMESH_TEST_SYSCTL_MACOS_STATE="$TMP/sysctl-macos.state" \
    WGMESH_TEST_ACTIVE="$TMP/active" \
    WGMESH_TEST_WG_DUMP_FILE="$TMP/wg-dump.txt" \
    WGMESH_TEST_WG_REAL_INTERFACE_FILE="$TMP/wg-real-interface" \
    WGMESH_TEST_WG_SET_LOG="$TMP/wg-set.log" \
    WGMESH_WIREGUARD_RUNTIME_ROOT="$TMP/wireguard-runtime" \
    WGMESH_TEST_SYSTEM_ENABLED="$TMP/system-enabled" \
    WGMESH_TEST_SYSTEM_ACTIVE="$TMP/system-active" \
    WGMESH_TEST_SYSTEMCTL_LOG="$TMP/systemctl.log" \
    WGMESH_LAUNCHD_ROOT="$TMP/launchd" \
    WGMESH_TEST_LAUNCHD_ENABLED="$TMP/launchd-enabled" \
    WGMESH_TEST_LAUNCHD_LOADED="$TMP/launchd-loaded" \
        "$SCRIPT" "$@"
}

runtime_interface_mapping() {
    network_name=$1
    interface_name=$(printf '%s' "wgmesh-$network_name" | awk '{
        if (length($0) <= 15) print $0
        else exit 1
    }') || interface_name=$(printf '%s\n' "$network_name" | cksum | awk '{printf "wm-%s", $1}')
    printf '%s\n' "$TMP/wireguard-runtime/$interface_name.name"
}

expect_contains() {
    case "$1" in
        *"$2"*) ;;
        *)
            printf 'expected output to contain: %s\nactual output:\n%s\n' "$2" "$1" >&2
            exit 1
            ;;
    esac
}

TEST_PLATFORM_BIN="$TMP/platform/darwin"

cp "$SCRIPT" "$TMP/wgmesh-without-firewall-helper.sh"
missing_helper_output=
if missing_helper_output=$(WGMESH_TEST_MODE=1 \
    PATH="$TEST_PLATFORM_BIN:$PATH" \
    "$TMP/wgmesh-without-firewall-helper.sh" --help 2>&1); then
    printf 'wgmesh accepted a missing Unix firewall helper\n' >&2
    exit 1
fi
expect_contains "$missing_helper_output" 'wgmesh firewall helper is missing or unreadable'

mkdir -p "$TMP/preflight-bin"
cat > "$TMP/preflight-bin/id" <<'EOF'
#!/bin/sh
printf '%s\n' 1000
EOF
chmod 700 "$TMP/preflight-bin/id"
nonroot_output=
if nonroot_output=$(PATH="$TMP/preflight-bin:$TEST_PLATFORM_BIN:/usr/bin:/bin" \
    "$SCRIPT" host init --network-name preflight-nonroot --node-id hub \
    --transport tailscale --overlay-cidr 198.51.100.0/24 \
    --address 198.51.100.1/24 --endpoint 203.0.113.130:51820 2>&1); then
    printf 'wgmesh accepted a non-root mutating command\n' >&2
    exit 1
fi
expect_contains "$nonroot_output" 'administrator privileges are required; rerun this command with sudo'

cat > "$TMP/preflight-bin/id" <<'EOF'
#!/bin/sh
printf '%s\n' 0
EOF
cat > "$TMP/preflight-bin/brew" <<'EOF'
#!/bin/sh
touch "$WGMESH_TEST_BREW_CALLED"
exit 1
EOF
chmod 700 "$TMP/preflight-bin/id" "$TMP/preflight-bin/brew"
root_brew_output=
if root_brew_output=$(SUDO_USER= \
    PATH="$TMP/preflight-bin:$TEST_PLATFORM_BIN:/usr/bin:/bin" \
    WGMESH_STATE_ROOT="$TMP/state" WGMESH_CONFIG_ROOT="$TMP/config" \
    WGMESH_LAUNCHD_ROOT="$TMP/launchd" \
    WGMESH_TEST_BREW_CALLED="$TMP/brew-called" \
    "$SCRIPT" host init --network-name preflight-brew --node-id hub \
    --transport tailscale --overlay-cidr 203.0.113.0/24 \
    --address 203.0.113.1/24 --endpoint 203.0.113.130:51820 2>&1); then
    printf 'wgmesh attempted to install Homebrew packages as root\n' >&2
    exit 1
fi
expect_contains "$root_brew_output" 'Homebrew cannot run as root'
if [ -e "$TMP/brew-called" ]; then
    printf 'root Homebrew preflight invoked brew unexpectedly\n' >&2
    exit 1
fi

cat > "$TMP/preflight-bin/apt-get" <<'EOF'
#!/bin/sh
touch "$WGMESH_TEST_PACKAGE_INSTALL_CALLED"
exit 0
EOF
chmod 700 "$TMP/preflight-bin/apt-get"
touch "$TMP/state-root-is-a-file" "$TMP/config-root-is-a-file" \
    "$TMP/launchd-root-is-a-file"
path_preflight_output=
if path_preflight_output=$(PATH="$TMP/preflight-bin:$TMP/platform/linux:/usr/bin:/bin" \
    WGMESH_STATE_ROOT="$TMP/state-root-is-a-file" \
    WGMESH_CONFIG_ROOT="$TMP/config" \
    WGMESH_WG="$TMP/missing-wg" WGMESH_WG_QUICK="$TMP/missing-wg-quick" \
    WGMESH_TEST_PACKAGE_INSTALL_CALLED="$TMP/package-install-called" \
    "$SCRIPT" host init --network-name preflight-state --node-id hub \
    --transport tailscale --overlay-cidr 198.51.100.0/24 \
    --address 198.51.100.1/24 --endpoint 203.0.113.130:51820 \
    --no-autostart 2>&1); then
    printf 'host init accepted a non-directory state path\n' >&2
    exit 1
fi
expect_contains "$path_preflight_output" 'wgmesh state root path is not a directory'
if [ -e "$TMP/package-install-called" ]; then
    printf 'host init installed WireGuard before rejecting the state path\n' >&2
    exit 1
fi
path_preflight_output=
if path_preflight_output=$(PATH="$TMP/preflight-bin:$TMP/platform/linux:/usr/bin:/bin" \
    WGMESH_STATE_ROOT="$TMP/preflight-state" \
    WGMESH_CONFIG_ROOT="$TMP/config-root-is-a-file" \
    WGMESH_WG="$TMP/missing-wg" WGMESH_WG_QUICK="$TMP/missing-wg-quick" \
    WGMESH_TEST_PACKAGE_INSTALL_CALLED="$TMP/package-install-called" \
    "$SCRIPT" node join --network-name preflight-config --node-id node-a \
    --transport tailscale --overlay-cidr 198.51.100.0/24 \
    --address 198.51.100.2/32 --hub-endpoint 203.0.113.130:51820 \
    --hub-public-key BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB= --no-autostart 2>&1); then
    printf 'node join accepted a non-directory config path\n' >&2
    exit 1
fi
expect_contains "$path_preflight_output" 'WireGuard config path is not a directory'
if [ -e "$TMP/package-install-called" ]; then
    printf 'node join installed WireGuard before rejecting the config path\n' >&2
    exit 1
fi
mkdir "$TMP/readonly-parent"
chmod 500 "$TMP/readonly-parent"
if [ ! -w "$TMP/readonly-parent" ]; then
    path_preflight_output=
    if path_preflight_output=$(PATH="$TMP/preflight-bin:$TMP/platform/linux:/usr/bin:/bin" \
        WGMESH_STATE_ROOT="$TMP/preflight-state" \
        WGMESH_CONFIG_ROOT="$TMP/readonly-parent/config" \
        WGMESH_WG="$TMP/missing-wg" WGMESH_WG_QUICK="$TMP/missing-wg-quick" \
        WGMESH_TEST_PACKAGE_INSTALL_CALLED="$TMP/package-install-called" \
        "$SCRIPT" node join --network-name preflight-permissions --node-id node-a \
        --transport tailscale --overlay-cidr 198.51.100.0/24 \
        --address 198.51.100.2/32 --hub-endpoint 203.0.113.130:51820 \
        --hub-public-key BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB= --no-autostart 2>&1); then
        printf 'node join accepted an unwritable config parent\n' >&2
        exit 1
    fi
    expect_contains "$path_preflight_output" 'WireGuard config path is not writable'
    if [ -e "$TMP/package-install-called" ]; then
        printf 'node join installed WireGuard before rejecting config permissions\n' >&2
        exit 1
    fi
fi
path_preflight_output=
if path_preflight_output=$(PATH="$TMP/preflight-bin:$TEST_PLATFORM_BIN:/usr/bin:/bin" \
    WGMESH_STATE_ROOT="$TMP/preflight-state" WGMESH_CONFIG_ROOT="$TMP/config" \
    WGMESH_LAUNCHD_ROOT="$TMP/launchd-root-is-a-file" \
    WGMESH_WG="$TMP/missing-wg" WGMESH_WG_QUICK="$TMP/missing-wg-quick" \
    WGMESH_TEST_BREW_CALLED="$TMP/preflight-brew-called" \
    "$SCRIPT" host init --network-name preflight-launchd --node-id hub \
    --transport tailscale --overlay-cidr 192.0.2.0/24 \
    --address 192.0.2.1/24 --endpoint 203.0.113.130:51820 2>&1); then
    printf 'host init accepted a non-directory LaunchDaemon path\n' >&2
    exit 1
fi
expect_contains "$path_preflight_output" 'LaunchDaemon path is not a directory'
if [ -e "$TMP/preflight-brew-called" ]; then
    printf 'host init invoked Homebrew before rejecting the LaunchDaemon path\n' >&2
    exit 1
fi

host_args="
--network-name demo
--node-id hub
--transport tailscale
--overlay-cidr 198.51.100.0/24
--address 198.51.100.1/24
--endpoint 203.0.113.130:51820
--no-autostart"

route_conflict_output=
if route_conflict_output=$(run host init --network-name route-conflict --node-id hub \
    --transport tailscale --overlay-cidr 192.0.2.0/24 \
    --address 192.0.2.1/24 --endpoint 203.0.113.130:51820 \
    --no-autostart 2>&1); then
    printf 'overlay overlapping an existing local network was accepted\n' >&2
    exit 1
fi
expect_contains "$route_conflict_output" 'overlaps existing local route'

host_output=$(run host init $host_args)
expect_contains "$host_output" 'hub_public_key=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB='
expect_contains "$host_output" 'result=CREATED'
expect_contains "$host_output" 'interface_state=ACTIVE'
if [ "$(grep -c '^PostUp = .*net\.inet\.ip\.forwarding=1$' "$TMP/config/wgmesh-demo.conf")" -ne 1 ] ||
    ! grep -q -- '-w net.inet.ip.forwarding=1' "$TMP/sysctl.log"; then
    printf 'macOS Hub forwarding was not configured exactly once\n' >&2
    exit 1
fi

new_option_output=$(run host init --network-name canonical-name --node-id hub \
    --transport tailscale --overlay-cidr 203.0.113.0/25 \
    --address 203.0.113.1/25 --endpoint 203.0.113.130:51820 \
    --no-autostart)
expect_contains "$new_option_output" 'network_id=canonical-name'
expect_contains "$new_option_output" 'result=CREATED'
new_option_uninstall=$(run host uninstall --network-name canonical-name)
expect_contains "$new_option_uninstall" 'state=ABSENT'

mtu_output=$(run host init --network-name mtu-demo --node-id hub \
    --transport tailscale --overlay-cidr 203.0.113.64/26 \
    --address 203.0.113.65/26 --endpoint 203.0.113.130:51820 \
    --mtu 1300 --no-autostart)
expect_contains "$mtu_output" 'result=CREATED'
mtu_repeat=$(run host init --network-name mtu-demo --node-id hub \
    --transport tailscale --overlay-cidr 203.0.113.64/26 \
    --address 203.0.113.65/26 --endpoint 203.0.113.130:51820 \
    --no-autostart)
expect_contains "$mtu_repeat" 'result=NOOP'
if ! grep -q '^MTU = 1300$' "$TMP/config/wgmesh-mtu-demo.conf"; then
    printf 'repeated host init did not preserve the configured MTU\n' >&2
    exit 1
fi
awk -F= '
    $1 != "schema_version" &&
    $1 != "firewall_mode" &&
    $1 != "peer_addresses" &&
    $1 != "mtu" { print }
' "$TMP/state/mtu-demo/host.state" > "$TMP/state/mtu-demo/host.state.legacy"
mv "$TMP/state/mtu-demo/host.state.legacy" "$TMP/state/mtu-demo/host.state"
cp "$TMP/state/mtu-demo/host.state" "$TMP/state/mtu-demo/host.state.before-status"
legacy_status=$(run status --network-name mtu-demo)
expect_contains "$legacy_status" 'mtu_configured=1300'
expect_contains "$legacy_status" 'state_migration_required=true'
expect_contains "$legacy_status" 'config_consistency=UNKNOWN'
expect_contains "$legacy_status" 'STATE_MIGRATION_REQUIRED'
if ! cmp -s "$TMP/state/mtu-demo/host.state.before-status" "$TMP/state/mtu-demo/host.state"; then
    printf 'status modified legacy host state\n' >&2
    exit 1
fi
legacy_migrate=$(run host init --network-name mtu-demo --node-id hub \
    --transport tailscale --overlay-cidr 203.0.113.64/26 \
    --address 203.0.113.65/26 --endpoint 203.0.113.130:51820 \
    --mtu 1300 --no-autostart)
expect_contains "$legacy_migrate" 'result=NOOP'
if ! grep -q '^schema_version=2$' "$TMP/state/mtu-demo/host.state" ||
    ! grep -q '^firewall_mode=external$' "$TMP/state/mtu-demo/host.state" ||
    ! grep -q '^peer_addresses=$' "$TMP/state/mtu-demo/host.state" ||
    ! grep -q '^mtu=1300$' "$TMP/state/mtu-demo/host.state"; then
    printf 'explicit host operation did not migrate legacy state with its configured MTU\n' >&2
    exit 1
fi
mtu_uninstall=$(run host uninstall --network-name mtu-demo)
expect_contains "$mtu_uninstall" 'state=ABSENT'

legacy_option_output=
if legacy_option_output=$(run host init --network legacy-name --node-id hub \
    --transport tailscale --overlay-cidr 203.0.113.0/25 \
    --address 203.0.113.1/25 --endpoint 203.0.113.130:51820 \
    --no-autostart 2>&1); then
    printf 'deprecated --network option was accepted\n' >&2
    exit 1
fi
expect_contains "$legacy_option_output" 'unknown option: --network'

state_conflict_output=
if state_conflict_output=$(run host init --network-name state-conflict --node-id hub \
    --transport tailscale --overlay-cidr 198.51.100.0/25 \
    --address 198.51.100.10/25 --endpoint 203.0.113.130:51820 \
    --no-autostart 2>&1); then
    printf 'overlay overlapping an existing wgmesh state was accepted\n' >&2
    exit 1
fi
expect_contains "$state_conflict_output" 'overlaps existing wgmesh network'

cp "$TMP/ip.routes" "$TMP/ip.routes.baseline"
cat > "$TMP/ip.routes" <<'EOF'
default via 192.0.2.1 dev eth0
192.0.2.0/24 dev eth0 proto kernel scope link src 192.0.2.10
203.0.113.128/25 dev tailscale0 proto kernel scope link src 203.0.113.129
198.51.100.0/24 dev wgmesh-demo proto kernel scope link src 198.51.100.1
EOF
host_output=$(run host init $host_args)
expect_contains "$host_output" 'result=NOOP'
mv "$TMP/ip.routes.baseline" "$TMP/ip.routes"

host_output=$(run host init $host_args)
expect_contains "$host_output" 'result=NOOP'
rm -f "$TMP/active"
host_output=$(run host init $host_args)
expect_contains "$host_output" 'result=NOOP'
if [ ! -f "$TMP/active" ]; then
    printf 'repeated macOS host init did not restore the stopped interface\n' >&2
    exit 1
fi

launchd_output=$(run host init --network-name darwin-auto --node-id hub \
    --transport tailscale --overlay-cidr 203.0.113.0/25 \
    --address 203.0.113.1/25 --endpoint 203.0.113.130:51820)
expect_contains "$launchd_output" 'result=CREATED'
rm -f "$TMP"/launchd/*.plist "$TMP/launchd-enabled" "$TMP/launchd-loaded" "$TMP/active"
launchd_output=$(run host init --network-name darwin-auto --node-id hub \
    --transport tailscale --overlay-cidr 203.0.113.0/25 \
    --address 203.0.113.1/25 --endpoint 203.0.113.130:51820)
expect_contains "$launchd_output" 'result=NOOP'
if [ ! -f "$TMP/active" ] || [ ! -f "$TMP/launchd-enabled" ] ||
    [ ! -f "$TMP/launchd-loaded" ] ||
    ! grep -q 'wgmesh-managed=true' "$TMP"/launchd/*.plist; then
    printf 'repeated macOS host init did not restore its interface or LaunchDaemon\n' >&2
    exit 1
fi
if ! grep -Fq "<key>EnvironmentVariables</key><dict>" "$TMP/launchd"/*.plist ||
    ! grep -Fq "<string>$TMP/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>" "$TMP/launchd"/*.plist; then
    printf 'macOS LaunchDaemon does not include the WireGuard tools in PATH\n' >&2
    exit 1
fi
launchd_status=$(run status --network-name darwin-auto --json)
expect_contains "$launchd_status" '"autostart":true'
expect_contains "$launchd_status" '"service_state":"ACTIVE"'
mkdir -p "$TMP/wireguard-runtime"
printf '%s\n' utun9 > "$(runtime_interface_mapping darwin-auto)"
printf '%s\n' utun9 > "$TMP/wg-real-interface"
launchd_status=$(run status --network-name darwin-auto --json)
expect_contains "$launchd_status" '"state":"ACTIVE"'
rm -f "$(runtime_interface_mapping darwin-auto)" "$TMP/wg-real-interface"
launchd_uninstall=$(run host uninstall --network-name darwin-auto)
expect_contains "$launchd_uninstall" 'state=ABSENT'
host_output=$(run host init $host_args)
expect_contains "$host_output" 'result=NOOP'

if run host add-node --network-name demo --node-id outside --address 203.0.113.2/32 \
    --node-public-key CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC= >/dev/null 2>&1; then
    printf 'out-of-overlay peer was accepted\n' >&2
    exit 1
fi

mkdir -p "$TMP/wireguard-runtime"
printf '%s\n' utun9 > "$(runtime_interface_mapping demo)"
printf '%s\n' utun9 > "$TMP/wg-real-interface"
touch "$TMP/active"
peer_args="--network-name demo --node-id node-a --address 198.51.100.2/32 --node-public-key CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC="
peer_output=$(run host add-node $peer_args)
expect_contains "$peer_output" 'result=CREATED'
peer_output=$(run host add-node $peer_args)
expect_contains "$peer_output" 'result=NOOP'
if ! grep -q '^set utun9 peer CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC= allowed-ips 198.51.100.2/32$' "$TMP/wg-set.log"; then
    printf 'macOS peer mutation did not use the resolved utun interface\n' >&2
    exit 1
fi
rm -f "$TMP/wg-real-interface"

peer_two_args="--network-name demo --node-id node-b --address 198.51.100.3/32 --node-public-key DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD= --peer-address 203.0.113.7/32 --peer-address 203.0.113.6/32"
peer_output=$(run host add-node $peer_two_args)
expect_contains "$peer_output" 'result=CREATED'
if ! grep -q '^AllowedIPs = 198.51.100.3/32,203.0.113.6/32,203.0.113.7/32$' "$TMP/config/wgmesh-demo.conf"; then
    printf 'Hub config did not persist the peer additional address\n' >&2
    cat "$TMP/config/wgmesh-demo.conf" >&2
    exit 1
fi
host_routes=$(run host set-routes --network-name demo --node-id node-a \
    --peer-address 203.0.113.8/32 --peer-address 203.0.113.9/32)
expect_contains "$host_routes" 'result=UPDATED'
host_routes=$(run host set-routes --network-name demo --node-id node-a \
    --peer-address 203.0.113.8/32 --peer-address 203.0.113.9/32)
expect_contains "$host_routes" 'result=NOOP'
if ! grep -q '^AllowedIPs = 198.51.100.2/32,203.0.113.8/32,203.0.113.9/32$' "$TMP/config/wgmesh-demo.conf"; then
    printf 'host set-routes did not update peer AllowedIPs\n' >&2
    exit 1
fi
if [ ! -f "$TMP/state/demo/peers/node-a.state" ] ||
    [ ! -f "$TMP/state/demo/peers/node-b.state" ] ||
    ! grep -q '^node_id=node-a$' "$TMP/state/demo/peers/node-a.state" ||
    ! grep -q '^node_id=node-b$' "$TMP/state/demo/peers/node-b.state"; then
    printf 'adding a second peer did not preserve both peer state files\n' >&2
    exit 1
fi
if [ "$(grep -c '^PostUp = .*net\.inet\.ip\.forwarding=1$' "$TMP/config/wgmesh-demo.conf")" -ne 1 ]; then
    printf 'adding Hub peers duplicated the macOS forwarding hook\n' >&2
    exit 1
fi

peer_a_key=$(sed -n 's/^public_key=//p' "$TMP/state/demo/peers/node-a.state")
peer_b_key=$(sed -n 's/^public_key=//p' "$TMP/state/demo/peers/node-b.state")
{
    printf '%s\n' 'private-key	public-key	51820	off'
    printf '%s\n' "$peer_a_key	(none)	0.0.0.0:0	198.51.100.2/32,203.0.113.8/32,203.0.113.9/32	0	0	0	off"
    printf '%s\n' "$peer_b_key	(none)	0.0.0.0:0	198.51.100.3/32,203.0.113.6/32,203.0.113.7/32	0	0	0	off"
} > "$TMP/wg-dump.txt"
status_output=$(run status --network-name demo --json)
expect_contains "$status_output" '"state":"ACTIVE"'
expect_contains "$status_output" '"service_state":"INACTIVE"'
expect_contains "$status_output" '"peer_count":2'
expect_contains "$status_output" '"config_consistency":"CONSISTENT"'
expect_contains "$status_output" '"endpoint_path":"tailscale0"'

sed 's/203.0.113.8\/32/203.0.113.10\/32/' "$TMP/wg-dump.txt" > "$TMP/wg-dump.drift"
mv "$TMP/wg-dump.drift" "$TMP/wg-dump.txt"
status_output=$(run status --network-name demo --json)
expect_contains "$status_output" '"config_consistency":"CONFIG_DRIFT"'
expect_contains "$status_output" 'RUNTIME_PEERS'
{
    printf '%s\n' 'private-key	public-key	51820	off'
    printf '%s\n' "$peer_a_key	(none)	0.0.0.0:0	198.51.100.2/32,203.0.113.8/32,203.0.113.9/32	0	0	0	off"
    printf '%s\n' "$peer_b_key	(none)	0.0.0.0:0	198.51.100.3/32,203.0.113.6/32,203.0.113.7/32	0	0	0	off"
} > "$TMP/wg-dump.txt"
cp "$TMP/netstat.txt" "$TMP/netstat.before-status-route-drift"
awk '$1 == "203.0.113.8" { $NF="en0" } { print }' "$TMP/netstat.txt" > "$TMP/netstat.drift"
mv "$TMP/netstat.drift" "$TMP/netstat.txt"
status_output=$(run status --network-name demo --json)
expect_contains "$status_output" '"config_consistency":"CONFIG_DRIFT"'
expect_contains "$status_output" 'PEER_ROUTE'
mv "$TMP/netstat.before-status-route-drift" "$TMP/netstat.txt"
printf '%s\n' utun9 > "$TMP/endpoint-interface"
printf '%s\n' utun9 > "$TMP/wg-real-interface"
status_output=$(run status --network-name demo --json)
expect_contains "$status_output" '"config_consistency":"CONFIG_DRIFT"'
expect_contains "$status_output" 'ENDPOINT_PATH'
rm -f "$TMP/endpoint-interface"
rm -f "$TMP/wg-real-interface"

remove_output=$(run host remove-node --network-name demo --node-id node-a)
expect_contains "$remove_output" 'result=REMOVED'
uninstall_output=$(run host uninstall --network-name demo)
expect_contains "$uninstall_output" 'state=ABSENT'
if grep -q '^203\.0\.113\.7 ' "$TMP/netstat.txt" ||
    ! grep -q 'delete -host 203\.0\.113\.7$' "$TMP/route-mutations.log"; then
    printf 'Hub uninstall did not remove its macOS wgmesh-owned peer route\n' >&2
    exit 1
fi

printf '%s\n' utun9 > "$TMP/wg-real-interface"
touch "$TMP/active"
node_output=$(run node join --network-name demo --node-id node-a --transport public \
    --overlay-cidr 198.51.100.0/24 --address 198.51.100.2/32 \
    --hub-endpoint 203.0.113.130:51820 \
    --hub-public-key CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC= \
    --mtu 1250 --no-autostart)
expect_contains "$node_output" 'node_public_key=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB='
expect_contains "$node_output" 'interface_state=ACTIVE'
node_repeat=$(run node join --network-name demo --node-id node-a --transport public \
    --overlay-cidr 198.51.100.0/24 --address 198.51.100.2/32 \
    --hub-endpoint 203.0.113.130:51820 \
    --hub-public-key CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC= --no-autostart)
expect_contains "$node_repeat" 'result=NOOP'
if ! grep -q '^MTU = 1250$' "$TMP/config/wgmesh-demo.conf"; then
    printf 'repeated node join did not preserve the configured MTU\n' >&2
    exit 1
fi
node_status=$(run status --network-name demo --json)
expect_contains "$node_status" '"peer_addresses":""'
node_routes=$(run node set-routes --network-name demo --peer-address 203.0.113.9/32)
expect_contains "$node_routes" 'result=UPDATED'
if ! grep -q '^AllowedIPs = 198\.51\.100\.0/24,203\.0\.113\.9/32$' "$TMP/config/wgmesh-demo.conf"; then
    printf 'Node set-routes did not persist the additional peer address\n' >&2
    exit 1
fi
if ! grep -q 'add -host 203\.0\.113\.9 -interface utun9' "$TMP/route-mutations.log"; then
    printf 'Node set-routes did not add the verified absent route to utun9\n' >&2
    exit 1
fi
rm -f "$TMP/active" "$TMP/wg-real-interface"
if run node set-routes --network-name demo --peer-address 203.0.113.9/32 >/dev/null 2>&1; then
    printf 'Node set-routes changed route state while the interface was inactive\n' >&2
    exit 1
fi
printf '%s\n' utun9 > "$TMP/wg-real-interface"
touch "$TMP/active"
cp "$TMP/config/wgmesh-demo.conf" "$TMP/node-config.before-route-conflict"
printf '%s\n' '203.0.113.10       link#3             UHS          en0' >> "$TMP/netstat.txt"
if run node set-routes --network-name demo --peer-address 203.0.113.10/32 >/dev/null 2>&1; then
    printf 'Node set-routes replaced a pre-existing route on another interface\n' >&2
    exit 1
fi
cmp -s "$TMP/config/wgmesh-demo.conf" "$TMP/node-config.before-route-conflict" || {
    printf 'route conflict changed the managed config\n' >&2
    exit 1
}
if grep -q 'add -host 203\.0\.113\.10 ' "$TMP/route-mutations.log"; then
    printf 'route conflict attempted to overwrite the existing route\n' >&2
    exit 1
fi
sed '$d' "$TMP/netstat.txt" > "$TMP/netstat.txt.tmp"
mv "$TMP/netstat.txt.tmp" "$TMP/netstat.txt"
TEST_FAIL_ROUTE_ADD=203.0.113.12
if run node set-routes --network-name demo --peer-address 203.0.113.11/32 \
    --peer-address 203.0.113.12/32 >/dev/null 2>&1; then
    printf 'route-add failure did not abort the route transaction\n' >&2
    exit 1
fi
unset TEST_FAIL_ROUTE_ADD
cmp -s "$TMP/config/wgmesh-demo.conf" "$TMP/node-config.before-route-conflict" || {
    printf 'failed route transaction changed the managed config\n' >&2
    exit 1
}
if ! grep -q 'delete -host 203\.0\.113\.11$' "$TMP/route-mutations.log"; then
    printf 'failed route transaction did not remove its newly added route\n' >&2
    exit 1
fi
if run node set-routes --network-name demo --peer-address 203.0.113.130/32 >/dev/null 2>&1; then
    printf 'peer route equal to the WireGuard endpoint bypassed underlay protection\n' >&2
    exit 1
fi
if [ "$(grep -c '^\[Peer\]$' "$TMP/config/wgmesh-demo.conf")" -ne 1 ] ||
    grep -q '^PostUp = ' "$TMP/config/wgmesh-demo.conf" ||
    ! grep -q '^AllowedIPs = 198\.51\.100\.0/24,203\.0\.113\.9/32$' "$TMP/config/wgmesh-demo.conf"; then
    printf 'Node config does not contain exactly one Hub peer without forwarding hook\n' >&2
    exit 1
fi

if run node uninstall --network-name demo --node-id wrong-node >/dev/null 2>&1; then
    printf 'uninstall accepted a mismatched node-id\n' >&2
    exit 1
fi

node_uninstall=$(run node uninstall --network-name demo --node-id node-a)
expect_contains "$node_uninstall" 'state=ABSENT'
if grep -q '^203\.0\.113\.9/32 dev ' "$TMP/ip.route-state" ||
    ! grep -q 'delete -host 203\.0\.113\.9$' "$TMP/route-mutations.log"; then
    printf 'Node uninstall did not remove its wgmesh-owned peer route\n' >&2
    exit 1
fi
rm -f "$TMP/wg-real-interface"

TEST_PLATFORM_BIN="$TMP/platform/linux"
linux_route_conflict_output=
if linux_route_conflict_output=$(run host init --network-name linux-route-conflict --node-id hub \
    --transport public --overlay-cidr 192.0.2.0/24 \
    --address 192.0.2.1/24 --endpoint 203.0.113.130:51820 \
    --no-autostart 2>&1); then
    printf 'Linux overlay overlapping an existing local network was accepted\n' >&2
    exit 1
fi
expect_contains "$linux_route_conflict_output" 'overlaps existing local route'

linux_output=$(run host init --network-name linux-demo --node-id hub \
    --transport public --overlay-cidr 198.51.100.0/24 \
    --address 198.51.100.1/24 --endpoint 203.0.113.130:51820)
expect_contains "$linux_output" 'result=CREATED'
expect_contains "$linux_output" 'interface_state=ACTIVE'
linux_status=$(run status --network-name linux-demo --json)
expect_contains "$linux_status" '"autostart":true'
expect_contains "$linux_status" '"state":"ACTIVE"'
expect_contains "$linux_status" '"service_state":"ACTIVE"'
linux_status_text=$(run status --network-name linux-demo)
expect_contains "$linux_status_text" 'autostart=enabled'
expect_contains "$linux_status_text" 'state=ACTIVE'
expect_contains "$linux_status_text" 'service_state=ACTIVE'
expect_contains "$linux_status_text" 'consistency_state=CONSISTENT'
linux_config=
for candidate in "$TMP/config"/*.conf; do
    [ -f "$candidate" ] || continue
    linux_config=$candidate
done
if [ -z "$linux_config" ] ||
    [ "$(grep -c '^PostUp = .*net\.ipv4\.ip_forward=1$' "$linux_config")" -ne 1 ] ||
    ! grep -q -- '-w net.ipv4.ip_forward=1' "$TMP/sysctl.log"; then
    printf 'Linux Hub forwarding was not configured exactly once\n' >&2
    exit 1
fi
rm -f "$TMP/active" "$TMP/system-enabled"
linux_output=$(run host init --network-name linux-demo --node-id hub \
    --transport public --overlay-cidr 198.51.100.0/24 \
    --address 198.51.100.1/24 --endpoint 203.0.113.130:51820)
expect_contains "$linux_output" 'result=NOOP'
expect_contains "$linux_output" 'interface_state=ACTIVE'
if [ ! -f "$TMP/active" ] || [ ! -f "$TMP/system-enabled" ]; then
    printf 'repeated Linux host init did not restore the interface and autostart\n' >&2
    exit 1
fi
linux_peer=$(run host add-node --network-name linux-demo --node-id node-l \
    --address 198.51.100.2/32 --node-public-key CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC= \
    --peer-address 203.0.113.31/32)
expect_contains "$linux_peer" 'result=CREATED'
if ! grep -q '^203\.0\.113\.31/32 dev ' "$TMP/ip.route-state" ||
    grep -q 'route replace' "$TMP/ip-mutations.log"; then
    printf 'Linux peer route was not added only to an empty route slot\n' >&2
    exit 1
fi
cp "$linux_config" "$TMP/linux-config.before-route-tests"
cp "$TMP/state/linux-demo/peers/node-l.state" "$TMP/linux-peer.before-route-tests"
printf '%s\n' '203.0.113.32/32 dev eth0' >> "$TMP/ip.route-state"
if run host set-routes --network-name linux-demo --node-id node-l \
    --peer-address 203.0.113.32/32 >/dev/null 2>&1; then
    printf 'Linux route update replaced a pre-existing route on another interface\n' >&2
    exit 1
fi
cmp -s "$linux_config" "$TMP/linux-config.before-route-tests" ||
    { printf 'Linux route conflict changed config\n' >&2; exit 1; }
cmp -s "$TMP/state/linux-demo/peers/node-l.state" "$TMP/linux-peer.before-route-tests" ||
    { printf 'Linux route conflict changed peer state\n' >&2; exit 1; }
awk '$1 != "203.0.113.32/32" { print }' "$TMP/ip.route-state" > "$TMP/ip.route-state.tmp"
mv "$TMP/ip.route-state.tmp" "$TMP/ip.route-state"
TEST_FAIL_IP_ROUTE_ADD=203.0.113.33/32
if run host set-routes --network-name linux-demo --node-id node-l \
    --peer-address 203.0.113.32/32 --peer-address 203.0.113.33/32 >/dev/null 2>&1; then
    printf 'Linux route-add failure did not abort the transaction\n' >&2
    exit 1
fi
unset TEST_FAIL_IP_ROUTE_ADD
cmp -s "$linux_config" "$TMP/linux-config.before-route-tests" ||
    { printf 'failed Linux route transaction changed config\n' >&2; exit 1; }
cmp -s "$TMP/state/linux-demo/peers/node-l.state" "$TMP/linux-peer.before-route-tests" ||
    { printf 'failed Linux route transaction changed peer state\n' >&2; exit 1; }
if grep -q '^203\.0\.113\.32/32 dev ' "$TMP/ip.route-state"; then
    printf 'failed Linux route transaction left its newly added route\n' >&2
    exit 1
fi
linux_uninstall=$(run host uninstall --network-name linux-demo)
expect_contains "$linux_uninstall" 'state=ABSENT'
if grep -q '^203\.0\.113\.31/32 dev ' "$TMP/ip.route-state" ||
    ! grep -q -- '-4 route del 203.0.113.31/32 dev ' "$TMP/ip-mutations.log"; then
    printf 'Hub uninstall did not remove its wgmesh-owned peer route\n' >&2
    exit 1
fi
if ! awk '$1 == "disable" && $2 == "--now" { found = 1 } END { exit !found }' \
    "$TMP/systemctl.log"; then
    printf 'Linux uninstall did not stop the enabled tunnel service\n' >&2
    exit 1
fi

printf 'wgmesh Unix mock smoke: PASS\n'
