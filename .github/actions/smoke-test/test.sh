#!/bin/bash
TEMPLATE_ID="$1"
set -e

SRC_DIR="/tmp/${TEMPLATE_ID}"
echo "Running Smoke Test"

ID_LABEL="test-container=${TEMPLATE_ID}"

# Invoked as `bash ./test.sh` rather than `./test.sh`: the upstream starter chmods
# the script with sudo first, which this image refuses on purpose — its sudoers rule
# is scoped to configure-firewall.sh alone.
# COLORTERM stands in for a true-colour capable client. Runners do not set it, and
# nothing forwards it into a container unless the template asks for it — so without
# this the passthrough could never be exercised here.
COLORTERM=truecolor devcontainer exec --workspace-folder "${SRC_DIR}" --id-label "${ID_LABEL}" \
    /bin/bash -c 'set -e && cd test-project && bash ./test.sh'

# Privileged half, when the template ships one.
#
# Some checks have to break the firewall and rebuild it, which the container's
# unprivileged user is deliberately not allowed to do — that restriction is
# itself under test above. Driving those as real root goes around the
# devcontainer CLI, since it always execs as the remote user.
if [ -f "${SRC_DIR}/test-project/test-root.sh" ]; then
    echo "Running privileged smoke test"
    CONTAINER_ID=$(docker container ls -f "label=${ID_LABEL}" -q | head -1)
    [ -n "${CONTAINER_ID}" ] || { echo "no running container for ${ID_LABEL}"; exit 1; }
    docker exec -u 0 "${CONTAINER_ID}" /bin/bash -c '
        set -e
        dir=$(ls -d /workspaces/*/test-project 2>/dev/null | head -1)
        [ -n "$dir" ] || { echo "test-project not found in container"; exit 1; }
        cd "$dir" && bash ./test-root.sh'
fi

# Clean up
docker rm -f $(docker container ls -f "label=${ID_LABEL}" -q)
rm -rf "${SRC_DIR}"
