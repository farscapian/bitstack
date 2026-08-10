#!/usr/bin/env bash
# bitstack.sh -- control the bitcoind + electrs docker-swarm stack.
#
# Commands: up / down / reset. See docs/help/bitstack.txt (or run 'bitstack'
# with no arguments) for the command catalog. First-time dependency install
# (docker, swarm, images, Sparrow) is ./setup.sh, not this script.
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

bitstack_help_topic() {
  case "${1:-}" in
    ""|bitstack) usage ;;
    up)    help_up ;;
    down)  help_down ;;
    reset) help_reset ;;
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

  bitstack_load_versions || err "No images built yet -- run ./setup.sh first (see: bitstack up help)."
  bitstack_swarm_active || err "Docker swarm is not active -- run ./setup.sh first."
  bitstack_image_present "local/bitcoind:${BITCOIN_VERSION}" \
    || err "Missing image local/bitcoind:${BITCOIN_VERSION} -- run ./setup.sh first."
  bitstack_image_present "local/electrs:${ELECTRS_VERSION}" \
    || err "Missing image local/electrs:${ELECTRS_VERSION} -- run ./setup.sh first."

  local node_uid node_gid
  node_uid="$(id -u "${BITSTACK_NODE_USER}")"
  node_gid="$(id -g "${BITSTACK_NODE_USER}")"

  info "Preparing ${BITSTACK_BITCOIN_DIR}"
  mkdir -p "${BITSTACK_BITCOIN_DIR}"
  chown "${node_uid}:${node_gid}" "${BITSTACK_BITCOIN_DIR}"
  if [[ ! -f "${BITSTACK_BITCOIN_DIR}/bitcoin.conf" ]]; then
    install -o "${node_uid}" -g "${node_gid}" -m 0644 \
      "${SCRIPT_DIR}/bitcoin.conf" "${BITSTACK_BITCOIN_DIR}/bitcoin.conf"
  fi

  info "Deploying stack '${BITSTACK_STACK_NAME}' (bitcoind ${BITCOIN_VERSION}, electrs ${ELECTRS_VERSION})"
  sudo env \
    BITCOIN_VERSION="${BITCOIN_VERSION}" \
    ELECTRS_VERSION="${ELECTRS_VERSION}" \
    BITCOIN_DIR="${BITSTACK_BITCOIN_DIR}" \
    docker stack deploy --resolve-image never \
    -c "${SCRIPT_DIR}/btc-stack.yml" "${BITSTACK_STACK_NAME}"

  ok "Stack '${BITSTACK_STACK_NAME}' deployed."
  cat <<INFO

Stack:    sudo docker stack services ${BITSTACK_STACK_NAME}
Logs:     sudo docker service logs -f ${BITSTACK_STACK_NAME}_bitcoind
          sudo docker service logs -f ${BITSTACK_STACK_NAME}_electrs
Sparrow:  ${BITSTACK_SPARROW_DIR}/bin/Sparrow   (or the app menu)
Electrum: tcp://127.0.0.1:50001  (Private Electrum, SSL off)

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
    *) err "Unknown command: ${cmd}. Try 'bitstack help'" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
