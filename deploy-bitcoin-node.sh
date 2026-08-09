#!/usr/bin/env bash
#
# deploy-bitcoin-node.sh
# Ubuntu 26.04 (resolute). Deploys a fully-validating bitcoind + electrs
# as a docker swarm stack, then installs Sparrow (host GUI) pointed at electrs.
#
#   1) docker-ce
#   2) build bitcoind image (latest Bitcoin Core, GPG+SHA256 verified)
#   3) build+deploy electrs as a stack service
#   4) install Sparrow, connect it to local electrs
#
# Reads these sibling files from its own directory:
#   bitcoind.Dockerfile  electrs.Dockerfile  btc-stack.yml
#   bitcoin.conf         sparrow-config.json
#
# Run as user 'derek' (needs sudo). Not root.

set -euo pipefail

# ------------------------------------------------------------------ config
NODE_USER="derek"
NODE_HOME="/home/${NODE_USER}"
BITCOIN_DIR="${NODE_HOME}/.bitcoin"          # bind-mounted into containers
STACK_NAME="btc"
SPARROW_DIR="/opt/sparrow"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NODE_UID="$(id -u "${NODE_USER}")"
NODE_GID="$(id -g "${NODE_USER}")"

# fallbacks used if the GitHub API is unreachable
BITCOIN_FALLBACK="31.1"
ELECTRS_FALLBACK="v0.11.1"
SPARROW_FALLBACK="2.5.3"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Run as ${NODE_USER}, not root."
[ "$(dpkg --print-architecture)" = "amd64" ] || die "This script assumes amd64."

# required sibling files
for f in bitcoind.Dockerfile electrs.Dockerfile btc-stack.yml bitcoin.conf sparrow-config.json; do
  [ -f "${SCRIPT_DIR}/${f}" ] || die "Missing ${SCRIPT_DIR}/${f}"
done

# latest tag from a github repo, or a fallback
latest_tag() {
  local repo="$1" fallback="$2" tag
  tag="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
        | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')" || true
  printf '%s' "${tag:-$fallback}"
}

# ------------------------------------------------------------------ 0. prereqs
log "Installing prerequisites"
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg wget tar coreutils

# ------------------------------------------------------------------ 1. docker-ce
if ! command -v docker >/dev/null 2>&1; then
  log "Installing docker-ce"
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
  sudo usermod -aG docker "${NODE_USER}" || true
else
  log "docker already present, skipping install"
fi

# single-node swarm (required for 'docker stack deploy')
if ! sudo docker info 2>/dev/null | grep -q 'Swarm: active'; then
  log "Initializing swarm"
  sudo docker swarm init >/dev/null 2>&1 || sudo docker swarm init --advertise-addr 127.0.0.1 >/dev/null
fi

# ------------------------------------------------------------------ 2. datadir + bitcoin.conf
log "Preparing ${BITCOIN_DIR}"
mkdir -p "${BITCOIN_DIR}"
chown "${NODE_UID}:${NODE_GID}" "${BITCOIN_DIR}"
if [ ! -f "${BITCOIN_DIR}/bitcoin.conf" ]; then
  install -o "${NODE_UID}" -g "${NODE_GID}" -m 0644 \
    "${SCRIPT_DIR}/bitcoin.conf" "${BITCOIN_DIR}/bitcoin.conf"
fi

# ------------------------------------------------------------------ 3. resolve versions
BITCOIN_TAG="$(latest_tag bitcoin/bitcoin "v${BITCOIN_FALLBACK}")"
BITCOIN_VERSION="${BITCOIN_TAG#v}"
ELECTRS_VERSION="$(latest_tag romanz/electrs "${ELECTRS_FALLBACK}")"
SPARROW_VERSION="$(latest_tag sparrowwallet/sparrow "${SPARROW_FALLBACK}")"
log "bitcoind ${BITCOIN_VERSION} | electrs ${ELECTRS_VERSION} | sparrow ${SPARROW_VERSION}"

# ------------------------------------------------------------------ 4. build images
log "Building bitcoind image"
sudo docker build \
  --build-arg BITCOIN_VERSION="${BITCOIN_VERSION}" \
  --build-arg UID="${NODE_UID}" --build-arg GID="${NODE_GID}" \
  -t "local/bitcoind:${BITCOIN_VERSION}" \
  -f "${SCRIPT_DIR}/bitcoind.Dockerfile" "${SCRIPT_DIR}"

log "Building electrs image (this compiles rocksdb; give it a few minutes)"
sudo docker build \
  --build-arg ELECTRS_VERSION="${ELECTRS_VERSION}" \
  --build-arg UID="${NODE_UID}" --build-arg GID="${NODE_GID}" \
  -t "local/electrs:${ELECTRS_VERSION}" \
  -f "${SCRIPT_DIR}/electrs.Dockerfile" "${SCRIPT_DIR}"

# ------------------------------------------------------------------ 5. deploy stack
log "Deploying stack '${STACK_NAME}'"
sudo env \
  BITCOIN_VERSION="${BITCOIN_VERSION}" \
  ELECTRS_VERSION="${ELECTRS_VERSION}" \
  BITCOIN_DIR="${BITCOIN_DIR}" \
  docker stack deploy --resolve-image never \
  -c "${SCRIPT_DIR}/btc-stack.yml" "${STACK_NAME}"

# ------------------------------------------------------------------ 6. Sparrow (host)
log "Installing Sparrow ${SPARROW_VERSION}"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
cd "${TMP}"

tarball="sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz"
manifest="sparrow-${SPARROW_VERSION}-manifest.txt"
base="https://github.com/sparrowwallet/sparrow/releases/download/${SPARROW_VERSION}"
curl -fsSLO "${base}/${tarball}"
curl -fsSLO "${base}/${manifest}"
curl -fsSLO "${base}/${manifest}.asc"

# verify craig raw's signature over the manifest, then the tarball hash
curl -fsSL https://keybase.io/craigraw/pgp_keys.asc | gpg --import
gpg --verify "${manifest}.asc" "${manifest}"
grep " ${tarball}\$" "${manifest}" | sha256sum -c -

tar -xzf "${tarball}"        # extracts a capitalized 'Sparrow' dir
sudo rm -rf "${SPARROW_DIR}"
sudo mv Sparrow "${SPARROW_DIR}"
sudo chown -R "${NODE_UID}:${NODE_GID}" "${SPARROW_DIR}"

# desktop launcher
mkdir -p "${NODE_HOME}/.local/share/applications"
cat > "${NODE_HOME}/.local/share/applications/sparrow.desktop" <<DESKTOP
[Desktop Entry]
Name=Sparrow
Comment=Bitcoin Wallet
Exec=${SPARROW_DIR}/bin/Sparrow
Icon=${SPARROW_DIR}/lib/Sparrow.png
Terminal=false
Type=Application
Categories=Utility;Finance;
DESKTOP
chown "${NODE_UID}:${NODE_GID}" "${NODE_HOME}/.local/share/applications/sparrow.desktop"

# best-effort: point Sparrow at local electrs (won't overwrite an existing config)
mkdir -p "${NODE_HOME}/.sparrow"
if [ ! -f "${NODE_HOME}/.sparrow/config" ]; then
  install -o "${NODE_UID}" -g "${NODE_GID}" -m 0644 \
    "${SCRIPT_DIR}/sparrow-config.json" "${NODE_HOME}/.sparrow/config"
fi
chown -R "${NODE_UID}:${NODE_GID}" "${NODE_HOME}/.sparrow"

# ------------------------------------------------------------------ done
log "Done."
cat <<INFO

Stack:    sudo docker stack services ${STACK_NAME}
Logs:     sudo docker service logs -f ${STACK_NAME}_bitcoind
          sudo docker service logs -f ${STACK_NAME}_electrs
Sparrow:  ${SPARROW_DIR}/bin/Sparrow   (or the app menu)
Electrum: tcp://127.0.0.1:50001  (Private Electrum, SSL off)

INFO
