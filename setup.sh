#!/usr/bin/env bash
#
# setup.sh
# One-time (re-runnable) dependency installer for the bitstack bitcoind +
# electrs docker-swarm stack. Ubuntu 26.04 (resolute).
#
#   1) apt prerequisites
#   2) docker-ce + single-node swarm (post-install step 'docker stack deploy' needs)
#   3) install Sparrow (host GUI wallet), pointed at local electrs
#
# Building the local/bitcoind, local/electrs, and local/tor images
# (GPG+SHA256 verified Bitcoin Core source) is 'bitstack up's job, not this
# script's -- it builds each on first run and skips the build on later runs
# once the tagged image already exists. Reads sparrow-config.json from its
# own directory.
#
# Run as your regular login user (needs sudo). Not root. Deploying/stopping/resetting the
# stack itself is bitstack.sh's job (bitstack up / down / reset) -- this script
# only installs dependencies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BITSTACK_ROOT="${SCRIPT_DIR}"

# shellcheck source=.agentstack/scripts/lib/cli-log.sh
source "${SCRIPT_DIR}/.agentstack/scripts/lib/cli-log.sh"
AGENTSTACK_CLI_LOG_PREFIX="setup"

info()  { _as_cli_info  "$@"; }
ok()    { _as_cli_ok    "$@"; }
warn()  { _as_cli_warn  "$@"; }
err()   { _as_cli_err   "$@"; exit 1; }
debug() { _as_cli_debug "$@"; }

# shellcheck source=scripts/bitstack-common.sh
source "${SCRIPT_DIR}/scripts/bitstack-common.sh"

main() {
  local argv=()
  _as_cli_parse_global_flags argv "$@"
  (( ${#argv[@]} == 0 )) || err "setup.sh: unknown argument: ${argv[0]} (setup.sh takes no arguments other than global flags)"

  bitstack_require_node_user
  [[ "$(dpkg --print-architecture)" == amd64 ]] || err "This script assumes amd64."
  bitstack_require_siblings "${SCRIPT_DIR}"

  local node_uid node_gid
  node_uid="$(id -u "${BITSTACK_NODE_USER}")"
  node_gid="$(id -g "${BITSTACK_NODE_USER}")"

  # ---------------------------------------------------------------- prereqs
  info "Installing prerequisites"
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg wget tar coreutils jq

  # ---------------------------------------------------------------- docker-ce
  if ! command -v docker >/dev/null 2>&1; then
    info "Installing docker-ce"
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker
    sudo usermod -aG docker "${BITSTACK_NODE_USER}" || true
  else
    info "docker already present, skipping install"
  fi

  # single-node swarm (required for 'docker stack deploy', used by 'bitstack up')
  if ! bitstack_swarm_active; then
    info "Initializing swarm"
    sudo docker swarm init >/dev/null 2>&1 || sudo docker swarm init --advertise-addr 127.0.0.1 >/dev/null
  fi

  # ---------------------------------------------------------------- Sparrow (host)
  local sparrow_version
  sparrow_version="$(bitstack_latest_tag sparrowwallet/sparrow "${BITSTACK_SPARROW_FALLBACK}")"
  info "Installing Sparrow ${sparrow_version}"
  local tmp
  tmp="$(mktemp -d)"
  # expand tmp now: it's local, and set -e exiting mid-function drops
  # locals before a deferred (single-quoted) EXIT trap would see them
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" EXIT
  cd "${tmp}"

  local tarball="sparrowwallet-${sparrow_version}-x86_64.tar.gz"
  local manifest="sparrow-${sparrow_version}-manifest.txt"
  local base="https://github.com/sparrowwallet/sparrow/releases/download/${sparrow_version}"
  curl -fsSLO "${base}/${tarball}"
  curl -fsSLO "${base}/${manifest}"
  curl -fsSLO "${base}/${manifest}.asc"

  # verify craig raw's signature over the manifest, then the tarball hash
  curl -fsSL https://keybase.io/craigraw/pgp_keys.asc | gpg --import
  gpg --verify "${manifest}.asc" "${manifest}"
  sha256sum --ignore-missing -c "${manifest}"

  tar -xzf "${tarball}"        # extracts a capitalized 'Sparrow' dir
  sudo rm -rf "${BITSTACK_SPARROW_DIR}"
  sudo mv Sparrow "${BITSTACK_SPARROW_DIR}"
  sudo chown -R "${node_uid}:${node_gid}" "${BITSTACK_SPARROW_DIR}"

  # desktop launcher
  mkdir -p "${BITSTACK_NODE_HOME}/.local/share/applications"
  cat > "${BITSTACK_NODE_HOME}/.local/share/applications/sparrow.desktop" <<DESKTOP
[Desktop Entry]
Name=Sparrow
Comment=Bitcoin Wallet
Exec=${BITSTACK_SPARROW_DIR}/bin/Sparrow
Icon=${BITSTACK_SPARROW_DIR}/lib/Sparrow.png
Terminal=false
Type=Application
Categories=Utility;Finance;
DESKTOP
  chown "${node_uid}:${node_gid}" "${BITSTACK_NODE_HOME}/.local/share/applications/sparrow.desktop"

  # best-effort: point Sparrow at local electrs (won't overwrite an existing config)
  mkdir -p "${BITSTACK_NODE_HOME}/.sparrow"
  if [[ ! -f "${BITSTACK_NODE_HOME}/.sparrow/config" ]]; then
    install -o "${node_uid}" -g "${node_gid}" -m 0644 \
      "${SCRIPT_DIR}/sparrow-config.json" "${BITSTACK_NODE_HOME}/.sparrow/config"
  fi
  chown -R "${node_uid}:${node_gid}" "${BITSTACK_NODE_HOME}/.sparrow"

  ok "Setup complete."
  cat <<INFO

Next:  ./bitstack.sh up       deploy the bitcoind + electrs stack
Sparrow: ${BITSTACK_SPARROW_DIR}/bin/Sparrow   (or 'bitstack wallet')

INFO
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
