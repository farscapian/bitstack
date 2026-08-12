#!/usr/bin/env bash
# bitstack-common.sh -- shared config and helpers for setup.sh and bitstack.sh.
#
# Sourced by both entry points; not meant to be executed directly. Callers must
# set BITSTACK_ROOT (the repo root, where the sibling Dockerfiles/yml/conf
# live) before sourcing.
#
# shellcheck shell=bash

: "${BITSTACK_ROOT:?bitstack-common.sh: BITSTACK_ROOT must be set before sourcing}"

BITSTACK_NODE_USER="${BITSTACK_NODE_USER:-$(id -un)}"
BITSTACK_NODE_HOME="/home/${BITSTACK_NODE_USER}"
BITSTACK_BITCOIN_DIR="${BITSTACK_NODE_HOME}/.bitcoin"      # bind-mounted into containers
BITSTACK_STACK_NAME="bitstack"
BITSTACK_SPARROW_DIR="/opt/sparrow"
# Last-known onion hostname 'bitstack up'/'bitstack electrs tor' queried
# from the running tor service. Lets 'bitstack sparrow' resolve an onion
# address on a client host that does not run the stack itself (copy this
# file there).
BITSTACK_ONION_FILE="${BITSTACK_ROOT}/.bitstack-onion"

# fallbacks used if the GitHub API is unreachable
BITSTACK_BITCOIN_FALLBACK="31.1"
BITSTACK_ELECTRS_FALLBACK="v0.11.1"
BITSTACK_SPARROW_FALLBACK="2.5.3"

# local/tor has no upstream release to track (tor.Dockerfile just installs the
# distro tor package) -- bump this by hand whenever tor.Dockerfile, torrc, or
# tor-entrypoint.sh change in a way that should invalidate the cached image.
BITSTACK_TOR_IMAGE_VERSION="2"

BITSTACK_SIBLINGS=(bitcoind.Dockerfile electrs.Dockerfile tor.Dockerfile torrc tor-entrypoint.sh btc-stack.yml bitcoin.conf sparrow-config.json)

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

bitstack_swarm_active() {
  sudo docker info 2>/dev/null | grep -q 'Swarm: active'
}

bitstack_image_present() {
  sudo docker image inspect "$1" >/dev/null 2>&1
}

# Build docker image tagged $1 by running the remaining arguments as the
# build command, unless that tag already exists locally -- 'bitstack up' is
# safe to re-run without re-building images it already built.
bitstack_ensure_image() {
  local tag="$1"; shift
  if bitstack_image_present "${tag}"; then
    info "Image ${tag} already present, skipping build"
    return 0
  fi
  info "Building image ${tag}"
  "$@"
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

# Container ID of the running tor swarm task, or empty if none.
bitstack_onion_container() {
  sudo docker ps \
    --filter "label=com.docker.swarm.service.name=${BITSTACK_STACK_NAME}_tor" \
    --filter "status=running" \
    --format '{{.ID}}' | head -n1
}

# Onion hostname the tor service is currently publishing, or a nonzero return
# if the service isn't running or hasn't published a hidden service yet.
bitstack_onion_hostname() {
  local container
  container="$(bitstack_onion_container)"
  [[ -n "$container" ]] || return 1
  sudo docker exec "$container" cat /var/lib/tor/hidden_service/hostname 2>/dev/null | tr -d '[:space:]'
}

# Poll for the onion hostname to appear -- first run generates a fresh
# hidden-service keypair and publishing the descriptor can take a while.
bitstack_wait_onion_hostname() {
  local timeout="${1:-30}" waited=0 host
  while true; do
    host="$(bitstack_onion_hostname 2>/dev/null || true)"
    if [[ -n "$host" ]]; then
      printf '%s' "$host"
      return 0
    fi
    ((waited >= timeout)) && return 1
    sleep 2
    ((waited += 2))
  done
}

# Resolve the onion hostname for a remote Sparrow connection: prefer a live
# query against a running tor service, falling back to the address
# 'bitstack up'/'bitstack electrs tor' last cached to BITSTACK_ONION_FILE
# (e.g. on a client host that does not run the stack itself). Nonzero
# return if neither is available.
bitstack_resolve_onion_host() {
  local host
  host="$(bitstack_onion_hostname 2>/dev/null || true)"
  if [[ -z "$host" && -f "${BITSTACK_ONION_FILE}" ]]; then
    host="$(<"${BITSTACK_ONION_FILE}")"
  fi
  [[ -n "$host" ]] || return 1
  printf '%s' "$host"
}

# True if something is listening on the local electrs Electrum RPC port --
# i.e. electrs is co-resident with the caller, not just reachable remotely.
bitstack_electrs_local_reachable() {
  timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/50001' 2>/dev/null
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

# Wait (best-effort) for the stack's overlay network to fully disappear
# after 'docker stack rm'. Network teardown is asynchronous and can lag
# well behind 'docker stack rm' returning (unlike service removal, which
# bitstack_wait_stack_gone already covers) -- a caller that redeploys
# right after (e.g. 'bitstack restart') can otherwise race a
# still-tearing-down network and hit "network ... not found" from
# 'docker stack deploy'.
bitstack_wait_network_gone() {
  local timeout="${1:-60}" waited=0
  while sudo docker network inspect "${BITSTACK_STACK_NAME}_btc" >/dev/null 2>&1; do
    ((waited >= timeout)) && return 1
    sleep 1
    ((waited += 1))
  done
  return 0
}

# Wait (best-effort) for a single service to have zero running tasks, after
# scaling it to 0 replicas -- so a caller that touches its volume next does
# not race a still-terminating container.
bitstack_wait_service_idle() {
  local service="$1" timeout="${2:-60}" waited=0
  while sudo docker service ps "${service}" \
      --filter "desired-state=running" \
      --format '{{.ID}}' 2>/dev/null | grep -q .; do
    ((waited >= timeout)) && return 1
    sleep 1
    ((waited += 1))
  done
  return 0
}
