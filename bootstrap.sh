#!/usr/bin/env bash
# Lightweight bootstrap - downloads the repo and runs deploy or repair
#
# Deploy:  bash -c "$(wget -qLO - https://raw.githubusercontent.com/jnguyen1990/proxmox-scripts/main/bootstrap.sh)"
# Repair:  bash -c "$(wget -qLO - https://raw.githubusercontent.com/jnguyen1990/proxmox-scripts/main/bootstrap.sh)" _ repair

set -euo pipefail

REPO="https://github.com/jnguyen1990/proxmox-scripts.git"
DIR="/tmp/proxmox-scripts"
COMMAND="${1:-deploy}"

echo "==> Downloading proxmox-scripts..."

# Ensure git is available
if ! command -v git &>/dev/null; then
  echo "==> Installing git..."
  apt-get update -qq && apt-get install -y -qq git
fi

# Fresh clone every time to get latest
rm -rf "${DIR}"
git clone --depth 1 "${REPO}" "${DIR}"

echo "==> Starting ${COMMAND}..."
exec bash "${DIR}/${COMMAND}"
