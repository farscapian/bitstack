#!/usr/bin/env bash
# bitstack.sh -- control the bitcoind + electrs docker-swarm stack.
#
# Commands: up / down / reset. See docs/help/bitstack.txt (or run 'bitstack'
# with no arguments) for the command catalog. First-time dependency install
# (docker, swarm, Sparrow) is ./setup.sh, not this script. 'bitstack up'
# builds the local/bitcoind, local/electrs, and local/tor images itself,
# tagged by version, and skips the build once a tag already exists.
#
# Run as your regular login user (needs sudo). Not root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BITSTACK_ROOT="${SCRIPT_DIR}"

# shellcheck source=.agentstack/scripts/lib/cli-log.sh
source "${SCRIPT_DIR}/.agentstack/scripts/lib/cli-log.sh"
AGENTSTACK_CLI_LOG_PREFIX="bitstack"

info()  { _as_cli_info  "$@"; }
ok()    { _as_cli_ok    "$@"; }
warn()  { _as_cli_warn  "$@"; }
err()   { _as_cli_err   "$@"; exit 1; }
debug() { _as_cli_debug "$@"; }

# shellcheck source=scripts/bitstack-common.sh
source "${SCRIPT_DIR}/scripts/bitstack-common.sh"

HELP_DIR="${SCRIPT_DIR}/docs/help"

cat_help() {
  local file="${HELP_DIR}/$1"
  [[ -f "$file" ]] || err "bitstack: help file missing: ${file}"
  cat "$file"
}

help_requested() { case "${1:-}" in help|-h|--help) return 0 ;; *) return 1 ;; esac; }

usage()       { cat_help bitstack.txt; }
help_up()     { cat_help bitstack-up.txt; }
help_down()   { cat_help bitstack-down.txt; }
help_reset()  { cat_help bitstack-reset.txt; }
help_bitcoin_cli() { cat_help bitstack-bitcoin-cli.txt; }
help_tor()    { cat_help bitstack-tor.txt; }
help_wallet() { cat_help bitstack-wallet.txt; }

bitstack_help_topic() {
  case "${1:-}" in
    ""|bitstack) usage ;;
    up)    help_up ;;
    down)  help_down ;;
    reset) help_reset ;;
    bitcoin-cli) help_bitcoin_cli ;;
    tor)    help_tor ;;
    wallet) help_wallet ;;
    *) err "bitstack: unknown help topic: ${1} (try: bitstack help)" ;;
  esac
}

# Deploy is idempotent: 'docker stack deploy' converges the running stack to
# match btc-stack.yml without discarding ~/.bitcoin or the electrs volume.
cmd_up() {
  help_requested "${1:-}" && { help_up; return 0; }
  (( $# == 0 )) || err "bitstack up: unexpected argument: $1 (see: bitstack up help)"

  bitstack_require_node_user
  bitstack_require_siblings "${SCRIPT_DIR}"

  bitstack_swarm_active || err "Docker swarm is not active -- run ./setup.sh first."

  local node_uid node_gid
  node_uid="$(id -u "${BITSTACK_NODE_USER}")"
  node_gid="$(id -g "${BITSTACK_NODE_USER}")"

  local bitcoin_tag bitcoin_version electrs_version
  bitcoin_tag="$(bitstack_latest_tag bitcoin/bitcoin "v${BITSTACK_BITCOIN_FALLBACK}")"
  bitcoin_version="${bitcoin_tag#v}"
  electrs_version="$(bitstack_latest_tag romanz/electrs "${BITSTACK_ELECTRS_FALLBACK}")"

  bitstack_ensure_image "local/bitcoind:${bitcoin_version}" \
    sudo docker build \
      --build-arg BITCOIN_VERSION="${bitcoin_version}" \
      --build-arg UID="${node_uid}" --build-arg GID="${node_gid}" \
      -t "local/bitcoind:${bitcoin_version}" \
      -f "${SCRIPT_DIR}/bitcoind.Dockerfile" "${SCRIPT_DIR}"

  bitstack_ensure_image "local/electrs:${electrs_version}" \
    sudo docker build \
      --build-arg ELECTRS_VERSION="${electrs_version}" \
      --build-arg UID="${node_uid}" --build-arg GID="${node_gid}" \
      -t "local/electrs:${electrs_version}" \
      -f "${SCRIPT_DIR}/electrs.Dockerfile" "${SCRIPT_DIR}"

  bitstack_ensure_image "local/tor:latest" \
    sudo docker build \
      -t "local/tor:latest" \
      -f "${SCRIPT_DIR}/tor.Dockerfile" "${SCRIPT_DIR}"

  info "Preparing ${BITSTACK_BITCOIN_DIR}"
  mkdir -p "${BITSTACK_BITCOIN_DIR}"
  chown "${node_uid}:${node_gid}" "${BITSTACK_BITCOIN_DIR}"
  if [[ ! -f "${BITSTACK_BITCOIN_DIR}/bitcoin.conf" ]]; then
    install -o "${node_uid}" -g "${node_gid}" -m 0644 \
      "${SCRIPT_DIR}/bitcoin.conf" "${BITSTACK_BITCOIN_DIR}/bitcoin.conf"
  fi

  info "Deploying stack '${BITSTACK_STACK_NAME}' (bitcoind ${bitcoin_version}, electrs ${electrs_version})"
  sudo env \
    BITCOIN_VERSION="${bitcoin_version}" \
    ELECTRS_VERSION="${electrs_version}" \
    BITCOIN_DIR="${BITSTACK_BITCOIN_DIR}" \
    docker stack deploy --resolve-image never \
    -c "${SCRIPT_DIR}/btc-stack.yml" "${BITSTACK_STACK_NAME}"

  ok "Stack '${BITSTACK_STACK_NAME}' deployed."

  info "Waiting for the Tor hidden service to publish (first run generates a key; can take up to a minute)"
  local onion_host="" onion_line
  if onion_host="$(bitstack_wait_onion_hostname 60)"; then
    printf '%s\n' "${onion_host}" > "${BITSTACK_ONION_FILE}"
    onion_line="tcp://${onion_host}:50001"
  else
    warn "Tor hidden service not ready yet -- check: sudo docker service logs -f ${BITSTACK_STACK_NAME}_tor"
    onion_line="pending -- run 'bitstack tor' once the tor service is up"
  fi

  cat <<INFO

Stack:    sudo docker stack services ${BITSTACK_STACK_NAME}
Logs:     sudo docker service logs -f ${BITSTACK_STACK_NAME}_bitcoind
          sudo docker service logs -f ${BITSTACK_STACK_NAME}_electrs
          sudo docker service logs -f ${BITSTACK_STACK_NAME}_tor
Electrum: tcp://127.0.0.1:50001  (Private Electrum, SSL off)
Onion:    ${onion_line}
Wallet:   bitstack wallet   (auto: local when co-resident with electrs, else onion)

INFO
}

# Shared by cmd_down and cmd_reset. Idempotent: fine to call with no stack up.
bitstack_do_down() {
  if ! bitstack_stack_exists; then
    info "Stack '${BITSTACK_STACK_NAME}' is not running."
    return 0
  fi
  info "Stopping stack '${BITSTACK_STACK_NAME}'"
  sudo docker stack rm "${BITSTACK_STACK_NAME}"
  bitstack_wait_stack_gone 120 \
    || warn "Timed out waiting for '${BITSTACK_STACK_NAME}' services to fully terminate; check: sudo docker service ls"
}

cmd_down() {
  help_requested "${1:-}" && { help_down; return 0; }
  (( $# == 0 )) || err "bitstack down: unexpected argument: $1 (see: bitstack down help)"

  bitstack_require_node_user
  bitstack_do_down
  ok "Stack '${BITSTACK_STACK_NAME}' stopped. Node data under ${BITSTACK_BITCOIN_DIR} was left in place."
}

# TWO interactive confirmations gate deleting blocks/chainstate/wallets: a
# yes/no prompt naming exactly what is about to be lost, then typing the
# literal word RESET. -f/--force bypasses both for scripted use.
bitstack_confirm_reset() {
  local dir="$1" force="$2"
  local -a sensitive=()
  [[ -d "${dir}/blocks" ]]     && sensitive+=("blocks/")
  [[ -d "${dir}/chainstate" ]] && sensitive+=("chainstate/")
  [[ -d "${dir}/wallets" ]]    && sensitive+=("wallets/")

  (( force == 1 )) && return 0

  warn "This will permanently delete everything under ${dir}."
  if (( ${#sensitive[@]} > 0 )); then
    warn "That includes: ${sensitive[*]}"
    for d in "${sensitive[@]}"; do
      [[ "$d" == "wallets/" ]] || continue
      warn "wallets/ is present -- if it holds an unbacked wallet, any funds in it become UNRECOVERABLE."
    done
    warn "Losing blocks/ and chainstate/ means a full re-sync (hours to days) after the next 'bitstack up'."
  fi

  local reply
  read -r -p "Confirmation 1/2 -- delete ${dir} and all node data? [y/N] " reply </dev/tty
  case "${reply,,}" in y|yes) ;; *) info "Aborted; nothing deleted."; return 1 ;; esac

  read -r -p "Confirmation 2/2 -- type RESET to permanently delete this data: " reply </dev/tty
  [[ "$reply" == "RESET" ]] || { info "Aborted; nothing deleted."; return 1; }
}

cmd_reset() {
  local force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      help|-h|--help) help_reset; return 0 ;;
      -f|--force) force=1; shift ;;
      *) err "bitstack reset: unexpected argument: $1 (see: bitstack reset help)" ;;
    esac
  done

  bitstack_require_node_user
  bitstack_do_down

  if sudo docker volume inspect "${BITSTACK_STACK_NAME}_electrs-db" >/dev/null 2>&1; then
    info "Removing electrs database volume"
    sudo docker volume rm "${BITSTACK_STACK_NAME}_electrs-db" >/dev/null 2>&1 || true
  fi

  if [[ ! -d "${BITSTACK_BITCOIN_DIR}" ]] || [[ -z "$(ls -A "${BITSTACK_BITCOIN_DIR}" 2>/dev/null)" ]]; then
    info "Nothing to reset under ${BITSTACK_BITCOIN_DIR}."
    return 0
  fi

  bitstack_confirm_reset "${BITSTACK_BITCOIN_DIR}" "${force}" || exit 0

  info "Deleting ${BITSTACK_BITCOIN_DIR}"
  find "${BITSTACK_BITCOIN_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

  ok "Reset complete. Run 'bitstack up' to redeploy a fresh node."
}

# Passthrough wrapper: forwards every argument verbatim to bitcoin-cli inside
# the running bitcoind container. Deliberately does NOT intercept "help" as a
# bitstack help topic here (unlike the other cmd_* functions) because
# bitcoin-cli has its own 'help' RPC (lists/describes RPC commands) -- 'bitstack
# bitcoin-cli help getblockchaininfo' must reach bitcoin-cli unchanged. Use
# 'bitstack help bitcoin-cli' for this wrapper's own help instead.
cmd_bitcoin_cli() {
  bitstack_require_node_user
  bitstack_stack_exists || err "Stack '${BITSTACK_STACK_NAME}' is not running -- run 'bitstack up' first."

  local container
  container="$(bitstack_bitcoind_container)"
  [[ -n "$container" ]] \
    || err "bitcoind container not found (stack up but service not ready?) -- check: sudo docker service ps ${BITSTACK_STACK_NAME}_bitcoind"

  local -a tty_flags=(-i)
  [[ -t 0 && -t 1 ]] && tty_flags=(-it)

  sudo docker exec "${tty_flags[@]}" "$container" bitcoin-cli -datadir="${BITSTACK_BITCOIN_DIR}" "$@"
}

# Shows the Tor onion address publishing electrs' Electrum RPC port,
# querying the running tor service and caching the result to
# BITSTACK_ONION_FILE for 'bitstack wallet' to use later (including from a
# host that does not run the stack itself -- copy that file there).
cmd_tor() {
  help_requested "${1:-}" && { help_tor; return 0; }
  (( $# == 0 )) || err "bitstack tor: unexpected argument: $1 (see: bitstack tor help)"

  bitstack_require_node_user

  local host
  if host="$(bitstack_wait_onion_hostname 5)"; then
    printf '%s\n' "${host}" > "${BITSTACK_ONION_FILE}"
  elif [[ -f "${BITSTACK_ONION_FILE}" ]]; then
    host="$(<"${BITSTACK_ONION_FILE}")"
    warn "Tor hidden service not reachable right now; showing the last-known address."
  else
    err "No onion endpoint known -- run 'bitstack up' first."
  fi

  ok "Onion endpoint: tcp://${host}:50001"
}

# Idempotently patches ~/.sparrow/config so Sparrow points at the given
# Electrum server on next launch, preserving every other Sparrow preference
# (wallet list, theme, etc.) already in that file.
bitstack_write_sparrow_server() {
  local url="$1" cfg tmp
  cfg="${BITSTACK_NODE_HOME}/.sparrow/config"
  mkdir -p "$(dirname "${cfg}")"
  tmp="$(mktemp)"
  if [[ -f "${cfg}" ]]; then
    jq --arg url "${url}" \
      '.mode="ONLINE" | .serverType="ELECTRUM_SERVER" | .electrumServer=$url | .useProxy=false' \
      "${cfg}" > "${tmp}"
  else
    jq -n --arg url "${url}" \
      '{mode:"ONLINE", serverType:"ELECTRUM_SERVER", electrumServer:$url, useProxy:false}' \
      > "${tmp}"
  fi
  mv "${tmp}" "${cfg}"
}

# Picks the Electrum server for Sparrow and launches it. With no argument,
# defaults to 'local' when electrs is reachable on 127.0.0.1:50001
# (co-resident with this host) and falls back to the Tor onion endpoint
# otherwise -- e.g. running this on a separate client machine.
cmd_wallet() {
  local target=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      help|-h|--help) help_wallet; return 0 ;;
      local|onion)
        [[ -z "$target" ]] || err "bitstack wallet: unexpected argument: $1 (see: bitstack wallet help)"
        target="$1"; shift ;;
      *) err "bitstack wallet: unexpected argument: $1 (see: bitstack wallet help)" ;;
    esac
  done

  bitstack_require_node_user
  [[ -x "${BITSTACK_SPARROW_DIR}/bin/Sparrow" ]] || err "Sparrow is not installed -- run ./setup.sh first."
  command -v jq >/dev/null 2>&1 || err "jq is required to configure Sparrow -- run ./setup.sh first."

  if [[ -z "$target" ]]; then
    if bitstack_electrs_local_reachable; then target="local"; else target="onion"; fi
  fi

  local electrum_url
  if [[ "$target" == "local" ]]; then
    electrum_url="tcp://127.0.0.1:50001"
  else
    local onion_host
    onion_host="$(bitstack_resolve_onion_host)" \
      || err "No onion endpoint known -- run 'bitstack up' or 'bitstack tor' on the electrs host, or copy its ${BITSTACK_ONION_FILE} here."
    electrum_url="tcp://${onion_host}:50001"
  fi

  bitstack_write_sparrow_server "${electrum_url}"
  info "Launching Sparrow (${target}: ${electrum_url})"
  exec "${BITSTACK_SPARROW_DIR}/bin/Sparrow"
}

main() {
  local argv=()
  _as_cli_parse_global_flags argv "$@"
  set -- "${argv[@]}"

  eval "$(AGENTSTACK_CLI_TOOL=bitstack "${BITSTACK_ROOT}/.agentstack/scripts/cli-preamble.sh" "${BITSTACK_ROOT}")"
  debug "provenance HEAD=${AGENTSTACK_CLI_HEAD:-unknown}"

  local cmd="${1:-}"
  case "$cmd" in
    ""|help|-h|--help)
      if [[ -n "${2:-}" ]]; then bitstack_help_topic "$2"; else usage; fi
      ;;
    up)    shift; cmd_up "$@" ;;
    down)  shift; cmd_down "$@" ;;
    reset) shift; cmd_reset "$@" ;;
    bitcoin-cli) shift; cmd_bitcoin_cli "$@" ;;
    tor)    shift; cmd_tor "$@" ;;
    wallet) shift; cmd_wallet "$@" ;;
    *) err "Unknown command: ${cmd}. Try 'bitstack help'" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
