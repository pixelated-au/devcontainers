
# Claude Sandbox (claude-sandbox)

Runs Claude Code inside a Docker sandbox with a default-deny outbound firewall. This isn't a general-purpose development container; it exists to give Claude a contained environment where it can only reach an explicit allow-list of hosts.

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| timezone | IANA timezone for the container. The host's $TZ takes precedence when it is set. | string | Australia/Melbourne |
| workspaceFolder | Folder name to mount this project under /workspaces inside the container. Claude keys its session history by path, so projects sharing a name share their history in the common config volume. The default resolves to the name of your project folder on the host. | string | ${localWorkspaceFolderBasename} |

## What this is

A container for running Claude Code with its network access fenced in. It is not
meant to be a general-purpose dev container — there is no language toolchain here
beyond Node and Bun, and no attempt to be a comfortable place to hand-write code.

The container starts with `iptables -P OUTPUT DROP` and an `ipset` allow-list built
from `.devcontainer/firewall/firewall-whitelist-domains.json`. Anything not on that
list is rejected outright, so Claude can install packages and talk to the Anthropic
API but cannot reach an arbitrary host you did not sanction.

`configure-firewall.sh` refuses to install an empty allow-list, and verifies after
setup that `example.com` is unreachable and (when GitHub ranges are enabled) that
`api.github.com` is. A misconfigured whitelist fails the container start rather than
silently leaving the sandbox wide open.

`--init` fails closed. It has to flush the live rules before it is in a position to
install the default-deny policy, so any failure in that window — an unreachable
GitHub meta endpoint, an unresolvable domain under `--strict` — would otherwise
leave the container with no firewall at all. Instead the container is sealed:
default-deny on every chain, loopback only, no allow-list. Egress stays broken
until a `--init` succeeds, which is the safe direction to be wrong in.

That still leaves one gap, because it only helps if the script runs at all. If
`postStartCommand` never fires — the stale-container trap described below is the
usual cause — there is no firewall and nothing has failed loudly. So every
interactive shell checks for the allow-list and prints a red warning when it is
missing. If you see that warning, treat the container as unsandboxed.

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

That last one is rate-limited to 60 requests an hour **per source IP**, unauthenticated,
and a container that cannot fetch it seals itself rather than come up without the
ranges. On a workstation that limit is unlikely to bother you; on shared egress —
CI runners especially — it is routinely already spent by somebody else, and roughly
half of our own CI runs used to fail on it.

The fetch retries three times with backoff, and reports a 403/429 as the rate limit
it almost certainly is rather than as a broken whitelist. If it still cannot be had,
a pre-fetched copy of the response at `firewall/github-meta-fallback.json` is used
instead, with a warning that the ranges may be stale. Populate it from somewhere with
a higher limit — an authenticated request is 1000/hour:

```bash
curl -sSf -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/meta \
  > .devcontainer/firewall/github-meta-fallback.json
```

The live endpoint is always tried first, so the file only matters when the fetch
fails. No token is passed into the container: the fetch runs on the host, and a
token inside a sandbox whose allow-list already includes GitHub would be worth more
to an attacker than anything else in there.

## Keeping projects apart

Claude's own config — including your login — lives in one named volume shared by
every container built from this template. That is deliberate for credentials, but
it also means Claude's session history is shared, and Claude keys that history by
the path it is run from. If every project mounted at the same `/workspace`, they
would all write into the same bucket and `claude --continue` in one project would
offer you another project's sessions.

So the project is mounted at `/workspaces/<name>`, where `<name>` comes from the
`workspaceFolder` template option. Its default, `${localWorkspaceFolderBasename}`,
resolves to the name of your project folder on the host, which is unique often
enough to be a sane default — but two checkouts both called `api` would still
collide. Set it explicitly when that matters:

```bash
devcontainer templates apply \
  --workspace-folder . \
  --template-id ghcr.io/pixelated-au/devcontainers/claude-sandbox:latest \
  --template-args '{"workspaceFolder":"acme-api"}'
```

Note that the CLI does not prompt: options you leave out of `--template-args` take
their default silently. The prompt only appears in editors that surface template
options in their UI.

Two consequences worth knowing:

- The value is baked into `devcontainer.json` when the template is applied, so
  changing it later means editing `workspaceMount` and `workspaceFolder` by hand
  (or re-applying the template) — and then **recreating the container**, not just
  restarting it:

  ```bash
  devcontainer up --workspace-folder . --remove-existing-container
  ```

  `devcontainer up` on its own reuses any container that matches the workspace,
  and a changed mount is not enough to make it rebuild. The old container keeps
  its old bind target, the CLI then execs with a working directory that does not
  exist there, and you get `chdir to cwd (...) failed: no such file or directory`
  with exit 127. In VS Code, *Dev Containers: Rebuild Container* does the same
  thing. Nothing is wrong with your config when this happens.
- Sessions recorded before this change live under `~/.claude/projects/-workspace`
  in the shared volume. Moving to a namespaced path leaves them there — they are
  not lost, but `--continue` will no longer find them.

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

- Your workspace is bind-mounted read-write at `/workspaces/<name>`. Anything Claude
  does there lands on your real filesystem.
- Allow-listing a host allows everything on that host. `github_meta` permits any
  GitHub repo, not just yours — including pushes.
- DNS is unrestricted (UDP/53 is allowed before the default-deny rule), so hostname
  lookups themselves are an unmonitored side channel.
- Outbound SSH on port 22 is allowed to any host.
- `node` may run `configure-firewall.sh` as root via a narrow sudoers rule and
  nothing else. That script is the sandbox's trusted boundary — treat edits to it
  the way you'd treat edits to a sudoers file. It refuses `--file` (and
  `FIREWALL_WHITELIST_FILE`) when reached through sudo, because otherwise `node`
  could point the firewall at a whitelist it wrote itself and authorise anything;
  the refusal happens before any rule is touched. Real root — `docker exec -u 0`,
  which is how `firewall-ctl.sh` normally drives it — keeps both.


---

_Note: This file was auto-generated from the [devcontainer-template.json](https://github.com/pixelated-au/devcontainers/blob/main/src/claude-sandbox/devcontainer-template.json).  Add additional notes to a `NOTES.md`._
