#!/usr/bin/env bash
#
# setup.sh
# One-time (re-runnable) dependency installer for the bitstack bitcoind +
# electrs docker-swarm stack. Ubuntu 26.04 (resolute).
#
#   1) apt prerequisites
#   2) symlink bitstack.sh to /usr/local/bin/bitstack (bare 'bitstack' command)
#   3) docker-ce, and adds the invoking user to the docker group if needed
#
# Building the local/bitcoind, local/electrs, and local/tor images
# (GPG+SHA256 verified Bitcoin Core source) is 'bitstack up's job, not this
# script's -- it builds each on first run and skips the build on later runs
# once the tagged image already exists. Installing Sparrow (host GUI wallet,
# reading sparrow-config.json from its own directory) is 'bitstack sparrow's
# job, likewise on first run only. Initializing the single-node swarm
# ('docker stack deploy' needs one) is bitstack.sh's job too, on every
# invocation (idempotent) -- see bitstack.sh's own header comment for why
# that isn't done here.
#
# Run as your regular login user (needs sudo). Not root. Deploying/stopping/resetting the
# stack itself is bitstack.sh's job (bitstack up / down / reset) -- this script
# only installs dependencies.

set -euo pipefail

# readlink -f matches bitstack.sh's SCRIPT_DIR resolution (needed there to
# see through the /usr/local/bin/bitstack symlink this script creates); kept
# the same here so both entry points resolve identically if ever symlinked.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
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

  # ---------------------------------------------------------------- prereqs
  info "Installing prerequisites"
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg wget tar coreutils jq

  # ------------------------------------------------------------- bitstack command
  info "Wiring up 'bitstack' command"
  sudo ln -sf "${SCRIPT_DIR}/bitstack.sh" /usr/local/bin/bitstack

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
  else
    info "docker already present, skipping install"
  fi

  # Group membership is checked independently of install (docker may already
  # be present -- e.g. a re-run, or installed by someone else -- while the
  # invoking user still isn't in the group). bitstack.sh runs docker bare, no
  # sudo (see bitstack_require_docker_group), so this IS required for
  # bitstack to work -- but a membership added just now is stale in THIS
  # login session (the kernel only reads group membership at login), so tell
  # the human explicitly rather than leaving a silent trap for their first
  # 'bitstack' command.
  local docker_group_added=0
  if ! id -nG "${BITSTACK_NODE_USER}" | grep -qw docker; then
    info "Adding ${BITSTACK_NODE_USER} to the docker group"
    sudo usermod -aG docker "${BITSTACK_NODE_USER}"
    docker_group_added=1
  fi

  ok "Setup complete."
  cat <<INFO

Next:    bitstack up        deploy the bitcoind + electrs stack
Wallet:  bitstack sparrow   installs Sparrow on first run, then launches it

INFO

  if (( docker_group_added )); then
    warn "Added ${BITSTACK_NODE_USER} to the docker group -- this login session doesn't see it yet."
    warn "Log out and log back in, or run 'newgrp docker', before using 'docker' or 'bitstack' commands."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
