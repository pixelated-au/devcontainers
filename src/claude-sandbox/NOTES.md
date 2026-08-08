## What this is

A container for running Claude Code with its network access fenced in. It is not
meant to be a general-purpose dev container — there is no language toolchain here
beyond Node, and no attempt to be a comfortable place to hand-write code.

The container starts with `iptables -P OUTPUT DROP` and an `ipset` allow-list built
from `.devcontainer/firewall/firewall-whitelist-domains.json`. Anything not on that
list is rejected outright, so Claude can install packages and talk to the Anthropic
API but cannot reach an arbitrary host you did not sanction.

`configure-firewall.sh` refuses to install an empty allow-list, and verifies after
setup that `example.com` is unreachable and (when GitHub ranges are enabled) that
`api.github.com` is. A misconfigured whitelist fails the container start rather than
silently leaving the sandbox wide open.

## Requirements

- Docker with `NET_ADMIN` and `NET_RAW` available to the container. Rootless Docker
  and most hosted/remote container runtimes do not grant these; the container will
  start but `postStartCommand` will fail.
- macOS or Linux host. The `initializeCommand` uses `mkdir -p`, so on Windows run
  this from WSL rather than native Docker Desktop + cmd.exe.

## Editing the allow-list

The whitelist is bind-mounted read-only at `/etc/firewall`, so host edits are visible
to the container immediately — but iptables/ipset only re-read it when told to.
`firewall-ctl.sh` (host-side) drives that:

```bash
# from your project root
./.devcontainer/firewall-ctl.sh add pypi.org files.pythonhosted.org
./.devcontainer/firewall-ctl.sh test https://pypi.org https://example.com
./.devcontainer/firewall-ctl.sh list
./.devcontainer/firewall-ctl.sh status
./.devcontainer/firewall-ctl.sh watch      # reload on every save
```

`add` and `remove` edit the JSON and reload in one step. Note that removing a domain
does not kill connections already established to it — pass `--flush-conntrack` if you
need it cut immediately.

Three shapes of entry are supported in the JSON:

- `domains` — resolved via DNS at reload time. A domain behind rotating IPs (most
  CDNs) may need a re-run when its records change; this is the main sharp edge.
- `cidrs` — static ranges, never re-resolved.
- `github_meta` — pulls current GitHub ranges from `api.github.com/meta`. Set
  `enabled: false` if you don't want the container talking to GitHub at all.

## Host configuration passed through

Your host slash-commands and subagents are mounted read-only:

| Host path | Container path |
| --- | --- |
| `~/.claude/commands` | `/home/node/.claude/commands` |
| `~/.claude/agents` | `/home/node/.claude/agents` |

Set `CLAUDE_HOST_CONFIG_DIR` on the host to use a directory other than `.claude`.
The value is interpreted relative to `$HOME` — `CLAUDE_HOST_CONFIG_DIR=.claude-work`
mounts `~/.claude-work/commands`. (Dev Containers cannot nest one `localEnv`
substitution inside another's default, which is why this is a sub-path rather than a
full path.) `initializeCommand` creates the directories if they don't exist, so an
unset or unused config dir won't break container start.

Claude's own config — including your login — lives in the named volume
`claude-code-devcontainer-config`, shared by every container built from this
template. You authenticate once, not once per project. Delete the volume to log out
everywhere:

```bash
docker volume rm claude-code-devcontainer-config
```

## What this does not protect against

Be clear-eyed about the boundary. The firewall constrains *where* the container can
send bytes; it does nothing about what happens to the code inside it.

- Your workspace is bind-mounted read-write at `/workspace`. Anything Claude does
  there lands on your real filesystem.
- Allow-listing a host allows everything on that host. `github_meta` permits any
  GitHub repo, not just yours — including pushes.
- DNS is unrestricted (UDP/53 is allowed before the default-deny rule), so hostname
  lookups themselves are an unmonitored side channel.
- Outbound SSH on port 22 is allowed to any host.
- `node` may run `configure-firewall.sh` as root via a narrow sudoers rule and
  nothing else. That script is the sandbox's trusted boundary — treat edits to it
  the way you'd treat edits to a sudoers file.
