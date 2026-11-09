#!/bin/sh

# wgmesh: small WireGuard host/node helper for Linux and macOS.
# The script deliberately manages only resources that it records locally.

set -u
umask 077

SCRIPT_NAME=wgmesh.sh
VERSION=1
OS_NAME=$(uname -s 2>/dev/null || printf '%s' unknown)

case "$OS_NAME" in
    Linux)
        PLATFORM=linux
        DEFAULT_CONFIG_ROOT=/etc/wireguard
        DEFAULT_STATE_ROOT=/var/lib/wgmesh
        DEFAULT_LAUNCHD_ROOT=
        ;;
    Darwin)
        PLATFORM=macos
        DEFAULT_CONFIG_ROOT=/etc/wireguard
        DEFAULT_STATE_ROOT=/var/db/wgmesh
        DEFAULT_LAUNCHD_ROOT=/Library/LaunchDaemons
        ;;
    *)
        printf 'ERROR: unsupported platform: %s\n' "$OS_NAME" >&2
        exit 1
        ;;
esac

CONFIG_ROOT=${WGMESH_CONFIG_ROOT:-$DEFAULT_CONFIG_ROOT}
STATE_ROOT=${WGMESH_STATE_ROOT:-$DEFAULT_STATE_ROOT}
LAUNCHD_ROOT=${WGMESH_LAUNCHD_ROOT:-$DEFAULT_LAUNCHD_ROOT}

WG=${WGMESH_WG:-}
WG_QUICK=${WGMESH_WG_QUICK:-}
SYSTEMCTL=${WGMESH_SYSTEMCTL:-}
LAUNCHCTL=${WGMESH_LAUNCHCTL:-}
WIREGUARD_GO=${WGMESH_WIREGUARD_GO:-}
BREW=${WGMESH_BREW:-}
IP=${WGMESH_IP:-}
IFCONFIG=${WGMESH_IFCONFIG:-}
NETSTAT=${WGMESH_NETSTAT:-}

NETWORK=
NODE_ID=
TRANSPORT=
OVERLAY_CIDR=
ADDRESS=
ENDPOINT=
HUB_ENDPOINT=
HUB_PUBLIC_KEY=
NODE_PUBLIC_KEY=
NO_AUTOSTART=0
JSON_OUTPUT=0
SEEN_OPTIONS=
HOST_ADDRESS=

ROLE=
STATE_FILE=
NETWORK_DIR=
INTERFACE=
CONFIG_PATH=
PRIVATE_KEY_PATH=
SERVICE_PATH=
STATE_AUTOSTART=
PUBLIC_KEY=
LISTEN_PORT=
PEER_NODE_ID=
PEER_ADDRESS=
PEER_PUBLIC_KEY=

usage() {
    cat <<'EOF'
Usage:
  wgmesh.sh host init --network-name ID --node-id ID --transport tailscale|public
    --overlay-cidr CIDR --address CIDR --endpoint HOST:PORT [--no-autostart]
  wgmesh.sh node join --network-name ID --node-id ID --transport tailscale|public
    --overlay-cidr CIDR --address CIDR --hub-endpoint HOST:PORT
    --hub-public-key KEY [--no-autostart]
  wgmesh.sh host add-node --network-name ID --node-id ID --address CIDR
    --node-public-key KEY
  wgmesh.sh host remove-node --network-name ID --node-id ID
  wgmesh.sh node uninstall --network-name ID --node-id ID
  wgmesh.sh host uninstall --network-name ID
  wgmesh.sh status [--network-name ID] [--json]
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_value() {
    [ "$#" -ge 2 ] || die "missing value for $1"
    [ -n "$2" ] || die "empty value for $1"
    case "$2" in
        --*) die "missing value for $1" ;;
    esac
}

command_path() {
    if [ -n "$1" ]; then
        case "$1" in
            */*)
                [ -x "$1" ] || return 0
                printf '%s' "$1"
                ;;
            *)
                command -v "$1" 2>/dev/null || printf '%s' ''
                ;;
        esac
    else
        command -v "$2" 2>/dev/null || printf '%s' ''
    fi
}

require_privilege() {
    if [ "${WGMESH_TEST_MODE:-0}" = 1 ]; then
        return 0
    fi
    [ "$(id -u)" -eq 0 ] || die "administrator privileges are required"
}

install_linux_wireguard_tools() {
    package_manager=
    package_name=
    for candidate in apt-get dnf yum apk pacman; do
        package_manager=$(command_path '' "$candidate")
        [ -n "$package_manager" ] || continue
        package_name=$candidate
        break
    done
    [ -n "$package_manager" ] ||
        die "required WireGuard tools are missing and no supported package manager was found (tried apt-get, dnf, yum, apk, pacman)"
    printf 'Installing WireGuard tools with %s...\n' "$package_name" >&2
    case "$package_name" in
        apt-get|dnf|yum)
            "$package_manager" install -y wireguard-tools ||
                die "failed to install wireguard-tools with $package_name"
            ;;
        apk)
            "$package_manager" add --no-cache wireguard-tools ||
                die "failed to install wireguard-tools with apk"
            ;;
        pacman)
            "$package_manager" -S --noconfirm wireguard-tools ||
                die "failed to install wireguard-tools with pacman"
            ;;
    esac
}

install_macos_wireguard_tools() {
    BREW=$(command_path "$BREW" brew)
    if [ -z "$BREW" ]; then
        for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            if [ -x "$candidate" ]; then
                BREW=$candidate
                break
            fi
        done
    fi
    [ -n "$BREW" ] ||
        die "required WireGuard tools are missing and Homebrew is not installed; install Homebrew or install wireguard-tools and wireguard-go manually, then rerun"
    printf 'Installing WireGuard tools with Homebrew...\n' >&2
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        command_path '' sudo >/dev/null 2>&1 ||
            die "Homebrew cannot run as root; install the WireGuard tools as the login user, then rerun this command with sudo"
        sudo -u "$SUDO_USER" "$BREW" install wireguard-tools wireguard-go ||
            die "failed to install WireGuard tools with Homebrew"
    else
        "$BREW" install wireguard-tools wireguard-go ||
            die "failed to install WireGuard tools with Homebrew"
    fi
    brew_prefix=$("$BREW" --prefix 2>/dev/null || printf '%s' '')
    if [ -n "$brew_prefix" ] && [ -d "$brew_prefix/bin" ]; then
        PATH="$brew_prefix/bin:$PATH"
        export PATH
    fi
}

ensure_wireguard_tools() {
    missing=0
    [ -n "$WG" ] || missing=1
    [ -n "$WG_QUICK" ] || missing=1
    if [ "$PLATFORM" = macos ]; then
        [ -n "$WIREGUARD_GO" ] || missing=1
    fi
    [ "$missing" = 0 ] && return 0
    [ "${WGMESH_TEST_MODE:-0}" = 1 ] &&
        die "required WireGuard tools are missing in test mode"
    case "$PLATFORM" in
        linux)
            install_linux_wireguard_tools
            ;;
        macos)
            install_macos_wireguard_tools
            ;;
        *)
            die "unsupported platform for WireGuard tool installation: $PLATFORM"
            ;;
    esac
    WG=$(command_path "$WG" wg)
    WG_QUICK=$(command_path "$WG_QUICK" wg-quick)
    if [ "$PLATFORM" = macos ]; then
        WIREGUARD_GO=$(command_path "$WIREGUARD_GO" wireguard-go)
    fi
}

load_tools() {
    WG=$(command_path "$WG" wg)
    WG_QUICK=$(command_path "$WG_QUICK" wg-quick)
    if [ "$PLATFORM" = macos ]; then
        WIREGUARD_GO=$(command_path "$WIREGUARD_GO" wireguard-go)
    fi
    ensure_wireguard_tools
    [ -n "$WG" ] || die "required command not found: wg"
    [ -n "$WG_QUICK" ] || die "required command not found: wg-quick"

    if [ "$PLATFORM" = linux ]; then
        if [ "$1" = autostart ] ||
            { [ "$1" = uninstall ] && [ "$STATE_AUTOSTART" = 1 ]; }; then
            SYSTEMCTL=$(command_path "$SYSTEMCTL" systemctl)
            [ -n "$SYSTEMCTL" ] || die "required command not found: systemctl"
        fi
    else
        WIREGUARD_GO=$(command_path "$WIREGUARD_GO" wireguard-go)
        [ -n "$WIREGUARD_GO" ] || die "required command not found: wireguard-go"
        if [ "$1" = autostart ] ||
            { [ "$1" = uninstall ] && [ "$STATE_AUTOSTART" = 1 ]; }; then
            LAUNCHCTL=$(command_path "$LAUNCHCTL" launchctl)
            [ -n "$LAUNCHCTL" ] || die "required command not found: launchctl"
        fi
    fi
}

validate_id() {
    value=$1
    label=$2
    printf '%s\n' "$value" | awk '
        length($0) >= 1 && length($0) <= 48 &&
        $0 ~ /^[a-z0-9][a-z0-9_-]*$/ { exit 0 }
        { exit 1 }
    ' || die "$label must start with a lowercase letter or digit and contain only lowercase letters, digits, "_" or "-" (max 48 characters)"
}

validate_transport() {
    case "$1" in
        tailscale|public) ;;
        *) die "transport must be tailscale or public" ;;
    esac
}

validate_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || ($i + 0) > 255) {
                    exit 1
                }
            }
            exit 0
        }
    '
}

validate_cidr() {
    value=$1
    label=$2
    case "$value" in
        */*|*/*/*) ;;
        *) die "invalid $label: $value" ;;
    esac
    ip=${value%/*}
    prefix=${value#*/}
    [ -n "$ip" ] && [ -n "$prefix" ] || die "invalid $label: $value"
    validate_ipv4 "$ip" || die "invalid $label: $value"
    printf '%s\n' "$prefix" | awk '
        /^[0-9]+$/ && ($0 + 0) >= 1 && ($0 + 0) <= 32 { exit 0 }
        { exit 1 }
    ' || die "invalid $label prefix: $value"
}

cidr_contains() {
    overlay=$1
    address=$2
    overlay_ip=${overlay%/*}
    overlay_prefix=${overlay#*/}
    address_ip=${address%/*}
    awk -F. -v overlay="$overlay_ip" -v address="$address_ip" \
        -v prefix="$overlay_prefix" '
        function ip_number(value, parts, i, result) {
            split(value, parts, ".")
            result = 0
            for (i = 1; i <= 4; i++) {
                result = (result * 256) + (parts[i] + 0)
            }
            return result
        }
        BEGIN {
            overlay_number = ip_number(overlay)
            address_number = ip_number(address)
            block_size = 2 ^ (32 - prefix)
            network_start = int(overlay_number / block_size) * block_size
            if (address_number >= network_start &&
                address_number < network_start + block_size) {
                exit 0
            }
            exit 1
        }
    '
}

cidr_overlaps() {
    left=$1
    right=$2
    cidr_contains "$left" "${right%/*}" ||
        cidr_contains "$right" "${left%/*}"
}

check_overlay_lines() {
    requested_overlay=$1
    source_name=$2
    while IFS= read -r existing_cidr || [ -n "$existing_cidr" ]; do
        [ -n "$existing_cidr" ] || continue
        case "$existing_cidr" in
            */0) continue ;;
            */*) ;;
            *) continue ;;
        esac
        if cidr_overlaps "$requested_overlay" "$existing_cidr"; then
            die "overlay-cidr $requested_overlay overlaps existing $source_name $existing_cidr"
        fi
    done
}

check_wgmesh_state_overlay_conflicts() {
    requested_overlay=$1
    ignored_state=$2
    for state_file in "$STATE_ROOT"/*/*.state; do
        [ -f "$state_file" ] || continue
        [ "$state_file" = "$ignored_state" ] && continue
        existing_overlay=
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                overlay_cidr=*) existing_overlay=${line#*=} ;;
            esac
        done < "$state_file"
        [ -n "$existing_overlay" ] || continue
        validate_cidr "$existing_overlay" stored-overlay-cidr
        check_overlay_lines "$requested_overlay" "wgmesh network" <<EOF
$existing_overlay
EOF
    done
}

linux_route_cidrs() {
    awk '
        function is_cidr(value) {
            return value ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/
        }
        function is_ipv4(value) {
            return value ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/
        }
        {
            for (pos = 1; pos <= NF; pos++) {
                if (is_cidr($pos)) {
                    if ($pos !~ /\/0$/) print $pos
                    break
                }
                if (pos == 1 && is_ipv4($pos)) {
                    print $pos "/32"
                    break
                }
            }
        }
    '
}

macos_route_cidrs() {
    awk '
        function emit_destination(value, parts, count, pos, octet, address) {
            if (value == "default" || value == "0.0.0.0") return
            if (value ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) {
                if (value !~ /\/0$/) print value
                return
            }
            count = split(value, parts, ".")
            if (count < 1 || count > 4) return
            for (pos = 1; pos <= count; pos++) {
                if (parts[pos] !~ /^[0-9]+$/ || parts[pos] > 255) return
            }
            address = ""
            for (pos = 1; pos <= 4; pos++) {
                if (pos <= count) octet = parts[pos]
                else octet = 0
                address = address (pos == 1 ? "" : ".") octet
            }
            print address "/" (count * 8)
        }
        $1 != "Destination" { emit_destination($1) }
    '
}

macos_interface_cidrs() {
    awk '
        function hex_value(value) {
            return index("0123456789abcdef", tolower(value)) - 1
        }
        function mask_prefix(value, clean, pos, nibble, bits) {
            clean = tolower(value)
            sub(/^0x/, "", clean)
            if (length(clean) != 8) return -1
            bits = 0
            for (pos = 1; pos <= 8; pos++) {
                nibble = hex_value(substr(clean, pos, 1))
                if (nibble == 15) bits += 4
                else if (nibble == 14) bits += 3
                else if (nibble == 12) bits += 2
                else if (nibble == 8) bits += 1
                else if (nibble == 0) return bits
                else return -1
            }
            return bits
        }
        $1 == "inet" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
            prefix = mask_prefix($4)
            if (prefix >= 1) print $2 "/" prefix
        }
    '
}

check_system_overlay_conflicts() {
    requested_overlay=$1
    case "$PLATFORM" in
        linux)
            IP=$(command_path "$IP" ip)
            [ -n "$IP" ] ||
                die "required command not found: ip (needed to check overlay-cidr conflicts)"
            route_output=$("$IP" -4 route show 2>/dev/null) ||
                die "cannot inspect local IPv4 routes for overlay-cidr conflicts"
            address_output=$("$IP" -4 -o addr show 2>/dev/null) ||
                die "cannot inspect local IPv4 addresses for overlay-cidr conflicts"
            route_cidrs=$(printf '%s\n' "$route_output" | linux_route_cidrs) ||
                die "cannot parse local IPv4 routes for overlay-cidr conflicts"
            address_cidrs=$(printf '%s\n' "$address_output" |
                awk '$3 == "inet" { print $4 }') ||
                die "cannot parse local IPv4 addresses for overlay-cidr conflicts"
            check_overlay_lines "$requested_overlay" "local route" <<EOF
$route_cidrs
EOF
            check_overlay_lines "$requested_overlay" "local address" <<EOF
$address_cidrs
EOF
            ;;
        macos)
            IFCONFIG=$(command_path "$IFCONFIG" ifconfig)
            NETSTAT=$(command_path "$NETSTAT" netstat)
            [ -n "$IFCONFIG" ] ||
                die "required command not found: ifconfig (needed to check overlay-cidr conflicts)"
            [ -n "$NETSTAT" ] ||
                die "required command not found: netstat (needed to check overlay-cidr conflicts)"
            address_output=$("$IFCONFIG" -a 2>/dev/null) ||
                die "cannot inspect local IPv4 addresses for overlay-cidr conflicts"
            route_output=$("$NETSTAT" -rn -f inet 2>/dev/null) ||
                die "cannot inspect local IPv4 routes for overlay-cidr conflicts"
            route_cidrs=$(printf '%s\n' "$route_output" | macos_route_cidrs) ||
                die "cannot parse local IPv4 routes for overlay-cidr conflicts"
            address_cidrs=$(printf '%s\n' "$address_output" |
                macos_interface_cidrs) ||
                die "cannot parse local IPv4 addresses for overlay-cidr conflicts"
            check_overlay_lines "$requested_overlay" "local route" <<EOF
$route_cidrs
EOF
            check_overlay_lines "$requested_overlay" "local address" <<EOF
$address_cidrs
EOF
            ;;
        *)
            die "unsupported platform for overlay-cidr conflict checks: $PLATFORM"
            ;;
    esac
}

check_overlay_conflicts() {
    requested_overlay=$1
    ignored_state=$2
    check_wgmesh_state_overlay_conflicts "$requested_overlay" "$ignored_state"
    check_system_overlay_conflicts "$requested_overlay"
}

validate_address_in_overlay() {
    cidr_contains "$1" "$2" ||
        die "address $2 is outside overlay-cidr $1"
}

validate_key() {
    value=$1
    label=$2
    printf '%s\n' "$value" | awk '
        length($0) == 44 && $0 ~ /^[A-Za-z0-9+\/]{43}=$/ { exit 0 }
        { exit 1 }
    ' || die "invalid $label"
}

parse_endpoint() {
    value=$1
    ENDPOINT_HOST=
    ENDPOINT_PORT=
    case "$value" in
        \[*\]:*)
            ENDPOINT_HOST=${value#\[}
            ENDPOINT_HOST=${ENDPOINT_HOST%\]:*}
            ENDPOINT_PORT=${value##*:}
            ;;
        *:*)
            ENDPOINT_HOST=${value%:*}
            ENDPOINT_PORT=${value##*:}
            case "$ENDPOINT_HOST" in
                *:*) die "IPv6 endpoint must use [address]:port syntax" ;;
            esac
            ;;
        *) die "endpoint must be HOST:PORT" ;;
    esac
    [ -n "$ENDPOINT_HOST" ] || die "endpoint host is empty"
    case "$ENDPOINT_HOST" in
        *[!A-Za-z0-9._:-]*) die "endpoint host contains invalid characters" ;;
    esac
    printf '%s\n' "$ENDPOINT_PORT" | awk '
        /^[0-9]+$/ && ($0 + 0) >= 1 && ($0 + 0) <= 65535 { exit 0 }
        { exit 1 }
    ' || die "endpoint port must be 1-65535"
}

interface_for_network() {
    candidate=wgmesh-$1
    if [ "$(printf '%s' "$candidate" | awk '{print length($0)}')" -le 15 ]; then
        printf '%s' "$candidate"
    else
        printf '%s\n' "$1" | cksum | awk '{printf "wm-%s", $1}'
    fi
}

mark_option() {
    case " $SEEN_OPTIONS " in
        *" $1 "*)
            die "duplicate option: $1"
            ;;
    esac
    SEEN_OPTIONS="$SEEN_OPTIONS $1"
}

check_options() {
    allowed=" $1 "
    for option in $SEEN_OPTIONS; do
        case "$allowed" in
            *" $option "*) ;;
            *) die "option is not valid for this command: $option" ;;
        esac
    done
}

network_dir_for() {
    printf '%s/%s' "$STATE_ROOT" "$1"
}

state_path_for() {
    printf '%s/%s/%s.state' "$STATE_ROOT" "$1" "$2"
}

config_path_for() {
    printf '%s/%s.conf' "$CONFIG_ROOT" "$1"
}

private_key_path_for() {
    printf '%s/%s/private.key' "$STATE_ROOT" "$1"
}

service_path_for() {
    if [ "$PLATFORM" = macos ]; then
        printf '%s/com.wgmesh.%s.plist' "$LAUNCHD_ROOT" "$1"
    else
        printf '%s' ''
    fi
}

ensure_state_dirs() {
    for directory in "$STATE_ROOT" "$NETWORK_DIR" "$NETWORK_DIR/peers"; do
        if [ ! -d "$directory" ]; then
            mkdir -p -m 700 "$directory" || die "cannot create wgmesh state directory: $directory"
        fi
    done
    [ -d "$CONFIG_ROOT" ] || mkdir -p "$CONFIG_ROOT" ||
        die "cannot create WireGuard config directory"
}

atomic_write() {
    target=$1
    temp="${target}.tmp.$$"
    rm -f "$temp"
    if ! cat > "$temp"; then
        rm -f "$temp"
        return 1
    fi
    chmod 600 "$temp" 2>/dev/null || :
    if ! mv "$temp" "$target"; then
        rm -f "$temp"
        return 1
    fi
    return 0
}

load_state() {
    STATE_FILE=$1
    [ -f "$STATE_FILE" ] || return 1
    ROLE=
    NETWORK=
    NODE_ID=
    TRANSPORT=
    OVERLAY_CIDR=
    ADDRESS=
    ENDPOINT=
    HUB_ENDPOINT=
    HUB_PUBLIC_KEY=
    PUBLIC_KEY=
    INTERFACE=
    CONFIG_PATH=
    PRIVATE_KEY_PATH=
    SERVICE_PATH=
    STATE_AUTOSTART=
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *=*)
                key=${line%%=*}
                value=${line#*=}
                ;;
            *) continue ;;
        esac
        case "$key" in
            role) ROLE=$value ;;
            network) NETWORK=$value ;;
            node_id) NODE_ID=$value ;;
            transport) TRANSPORT=$value ;;
            overlay_cidr) OVERLAY_CIDR=$value ;;
            address) ADDRESS=$value ;;
            endpoint) ENDPOINT=$value ;;
            hub_endpoint) HUB_ENDPOINT=$value ;;
            hub_public_key) HUB_PUBLIC_KEY=$value ;;
            public_key) PUBLIC_KEY=$value ;;
            interface) INTERFACE=$value ;;
            config_path) CONFIG_PATH=$value ;;
            private_key_path) PRIVATE_KEY_PATH=$value ;;
            service_path) SERVICE_PATH=$value ;;
            autostart) STATE_AUTOSTART=$value ;;
            version) ;;
        esac
    done < "$STATE_FILE"
    [ -n "$ROLE" ] && [ -n "$NETWORK" ] && [ -n "$NODE_ID" ] &&
        [ -n "$INTERFACE" ] && [ -n "$CONFIG_PATH" ] || return 1
    return 0
}

load_peer_state() {
    peer_input=$1
    PEER_NODE_ID=
    PEER_ADDRESS=
    PEER_PUBLIC_KEY=
    [ -f "$peer_input" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            node_id=*) PEER_NODE_ID=${line#*=} ;;
            address=*) PEER_ADDRESS=${line#*=} ;;
            public_key=*) PEER_PUBLIC_KEY=${line#*=} ;;
        esac
    done < "$peer_input"
    [ -n "$PEER_NODE_ID" ] && [ -n "$PEER_ADDRESS" ] && [ -n "$PEER_PUBLIC_KEY" ]
}

read_private_key() {
    [ -n "$PRIVATE_KEY_PATH" ] && [ -f "$PRIVATE_KEY_PATH" ] ||
        die "private key file is missing"
    PRIVATE_KEY=$(cat "$PRIVATE_KEY_PATH") || die "cannot read private key"
    [ -n "$PRIVATE_KEY" ] || die "private key file is empty"
}

write_state() {
    target=$1
    role_value=$2
    state_tmp="${target}.tmp.$$"
    {
        printf 'version=%s\n' "$VERSION"
        printf 'role=%s\n' "$role_value"
        printf 'network=%s\n' "$NETWORK"
        printf 'node_id=%s\n' "$NODE_ID"
        printf 'transport=%s\n' "$TRANSPORT"
        printf 'overlay_cidr=%s\n' "$OVERLAY_CIDR"
        printf 'address=%s\n' "$ADDRESS"
        if [ "$role_value" = host ]; then
            printf 'endpoint=%s\n' "$ENDPOINT"
        else
            printf 'hub_endpoint=%s\n' "$HUB_ENDPOINT"
            printf 'hub_public_key=%s\n' "$HUB_PUBLIC_KEY"
        fi
        printf 'interface=%s\n' "$INTERFACE"
        printf 'config_path=%s\n' "$CONFIG_PATH"
        printf 'private_key_path=%s\n' "$PRIVATE_KEY_PATH"
        printf 'service_path=%s\n' "$SERVICE_PATH"
        printf 'autostart=%s\n' "$STATE_AUTOSTART"
        printf 'public_key=%s\n' "$PUBLIC_KEY"
    } | atomic_write "$target" || die "cannot write state file"
}

write_peer_state() {
    target=$1
    {
        printf 'node_id=%s\n' "$NODE_ID"
        printf 'address=%s\n' "$ADDRESS"
        printf 'public_key=%s\n' "$NODE_PUBLIC_KEY"
    } | atomic_write "$target" || return 1
}

write_host_config() {
    target=$1
    skip_node=$2
    read_private_key
    temp="${target}.tmp.$$"
    rm -f "$temp"
    {
        printf '# wgmesh-managed=true\n'
        printf '# wgmesh-network=%s\n' "$NETWORK"
        printf '[Interface]\n'
        printf 'PrivateKey = %s\n' "$PRIVATE_KEY"
        printf 'Address = %s\n' "${HOST_ADDRESS:-$ADDRESS}"
        printf 'ListenPort = %s\n' "$LISTEN_PORT"
        for peer_file in "$NETWORK_DIR"/peers/*.state; do
            [ -f "$peer_file" ] || continue
            load_peer_state "$peer_file" || return 1
            [ "$PEER_NODE_ID" = "$skip_node" ] && continue
            printf '\n[Peer]\n'
            printf 'PublicKey = %s\n' "$PEER_PUBLIC_KEY"
            printf 'AllowedIPs = %s\n' "$PEER_ADDRESS"
        done
    } > "$temp" || {
        rm -f "$temp"
        return 1
    }
    chmod 600 "$temp" 2>/dev/null || :
    mv "$temp" "$target" || {
        rm -f "$temp"
        return 1
    }
    return 0
}

write_node_config() {
    target=$1
    read_private_key
    {
        printf '# wgmesh-managed=true\n'
        printf '# wgmesh-network=%s\n' "$NETWORK"
        printf '[Interface]\n'
        printf 'PrivateKey = %s\n' "$PRIVATE_KEY"
        printf 'Address = %s\n' "$ADDRESS"
        printf '\n[Peer]\n'
        printf 'PublicKey = %s\n' "$HUB_PUBLIC_KEY"
        printf 'AllowedIPs = %s\n' "$OVERLAY_CIDR"
        printf 'Endpoint = %s\n' "$HUB_ENDPOINT"
        printf 'PersistentKeepalive = 25\n'
    } | atomic_write "$target" || return 1
    return 0
}

write_private_key() {
    target=$1
    printf '%s\n' "$PRIVATE_KEY" | atomic_write "$target" || return 1
    chmod 600 "$target" 2>/dev/null || :
    return 0
}

generate_keypair() {
    PRIVATE_KEY=$("$WG" genkey 2>/dev/null) || die "wg genkey failed"
    [ -n "$PRIVATE_KEY" ] || die "wg genkey returned an empty key"
    PUBLIC_KEY=$(printf '%s\n' "$PRIVATE_KEY" | "$WG" pubkey 2>/dev/null) ||
        die "wg pubkey failed"
    validate_key "$PUBLIC_KEY" public-key
}

interface_active() {
    "$WG" show "$INTERFACE" >/dev/null 2>&1
}

assert_managed_config() {
    target=$1
    [ -f "$target" ] || die "managed config is missing: $target"
    awk -v network="$NETWORK" '
        NR == 1 && $0 == "# wgmesh-managed=true" { managed = 1 }
        $0 == "# wgmesh-network=" network { matched_network = 1 }
        END { exit !(managed && matched_network) }
    ' "$target" || die "refusing to modify a config not marked as wgmesh-managed: $target"
}

bring_up() {
    "$WG_QUICK" up "$CONFIG_PATH" >/dev/null 2>&1 ||
        die "failed to bring up WireGuard interface $INTERFACE"
}

bring_down_if_active() {
    if interface_active; then
        "$WG_QUICK" down "$CONFIG_PATH" >/dev/null 2>&1 ||
            return 1
    fi
    return 0
}

create_launchd_plist() {
    target=$1
    temp="${target}.tmp.$$"
    quick_path=$WG_QUICK
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '<!-- wgmesh-managed=true network=%s interface=%s -->\n' "$NETWORK" "$INTERFACE"
        printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        printf '%s\n' '<plist version="1.0"><dict>'
        printf '%s\n' '<key>Label</key>'
        printf '<string>com.wgmesh.%s</string>\n' "$INTERFACE"
        printf '%s\n' '<key>ProgramArguments</key><array>'
        printf '<string>%s</string>\n' "$quick_path"
        printf '<string>up</string>\n'
        printf '<string>%s</string>\n' "$CONFIG_PATH"
        printf '%s\n' '</array><key>RunAtLoad</key><true/>'
        printf '%s\n' '</dict></plist>'
    } > "$temp" || {
        rm -f "$temp"
        return 1
    }
    chmod 600 "$temp" 2>/dev/null || :
    mv "$temp" "$target" || {
        rm -f "$temp"
        return 1
    }
}

assert_launchd_plist() {
    expected="<!-- wgmesh-managed=true network=$NETWORK interface=$INTERFACE -->"
    [ -f "$SERVICE_PATH" ] &&
        grep -Fqx "$expected" "$SERVICE_PATH" ||
        die "refusing to modify a LaunchDaemon not marked as wgmesh-managed: $SERVICE_PATH"
}

wait_for_interface() {
    attempt=0
    while [ "$attempt" -lt 20 ]; do
        interface_active && return 0
        sleep 0.25
        attempt=$((attempt + 1))
    done
    return 1
}

enable_autostart() {
    if [ "$PLATFORM" = linux ]; then
        "$SYSTEMCTL" enable "wg-quick@$INTERFACE.service" >/dev/null 2>&1 ||
            return 1
    else
        mkdir -p "$LAUNCHD_ROOT" || return 1
        create_launchd_plist "$SERVICE_PATH" || return 1
        "$LAUNCHCTL" enable "system/com.wgmesh.$INTERFACE" >/dev/null 2>&1 ||
            return 1
        if ! interface_active; then
            "$LAUNCHCTL" bootstrap system "$SERVICE_PATH" >/dev/null 2>&1 ||
                return 1
            wait_for_interface || return 1
        fi
    fi
    return 0
}

ensure_persistent_autostart() {
    if [ "$PLATFORM" = linux ]; then
        "$SYSTEMCTL" enable "wg-quick@$INTERFACE.service" >/dev/null 2>&1 ||
            return 1
    else
        mkdir -p "$LAUNCHD_ROOT" || return 1
        if [ -e "$SERVICE_PATH" ]; then
            assert_launchd_plist || return 1
        else
            create_launchd_plist "$SERVICE_PATH" || return 1
        fi
        "$LAUNCHCTL" enable "system/com.wgmesh.$INTERFACE" >/dev/null 2>&1 ||
            return 1
        if ! interface_active &&
            ! "$LAUNCHCTL" print "system/com.wgmesh.$INTERFACE" >/dev/null 2>&1; then
            "$LAUNCHCTL" bootstrap system "$SERVICE_PATH" >/dev/null 2>&1 ||
                return 1
            wait_for_interface || return 1
        fi
    fi
    return 0
}

restore_existing_install() {
    if [ "$STATE_AUTOSTART" = 1 ]; then
        ensure_persistent_autostart ||
            die "cannot restore autostart"
    fi
    if ! interface_active; then
        if [ "$PLATFORM" = linux ] && [ "$STATE_AUTOSTART" = 1 ]; then
            "$SYSTEMCTL" restart "wg-quick@$INTERFACE.service" >/dev/null 2>&1 ||
                die "cannot restore WireGuard interface $INTERFACE"
        else
            bring_up ||
                die "cannot restore WireGuard interface $INTERFACE"
        fi
    fi
}

disable_autostart() {
    if [ "$STATE_AUTOSTART" != 1 ]; then
        return 0
    fi
    if [ "$PLATFORM" = linux ]; then
        "$SYSTEMCTL" disable --now "wg-quick@$INTERFACE.service" >/dev/null 2>&1 || return 1
    else
        if [ -f "$SERVICE_PATH" ]; then
            assert_launchd_plist || return 1
            if "$LAUNCHCTL" print "system/com.wgmesh.$INTERFACE" >/dev/null 2>&1; then
                "$LAUNCHCTL" bootout system "$SERVICE_PATH" >/dev/null 2>&1 || return 1
            fi
        fi
        rm -f "$SERVICE_PATH" || return 1
    fi
    return 0
}

cleanup_new_install() {
    if [ "$STATE_AUTOSTART" = 1 ] && [ -n "$SERVICE_PATH" ]; then
        disable_autostart >/dev/null 2>&1 || :
    fi
    bring_down_if_active >/dev/null 2>&1 || :
    rm -f "$CONFIG_PATH" "$PRIVATE_KEY_PATH" "$STATE_FILE" "$SERVICE_PATH" 2>/dev/null || :
}

state_matches_host_init() {
    [ "$ROLE" = host ] &&
    [ "$NETWORK" = "$1" ] &&
    [ "$NODE_ID" = "$2" ] &&
    [ "$TRANSPORT" = "$3" ] &&
    [ "$OVERLAY_CIDR" = "$4" ] &&
    [ "$ADDRESS" = "$5" ] &&
    [ "$ENDPOINT" = "$6" ] &&
    [ "$STATE_AUTOSTART" = "$7" ]
}

state_matches_node_join() {
    [ "$ROLE" = node ] &&
    [ "$NETWORK" = "$1" ] &&
    [ "$NODE_ID" = "$2" ] &&
    [ "$TRANSPORT" = "$3" ] &&
    [ "$OVERLAY_CIDR" = "$4" ] &&
    [ "$ADDRESS" = "$5" ] &&
    [ "$HUB_ENDPOINT" = "$6" ] &&
    [ "$HUB_PUBLIC_KEY" = "$7" ] &&
    [ "$STATE_AUTOSTART" = "$8" ]
}

print_install_result() {
    printf 'network_id=%s\n' "$NETWORK"
    printf 'role=%s\n' "$ROLE"
    printf 'node_id=%s\n' "$NODE_ID"
    printf 'transport=%s\n' "$TRANSPORT"
    if [ "$ROLE" = host ]; then
        printf 'endpoint=%s\n' "$ENDPOINT"
        printf 'hub_public_key=%s\n' "$PUBLIC_KEY"
    else
        printf 'endpoint=%s\n' "$HUB_ENDPOINT"
        printf 'node_public_key=%s\n' "$PUBLIC_KEY"
    fi
    printf 'address=%s\n' "$ADDRESS"
    printf 'interface=%s\n' "$INTERFACE"
    if [ "$STATE_AUTOSTART" = 1 ]; then
        printf 'autostart=enabled\n'
    else
        printf 'autostart=disabled\n'
    fi
    printf 'state=CONFIGURED\n'
}

host_init() {
    requested_network=$NETWORK
    requested_node_id=$NODE_ID
    requested_transport=$TRANSPORT
    requested_overlay_cidr=$OVERLAY_CIDR
    requested_address=$ADDRESS
    requested_endpoint=$ENDPOINT
    require_privilege
    validate_id "$NETWORK" network
    validate_id "$NODE_ID" node-id
    validate_transport "$TRANSPORT"
    validate_cidr "$OVERLAY_CIDR" overlay-cidr
    validate_cidr "$ADDRESS" address
    validate_address_in_overlay "$OVERLAY_CIDR" "$ADDRESS"
    parse_endpoint "$ENDPOINT"
    load_tools "$([ "$NO_AUTOSTART" = 1 ] && printf noautostart || printf autostart)"

    INTERFACE=$(interface_for_network "$NETWORK")
    NETWORK_DIR=$(network_dir_for "$NETWORK")
    STATE_FILE=$(state_path_for "$NETWORK" host)
    CONFIG_PATH=$(config_path_for "$INTERFACE")
    PRIVATE_KEY_PATH=$(private_key_path_for "$NETWORK")
    SERVICE_PATH=$(service_path_for "$INTERFACE")
    HOST_ADDRESS=$ADDRESS
    STATE_AUTOSTART=1
    [ "$NO_AUTOSTART" = 1 ] && STATE_AUTOSTART=0
    requested_autostart=$STATE_AUTOSTART
    LISTEN_PORT=$ENDPOINT_PORT

    if [ -f "$STATE_FILE" ]; then
        load_state "$STATE_FILE" || die "host state is unreadable: $STATE_FILE"
        if state_matches_host_init "$requested_network" "$requested_node_id" \
            "$requested_transport" "$requested_overlay_cidr" \
            "$requested_address" "$requested_endpoint" "$requested_autostart"; then
            assert_managed_config "$CONFIG_PATH"
            restore_existing_install
            print_install_result
            printf 'result=NOOP\n'
            return 0
        fi
        die "host network already exists with different parameters"
    fi
    [ ! -e "$CONFIG_PATH" ] || die "refusing to overwrite existing config: $CONFIG_PATH"
    [ ! -e "$PRIVATE_KEY_PATH" ] || die "refusing to overwrite existing key: $PRIVATE_KEY_PATH"
    if [ "$PLATFORM" = macos ] && [ "$STATE_AUTOSTART" = 1 ] &&
        [ -e "$SERVICE_PATH" ]; then
        die "refusing to overwrite existing LaunchDaemon: $SERVICE_PATH"
    fi
    check_overlay_conflicts "$OVERLAY_CIDR" "$STATE_FILE"

    ensure_state_dirs
    generate_keypair
    write_private_key "$PRIVATE_KEY_PATH" || die "cannot save private key"
    write_host_config "$CONFIG_PATH" '' || {
        rm -f "$PRIVATE_KEY_PATH"
        die "cannot write host config"
    }
    bring_up || {
        rm -f "$CONFIG_PATH" "$PRIVATE_KEY_PATH"
        die "host initialization failed"
    }
    if [ "$STATE_AUTOSTART" = 1 ]; then
        enable_autostart || {
            cleanup_new_install
            die "cannot enable host autostart"
        }
    fi
    ROLE=host
    write_state "$STATE_FILE" host || {
        cleanup_new_install
        die "cannot save host state"
    }
    print_install_result
    printf 'result=CREATED\n'
}

node_join() {
    requested_network=$NETWORK
    requested_node_id=$NODE_ID
    requested_transport=$TRANSPORT
    requested_overlay_cidr=$OVERLAY_CIDR
    requested_address=$ADDRESS
    requested_hub_endpoint=$HUB_ENDPOINT
    requested_hub_public_key=$HUB_PUBLIC_KEY
    require_privilege
    validate_id "$NETWORK" network
    validate_id "$NODE_ID" node-id
    validate_transport "$TRANSPORT"
    validate_cidr "$OVERLAY_CIDR" overlay-cidr
    validate_cidr "$ADDRESS" address
    case "$ADDRESS" in
        */32) ;;
        *) die "node address must use /32" ;;
    esac
    validate_address_in_overlay "$OVERLAY_CIDR" "$ADDRESS"
    parse_endpoint "$HUB_ENDPOINT"
    validate_key "$HUB_PUBLIC_KEY" hub-public-key
    load_tools "$([ "$NO_AUTOSTART" = 1 ] && printf noautostart || printf autostart)"

    INTERFACE=$(interface_for_network "$NETWORK")
    NETWORK_DIR=$(network_dir_for "$NETWORK")
    STATE_FILE=$(state_path_for "$NETWORK" node)
    CONFIG_PATH=$(config_path_for "$INTERFACE")
    PRIVATE_KEY_PATH=$(private_key_path_for "$NETWORK")
    SERVICE_PATH=$(service_path_for "$INTERFACE")
    STATE_AUTOSTART=1
    [ "$NO_AUTOSTART" = 1 ] && STATE_AUTOSTART=0
    requested_autostart=$STATE_AUTOSTART

    if [ -f "$STATE_FILE" ]; then
        load_state "$STATE_FILE" || die "node state is unreadable: $STATE_FILE"
        if state_matches_node_join "$requested_network" "$requested_node_id" \
            "$requested_transport" "$requested_overlay_cidr" \
            "$requested_address" "$requested_hub_endpoint" "$requested_hub_public_key" \
            "$requested_autostart"; then
            assert_managed_config "$CONFIG_PATH"
            restore_existing_install
            print_install_result
            printf 'result=NOOP\n'
            return 0
        fi
        die "node network already exists with different parameters"
    fi
    [ ! -e "$CONFIG_PATH" ] || die "refusing to overwrite existing config: $CONFIG_PATH"
    [ ! -e "$PRIVATE_KEY_PATH" ] || die "refusing to overwrite existing key: $PRIVATE_KEY_PATH"
    if [ "$PLATFORM" = macos ] && [ "$STATE_AUTOSTART" = 1 ] &&
        [ -e "$SERVICE_PATH" ]; then
        die "refusing to overwrite existing LaunchDaemon: $SERVICE_PATH"
    fi
    check_overlay_conflicts "$OVERLAY_CIDR" "$STATE_FILE"

    ensure_state_dirs
    generate_keypair
    write_private_key "$PRIVATE_KEY_PATH" || die "cannot save private key"
    write_node_config "$CONFIG_PATH" || {
        rm -f "$PRIVATE_KEY_PATH"
        die "cannot write node config"
    }
    bring_up || {
        rm -f "$CONFIG_PATH" "$PRIVATE_KEY_PATH"
        die "node join failed"
    }
    if [ "$STATE_AUTOSTART" = 1 ]; then
        enable_autostart || {
            cleanup_new_install
            die "cannot enable node autostart"
        }
    fi
    ROLE=node
    write_state "$STATE_FILE" node || {
        cleanup_new_install
        die "cannot save node state"
    }
    print_install_result
    printf 'result=CREATED\n'
}

load_host_or_die() {
    STATE_FILE=$(state_path_for "$NETWORK" host)
    load_state "$STATE_FILE" || die "host network is not initialized: $NETWORK"
    [ "$ROLE" = host ] || die "state is not a host network"
    CONFIG_PATH=${CONFIG_PATH:-$(config_path_for "$INTERFACE")}
    NETWORK_DIR=$(network_dir_for "$NETWORK")
    PRIVATE_KEY_PATH=${PRIVATE_KEY_PATH:-$(private_key_path_for "$NETWORK")}
    SERVICE_PATH=${SERVICE_PATH:-$(service_path_for "$INTERFACE")}
    HOST_ADDRESS=$ADDRESS
    assert_managed_config "$CONFIG_PATH"
}

host_add_node() {
    requested_network=$NETWORK
    requested_node_id=$NODE_ID
    requested_address=$ADDRESS
    requested_node_public_key=$NODE_PUBLIC_KEY
    require_privilege
    validate_id "$requested_network" network
    validate_id "$requested_node_id" node-id
    validate_cidr "$requested_address" address
    case "$requested_address" in
        */32) ;;
        *) die "node address must use /32" ;;
    esac
    validate_key "$requested_node_public_key" node-public-key
    load_host_or_die
    NETWORK=$requested_network
    NODE_ID=$requested_node_id
    ADDRESS=$requested_address
    NODE_PUBLIC_KEY=$requested_node_public_key
    validate_address_in_overlay "$OVERLAY_CIDR" "$ADDRESS"
    load_tools noautostart

    peer_file="$NETWORK_DIR/peers/$NODE_ID.state"
    if [ -f "$peer_file" ]; then
        load_peer_state "$peer_file" || die "peer state is unreadable: $peer_file"
        if [ "$PEER_ADDRESS" = "$ADDRESS" ] &&
            [ "$PEER_PUBLIC_KEY" = "$NODE_PUBLIC_KEY" ]; then
            printf 'network_id=%s\nnode_id=%s\npeer=committed\nallowed_ips=%s\nstate=CONFIGURED\nresult=NOOP\n' \
                "$NETWORK" "$NODE_ID" "$ADDRESS"
            return 0
        fi
        die "peer already exists with different address or public key"
    fi

    requested_peer_ip=${ADDRESS%/*}
    [ "$requested_peer_ip" != "${HOST_ADDRESS%/*}" ] ||
        die "peer address conflicts with host address: $ADDRESS"
    [ "$NODE_PUBLIC_KEY" != "$PUBLIC_KEY" ] ||
        die "peer public key conflicts with host public key"
    for existing_peer_file in "$NETWORK_DIR"/peers/*.state; do
        [ -f "$existing_peer_file" ] || continue
        load_peer_state "$existing_peer_file" || die "peer state is unreadable: $existing_peer_file"
        existing_peer_ip=${PEER_ADDRESS%/*}
        if [ "$existing_peer_ip" = "$requested_peer_ip" ]; then
            die "peer address is already registered: $ADDRESS"
        fi
        if [ "$PEER_PUBLIC_KEY" = "$NODE_PUBLIC_KEY" ]; then
            die "peer public key is already registered"
        fi
    done

    ensure_state_dirs
    peer_tmp="${peer_file}.tmp.$$"
    {
        printf 'node_id=%s\n' "$NODE_ID"
        printf 'address=%s\n' "$ADDRESS"
        printf 'public_key=%s\n' "$NODE_PUBLIC_KEY"
    } | atomic_write "$peer_tmp" || die "cannot prepare peer state"
    temp_config="${CONFIG_PATH}.tmp.$$"
    if ! mv "$peer_tmp" "$peer_file"; then
        rm -f "$peer_tmp"
        die "cannot save peer state"
    fi
    if ! write_host_config "$temp_config" ''; then
        rm -f "$peer_file" "$temp_config"
        die "cannot build host config"
    fi
    live_added=0
    if interface_active; then
        if ! "$WG" set "$INTERFACE" peer "$NODE_PUBLIC_KEY" allowed-ips "$ADDRESS" >/dev/null 2>&1; then
            rm -f "$peer_file" "$temp_config"
            die "cannot add peer to active interface"
        fi
        live_added=1
    fi
    if ! mv "$temp_config" "$CONFIG_PATH"; then
        if [ "$live_added" = 1 ]; then
            "$WG" set "$INTERFACE" peer "$NODE_PUBLIC_KEY" remove >/dev/null 2>&1 || :
        fi
        rm -f "$peer_file" "$temp_config"
        die "cannot commit host config"
    fi
    printf 'network_id=%s\nnode_id=%s\npeer=committed\nallowed_ips=%s\nstate=CONFIGURED\nresult=CREATED\n' \
        "$NETWORK" "$NODE_ID" "$ADDRESS"
}

host_remove_node() {
    requested_network=$NETWORK
    requested_node_id=$NODE_ID
    require_privilege
    validate_id "$requested_network" network
    validate_id "$requested_node_id" node-id
    load_host_or_die
    NETWORK=$requested_network
    NODE_ID=$requested_node_id
    load_tools noautostart
    peer_file="$NETWORK_DIR/peers/$NODE_ID.state"
    [ -f "$peer_file" ] || {
        printf 'network_id=%s\nnode_id=%s\npeer_revoked=none\nstate=CONFIGURED\nresult=NOOP\n' \
            "$NETWORK" "$NODE_ID"
        return 0
    }
    load_peer_state "$peer_file" || die "peer state is unreadable: $peer_file"
    peer_tmp="${peer_file}.removing.$$"
    mv "$peer_file" "$peer_tmp" || die "cannot prepare peer removal"

    temp_config="${CONFIG_PATH}.tmp.$$"
    if ! write_host_config "$temp_config" ''; then
        mv "$peer_tmp" "$peer_file" 2>/dev/null || :
        rm -f "$temp_config"
        die "cannot build host config"
    fi
    live_removed=0
    if interface_active; then
        if ! "$WG" set "$INTERFACE" peer "$PEER_PUBLIC_KEY" remove >/dev/null 2>&1; then
            mv "$peer_tmp" "$peer_file" 2>/dev/null || :
            rm -f "$temp_config"
            die "cannot remove peer from active interface"
        fi
        live_removed=1
    fi
    if ! mv "$temp_config" "$CONFIG_PATH"; then
        if [ "$live_removed" = 1 ]; then
            "$WG" set "$INTERFACE" peer "$PEER_PUBLIC_KEY" \
                allowed-ips "$PEER_ADDRESS" >/dev/null 2>&1 || :
        fi
        mv "$peer_tmp" "$peer_file" 2>/dev/null || :
        rm -f "$temp_config"
        die "cannot commit host config"
    fi
    rm -f "$peer_tmp" 2>/dev/null || :
    printf 'network_id=%s\nnode_id=%s\npeer_revoked=done\nstate=CONFIGURED\nresult=REMOVED\n' \
        "$NETWORK" "$NODE_ID"
}

uninstall_state() {
    role_value=$1
    requested_node_id=$NODE_ID
    require_privilege
    validate_id "$NETWORK" network
    if [ "$role_value" = host ]; then
        STATE_FILE=$(state_path_for "$NETWORK" host)
    else
        STATE_FILE=$(state_path_for "$NETWORK" node)
    fi
    [ -f "$STATE_FILE" ] || {
        printf 'network_id=%s\nrole=%s\nstate=ABSENT\nresult=NOOP\n' "$NETWORK" "$role_value"
        return 0
    }
    load_state "$STATE_FILE" || die "state is unreadable: $STATE_FILE"
    [ "$ROLE" = "$role_value" ] || die "state role does not match requested uninstall"
    if [ "$role_value" = node ] && [ "$NODE_ID" != "$requested_node_id" ]; then
        die "node-id does not match the installed node"
    fi
    NETWORK_DIR=$(network_dir_for "$NETWORK")
    CONFIG_PATH=${CONFIG_PATH:-$(config_path_for "$INTERFACE")}
    PRIVATE_KEY_PATH=${PRIVATE_KEY_PATH:-$(private_key_path_for "$NETWORK")}
    SERVICE_PATH=${SERVICE_PATH:-$(service_path_for "$INTERFACE")}
    assert_managed_config "$CONFIG_PATH"
    load_tools uninstall
    if [ "$STATE_AUTOSTART" = 1 ]; then
        disable_autostart || die "cannot disable autostart"
    fi
    bring_down_if_active || die "cannot bring down WireGuard interface"
    rm -f "$CONFIG_PATH" "$PRIVATE_KEY_PATH" || die "cannot remove wgmesh files"
    if [ "$role_value" = host ]; then
        rm -f "$NETWORK_DIR"/peers/*.state 2>/dev/null || :
    fi
    rm -f "$STATE_FILE" || die "cannot remove state file"
    rmdir "$NETWORK_DIR/peers" "$NETWORK_DIR" 2>/dev/null || :
    printf 'network_id=%s\nrole=%s\ninterface_removed=true\nautostart_removed=true\nstate=ABSENT\nresult=REMOVED\n' \
        "$NETWORK" "$role_value"
}

state_is_active() {
    INTERFACE=$1
    if [ -n "$WG" ] && interface_active; then
        printf ACTIVE
    else
        printf CONFIGURED
    fi
}

latest_handshake() {
    "$WG" show "$1" latest-handshakes 2>/dev/null |
        awk '$2 ~ /^[0-9]+$/ && $2 > latest { latest = $2 }
             END { if (latest > 0) print latest }'
}

json_quote() {
    printf '%s' "$1" | awk '
        {
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            printf "\"%s\"", $0
        }
    '
}

count_peers() {
    count=0
    for peer_file in "$NETWORK_DIR"/peers/*.state; do
        [ -f "$peer_file" ] || continue
        count=$((count + 1))
    done
    printf '%s' "$count"
}

print_status_one() {
    state_file=$1
    load_state "$state_file" || return 1
    NETWORK_DIR=$(network_dir_for "$NETWORK")
    PRIVATE_KEY_PATH=${PRIVATE_KEY_PATH:-$(private_key_path_for "$NETWORK")}
    if [ -z "$WG" ]; then
        WG=$(command_path "$WG" wg)
    fi
    [ -n "$WG" ] || die "required command not found: wg"
    current_state=$(state_is_active "$INTERFACE")
    handshake=$(latest_handshake "$INTERFACE")
    if [ "$JSON_OUTPUT" = 1 ]; then
        if [ "$ROLE" = host ]; then
            printf '{'
            printf '"network_id":%s,' "$(json_quote "$NETWORK")"
            printf '"role":"host",'
            printf '"node_id":%s,' "$(json_quote "$NODE_ID")"
            printf '"transport":%s,' "$(json_quote "$TRANSPORT")"
            printf '"interface":%s,' "$(json_quote "$INTERFACE")"
            printf '"address":%s,' "$(json_quote "$ADDRESS")"
            printf '"autostart":%s,' "$([ "$STATE_AUTOSTART" = 1 ] && printf true || printf false)"
            printf '"state":%s,' "$(json_quote "$current_state")"
            printf '"handshake":%s,' "${handshake:-null}"
            printf '"hub_public_key":%s,' "$(json_quote "$PUBLIC_KEY")"
            printf '"peer_count":%s' "$(count_peers)"
            printf '}\n'
        else
            printf '{'
            printf '"network_id":%s,' "$(json_quote "$NETWORK")"
            printf '"role":"node",'
            printf '"node_id":%s,' "$(json_quote "$NODE_ID")"
            printf '"transport":%s,' "$(json_quote "$TRANSPORT")"
            printf '"interface":%s,' "$(json_quote "$INTERFACE")"
            printf '"address":%s,' "$(json_quote "$ADDRESS")"
            printf '"autostart":%s,' "$([ "$STATE_AUTOSTART" = 1 ] && printf true || printf false)"
            printf '"state":%s,' "$(json_quote "$current_state")"
            printf '"handshake":%s,' "${handshake:-null}"
            printf '"node_public_key":%s,' "$(json_quote "$PUBLIC_KEY")"
            printf '"hub_public_key":%s' "$(json_quote "$HUB_PUBLIC_KEY")"
            printf '}\n'
        fi
    else
        printf 'network_id=%s\n' "$NETWORK"
        printf 'role=%s\n' "$ROLE"
        printf 'node_id=%s\n' "$NODE_ID"
        printf 'transport=%s\n' "$TRANSPORT"
        printf 'interface=%s\n' "$INTERFACE"
        printf 'address=%s\n' "$ADDRESS"
        printf 'autostart=%s\n' "$([ "$STATE_AUTOSTART" = 1 ] && printf enabled || printf disabled)"
        printf 'state=%s\n' "$current_state"
        printf 'handshake=%s\n' "${handshake:-none}"
        if [ "$ROLE" = host ]; then
            printf 'hub_public_key=%s\n' "$PUBLIC_KEY"
            printf 'peer_count=%s\n' "$(count_peers)"
        else
            printf 'node_public_key=%s\n' "$PUBLIC_KEY"
            printf 'hub_public_key=%s\n' "$HUB_PUBLIC_KEY"
        fi
    fi
    return 0
}

status_command() {
    if [ -n "$NETWORK" ]; then
        validate_id "$NETWORK" network
        host_state=$(state_path_for "$NETWORK" host)
        node_state=$(state_path_for "$NETWORK" node)
        if [ -f "$host_state" ]; then
            print_status_one "$host_state" || die "cannot read host state"
            return 0
        fi
        if [ -f "$node_state" ]; then
            print_status_one "$node_state" || die "cannot read node state"
            return 0
        fi
        die "network state not found: $NETWORK"
    fi

    first=1
    if [ "$JSON_OUTPUT" = 1 ]; then
        printf '['
    fi
    for candidate in "$STATE_ROOT"/*/host.state "$STATE_ROOT"/*/node.state; do
        [ -f "$candidate" ] || continue
        if [ "$JSON_OUTPUT" = 1 ]; then
            [ "$first" = 1 ] || printf ','
            first=0
            print_status_one "$candidate" || die "cannot read state: $candidate"
        else
            [ "$first" = 1 ] || printf '\n'
            first=0
            print_status_one "$candidate" || die "cannot read state: $candidate"
        fi
    done
    if [ "$JSON_OUTPUT" = 1 ]; then
        printf ']\n'
    elif [ "$first" = 1 ]; then
        printf 'state=ABSENT\n'
    fi
}

parse_options() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --network-name)
                mark_option --network-name
                need_value "$@"
                NETWORK=$2
                shift 2
                ;;
            --node-id)
                mark_option "$1"
                need_value "$@"
                NODE_ID=$2
                shift 2
                ;;
            --transport)
                mark_option "$1"
                need_value "$@"
                TRANSPORT=$2
                shift 2
                ;;
            --overlay-cidr)
                mark_option "$1"
                need_value "$@"
                OVERLAY_CIDR=$2
                shift 2
                ;;
            --address)
                mark_option "$1"
                need_value "$@"
                ADDRESS=$2
                shift 2
                ;;
            --endpoint)
                mark_option "$1"
                need_value "$@"
                ENDPOINT=$2
                shift 2
                ;;
            --hub-endpoint)
                mark_option "$1"
                need_value "$@"
                HUB_ENDPOINT=$2
                shift 2
                ;;
            --hub-public-key)
                mark_option "$1"
                need_value "$@"
                HUB_PUBLIC_KEY=$2
                shift 2
                ;;
            --node-public-key)
                mark_option "$1"
                need_value "$@"
                NODE_PUBLIC_KEY=$2
                shift 2
                ;;
            --no-autostart)
                mark_option "$1"
                NO_AUTOSTART=1
                shift
                ;;
            --json)
                mark_option "$1"
                JSON_OUTPUT=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            --*)
                die "unknown option: $1"
                ;;
            *)
                die "unexpected argument: $1"
                ;;
        esac
    done
}

require_option() {
    [ -n "$1" ] || die "missing required option: $2"
}

if [ "$#" -lt 1 ]; then
    usage >&2
    exit 2
fi

COMMAND=$1
shift
SUBCOMMAND=
case "$COMMAND" in
    host|node)
        [ "$#" -gt 0 ] || die "missing subcommand for $COMMAND"
        SUBCOMMAND=$1
        shift
        ;;
    status)
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        die "unknown command: $COMMAND"
        ;;
esac

parse_options "$@"

case "$COMMAND:$SUBCOMMAND" in
    host:init)
        check_options "--network-name --node-id --transport --overlay-cidr --address --endpoint --no-autostart"
        require_option "$NETWORK" --network-name
        require_option "$NODE_ID" --node-id
        require_option "$TRANSPORT" --transport
        require_option "$OVERLAY_CIDR" --overlay-cidr
        require_option "$ADDRESS" --address
        require_option "$ENDPOINT" --endpoint
        [ "$JSON_OUTPUT" = 0 ] || die "--json is only valid for status"
        host_init
        ;;
    node:join)
        check_options "--network-name --node-id --transport --overlay-cidr --address --hub-endpoint --hub-public-key --no-autostart"
        require_option "$NETWORK" --network-name
        require_option "$NODE_ID" --node-id
        require_option "$TRANSPORT" --transport
        require_option "$OVERLAY_CIDR" --overlay-cidr
        require_option "$ADDRESS" --address
        require_option "$HUB_ENDPOINT" --hub-endpoint
        require_option "$HUB_PUBLIC_KEY" --hub-public-key
        [ "$JSON_OUTPUT" = 0 ] || die "--json is only valid for status"
        node_join
        ;;
    host:add-node)
        check_options "--network-name --node-id --address --node-public-key"
        require_option "$NETWORK" --network-name
        require_option "$NODE_ID" --node-id
        require_option "$ADDRESS" --address
        require_option "$NODE_PUBLIC_KEY" --node-public-key
        [ "$JSON_OUTPUT" = 0 ] || die "--json is only valid for status"
        [ "$NO_AUTOSTART" = 0 ] || die "--no-autostart is not valid for host add-node"
        host_add_node
        ;;
    host:remove-node)
        check_options "--network-name --node-id"
        require_option "$NETWORK" --network-name
        require_option "$NODE_ID" --node-id
        [ "$JSON_OUTPUT" = 0 ] || die "--json is only valid for status"
        [ "$NO_AUTOSTART" = 0 ] || die "--no-autostart is not valid for host remove-node"
        host_remove_node
        ;;
    node:uninstall)
        check_options "--network-name --node-id"
        require_option "$NETWORK" --network-name
        require_option "$NODE_ID" --node-id
        [ "$JSON_OUTPUT" = 0 ] || die "--json is only valid for status"
        [ "$NO_AUTOSTART" = 0 ] || die "--no-autostart is not valid for node uninstall"
        uninstall_state node
        ;;
    host:uninstall)
        check_options "--network-name"
        require_option "$NETWORK" --network-name
        [ "$JSON_OUTPUT" = 0 ] || die "--json is only valid for status"
        [ -z "$NODE_ID" ] || die "--node-id is not valid for host uninstall"
        [ "$NO_AUTOSTART" = 0 ] || die "--no-autostart is not valid for host uninstall"
        uninstall_state host
        ;;
    status:)
        check_options "--network-name --json"
        [ "$NO_AUTOSTART" = 0 ] || die "--no-autostart is not valid for status"
        status_command
        ;;
    *)
        die "unknown command or subcommand: $COMMAND $SUBCOMMAND"
        ;;
esac
