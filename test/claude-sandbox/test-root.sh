#!/bin/bash
#
# Privileged half of the claude-sandbox smoke test.
#
# Runs as root via `docker exec -u 0`, not through the devcontainer CLI. These
# checks have to tear the firewall down and put it back, and `node` deliberately
# cannot do that — choosing the allow-list via --file is refused through sudo,
# which is what test.sh asserts. Driving it as real root keeps that restriction
# intact while still exercising the failure paths end to end.
#
set -e

# shellcheck source=../test-utils/test-utils.sh
source test-utils.sh

# --- Fail closed on a broken init ------------------------------------------
# `--init` flushes the live rules before it is in a position to install the
# default-deny policy. A failure inside that window must leave the container
# sealed, never open. This whitelist is valid JSON that dies in
# add_github_ranges — exactly where the api.github.com/meta rate-limit failure
# lands on CI.
cat > /tmp/broken-whitelist.json <<'JSON'
{"domains":[],"cidrs":[],"github_meta":{"enabled":true,"sections":["no-such-section"]}}
JSON

check "broken-init-fails" bash -c '
    ! /usr/local/bin/configure-firewall.sh --init --file /tmp/broken-whitelist.json \
        >/dev/null 2>&1'

check "broken-init-seals-egress" bash -c '
    ! curl -sS --connect-timeout 5 --max-time 10 https://api.github.com/zen >/dev/null 2>&1'
check "broken-init-blocks-example" bash -c '
    ! curl -sS --connect-timeout 5 --max-time 10 https://example.com >/dev/null 2>&1'

# --- The warning is the only signal when init never ran --------------------
# Checked as `node`, since that is who gets the shell.
check "warns-in-bash" bash -c '
    su node -c "bash -ic true" 2>&1 | grep -q "firewall is NOT active"'
check "warns-in-zsh" bash -c '
    su node -c "zsh -ic true" 2>&1 | grep -q "firewall is NOT active"'

# --- Sealing has to stay recoverable ---------------------------------------
# Rebuilding needs egress of its own (DNS, and api.github.com for the meta
# ranges). If sealing left the policies closed to the rebuild itself, a single
# transient failure would strand the container for good.
check "reinit-restores-firewall" bash -c '
    /usr/local/bin/configure-firewall.sh --init >/dev/null 2>&1'
check "restored-allows-github" bash -c '
    curl -sS --connect-timeout 10 --max-time 20 https://api.github.com/zen >/dev/null'
check "restored-blocks-example" bash -c '
    ! curl -sS --connect-timeout 5 --max-time 10 https://example.com >/dev/null 2>&1'
check "no-warning-when-healthy" bash -c '
    ! su node -c "bash -ic true" 2>&1 | grep -q "NOT active"'

# --- GitHub meta: retry, then fall back ------------------------------------
# api.github.com is rate-limited per source IP and CI shares its egress, so this
# fetch fails for reasons that have nothing to do with the change under test.
#
# The fixture is built from live DNS rather than a canned file: the post-init
# verification really does curl api.github.com, so the ranges have to be ones
# that actually reach it. An unreachable META_URL then isolates the meta fetch
# without breaking anything else.
UNREACHABLE_META="https://127.0.0.1:1/meta"
META_FIXTURE=/tmp/meta-fallback.json

# The fixture has to be GitHub's real published ranges. Post-init verification
# genuinely curls api.github.com, and that name resolves to a pool — pinning one
# DNS answer passes locally and then fails when the verify picks a different IP.
#
# Prefer the copy the harness pre-fetched (authenticated, so it is always there on
# CI); fall back to fetching live, which is fine on a workstation where the rate
# limit is not contended. Built before the sealing checks below, while there is
# still egress to build it with.
FIXTURE_SOURCE=""
if jq -e '.web and .api and .git' /etc/firewall/github-meta-fallback.json >/dev/null 2>&1; then
    cp /etc/firewall/github-meta-fallback.json "$META_FIXTURE"
    FIXTURE_SOURCE="pre-fetched fallback"
elif curl -sSf --connect-timeout 10 --max-time 30 "https://api.github.com/meta" > "$META_FIXTURE" 2>/dev/null \
     && jq -e '.web and .api and .git' "$META_FIXTURE" >/dev/null 2>&1; then
    FIXTURE_SOURCE="live api.github.com"
fi
echo "meta fixture source: ${FIXTURE_SOURCE:-none}"

# No fallback available: retries, reports the attempts, and seals rather than
# coming up without the ranges it was told to install.
check "meta-fetch-retries-then-fails" bash -c "
    out=\$(FIREWALL_GITHUB_META_URL='$UNREACHABLE_META' \
          FIREWALL_GITHUB_META_FALLBACK=/nonexistent.json \
          /usr/local/bin/configure-firewall.sh --init 2>&1) || true
    echo \"\$out\" | grep -q 'attempt 3/3'"
check "meta-failure-still-seals" bash -c '
    ! curl -sS --connect-timeout 5 --max-time 10 https://example.com >/dev/null 2>&1'

# Fallback available: the same failure is survivable, and says so.
#
# Captured before grepping, never piped straight into `grep -q`: that exits on the
# first match and SIGPIPEs the script mid-configuration. The script now ignores
# SIGPIPE, but a test that half-kills the thing it is measuring would be lying
# either way. The exit status is checked too — a warning alone proves nothing.
if [ -n "$FIXTURE_SOURCE" ]; then
    check "meta-falls-back-when-unreachable" bash -c "
        out=\$(FIREWALL_GITHUB_META_URL='$UNREACHABLE_META' \
               FIREWALL_GITHUB_META_FALLBACK='$META_FIXTURE' \
               /usr/local/bin/configure-firewall.sh --init 2>&1)
        rc=\$?
        [ \$rc -eq 0 ] || { echo \"\$out\" | tail -5; exit 1; }
        echo \"\$out\" | grep -q 'may be stale'"
    check "fallback-reaches-github" bash -c '
        curl -sS --connect-timeout 10 --max-time 20 https://api.github.com/zen >/dev/null'
    check "fallback-still-blocks-example" bash -c '
        ! curl -sS --connect-timeout 5 --max-time 10 https://example.com >/dev/null 2>&1'
else
    # Loud on purpose: silently skipping these would read as "the fallback works".
    echoStderr "⚠️  SKIPPED fallback checks: no usable GitHub meta fixture."
    echoStderr "   Needs /etc/firewall/github-meta-fallback.json or a reachable api.github.com."
fi

# Regression: a reader that closes the pipe early used to SIGPIPE the script
# mid-configuration, after the flush and before the default-deny policy — leaving
# the container wide open. "Using whitelist" is printed early on purpose, so
# grep -q exits almost immediately and the pipe closes at the worst moment.
#
# Either outcome is acceptable (complete, or fail and seal); being reachable is
# not, and that is what this asserts.
check "sigpipe-mid-init-never-opens-egress" bash -c '
    /usr/local/bin/configure-firewall.sh --init 2>&1 | grep -q "Using whitelist" || true
    ! curl -sS --connect-timeout 5 --max-time 10 https://example.com >/dev/null 2>&1'

# Leave the container on the real ranges.
check "final-reinit" bash -c '
    /usr/local/bin/configure-firewall.sh --init >/dev/null 2>&1'
check "final-state-allows-github" bash -c '
    curl -sS --connect-timeout 10 --max-time 20 https://api.github.com/zen >/dev/null'
check "final-state-blocks-example" bash -c '
    ! curl -sS --connect-timeout 5 --max-time 10 https://example.com >/dev/null 2>&1'

reportResults
