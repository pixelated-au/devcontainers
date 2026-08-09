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

# Owned by `node`, so `bun upgrade` doesn't need root.
check "bun-owned-by-node" bash -c '[ -O /home/node/.bun/bin/bun ]'

# --- Environment -----------------------------------------------------------
check "runs-as-node"        bash -c '[ "$(whoami)" = "node" ]'
check "claude-config-dir"   bash -c '[ "$CLAUDE_CONFIG_DIR" = "/home/node/.claude" ]'
check "devcontainer-flag"   bash -c '[ "$DEVCONTAINER" = "true" ]'
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

# The reason bun.com is on the allow-list. Version tags come from GitHub and the
# installer from bun.com, so this fails if either is fenced off. On an
# already-current container this upgrades nothing; the container is disposable
# either way.
check "bun-can-upgrade" bash -c '
    bun upgrade 2>&1 | tee /dev/stderr \
        | grep -qE "already on the latest version|Upgraded|Installed"'

reportResults
