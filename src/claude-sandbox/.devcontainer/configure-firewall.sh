#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# sudo resets the environment by default (env_reset), so FIREWALL_WHITELIST_FILE
# set via devcontainer.json's containerEnv does NOT survive
# `sudo configure-firewall.sh`. Never rely on it being present: search known
# locations instead, and treat the env var as an override when it does arrive.
WHITELIST_CANDIDATES=(
    "/etc/firewall/firewall-whitelist-domains.json"
    "${SCRIPT_DIR}/firewall-whitelist-domains.json"
)

WHITELIST_FILE="${FIREWALL_WHITELIST_FILE:-}"
if [ -z "$WHITELIST_FILE" ]; then
    for _candidate in "${WHITELIST_CANDIDATES[@]}"; do
        if [ -f "$_candidate" ]; then
            WHITELIST_FILE="$_candidate"
            break
        fi
    done
    # Nothing found: fall through with the preferred path so the error names it.
    WHITELIST_FILE="${WHITELIST_FILE:-${WHITELIST_CANDIDATES[0]}}"
fi

IPSET_NAME="${FIREWALL_IPSET_NAME:-allowed-domains}"
IPSET_TMP="${IPSET_NAME}-tmp"

MODE="init"
STRICT_DNS="${FIREWALL_STRICT_DNS:-0}"
FLUSH_CONNTRACK=0

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") [MODE] [OPTIONS]

Modes:
  --init              Full setup: iptables rules + build the allow-list (default)
  --reload            Rebuild the allow-list only, leaving iptables rules untouched
  --list              Print the currently active allow-list and exit

Options:
  --file <path>       Whitelist JSON to use, overriding auto-detection.
  --strict            Fail (and, on reload, keep the old list) if any domain
                      cannot be resolved. Default is to warn and skip.
  --flush-conntrack   On reload, drop existing connection tracking entries so
                      that connections to removed domains are cut immediately.

Whitelist resolution order:
  1. --file <path>
  2. \$FIREWALL_WHITELIST_FILE  (note: sudo strips this unless env_keep is set)
  3. /etc/firewall/firewall-whitelist-domains.json
  4. <script dir>/firewall-whitelist-domains.json

Environment:
  FIREWALL_IPSET_NAME       ipset name (default: allowed-domains)
  FIREWALL_STRICT_DNS=1     Same as --strict
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --init)             MODE="init" ;;
        --reload)           MODE="reload" ;;
        --list)             MODE="list" ;;
        --strict)           STRICT_DNS=1 ;;
        --file)             WHITELIST_FILE="${2:?--file requires a path}"; shift ;;
        --flush-conntrack)  FLUSH_CONNTRACK=1 ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[firewall] $*"; }
die() { echo "[firewall] ERROR: $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "must be run as root (try: sudo $0 ...)"
}

# Any failure between creating the temp set and swapping it in leaves the live
# set completely untouched, so a bad config can never open or close the firewall
# half-way.
cleanup_tmp() { ipset destroy "$IPSET_TMP" 2>/dev/null || true; }

# Leave the container with no way out except loopback.
#
# `--init` flushes the existing rules long before it is in a position to install
# the default-deny policy, so every failure in between — an unreachable GitHub
# meta endpoint, an unresolvable domain under --strict, a malformed whitelist —
# used to leave the container with no firewall at all. An agent running in that
# window has unrestricted egress and no way to tell. Sealing is the safe end
# state: wrong, but wrong in the direction that cannot leak.
seal_firewall() {
    log "Sealing container: default-deny policy, loopback only"
    iptables -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    iptables -P INPUT DROP 2>/dev/null || true
    iptables -P FORWARD DROP 2>/dev/null || true
    iptables -P OUTPUT DROP 2>/dev/null || true
    iptables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
    ipset destroy "$IPSET_NAME" 2>/dev/null || true
    ipset destroy "$IPSET_TMP" 2>/dev/null || true
}

validate_whitelist() {
    [ -f "$WHITELIST_FILE" ] || die "whitelist file not found: $WHITELIST_FILE"
    jq -e . "$WHITELIST_FILE" >/dev/null 2>&1 \
        || die "whitelist file is not valid JSON: $WHITELIST_FILE"
    log "Using whitelist: $WHITELIST_FILE"
}

# Accepts either a bare array of domains, or an object with a "domains" key.
read_domains() {
    jq -r 'if type == "array" then . else (.domains // []) end | .[]' "$WHITELIST_FILE"
}

read_cidrs() {
    jq -r 'if type == "array" then [] else (.cidrs // []) end | .[]' "$WHITELIST_FILE"
}

github_enabled() {
    local enabled
    enabled=$(jq -r 'if type == "array" then true else (.github_meta.enabled // false) end' "$WHITELIST_FILE")
    [ "$enabled" = "true" ]
}

read_github_sections() {
    jq -r 'if type == "array" then ["web","api","git"] else (.github_meta.sections // ["web","api","git"]) end | .[]' "$WHITELIST_FILE"
}

is_ipv4_cidr() { [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; }
is_ipv4()      { [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; }
is_hostname()  { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; }

# ---------------------------------------------------------------------------
# Building the allow-list
# ---------------------------------------------------------------------------
add_github_ranges() {
    local set_name="$1"
    local gh_ranges sections=() section cidrs all_cidrs="" cidr

    log "Fetching GitHub IP ranges..."
    gh_ranges=$(curl -s --connect-timeout 10 https://api.github.com/meta) \
        || die "failed to fetch GitHub IP ranges"
    [ -n "$gh_ranges" ] || die "failed to fetch GitHub IP ranges"

    mapfile -t sections < <(read_github_sections)
    [ "${#sections[@]}" -gt 0 ] || die "github_meta.sections is empty"

    for section in "${sections[@]}"; do
        cidrs=$(echo "$gh_ranges" | jq -r --arg s "$section" '.[$s] // empty | .[]') \
            || die "GitHub meta response missing section: $section"
        [ -n "$cidrs" ] || die "GitHub meta response missing or empty section: $section"
        all_cidrs+="${cidrs}"$'\n'
    done

    # GitHub publishes IPv6 ranges too; this ruleset is IPv4-only, so drop them.
    all_cidrs=$(printf '%s' "$all_cidrs" | grep -E '^[0-9]+\.' || true)
    [ -n "$all_cidrs" ] || die "no IPv4 ranges found in GitHub meta response"

    if command -v aggregate >/dev/null 2>&1; then
        all_cidrs=$(printf '%s\n' "$all_cidrs" | aggregate -q)
    fi

    log "Processing GitHub IPs..."
    while read -r cidr; do
        [ -n "$cidr" ] || continue
        is_ipv4_cidr "$cidr" || die "invalid CIDR range from GitHub meta: $cidr"
        ipset add "$set_name" "$cidr" -exist
    done < <(printf '%s\n' "$all_cidrs")
}

add_static_cidrs() {
    local set_name="$1" cidr
    while read -r cidr; do
        [ -n "$cidr" ] || continue
        is_ipv4_cidr "$cidr" || is_ipv4 "$cidr" \
            || die "invalid CIDR in $WHITELIST_FILE: $cidr"
        log "Adding static range $cidr"
        ipset add "$set_name" "$cidr" -exist
    done < <(read_cidrs)
}

add_domains() {
    local set_name="$1" domain ips ip count=0 failed=0

    while read -r domain; do
        [ -n "$domain" ] || continue
        is_hostname "$domain" || die "invalid domain in $WHITELIST_FILE: $domain"

        log "Resolving $domain..."
        ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
        if [ -z "$ips" ]; then
            if [ "$STRICT_DNS" = "1" ]; then
                die "failed to resolve $domain (strict mode)"
            fi
            log "WARNING: Failed to resolve $domain, skipping"
            failed=$((failed + 1))
            continue
        fi

        while read -r ip; do
            [ -n "$ip" ] || continue
            is_ipv4 "$ip" || die "invalid IP from DNS for $domain: $ip"
            log "Adding $ip for $domain"
            ipset add "$set_name" "$ip" -exist
            count=$((count + 1))
        done < <(echo "$ips")
    done < <(read_domains)

    [ "$failed" -eq 0 ] || log "WARNING: $failed domain(s) could not be resolved"
}

# Populates a fresh temp set, then atomically swaps it into place. iptables
# rules reference the set by name, so nothing needs to be re-created here.
build_allowed_set() {
    validate_whitelist

    trap cleanup_tmp EXIT
    cleanup_tmp
    ipset create "$IPSET_TMP" hash:net

    if github_enabled; then
        add_github_ranges "$IPSET_TMP"
    else
        log "GitHub meta ranges disabled in $WHITELIST_FILE"
    fi
    add_static_cidrs "$IPSET_TMP"
    add_domains "$IPSET_TMP"

    local entries
    entries=$(ipset list "$IPSET_TMP" -t | awk '/Number of entries/ {print $NF}')
    [ "${entries:-0}" -gt 0 ] || die "refusing to install an empty allow-list"

    ipset create "$IPSET_NAME" hash:net -exist
    ipset swap "$IPSET_TMP" "$IPSET_NAME"
    ipset destroy "$IPSET_TMP"
    trap - EXIT

    log "Allow-list installed: $entries entries"
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
do_list() {
    ipset list "$IPSET_NAME" 2>/dev/null || die "ipset '$IPSET_NAME' does not exist; run --init first"
}

do_reload() {
    require_root
    iptables -C OUTPUT -m set --match-set "$IPSET_NAME" dst -j ACCEPT 2>/dev/null \
        || die "firewall rules are not installed; run '$0 --init' first"

    log "Reloading allow-list from $WHITELIST_FILE"
    build_allowed_set

    if [ "$FLUSH_CONNTRACK" = "1" ]; then
        if command -v conntrack >/dev/null 2>&1; then
            log "Flushing connection tracking table..."
            conntrack -F 2>/dev/null || log "WARNING: conntrack flush failed"
        else
            log "WARNING: conntrack not installed, skipping flush"
        fi
    fi

    log "Reload complete"
}

install_firewall() {
    # 1. Extract Docker DNS (pre-defined by Docker to be `127.0.0.11`)
    # info BEFORE any flushing
    DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

    # Flush existing rules and delete existing ipsets
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    ipset destroy "$IPSET_NAME" 2>/dev/null || true
    ipset destroy "$IPSET_TMP" 2>/dev/null || true

    # Building the allow-list needs egress of its own — DNS lookups and, when
    # github_meta is on, a call to api.github.com. `iptables -F` leaves the
    # policies alone, so a previous seal (or a previous successful init) would
    # still be denying that traffic and the rebuild could never succeed. Reopen
    # for the build window only; every exit path from here lands in
    # seal_firewall or in the DROP policies installed at the end.
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT

    # 2. Selectively restore ONLY internal Docker DNS resolution
    if [ -n "$DOCKER_DNS_RULES" ]; then
        log "Restoring Docker DNS rules..."
        iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
        iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
        echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
    else
        log "No Docker DNS rules to restore"
    fi

    # First allow DNS and localhost before any restrictions
    # Allow outbound DNS
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    # Allow inbound DNS responses
    iptables -A INPUT -p udp --sport 53 -j ACCEPT
    # Allow outbound SSH
    iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
    # Allow inbound SSH responses
    iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
    # Allow localhost
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT

    # Build the allow-list from the JSON whitelist
    build_allowed_set

    # Get host IP from default route
    HOST_IP=$(ip route | grep default | cut -d" " -f3)
    [ -n "$HOST_IP" ] || die "failed to detect host IP"

    HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
    log "Host network detected as: $HOST_NETWORK"

    # Set up remaining iptables rules
    iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
    iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

    # Set default policies to DROP first
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT DROP

    # First allow established connections for already approved traffic
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Then allow only specific outbound traffic to allowed domains
    iptables -A OUTPUT -m set --match-set "$IPSET_NAME" dst -j ACCEPT

    # Explicitly REJECT all other outbound traffic for immediate feedback
    iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

    log "Firewall configuration complete"
    log "Verifying firewall rules..."
    if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
        die "firewall verification failed - was able to reach https://example.com"
    else
        log "Firewall verification passed - unable to reach https://example.com as expected"
    fi

    # Verify GitHub API access
    if github_enabled; then
        if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
            die "firewall verification failed - unable to reach https://api.github.com"
        else
            log "Firewall verification passed - able to reach https://api.github.com as expected"
        fi
    fi
}

do_init() {
    require_root
    validate_whitelist

    # The subshell is what makes this work: `die` inside install_firewall exits
    # the subshell rather than the script, so control comes back here and we get
    # to choose the end state rather than stopping wherever the failure landed.
    if ! ( install_firewall ); then
        seal_firewall
        die "init failed - the container is sealed and has no egress. Fix the cause above and re-run --init."
    fi
}

case "$MODE" in
    init)   do_init ;;
    reload) do_reload ;;
    list)   do_list ;;
esac
