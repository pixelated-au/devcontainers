#!/bin/bash
TEMPLATE_ID="$1"
set -e

SRC_DIR="/tmp/${TEMPLATE_ID}"
echo "Running Smoke Test"

ID_LABEL="test-container=${TEMPLATE_ID}"

# Invoked as `bash ./test.sh` rather than `./test.sh`: the upstream starter chmods
# the script with sudo first, which this image refuses on purpose — its sudoers rule
# is scoped to configure-firewall.sh alone.
devcontainer exec --workspace-folder "${SRC_DIR}" --id-label "${ID_LABEL}" \
    /bin/bash -c 'set -e && cd test-project && bash ./test.sh'

# Clean up
docker rm -f $(docker container ls -f "label=${ID_LABEL}" -q)
rm -rf "${SRC_DIR}"
