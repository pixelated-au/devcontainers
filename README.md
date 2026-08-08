# Pixelated Dev Container Templates

Dev Container Templates published to `ghcr.io/pixelated-au/devcontainers`.

## Templates

| Template | Description |
| --- | --- |
| [`claude-sandbox`](src/claude-sandbox) | Claude Code in a Docker sandbox with a default-deny outbound firewall. |

## Using a template

With the [Dev Containers CLI](https://github.com/devcontainers/cli), from your
project root:

```bash
npm install -g @devcontainers/cli    # once

devcontainer templates apply \
  --workspace-folder . \
  --template-id ghcr.io/pixelated-au/devcontainers/claude-sandbox:latest \
  --template-args '{"timezone":"Australia/Melbourne"}'
```

Then open the folder in VS Code and run **Dev Containers: Reopen in Container**.

This collection does not appear in VS Code's **Add Dev Container Configuration
Files...** picker. That list is populated from the community collection index, not
from the registry — publishing to GHCR is not enough to be listed. Getting in means
a PR against [`collection-index.yml`](https://github.com/devcontainers/devcontainers.github.io/blob/gh-pages/_data/collection-index.yml).

Applying a template copies its files into your project — it does not create a
dependency on this repo. Once applied, the config is yours to edit.

The template ships `LICENSE.md` and `THIRD-PARTY-LICENSES.md` at the project root,
which will overwrite a `LICENSE.md` you already have. Skip them with:

```bash
--omit-paths '["LICENSE.md"]'
```

## Repository layout

```
src/<template-id>/
    devcontainer-template.json   # id, version, options, metadata
    NOTES.md                     # hand-written docs, appended to the generated README
    README.md                    # generated on release; edit NOTES.md instead
    .devcontainer/               # everything copied into the user's project
test/<template-id>/test.sh       # smoke test run inside the built container
test/test-utils/                 # shared check/reportResults helpers
.github/actions/smoke-test/      # applies a template with default options, then builds it
```

## Developing

Build and test a template locally, exactly as CI does:

```bash
.github/actions/smoke-test/build.sh claude-sandbox
.github/actions/smoke-test/test.sh  claude-sandbox
```

`build.sh` copies `src/<id>` to `/tmp/<id>`, substitutes each option's **default**
value for its `${templateOption:...}` placeholder, then runs `devcontainer up`. Any
option without a default fails the build, and a placeholder that never appears in a
file is silently a no-op — so check that new options actually land where you expect.

CI runs the same two scripts on every pull request, matrixed over whichever templates
the PR touched.

## Releasing

Publishing is manual: run the **Release Dev Container Templates & Generate
Documentation** workflow from the Actions tab, on `main`.

Bump `version` in the template's `devcontainer-template.json` first. The registry
rejects a re-push of an existing version, so an unbumped release fails. Semver tags
are published for each level — `1`, `1.2`, `1.2.3`, and `latest` — so users who pin
to `:1` pick up minor releases automatically.

The workflow also regenerates each template's `README.md` from
`devcontainer-template.json` + `NOTES.md` and opens a PR with the result. Hand-editing
a generated `README.md` gets overwritten; edit `NOTES.md`.

## Licence

MIT — see [LICENSE](LICENSE). Portions are derived from Anthropic's Claude Code
devcontainer example; see
[THIRD-PARTY-LICENSES.md](src/claude-sandbox/THIRD-PARTY-LICENSES.md).
