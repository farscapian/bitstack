#!/usr/bin/env bash
# bitstack-common.sh -- shared config and helpers for setup.sh and bitstack.sh.
#
# Sourced by both entry points; not meant to be executed directly. Callers must
# set BITSTACK_ROOT (the repo root, where the sibling Dockerfiles/yml/conf and
# the .bitstack-versions state file live) before sourcing.
#
# shellcheck shell=bash

: "${BITSTACK_ROOT:?bitstack-common.sh: BITSTACK_ROOT must be set before sourcing}"

BITSTACK_NODE_USER="${BITSTACK_NODE_USER:-$(id -un)}"
BITSTACK_NODE_HOME="/home/${BITSTACK_NODE_USER}"
BITSTACK_BITCOIN_DIR="${BITSTACK_NODE_HOME}/.bitcoin"      # bind-mounted into containers
BITSTACK_STACK_NAME="btc"
BITSTACK_SPARROW_DIR="/opt/sparrow"
BITSTACK_VERSIONS_FILE="${BITSTACK_ROOT}/.bitstack-versions"

# fallbacks used if the GitHub API is unreachable
BITSTACK_BITCOIN_FALLBACK="31.1"
BITSTACK_ELECTRS_FALLBACK="v0.11.1"
BITSTACK_SPARROW_FALLBACK="2.5.3"

BITSTACK_SIBLINGS=(bitcoind.Dockerfile electrs.Dockerfile btc-stack.yml bitcoin.conf sparrow-config.json)

# Fail unless invoked as BITSTACK_NODE_USER (needs sudo for docker/apt, but must
# not run as root itself -- matches the original deploy-bitcoin-node.sh guard).
# BITSTACK_NODE_USER defaults to the invoking user; set it explicitly to pin
# node ownership to a different account.
bitstack_require_node_user() {
  [[ "${BITSTACK_NODE_USER}" != "root" ]] || {
    err "Run this as a regular user (needs sudo), not as root."
  }
  [[ "$(id -un)" == "${BITSTACK_NODE_USER}" ]] || {
    err "Run this as ${BITSTACK_NODE_USER} (needs sudo), not as $(id -un)."
  }
}

bitstack_require_siblings() {
  local dir="$1" f missing=()
  for f in "${BITSTACK_SIBLINGS[@]}"; do
    [[ -f "${dir}/${f}" ]] || missing+=("$f")
  done
  ((${#missing[@]} == 0)) || {
    err "Missing required file(s) in ${dir}: ${missing[*]}"
  }
}

# Latest release tag from a GitHub repo, or a fallback if the API is unreachable.
bitstack_latest_tag() {
  local repo="$1" fallback="$2" tag
  tag="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
        | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')" || true
  printf '%s' "${tag:-$fallback}"
}

# Load BITCOIN_VERSION / ELECTRS_VERSION written by setup.sh. Returns 1 (no
# error printed) when the state file is absent so callers can give an
# actionable message pointing at ./setup.sh.
bitstack_load_versions() {
  [[ -f "${BITSTACK_VERSIONS_FILE}" ]] || return 1
  # shellcheck source=/dev/null
  source "${BITSTACK_VERSIONS_FILE}"
  [[ -n "${BITCOIN_VERSION:-}" && -n "${ELECTRS_VERSION:-}" ]] || return 1
}

bitstack_write_versions() {
  local bitcoin_version="$1" electrs_version="$2"
  cat > "${BITSTACK_VERSIONS_FILE}" <<EOF
# Written by setup.sh -- versions of the local/bitcoind and local/electrs
# images currently built. Consumed by 'bitstack up'. Machine-local state,
# not tracked in git.
BITCOIN_VERSION=${bitcoin_version}
ELECTRS_VERSION=${electrs_version}
EOF
}

bitstack_swarm_active() {
  sudo docker info 2>/dev/null | grep -q 'Swarm: active'
}

bitstack_image_present() {
  sudo docker image inspect "$1" >/dev/null 2>&1
}

bitstack_stack_exists() {
  sudo docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx "${BITSTACK_STACK_NAME}"
}

# Container ID of the running bitcoind swarm task, or empty if none.
bitstack_bitcoind_container() {
  sudo docker ps \
    --filter "label=com.docker.swarm.service.name=${BITSTACK_STACK_NAME}_bitcoind" \
    --filter "status=running" \
    --format '{{.ID}}' | head -n1
}

# Wait (best-effort) for every service in the stack's namespace to disappear
# after 'docker stack rm', so a caller that deletes volumes/data next does not
# race a still-terminating container.
bitstack_wait_stack_gone() {
  local timeout="${1:-120}" waited=0
  while sudo docker service ls \
      --filter "label=com.docker.stack.namespace=${BITSTACK_STACK_NAME}" \
      --format '{{.Name}}' 2>/dev/null | grep -q .; do
    ((waited >= timeout)) && return 1
    sleep 2
    ((waited += 2))
  done
  return 0
}
