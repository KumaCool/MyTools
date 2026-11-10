#!/bin/sh

# wgmesh: small WireGuard host/node helper for Linux and macOS.
# The script deliberately manages only resources that it records locally.

set -u
umask 077

SCRIPT_NAME=wgmesh.sh
VERSION=2
OS_NAME=$(uname -s 2>/dev/null || printf '%s' unknown)
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)

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
WIREGUARD_RUNTIME_ROOT=${WGMESH_WIREGUARD_RUNTIME_ROOT:-/var/run/wireguard}

WG=${WGMESH_WG:-}
WG_QUICK=${WGMESH_WG_QUICK:-}
SYSTEMCTL=${WGMESH_SYSTEMCTL:-}
LAUNCHCTL=${WGMESH_LAUNCHCTL:-}
WIREGUARD_GO=${WGMESH_WIREGUARD_GO:-}
BREW=${WGMESH_BREW:-}
IP=${WGMESH_IP:-}
IFCONFIG=${WGMESH_IFCONFIG:-}
NETSTAT=${WGMESH_NETSTAT:-}
SYSCTL=${WGMESH_SYSCTL:-}
ROUTE=${WGMESH_ROUTE:-}

NETWORK=
NODE_ID=
TRANSPORT=
OVERLAY_CIDR=
ADDRESS=
ENDPOINT=
HUB_ENDPOINT=
HUB_PUBLIC_KEY=
NODE_PUBLIC_KEY=
MTU=
FIREWALL_MODE=external
FIREWALL_OPTION_SET=0
FIREWALL_CHECK=NOT_CHECKED
PEER_ADDRESSES=
NO_AUTOSTART=0
JSON_OUTPUT=0
SEEN_OPTIONS=
HOST_ADDRESS=
HOST_FORWARDING_KEY=

ROLE=
STATE_FILE=
NETWORK_DIR=
INTERFACE=
CONFIG_PATH=
PRIVATE_KEY_PATH=
SERVICE_PATH=
STATE_AUTOSTART=
STATE_SCHEMA_VERSION=
STATE_NEEDS_MIGRATION=0
PUBLIC_KEY=
LISTEN_PORT=
PEER_NODE_ID=
PEER_ADDRESS=
PEER_PUBLIC_KEY=
PEER_ROUTES=

usage() {
    cat <<'EOF'
Usage:
  wgmesh.sh host init --network-name ID --node-id ID --transport tailscale|public
    --overlay-cidr CIDR --address CIDR --endpoint HOST:PORT
    [--mtu BYTES] [--forward-firewall external|managed] [--no-autostart]
  wgmesh.sh node join --network-name ID --node-id ID --transport tailscale|public
    --overlay-cidr CIDR --address CIDR --hub-endpoint HOST:PORT
    --hub-public-key KEY [--mtu BYTES] [--no-autostart]
  wgmesh.sh host add-node --network-name ID --node-id ID --address CIDR
    --node-public-key KEY [--peer-address IPv4/32 ...]
  wgmesh.sh host set-routes --network-name ID --node-id ID [--peer-address IPv4/32 ...]
  wgmesh.sh node set-routes --network-name ID [--peer-address IPv4/32 ...]
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

if [ "$PLATFORM" = linux ] || [ "$PLATFORM" = macos ]; then
    [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR" ] ||
        die "cannot determine the wgmesh script directory"
    [ -f "$SCRIPT_DIR/firewall-unix.sh" ] &&
        [ -r "$SCRIPT_DIR/firewall-unix.sh" ] ||
        die "wgmesh firewall helper is missing or unreadable: $SCRIPT_DIR/firewall-unix.sh"
    # The helper only defines functions; it never changes firewall state while
    # being sourced. Windows uses the PowerShell implementation and does not
    # load this file.
    . "$SCRIPT_DIR/firewall-unix.sh" ||
        die "cannot load wgmesh firewall helper: $SCRIPT_DIR/firewall-unix.sh"
fi

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
    [ "$(id -u)" -eq 0 ] ||
        die "administrator privileges are required; rerun this command with sudo"
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
    if [ "$(id -u)" -eq 0 ]; then
        [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] ||
            die "Homebrew cannot run as root; install WireGuard tools as the login user, then rerun this command with sudo"
        command_path '' sudo >/dev/null 2>&1 ||
            die "Homebrew cannot run as root; install the WireGuard tools as the login user, then rerun this command with sudo"
        sudo -u "$SUDO_USER" "$BREW" install wireguard-tools wireguard-go ||
            die "failed to install WireGuard tools with Homebrew as user $SUDO_USER"
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

load_host_forwarding_tool() {
    case "$PLATFORM" in
        linux)
            HOST_FORWARDING_KEY=net.ipv4.ip_forward
            ;;
        macos)
            HOST_FORWARDING_KEY=net.inet.ip.forwarding
            ;;
        *)
            die "unsupported platform for Hub forwarding: $PLATFORM"
            ;;
    esac
    SYSCTL=$(command_path "$SYSCTL" sysctl)
    [ -n "$SYSCTL" ] ||
        die "required command not found: sysctl (needed for Hub overlay forwarding)"
}

ensure_host_forwarding() {
    [ -n "$SYSCTL" ] && [ -n "$HOST_FORWARDING_KEY" ] ||
        load_host_forwarding_tool
    forwarding_value=$("$SYSCTL" -n "$HOST_FORWARDING_KEY" 2>/dev/null) || forwarding_value=
    if [ "$forwarding_value" != 1 ]; then
        "$SYSCTL" -w "$HOST_FORWARDING_KEY=1" >/dev/null 2>&1 ||
            return 1
        forwarding_value=$("$SYSCTL" -n "$HOST_FORWARDING_KEY" 2>/dev/null) ||
            return 1
    fi
    [ "$forwarding_value" = 1 ]
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

validate_firewall_mode() {
    case "$1" in
        external|managed) ;;
        *) die "forward-firewall must be external or managed" ;;
    esac
}

firewall_peer_addresses_csv() {
    firewall_lines=
    for firewall_peer_file in "$NETWORK_DIR"/peers/*.state; do
        [ -f "$firewall_peer_file" ] || continue
        awk -F= '
            $1 == "address" { print $2 }
            $1 == "peer_addresses" && $2 != "" {
                count = split($2, values, ",")
                for (i = 1; i <= count; i++) print values[i]
            }
        ' "$firewall_peer_file"
    done | awk 'NF && !seen[$0]++ { print }' | paste -sd, -
}

firewall_preflight() {
    firewall_mode=$1
    [ "$firewall_mode" = managed ] || return 0
    case "$PLATFORM" in
        linux|macos)
            type wgmesh_firewall_preflight >/dev/null 2>&1 ||
                die "managed forwarding firewall is unavailable on this platform"
            wgmesh_firewall_preflight "$PLATFORM" "$NETWORK" "$INTERFACE" \
                "$OVERLAY_CIDR" managed || die "managed forwarding firewall preflight failed"
            ;;
        *)
            die "managed forwarding firewall is unsupported on this platform"
            ;;
    esac
}

firewall_sync() {
    [ "$FIREWALL_MODE" = managed ] || {
        FIREWALL_CHECK=EXTERNAL
        return 0
    }
    case "$PLATFORM" in
        linux|macos)
            firewall_peer_csv=$(firewall_peer_addresses_csv)
            wgmesh_firewall_sync "$PLATFORM" "$NETWORK" "$INTERFACE" \
                "$OVERLAY_CIDR" "$firewall_peer_csv" ||
                return 1
            FIREWALL_CHECK=OK
            ;;
        *) return 1 ;;
    esac
}

firewall_install() {
    [ "$FIREWALL_MODE" = managed ] || {
        FIREWALL_CHECK=EXTERNAL
        return 0
    }
    firewall_preflight managed
    firewall_peer_csv=$(firewall_peer_addresses_csv)
    wgmesh_firewall_install "$PLATFORM" "$NETWORK" "$INTERFACE" \
        "$OVERLAY_CIDR" "$firewall_peer_csv" || return 1
    FIREWALL_CHECK=OK
}

firewall_remove() {
    [ "$FIREWALL_MODE" = managed ] || {
        FIREWALL_CHECK=EXTERNAL
        return 0
    }
    case "$PLATFORM" in
        linux|macos)
            wgmesh_firewall_remove "$PLATFORM" "$NETWORK" || return 1
            FIREWALL_CHECK=EXTERNAL
            ;;
        *) return 1 ;;
    esac
}

firewall_status() {
    if [ "$FIREWALL_MODE" != managed ]; then
        FIREWALL_CHECK=NOT_CHECKED
        return 0
    fi
    case "$PLATFORM" in
        linux|macos)
            FIREWALL_CHECK=$(wgmesh_firewall_status "$PLATFORM" "$NETWORK" "$INTERFACE" 2>/dev/null || printf DRIFT)
            ;;
        *) FIREWALL_CHECK=UNSUPPORTED ;;
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

validate_mtu() {
    value=$1
    [ -n "$value" ] || die "mtu must be a decimal integer"
    printf '%s\n' "$value" | awk '/^[0-9]+$/ && ($0 + 0) >= 576 && ($0 + 0) <= 65535 { exit 0 } { exit 1 }' ||
        die "mtu must be an integer from 576 to 65535"
}

normalize_peer_addresses() {
    # PEER_ADDRESSES is newline-delimited; return sorted unique /32 values.
    printf '%s\n' "$PEER_ADDRESSES" | awk 'NF { print }' | sort -u
}

peer_addresses_csv() {
    normalize_peer_addresses | paste -sd, -
}

append_peer_address() {
    if [ -n "$PEER_ADDRESSES" ]; then
        PEER_ADDRESSES="$PEER_ADDRESSES
$1"
    else
        PEER_ADDRESSES=$1
    fi
}

validate_peer_addresses_lines() {
    addresses=$1
    [ -n "$addresses" ] || return 0
    while IFS= read -r address || [ -n "$address" ]; do
        [ -n "$address" ] || continue
        validate_cidr "$address" peer-address
        case "$address" in */32) ;; *) die "peer-address must use /32" ;; esac
        if cidr_contains "$OVERLAY_CIDR" "$address"; then
            die "peer-address must be outside the overlay-cidr: $address"
        fi
    done <<EOF
$addresses
EOF
}

option_seen() {
    case " $SEEN_OPTIONS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
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
        {
            if (length($0) != 44 || substr($0, 44, 1) != "=" ||
                substr($0, 1, 43) ~ /[^A-Za-z0-9+\/]/) {
                exit 1
            }
            exit 0
        }
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

preflight_directory_access() {
    target_directory=$1
    description=$2
    require_write_if_exists=$3
    existing_directory=$target_directory
    target_exists=1
    while [ ! -e "$existing_directory" ] && [ ! -L "$existing_directory" ]; do
        target_exists=0
        case "$existing_directory" in
            */*)
                existing_directory=${existing_directory%/*}
                [ -n "$existing_directory" ] || existing_directory=/
                ;;
            *) existing_directory=. ;;
        esac
    done
    [ -d "$existing_directory" ] ||
        die "$description path is not a directory: $existing_directory"
    [ -x "$existing_directory" ] ||
        die "$description path is not traversable: $existing_directory"
    if [ "$target_exists" = 0 ] || [ "$require_write_if_exists" = 1 ]; then
        [ -w "$existing_directory" ] ||
            die "$description path is not writable: $existing_directory"
    fi
}

preflight_install_paths() {
    preflight_directory_access "$STATE_ROOT" 'wgmesh state root' 0
    preflight_directory_access "$NETWORK_DIR" 'wgmesh network state' 1
    preflight_directory_access "$NETWORK_DIR/peers" 'wgmesh peer state' 0
    preflight_directory_access "$CONFIG_ROOT" 'WireGuard config' 1
    if [ "$PLATFORM" = macos ] && [ "$STATE_AUTOSTART" = 1 ]; then
        preflight_directory_access "$LAUNCHD_ROOT" 'LaunchDaemon' 1
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
    STATE_SCHEMA_VERSION=
    STATE_NEEDS_MIGRATION=0
    MTU=
    FIREWALL_MODE=external
    PEER_ADDRESSES=
    schema_seen=0
    firewall_seen=0
    mtu_seen=0
    peer_addresses_seen=0
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
            mtu) MTU=$value; mtu_seen=1 ;;
            firewall_mode) FIREWALL_MODE=$value; firewall_seen=1 ;;
            peer_addresses) PEER_ADDRESSES=$(printf "%s" "$value" | tr "," "\n"); peer_addresses_seen=1 ;;
            schema_version) STATE_SCHEMA_VERSION=$value; schema_seen=1 ;;
            version) ;;
        esac
    done < "$STATE_FILE"
    [ -n "$ROLE" ] && [ -n "$NETWORK" ] && [ -n "$NODE_ID" ] &&
        [ -n "$INTERFACE" ] && [ -n "$CONFIG_PATH" ] || return 1
    [ -n "$STATE_AUTOSTART" ] || STATE_AUTOSTART=0
    [ -n "$FIREWALL_MODE" ] || FIREWALL_MODE=external
    case "$FIREWALL_MODE" in
        external|managed) ;;
        *) return 1 ;;
    esac
    if [ -n "$MTU" ]; then validate_mtu "$MTU"; fi
    if [ "$mtu_seen" = 0 ] && [ -f "$CONFIG_PATH" ]; then
        MTU=$(awk -F= '
            /^[[:space:]]*MTU[[:space:]]*=/ {
                value=$2
                gsub(/[[:space:]]/, "", value)
                print value
                exit
            }
        ' "$CONFIG_PATH")
        [ -z "$MTU" ] || validate_mtu "$MTU"
    fi
    [ "$schema_seen" = 1 ] && [ "$STATE_SCHEMA_VERSION" = 2 ] ||
        STATE_NEEDS_MIGRATION=1
    [ "$firewall_seen" = 1 ] || STATE_NEEDS_MIGRATION=1
    [ "$mtu_seen" = 1 ] || STATE_NEEDS_MIGRATION=1
    [ "$peer_addresses_seen" = 1 ] || STATE_NEEDS_MIGRATION=1
    return 0
}

migrate_state_if_needed() {
    [ "$STATE_NEEDS_MIGRATION" = 1 ] || return 0
    migration_peer_addresses=$PEER_ADDRESSES
    if [ "$ROLE" = host ]; then
        # Hub peer records live in separate files. Never let a caller's
        # temporary PEER_ADDRESSES value leak into the Hub state file.
        PEER_ADDRESSES=
    fi
    if ! write_state "$STATE_FILE" "$ROLE"; then
        PEER_ADDRESSES=$migration_peer_addresses
        return 1
    fi
    PEER_ADDRESSES=$migration_peer_addresses
    STATE_NEEDS_MIGRATION=0
    return 0
}

load_peer_state() {
    peer_input=$1
    PEER_NODE_ID=
    PEER_ADDRESS=
    PEER_PUBLIC_KEY=
    PEER_ROUTES=
    [ -f "$peer_input" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            node_id=*) PEER_NODE_ID=${line#*=} ;;
            address=*) PEER_ADDRESS=${line#*=} ;;
            public_key=*) PEER_PUBLIC_KEY=${line#*=} ;;
            peer_addresses=*) PEER_ROUTES=$(printf "%s" "${line#*=}" | tr "," "\n") ;;
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
        printf 'schema_version=2\n'
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
        printf 'mtu=%s\n' "$MTU"
        printf 'firewall_mode=%s\n' "$FIREWALL_MODE"
        if [ "$role_value" = node ]; then
            printf 'peer_addresses=%s\n' "$(peer_addresses_csv)"
        else
            printf 'peer_addresses=\n'
        fi
    } | atomic_write "$target"
}

write_peer_state() {
    target=$1
    {
        printf 'node_id=%s\n' "$NODE_ID"
        printf 'address=%s\n' "$ADDRESS"
        printf 'public_key=%s\n' "$NODE_PUBLIC_KEY"
        printf 'peer_addresses=%s\n' "$(peer_addresses_csv)"
    } | atomic_write "$target" || return 1
}

write_host_config() {
    target=$1
    skip_node=$2
    read_private_key
    temp="${target}.tmp.$$"
    rm -f "$temp"
    [ -n "$SYSCTL" ] && [ -n "$HOST_FORWARDING_KEY" ] || return 1
    {
        printf '# wgmesh-managed=true\n'
        printf '# wgmesh-network=%s\n' "$NETWORK"
        printf '[Interface]\n'
        printf 'PrivateKey = %s\n' "$PRIVATE_KEY"
        printf 'Address = %s\n' "${HOST_ADDRESS:-$ADDRESS}"
        printf 'ListenPort = %s\n' "$LISTEN_PORT"
        [ -n "$MTU" ] && printf 'MTU = %s\n' "$MTU"
        printf 'PostUp = %s -w %s=1\n' "$SYSCTL" "$HOST_FORWARDING_KEY"
        for peer_file in "$NETWORK_DIR"/peers/*.state; do
            [ -f "$peer_file" ] || continue
            load_peer_state "$peer_file" || return 1
            [ "$PEER_NODE_ID" = "$skip_node" ] && continue
            printf '\n[Peer]\n'
            printf 'PublicKey = %s\n' "$PEER_PUBLIC_KEY"
            peer_allowed="$PEER_ADDRESS"
            if [ -n "$PEER_ROUTES" ]; then
                peer_allowed=$(printf "%s\n%s" "$peer_allowed" "$PEER_ROUTES" | awk 'NF { print }' | paste -sd, -)
            fi
            printf 'AllowedIPs = %s\n' "$peer_allowed"
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

ensure_host_forwarding_hook() {
    expected="PostUp = $SYSCTL -w $HOST_FORWARDING_KEY=1"
    grep -Fqx "$expected" "$CONFIG_PATH" 2>/dev/null && return 0
    temp_config="${CONFIG_PATH}.tmp.$$"
    if ! write_host_config "$temp_config" ''; then
        rm -f "$temp_config"
        die "cannot add Hub forwarding hook to config"
    fi
    mv "$temp_config" "$CONFIG_PATH" || {
        rm -f "$temp_config"
        die "cannot update Hub forwarding hook in config"
    }
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
        [ -n "$MTU" ] && printf 'MTU = %s\n' "$MTU"
        printf '\n[Peer]\n'
        printf 'PublicKey = %s\n' "$HUB_PUBLIC_KEY"
        node_allowed="$OVERLAY_CIDR"
        if [ -n "$PEER_ADDRESSES" ]; then
            node_allowed=$(printf "%s\n%s" "$OVERLAY_CIDR" "$PEER_ADDRESSES" | awk 'NF { print }' | paste -sd, -)
        fi
        printf 'AllowedIPs = %s\n' "$node_allowed"
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

resolve_interface() {
    requested_interface=$1
    if "$WG" show "$requested_interface" >/dev/null 2>&1; then
        printf '%s' "$requested_interface"
        return 0
    fi
    [ "$PLATFORM" = macos ] || return 1
    mapping_file="$WIREGUARD_RUNTIME_ROOT/$requested_interface.name"
    [ -r "$mapping_file" ] || return 1
    runtime_interface=$(sed -n '1p' "$mapping_file") || return 1
    case "$runtime_interface" in
        utun[0-9]*) ;;
        *) return 1 ;;
    esac
    "$WG" show "$runtime_interface" >/dev/null 2>&1 || return 1
    printf '%s' "$runtime_interface"
}

active_interface_name() {
    resolve_interface "$INTERFACE"
}

apply_peer_route() {
    wgmesh_route_destination=$1
    wgmesh_route_interface=$2
    wgmesh_route_ip=${wgmesh_route_destination%/*}
    case "$PLATFORM" in
        linux)
            IP=$(command_path "$IP" ip)
            [ -n "$IP" ] || return 1
            "$IP" -4 route add "$wgmesh_route_destination" dev "$wgmesh_route_interface" >/dev/null 2>&1
            ;;
        macos)
            ROUTE=$(command_path "$ROUTE" route)
            [ -n "$ROUTE" ] || return 1
            "$ROUTE" -n add -host "$wgmesh_route_ip" -interface "$wgmesh_route_interface" >/dev/null 2>&1
            ;;
    esac
}

peer_route_status() {
    wgmesh_route_destination=$1
    wgmesh_route_interface=$2
    wgmesh_owned_routes=$3
    wgmesh_route_ip=${wgmesh_route_destination%/*}
    case "$PLATFORM" in
        linux)
            IP=$(command_path "$IP" ip)
            [ -n "$IP" ] || { printf UNKNOWN; return 0; }
            wgmesh_route_output=$("$IP" -4 route show exact "$wgmesh_route_destination" 2>/dev/null) || {
                printf UNKNOWN
                return 0
            }
            [ -n "$wgmesh_route_output" ] || { printf ABSENT; return 0; }
            if printf '%s\n' "$wgmesh_route_output" | awk -v dev="$wgmesh_route_interface" '
                {
                    found = 1
                    matched = 0
                    for (i = 1; i < NF; i++) {
                        if ($i == "dev" && $(i + 1) == dev) matched = 1
                    }
                    if (!matched) bad = 1
                }
                END { exit !(found && !bad) }
            ' && route_is_owned "$wgmesh_route_destination" "$wgmesh_owned_routes"; then
                printf OWNED
            else
                printf FOREIGN
            fi
            ;;
        macos)
            NETSTAT=$(command_path "$NETSTAT" netstat)
            [ -n "$NETSTAT" ] || { printf UNKNOWN; return 0; }
            wgmesh_route_output=$("$NETSTAT" -rn -f inet 2>/dev/null) || {
                printf UNKNOWN
                return 0
            }
            wgmesh_exact_route=$(printf '%s\n' "$wgmesh_route_output" | awk -v address="$wgmesh_route_ip" '
                $1 == address || $1 == address "/32" { print }
            ')
            [ -n "$wgmesh_exact_route" ] || { printf ABSENT; return 0; }
            if printf '%s\n' "$wgmesh_exact_route" | awk -v dev="$wgmesh_route_interface" '
                NF < 4 || $NF != dev { bad = 1 }
                END { exit bad }
            ' && route_is_owned "$wgmesh_route_destination" "$wgmesh_owned_routes"; then
                printf OWNED
            else
                printf FOREIGN
            fi
            ;;
        *)
            printf UNKNOWN
            ;;
    esac
}

ensure_peer_route() {
    wgmesh_route_destination=$1
    wgmesh_route_interface=$2
    wgmesh_owned_routes=$3
    wgmesh_route_state=$(peer_route_status "$wgmesh_route_destination" "$wgmesh_route_interface" "$wgmesh_owned_routes")
    case "$wgmesh_route_state" in
        OWNED) return 0 ;;
        ABSENT) apply_peer_route "$wgmesh_route_destination" "$wgmesh_route_interface" ;;
        *) return 1 ;;
    esac
}

remove_peer_route() {
    wgmesh_route_destination=$1
    wgmesh_route_interface=$2
    wgmesh_route_ip=${wgmesh_route_destination%/*}
    case "$PLATFORM" in
        linux)
            IP=$(command_path "$IP" ip)
            [ -n "$IP" ] || return 1
            "$IP" -4 route del "$wgmesh_route_destination" dev "$wgmesh_route_interface" >/dev/null 2>&1
            ;;
        macos)
            ROUTE=$(command_path "$ROUTE" route)
            [ -n "$ROUTE" ] || return 1
            "$ROUTE" -n delete -host "$wgmesh_route_ip" >/dev/null 2>&1
            ;;
    esac
}

reject_endpoint_route() {
    wgmesh_endpoint_destination=$1
    wgmesh_endpoint=$2
    wgmesh_endpoint_ip=${wgmesh_endpoint%:*}
    wgmesh_requested_ip=${wgmesh_endpoint_destination%/*}
    case "$wgmesh_endpoint_ip" in
        *[!0-9.]*|'')
            die "cannot verify WireGuard endpoint underlay for peer route: $wgmesh_endpoint_destination"
            ;;
    esac
    [ "$wgmesh_requested_ip" != "$wgmesh_endpoint_ip" ] ||
        die "peer route conflicts with WireGuard endpoint underlay address: $wgmesh_requested_ip"
}

preflight_peer_route_set() {
    wgmesh_new_routes=$1
    wgmesh_old_routes=$2
    wgmesh_route_interface=$3
    wgmesh_endpoint=$4
    while IFS= read -r wgmesh_candidate_route || [ -n "$wgmesh_candidate_route" ]; do
        [ -n "$wgmesh_candidate_route" ] || continue
        reject_endpoint_route "$wgmesh_candidate_route" "$wgmesh_endpoint"
        wgmesh_candidate_state=$(peer_route_status "$wgmesh_candidate_route" "$wgmesh_route_interface" "$wgmesh_old_routes")
        case "$wgmesh_candidate_state" in
            ABSENT|OWNED) ;;
            *) die "peer route is not safely managed: $wgmesh_candidate_route ($wgmesh_candidate_state)" ;;
        esac
    done <<EOF
$(printf '%s\n' "$wgmesh_new_routes" | tr ',' '\n')
EOF
    while IFS= read -r wgmesh_candidate_route || [ -n "$wgmesh_candidate_route" ]; do
        [ -n "$wgmesh_candidate_route" ] || continue
        case ",$wgmesh_new_routes," in
            *,"$wgmesh_candidate_route",*) continue ;;
        esac
        wgmesh_candidate_state=$(peer_route_status "$wgmesh_candidate_route" "$wgmesh_route_interface" "$wgmesh_old_routes")
        case "$wgmesh_candidate_state" in
            ABSENT|OWNED) ;;
            *) die "registered peer route is not safely managed: $wgmesh_candidate_route ($wgmesh_candidate_state)" ;;
        esac
    done <<EOF
$(printf '%s\n' "$wgmesh_old_routes" | tr ',' '\n')
EOF
}

validate_host_peer_route_conflicts() {
    requested_routes=$1
    excluded_node=$2
    while IFS= read -r requested_route || [ -n "$requested_route" ]; do
        [ -n "$requested_route" ] || continue
        [ "$requested_route" != "$HOST_ADDRESS" ] ||
            die "peer-address conflicts with hub address: $requested_route"
        for conflict_peer_file in "$NETWORK_DIR"/peers/*.state; do
            [ -f "$conflict_peer_file" ] || continue
            conflict_node=${conflict_peer_file##*/}
            conflict_node=${conflict_node%.state}
            [ "$conflict_node" = "$excluded_node" ] && continue
            load_peer_state "$conflict_peer_file" ||
                die "peer state is unreadable: $conflict_peer_file"
            [ "$requested_route" != "$PEER_ADDRESS" ] ||
                die "peer-address conflicts with registered peer address: $requested_route"
            printf '%s\n' "$PEER_ROUTES" | grep -Fqx "$requested_route" &&
                die "peer-address is already registered: $requested_route"
        done
    done <<EOF
$requested_routes
EOF
}

interface_active() {
    runtime_interface=$(resolve_interface "$INTERFACE") || return 1
    [ -n "$runtime_interface" ]
}

require_route_interface() {
    route_set=$1
    route_interface=$2
    [ -z "$route_set" ] || [ -n "$route_interface" ] ||
        die "cannot verify wgmesh peer routes while the WireGuard interface is inactive"
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
    tool_path=${quick_path%/*}
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '<!-- wgmesh-managed=true network=%s interface=%s -->\n' "$NETWORK" "$INTERFACE"
        printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        printf '%s\n' '<plist version="1.0"><dict>'
        printf '%s\n' '<key>Label</key>'
        printf '<string>com.wgmesh.%s</string>\n' "$INTERFACE"
        printf '%s\n' '<key>EnvironmentVariables</key><dict>'
        printf '%s\n' '<key>PATH</key>'
        printf '<string>%s:/usr/bin:/bin:/usr/sbin:/sbin</string>\n' "$tool_path"
        printf '%s\n' '</dict>'
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
        "$SYSTEMCTL" enable --now "wg-quick@$INTERFACE.service" >/dev/null 2>&1 ||
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
        "$SYSTEMCTL" enable --now "wg-quick@$INTERFACE.service" >/dev/null 2>&1 ||
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
    if [ "$FIREWALL_MODE" = managed ]; then
        firewall_remove >/dev/null 2>&1 || :
    fi
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
    [ "$MTU" = "$7" ] &&
    [ "$STATE_AUTOSTART" = "$8" ] &&
    [ "$FIREWALL_MODE" = "$9" ]
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
    [ "$MTU" = "$8" ] &&
    [ "$STATE_AUTOSTART" = "$9" ]
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
    printf 'interface_state=%s\n' "$(state_is_active "$INTERFACE")"
}

host_init() {
    requested_network=$NETWORK
    requested_node_id=$NODE_ID
    requested_transport=$TRANSPORT
    requested_overlay_cidr=$OVERLAY_CIDR
    requested_address=$ADDRESS
    requested_endpoint=$ENDPOINT
    requested_mtu=$MTU
    requested_firewall_mode=$FIREWALL_MODE
    requested_firewall_option=$FIREWALL_OPTION_SET
    require_privilege
    validate_id "$NETWORK" network
    validate_id "$NODE_ID" node-id
    validate_transport "$TRANSPORT"
    validate_cidr "$OVERLAY_CIDR" overlay-cidr
    validate_cidr "$ADDRESS" address
    validate_address_in_overlay "$OVERLAY_CIDR" "$ADDRESS"
    parse_endpoint "$ENDPOINT"
    [ -z "$MTU" ] || validate_mtu "$MTU"
    validate_firewall_mode "$requested_firewall_mode"
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
    preflight_install_paths
    load_tools "$([ "$NO_AUTOSTART" = 1 ] && printf noautostart || printf autostart)"
    load_host_forwarding_tool

    if [ -f "$STATE_FILE" ]; then
        load_state "$STATE_FILE" || die "host state is unreadable: $STATE_FILE"
        migrate_state_if_needed ||
            die "cannot migrate legacy host state: $STATE_FILE"
        existing_firewall_mode=$FIREWALL_MODE
        if [ "$requested_firewall_option" = 0 ]; then
            requested_firewall_mode=$existing_firewall_mode
        fi
        if ! option_seen --mtu; then
            requested_mtu=$MTU
        fi
        if state_matches_host_init "$requested_network" "$requested_node_id" \
            "$requested_transport" "$requested_overlay_cidr" \
            "$requested_address" "$requested_endpoint" "$requested_mtu" "$requested_autostart" \
            "$requested_firewall_mode"; then
            assert_managed_config "$CONFIG_PATH"
            ensure_host_forwarding_hook
            restore_existing_install
            ensure_host_forwarding ||
                die "cannot enable Hub IPv4 forwarding with sysctl"
            firewall_sync || die "cannot reconcile managed forwarding firewall"
            print_install_result
            printf 'result=NOOP\n'
            return 0
        fi
        if [ "$requested_firewall_option" = 1 ] &&
            [ "$requested_firewall_mode" != "$existing_firewall_mode" ] &&
            state_matches_host_init "$requested_network" "$requested_node_id" \
                "$requested_transport" "$requested_overlay_cidr" \
                "$requested_address" "$requested_endpoint" "$requested_mtu" "$requested_autostart" \
                "$existing_firewall_mode"; then
            firewall_state_backup="${STATE_FILE}.firewall-backup.$$"
            cp -p "$STATE_FILE" "$firewall_state_backup" 2>/dev/null ||
                die "cannot snapshot host state for firewall mode change"
            FIREWALL_MODE=$existing_firewall_mode
            if [ "$requested_firewall_mode" = managed ]; then
                FIREWALL_MODE=managed
                if ! firewall_install; then
                    rm -f "$firewall_state_backup"
                    die "cannot enable managed forwarding firewall"
                fi
            else
                if ! firewall_remove; then
                    rm -f "$firewall_state_backup"
                    die "cannot remove managed forwarding firewall"
                fi
            fi
            FIREWALL_MODE=$requested_firewall_mode
            if ! write_state "$STATE_FILE" host; then
                FIREWALL_MODE=$requested_firewall_mode
                if [ "$existing_firewall_mode" = managed ]; then
                    firewall_remove >/dev/null 2>&1 || :
                    FIREWALL_MODE=managed
                    firewall_install >/dev/null 2>&1 || :
                else
                    firewall_remove >/dev/null 2>&1 || :
                fi
                mv "$firewall_state_backup" "$STATE_FILE" 2>/dev/null || :
                die "cannot save firewall mode state"
            fi
            rm -f "$firewall_state_backup"
            print_install_result
            printf 'result=UPDATED\n'
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
    FIREWALL_MODE=$requested_firewall_mode
    firewall_preflight "$FIREWALL_MODE"

    ensure_state_dirs
    generate_keypair
    write_private_key "$PRIVATE_KEY_PATH" || die "cannot save private key"
    write_host_config "$CONFIG_PATH" '' || {
        rm -f "$PRIVATE_KEY_PATH"
        die "cannot write host config"
    }
    if [ "$STATE_AUTOSTART" = 1 ]; then
        enable_autostart || {
            cleanup_new_install
            die "cannot enable host autostart"
        }
    else
        bring_up || {
            rm -f "$CONFIG_PATH" "$PRIVATE_KEY_PATH"
            die "host initialization failed"
        }
    fi
    if ! ensure_host_forwarding; then
        cleanup_new_install
        die "cannot enable Hub IPv4 forwarding with sysctl"
    fi
    if ! firewall_install; then
        cleanup_new_install
        die "cannot enable managed forwarding firewall"
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
    requested_mtu=$MTU
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
    [ -z "$MTU" ] || validate_mtu "$MTU"
    INTERFACE=$(interface_for_network "$NETWORK")
    NETWORK_DIR=$(network_dir_for "$NETWORK")
    STATE_FILE=$(state_path_for "$NETWORK" node)
    CONFIG_PATH=$(config_path_for "$INTERFACE")
    PRIVATE_KEY_PATH=$(private_key_path_for "$NETWORK")
    SERVICE_PATH=$(service_path_for "$INTERFACE")
    STATE_AUTOSTART=1
    [ "$NO_AUTOSTART" = 1 ] && STATE_AUTOSTART=0
    requested_autostart=$STATE_AUTOSTART
    preflight_install_paths
    load_tools "$([ "$NO_AUTOSTART" = 1 ] && printf noautostart || printf autostart)"

    if [ -f "$STATE_FILE" ]; then
        load_state "$STATE_FILE" || die "node state is unreadable: $STATE_FILE"
        migrate_state_if_needed ||
            die "cannot migrate legacy node state: $STATE_FILE"
        if ! option_seen --mtu; then
            requested_mtu=$MTU
        fi
        if state_matches_node_join "$requested_network" "$requested_node_id" \
            "$requested_transport" "$requested_overlay_cidr" \
            "$requested_address" "$requested_hub_endpoint" "$requested_hub_public_key" \
            "$requested_mtu" "$requested_autostart"; then
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
    if [ "$STATE_AUTOSTART" = 1 ]; then
        enable_autostart || {
            cleanup_new_install
            die "cannot enable node autostart"
        }
    else
        bring_up || {
            rm -f "$CONFIG_PATH" "$PRIVATE_KEY_PATH"
            die "node join failed"
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
    parse_endpoint "$ENDPOINT"
    LISTEN_PORT=$ENDPOINT_PORT
    assert_managed_config "$CONFIG_PATH"
    migrate_state_if_needed ||
        die "cannot migrate legacy host state: $STATE_FILE"
}

host_add_node() {
    requested_network=$NETWORK
    requested_node_id=$NODE_ID
    requested_address=$ADDRESS
    requested_node_public_key=$NODE_PUBLIC_KEY
    requested_peer_addresses=$PEER_ADDRESSES
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
    PEER_ADDRESSES=$requested_peer_addresses
    validate_address_in_overlay "$OVERLAY_CIDR" "$ADDRESS"
    load_tools noautostart
    load_host_forwarding_tool
    validate_peer_addresses_lines "$PEER_ADDRESSES"
    while IFS= read -r peer_route || [ -n "$peer_route" ]; do
        [ -n "$peer_route" ] || continue
        reject_endpoint_route "$peer_route" "$ENDPOINT"
    done <<EOF
$PEER_ADDRESSES
EOF

    peer_file="$NETWORK_DIR/peers/$NODE_ID.state"
    if [ -f "$peer_file" ]; then
        load_peer_state "$peer_file" || die "peer state is unreadable: $peer_file"
        if [ "$PEER_ADDRESS" = "$ADDRESS" ] &&
            [ "$PEER_PUBLIC_KEY" = "$NODE_PUBLIC_KEY" ]; then
            requested_routes=$(printf '%s\n' "$requested_peer_addresses" | awk 'NF { print }' | sort -u | paste -sd, -)
            existing_routes=$(printf '%s\n' "$PEER_ROUTES" | awk 'NF { print }' | sort -u | paste -sd, -)
            [ "$requested_routes" = "$existing_routes" ] ||
                die "peer is already registered; use host set-routes to change peer addresses"
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
        while IFS= read -r route || [ -n "$route" ]; do
            [ -n "$route" ] || continue
            printf '%s\n' "$PEER_ADDRESSES" | grep -Fqx "$route" &&
                die "peer-address is already registered: $route"
        done <<EOF
$PEER_ROUTES
EOF
    done
    validate_host_peer_route_conflicts "$PEER_ADDRESSES" "$NODE_ID"
    load_host_or_die
    NETWORK=$requested_network
    NODE_ID=$requested_node_id
    ADDRESS=$requested_address
    NODE_PUBLIC_KEY=$requested_node_public_key
    PEER_ADDRESSES=$requested_peer_addresses
    validate_peer_addresses_lines "$PEER_ADDRESSES"
    runtime_interface=$(active_interface_name 2>/dev/null || printf '%s' '')
    require_route_interface "$PEER_ADDRESSES" "$runtime_interface"
    route_probe_interface=${runtime_interface:-$INTERFACE}
    requested_route_csv=$(printf '%s\n' "$PEER_ADDRESSES" | awk 'NF { print }' | sort -u | paste -sd, -)
    preflight_peer_route_set "$requested_route_csv" "" "$route_probe_interface" "$ENDPOINT"

    ensure_state_dirs
    peer_tmp="${peer_file}.tmp.$$"
    write_peer_state "$peer_tmp" || die "cannot prepare peer state"
    temp_config="${CONFIG_PATH}.tmp.$$"
    if ! mv "$peer_tmp" "$peer_file"; then
        rm -f "$peer_tmp"
        die "cannot save peer state"
    fi
    if ! write_host_config "$temp_config" ''; then
        rm -f "$peer_file" "$temp_config"
        die "cannot build host config"
    fi
    config_backup="${CONFIG_PATH}.backup.$$"
    cp "$CONFIG_PATH" "$config_backup" 2>/dev/null || {
        rm -f "$peer_file" "$temp_config"
        die "cannot snapshot host config"
    }
    live_added=0
    added_routes=
    if [ -n "$runtime_interface" ]; then
        while IFS= read -r peer_route || [ -n "$peer_route" ]; do
            [ -n "$peer_route" ] || continue
            route_before=$(peer_route_status "$peer_route" "$runtime_interface" "")
            if ! ensure_peer_route "$peer_route" "$runtime_interface" ""; then
                while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
                    [ -n "$rollback_route" ] || continue
                    remove_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
                done <<EOF
$added_routes
EOF
                rm -f "$peer_file" "$temp_config" "$config_backup"
                die "cannot install peer route: $peer_route"
            fi
            [ "$route_before" = ABSENT ] &&
                added_routes="${added_routes}${added_routes:+
}$peer_route"
        done <<EOF
$PEER_ADDRESSES
EOF
        live_allowed="$ADDRESS"
        if [ -n "$PEER_ADDRESSES" ]; then
            live_allowed=$(printf "%s\n%s" "$ADDRESS" "$PEER_ADDRESSES" | awk 'NF { print }' | paste -sd, -)
        fi
        if ! "$WG" set "$runtime_interface" peer "$NODE_PUBLIC_KEY" allowed-ips "$live_allowed" >/dev/null 2>&1; then
            while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
                [ -n "$rollback_route" ] || continue
                remove_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
            done <<EOF
$added_routes
EOF
            rm -f "$peer_file" "$temp_config" "$config_backup"
            die "cannot add peer to active interface"
        fi
        live_added=1
    fi
    if ! mv "$temp_config" "$CONFIG_PATH"; then
        if [ "$live_added" = 1 ]; then
            "$WG" set "$runtime_interface" peer "$NODE_PUBLIC_KEY" remove >/dev/null 2>&1 || :
        fi
        while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
            [ -n "$rollback_route" ] || continue
            remove_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
        done <<EOF
$added_routes
EOF
        rm -f "$peer_file" "$temp_config"
        rm -f "$config_backup"
        die "cannot commit host config"
    fi
    if ! firewall_sync; then
        rm -f "$peer_file"
        mv "$config_backup" "$CONFIG_PATH" 2>/dev/null || :
        if [ "$live_added" = 1 ]; then
            "$WG" set "$runtime_interface" peer "$NODE_PUBLIC_KEY" remove >/dev/null 2>&1 || :
        fi
        while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
            [ -n "$rollback_route" ] || continue
            remove_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
        done <<EOF
$added_routes
EOF
        firewall_sync >/dev/null 2>&1 || :
        die "cannot reconcile managed forwarding firewall"
    fi
    rm -f "$config_backup"
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
    load_host_forwarding_tool
    peer_file="$NETWORK_DIR/peers/$NODE_ID.state"
    [ -f "$peer_file" ] || {
        printf 'network_id=%s\nnode_id=%s\npeer_revoked=none\nstate=CONFIGURED\nresult=NOOP\n' \
            "$NETWORK" "$NODE_ID"
        return 0
    }
    load_peer_state "$peer_file" || die "peer state is unreadable: $peer_file"
    peer_routes_csv=$(printf '%s\n' "$PEER_ROUTES" | awk 'NF { print }' | sort -u | paste -sd, -)
    runtime_interface=$(active_interface_name 2>/dev/null || printf '%s' '')
    require_route_interface "$peer_routes_csv" "$runtime_interface"
    route_probe_interface=${runtime_interface:-$INTERFACE}
    preflight_peer_route_set "" "$peer_routes_csv" "$route_probe_interface" "$ENDPOINT"
    peer_tmp="${peer_file}.removing.$$"
    mv "$peer_file" "$peer_tmp" || die "cannot prepare peer removal"

    temp_config="${CONFIG_PATH}.tmp.$$"
    if ! write_host_config "$temp_config" ''; then
        mv "$peer_tmp" "$peer_file" 2>/dev/null || :
        rm -f "$temp_config"
        die "cannot build host config"
    fi
    config_backup="${CONFIG_PATH}.backup.$$"
    cp "$CONFIG_PATH" "$config_backup" 2>/dev/null || {
        mv "$peer_tmp" "$peer_file" 2>/dev/null || :
        rm -f "$temp_config"
        die "cannot snapshot host config"
    }
    live_removed=0
    if [ -n "$runtime_interface" ]; then
        if ! "$WG" set "$runtime_interface" peer "$PEER_PUBLIC_KEY" remove >/dev/null 2>&1; then
            mv "$peer_tmp" "$peer_file" 2>/dev/null || :
            rm -f "$temp_config" "$config_backup"
            die "cannot remove peer from active interface"
        fi
        live_removed=1
    fi
    removed_routes=
    if [ -n "$runtime_interface" ]; then
        while IFS= read -r route_address || [ -n "$route_address" ]; do
            [ -n "$route_address" ] || continue
            route_state=$(peer_route_status "$route_address" "$runtime_interface" "$peer_routes_csv")
            [ "$route_state" = ABSENT ] && continue
            [ "$route_state" = OWNED ] || {
                [ "$live_removed" = 1 ] &&
                    "$WG" set "$runtime_interface" peer "$PEER_PUBLIC_KEY" \
                        allowed-ips "$PEER_ADDRESS${peer_routes_csv:+,$peer_routes_csv}" >/dev/null 2>&1 || :
                mv "$peer_tmp" "$peer_file" 2>/dev/null || :
                rm -f "$temp_config" "$config_backup"
                die "peer route ownership changed during removal: $route_address"
            }
            if ! remove_peer_route "$route_address" "$runtime_interface"; then
                while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
                    [ -n "$rollback_route" ] || continue
                    apply_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
                done <<EOF
$removed_routes
EOF
                [ "$live_removed" = 1 ] &&
                    "$WG" set "$runtime_interface" peer "$PEER_PUBLIC_KEY" \
                        allowed-ips "$PEER_ADDRESS${peer_routes_csv:+,$peer_routes_csv}" >/dev/null 2>&1 || :
                mv "$peer_tmp" "$peer_file" 2>/dev/null || :
                rm -f "$temp_config" "$config_backup"
                die "cannot remove peer route: $route_address"
            fi
            removed_routes="${removed_routes}${removed_routes:+
}$route_address"
        done <<EOF
$(printf '%s\n' "$peer_routes_csv" | tr ',' '\n')
EOF
    fi
    if ! mv "$temp_config" "$CONFIG_PATH"; then
        if [ "$live_removed" = 1 ]; then
            "$WG" set "$runtime_interface" peer "$PEER_PUBLIC_KEY" \
                allowed-ips "$PEER_ADDRESS${peer_routes_csv:+,$peer_routes_csv}" >/dev/null 2>&1 || :
        fi
        while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
            [ -n "$rollback_route" ] || continue
            apply_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
        done <<EOF
$removed_routes
EOF
        mv "$peer_tmp" "$peer_file" 2>/dev/null || :
        rm -f "$temp_config"
        mv "$config_backup" "$CONFIG_PATH" 2>/dev/null || :
        die "cannot commit host config"
    fi
    if ! firewall_sync; then
        mv "$config_backup" "$CONFIG_PATH" 2>/dev/null || :
        mv "$peer_tmp" "$peer_file" 2>/dev/null || :
        if [ "$live_removed" = 1 ]; then
            "$WG" set "$runtime_interface" peer "$PEER_PUBLIC_KEY" \
                allowed-ips "$PEER_ADDRESS${peer_routes_csv:+,$peer_routes_csv}" >/dev/null 2>&1 || :
        fi
        while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
            [ -n "$rollback_route" ] || continue
            apply_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
        done <<EOF
$removed_routes
EOF
        firewall_sync >/dev/null 2>&1 || :
        die "cannot reconcile managed forwarding firewall"
    fi
    rm -f "$config_backup"
    rm -f "$peer_tmp" 2>/dev/null || :
    printf 'network_id=%s\nnode_id=%s\npeer_revoked=done\nstate=CONFIGURED\nresult=REMOVED\n' \
        "$NETWORK" "$NODE_ID"
}

host_set_routes() {
    requested_network=$NETWORK
    requested_node_id=$NODE_ID
    requested_addresses=$PEER_ADDRESSES
    require_privilege
    validate_id "$requested_network" network
    validate_id "$requested_node_id" node-id
    load_host_or_die
    NETWORK=$requested_network
    NODE_ID=$requested_node_id
    load_tools noautostart
    load_host_forwarding_tool
    validate_peer_addresses_lines "$requested_addresses"
    PEER_ADDRESSES=$requested_addresses
    peer_file="$NETWORK_DIR/peers/$NODE_ID.state"
    [ -f "$peer_file" ] || die "peer is not registered: $NODE_ID"
    load_peer_state "$peer_file" || die "peer state is unreadable: $peer_file"
    PEER_NODE_ID=$NODE_ID
    ADDRESS=$PEER_ADDRESS
    NODE_PUBLIC_KEY=$PEER_PUBLIC_KEY
    validate_host_peer_route_conflicts "$requested_addresses" "$NODE_ID"
    load_peer_state "$peer_file" || die "peer state is unreadable: $peer_file"
    PEER_NODE_ID=$NODE_ID
    ADDRESS=$PEER_ADDRESS
    NODE_PUBLIC_KEY=$PEER_PUBLIC_KEY
    old_routes=$PEER_ROUTES
    old_csv=$(printf '%s\n' "$old_routes" | awk 'NF { print }' | sort -u | paste -sd, -)
    new_csv=$(printf '%s\n' "$requested_addresses" | awk 'NF { print }' | sort -u | paste -sd, -)
    runtime_interface=$(active_interface_name 2>/dev/null || printf '%s' '')
    require_route_interface "$old_csv${new_csv:+
$new_csv}" "$runtime_interface"
    route_probe_interface=${runtime_interface:-$INTERFACE}
    preflight_peer_route_set "$new_csv" "$old_csv" "$route_probe_interface" "$ENDPOINT"
    [ "$old_csv" = "$new_csv" ] && {
        printf 'network_id=%s\nnode_id=%s\npeer_addresses=%s\nresult=NOOP\n' "$NETWORK" "$NODE_ID" "$new_csv"
        return 0
    }
    old_allowed="$PEER_ADDRESS"
    [ -n "$old_csv" ] && old_allowed="$old_allowed,$old_csv"
    new_allowed="$PEER_ADDRESS"
    [ -n "$new_csv" ] && new_allowed="$new_allowed,$new_csv"
    PEER_ADDRESSES=$(printf '%s' "$new_csv" | tr ',' '\n')
    peer_tmp="${peer_file}.tmp.$$"
    write_peer_state "$peer_tmp" || die "cannot prepare route state"
    peer_backup="${peer_file}.backup.$$"
    if ! mv "$peer_file" "$peer_backup" || ! mv "$peer_tmp" "$peer_file"; then
        mv "$peer_backup" "$peer_file" 2>/dev/null || :
        rm -f "$peer_tmp"
        die "cannot stage peer route state"
    fi
    temp_config="${CONFIG_PATH}.tmp.$$"
    if ! write_host_config "$temp_config" ''; then
        rm -f "$peer_file"
        mv "$peer_backup" "$peer_file" 2>/dev/null || :
        rm -f "$temp_config"
        die "cannot build host config"
    fi
    config_backup="${CONFIG_PATH}.backup.$$"
    cp -p "$CONFIG_PATH" "$config_backup" 2>/dev/null ||
        { rm -f "$temp_config" "$config_backup"; rm -f "$peer_file"; mv "$peer_backup" "$peer_file" 2>/dev/null || :; die "cannot preserve host config for route transaction"; }
    live_changed=0
    added_routes=
    removed_routes=
    if [ -n "$runtime_interface" ]; then
        if ! "$WG" set "$runtime_interface" peer "$PEER_PUBLIC_KEY" allowed-ips "$new_allowed" >/dev/null 2>&1; then
            rm -f "$peer_tmp" "$temp_config" "$peer_file" "$config_backup"
            mv "$peer_backup" "$peer_file" 2>/dev/null || :
            die "cannot update peer routes on active interface"
        fi
        live_changed=1
        while IFS= read -r route_address || [ -n "$route_address" ]; do
            [ -n "$route_address" ] || continue
            route_before=$(peer_route_status "$route_address" "$runtime_interface" "$old_csv")
            if ! ensure_peer_route "$route_address" "$runtime_interface" "$old_csv"; then
                "$WG" set "$runtime_interface" peer "$PEER_PUBLIC_KEY" allowed-ips "$old_allowed" >/dev/null 2>&1 || :
                while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
                    [ -n "$rollback_route" ] || continue
                    remove_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
                done <<EOF
$added_routes
EOF
                rm -f "$peer_tmp" "$temp_config" "$peer_file" "$config_backup"
                mv "$peer_backup" "$peer_file" 2>/dev/null || :
                die "cannot install peer route: $route_address"
            fi
            [ "$route_before" = ABSENT ] && added_routes="${added_routes}${added_routes:+
}$route_address"
        done <<EOF
$(printf '%s\n' "$new_csv" | tr ',' '\n')
EOF
        while IFS= read -r route_address || [ -n "$route_address" ]; do
            [ -n "$route_address" ] || continue
            case ",$new_csv," in
                *,"$route_address",*) continue ;;
            esac
            route_before=$(peer_route_status "$route_address" "$runtime_interface" "$old_csv")
            [ "$route_before" = ABSENT ] && continue
            if ! remove_peer_route "$route_address" "$runtime_interface"; then
                "$WG" set "$runtime_interface" peer "$PEER_PUBLIC_KEY" allowed-ips "$old_allowed" >/dev/null 2>&1 || :
                while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
                    [ -n "$rollback_route" ] || continue
                    apply_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
                done <<EOF
$removed_routes
EOF
                while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
                    [ -n "$rollback_route" ] || continue
                    remove_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
                done <<EOF
$added_routes
EOF
                rm -f "$peer_tmp" "$temp_config" "$peer_file" "$config_backup"
                mv "$peer_backup" "$peer_file" 2>/dev/null || :
                die "cannot remove peer route: $route_address"
            fi
            removed_routes="${removed_routes}${removed_routes:+
}$route_address"
        done <<EOF
$(printf '%s\n' "$old_csv" | tr ',' '\n')
EOF
    fi
    if ! mv "$temp_config" "$CONFIG_PATH"; then
        rm -f "$peer_file"
        mv "$peer_backup" "$peer_file" 2>/dev/null || :
        if [ "$live_changed" = 1 ]; then
            "$WG" set "$runtime_interface" peer "$PEER_PUBLIC_KEY" allowed-ips "$old_allowed" >/dev/null 2>&1 || :
            while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
                [ -n "$rollback_route" ] || continue
                apply_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
            done <<EOF
$removed_routes
EOF
            while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
                [ -n "$rollback_route" ] || continue
                remove_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
            done <<EOF
$added_routes
EOF
        fi
        rm -f "$peer_tmp" "$temp_config" "$config_backup"
        die "cannot commit route state"
    fi
    if ! firewall_sync; then
        mv "$config_backup" "$CONFIG_PATH" 2>/dev/null || :
        rm -f "$peer_file"
        mv "$peer_backup" "$peer_file" 2>/dev/null || :
        if [ "$live_changed" = 1 ]; then
            "$WG" set "$runtime_interface" peer "$PEER_PUBLIC_KEY" allowed-ips "$old_allowed" >/dev/null 2>&1 || :
            while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
                [ -n "$rollback_route" ] || continue
                apply_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
            done <<EOF
$removed_routes
EOF
            while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
                [ -n "$rollback_route" ] || continue
                remove_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
            done <<EOF
$added_routes
EOF
        fi
        firewall_sync >/dev/null 2>&1 || :
        rm -f "$config_backup"
        die "cannot reconcile managed forwarding firewall"
    fi
    rm -f "$config_backup"
    rm -f "$peer_backup"
    printf 'network_id=%s\nnode_id=%s\npeer_addresses=%s\nresult=UPDATED\n' "$NETWORK" "$NODE_ID" "$new_csv"
}

node_set_routes() {
    requested_network=$NETWORK
    requested_addresses=$PEER_ADDRESSES
    require_privilege
    validate_id "$requested_network" network
    load_state "$(state_path_for "$NETWORK" node)" || die "node network is not initialized: $NETWORK"
    [ "$ROLE" = node ] || die "state is not a node network"
    migrate_state_if_needed ||
        die "cannot migrate legacy node state: $(state_path_for "$NETWORK" node)"
    NETWORK=$requested_network
    CONFIG_PATH=${CONFIG_PATH:-$(config_path_for "$INTERFACE")}
    PRIVATE_KEY_PATH=${PRIVATE_KEY_PATH:-$(private_key_path_for "$NETWORK")}
    SERVICE_PATH=${SERVICE_PATH:-$(service_path_for "$INTERFACE")}
    assert_managed_config "$CONFIG_PATH"
    load_tools noautostart
    old_csv=$(peer_addresses_csv)
    PEER_ADDRESSES=$requested_addresses
    validate_peer_addresses_lines "$PEER_ADDRESSES"
    new_csv=$(printf '%s' "$PEER_ADDRESSES" | awk 'NF { print }' | sort -u | paste -sd, -)
    old_routes=$old_csv
    runtime_interface=$(active_interface_name 2>/dev/null || printf '%s' '')
    require_route_interface "$old_csv${new_csv:+
$new_csv}" "$runtime_interface"
    route_probe_interface=${runtime_interface:-$INTERFACE}
    preflight_peer_route_set "$new_csv" "$old_csv" "$route_probe_interface" "$HUB_ENDPOINT"
    [ "$old_csv" = "$new_csv" ] && {
        printf 'network_id=%s\npeer_addresses=%s\nresult=NOOP\n' "$NETWORK" "$new_csv"
        return 0
    }
    STATE_FILE=$(state_path_for "$NETWORK" node)
    PEER_ADDRESSES=$(printf '%s' "$new_csv" | tr ',' '\n')
    temp_config="${CONFIG_PATH}.tmp.$$"
    write_node_config "$temp_config" || { rm -f "$temp_config"; die "cannot build node config"; }
    config_backup="${CONFIG_PATH}.backup.$$"
    state_backup="${STATE_FILE}.backup.$$"
    cp -p "$CONFIG_PATH" "$config_backup" ||
        { rm -f "$temp_config" "$config_backup"; die "cannot preserve node config for route transaction"; }
    cp -p "$STATE_FILE" "$state_backup" ||
        { rm -f "$temp_config" "$config_backup" "$state_backup"; die "cannot preserve node state for route transaction"; }
    old_allowed="$OVERLAY_CIDR"
    [ -n "$old_csv" ] && old_allowed="$old_allowed,$old_csv"
    new_allowed="$OVERLAY_CIDR"
    [ -n "$new_csv" ] && new_allowed="$new_allowed,$new_csv"
    live_changed=0
    if [ -n "$runtime_interface" ]; then
        if ! "$WG" set "$runtime_interface" peer "$HUB_PUBLIC_KEY" allowed-ips "$new_allowed" >/dev/null 2>&1; then
            rm -f "$temp_config" "$config_backup" "$state_backup"
            die "cannot update node routes on active interface"
        fi
        live_changed=1
        added_routes=
        removed_routes=
        while IFS= read -r route_address || [ -n "$route_address" ]; do
            [ -n "$route_address" ] || continue
            route_before=$(peer_route_status "$route_address" "$runtime_interface" "$old_csv")
            if ! ensure_peer_route "$route_address" "$runtime_interface" "$old_csv"; then
                "$WG" set "$runtime_interface" peer "$HUB_PUBLIC_KEY" allowed-ips "$old_allowed" >/dev/null 2>&1 || :
                while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
                    [ -n "$rollback_route" ] || continue
                    remove_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
                done <<EOF
$added_routes
EOF
                rm -f "$temp_config" "$config_backup" "$state_backup"
                die "cannot install peer route: $route_address"
            fi
            [ "$route_before" = ABSENT ] && added_routes="${added_routes}${added_routes:+
}$route_address"
        done <<EOF
$(printf '%s\n' "$new_csv" | tr ',' '\n')
EOF
        while IFS= read -r route_address || [ -n "$route_address" ]; do
            [ -n "$route_address" ] || continue
            case ",$new_csv," in
                *,"$route_address",*) ;;
                *)
                    route_before=$(peer_route_status "$route_address" "$runtime_interface" "$old_csv")
                    [ "$route_before" = ABSENT ] && continue
                    if ! remove_peer_route "$route_address" "$runtime_interface"; then
                        "$WG" set "$runtime_interface" peer "$HUB_PUBLIC_KEY" allowed-ips "$old_allowed" >/dev/null 2>&1 || :
                        while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
                            [ -n "$rollback_route" ] || continue
                            apply_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
                        done <<EOF
$removed_routes
EOF
                        while IFS= read -r rollback_route || [ -n "$rollback_route" ]; do
                            [ -n "$rollback_route" ] || continue
                            remove_peer_route "$rollback_route" "$runtime_interface" >/dev/null 2>&1 || :
                        done <<EOF
$added_routes
EOF
                        rm -f "$temp_config" "$config_backup" "$state_backup"
                        die "cannot remove peer route: $route_address"
                    fi
                    removed_routes="${removed_routes}${removed_routes:+
}$route_address"
                    ;;
            esac
        done <<EOF
$(printf '%s\n' "$old_csv" | tr ',' '\n')
EOF
    fi
    temp_state="${STATE_FILE}.tmp.$$"
    if ! write_state "$temp_state" node; then
        rm -f "$temp_config" "$temp_state" "$config_backup" "$state_backup"
        if [ "$live_changed" = 1 ]; then
            "$WG" set "$runtime_interface" peer "$HUB_PUBLIC_KEY" allowed-ips "$old_allowed" >/dev/null 2>&1 || :
            while IFS= read -r route_address || [ -n "$route_address" ]; do
                [ -n "$route_address" ] || continue
                apply_peer_route "$route_address" "$runtime_interface" >/dev/null 2>&1 || :
            done <<EOF
$removed_routes
EOF
            while IFS= read -r route_address || [ -n "$route_address" ]; do
                [ -n "$route_address" ] || continue
                remove_peer_route "$route_address" "$runtime_interface" >/dev/null 2>&1 || :
            done <<EOF
$added_routes
EOF
        fi
        die "cannot prepare node route state"
    fi
    if ! mv "$temp_config" "$CONFIG_PATH" || ! mv "$temp_state" "$STATE_FILE"; then
        mv "$config_backup" "$CONFIG_PATH" 2>/dev/null || :
        mv "$state_backup" "$STATE_FILE" 2>/dev/null || :
        if [ "$live_changed" = 1 ]; then
            "$WG" set "$runtime_interface" peer "$HUB_PUBLIC_KEY" allowed-ips "$old_allowed" >/dev/null 2>&1 || :
            while IFS= read -r route_address || [ -n "$route_address" ]; do
                [ -n "$route_address" ] || continue
                apply_peer_route "$route_address" "$runtime_interface" >/dev/null 2>&1 || :
            done <<EOF
$removed_routes
EOF
            while IFS= read -r route_address || [ -n "$route_address" ]; do
                [ -n "$route_address" ] || continue
                remove_peer_route "$route_address" "$runtime_interface" >/dev/null 2>&1 || :
            done <<EOF
$added_routes
EOF
        fi
        rm -f "$temp_config" "$temp_state" "$config_backup" "$state_backup"
        die "cannot commit node route state"
    fi
    rm -f "$config_backup" "$state_backup"
    printf 'network_id=%s\npeer_addresses=%s\nresult=UPDATED\n' "$NETWORK" "$new_csv"
}

restore_removed_routes() {
    restore_route_interface=$1
    [ -n "$restore_route_interface" ] || return 1
    restore_failed=0
    while IFS= read -r restore_route || [ -n "$restore_route" ]; do
        [ -n "$restore_route" ] || continue
        apply_peer_route "$restore_route" "$restore_route_interface" >/dev/null 2>&1 ||
            restore_failed=1
    done <<EOF
$REMOVED_ROUTES
EOF
    [ "$restore_failed" = 0 ]
}

remove_owned_routes() {
    remove_routes_csv=$1
    remove_route_interface=$2
    REMOVED_ROUTES=
    [ -n "$remove_routes_csv" ] || return 0
    [ -n "$remove_route_interface" ] || return 1
    while IFS= read -r remove_route || [ -n "$remove_route" ]; do
        [ -n "$remove_route" ] || continue
        remove_route_state=$(peer_route_status "$remove_route" \
            "$remove_route_interface" "$remove_routes_csv")
        case "$remove_route_state" in
            ABSENT) continue ;;
            OWNED) ;;
            *) restore_removed_routes "$remove_route_interface" >/dev/null 2>&1 || :
                return 1 ;;
        esac
        if ! remove_peer_route "$remove_route" "$remove_route_interface"; then
            restore_removed_routes "$remove_route_interface" >/dev/null 2>&1 || :
            return 1
        fi
        REMOVED_ROUTES="${REMOVED_ROUTES}${REMOVED_ROUTES:+
}$remove_route"
    done <<EOF
$(printf '%s' "$remove_routes_csv" | tr ',' '\n')
EOF
    return 0
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
    migrate_state_if_needed ||
        die "cannot migrate legacy state: $STATE_FILE"
    if [ "$role_value" = node ] && [ "$NODE_ID" != "$requested_node_id" ]; then
        die "node-id does not match the installed node"
    fi
    NETWORK_DIR=$(network_dir_for "$NETWORK")
    CONFIG_PATH=${CONFIG_PATH:-$(config_path_for "$INTERFACE")}
    PRIVATE_KEY_PATH=${PRIVATE_KEY_PATH:-$(private_key_path_for "$NETWORK")}
    SERVICE_PATH=${SERVICE_PATH:-$(service_path_for "$INTERFACE")}
    assert_managed_config "$CONFIG_PATH"
    load_tools uninstall
    runtime_interface=$(active_interface_name 2>/dev/null || printf '%s' '')
    uninstall_routes_csv=
    if [ "$role_value" = host ]; then
        for uninstall_peer_file in "$NETWORK_DIR"/peers/*.state; do
            [ -f "$uninstall_peer_file" ] || continue
            load_peer_state "$uninstall_peer_file" ||
                die "peer state is unreadable: $uninstall_peer_file"
            uninstall_peer_csv=$(printf '%s\n' "$PEER_ROUTES" |
                awk 'NF { print }' | sort -u | paste -sd, -)
            if [ -n "$uninstall_peer_csv" ]; then
                if [ -n "$uninstall_routes_csv" ]; then
                    uninstall_routes_csv="$uninstall_routes_csv,$uninstall_peer_csv"
                else
                    uninstall_routes_csv=$uninstall_peer_csv
                fi
            fi
        done
        uninstall_routes_csv=$(printf '%s' "$uninstall_routes_csv" |
            tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -)
    else
        uninstall_routes_csv=$(peer_addresses_csv)
    fi
    firewall_removed=0
    if [ "$role_value" = host ] && [ "$FIREWALL_MODE" = managed ]; then
        firewall_remove || die "cannot remove managed forwarding firewall"
        firewall_removed=1
    fi
    if ! remove_owned_routes "$uninstall_routes_csv" "$runtime_interface"; then
        if [ "$firewall_removed" = 1 ]; then
            firewall_install >/dev/null 2>&1 || :
        fi
        die "cannot remove wgmesh-owned peer routes"
    fi
    if [ "$STATE_AUTOSTART" = 1 ]; then
        if ! disable_autostart; then
            restore_removed_routes "$runtime_interface" >/dev/null 2>&1 || :
            [ "$firewall_removed" = 1 ] && firewall_install >/dev/null 2>&1 || :
            die "cannot disable autostart"
        fi
    fi
    if ! bring_down_if_active; then
        restore_removed_routes "$runtime_interface" >/dev/null 2>&1 || :
        [ "$firewall_removed" = 1 ] && firewall_install >/dev/null 2>&1 || :
        die "cannot bring down WireGuard interface"
    fi
    if ! rm -f "$CONFIG_PATH" "$PRIVATE_KEY_PATH"; then
        die "cannot remove wgmesh files"
    fi
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

service_is_active() {
    case "$PLATFORM" in
        linux)
            SYSTEMCTL=$(command_path "$SYSTEMCTL" systemctl)
            [ -n "$SYSTEMCTL" ] || {
                printf UNKNOWN
                return 0
            }
            if "$SYSTEMCTL" is-active --quiet "wg-quick@$INTERFACE.service" \
                >/dev/null 2>&1; then
                printf ACTIVE
            else
                printf INACTIVE
            fi
            ;;
        macos)
            LAUNCHCTL=$(command_path "$LAUNCHCTL" launchctl)
            [ -n "$LAUNCHCTL" ] || {
                printf UNKNOWN
                return 0
            }
            if "$LAUNCHCTL" print "system/com.wgmesh.$INTERFACE" \
                >/dev/null 2>&1; then
                printf ACTIVE
            else
                printf INACTIVE
            fi
            ;;
        *)
            printf UNKNOWN
            ;;
    esac
}

effective_mtu() {
    interface_name=$(resolve_interface "$1") || { printf UNKNOWN; return 0; }
    case "$PLATFORM" in
        linux)
            IP=$(command_path "$IP" ip)
            [ -n "$IP" ] || { printf UNKNOWN; return 0; }
            "$IP" -o link show dev "$interface_name" 2>/dev/null | awk '{ for (i=1;i<=NF;i++) if ($i == "mtu") { print $(i+1); exit } }'
            ;;
        macos)
            IFCONFIG=$(command_path "$IFCONFIG" ifconfig)
            [ -n "$IFCONFIG" ] || { printf UNKNOWN; return 0; }
            "$IFCONFIG" "$interface_name" 2>/dev/null | awk '$1 == "mtu" { print $2; exit }'
            ;;
    esac
}

latest_handshake() {
    runtime_interface=$(resolve_interface "$1") || return 0
    "$WG" show "$runtime_interface" latest-handshakes 2>/dev/null |
        awk '$2 ~ /^[0-9]+$/ && $2 > latest { latest = $2 }
             END { if (latest > 0) print latest }'
}

json_quote() {
    printf '%s\n' "$1" | awk '
        {
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            printf "\"%s\"", $0
        }
    '
}

route_is_owned() {
    owned_route=$1
    owned_route_list=$2
    printf '%s\n' "$owned_route_list" | tr ',' '\n' | grep -Fqx "$owned_route"
}

managed_config_consistency() {
    config_drift=
    [ -r "$CONFIG_PATH" ] || {
        printf 'CONFIG_DRIFT:CONFIG_MISSING'
        return 0
    }
    grep -Fqx '# wgmesh-managed=true' "$CONFIG_PATH" &&
        grep -Fqx "# wgmesh-network=$NETWORK" "$CONFIG_PATH" || {
            printf 'CONFIG_DRIFT:CONFIG_OWNERSHIP'
            return 0
        }
    config_address=$(awk -F= '
        /^[[:space:]]*Address[[:space:]]*=/ {
            value=$2; gsub(/[[:space:]]/, "", value); print value; exit
        }
    ' "$CONFIG_PATH")
    [ "$config_address" = "$ADDRESS" ] || config_drift="${config_drift}${config_drift:+,}CONFIG_ADDRESS"
    config_mtu=$(awk -F= '
        /^[[:space:]]*MTU[[:space:]]*=/ {
            value=$2; gsub(/[[:space:]]/, "", value); print value; exit
        }
    ' "$CONFIG_PATH")
    [ "${config_mtu:-}" = "${MTU:-}" ] ||
        config_drift="${config_drift}${config_drift:+,}CONFIG_MTU"
    if [ "$ROLE" = host ]; then
        config_listen_port=$(awk -F= '
            /^[[:space:]]*ListenPort[[:space:]]*=/ {
                value=$2; gsub(/[[:space:]]/, "", value); print value; exit
            }
        ' "$CONFIG_PATH")
        expected_listen_port=${ENDPOINT##*:}
        [ "$config_listen_port" = "$expected_listen_port" ] ||
            config_drift="${config_drift}${config_drift:+,}CONFIG_LISTEN_PORT"
    fi

    expected_config_peers=$(mktemp "${TMPDIR:-/tmp}/wgmesh-status-peers.XXXXXX") || {
        printf UNKNOWN:TEMPFILE
        return 0
    }
    actual_config_peers=$(mktemp "${TMPDIR:-/tmp}/wgmesh-status-peers.XXXXXX") || {
        rm -f "$expected_config_peers"
        printf UNKNOWN:TEMPFILE
        return 0
    }
    if [ "$ROLE" = host ]; then
        for peer_file in "$NETWORK_DIR"/peers/*.state; do
            [ -f "$peer_file" ] || continue
            load_peer_state "$peer_file" || {
                config_drift="${config_drift}${config_drift:+,}PEER_STATE_UNREADABLE"
                continue
            }
            expected_allowed="$PEER_ADDRESS"
            [ -z "$PEER_ROUTES" ] ||
                expected_allowed=$(printf '%s\n%s' "$expected_allowed" "$PEER_ROUTES" |
                    awk 'NF { print }' | sort -u | paste -sd, -)
            printf '%s|%s\n' "$PEER_PUBLIC_KEY" "$expected_allowed" >> "$expected_config_peers"
        done
    else
        expected_allowed=$OVERLAY_CIDR
        [ -z "$PEER_ADDRESSES" ] ||
            expected_allowed=$(printf '%s\n%s' "$expected_allowed" "$PEER_ADDRESSES" |
                awk 'NF { print }' | sort -u | paste -sd, -)
        printf '%s|%s\n' "$HUB_PUBLIC_KEY" "$expected_allowed" >> "$expected_config_peers"
        config_endpoint=$(awk -F= '
            /^[[:space:]]*Endpoint[[:space:]]*=/ {
                value=$2; sub(/^[[:space:]]*/, "", value); sub(/[[:space:]]*$/, "", value)
                print value; exit
            }
        ' "$CONFIG_PATH")
        [ "$config_endpoint" = "$HUB_ENDPOINT" ] ||
            config_drift="${config_drift}${config_drift:+,}CONFIG_ENDPOINT"
    fi
    awk '
        BEGIN { in_peer=0; key=""; allowed="" }
        /^[[:space:]]*\[Peer\][[:space:]]*$/ {
            if (in_peer && key != "") print key "|" allowed
            in_peer=1; key=""; allowed=""; next
        }
        in_peer && /^[[:space:]]*PublicKey[[:space:]]*=/ {
            value=$0; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/[[:space:]]*$/, "", value); key=value; next
        }
        in_peer && /^[[:space:]]*AllowedIPs[[:space:]]*=/ {
            value=$0; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/[[:space:]]*$/, "", value); allowed=value; next
        }
        END { if (in_peer && key != "") print key "|" allowed }
    ' "$CONFIG_PATH" | sort > "$actual_config_peers"
    sort -o "$expected_config_peers" "$expected_config_peers"
    if ! cmp -s "$expected_config_peers" "$actual_config_peers"; then
        config_drift="${config_drift}${config_drift:+,}CONFIG_PEERS"
    fi
    rm -f "$expected_config_peers" "$actual_config_peers"
    [ -z "$config_drift" ] && printf CONSISTENT || printf 'CONFIG_DRIFT:%s' "$config_drift"
}

runtime_peer_consistency() {
    runtime_status=CONSISTENT
    runtime_interface=$(resolve_interface "$INTERFACE") || {
        printf UNKNOWN:INTERFACE
        return 0
    }
    expected_runtime=$(mktemp "${TMPDIR:-/tmp}/wgmesh-status-runtime.XXXXXX") || {
        printf UNKNOWN:TEMPFILE
        return 0
    }
    actual_runtime=$(mktemp "${TMPDIR:-/tmp}/wgmesh-status-runtime.XXXXXX") || {
        rm -f "$expected_runtime"
        printf UNKNOWN:TEMPFILE
        return 0
    }
    if [ "$ROLE" = host ]; then
        for peer_file in "$NETWORK_DIR"/peers/*.state; do
            [ -f "$peer_file" ] || continue
            load_peer_state "$peer_file" || continue
            runtime_allowed="$PEER_ADDRESS"
            [ -z "$PEER_ROUTES" ] ||
                runtime_allowed=$(printf '%s\n%s' "$runtime_allowed" "$PEER_ROUTES" |
                    awk 'NF { print }' | sort -u | paste -sd, -)
            printf '%s|%s\n' "$PEER_PUBLIC_KEY" "$runtime_allowed" >> "$expected_runtime"
        done
    else
        runtime_allowed=$OVERLAY_CIDR
        [ -z "$PEER_ADDRESSES" ] ||
            runtime_allowed=$(printf '%s\n%s' "$runtime_allowed" "$PEER_ADDRESSES" |
                awk 'NF { print }' | sort -u | paste -sd, -)
        printf '%s|%s\n' "$HUB_PUBLIC_KEY" "$runtime_allowed" >> "$expected_runtime"
    fi
    runtime_dump=$("$WG" show "$runtime_interface" dump 2>/dev/null) || {
        rm -f "$expected_runtime" "$actual_runtime"
        printf UNKNOWN:WG_DUMP
        return 0
    }
    printf '%s\n' "$runtime_dump" | awk 'NR > 1 && NF >= 4 { print $1 "|" $4 }' |
        sort > "$actual_runtime"
    runtime_mismatch=0
    while IFS= read -r runtime_expected || [ -n "$runtime_expected" ]; do
        [ -n "$runtime_expected" ] || continue
        grep -Fqx "$runtime_expected" "$actual_runtime" || runtime_mismatch=1
    done < "$expected_runtime"
    while IFS= read -r runtime_actual || [ -n "$runtime_actual" ]; do
        [ -n "$runtime_actual" ] || continue
        grep -Fqx "$runtime_actual" "$expected_runtime" || runtime_mismatch=1
    done < "$actual_runtime"
    if [ "$runtime_mismatch" = 1 ]; then
        runtime_status=CONFIG_DRIFT:RUNTIME_PEERS
    fi
    rm -f "$expected_runtime" "$actual_runtime"
    printf '%s' "$runtime_status"
}

endpoint_route_path() {
    endpoint_value=$1
    runtime_interface=$2
    endpoint_host=${endpoint_value%:*}
    case "$endpoint_host" in
        *[!0-9.]*|'') printf UNKNOWN; return 0 ;;
    esac
    case "$PLATFORM" in
        linux)
            IP=$(command_path "$IP" ip)
            [ -n "$IP" ] || { printf UNKNOWN; return 0; }
            endpoint_route_output=$("$IP" -4 route get "$endpoint_host" 2>/dev/null) || {
                printf UNKNOWN
                return 0
            }
            endpoint_route_device=$(printf '%s\n' "$endpoint_route_output" |
                awk '{ for (i=1;i<NF;i++) if ($i=="dev") { print $(i+1); exit } }')
            ;;
        macos)
            ROUTE=$(command_path "$ROUTE" route)
            [ -n "$ROUTE" ] || { printf UNKNOWN; return 0; }
            endpoint_route_output=$("$ROUTE" -n get "$endpoint_host" 2>/dev/null) || {
                printf UNKNOWN
                return 0
            }
            endpoint_route_device=$(printf '%s\n' "$endpoint_route_output" |
                awk '$1 == "interface:" { print $2; exit }')
            ;;
    esac
    [ -n "$endpoint_route_device" ] || { printf UNKNOWN; return 0; }
    [ "$endpoint_route_device" != "$runtime_interface" ] ||
        { printf 'CONFIG_DRIFT:%s' "$endpoint_route_device"; return 0; }
    printf '%s' "$endpoint_route_device"
}

registered_route_consistency() {
    route_status=CONSISTENT
    runtime_interface=$(resolve_interface "$INTERFACE") || {
        printf UNKNOWN:INTERFACE
        return 0
    }
    if [ "$ROLE" = host ]; then
        for peer_file in "$NETWORK_DIR"/peers/*.state; do
            [ -f "$peer_file" ] || continue
            load_peer_state "$peer_file" || {
                route_status=UNKNOWN:PEER_STATE
                continue
            }
            while IFS= read -r route_address || [ -n "$route_address" ]; do
                [ -n "$route_address" ] || continue
                route_state=$(peer_route_status "$route_address" "$runtime_interface" "$PEER_ROUTES")
                case "$route_state" in
                    OWNED) ;;
                    UNKNOWN) route_status=UNKNOWN:PEER_ROUTE ;;
                    *) route_status=CONFIG_DRIFT:PEER_ROUTE ;;
                esac
            done <<EOF_ROUTE
$(printf '%s\n' "$PEER_ROUTES")
EOF_ROUTE
        done
    else
        while IFS= read -r route_address || [ -n "$route_address" ]; do
            [ -n "$route_address" ] || continue
            route_state=$(peer_route_status "$route_address" "$runtime_interface" "$PEER_ADDRESSES")
            case "$route_state" in
                OWNED) ;;
                UNKNOWN) route_status=UNKNOWN:PEER_ROUTE ;;
                *) route_status=CONFIG_DRIFT:PEER_ROUTE ;;
            esac
        done <<EOF_ROUTE_NODE
$(printf '%s\n' "$PEER_ADDRESSES")
EOF_ROUTE_NODE
    fi
    printf '%s' "$route_status"
}

count_peers() {
    count=0
    for peer_file in "$NETWORK_DIR"/peers/*.state; do
        [ -f "$peer_file" ] || continue
        count=$((count + 1))
    done
    printf '%s' "$count"
}

print_peer_routes_json() {
    peer_routes_first=1
    printf '['
    for peer_file in "$NETWORK_DIR"/peers/*.state; do
        [ -f "$peer_file" ] || continue
        load_peer_state "$peer_file" || return 1
        [ "$peer_routes_first" = 1 ] || printf ','
        peer_routes_first=0
        peer_routes_value=$(printf '%s\n' "$PEER_ROUTES" |
            awk 'NF { print }' | paste -sd, -)
        printf '{"node_id":%s,"address":%s,"peer_addresses":%s}' \
            "$(json_quote "$PEER_NODE_ID")" \
            "$(json_quote "$PEER_ADDRESS")" \
            "$(json_quote "$peer_routes_value")"
    done
    printf ']'
}

print_peer_routes_text() {
    peer_routes_first=1
    peer_routes_value=
    for peer_file in "$NETWORK_DIR"/peers/*.state; do
        [ -f "$peer_file" ] || continue
        load_peer_state "$peer_file" || return 1
        peer_route_item="$PEER_NODE_ID:$PEER_ADDRESS"
        peer_routes_csv=$(printf '%s\n' "$PEER_ROUTES" |
            awk 'NF { print }' | paste -sd, -)
        [ -z "$peer_routes_csv" ] || peer_route_item="$peer_route_item:$peer_routes_csv"
        if [ "$peer_routes_first" = 1 ]; then
            peer_routes_value=$peer_route_item
            peer_routes_first=0
        else
            peer_routes_value="$peer_routes_value;$peer_route_item"
        fi
    done
    printf '%s' "${peer_routes_value:-none}"
}

print_status_one() {
    state_file=$1
    load_state "$state_file" || return 1
    state_migration_required=0
    [ "$STATE_NEEDS_MIGRATION" = 1 ] && state_migration_required=1
    NETWORK_DIR=$(network_dir_for "$NETWORK")
    PRIVATE_KEY_PATH=${PRIVATE_KEY_PATH:-$(private_key_path_for "$NETWORK")}
    if [ -z "$WG" ]; then
        WG=$(command_path "$WG" wg)
    fi
    [ -n "$WG" ] || die "required command not found: wg"
    current_state=$(state_is_active "$INTERFACE")
    current_service_state=$(service_is_active)
    handshake=$(latest_handshake "$INTERFACE")
    effective_mtu_value=$(effective_mtu "$INTERFACE")
    if [ "$ROLE" = host ]; then
        firewall_status
    else
        FIREWALL_CHECK=NOT_CHECKED
    fi
    config_consistency=CONSISTENT
    config_drift=
    config_check=$(managed_config_consistency)
    case "$config_check" in
        CONFIG_DRIFT:*)
            config_consistency=CONFIG_DRIFT
            config_drift=${config_check#CONFIG_DRIFT:}
            ;;
        UNKNOWN:*)
            config_consistency=UNKNOWN
            config_drift=${config_check#UNKNOWN:}
            ;;
    esac
    if [ "$state_migration_required" = 1 ]; then
        [ "$config_consistency" = CONSISTENT ] && config_consistency=UNKNOWN
        config_drift="${config_drift}${config_drift:+,}STATE_MIGRATION_REQUIRED"
    fi
    endpoint_value=$ENDPOINT
    [ "$ROLE" = host ] || endpoint_value=$HUB_ENDPOINT
    resolved_interface=$(resolve_interface "$INTERFACE" 2>/dev/null) ||
        resolved_interface=$INTERFACE
    endpoint_path=$(endpoint_route_path "$endpoint_value" "$resolved_interface")
    case "$endpoint_path" in
        CONFIG_DRIFT:*)
            config_consistency=CONFIG_DRIFT
            config_drift="${config_drift}${config_drift:+,}ENDPOINT_PATH"
            ;;
        UNKNOWN)
            if [ "$config_consistency" = CONSISTENT ]; then config_consistency=UNKNOWN; fi
            config_drift="${config_drift}${config_drift:+,}ENDPOINT_PATH_UNKNOWN"
            ;;
    esac
    if [ "$current_state" = ACTIVE ]; then
        runtime_check=$(runtime_peer_consistency)
        case "$runtime_check" in
            CONFIG_DRIFT:*)
                config_consistency=CONFIG_DRIFT
                config_drift="${config_drift}${config_drift:+,}${runtime_check#CONFIG_DRIFT:}"
                ;;
            UNKNOWN:*)
                if [ "$config_consistency" = CONSISTENT ]; then config_consistency=UNKNOWN; fi
                config_drift="${config_drift}${config_drift:+,}${runtime_check#UNKNOWN:}"
                ;;
        esac
        route_check=$(registered_route_consistency)
        case "$route_check" in
            CONFIG_DRIFT:*)
                config_consistency=CONFIG_DRIFT
                config_drift="${config_drift}${config_drift:+,}${route_check#CONFIG_DRIFT:}"
                ;;
            UNKNOWN:*)
                if [ "$config_consistency" = CONSISTENT ]; then config_consistency=UNKNOWN; fi
                config_drift="${config_drift}${config_drift:+,}${route_check#UNKNOWN:}"
                ;;
        esac
    else
        if [ "$config_consistency" = CONSISTENT ]; then
            config_consistency=UNKNOWN
        fi
        config_drift="${config_drift}${config_drift:+,}RUNTIME_UNVERIFIED"
    fi
    [ -n "$config_drift" ] || config_drift=none
    consistency_state=CONSISTENT
    if [ "$STATE_AUTOSTART" = 0 ] && [ "$current_state" = ACTIVE ]; then
        consistency_state=EXPECTED_NO_AUTOSTART
    elif [ "$STATE_AUTOSTART" = 1 ] && [ "$current_state" = ACTIVE ] && [ "$current_service_state" = INACTIVE ]; then
        consistency_state=DEGRADED
    elif [ "$STATE_AUTOSTART" = 1 ] && [ "$current_service_state" = INACTIVE ]; then
        consistency_state=DEGRADED
    fi
    if [ "$JSON_OUTPUT" = 1 ]; then
        if [ "$ROLE" = host ]; then
            printf '{'
            printf '"network_id":%s,' "$(json_quote "$NETWORK")"
            printf '"role":"host",'
            printf '"node_id":%s,' "$(json_quote "$NODE_ID")"
            printf '"transport":%s,' "$(json_quote "$TRANSPORT")"
            printf '"interface":%s,' "$(json_quote "$INTERFACE")"
            printf '"address":%s,' "$(json_quote "$ADDRESS")"
            printf '"endpoint":%s,' "$(json_quote "$ENDPOINT")"
            printf '"autostart":%s,' "$([ "$STATE_AUTOSTART" = 1 ] && printf true || printf false)"
            printf '"service_state":%s,' "$(json_quote "$current_service_state")"
            printf '"state":%s,' "$(json_quote "$current_state")"
            printf '"consistency_state":%s,' "$(json_quote "$consistency_state")"
            printf '"config_consistency":%s,' "$(json_quote "$config_consistency")"
            printf '"config_drift":%s,' "$(json_quote "$config_drift")"
            printf '"state_migration_required":%s,' \
                "$([ "$state_migration_required" = 1 ] && printf true || printf false)"
            printf '"endpoint_path":%s,' "$(json_quote "$endpoint_path")"
            printf '"mtu_configured":%s,' "$(json_quote "${MTU:-UNSET}")"
            printf '"mtu_effective":%s,' "$(json_quote "${effective_mtu_value:-UNKNOWN}")"
            printf '"firewall_mode":%s,' "$(json_quote "$FIREWALL_MODE")"
            printf '"firewall_check":%s,' "$(json_quote "$FIREWALL_CHECK")"
            printf '"handshake":%s,' "${handshake:-null}"
            printf '"hub_public_key":%s,' "$(json_quote "$PUBLIC_KEY")"
            printf '"peer_routes":'
            print_peer_routes_json || return 1
            printf ',"peer_count":%s' "$(count_peers)"
            printf '}\n'
        else
            printf '{'
            printf '"network_id":%s,' "$(json_quote "$NETWORK")"
            printf '"role":"node",'
            printf '"node_id":%s,' "$(json_quote "$NODE_ID")"
            printf '"transport":%s,' "$(json_quote "$TRANSPORT")"
            printf '"interface":%s,' "$(json_quote "$INTERFACE")"
            printf '"address":%s,' "$(json_quote "$ADDRESS")"
            printf '"endpoint":%s,' "$(json_quote "$HUB_ENDPOINT")"
            printf '"autostart":%s,' "$([ "$STATE_AUTOSTART" = 1 ] && printf true || printf false)"
            printf '"service_state":%s,' "$(json_quote "$current_service_state")"
            printf '"state":%s,' "$(json_quote "$current_state")"
            printf '"consistency_state":%s,' "$(json_quote "$consistency_state")"
            printf '"config_consistency":%s,' "$(json_quote "$config_consistency")"
            printf '"config_drift":%s,' "$(json_quote "$config_drift")"
            printf '"state_migration_required":%s,' \
                "$([ "$state_migration_required" = 1 ] && printf true || printf false)"
            printf '"endpoint_path":%s,' "$(json_quote "$endpoint_path")"
            printf '"mtu_configured":%s,' "$(json_quote "${MTU:-UNSET}")"
            printf '"mtu_effective":%s,' "$(json_quote "${effective_mtu_value:-UNKNOWN}")"
            printf '"firewall_mode":%s,' "$(json_quote "$FIREWALL_MODE")"
            printf '"firewall_check":%s,' "$(json_quote "$FIREWALL_CHECK")"
            printf '"handshake":%s,' "${handshake:-null}"
            printf '"node_public_key":%s,' "$(json_quote "$PUBLIC_KEY")"
            printf '"hub_public_key":%s,' "$(json_quote "$HUB_PUBLIC_KEY")"
            printf '"peer_addresses":%s' "$(json_quote "$(peer_addresses_csv)")"
            printf '}\n'
        fi
    else
        printf 'network_id=%s\n' "$NETWORK"
        printf 'role=%s\n' "$ROLE"
        printf 'node_id=%s\n' "$NODE_ID"
        printf 'transport=%s\n' "$TRANSPORT"
        printf 'interface=%s\n' "$INTERFACE"
        printf 'address=%s\n' "$ADDRESS"
        if [ "$ROLE" = host ]; then
            printf 'endpoint=%s\n' "$ENDPOINT"
        else
            printf 'endpoint=%s\n' "$HUB_ENDPOINT"
        fi
        printf 'autostart=%s\n' "$([ "$STATE_AUTOSTART" = 1 ] && printf enabled || printf disabled)"
        printf 'service_state=%s\n' "$current_service_state"
        printf 'state=%s\n' "$current_state"
        printf 'consistency_state=%s\n' "$consistency_state"
        printf 'config_consistency=%s\n' "$config_consistency"
        printf 'config_drift=%s\n' "$config_drift"
        printf 'state_migration_required=%s\n' \
            "$([ "$state_migration_required" = 1 ] && printf true || printf false)"
        printf 'endpoint_path=%s\n' "$endpoint_path"
        printf 'mtu_configured=%s\n' "${MTU:-UNSET}"
        printf 'mtu_effective=%s\n' "${effective_mtu_value:-UNKNOWN}"
        printf 'firewall_mode=%s\nfirewall_check=%s\n' "$FIREWALL_MODE" "$FIREWALL_CHECK"
        printf 'handshake=%s\n' "${handshake:-none}"
        if [ "$ROLE" = host ]; then
            printf 'hub_public_key=%s\n' "$PUBLIC_KEY"
            printf 'peer_routes=%s\n' "$(print_peer_routes_text)"
            printf 'peer_count=%s\n' "$(count_peers)"
        else
            printf 'node_public_key=%s\n' "$PUBLIC_KEY"
            printf 'hub_public_key=%s\n' "$HUB_PUBLIC_KEY"
            printf 'peer_addresses=%s\n' "$(peer_addresses_csv)"
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
            --forward-firewall)
                mark_option "$1"
                need_value "$@"
                FIREWALL_MODE=$2
                FIREWALL_OPTION_SET=1
                shift 2
                ;;
            --mtu)
                mark_option --mtu
                need_value "$@"
                MTU=$2
                shift 2
                ;;
            --peer-address)
                need_value "$@"
                case "$COMMAND:$SUBCOMMAND" in
                    host:add-node|host:set-routes|node:set-routes) ;;
                    *) die "option is not valid for this command: --peer-address" ;;
                esac
                append_peer_address "$2"
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
        check_options "--network-name --node-id --transport --overlay-cidr --address --endpoint --forward-firewall --mtu --no-autostart"
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
        check_options "--network-name --node-id --transport --overlay-cidr --address --hub-endpoint --hub-public-key --mtu --no-autostart"
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
        check_options "--network-name --node-id --address --node-public-key --peer-address"
        require_option "$NETWORK" --network-name
        require_option "$NODE_ID" --node-id
        require_option "$ADDRESS" --address
        require_option "$NODE_PUBLIC_KEY" --node-public-key
        [ "$JSON_OUTPUT" = 0 ] || die "--json is only valid for status"
        [ "$NO_AUTOSTART" = 0 ] || die "--no-autostart is not valid for host add-node"
        host_add_node
        ;;
    host:set-routes)
        check_options "--network-name --node-id --peer-address"
        require_option "$NETWORK" --network-name
        require_option "$NODE_ID" --node-id
        [ "$JSON_OUTPUT" = 0 ] || die "--json is only valid for status"
        host_set_routes
        ;;
    node:set-routes)
        check_options "--network-name --peer-address"
        require_option "$NETWORK" --network-name
        [ "$JSON_OUTPUT" = 0 ] || die "--json is only valid for status"
        node_set_routes
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
