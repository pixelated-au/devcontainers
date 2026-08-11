#!/bin/bash
#
# Applies a template the way `devcontainer templates apply` would (substituting
# each option's default), then brings the resulting container up.
#
TEMPLATE_ID="$1"

set -e

shopt -s dotglob

SRC_DIR="/tmp/${TEMPLATE_ID}"
rm -rf "${SRC_DIR}"
cp -R "src/${TEMPLATE_ID}" "${SRC_DIR}"

pushd "${SRC_DIR}"

# Configure templates only if `devcontainer-template.json` contains the `options` property.
OPTION_PROPERTY=( $(jq -r '.options' devcontainer-template.json) )

if [ "${OPTION_PROPERTY}" != "" ] && [ "${OPTION_PROPERTY}" != "null" ] ; then
    OPTIONS=( $(jq -r '.options | keys[]' devcontainer-template.json) )

    if [ "${OPTIONS[0]}" != "" ] && [ "${OPTIONS[0]}" != "null" ] ; then
        echo "(!) Configuring template options for '${TEMPLATE_ID}'"
        for OPTION in "${OPTIONS[@]}"
        do
            OPTION_KEY="\${templateOption:$OPTION}"
            OPTION_VALUE=$(jq -r ".options | .${OPTION} | .default" devcontainer-template.json)

            if [ "${OPTION_VALUE}" = "" ] || [ "${OPTION_VALUE}" = "null" ] ; then
                echo "Template '${TEMPLATE_ID}' is missing a default value for option '${OPTION}'"
                exit 1
            fi

            echo "(!) Replacing '${OPTION_KEY}' with '${OPTION_VALUE}'"
            # perl rather than `sed -i`: the latter needs an argument on BSD/macOS
            # and must not have one on GNU, and this script is meant to be runnable
            # locally as well as in CI. \Q..\E also removes all the escaping
            # gymnastics a sed expression would need around the option value.
            find ./ -type f -print0 \
                | OPTION_KEY="${OPTION_KEY}" OPTION_VALUE="${OPTION_VALUE}" \
                  xargs -0 perl -pi -e 's/\Q$ENV{OPTION_KEY}\E/$ENV{OPTION_VALUE}/g'
        done
    fi
fi

popd

TEST_DIR="test/${TEMPLATE_ID}"
if [ -d "${TEST_DIR}" ] ; then
    echo "(*) Copying test folder"
    DEST_DIR="${SRC_DIR}/test-project"
    mkdir -p ${DEST_DIR}
    cp -Rp ${TEST_DIR}/* ${DEST_DIR}
    cp -Rp test/test-utils/* ${DEST_DIR}
fi

# Pre-fetch GitHub's IP ranges from the runner, authenticated.
#
# The container fetches these itself at start-up, but unauthenticated and from a
# shared runner IP, where the 60/hour limit is routinely already spent by someone
# else. That made roughly half of CI runs fail on a rate limit that has nothing to
# do with the change under test. The token here lifts the limit to 1000/hour, and
# the container still tries the live endpoint first — this is only its fallback.
FIREWALL_DIR="${SRC_DIR}/.devcontainer/firewall"
if [ -n "${GITHUB_TOKEN:-}" ] && [ -d "${FIREWALL_DIR}" ] ; then
    echo "(*) Pre-fetching GitHub meta ranges as a fallback"
    if curl -sSf --connect-timeout 10 --max-time 30 \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            https://api.github.com/meta > "${FIREWALL_DIR}/github-meta-fallback.json" ; then
        echo "(*) Fallback written"
    else
        # Not fatal: the container will still try the live endpoint.
        echo "(!) Could not pre-fetch GitHub meta ranges; continuing without a fallback"
        rm -f "${FIREWALL_DIR}/github-meta-fallback.json"
    fi
fi

export DOCKER_BUILDKIT=1
echo "(*) Installing @devcontainer/cli"
npm install -g @devcontainers/cli

echo "Building Dev Container"
ID_LABEL="test-container=${TEMPLATE_ID}"
devcontainer up --id-label ${ID_LABEL} --workspace-folder "${SRC_DIR}"
