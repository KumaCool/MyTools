# Unix firewall helpers for wgmesh.
#
# This file is sourced by wgmesh.sh. It deliberately manages only deterministic
# wgmesh-owned nftables chains/sets or a pre-registered pf anchor. Unknown or
# mixed firewall layouts fail before any write.

wgmesh_fw_error() {
    printf 'ERROR: %s\n' "$*" >&2
}

wgmesh_fw_valid_network() {
    case "$1" in
        ''|[!a-z0-9]*|*[!a-z0-9_-]*) return 1 ;;
        *) [ "${#1}" -le 48 ] ;;
    esac
}

wgmesh_fw_valid_interface() {
    case "$1" in
        ''|*[!A-Za-z0-9_.-]*) return 1 ;;
        *) [ "${#1}" -le 15 ] ;;
    esac
}

wgmesh_fw_valid_ipv4_cidr() {
    printf '%s\n' "$1" | awk -F'[./]' '
        NF != 5 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || ($i + 0) > 255) exit 1
            }
            if ($5 !~ /^[0-9]+$/ || ($5 + 0) > 32) exit 1
            exit 0
        }
    '
}

wgmesh_fw_validate_inputs() {
    wgmesh_fw_valid_network "$2" ||
        { wgmesh_fw_error "invalid network identifier for firewall ownership"; return 1; }
    wgmesh_fw_valid_interface "$3" ||
        { wgmesh_fw_error "invalid WireGuard interface name for firewall rule"; return 1; }
    wgmesh_fw_valid_ipv4_cidr "$4" ||
        { wgmesh_fw_error "invalid IPv4 overlay CIDR for firewall rule"; return 1; }
    if [ -n "$5" ]; then
        wgmesh_fw_error "invalid firewall mode: $5"
        return 1
    fi
    return 0
}

wgmesh_fw_linux_names() {
    wf_hash=$(printf '%s' "$1" | cksum | awk '{print $1}')
    WF_NFT_CHAIN="wgmesh_${wf_hash}_forward"
    WF_NFT_SET="wgmesh_${wf_hash}_addresses"
    WF_NFT_TAG="wgmesh:$1"
}

wgmesh_fw_pf_names() {
    wf_hash=$(printf '%s' "$1" | cksum | awk '{print $1}')
    WF_PF_ANCHOR="wgmesh/$wf_hash"
    WF_PF_TAG="wgmesh:$1"
}

wgmesh_fw_nft() {
    wf_tool=${WGMESH_NFT:-nft}
    command -v "$wf_tool" >/dev/null 2>&1 || return 127
    "$wf_tool" "$@"
}

wgmesh_fw_pfctl() {
    wf_tool=${WGMESH_PFCTL:-pfctl}
    command -v "$wf_tool" >/dev/null 2>&1 || return 127
    "$wf_tool" "$@"
}

wgmesh_fw_nft_backend() {
    wf_ruleset=$(wgmesh_fw_nft -a list ruleset 2>/dev/null) || {
        wgmesh_fw_error "cannot read the complete nftables ruleset"
        return 1
    }

    # An installed legacy binary is treated as a potentially active parallel
    # backend. The nftables implementation never edits or guesses at it.
    wf_legacy_tool=${WGMESH_IPTABLES_LEGACY:-iptables-legacy}
    if command -v "$wf_legacy_tool" >/dev/null 2>&1; then
        wgmesh_fw_error "iptables-legacy is present; refusing mixed firewall management"
        return 1
    fi

    wf_iptables_tool=${WGMESH_IPTABLES:-iptables}
    if command -v "$wf_iptables_tool" >/dev/null 2>&1; then
        wf_iptables_version=$("$wf_iptables_tool" -V 2>/dev/null) || {
            wgmesh_fw_error "cannot determine the iptables backend"
            return 1
        }
        case "$wf_iptables_version" in
            *nf_tables*) ;;
            *)
                wgmesh_fw_error "iptables is not using the nftables backend"
                return 1
                ;;
        esac
    fi

    # Support only a single IPv4-capable filter hook whose order is explicit.
    # A jump at the head of this chain then decides wgmesh peer packets before
    # the chain's existing rules, while all other packets continue unchanged.
    printf '%s\n' "$wf_ruleset" | awk '
        function finish_chain( supported_here) {
            if (chain_has_forward) {
                count++
                supported_here = (family == "inet" && table == "filter" &&
                    chain == "forward" && chain_has_filter &&
                    chain_priority_ok)
                if (supported_here) supported++
                else unsupported++
            }
            in_chain = 0
            chain_has_forward = 0
            chain_has_filter = 0
            chain_priority_ok = 0
        }
        /^table[ \t]+/ {
            if (in_chain) finish_chain()
            family = $2
            table = $3
            sub(/[ \t\{].*/, "", table)
        }
        /^[ \t]*chain[ \t]+/ {
            if (in_chain) finish_chain()
            chain = $2
            sub(/\{.*/, "", chain)
            in_chain = 1
        }
        in_chain {
            if ($0 ~ /type[ \t]+filter([; \t}]|$)/) chain_has_filter = 1
            if ($0 ~ /hook[ \t]+forward([; \t}]|$)/) chain_has_forward = 1
            if ($0 ~ /priority[ \t]+(filter|0)([; \t}]|$)/) chain_priority_ok = 1
            if ($0 ~ /^[ \t]*}/) finish_chain()
        }
        END {
            if (in_chain) finish_chain()
            if (count == 1 && supported == 1 && unsupported == 0) exit 0
            exit 1
        }
    ' || {
        wgmesh_fw_error "managed nftables requires exactly one verifiable IPv4 forward filter hook at inet filter forward with priority filter/0"
        return 1
    }

    WF_NFT_RULESET=$wf_ruleset
    return 0
}

wgmesh_fw_nft_read_forward() {
    wgmesh_fw_nft -a list chain inet filter forward 2>/dev/null
}

wgmesh_fw_nft_read_owned_chain() {
    wgmesh_fw_nft -a list chain inet filter "$WF_NFT_CHAIN" 2>/dev/null
}

wgmesh_fw_nft_read_owned_set() {
    wgmesh_fw_nft -a list set inet filter "$WF_NFT_SET" 2>/dev/null
}

wgmesh_fw_nft_object_state() {
    wf_chain_exists=0
    wf_set_exists=0
    wf_jump_exists=0
    case "$WF_NFT_RULESET" in
        *"chain $WF_NFT_CHAIN {"*) wf_chain_exists=1 ;;
    esac
    case "$WF_NFT_RULESET" in
        *"set $WF_NFT_SET {"*) wf_set_exists=1 ;;
    esac
    wf_forward=$(wgmesh_fw_nft_read_forward) || {
        printf '%s' DRIFT
        return 0
    }
    wf_jump_count=$(printf '%s\n' "$wf_forward" |
        grep -F -c "jump $WF_NFT_CHAIN comment \"$WF_NFT_TAG\"" 2>/dev/null || :)
    [ -n "$wf_jump_count" ] || wf_jump_count=0
    [ "$wf_jump_count" -eq 0 ] 2>/dev/null || wf_jump_exists=1
    wf_reference_count=$(printf '%s\n' "$WF_NFT_RULESET" |
        grep -E -c "(jump|goto)[[:space:]]+$WF_NFT_CHAIN([[:space:]]|$)" 2>/dev/null || :)
    [ -n "$wf_reference_count" ] || wf_reference_count=0

    if [ "$wf_chain_exists" = 0 ] && [ "$wf_set_exists" = 0 ] &&
        [ "$wf_jump_exists" = 0 ] && [ "$wf_reference_count" -eq 0 ] 2>/dev/null; then
        printf '%s' ABSENT
        return 0
    fi
    if [ "$wf_chain_exists" != 1 ] || [ "$wf_set_exists" != 1 ] ||
        [ "$wf_jump_exists" != 1 ] || [ "$wf_jump_count" -ne 1 ] 2>/dev/null ||
        [ "$wf_reference_count" -ne 1 ] 2>/dev/null; then
        printf '%s' DRIFT
        return 0
    fi
    wf_first_rule=$(wgmesh_fw_nft_first_handle "$wf_forward")
    wf_first_line=$(printf '%s\n' "$wf_forward" | awk '/# handle / { print; exit }')
    case "$wf_first_line" in
        *"jump $WF_NFT_CHAIN comment \"$WF_NFT_TAG\""*) wf_first_jump=1 ;;
        *) wf_first_jump=0 ;;
    esac
    if [ -z "$wf_first_rule" ] || [ "$wf_first_jump" != 1 ]; then
        printf '%s' DRIFT
        return 0
    fi

    wf_chain=$(wgmesh_fw_nft_read_owned_chain) || {
        printf '%s' DRIFT
        return 0
    }
    wf_set=$(wgmesh_fw_nft_read_owned_set) || {
        printf '%s' DRIFT
        return 0
    }
    wf_rule_count=$(printf '%s\n' "$wf_chain" |
        grep -F -c '# handle ' 2>/dev/null || :)
    [ -n "$wf_rule_count" ] || wf_rule_count=0
    wf_allow_line=$(printf '%s\n' "$wf_chain" |
        awk -v set="$WF_NFT_SET" -v tag="$WF_NFT_TAG" '
            index($0, "iifname \"") &&
            index($0, "oifname \"") &&
            index($0, "ip saddr @" set " ip daddr @" set " ") &&
            index($0, "accept comment \"" tag "\"") {
                count++
                line = $0
            }
            END {
                if (count == 1) print line
                else exit 1
            }
        ') || wf_allow_line=
    wf_interfaces=$(printf '%s\n' "$wf_allow_line" |
        sed -n 's/.*iifname "\([^"]*\)" oifname "\([^"]*\)".*/\1 \2/p')
    wf_in_interface=${wf_interfaces%% *}
    wf_out_interface=${wf_interfaces#* }
    wf_allow_rule=0
    if [ -n "$wf_allow_line" ] &&
        [ -n "$wf_in_interface" ] &&
        [ "$wf_in_interface" = "$wf_out_interface" ] &&
        wgmesh_fw_valid_interface "$wf_in_interface" &&
        { [ -z "$WF_EXPECTED_INTERFACE" ] ||
            [ "$WF_EXPECTED_INTERFACE" = "$wf_in_interface" ]; }; then
        wf_allow_rule=1
    fi
    case "$wf_chain" in
        *"return comment \"$WF_NFT_TAG\""*) wf_return_rule=1 ;;
        *) wf_return_rule=0 ;;
    esac
    case "$wf_set" in
        *"type ipv4_addr"*"flags interval"*) wf_valid_set=1 ;;
        *) wf_valid_set=0 ;;
    esac
    if [ "$wf_rule_count" -eq 2 ] 2>/dev/null &&
        [ "$wf_allow_rule" = 1 ] && [ "$wf_return_rule" = 1 ] &&
        [ "$wf_valid_set" = 1 ]; then
        printf '%s' VALID
    else
        printf '%s' DRIFT
    fi
}

wgmesh_fw_pf_root_preflight() {
    wf_info=$(wgmesh_fw_pfctl -s info 2>/dev/null) || {
        wgmesh_fw_error "cannot read pf status"
        return 1
    }
    printf '%s\n' "$wf_info" | grep -Eq '^Status:[[:space:]]+Enabled([[:space:]]|$)' || {
        wgmesh_fw_error "pf is not enabled; wgmesh will not enable or reconfigure pf"
        return 1
    }
    wf_root_rules=$(wgmesh_fw_pfctl -sr 2>/dev/null) || {
        wgmesh_fw_error "cannot read the active pf filter rules"
        return 1
    }
    printf '%s\n' "$wf_root_rules" | awk '
        /^[ \t]*anchor[ \t]+/ {
            if ($0 ~ /^[ \t]*anchor[ \t]+"wgmesh\/\*"/) {
                count++
                found = 1
                next
            }
            if (!found) unsafe = 1
        }
        /^[ \t]*block[ \t]+/ && /quick/ && !found { unsafe = 1 }
        END {
            if (count == 1 && !unsafe) exit 0
            exit 1
        }
    ' || {
        wgmesh_fw_error "managed pf requires one pre-registered anchor \"wgmesh/*\" before any filter anchor or block quick rule"
        return 1
    }
    WF_PF_ROOT_RULES=$wf_root_rules
    return 0
}

wgmesh_fw_pf_read_anchor() {
    wgmesh_fw_pfctl -a "$WF_PF_ANCHOR" -sr 2>/dev/null
}

wgmesh_fw_pf_object_state() {
    wf_anchor_rules=$(wgmesh_fw_pf_read_anchor) || {
        printf '%s' DRIFT
        return 0
    }
    wf_count=$(printf '%s\n' "$wf_anchor_rules" | awk 'NF { count++ } END { print count + 0 }')
    if [ "$wf_count" -eq 0 ]; then
        printf '%s' ABSENT
        return 0
    fi
    if [ "$wf_count" -ne 1 ]; then
        printf '%s' DRIFT
        return 0
    fi
    case "$wf_anchor_rules" in
        *"pass in quick on \"$WF_EXPECTED_INTERFACE\" inet from {"*"to {"*"keep state label \"$WF_PF_TAG\""*) printf '%s' VALID ;;
        *) printf '%s' DRIFT ;;
    esac
}

wgmesh_firewall_preflight() {
    wf_platform=$1
    wf_network=$2
    wf_interface=$3
    wf_overlay=$4
    wf_mode=$5
    case "$wf_mode" in
        external) return 0 ;;
        managed) ;;
        *)
            wgmesh_fw_error "firewall mode must be external or managed"
            return 1
            ;;
    esac
    wgmesh_fw_valid_network "$wf_network" ||
        { wgmesh_fw_error "invalid network identifier for firewall ownership"; return 1; }
    wgmesh_fw_valid_interface "$wf_interface" ||
        { wgmesh_fw_error "invalid WireGuard interface name for firewall rule"; return 1; }
    wgmesh_fw_valid_ipv4_cidr "$wf_overlay" ||
        { wgmesh_fw_error "invalid IPv4 overlay CIDR for firewall rule"; return 1; }
    case "$wf_platform" in
        linux)
            wgmesh_fw_linux_names "$wf_network"
            wgmesh_fw_nft_backend || return 1
            WF_EXPECTED_INTERFACE=$wf_interface
            wf_state=$(wgmesh_fw_nft_object_state)
            [ "$wf_state" != DRIFT ] || {
                wgmesh_fw_error "wgmesh nftables objects are incomplete or modified; refusing to take ownership"
                return 1
            }
            ;;
        macos)
            wgmesh_fw_pf_names "$wf_network"
            wgmesh_fw_pf_root_preflight || return 1
            WF_EXPECTED_INTERFACE=$wf_interface
            wf_state=$(wgmesh_fw_pf_object_state)
            [ "$wf_state" != DRIFT ] || {
                wgmesh_fw_error "wgmesh pf anchor contains unrecognized rules; refusing to take ownership"
                return 1
            }
            ;;
        *)
            wgmesh_fw_error "managed firewall is unsupported on platform: $wf_platform"
            return 1
            ;;
    esac
    return 0
}

wgmesh_fw_peer_elements() {
    wf_overlay=$1
    wf_peer_csv=$2
    printf '%s\n' "$wf_overlay"
    while IFS= read -r wf_peer || [ -n "$wf_peer" ]; do
        [ -n "$wf_peer" ] || continue
        case "$wf_peer" in
            */32) ;;
            *)
                wgmesh_fw_error "firewall peer address must use IPv4 /32: $wf_peer"
                exit 1
                ;;
        esac
        wgmesh_fw_valid_ipv4_cidr "$wf_peer" || {
            wgmesh_fw_error "invalid IPv4 firewall peer address: $wf_peer"
            exit 1
        }
        printf '%s\n' "$wf_peer"
    done <<EOF
$(printf '%s' "$wf_peer_csv" | tr ',' '\n')
EOF
}

wgmesh_fw_nft_elements_csv() {
    wf_lines=$(wgmesh_fw_peer_elements "$1" "$2") || return 1
    printf '%s\n' "$wf_lines" |
        awk 'NF && !seen[$0]++ { printf "%s%s", separator, $0; separator=", " }'
}

wgmesh_fw_nft_first_handle() {
    printf '%s\n' "$1" |
        sed -n 's/.*# handle \([0-9][0-9]*\).*/\1/p' |
        awk 'NR == 1 { print; exit }'
}

wgmesh_fw_nft_install() {
    wf_network=$1
    wf_interface=$2
    wf_overlay=$3
    wf_peer_csv=$4
    wgmesh_fw_linux_names "$wf_network"
    WF_EXPECTED_INTERFACE=$wf_interface
    wf_state=$(wgmesh_fw_nft_object_state)
    case "$wf_state" in
        VALID)
            wgmesh_fw_nft_sync "$wf_network" "$wf_interface" "$wf_overlay" "$wf_peer_csv"
            return $?
            ;;
        ABSENT) ;;
        *)
            wgmesh_fw_error "wgmesh nftables objects are incomplete or modified; refusing installation"
            return 1
            ;;
    esac

    wf_elements=$(wgmesh_fw_nft_elements_csv "$wf_overlay" "$wf_peer_csv") || return 1
    wf_forward=$(wgmesh_fw_nft_read_forward) || {
        wgmesh_fw_error "cannot read inet filter forward before installation"
        return 1
    }
    wf_first=$(wgmesh_fw_nft_first_handle "$wf_forward")
    if [ -n "$wf_first" ]; then
        wf_jump_command="insert rule inet filter forward position $wf_first jump $WF_NFT_CHAIN comment \"$WF_NFT_TAG\""
    else
        wf_jump_command="add rule inet filter forward jump $WF_NFT_CHAIN comment \"$WF_NFT_TAG\""
    fi
    wf_batch=$(cat <<EOF
add chain inet filter $WF_NFT_CHAIN
add set inet filter $WF_NFT_SET { type ipv4_addr; flags interval; }
add element inet filter $WF_NFT_SET { $wf_elements }
add rule inet filter $WF_NFT_CHAIN iifname "$wf_interface" oifname "$wf_interface" ip saddr @$WF_NFT_SET ip daddr @$WF_NFT_SET accept comment "$WF_NFT_TAG"
add rule inet filter $WF_NFT_CHAIN return comment "$WF_NFT_TAG"
$wf_jump_command
EOF
) || return 1
    printf '%s\n' "$wf_batch" | wgmesh_fw_nft -f - >/dev/null 2>&1 || {
        wgmesh_fw_error "nftables rejected the atomic wgmesh firewall transaction"
        return 1
    }
    if ! wgmesh_fw_nft_backend; then
        wgmesh_fw_nft_rollback_install "$wf_network" ||
            wgmesh_fw_error "failed to roll back nftables objects after backend verification failed"
        return 1
    fi
    WF_EXPECTED_INTERFACE=$wf_interface
    wf_state=$(wgmesh_fw_nft_object_state)
    if [ "$wf_state" != VALID ]; then
        wgmesh_fw_nft_rollback_install "$wf_network" ||
            wgmesh_fw_error "failed to roll back nftables objects after install verification failed"
        wgmesh_fw_error "nftables did not retain the expected wgmesh firewall objects"
        return 1
    fi
    return 0
}

wgmesh_fw_nft_rollback_install() {
    wf_network=$1
    wgmesh_fw_linux_names "$wf_network"
    wf_forward=$(wgmesh_fw_nft_read_forward 2>/dev/null) || return 1
    wf_jump_lines=$(printf '%s\n' "$wf_forward" |
        grep -F "jump $WF_NFT_CHAIN comment \"$WF_NFT_TAG\"" || :)
    wf_jump_count=$(printf '%s\n' "$wf_jump_lines" |
        awk 'NF { count++ } END { print count + 0 }')
    [ "$wf_jump_count" -eq 1 ] || return 1
    wf_handle=$(printf '%s\n' "$wf_jump_lines" |
        sed -n 's/.*# handle \([0-9][0-9]*\).*/\1/p')
    [ -n "$wf_handle" ] || return 1
    wf_batch=$(cat <<EOF
delete rule inet filter forward handle $wf_handle
delete chain inet filter $WF_NFT_CHAIN
delete set inet filter $WF_NFT_SET
EOF
) || return 1
    printf '%s\n' "$wf_batch" | wgmesh_fw_nft -f - >/dev/null 2>&1 || return 1
    return 0
}

wgmesh_fw_nft_sync() {
    wf_network=$1
    wf_interface=$2
    wf_overlay=$3
    wf_peer_csv=$4
    wgmesh_fw_linux_names "$wf_network"
    WF_EXPECTED_INTERFACE=$wf_interface
    wf_state=$(wgmesh_fw_nft_object_state)
    if [ "$wf_state" = ABSENT ]; then
        wgmesh_fw_nft_install "$wf_network" "$wf_interface" "$wf_overlay" "$wf_peer_csv"
        return $?
    fi
    [ "$wf_state" = VALID ] || {
        wgmesh_fw_error "wgmesh nftables objects are incomplete or modified; refusing update"
        return 1
    }
    wf_elements=$(wgmesh_fw_nft_elements_csv "$wf_overlay" "$wf_peer_csv") || return 1
    wf_batch=$(cat <<EOF
flush set inet filter $WF_NFT_SET
add element inet filter $WF_NFT_SET { $wf_elements }
EOF
) || return 1
    printf '%s\n' "$wf_batch" | wgmesh_fw_nft -f - >/dev/null 2>&1 || {
        wgmesh_fw_error "nftables rejected the atomic wgmesh address-set update"
        return 1
    }
    wgmesh_fw_nft_backend || return 1
    WF_EXPECTED_INTERFACE=$wf_interface
    wf_state=$(wgmesh_fw_nft_object_state)
    [ "$wf_state" = VALID ] || {
        wgmesh_fw_error "wgmesh nftables rules changed during address-set update"
        return 1
    }
    return 0
}

wgmesh_fw_pf_apply() {
    wf_network=$1
    wf_interface=$2
    wf_overlay=$3
    wf_peer_csv=$4
    wf_lines=$(wgmesh_fw_peer_elements "$wf_overlay" "$wf_peer_csv") || return 1
    wf_elements=$(printf '%s\n' "$wf_lines" |
        awk 'NF && !seen[$0]++ { printf "%s%s", separator, $0; separator=", " }') || return 1
    wf_rule="pass in quick on \"$wf_interface\" inet from { $wf_elements } to { $wf_elements } keep state label \"$WF_PF_TAG\""
    wf_old=$(wgmesh_fw_pf_read_anchor) || {
        wgmesh_fw_error "cannot read the wgmesh pf anchor before update"
        return 1
    }
    if ! printf '%s\n' "$wf_rule" |
        wgmesh_fw_pfctl -a "$WF_PF_ANCHOR" -f - >/dev/null 2>&1; then
        wf_restore_ok=1
        if [ -n "$wf_old" ]; then
            printf '%s\n' "$wf_old" |
                wgmesh_fw_pfctl -a "$WF_PF_ANCHOR" -f - >/dev/null 2>&1 || wf_restore_ok=0
        else
            wgmesh_fw_pfctl -a "$WF_PF_ANCHOR" -F rules >/dev/null 2>&1 || wf_restore_ok=0
        fi
        [ "$wf_restore_ok" = 1 ] ||
            wgmesh_fw_error "failed to restore the prior wgmesh pf anchor after rule load failed"
        wgmesh_fw_error "pf rejected the wgmesh anchor rules"
        return 1
    fi
    wf_state=$(wgmesh_fw_pf_object_state)
    if [ "$wf_state" != VALID ]; then
        if [ -n "$wf_old" ]; then
            printf '%s\n' "$wf_old" | wgmesh_fw_pfctl -a "$WF_PF_ANCHOR" -f - >/dev/null 2>&1 || :
        else
            wgmesh_fw_pfctl -a "$WF_PF_ANCHOR" -F rules >/dev/null 2>&1 || :
        fi
        wgmesh_fw_error "pf did not retain the expected wgmesh anchor rule"
        return 1
    fi
    return 0
}

wgmesh_firewall_install() {
    wf_platform=$1
    wf_network=$2
    wf_interface=$3
    wf_overlay=$4
    wf_peer_csv=$5
    wgmesh_fw_valid_network "$wf_network" &&
        wgmesh_fw_valid_interface "$wf_interface" &&
        wgmesh_fw_valid_ipv4_cidr "$wf_overlay" || return 1
    case "$wf_platform" in
        linux)
            wgmesh_fw_linux_names "$wf_network"
            wgmesh_fw_nft_backend || return 1
            wgmesh_fw_nft_install "$wf_network" "$wf_interface" "$wf_overlay" "$wf_peer_csv"
            ;;
        macos)
            wgmesh_fw_pf_names "$wf_network"
            wgmesh_fw_pf_root_preflight || return 1
            WF_EXPECTED_INTERFACE=$wf_interface
            wf_state=$(wgmesh_fw_pf_object_state)
            case "$wf_state" in
                VALID) wgmesh_fw_pf_apply "$wf_network" "$wf_interface" "$wf_overlay" "$wf_peer_csv" ;;
                ABSENT) wgmesh_fw_pf_apply "$wf_network" "$wf_interface" "$wf_overlay" "$wf_peer_csv" ;;
                *)
                    wgmesh_fw_error "wgmesh pf anchor contains unrecognized rules; refusing installation"
                    return 1
                    ;;
            esac
            ;;
        *) wgmesh_fw_error "managed firewall is unsupported on platform: $wf_platform"; return 1 ;;
    esac
}

wgmesh_firewall_sync() {
    wf_platform=$1
    wf_network=$2
    wf_interface=$3
    wf_overlay=$4
    wf_peer_csv=$5
    case "$wf_platform" in
        linux)
            wgmesh_fw_nft_backend || return 1
            wgmesh_fw_nft_sync "$wf_network" "$wf_interface" "$wf_overlay" "$wf_peer_csv"
            ;;
        macos)
            wgmesh_fw_pf_names "$wf_network"
            wgmesh_fw_pf_root_preflight || return 1
            WF_EXPECTED_INTERFACE=$wf_interface
            wf_state=$(wgmesh_fw_pf_object_state)
            [ "$wf_state" = VALID ] || {
                wgmesh_fw_error "wgmesh pf anchor is missing or modified; refusing update"
                return 1
            }
            wgmesh_fw_pf_apply "$wf_network" "$wf_interface" "$wf_overlay" "$wf_peer_csv"
            ;;
        *) wgmesh_fw_error "managed firewall is unsupported on platform: $wf_platform"; return 1 ;;
    esac
}

wgmesh_firewall_status() {
    wf_platform=$1
    wf_network=$2
    wf_expected_interface=${3:-}
    case "$wf_platform" in
        linux)
            wgmesh_fw_linux_names "$wf_network"
            if ! wgmesh_fw_nft_backend; then
                printf '%s\n' DRIFT
                return 0
            fi
            WF_EXPECTED_INTERFACE=$wf_expected_interface
            wf_chain_exists=0
            wf_set_exists=0
            case "$WF_NFT_RULESET" in *"chain $WF_NFT_CHAIN {"*) wf_chain_exists=1 ;; esac
            case "$WF_NFT_RULESET" in *"set $WF_NFT_SET {"*) wf_set_exists=1 ;; esac
            wf_forward=$(wgmesh_fw_nft_read_forward 2>/dev/null || :)
            wf_jump_count=$(printf '%s\n' "$wf_forward" |
                grep -F -c "jump $WF_NFT_CHAIN comment \"$WF_NFT_TAG\"" 2>/dev/null || :)
            [ -n "$wf_jump_count" ] || wf_jump_count=0
            wf_reference_count=$(printf '%s\n' "$WF_NFT_RULESET" |
                grep -E -c "(jump|goto)[[:space:]]+$WF_NFT_CHAIN([[:space:]]|$)" 2>/dev/null || :)
            [ -n "$wf_reference_count" ] || wf_reference_count=0
            wf_first_handle=$(wgmesh_fw_nft_first_handle "$wf_forward")
            wf_first_line=$(printf '%s\n' "$wf_forward" |
                awk '/# handle / { print; exit }')
            case "$wf_first_line" in
                *"jump $WF_NFT_CHAIN comment \"$WF_NFT_TAG\""*) wf_first_jump=1 ;;
                *) wf_first_jump=0 ;;
            esac
            if [ "$wf_chain_exists" != 1 ] || [ "$wf_set_exists" != 1 ] ||
                [ "$wf_jump_count" -ne 1 ] || [ "$wf_reference_count" -ne 1 ] ||
                [ -z "$wf_first_handle" ] || [ "$wf_first_jump" != 1 ] 2>/dev/null; then
                printf '%s\n' DRIFT
                return 0
            fi
            wf_chain=$(wgmesh_fw_nft_read_owned_chain 2>/dev/null || :)
            wf_set=$(wgmesh_fw_nft_read_owned_set 2>/dev/null || :)
            wf_rule_count=$(printf '%s\n' "$wf_chain" | grep -F -c '# handle ' 2>/dev/null || :)
            [ -n "$wf_rule_count" ] || wf_rule_count=0
            case "$wf_chain" in
                *"ip saddr @$WF_NFT_SET ip daddr @$WF_NFT_SET"*"accept comment \"$WF_NFT_TAG\""*"return comment \"$WF_NFT_TAG\""*) wf_expected_rules=1 ;;
                *) wf_expected_rules=0 ;;
            esac
            wf_interfaces=$(printf '%s\n' "$wf_chain" |
                sed -n 's/.*iifname "\([^"]*\)" oifname "\([^"]*\)".*/\1 \2/p' |
                awk 'NR == 1 { print; exit }')
            wf_in_interface=${wf_interfaces%% *}
            wf_out_interface=${wf_interfaces#* }
            case "$wf_set" in *"type ipv4_addr"*"flags interval"*) wf_expected_set=1 ;; *) wf_expected_set=0 ;; esac
            if [ "$wf_rule_count" -eq 2 ] 2>/dev/null &&
                [ "$wf_expected_rules" = 1 ] && [ "$wf_expected_set" = 1 ] &&
                [ -n "$wf_in_interface" ] &&
                [ "$wf_in_interface" = "$wf_out_interface" ] &&
                wgmesh_fw_valid_interface "$wf_in_interface" &&
                { [ -z "$WF_EXPECTED_INTERFACE" ] ||
                    [ "$WF_EXPECTED_INTERFACE" = "$wf_in_interface" ]; }; then
                printf '%s\n' OK
            else
                printf '%s\n' DRIFT
            fi
            ;;
        macos)
            wgmesh_fw_pf_names "$wf_network"
            WF_EXPECTED_INTERFACE=$wf_expected_interface
            if ! wgmesh_fw_pf_root_preflight >/dev/null 2>&1; then
                printf '%s\n' DRIFT
                return 0
            fi
            wf_anchor_rules=$(wgmesh_fw_pf_read_anchor 2>/dev/null || :)
            wf_count=$(printf '%s\n' "$wf_anchor_rules" | awk 'NF { count++ } END { print count + 0 }')
            wf_pf_rule_valid=0
            if [ -n "$WF_EXPECTED_INTERFACE" ]; then
                case "$wf_anchor_rules" in
                    *"pass in quick on \"$WF_EXPECTED_INTERFACE\" inet from {"*"to {"*"keep state label \"$WF_PF_TAG\""*)
                        wf_pf_rule_valid=1
                        ;;
                esac
            else
                case "$wf_anchor_rules" in
                    *"pass in quick on "*"inet from {"*"to {"*"keep state label \"$WF_PF_TAG\""*)
                        wf_pf_rule_valid=1
                        ;;
                esac
            fi
            if [ "$wf_count" -eq 1 ] 2>/dev/null &&
                [ "$wf_pf_rule_valid" = 1 ]; then
                printf '%s\n' OK
            else
                printf '%s\n' DRIFT
            fi
            ;;
        *) printf '%s\n' DRIFT ;;
    esac
}

wgmesh_firewall_remove() {
    wf_platform=$1
    wf_network=$2
    case "$wf_platform" in
        linux)
            wgmesh_fw_linux_names "$wf_network"
            wgmesh_fw_nft_backend || return 1
            wf_state=$(wgmesh_fw_nft_object_state)
            [ "$wf_state" = VALID ] || {
                wgmesh_fw_error "wgmesh nftables objects are missing or modified; refusing removal"
                return 1
            }
            wf_forward=$(wgmesh_fw_nft_read_forward) || return 1
            wf_handle=$(printf '%s\n' "$wf_forward" |
                grep -F "jump $WF_NFT_CHAIN comment \"$WF_NFT_TAG\"" |
                sed -n 's/.*# handle \([0-9][0-9]*\).*/\1/p')
            [ -n "$wf_handle" ] || {
                wgmesh_fw_error "cannot identify the exact wgmesh nftables jump rule"
                return 1
            }
            wf_batch=$(cat <<EOF
delete rule inet filter forward handle $wf_handle
delete chain inet filter $WF_NFT_CHAIN
delete set inet filter $WF_NFT_SET
EOF
) || return 1
            printf '%s\n' "$wf_batch" | wgmesh_fw_nft -f - >/dev/null 2>&1 || {
                wgmesh_fw_error "nftables rejected the atomic wgmesh firewall removal"
                return 1
            }
            wgmesh_fw_nft_backend || return 1
            [ "$(wgmesh_fw_nft_object_state)" = ABSENT ] || {
                wgmesh_fw_error "wgmesh nftables objects remain after removal"
                return 1
            }
            ;;
        macos)
            wgmesh_fw_pf_names "$wf_network"
            wgmesh_fw_pf_root_preflight || return 1
            wf_state=$(wgmesh_fw_pf_object_state)
            [ "$wf_state" = VALID ] || {
                wgmesh_fw_error "wgmesh pf anchor is missing or modified; refusing removal"
                return 1
            }
            wgmesh_fw_pfctl -a "$WF_PF_ANCHOR" -F rules >/dev/null 2>&1 || {
                wgmesh_fw_error "pf rejected the exact wgmesh anchor cleanup"
                return 1
            }
            [ "$(wgmesh_fw_pf_object_state)" = ABSENT ] || {
                wgmesh_fw_error "wgmesh pf anchor rules remain after removal"
                return 1
            }
            ;;
        *) wgmesh_fw_error "managed firewall is unsupported on platform: $wf_platform"; return 1 ;;
    esac
    return 0
}
