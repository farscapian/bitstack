#!/usr/bin/env bash
# bitstack.sh -- control the bitcoind + electrs docker-swarm stack.
#
# Commands: up / down / reset. See docs/help/bitstack.txt (or run 'bitstack'
# with no arguments) for the command catalog. First-time dependency install
# (docker itself, plus adding this user to the docker group) is ./setup.sh,
# not this script -- but initializing the single-node swarm is main()'s job
# here, on every invocation (idempotent), so setup.sh doesn't need a second
# docker-group-active login session just to do it. 'bitstack up' builds the
# local/bitcoind, local/electrs, and local/tor images itself, tagged by
# version, and skips the build once a tag already exists. 'bitstack sparrow'
# installs Sparrow (host GUI wallet) itself, on first run.
#
# Run as your regular login user, an active member of the docker group
# (see ./setup.sh) -- not root, and no sudo needed for docker itself.

set -euo pipefail

# readlink -f resolves the /usr/local/bin/bitstack symlink (see setup.sh) to
# this file's real location -- BASH_SOURCE alone would leave SCRIPT_DIR
# pointing at /usr/local/bin when invoked as the bare 'bitstack' command.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
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
help_restart() { cat_help bitstack-restart.txt; }
help_reset()  { cat_help bitstack-reset.txt; }
help_bitcoin_cli() { cat_help bitstack-bitcoin-cli.txt; }
help_bitcoind() { cat_help bitstack-bitcoind.txt; }
help_electrs() { cat_help bitstack-electrs.txt; }
help_get_onion() { cat_help bitstack-get-onion.txt; }
help_sparrow() { cat_help bitstack-sparrow.txt; }

bitstack_help_topic() {
  case "${1:-}" in
    ""|bitstack) usage ;;
    up)    help_up ;;
    down)  help_down ;;
    restart) help_restart ;;
    reset) help_reset ;;
    bitcoin-cli) help_bitcoin_cli ;;
    bitcoind) help_bitcoind ;;
    electrs) help_electrs ;;
    get-onion) help_get_onion ;;
    sparrow) help_sparrow ;;
    *) err "bitstack: unknown help topic: ${1} (try: bitstack help)" ;;
  esac
}

# Deploy is idempotent: 'docker stack deploy' converges the running stack to
# match btc-stack.yml without discarding ~/.bitcoin, ~/.bitstack/electrs-db,
# or ~/.bitstack/onion.
cmd_up() {
  help_requested "${1:-}" && { help_up; return 0; }
  (( $# == 0 )) || err "bitstack up: unexpected argument: $1 (see: bitstack up help)"

  bitstack_require_node_user
  bitstack_require_siblings "${SCRIPT_DIR}"

  local node_uid node_gid
  node_uid="$(id -u "${BITSTACK_NODE_USER}")"
  node_gid="$(id -g "${BITSTACK_NODE_USER}")"

  local bitcoin_tag bitcoin_version electrs_version tor_version
  bitcoin_tag="$(bitstack_latest_tag bitcoin/bitcoin "v${BITSTACK_BITCOIN_FALLBACK}")"
  bitcoin_version="${bitcoin_tag#v}"
  electrs_version="$(bitstack_latest_tag romanz/electrs "${BITSTACK_ELECTRS_FALLBACK}")"
  tor_version="${BITSTACK_TOR_IMAGE_VERSION}"

  bitstack_ensure_image "local/bitcoind:${bitcoin_version}" \
    docker build \
      --build-arg BITCOIN_VERSION="${bitcoin_version}" \
      --build-arg UID="${node_uid}" --build-arg GID="${node_gid}" \
      -t "local/bitcoind:${bitcoin_version}" \
      -f "${SCRIPT_DIR}/bitcoind.Dockerfile" "${SCRIPT_DIR}"

  bitstack_ensure_image "local/electrs:${electrs_version}" \
    docker build \
      --build-arg ELECTRS_VERSION="${electrs_version}" \
      --build-arg UID="${node_uid}" --build-arg GID="${node_gid}" \
      -t "local/electrs:${electrs_version}" \
      -f "${SCRIPT_DIR}/electrs.Dockerfile" "${SCRIPT_DIR}"

  bitstack_ensure_image "local/tor:${tor_version}" \
    docker build \
      -t "local/tor:${tor_version}" \
      -f "${SCRIPT_DIR}/tor.Dockerfile" "${SCRIPT_DIR}"

  info "Preparing ${BITSTACK_BITCOIN_DIR}"
  mkdir -p "${BITSTACK_BITCOIN_DIR}"
  chown "${node_uid}:${node_gid}" "${BITSTACK_BITCOIN_DIR}"
  if [[ ! -f "${BITSTACK_BITCOIN_DIR}/bitcoin.conf" ]]; then
    install -o "${node_uid}" -g "${node_gid}" -m 0644 \
      "${SCRIPT_DIR}/bitcoin.conf" "${BITSTACK_BITCOIN_DIR}/bitcoin.conf"
  fi

  # Host bind mounts, not docker volumes, for electrs' index and the tor
  # hidden-service key material -- pre-created and owned by the node user
  # (matching electrs' in-container UID, set via build args above) so
  # electrs can write to its bind mount same as it could a fresh volume.
  # tor's entrypoint re-chowns its own mount to debian-tor on every start
  # regardless (see tor-entrypoint.sh), so this ownership is only a
  # starting point for that one, not load-bearing.
  info "Preparing ${BITSTACK_ELECTRS_DB_DIR} and ${BITSTACK_ONION_DIR}"
  mkdir -p "${BITSTACK_ELECTRS_DB_DIR}" "${BITSTACK_ONION_DIR}"
  chown "${node_uid}:${node_gid}" "${BITSTACK_ELECTRS_DB_DIR}" "${BITSTACK_ONION_DIR}"

  info "Deploying stack '${BITSTACK_STACK_NAME}' (bitcoind ${bitcoin_version}, electrs ${electrs_version})"
  BITCOIN_VERSION="${bitcoin_version}" \
    ELECTRS_VERSION="${electrs_version}" \
    TOR_VERSION="${tor_version}" \
    BITCOIN_DIR="${BITSTACK_BITCOIN_DIR}" \
    ELECTRS_DB_DIR="${BITSTACK_ELECTRS_DB_DIR}" \
    ONION_DIR="${BITSTACK_ONION_DIR}" \
    docker stack deploy --resolve-image never \
    -c "${SCRIPT_DIR}/btc-stack.yml" "${BITSTACK_STACK_NAME}"

  ok "Stack '${BITSTACK_STACK_NAME}' deployed."

  info "Waiting for the Tor hidden service to publish (first run generates a key; can take up to a minute)"
  local onion_host="" onion_line
  if onion_host="$(bitstack_wait_onion_hostname 60)"; then
    printf '%s\n' "${onion_host}" > "${BITSTACK_ONION_FILE}"
    onion_line="tcp://${onion_host}:50001"
  else
    warn "Tor hidden service not ready yet -- check: docker service logs -f ${BITSTACK_STACK_NAME}_tor"
    onion_line="pending -- run 'bitstack get-onion' once the tor service is up"
  fi

  cat <<INFO

Stack:    docker stack services ${BITSTACK_STACK_NAME}
Logs:     docker service logs -f ${BITSTACK_STACK_NAME}_bitcoind
          docker service logs -f ${BITSTACK_STACK_NAME}_electrs
          docker service logs -f ${BITSTACK_STACK_NAME}_tor
Electrum: tcp://127.0.0.1:50001  (Private Electrum, SSL off)
Onion:    ${onion_line}
Wallet:   bitstack sparrow   (installs Sparrow on first run; auto: local when co-resident with electrs, else onion)

INFO
}

# Shared by cmd_down and cmd_reset. Idempotent: fine to call with no stack up.
bitstack_do_down() {
  if ! bitstack_stack_exists; then
    info "Stack '${BITSTACK_STACK_NAME}' is not running."
    return 0
  fi
  info "Stopping stack '${BITSTACK_STACK_NAME}'"
  docker stack rm "${BITSTACK_STACK_NAME}"
  bitstack_wait_stack_gone 120 \
    || warn "Timed out waiting for '${BITSTACK_STACK_NAME}' services to fully terminate; check: docker service ls"
  # Network teardown lags service removal -- redeploying (e.g. 'bitstack
  # restart') before it finishes can race 'docker stack deploy' and fail
  # with "network ... not found" (see bitstack_wait_network_gone).
  bitstack_wait_network_gone 60 \
    || warn "Timed out waiting for the '${BITSTACK_STACK_NAME}_btc' network to fully terminate; check: docker network ls"
}

cmd_down() {
  help_requested "${1:-}" && { help_down; return 0; }
  (( $# == 0 )) || err "bitstack down: unexpected argument: $1 (see: bitstack down help)"

  bitstack_require_node_user
  bitstack_do_down
  ok "Stack '${BITSTACK_STACK_NAME}' stopped. Node data under ${BITSTACK_BITCOIN_DIR} was left in place."
}

# 'bitstack down' followed by 'bitstack up'. Node data is left in place
# (down doesn't touch it); up rebuilds/redeploys as usual.
cmd_restart() {
  help_requested "${1:-}" && { help_restart; return 0; }
  (( $# == 0 )) || err "bitstack restart: unexpected argument: $1 (see: bitstack restart help)"

  cmd_down
  cmd_up
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

  if [[ -d "${BITSTACK_ELECTRS_DB_DIR}" ]]; then
    info "Removing ${BITSTACK_ELECTRS_DB_DIR}"
    rm -rf "${BITSTACK_ELECTRS_DB_DIR}"
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
#
# stdout is captured (not streamed) so it can be checked for valid JSON and
# reformatted with 'jq .' when it is -- not every bitcoin-cli output is JSON
# (e.g. 'help' is plain text, and scalar string results like a block hash
# print unquoted, so they aren't valid JSON on their own), so anything that
# fails 'jq empty' is printed exactly as bitcoin-cli produced it. Only stdout
# goes through this check; stderr (RPC errors, connection failures) streams
# straight through untouched. No -t/tty flag: with stdout captured for the
# jq check, docker exec is never attached to a real terminal to allocate one
# for, only -i for stdin passthrough (e.g. 'bitcoin-cli -stdin').
cmd_bitcoin_cli() {
  bitstack_require_node_user
  bitstack_stack_exists || err "Stack '${BITSTACK_STACK_NAME}' is not running -- run 'bitstack up' first."
  command -v jq >/dev/null 2>&1 || err "jq is required to format bitcoin-cli's JSON output -- run ./setup.sh first."

  local container
  container="$(bitstack_bitcoind_container)"
  [[ -n "$container" ]] \
    || err "bitcoind container not found (stack up but service not ready?) -- check: docker service ps ${BITSTACK_STACK_NAME}_bitcoind"

  local out status
  if out="$(docker exec -i "$container" bitcoin-cli -datadir="${BITSTACK_BITCOIN_DIR}" "$@")"; then
    status=0
  else
    status=$?
  fi

  if [[ -n "$out" ]] && jq empty <<<"${out}" >/dev/null 2>&1; then
    jq . <<<"${out}"
  else
    printf '%s\n' "${out}"
  fi

  return "${status}"
}

# Prints (or, with -f/--follow, streams) '<service>'s docker service logs --
# shared by 'bitstack bitcoind logs' and 'bitstack electrs logs'.
bitstack_service_logs() {
  local service="$1" follow="$2"
  bitstack_stack_exists || err "Stack '${BITSTACK_STACK_NAME}' is not running -- run 'bitstack up' first."
  if (( follow )); then
    docker service logs -f "${BITSTACK_STACK_NAME}_${service}"
  else
    docker service logs "${BITSTACK_STACK_NAME}_${service}"
  fi
}

cmd_bitcoind_logs() {
  local follow=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      help|-h|--help) help_bitcoind; return 0 ;;
      -f|--follow) follow=1; shift ;;
      *) err "bitstack bitcoind logs: unexpected argument: $1 (see: bitstack bitcoind help)" ;;
    esac
  done

  bitstack_require_node_user
  bitstack_service_logs bitcoind "${follow}"
}

cmd_bitcoind_config() {
  help_requested "${1:-}" && { help_bitcoind; return 0; }
  (( $# == 0 )) || err "bitstack bitcoind config: unexpected argument: $1 (see: bitstack bitcoind help)"

  bitstack_require_node_user
  [[ -f "${BITSTACK_BITCOIN_DIR}/bitcoin.conf" ]] \
    || err "No bitcoin.conf found at ${BITSTACK_BITCOIN_DIR}/bitcoin.conf -- run 'bitstack up' first."
  cat "${BITSTACK_BITCOIN_DIR}/bitcoin.conf"
}

cmd_bitcoind() {
  case "${1:-}" in
    ""|help|-h|--help) help_bitcoind; return 0 ;;
    logs)   shift; cmd_bitcoind_logs "$@" ;;
    config) shift; cmd_bitcoind_config "$@" ;;
    *) err "bitstack bitcoind: unknown subcommand: $1 (see: bitstack bitcoind help)" ;;
  esac
}

# Common precondition for 'bitstack electrs rotate'/'set key': the stack
# must be running, and specifically the tor image their helper container
# reuses to touch ~/.bitstack/onion must already exist locally.
bitstack_electrs_require_stack() {
  bitstack_require_node_user
  bitstack_stack_exists || err "Stack '${BITSTACK_STACK_NAME}' is not running -- run 'bitstack up' first."
  bitstack_image_present "local/tor:${BITSTACK_TOR_IMAGE_VERSION}" \
    || err "local/tor:${BITSTACK_TOR_IMAGE_VERSION} image not found -- run 'bitstack up' first."
}

# Wipes ~/.bitstack/onion so Tor generates a brand-new v3 onion address on
# next start. Run only while the tor service has zero replicas (see
# bitstack_electrs_rekey) -- it isn't safe to yank key material out from
# under a running Tor.
bitstack_electrs_wipe_hs() {
  docker run --rm --entrypoint sh \
    -v "${BITSTACK_ONION_DIR}:/hs" \
    "local/tor:${BITSTACK_TOR_IMAGE_VERSION}" \
    -c 'find /hs -mindepth 1 -delete'
}

# Writes $1 -- a Tor v3 onion service private key, either the
# "ED25519-V3:<base64>" form (as used by Tor's ADD_ONION control command
# and most vanity-address generators) or the bare base64 of the same 64
# raw bytes -- as the hidden service's secret key, replacing whatever was
# there. Only the secret key file is written; Tor derives the matching
# public key and .onion hostname from it itself on next start -- the same
# code path it uses to derive them for a freshly *generated* secret, so
# there is no need to compute or supply those separately here. Run only
# while the tor service has zero replicas (see bitstack_electrs_rekey).
bitstack_electrs_write_key() {
  local key="$1" b64="$1"
  [[ "$key" == ED25519-V3:* ]] && b64="${key#ED25519-V3:}"

  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # 32-byte Tor key-file header, then the 64 raw expanded-secret-key bytes
  printf '== ed25519v1-secret: type0 ==\0\0\0' > "${tmp}/hs_ed25519_secret_key"
  printf '%s' "${b64}" | base64 -d >> "${tmp}/hs_ed25519_secret_key" 2>/dev/null \
    || err "bitstack electrs set key: not valid base64"
  chmod 600 "${tmp}/hs_ed25519_secret_key"

  local size
  size="$(stat -c%s "${tmp}/hs_ed25519_secret_key")"
  (( size == 96 )) \
    || err "bitstack electrs set key: expected a 64-byte private key, got $((size - 32)) bytes after base64 decoding -- pass the ED25519-V3:<base64> form of a Tor v3 onion service private key"

  docker run --rm --entrypoint sh \
    -v "${BITSTACK_ONION_DIR}:/hs" \
    -v "${tmp}:/src:ro" \
    "local/tor:${BITSTACK_TOR_IMAGE_VERSION}" \
    -c 'find /hs -mindepth 1 -delete && cp /src/hs_ed25519_secret_key /hs/hs_ed25519_secret_key && chmod 600 /hs/hs_ed25519_secret_key'
}

# Scales the tor service to 0, waits for it to actually stop (so nothing
# else has ~/.bitstack/onion open), runs $1 (a bitstack_electrs_*
# mutator, plus any further args) against it, then scales tor back to 1
# and waits for the (new) onion address, caching it to BITSTACK_ONION_FILE
# like 'bitstack up'/'bitstack get-onion' do. Shared by 'bitstack electrs
# rotate' and 'bitstack electrs set key'. Callers must have already run
# bitstack_electrs_require_stack.
bitstack_electrs_rekey() {
  local mutator="$1"; shift

  info "Stopping tor service"
  docker service scale "${BITSTACK_STACK_NAME}_tor=0" >/dev/null
  bitstack_wait_service_idle "${BITSTACK_STACK_NAME}_tor" 60 \
    || err "Timed out waiting for the tor service to stop -- check: docker service ps ${BITSTACK_STACK_NAME}_tor"

  "$mutator" "$@"

  info "Restarting tor service"
  docker service scale "${BITSTACK_STACK_NAME}_tor=1" >/dev/null

  info "Waiting for the new onion address to publish (can take up to a minute)"
  local onion_host
  if onion_host="$(bitstack_wait_onion_hostname 60)"; then
    printf '%s\n' "${onion_host}" > "${BITSTACK_ONION_FILE}"
    ok "New onion address: tcp://${onion_host}:50001"
  else
    warn "Tor hidden service not ready yet -- check: docker service logs -f ${BITSTACK_STACK_NAME}_tor"
  fi
}

cmd_electrs_rotate() {
  local force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      help|-h|--help) help_electrs; return 0 ;;
      -f|--force) force=1; shift ;;
      *) err "bitstack electrs rotate: unexpected argument: $1 (see: bitstack electrs help)" ;;
    esac
  done

  bitstack_electrs_require_stack

  if (( ! force )); then
    warn "This permanently discards the current onion address -- anything configured to reach it (Sparrow, bookmarks, etc.) will need the new one."
    local reply
    read -r -p "Rotate the onion address now? [y/N] " reply </dev/tty
    case "${reply,,}" in y|yes) ;; *) info "Aborted; onion address unchanged."; return 0 ;; esac
  fi

  bitstack_electrs_rekey bitstack_electrs_wipe_hs
}

cmd_electrs_set() {
  case "${1:-}" in
    help|-h|--help) help_electrs; return 0 ;;
    key) shift ;;
    "") err "bitstack electrs set: missing subcommand (see: bitstack electrs help)" ;;
    *) err "bitstack electrs set: unknown subcommand: $1 (see: bitstack electrs help)" ;;
  esac

  help_requested "${1:-}" && { help_electrs; return 0; }
  (( $# == 1 )) || err "bitstack electrs set key: expected exactly one argument, the private key (see: bitstack electrs help)"

  bitstack_electrs_require_stack
  warn "This replaces the current onion address -- anything configured to reach the old one (Sparrow, bookmarks, etc.) will need the new one."
  bitstack_electrs_rekey bitstack_electrs_write_key "$1"
}

cmd_electrs_logs() {
  local follow=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      help|-h|--help) help_electrs; return 0 ;;
      -f|--follow) follow=1; shift ;;
      *) err "bitstack electrs logs: unexpected argument: $1 (see: bitstack electrs help)" ;;
    esac
  done

  bitstack_require_node_user
  bitstack_service_logs electrs "${follow}"
}

cmd_electrs() {
  case "${1:-}" in
    ""|help|-h|--help) help_electrs; return 0 ;;
    rotate) shift; cmd_electrs_rotate "$@" ;;
    set)    shift; cmd_electrs_set "$@" ;;
    logs)   shift; cmd_electrs_logs "$@" ;;
    *) err "bitstack electrs: unknown subcommand: $1 (see: bitstack electrs help)" ;;
  esac
}

# Shows the Tor onion address publishing electrs' Electrum RPC port,
# querying the running tor service and caching the result to
# BITSTACK_ONION_FILE for 'bitstack sparrow' to use later (including from a
# host that does not run the stack itself -- copy that file there).
cmd_get_onion() {
  help_requested "${1:-}" && { help_get_onion; return 0; }
  (( $# == 0 )) || err "bitstack get-onion: unexpected argument: $1 (see: bitstack get-onion help)"

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

# Best-effort desktop dark/light mode detection so 'bitstack sparrow' can
# match Sparrow's theme to the OS setting on every launch -- Sparrow itself
# has no such detection (its Theme is a fixed LIGHT/DARK choice with no
# system-following code anywhere in its source). Prints LIGHT or DARK and
# returns 0, or returns 1 with no output if no signal is available; callers
# should leave the 'theme' config key untouched in that case rather than
# guess. GNOME 42+'s color-scheme key is authoritative when present; older
# GNOME/Ubuntu (including this host) only exposes it via the gtk-theme name
# (e.g. "Yaru-dark").
bitstack_detect_os_theme() {
  command -v gsettings >/dev/null 2>&1 || return 1

  local scheme
  scheme="$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null)" || scheme=""
  case "$scheme" in
    *prefer-dark*) printf 'DARK\n'; return 0 ;;
    *prefer-light*|*'default'*) printf 'LIGHT\n'; return 0 ;;
  esac

  local gtk_theme
  gtk_theme="$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null)" || gtk_theme=""
  [[ -n "$gtk_theme" ]] || return 1
  if [[ "${gtk_theme,,}" == *dark* ]]; then
    printf 'DARK\n'
  else
    printf 'LIGHT\n'
  fi
}

# Idempotently patches ~/.sparrow/config's 'theme' key, preserving every
# other Sparrow preference already in that file. No-op (leaves any existing
# theme alone) if the config doesn't exist yet -- bitstack_ensure_sparrow_
# installed always creates one before this runs, so that's only reachable
# if jq itself is missing, which cmd_sparrow already guards against.
bitstack_write_sparrow_theme() {
  local theme="$1" cfg tmp
  cfg="${BITSTACK_NODE_HOME}/.sparrow/config"
  [[ -f "${cfg}" ]] || return 0
  tmp="$(mktemp)"
  jq --arg theme "${theme}" '.theme=$theme' "${cfg}" > "${tmp}"
  mv "${tmp}" "${cfg}"
}

# Installs Sparrow (host GUI wallet) into BITSTACK_SPARROW_DIR, verifying the
# release tarball via craigraw's GPG signature over the release manifest and
# the manifest's SHA256 hash, then wires up a desktop launcher and a
# ~/.sparrow/config (won't overwrite one that already exists). Idempotent:
# skips entirely once .../bin/Sparrow is already present.
bitstack_ensure_sparrow_installed() {
  [[ -x "${BITSTACK_SPARROW_DIR}/bin/Sparrow" ]] && return 0

  bitstack_require_siblings "${SCRIPT_DIR}"
  command -v jq >/dev/null 2>&1 || err "jq is required to configure Sparrow -- run ./setup.sh first."

  local node_uid node_gid
  node_uid="$(id -u "${BITSTACK_NODE_USER}")"
  node_gid="$(id -g "${BITSTACK_NODE_USER}")"

  local sparrow_version
  sparrow_version="$(bitstack_latest_tag sparrowwallet/sparrow "${BITSTACK_SPARROW_FALLBACK}")"
  info "Installing Sparrow ${sparrow_version}"

  local tmp
  tmp="$(mktemp -d)"
  # expand tmp now: it's local, and set -e exiting mid-function drops
  # locals before a deferred (single-quoted) RETURN trap would see them
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
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

  ok "Sparrow ${sparrow_version} installed."
}

# Picks the Electrum server for Sparrow and launches it, installing Sparrow
# first if this is the first run. With no argument, defaults to 'local' when
# electrs is reachable on 127.0.0.1:50001 (co-resident with this host) and
# falls back to the Tor onion endpoint otherwise -- e.g. running this on a
# separate client machine.
cmd_sparrow() {
  local target=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      help|-h|--help) help_sparrow; return 0 ;;
      local|onion)
        [[ -z "$target" ]] || err "bitstack sparrow: unexpected argument: $1 (see: bitstack sparrow help)"
        target="$1"; shift ;;
      *) err "bitstack sparrow: unexpected argument: $1 (see: bitstack sparrow help)" ;;
    esac
  done

  bitstack_require_node_user
  bitstack_ensure_sparrow_installed

  # Always verified against the live service, even for an explicit
  # target -- writing an unreachable address to Sparrow's config would
  # otherwise fail silently (Sparrow just sits there unable to connect,
  # with no indication from this command that it never had a chance).
  local electrum_url
  if [[ -z "$target" || "$target" == "local" ]]; then
    if bitstack_electrs_local_reachable; then
      target="local"
      electrum_url="tcp://127.0.0.1:50001"
    elif [[ "$target" == "local" ]]; then
      err "Local electrs (tcp://127.0.0.1:50001) is not reachable -- is the stack running on this host? ('bitstack up')"
    fi
  fi

  if [[ -z "${electrum_url:-}" ]]; then
    local onion_host
    onion_host="$(bitstack_resolve_onion_host)" \
      || err "Neither local electrs (tcp://127.0.0.1:50001) nor a known onion endpoint is reachable -- run 'bitstack up' or 'bitstack get-onion' on the electrs host, or copy its ${BITSTACK_ONION_FILE} here."
    target="onion"
    electrum_url="tcp://${onion_host}:50001"
  fi

  bitstack_write_sparrow_server "${electrum_url}"

  local os_theme
  if os_theme="$(bitstack_detect_os_theme)"; then
    bitstack_write_sparrow_theme "${os_theme}"
  fi

  info "Launching Sparrow (${target}: ${electrum_url})"
  exec "${BITSTACK_SPARROW_DIR}/bin/Sparrow"
}

main() {
  local argv=()
  _as_cli_parse_global_flags argv "$@"
  set -- "${argv[@]}"

  bitstack_require_docker_group

  # Single-node swarm is required for 'docker stack deploy' ('bitstack up').
  # Idempotent and cheap to check, so just done unconditionally here rather
  # than making every command that eventually needs it re-check -- lets
  # ./setup.sh stay a one-shot install step instead of needing a second,
  # docker-group-active login session to finish this itself.
  bitstack_swarm_active || {
    info "Initializing docker swarm"
    docker swarm init >/dev/null 2>&1 || docker swarm init --advertise-addr 127.0.0.1 >/dev/null
  }

  eval "$(AGENTSTACK_CLI_TOOL=bitstack "${BITSTACK_ROOT}/.agentstack/scripts/cli-preamble.sh" "${BITSTACK_ROOT}")"
  debug "provenance HEAD=${AGENTSTACK_CLI_HEAD:-unknown}"

  local cmd="${1:-}"
  case "$cmd" in
    ""|help|-h|--help)
      if [[ -n "${2:-}" ]]; then bitstack_help_topic "$2"; else usage; fi
      ;;
    up)    shift; cmd_up "$@" ;;
    down)  shift; cmd_down "$@" ;;
    restart) shift; cmd_restart "$@" ;;
    reset) shift; cmd_reset "$@" ;;
    bitcoin-cli) shift; cmd_bitcoin_cli "$@" ;;
    bitcoind) shift; cmd_bitcoind "$@" ;;
    electrs) shift; cmd_electrs "$@" ;;
    get-onion) shift; cmd_get_onion "$@" ;;
    sparrow) shift; cmd_sparrow "$@" ;;
    *) err "Unknown command: ${cmd}. Try 'bitstack help'" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
