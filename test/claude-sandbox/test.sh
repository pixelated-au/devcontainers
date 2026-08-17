#!/bin/bash
#
# Smoke test for the claude-sandbox template.
#
# Runs inside the built container as the `node` user, after postStartCommand has
# installed the firewall.
#
set -e

# shellcheck source=../test-utils/test-utils.sh
source test-utils.sh

# --- Tooling ---------------------------------------------------------------
check "node"          node --version
check "npm"           npm --version
check "claude"        claude --version
check "bun"           bun --version
check "bunx"          bunx --version
check "php"           php --version
check "composer"      composer --version
check "git"           git --version
check "gh"            gh --version
check "delta"         delta --version
check "zsh"           zsh --version
check "jq"            jq --version
check "ipset"         bash -c 'command -v ipset'
check "iptables"      bash -c 'command -v iptables'
check "dig"           bash -c 'command -v dig'

# `latest` is resolved at build time, so just assert it is a real semver.
check "claude-is-versioned" bash -c 'claude --version | grep -qE "[0-9]+\.[0-9]+\.[0-9]+"'
check "bun-is-versioned"    bash -c 'bun --version | grep -qE "^[0-9]+\.[0-9]+\.[0-9]+"'

# The runtime, not just the binary — bun ships its own JS engine.
check "bun-runs-js" bash -c '[ "$(bun -e "console.log(40 + 2)")" = "42" ]'

# The php feature compiles from source and puts the result behind a `current`
# symlink; a broken build can still leave a binary that refuses to run a script.
check "php-runs-script" bash -c '[ "$(php -r "echo 40 + 2;")" = "42" ]'
check "php-from-feature" bash -c '[ "$(command -v php)" = "/usr/local/php/current/bin/php" ]'

# Xdebug ships enabled for step debugging, which puts "Could not connect to
# debugging client" on stderr for every single php invocation. Silence is the
# thing under test, not the variable — an upstream default that stops needing
# XDEBUG_MODE should not fail here.
check "php-stderr-is-quiet" bash -c '[ -z "$(php -r "echo 42;" 2>&1 >/dev/null)" ]'

# Owned by `node`, so `bun upgrade` doesn't need root.
check "bun-owned-by-node" bash -c '[ -O /home/node/.bun/bin/bun ]'

# --- Environment -----------------------------------------------------------
check "runs-as-node"        bash -c '[ "$(whoami)" = "node" ]'
check "claude-config-dir"   bash -c '[ "$CLAUDE_CONFIG_DIR" = "/home/node/.claude" ]'
check "devcontainer-flag"   bash -c '[ "$DEVCONTAINER" = "true" ]'
# 24-bit colour is detected through COLORTERM, not TERM, and it is not forwarded
# into a container unless remoteEnv asks for it — without which everything renders
# quantised to 256 colours.
check "colorterm-forwarded"  bash -c '[ "$COLORTERM" = "truecolor" ]'
# This script runs from <workspaceFolder>/test-project, so the workspace root is
# one level up.
export WORKSPACE_ROOT="${PWD%/test-project}"

# Claude keys session history by the path it runs from, and the config volume is
# shared across every container from this template. A bare /workspace would pool
# every project's history into one bucket, so the mount must be namespaced.
check "workspace-is-namespaced" bash -c '
    case "$PWD" in /workspaces/?*) : ;; *) echo "cwd is $PWD"; exit 1 ;; esac'
check "workspace-not-shared-path" bash -c "[ \"\$WORKSPACE_ROOT\" != /workspace ]"

# Proves the bind mount actually landed on the namespaced path, rather than the
# directory merely existing.
check "workspace-mount-landed" bash -c '[ -f ../devcontainer-template.json ]'

# postCreateCommand resolves ${containerWorkspaceFolder}; if that substitution
# broke, git would refuse to operate on the bind-mounted repo.
check "git-safe-directory" bash -c "
    git config --global --get-all safe.directory | grep -qxF \"\$WORKSPACE_ROOT\""
check "host-commands-mount" bash -c '[ -d /home/node/.claude/commands ]'
check "host-agents-mount"   bash -c '[ -d /home/node/.claude/agents ]'

# --- Persisted ~/.config ---------------------------------------------------
# A directory that merely exists would pass a -d check and still be discarded on
# rebuild, so assert it is actually a mount.
check "user-config-is-mounted" bash -c 'mountpoint -q /home/node/.config'

# The failure mode this guards is specific: if the image has no /home/node/.config,
# Docker creates the mountpoint as root:root and node — the only user here — cannot
# write to its own config dir. `gh auth login` fails with a permission error that
# reads like a gh bug.
check "user-config-owned-by-node" bash -c '[ -O /home/node/.config ]'
check "user-config-writable" bash -c '
    f=/home/node/.config/.write-probe.$$
    touch "$f" && rm -f "$f"'

# --- Firewall configuration ------------------------------------------------
check "whitelist-mounted" bash -c '[ -f /etc/firewall/firewall-whitelist-domains.json ]'
check "whitelist-is-json" bash -c 'jq -e . /etc/firewall/firewall-whitelist-domains.json > /dev/null'
check "firewall-script"   bash -c '[ -x /usr/local/bin/configure-firewall.sh ]'

# The allow-list must exist and be non-empty, otherwise the rules below are
# passing for the wrong reason.
check "allow-list-populated" bash -c '
    entries=$(sudo -n /usr/local/bin/configure-firewall.sh --list \
        | sed -n "s/^Number of entries: //p")
    echo "allow-list entries: ${entries:-0}"
    [ "${entries:-0}" -gt 0 ]'

# --- DNS pins --------------------------------------------------------------
# The allow-list is a DNS snapshot, so a name that answers with a different
# address later is rejected however correct the whitelist is. Behind a CDN that
# is routine: repo.packagist.org hands out one address per query from a pool
# spread across unrelated networks. Every allow-listed address is therefore
# pinned in /etc/hosts, and these assert the pins are what resolution actually
# uses — not merely that the file has some lines in it.
check "host-pins-present" bash -c '
    grep -q "^# BEGIN firewall pins" /etc/hosts'

check "pinned-name-resolves-to-allowed-ip" bash -c '
    ip=$(getent ahostsv4 repo.packagist.org | head -1 | cut -d" " -f1)
    echo "repo.packagist.org -> ${ip:-<nothing>}"
    [ -n "$ip" ] &&
    sudo -n /usr/local/bin/configure-firewall.sh --list | grep -qF "$ip"'

# The pin is only worth having if it beats DNS. Nothing else in this file would
# notice a pin that exists but sits below the resolver in nsswitch order.
check "pin-wins-over-dns" bash -c '
    pinned=$(awk "/^# BEGIN firewall pins/,/^# END firewall pins/" /etc/hosts |
        awk "\$2 == \"repo.packagist.org\" {print \$1; exit}")
    resolved=$(getent ahostsv4 repo.packagist.org | head -1 | cut -d" " -f1)
    [ -n "$pinned" ] && [ "$pinned" = "$resolved" ]'

# --- Privilege boundary ----------------------------------------------------
# The sandbox is only as good as this: `node` may run the firewall script as root
# and nothing else. If plain sudo works, the container is not a sandbox.
check "sudo-is-restricted" bash -c '! sudo -n true 2>/dev/null'

# --- Egress: denied by default ---------------------------------------------
check "blocks-example.com" bash -c '
    ! curl -sS --connect-timeout 5 --max-time 10 https://example.com > /dev/null 2>&1'
check "blocks-cloudflare"  bash -c '
    ! curl -sS --connect-timeout 5 --max-time 10 https://1.1.1.1 > /dev/null 2>&1'

# --- Egress: allow-listed hosts reachable ----------------------------------
check "allows-github-api" bash -c '
    curl -sS --connect-timeout 10 --max-time 20 https://api.github.com/zen > /dev/null'
check "allows-npm" bash -c '
    curl -sS --connect-timeout 10 --max-time 20 https://registry.npmjs.org/ > /dev/null'
# No -f: the API answers an unauthenticated request with 4xx, which still proves
# the connection was allowed through.
check "allows-anthropic-api" bash -c '
    curl -sS -o /dev/null --connect-timeout 10 --max-time 20 https://api.anthropic.com/'

# bun resolves the npm registry itself rather than going through npm, so prove its
# own fetch path clears the firewall.
check "bun-installs-from-npm" bash -c '
    tmp=$(mktemp -d) && trap "rm -rf $tmp" EXIT &&
    cd "$tmp" && echo "{}" > package.json &&
    bun add is-number@7.0.0 &&
    [ -f node_modules/is-number/package.json ]'

check "allows-bun-com" bash -c '
    curl -sS -o /dev/null --connect-timeout 10 --max-time 20 https://bun.com/install'

# Composer needs three hosts, and only the first is obvious: metadata from
# repo.packagist.org (packagist.org alone does not cover it — the allow-list
# resolves exact names), then the dist zip from codeload.github.com, which is not
# in any github_meta section. A real install is the only check that catches a
# whitelist covering some of that path but not all of it.
check "composer-installs-from-packagist" bash -c '
    tmp=$(mktemp -d) && trap "rm -rf $tmp" EXIT &&
    cd "$tmp" && composer require --no-interaction --no-progress psr/log &&
    [ -f vendor/psr/log/composer.json ]'

# The reason bun.com is on the allow-list. Version tags come from GitHub and the
# installer from bun.com, so this fails if either is fenced off. On an
# already-current container this upgrades nothing; the container is disposable
# either way.
#
# bun reads its version tags from api.github.com, which is rate-limited per source
# IP — so a 403 here means GitHub declined to answer, not that the firewall blocked
# anything. Treat that as skipped and say so out loud; failing the build over
# somebody else's rate limit trains people to ignore red builds, and passing
# silently would hide a real regression.
check "bun-can-upgrade" bash -c '
    out=$(bun upgrade 2>&1)
    echo "$out"
    if echo "$out" | grep -qE "already on the latest version|Upgraded|Installed"; then
        exit 0
    fi
    if echo "$out" | grep -qiE "forbidden|rate limit|403"; then
        echo "⚠️  SKIPPED: api.github.com refused the version lookup (rate limit), not a firewall failure" >&2
        exit 0
    fi
    exit 1'

# --- Privilege boundary: choosing the allow-list ---------------------------
# `node` may run configure-firewall.sh as root. If it could also choose which
# whitelist that run reads, it could authorise any host it liked and the sandbox
# would mean nothing. These are the checks that say it cannot.
cat > /tmp/attacker-whitelist.json <<'JSON'
{"domains":["example.com"],"cidrs":[],"github_meta":{"enabled":false}}
JSON

# Asserting the message, not just the exit code: the sudoers rule lists no
# arguments, which in sudoers means *any* arguments are permitted, so it is the
# script's own guard that has to refuse this. A non-zero exit alone could just as
# easily mean the command broke for an unrelated reason.
check "sudo-rejects-file-flag" bash -c '
    sudo -n /usr/local/bin/configure-firewall.sh --init --file /tmp/attacker-whitelist.json 2>&1 \
        | grep -q "not permitted via sudo"'

# This one is stopped by sudo itself, before the script runs: setting an
# environment variable on the command line is not something the rule allows.
check "sudo-rejects-whitelist-env" bash -c '
    ! sudo -n FIREWALL_WHITELIST_FILE=/tmp/attacker-whitelist.json \
        /usr/local/bin/configure-firewall.sh --init >/dev/null 2>&1'

# Rejection must happen before anything is touched, so a refused call cannot be
# used to tear the firewall down either.
check "rejected-file-leaves-firewall-up" bash -c '
    curl -sS --connect-timeout 10 --max-time 20 https://api.github.com/zen >/dev/null'
check "rejected-file-did-not-open-egress" bash -c '
    ! curl -sS --connect-timeout 5 --max-time 10 https://example.com >/dev/null 2>&1'

# The modes node legitimately needs must still work — --status in particular, as
# every interactive shell runs it to decide whether to warn.
check "sudo-allows-list" bash -c '
    sudo -n /usr/local/bin/configure-firewall.sh --list >/dev/null'
check "sudo-allows-status" bash -c '
    sudo -n /usr/local/bin/configure-firewall.sh --status >/dev/null'

reportResults
