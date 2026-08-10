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

reportResults
