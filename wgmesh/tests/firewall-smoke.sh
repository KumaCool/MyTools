#!/bin/sh
set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WGMESH_DIR=$(CDPATH= cd -- "$TEST_DIR/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wgmesh-fw.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

mkdir -p "$TMP/bin"

cat > "$TMP/bin/nft" <<'EOF'
#!/bin/sh
set -eu
case "$*" in
    "-a list ruleset")
        printf 'table inet filter {\n'
        case "${WGMESH_TEST_NFT_HOOKS:-1}" in
            1)
                printf ' chain forward {\n'
                printf '  type filter hook forward priority filter;\n'
                printf '  policy drop;\n'
                ;;
            2)
                printf ' chain forward {\n'
                printf '  type filter hook forward priority filter;\n'
                printf '  policy drop;\n'
                printf ' }\n}\n'
                printf 'table ip filter {\n chain forward { type filter hook forward priority filter; policy drop; }\n'
                ;;
            0)
                printf ' chain forward {\n'
                printf '  type filter hook input priority filter;\n'
                printf '  policy drop;\n'
                ;;
            *)
                printf ' chain forward {\n'
                printf '  type filter hook forward priority raw;\n'
                printf '  policy drop;\n'
                ;;
        esac
        if [ -f "$WGMESH_TEST_NFT_INSTALLED" ]; then
            if [ "${WGMESH_TEST_NFT_JUMP_NOT_FIRST:-0}" = 1 ]; then
                printf '  accept # handle 1\n'
                printf '  jump %s comment "%s" # handle 20\n' \
                    "$WGMESH_TEST_NFT_CHAIN" "$WGMESH_TEST_NFT_TAG"
            else
                printf '  jump %s comment "%s" # handle 20\n' \
                    "$WGMESH_TEST_NFT_CHAIN" "$WGMESH_TEST_NFT_TAG"
                printf '  accept # handle 1\n'
            fi
        fi
        if [ ! -f "$WGMESH_TEST_NFT_INSTALLED" ]; then
            printf '  accept # handle 1\n'
        fi
        printf ' }\n'
        if [ -f "$WGMESH_TEST_NFT_INSTALLED" ]; then
            printf ' chain %s {\n' "$WGMESH_TEST_NFT_CHAIN"
            nft_interface=$WGMESH_TEST_NFT_INTERFACE
            if [ "${WGMESH_TEST_NFT_POST_DRIFT:-0}" = 1 ]; then
                nft_interface=wgmesh-other
            fi
            printf '  iifname "%s" oifname "%s" ip saddr @%s ip daddr @%s counter packets 0 bytes 0 accept comment "%s" # handle 21\n' \
                "$nft_interface" "$nft_interface" \
                "$WGMESH_TEST_NFT_SET" "$WGMESH_TEST_NFT_SET" "$WGMESH_TEST_NFT_TAG"
            printf '  return comment "%s" # handle 22\n' "$WGMESH_TEST_NFT_TAG"
            printf ' }\n'
            printf ' set %s { type ipv4_addr; flags interval; elements = { 10.250.0.0/24 }; }\n' \
                "$WGMESH_TEST_NFT_SET"
        fi
        printf '}\n'
        ;;
    "-a list chain inet filter forward")
        printf 'chain forward {\n type filter hook forward priority filter; policy drop;\n'
        if [ -f "$WGMESH_TEST_NFT_INSTALLED" ]; then
            if [ "${WGMESH_TEST_NFT_JUMP_NOT_FIRST:-0}" = 1 ]; then
                printf ' accept # handle 1\n'
                printf ' jump %s comment "%s" # handle 20\n' \
                    "$WGMESH_TEST_NFT_CHAIN" "$WGMESH_TEST_NFT_TAG"
            else
                printf ' jump %s comment "%s" # handle 20\n' \
                    "$WGMESH_TEST_NFT_CHAIN" "$WGMESH_TEST_NFT_TAG"
                printf ' accept # handle 1\n'
            fi
        else
            printf ' accept # handle 1\n'
        fi
        printf '}\n'
        ;;
    "-a list chain inet filter "*)
        requested=
        for argument do requested=$argument; done
        if [ "$requested" = "$WGMESH_TEST_NFT_CHAIN" ] &&
            [ -f "$WGMESH_TEST_NFT_INSTALLED" ]; then
            printf 'chain %s {\n' "$WGMESH_TEST_NFT_CHAIN"
            nft_interface=$WGMESH_TEST_NFT_INTERFACE
            if [ "${WGMESH_TEST_NFT_POST_DRIFT:-0}" = 1 ]; then
                nft_interface=wgmesh-other
            fi
            printf ' iifname "%s" oifname "%s" ip saddr @%s ip daddr @%s counter packets 0 bytes 0 accept comment "%s" # handle 21\n' \
                "$nft_interface" "$nft_interface" \
                "$WGMESH_TEST_NFT_SET" "$WGMESH_TEST_NFT_SET" "$WGMESH_TEST_NFT_TAG"
            printf ' return comment "%s" # handle 22\n' "$WGMESH_TEST_NFT_TAG"
            printf '}\n'
            exit 0
        fi
        exit 1
        ;;
    "-a list set inet filter "*)
        requested=
        for argument do requested=$argument; done
        if [ "$requested" = "$WGMESH_TEST_NFT_SET" ] &&
            [ -f "$WGMESH_TEST_NFT_INSTALLED" ]; then
            printf 'set %s {\n type ipv4_addr\n flags interval\n elements = { 10.250.0.0/24 }\n}\n' \
                "$WGMESH_TEST_NFT_SET"
            exit 0
        fi
        exit 1
        ;;
    "-f -")
        batch=$(cat)
        printf '%s\n' "$batch" >> "$WGMESH_TEST_NFT_WRITES"
        case "$batch" in
            *"add chain inet filter $WGMESH_TEST_NFT_CHAIN"*)
                touch "$WGMESH_TEST_NFT_INSTALLED"
                ;;
            *"delete chain inet filter $WGMESH_TEST_NFT_CHAIN"*)
                rm -f "$WGMESH_TEST_NFT_INSTALLED"
                ;;
        esac
        ;;
    *)
        printf 'unexpected fake nft arguments: %s\n' "$*" >&2
        exit 2
        ;;
esac
EOF

cat > "$TMP/bin/iptables" <<'EOF'
#!/bin/sh
printf 'iptables v1.8.9 (nf_tables)\n'
EOF

cat > "$TMP/bin/pfctl" <<'EOF'
#!/bin/sh
set -eu
case "$*" in
    "-s info")
        printf 'Status: Enabled for 0 days 00:00:00\n'
        ;;
    "-sr")
        cat "$WGMESH_TEST_PF_ROOT_RULES"
        ;;
    "-a "*"-sr")
        anchor=${2#-a }
        [ -f "$WGMESH_TEST_PF_ANCHOR" ] && cat "$WGMESH_TEST_PF_ANCHOR" || :
        ;;
    "-a "*"-f -")
        batch=$(cat)
        printf '%s\n' "$batch" >> "$WGMESH_TEST_PF_WRITES"
        printf '%s\n' "$batch" > "$WGMESH_TEST_PF_ANCHOR"
        if [ "${WGMESH_TEST_PF_FAIL_WRITE:-0}" = 1 ] &&
            [ ! -f "$WGMESH_TEST_PF_FAILED_ONCE" ]; then
            touch "$WGMESH_TEST_PF_FAILED_ONCE"
            exit 1
        fi
        ;;
    "-a "*"-F rules")
        rm -f "$WGMESH_TEST_PF_ANCHOR"
        ;;
    *)
        printf 'unexpected fake pfctl arguments: %s\n' "$*" >&2
        exit 2
        ;;
esac
EOF

chmod 700 "$TMP/bin/nft" "$TMP/bin/iptables" "$TMP/bin/pfctl"

NETWORK=smoke-test
INTERFACE=wgmesh-smoke
OVERLAY=10.250.0.0/24
HASH=$(printf '%s' "$NETWORK" | cksum | awk '{print $1}')
export WGMESH_TEST_NFT_CHAIN="wgmesh_${HASH}_forward"
export WGMESH_TEST_NFT_SET="wgmesh_${HASH}_addresses"
export WGMESH_TEST_NFT_TAG="wgmesh:$NETWORK"
export WGMESH_TEST_NFT_INTERFACE=$INTERFACE
export WGMESH_TEST_NFT_INSTALLED="$TMP/nft-installed"
export WGMESH_TEST_NFT_WRITES="$TMP/nft-writes"
export WGMESH_TEST_NFT_HOOKS=1
export WGMESH_TEST_PF_ROOT_RULES="$TMP/pf-root-rules"
export WGMESH_TEST_PF_ANCHOR="$TMP/pf-anchor"
export WGMESH_TEST_PF_WRITES="$TMP/pf-writes"
export WGMESH_TEST_PF_FAILED_ONCE="$TMP/pf-failed-once"
export WGMESH_NFT="$TMP/bin/nft"
export WGMESH_IPTABLES="$TMP/bin/iptables"
export WGMESH_IPTABLES_LEGACY="$TMP/bin/iptables-legacy"
export WGMESH_PFCTL="$TMP/bin/pfctl"

. "$WGMESH_DIR/firewall-unix.sh"

if wgmesh_firewall_preflight linux "$NETWORK" "$INTERFACE" "$OVERLAY" external; then
    :
else
    printf 'external firewall preflight should be a no-op\n' >&2
    exit 1
fi
if [ -e "$WGMESH_TEST_NFT_WRITES" ]; then
    printf 'external firewall preflight wrote nftables state\n' >&2
    exit 1
fi

for hooks in 0 2 raw; do
    WGMESH_TEST_NFT_HOOKS=$hooks
    if wgmesh_firewall_preflight linux "$NETWORK" "$INTERFACE" "$OVERLAY" managed; then
        printf 'unsupported nftables hook layout was accepted: %s\n' "$hooks" >&2
        exit 1
    fi
    if [ -e "$WGMESH_TEST_NFT_WRITES" ]; then
        printf 'unsupported nftables layout wrote rules: %s\n' "$hooks" >&2
        exit 1
    fi
done
WGMESH_TEST_NFT_HOOKS=1

cat > "$TMP/bin/iptables-legacy" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 700 "$TMP/bin/iptables-legacy"
if wgmesh_firewall_preflight linux "$NETWORK" "$INTERFACE" "$OVERLAY" managed; then
    printf 'iptables-legacy coexistence was accepted\n' >&2
    exit 1
fi
if [ -e "$WGMESH_TEST_NFT_WRITES" ]; then
    printf 'legacy backend rejection wrote nftables state\n' >&2
    exit 1
fi
rm -f "$TMP/bin/iptables-legacy"

if ! wgmesh_firewall_preflight linux "$NETWORK" "$INTERFACE" "$OVERLAY" managed; then
    printf 'supported nftables fixture did not pass preflight\n' >&2
    exit 1
fi
if wgmesh_firewall_install linux "$NETWORK" "$INTERFACE" "$OVERLAY" 203.0.113.9/24; then
    printf 'nftables accepted a non-/32 peer address\n' >&2
    exit 1
fi
WGMESH_TEST_NFT_POST_DRIFT=1
export WGMESH_TEST_NFT_POST_DRIFT
if wgmesh_firewall_install linux "$NETWORK" "$INTERFACE" "$OVERLAY" 203.0.113.9/32; then
    printf 'nftables post-install drift was accepted\n' >&2
    exit 1
fi
[ ! -e "$WGMESH_TEST_NFT_INSTALLED" ] || {
    printf 'nftables post-install verification failure left partial objects\n' >&2
    exit 1
}
unset WGMESH_TEST_NFT_POST_DRIFT
: > "$WGMESH_TEST_NFT_WRITES"
wgmesh_firewall_install linux "$NETWORK" "$INTERFACE" "$OVERLAY" 203.0.113.9/32
wgmesh_firewall_install linux "$NETWORK" "$INTERFACE" "$OVERLAY" 203.0.113.9/32
if [ "$(grep -c '^add chain inet filter ' "$WGMESH_TEST_NFT_WRITES")" -ne 1 ] ||
    [ "$(grep -c '^insert rule inet filter forward position ' "$WGMESH_TEST_NFT_WRITES")" -ne 1 ]; then
    printf 'repeated nftables installation created duplicate wgmesh rules\n' >&2
    exit 1
fi
if [ "$(wgmesh_firewall_status linux "$NETWORK" "$INTERFACE")" != OK ]; then
    printf 'nftables status did not recognize the managed fixture\n' >&2
    exit 1
fi
WGMESH_TEST_NFT_JUMP_NOT_FIRST=1
export WGMESH_TEST_NFT_JUMP_NOT_FIRST
if [ "$(wgmesh_firewall_status linux "$NETWORK" "$INTERFACE")" != DRIFT ]; then
    printf 'nftables status accepted a non-head wgmesh jump\n' >&2
    exit 1
fi
unset WGMESH_TEST_NFT_JUMP_NOT_FIRST
if ! grep -Fq 'flush set inet filter' "$WGMESH_TEST_NFT_WRITES" ||
    ! grep -Fq 'add element inet filter' "$WGMESH_TEST_NFT_WRITES"; then
    printf 'nftables sync did not atomically replace the peer address set\n' >&2
    exit 1
fi
if ! grep -Fq "add element inet filter $WGMESH_TEST_NFT_SET { 10.250.0.0/24, 203.0.113.9/32 }" "$WGMESH_TEST_NFT_WRITES"; then
    printf 'nftables installation omitted the registered peer address\n' >&2
    exit 1
fi
wgmesh_firewall_remove linux "$NETWORK"
if [ "$(wgmesh_firewall_status linux "$NETWORK" "$INTERFACE")" != DRIFT ]; then
    printf 'nftables status should report missing managed objects after removal\n' >&2
    exit 1
fi
if ! grep -Fq 'delete rule inet filter forward handle 20' "$WGMESH_TEST_NFT_WRITES" ||
    ! grep -Fq "delete chain inet filter $WGMESH_TEST_NFT_CHAIN" "$WGMESH_TEST_NFT_WRITES" ||
    ! grep -Fq "delete set inet filter $WGMESH_TEST_NFT_SET" "$WGMESH_TEST_NFT_WRITES"; then
    printf 'nftables removal did not target the marked wgmesh objects\n' >&2
    exit 1
fi

printf 'block all\n' > "$WGMESH_TEST_PF_ROOT_RULES"
if wgmesh_firewall_preflight macos "$NETWORK" "$INTERFACE" "$OVERLAY" managed; then
    printf 'pf without a registered wgmesh anchor was accepted\n' >&2
    exit 1
fi
if [ -e "$WGMESH_TEST_PF_WRITES" ]; then
    printf 'unregistered pf anchor preflight wrote rules\n' >&2
    exit 1
fi

cat > "$WGMESH_TEST_PF_ROOT_RULES" <<'EOF'
block all
anchor "wgmesh/*" all
EOF
WGMESH_TEST_PF_FAIL_WRITE=1
export WGMESH_TEST_PF_FAIL_WRITE
if wgmesh_firewall_install macos "$NETWORK" "$INTERFACE" "$OVERLAY" 203.0.113.9/32; then
    printf 'pf failed anchor load was reported as success\n' >&2
    exit 1
fi
[ ! -e "$WGMESH_TEST_PF_ANCHOR" ] || {
    printf 'pf failed anchor load was not rolled back to its prior empty state\n' >&2
    exit 1
}
unset WGMESH_TEST_PF_FAIL_WRITE
wgmesh_firewall_install macos "$NETWORK" "$INTERFACE" "$OVERLAY" 203.0.113.9/32
wgmesh_firewall_sync macos "$NETWORK" "$INTERFACE" "$OVERLAY" 203.0.113.10/32
if [ "$(wc -l < "$WGMESH_TEST_PF_ANCHOR" | tr -d ' ')" -ne 1 ] ||
    ! grep -Fq 'pass in quick on "wgmesh-smoke" inet from {' "$WGMESH_TEST_PF_ANCHOR" ||
    ! grep -Fq 'label "wgmesh:smoke-test"' "$WGMESH_TEST_PF_ANCHOR"; then
    printf 'pf sync did not preserve one marked, interface-scoped rule\n' >&2
    exit 1
fi
if [ "$(wgmesh_firewall_status macos "$NETWORK" "$INTERFACE")" != OK ]; then
    printf 'pf status did not recognize the managed fixture\n' >&2
    exit 1
fi
wgmesh_firewall_remove macos "$NETWORK"
[ ! -e "$WGMESH_TEST_PF_ANCHOR" ] || {
    printf 'pf removal left the wgmesh anchor rule\n' >&2
    exit 1
}

printf 'wgmesh Unix firewall mock smoke: PASS\n'
