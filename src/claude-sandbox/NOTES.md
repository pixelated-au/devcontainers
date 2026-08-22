## What this is

A container for running Claude Code with its network access fenced in. It is not
meant to be a general-purpose dev container — the toolchain stops at Node, Bun and
PHP, and there is no attempt to make this a comfortable place to hand-write code.

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
interactive shell runs `configure-firewall.sh --status` and speaks up:

- **red, "NOT active"** — the firewall is not enforcing and egress is unrestricted.
  Treat the container as unsandboxed.
- **yellow, "sealed"** — closed but not working: an `--init` failed and nothing can
  get out. Safe, just unusable until you re-run it.

`--status` checks what is actually enforced — the `OUTPUT` policy, the allow-list
rule, a non-empty ipset, and the IPv6 policy — rather than whether the ipset merely
exists. Those are not the same question: flush the rules and set the policy back to
`ACCEPT` and the set is still sitting there, which reads as healthy while every
destination on the internet is reachable. Exit codes are `0` enforcing, `3` sealed,
`1` open, so scripts can tell the three apart.

## IPv6

IPv6 is denied outright, and that is deliberate rather than an omission. Every rule
here is an `iptables` rule, which IPv6 traffic never touches, and the allow-list is
IPv4-only by construction — GitHub's published IPv6 ranges are discarded, and
domains are resolved via `A` records only. So there is no such thing as an allowed
IPv6 destination, and leaving the family unfiltered would mean the entire allow-list
could be walked around by resolving `AAAA` instead of `A` on any host where Docker
has IPv6 enabled or the network is dual-stack.

If the container has an IPv6 stack that `ip6tables` cannot be made to filter,
`--init` fails rather than continuing.

## PHP

PHP and Composer come from `ghcr.io/devcontainers/features/php:1`. The reference is
pinned to the feature's major version, not to a PHP version; which PHP you get is the
`phpVersion` template option, defaulting to `latest` — so a rebuild tracks whatever
upstream calls current unless you pin it:

```bash
devcontainer templates apply \
  --workspace-folder . \
  --template-id ghcr.io/pixelated-au/devcontainers/claude-sandbox:latest \
  --template-args '{"phpVersion":"8.3"}'
```

The value is baked into `devcontainer.json` at apply time, so changing it later means
editing the feature's `version` there and rebuilding. Free-form values are allowed —
the proposals are only suggestions — but the feature compiles from source, so a
version it cannot fetch fails the image build rather than falling back to anything.

PHP itself is not optional. Template options are plain text substitution with no
conditionals, so a boolean cannot add or remove a `features` entry; the only
file-level escape hatch, `optionalPaths`, cannot reach inside `devcontainer.json`.
If you want this template without PHP, drop the feature entry by hand after applying.

That compile makes a cold build noticeably slower — cached layers make it a one-off,
but expect it again after any change that invalidates the image. It runs at build
time, before the firewall exists, so the sources it fetches (php.net, getcomposer.org,
xdebug.org) do not need allow-listing.

Composer at *runtime* does, and it takes three hosts rather than the one you would
guess. `repo.packagist.org` serves the metadata — the allow-list resolves exact
names, not wildcards, so `packagist.org` on its own does not cover it — and the
package zips come from `codeload.github.com`, which is *not* in any `github_meta`
section, so allowing GitHub is not enough. All three are in the whitelist. A private
Composer repository or a Satis mirror needs adding by hand.

`repo.packagist.org` is also what forced the DNS pinning described under *Editing
the allow-list*: it sits behind a CDN that answers with a different address on
almost every query, so allow-listing the address seen at start-up was a coin toss
by the time Composer connected.

Xdebug comes with the feature, configured upstream to start step debugging on every
request. With nothing listening on port 9003 that puts `Could not connect to debugging
client` on stderr for *every* `php` invocation — noise in the output of the one user
this container has. `XDEBUG_MODE=off` is set in `containerEnv` to stop that, and it is
overridable per command:

```bash
XDEBUG_MODE=coverage vendor/bin/phpunit
XDEBUG_MODE=debug php script.php   # with a listener on 9003
```

## Docker

By default there is no Docker in the sandbox in any meaningful sense: the CLI is
installed, and it has nothing to talk to. Point the `dockerSocket` template option at
the host's socket and it does — Claude can then drive containers you are already
running on the host, which is the point of the thing:

```bash
devcontainer templates apply \
  --workspace-folder . \
  --template-id ghcr.io/pixelated-au/devcontainers/claude-sandbox:latest \
  --template-args '{"dockerSocket":"/var/run/docker.sock"}'
```

`/var/run/docker.sock` is right for Docker Desktop on macOS and for a standard Linux
install. Rootless Docker puts it under `$XDG_RUNTIME_DIR`, and the option value is
substituted verbatim, so `${localEnv:XDG_RUNTIME_DIR}/docker.sock` survives into
`devcontainer.json` and is resolved at container start rather than at apply time.
Like every template option it is baked in at apply time; changing it later means
editing the mount in `devcontainer.json` and rebuilding.

### How it is made optional

`ghcr.io/devcontainers/features/docker-outside-of-docker` declares a mount of
`/var/run/docker.sock` in the feature itself, so merely listing the feature hands
over the socket. Setting the feature to `false` does not help — the merged
configuration still carries the mount — and, as noted under *PHP*, template options
cannot add or remove a `features` entry at all.

What does work is that the devcontainer CLI de-duplicates mounts by target and lets
`devcontainer.json` win. A mount on `/var/run/docker-host.sock` in the `mounts` array
therefore replaces the feature's, and the template option chooses its source. The
feature is always present; what it can reach is not.

`/dev/null` is the off value because it has to be a path that exists on the host —
Docker would otherwise create a directory there — and because a character device is
harmless. The feature's entrypoint proxies it like any other socket and every
connection fails, so `docker ps` reports that it cannot reach a daemon, which is the
truth.

### containerUser

Turning the feature on requires `"containerUser": "root"`, and the template sets it
whether or not a socket is mounted. The feature's entrypoint is what makes the socket
usable by `node`: the host socket arrives root-owned and mode 0660, so the entrypoint
socat-proxies it to one `node` can open. That runs as PID 1's user, under `set -e`,
over calls that need root — as `node` it would hit the narrow sudoers rule, fail, and
take container start down with it.

`remoteUser` stays `node`, so shells, `devcontainer exec` and the lifecycle commands
are unchanged, and the sudoers rule still bounds what the agent can do as root. Only
PID 1 — a `sleep` loop — is root.

### What works from in here, and what does not

Anything that operates on containers that are already running: `docker compose exec`,
`docker exec`, `docker logs`, `docker ps`, and the Laravel Sail commands built on them
(`sail artisan`, `sail composer`, `sail test`, `sail npm`, `sail mysql`). These run
the command *inside* the target container, so the sandbox does not even need a network
route to it.

Builds and lifecycle commands — `docker compose up`, `down`, `build`, `sail up` — do
not, and should be run from the host. The daemon is on the host, so a relative path in
a compose file resolves against the host filesystem: a bind mount written as
`.:/var/www/html` becomes `/workspaces/<name>` *on your machine*, which does not
exist, and Docker silently creates an empty directory and mounts that. Buildx is left
uninstalled for the same reason, so builds fail loudly rather than quietly producing
something wrong. Worse, if the project name matches, `up` will happily recreate the
containers you are actually using with those broken mounts.

Which brings up the project name. Compose derives it from the working directory's
basename, and in here that is the `workspaceFolder` template option, not the host
directory. Where the two differ, compose looks for a project that does not exist and
finds none of your containers. Pin it:

```jsonc
"containerEnv": {
  "COMPOSE_PROJECT_NAME": "the-name-the-host-uses"
}
```

### Reaching the containers over the network

Separate from the socket, and not needed for `exec`. The sandbox sits on Docker's
default bridge; a compose project gets a network of its own, on a different subnet
that the firewall does not allow. If you want Claude to open an HTTP connection to the
app, or talk to MySQL directly, it needs both a route and permission:

```bash
docker network connect <project>_<network> <sandbox-container>
```

and the network's subnet added to `cidrs` in `firewall-whitelist-domains.json`,
followed by a `firewall-ctl.sh reload`. Attaching the network through `runArgs`
instead makes it permanent, at the cost of `devcontainer up` failing whenever the
other stack is down.

### The cost

Read the last section of this document before turning any of this on. The socket is
the Docker daemon's full API and the daemon is root on the host; `docker run -v
/:/host` is a two-second escape from this container to the whole machine. Nothing in
this template constrains it — it is a Unix socket, so iptables never sees it, and a
container Claude starts gets unfiltered egress of its own. It is a deliberate trade of
the sandbox for the convenience, which is why it is off unless you ask for it.

Most of that cost is avoidable, and the next section is the recommended way in.

### The filtered socket

`.devcontainer/socket-proxy.yml` runs `wollomatic/socket-proxy` on the host between the
daemon and the container. It allows requests by HTTP method and path regexp, so the
handful of endpoints `docker compose exec` needs can be allowed while
`POST /containers/create` — the endpoint that makes `docker run -v /:/host` an escape —
stays refused. Two steps:

```bash
docker compose -f .devcontainer/socket-proxy.yml up -d

devcontainer templates apply \
  --workspace-folder . \
  --template-id ghcr.io/pixelated-au/devcontainers/claude-sandbox:latest \
  --template-args '{"dockerHost":"unix:///var/run/docker-proxy/docker.sock"}'
```

Note what is *not* in there: `dockerSocket` stays at `/dev/null`. The container never
holds the real socket at all; it holds a filtered one, and `DOCKER_HOST` points at it.

The two sides meet in a named volume, `claude-sandbox-docker-proxy`, mounted at
`/var/run/docker-proxy` in the container. That is not the obvious choice — a host
directory would be — but the proxy chmods the socket it creates, and Docker Desktop's
virtiofs answers `chmod: invalid argument` for a socket in a bind mount, which kills
the proxy on start-up with exit code 2. A named volume is a real filesystem inside the
VM and has no such problem. The socket is created 0660 root:1000, so the group is what
grants access: the compose file runs the proxy as `0:1000` because `node` is gid 1000
here. A host whose container user has a different gid needs that changed to match.

Deriving the allowlist is not guesswork and should not be. Run the proxy at
`-loglevel=debug` with `-allowGET=.*` and friends, run the commands you care about, and
read the log; the shipped list is what `docker ps`, `docker logs` and
`docker compose exec` were actually observed to send:

```
HEAD /_ping                        GET  /v1.x/containers/json
GET  /v1.x/containers/<id>/json    POST /v1.x/containers/<id>/exec
POST /v1.x/exec/<id>/start         GET  /v1.x/exec/<id>/json
```

**What this does and does not buy you.** Container creation, image pulls, and volume and
network creation are gone, and with them the two-second escape. What remains is exec,
and exec cannot be scoped by URL regexp to one project — container IDs are opaque — so
anything with access to this proxy can exec into *any* container on the host, as any
user, including a privileged one if you run one, and including this sandbox itself. It
is a large reduction in blast radius, not a boundary you should lean on.

Proxies that filter only by API section, such as `tecnativa/docker-socket-proxy`, do not
help here: `CONTAINERS=1` with `POST=1` also opens `/containers/create`, which is the
whole escape.

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

Four shapes of entry are supported in the JSON:

- `domains` — resolved via DNS at reload time, and pinned in `/etc/hosts` (below).
- `cidrs` — static ranges, never re-resolved.
- `github_meta` — pulls current GitHub ranges from `api.github.com/meta`. Set
  `enabled: false` if you don't want the container talking to GitHub at all.
- `host_ports` — TCP ports on your own machine. Unlike the three above these do not
  go into the ipset, and the difference matters: the ipset matches on destination
  address and knows nothing about ports, so allow-listing your host that way opens
  *everything* listening on it — your app on :80, MySQL on :3306, Mailpit, the lot.
  Each entry here becomes one iptables rule for that single port instead.

  The address is found by resolving `host.docker.internal`, which on Docker Desktop
  is not the default gateway: the gateway is 172.17.0.1 while the host answers on
  192.168.65.254, and only the latter is what a request to the host actually
  reaches. On plain Linux Docker the name usually does not resolve, the host *is*
  the default route, and the existing host-network rules already cover it — so the
  list is skipped with a warning rather than treated as an error.

  One wrinkle worth knowing: `reload` rebuilds the allow-list and deliberately
  leaves iptables alone, and these are iptables rules. Changing `host_ports` needs
  `./.devcontainer/firewall-ctl.sh init`.

### Why domains are pinned in /etc/hosts

An allow-list built from DNS quietly assumes a name keeps resolving to the same
address. Behind a CDN it does not. `repo.packagist.org` answers with a *different
single* A record per query, from a pool spread across unrelated networks:

```
1.1.1.1          -> 138.199.24.218
8.8.8.8          -> 156.146.56.161
9.9.9.9          -> 156.146.56.171
```

So the address allow-listed at start-up and the one Composer dials seconds later
are frequently not the same, and the connection is rejected — intermittently,
which is the worst way to meet a problem. Covering the pool with `cidrs` would
mean allow-listing most of a CDN provider's network.

Instead, every address added to the ipset is also written into `/etc/hosts`, in a
block between `# BEGIN firewall pins` and `# END firewall pins` that is rebuilt on
every `--init` and `--reload`. Nothing in the container can dial an address that
was not allow-listed, because it can no longer learn one: glibc answers from the
hosts file and never asks DNS for those names. All records are pinned, not just
the first, so clients can still fail over between allowed addresses.

Consequences worth knowing:

- A pinned address that goes unhealthy stays broken until the next reload. That is
  the staleness the ipset already had, now visible in one more place.
- Only A records are pinned, so `AAAA` for a pinned name resolves to nothing —
  which suits an allow-list that is IPv4-only by construction.
- Sealing removes the block, and a successful `--init` restores it.
- Edit the block by hand and the next reload will overwrite you. Change the
  whitelist instead.

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

## Colours

24-bit colour is advertised through `COLORTERM`, not `TERM` — `TERM=xterm-256color`
says exactly what it says — and nothing forwards `COLORTERM` into a container by
default. Output that is true-colour on the host therefore arrives quantised to 256
colours inside. `remoteEnv` passes the host's value through.

It is passed through rather than hardcoded to `truecolor`: on a terminal that cannot
do 24-bit, claiming it can turns readable output into approximated mush. If your
terminal supports true colour but does not export `COLORTERM` (some do not), set it
on the host and reconnect.

Being `remoteEnv`, this is read when you connect, not when the container is built —
editing it takes effect on the next shell, with no rebuild.

## Pasting images

Copying a screenshot and pressing ⌘V into Claude does nothing in here, and no
amount of container-side configuration will fix it. Claude Code is running in the
container; the macOS pasteboard is on the host; the Linux tools it would otherwise
reach for (`xclip`, `wl-paste`) need a display server that no devcontainer has.
The upstream request to bridge it over VS Code's IPC socket was
[closed as not planned](https://github.com/anthropics/claude-code/issues/51244),
so this is the arrangement, not a stopgap.

What does work is that Claude reads an image you give it a *path* to. So the
clipboard crosses the boundary as a file: `~/.clipdrop` on the host is mounted
read-only at `/clipdrop`, and `clip-drop.sh` writes the clipboard image there and
hands back the path it has inside the container.

```bash
# from your project root, with an image on the clipboard
./.devcontainer/clip-drop.sh          # prints /clipdrop/clip-20260817-113808.png
./.devcontainer/clip-drop.sh --copy   # puts that path on the clipboard instead
```

Pressing it with text on the clipboard is a no-op, so it is safe on a hotkey. Old
images are pruned to the most recent 50 (`--keep N`). Nothing is installed:
the pasteboard read is `osascript`, not `pngpaste`.

Binding it to a key is where terminals differ:

- **iTerm2** does it natively. Settings → Profiles → Keys, add a shortcut with the
  action **Run Coprocess**, pointing at `clip-drop.sh`. A coprocess's stdout is
  treated as keyboard input, so the path is typed straight into Claude's prompt —
  which is why the default output ends in a space. One coprocess per session.
- **Ghostty** cannot. Its key actions are a fixed set (`ghostty +list-actions`)
  with nothing that runs a command; `text:` sends static strings only. Use
  `--copy` from Raycast, Alfred or Keyboard Maestro and then ⌘V — which has the
  advantage of working identically in every terminal.
- **Hammerspoon** types it directly if you want one keystroke with no terminal
  support at all:

  ```lua
  hs.hotkey.bind({"cmd", "shift"}, "v", function()
    local out = hs.execute(os.getenv("HOME") .. "/path/to/clip-drop.sh")
    if out and out ~= "" then hs.eventtap.keyStrokes(out)
    else hs.eventtap.keyStroke({"cmd"}, "v") end
  end)
  ```

Set `CLAUDE_CLIPDROP_DIR` on the host (relative to `$HOME`, like
`CLAUDE_HOST_CONFIG_DIR`) to use a directory other than `.clipdrop`.
`initializeCommand` creates it, so a missing one cannot fail the container start.

If all you need is screenshots, there is a version of this with no script at all:
point macOS at a gitignored folder inside the workspace, which is already
bind-mounted read-write.

```bash
mkdir -p .clipdrop && echo .clipdrop/ >> .git/info/exclude
defaults write com.apple.screencapture location "$PWD/.clipdrop" && killall SystemUIServer
```

⌘⇧4 then writes into the project, and `@.clipdrop/` plus Tab completes the path
inside Claude. It does not cover an image copied out of a browser, which is what
`clip-drop.sh` is for.

## Opening files in your editor

Click a stack frame in a Vite error overlay and the tooling runs `launch-editor`,
which shells out to whatever `$LAUNCH_EDITOR` names. There is no editor in this
container to name, so `/usr/local/bin/host-editor` is installed to forward the call
to one on your machine: it takes the file, line and column `launch-editor` passes and
GETs them at `http://host.docker.internal:3334/open`.

Point your tooling at it — `LAUNCH_EDITOR=host-editor` — and run something on the
host that listens on 3334 and opens the file.

Two things it needs that it cannot do for itself, and both are silent when missing,
because the script sends `curl -s` to `/dev/null` and never reports a failure:

- **The firewall blocks the host by default.** Add the port to `host_ports` in the
  whitelist and re-run `firewall-ctl.sh init`. Nothing is opened for you: the
  template ships `host_ports` empty, because a sandbox should not punch a hole in
  itself on the assumption you wanted one.
- **The path it sends is the path in here.** `/workspaces/<name>/app/Foo.php` does
  not exist on your machine, and the mapping to the real one depends on where you
  cloned the project — so the listener on 3334 is the place to translate it. Note
  that the two are not always a simple prefix swap: the `workspaceFolder` option
  lets the folder name in here differ from the directory name on the host.

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

`~/.config` is persisted the same way, in `claude-code-devcontainer-user-config`.
That is where everything following the XDG convention writes — `gh`'s login, git
credential caches, tool state — none of which survives a rebuild otherwise, so
`gh auth login` would be a chore you repeat every time the image changes.

It is one volume shared by every container from this template, not one per project.
Convenient, and worth being deliberate about: a `gh` token in there is readable by
*any* container built from this template, and the firewall already allows GitHub, so
anything Claude does in one project can push to every repo that token can reach. If
that is more trust than you want to extend, give the project its own copy by editing
the mount to include `${devcontainerId}`:

```jsonc
"source=claude-code-devcontainer-user-config-${devcontainerId},target=/home/node/.config,type=volume",
```

The volume is seeded from the image the first time it is created and never again, so
a later image version that ships new defaults under `~/.config` will not reach a
volume you already have. Delete it to start clean:

```bash
docker volume rm claude-code-devcontainer-user-config
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
- The `~/.claude` and `~/.config` volumes are shared by every container from this
  template, so a credential written in one project is available to all of them.
- `~/.clipdrop` is a host directory outside the workspace, and everything ever
  dropped in it is readable in here. It is mounted read-only, so the container
  cannot write to it, but do not use it as a staging area for anything you would
  not hand to the agent.
- The Docker socket, if you have mounted the real one, is not a hole in the sandbox
  so much as the absence of one. It is a Unix socket, so no iptables rule applies to
  it; the daemon behind it is root on the host; and `docker run -v /:/host` reaches
  your whole filesystem from inside a container that is supposedly fenced in. Treat a
  container with the socket mounted as having the same authority as your host user.
- Going through `socket-proxy.yml` instead removes container creation and so that
  escape, but it still permits `exec` into any container on the host — the allowlist
  matches on URL, and container IDs carry no project. Exec into something privileged,
  or into this sandbox, is still reachable from there.
- `node` may run `configure-firewall.sh` as root via a narrow sudoers rule and
  nothing else. That script is the sandbox's trusted boundary — treat edits to it
  the way you'd treat edits to a sudoers file. It refuses `--file` (and
  `FIREWALL_WHITELIST_FILE`) when reached through sudo, because otherwise `node`
  could point the firewall at a whitelist it wrote itself and authorise anything;
  the refusal happens before any rule is touched. Real root — `docker exec -u 0`,
  which is how `firewall-ctl.sh` normally drives it — keeps both.
