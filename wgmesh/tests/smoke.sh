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
        [ -f "$WGMESH_TEST_ACTIVE" ]
        ;;
    set)
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
    enable) touch "$WGMESH_TEST_SYSTEM_ENABLED" ;;
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
    "-4 route show")
        cat "$WGMESH_TEST_IP_ROUTES"
        ;;
    "-4 -o addr show")
        cat "$WGMESH_TEST_IP_ADDRS"
        ;;
    *)
        exit 2
        ;;
esac
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
198.51.100.0/24 dev tailscale0 proto kernel scope link src 198.51.100.10
EOF

cat > "$TMP/ip.addrs" <<'EOF'
1: lo    inet 127.0.0.1/8 scope host lo
2: eth0    inet 192.0.2.10/24 scope global eth0
3: tailscale0    inet 198.51.100.10/32 scope global tailscale0
EOF

cat > "$TMP/ifconfig.txt" <<'EOF'
en0: flags=8863
	inet 192.0.2.10 netmask 0xffffff00 broadcast 192.0.2.255
tailscale0: flags=8863
	inet 198.51.100.10 netmask 0xffffffff
EOF

cat > "$TMP/netstat.txt" <<'EOF'
Routing tables

Internet:
Destination        Gateway            Flags        Netif
default            192.0.2.1          UGSc         en0
192.0.2            link#4             UCS          en0
198.51.100         link#5             UCS          tailscale0
EOF

chmod 700 "$TMP/bin/wg" "$TMP/bin/wg-quick" "$TMP/bin/wireguard-go" \
    "$TMP/bin/systemctl" "$TMP/bin/launchctl" "$TMP/bin/ip" \
    "$TMP/bin/ifconfig" "$TMP/bin/netstat" \
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
    WGMESH_IFCONFIG="$TMP/bin/ifconfig" \
    WGMESH_NETSTAT="$TMP/bin/netstat" \
    WGMESH_SYSCTL="$TMP/bin/sysctl" \
    WGMESH_TEST_IP_ROUTES="$TMP/ip.routes" \
    WGMESH_TEST_IP_ADDRS="$TMP/ip.addrs" \
    WGMESH_TEST_IFCONFIG="$TMP/ifconfig.txt" \
    WGMESH_TEST_NETSTAT="$TMP/netstat.txt" \
    WGMESH_TEST_SYSCTL_LOG="$TMP/sysctl.log" \
    WGMESH_TEST_SYSCTL_LINUX_STATE="$TMP/sysctl-linux.state" \
    WGMESH_TEST_SYSCTL_MACOS_STATE="$TMP/sysctl-macos.state" \
    WGMESH_TEST_ACTIVE="$TMP/active" \
    WGMESH_TEST_SYSTEM_ENABLED="$TMP/system-enabled" \
    WGMESH_TEST_SYSTEM_ACTIVE="$TMP/system-active" \
    WGMESH_TEST_SYSTEMCTL_LOG="$TMP/systemctl.log" \
    WGMESH_LAUNCHD_ROOT="$TMP/launchd" \
    WGMESH_TEST_LAUNCHD_ENABLED="$TMP/launchd-enabled" \
    WGMESH_TEST_LAUNCHD_LOADED="$TMP/launchd-loaded" \
        "$SCRIPT" "$@"
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
host_args="
--network-name demo
--node-id hub
--transport tailscale
--overlay-cidr 10.250.0.0/24
--address 10.250.0.1/24
--endpoint 203.0.113.1:51820
--no-autostart"

route_conflict_output=
if route_conflict_output=$(run host init --network-name route-conflict --node-id hub \
    --transport tailscale --overlay-cidr 192.0.2.0/24 \
    --address 192.0.2.1/24 --endpoint 203.0.113.1:51820 \
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
    --transport tailscale --overlay-cidr 10.253.0.0/24 \
    --address 10.253.0.1/24 --endpoint 203.0.113.1:51820 \
    --no-autostart)
expect_contains "$new_option_output" 'network_id=canonical-name'
expect_contains "$new_option_output" 'result=CREATED'
new_option_uninstall=$(run host uninstall --network-name canonical-name)
expect_contains "$new_option_uninstall" 'state=ABSENT'

legacy_option_output=
if legacy_option_output=$(run host init --network legacy-name --node-id hub \
    --transport tailscale --overlay-cidr 10.254.0.0/24 \
    --address 10.254.0.1/24 --endpoint 203.0.113.1:51820 \
    --no-autostart 2>&1); then
    printf 'deprecated --network option was accepted\n' >&2
    exit 1
fi
expect_contains "$legacy_option_output" 'unknown option: --network'

state_conflict_output=
if state_conflict_output=$(run host init --network-name state-conflict --node-id hub \
    --transport tailscale --overlay-cidr 10.250.0.0/25 \
    --address 10.250.0.10/25 --endpoint 203.0.113.1:51820 \
    --no-autostart 2>&1); then
    printf 'overlay overlapping an existing wgmesh state was accepted\n' >&2
    exit 1
fi
expect_contains "$state_conflict_output" 'overlaps existing wgmesh network'

cp "$TMP/ip.routes" "$TMP/ip.routes.baseline"
cat > "$TMP/ip.routes" <<'EOF'
default via 192.0.2.1 dev eth0
192.0.2.0/24 dev eth0 proto kernel scope link src 192.0.2.10
198.51.100.0/24 dev tailscale0 proto kernel scope link src 198.51.100.10
10.250.0.0/24 dev wgmesh-demo proto kernel scope link src 10.250.0.1
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
    --transport tailscale --overlay-cidr 10.251.0.0/24 \
    --address 10.251.0.1/24 --endpoint 203.0.113.1:51820)
expect_contains "$launchd_output" 'result=CREATED'
rm -f "$TMP"/launchd/*.plist "$TMP/launchd-enabled" "$TMP/launchd-loaded" "$TMP/active"
launchd_output=$(run host init --network-name darwin-auto --node-id hub \
    --transport tailscale --overlay-cidr 10.251.0.0/24 \
    --address 10.251.0.1/24 --endpoint 203.0.113.1:51820)
expect_contains "$launchd_output" 'result=NOOP'
if [ ! -f "$TMP/active" ] || [ ! -f "$TMP/launchd-enabled" ] ||
    [ ! -f "$TMP/launchd-loaded" ] ||
    ! grep -q 'wgmesh-managed=true' "$TMP"/launchd/*.plist; then
    printf 'repeated macOS host init did not restore its interface or LaunchDaemon\n' >&2
    exit 1
fi
launchd_status=$(run status --network-name darwin-auto --json)
expect_contains "$launchd_status" '"autostart":true'
expect_contains "$launchd_status" '"service_state":"ACTIVE"'
launchd_uninstall=$(run host uninstall --network-name darwin-auto)
expect_contains "$launchd_uninstall" 'state=ABSENT'
host_output=$(run host init $host_args)
expect_contains "$host_output" 'result=NOOP'

if run host add-node --network-name demo --node-id outside --address 198.51.100.2/32 \
    --node-public-key CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC= >/dev/null 2>&1; then
    printf 'out-of-overlay peer was accepted\n' >&2
    exit 1
fi

peer_args="--network-name demo --node-id node-a --address 10.250.0.2/32 --node-public-key CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC="
peer_output=$(run host add-node $peer_args)
expect_contains "$peer_output" 'result=CREATED'
peer_output=$(run host add-node $peer_args)
expect_contains "$peer_output" 'result=NOOP'

peer_two_args="--network-name demo --node-id node-b --address 10.250.0.3/32 --node-public-key DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD="
peer_output=$(run host add-node $peer_two_args)
expect_contains "$peer_output" 'result=CREATED'
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

status_output=$(run status --network-name demo --json)
expect_contains "$status_output" '"state":"ACTIVE"'
expect_contains "$status_output" '"service_state":"INACTIVE"'
expect_contains "$status_output" '"peer_count":2'

remove_output=$(run host remove-node --network-name demo --node-id node-a)
expect_contains "$remove_output" 'result=REMOVED'
uninstall_output=$(run host uninstall --network-name demo)
expect_contains "$uninstall_output" 'state=ABSENT'

node_output=$(run node join --network-name demo --node-id node-a --transport public \
    --overlay-cidr 10.250.0.0/24 --address 10.250.0.2/32 \
    --hub-endpoint 203.0.113.20:51820 \
    --hub-public-key CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC= --no-autostart)
expect_contains "$node_output" 'node_public_key=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB='
expect_contains "$node_output" 'interface_state=ACTIVE'
if [ "$(grep -c '^\[Peer\]$' "$TMP/config/wgmesh-demo.conf")" -ne 1 ] ||
    grep -q '^PostUp = ' "$TMP/config/wgmesh-demo.conf" ||
    ! grep -q '^AllowedIPs = 10\.250\.0\.0/24$' "$TMP/config/wgmesh-demo.conf"; then
    printf 'Node config does not contain exactly one Hub peer without forwarding hook\n' >&2
    exit 1
fi

if run node uninstall --network-name demo --node-id wrong-node >/dev/null 2>&1; then
    printf 'uninstall accepted a mismatched node-id\n' >&2
    exit 1
fi

node_uninstall=$(run node uninstall --network-name demo --node-id node-a)
expect_contains "$node_uninstall" 'state=ABSENT'

TEST_PLATFORM_BIN="$TMP/platform/linux"
linux_route_conflict_output=
if linux_route_conflict_output=$(run host init --network-name linux-route-conflict --node-id hub \
    --transport public --overlay-cidr 192.0.2.0/24 \
    --address 192.0.2.1/24 --endpoint 203.0.113.20:51820 \
    --no-autostart 2>&1); then
    printf 'Linux overlay overlapping an existing local network was accepted\n' >&2
    exit 1
fi
expect_contains "$linux_route_conflict_output" 'overlaps existing local route'

linux_output=$(run host init --network-name linux-demo --node-id hub \
    --transport public --overlay-cidr 10.252.0.0/24 \
    --address 10.252.0.1/24 --endpoint 203.0.113.20:51820)
expect_contains "$linux_output" 'result=CREATED'
expect_contains "$linux_output" 'interface_state=ACTIVE'
linux_status=$(run status --network-name linux-demo --json)
expect_contains "$linux_status" '"autostart":true'
expect_contains "$linux_status" '"state":"ACTIVE"'
expect_contains "$linux_status" '"service_state":"INACTIVE"'
linux_status_text=$(run status --network-name linux-demo)
expect_contains "$linux_status_text" 'autostart=enabled'
expect_contains "$linux_status_text" 'state=ACTIVE'
expect_contains "$linux_status_text" 'service_state=INACTIVE'
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
    --transport public --overlay-cidr 10.252.0.0/24 \
    --address 10.252.0.1/24 --endpoint 203.0.113.20:51820)
expect_contains "$linux_output" 'result=NOOP'
expect_contains "$linux_output" 'interface_state=ACTIVE'
if [ ! -f "$TMP/active" ] || [ ! -f "$TMP/system-enabled" ]; then
    printf 'repeated Linux host init did not restore the interface and autostart\n' >&2
    exit 1
fi
linux_uninstall=$(run host uninstall --network-name linux-demo)
expect_contains "$linux_uninstall" 'state=ABSENT'
if ! awk '$1 == "disable" && $2 == "--now" { found = 1 } END { exit !found }' \
    "$TMP/systemctl.log"; then
    printf 'Linux uninstall did not stop the enabled tunnel service\n' >&2
    exit 1
fi

printf 'wgmesh Unix mock smoke: PASS\n'
