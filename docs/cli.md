# bitstack CLI

Two entry points at the repo root, replacing the old `deploy-bitcoin-node.sh`:

- **`./setup.sh`** -- one-time (re-runnable) dependency install: apt prereqs
  (including `jq`, used to patch Sparrow's config), docker-ce, single-node
  swarm. Does NOT build any docker images -- that is `bitstack up`'s job --
  and does NOT install Sparrow -- that is `bitstack sparrow`'s job, on its
  own first run. Not a subcommand CLI -- just run it directly. Also symlinks
  `bitstack.sh` to `/usr/local/bin/bitstack` (`sudo ln -sf`) so the bare
  `bitstack` command below works from anywhere; idempotent, and always
  resolves to the sibling `bitstack.sh` next to `setup.sh` (the canonical
  local repo, when the human runs it).

- **`bitstack.sh`** (bare command: `bitstack`, wired up by `./setup.sh`) --
  runtime control of the docker-swarm stack, built to
  [.agentstack/docs/cli-conventions.md](../.agentstack/docs/cli-conventions.md)
  (single entrypoint + subcommand dispatch, external help files, tagged
  output via `.agentstack/scripts/lib/cli-log.sh`, the shared `cli-preamble.sh`
  provenance hook). Commands:
  - `bitstack up` -- builds the `local/bitcoind`, `local/electrs`, and
    `local/tor` images (bitcoind/electrs GPG+SHA256 verified; tor is
    Debian's apt package), tagged by resolved version, skipping the build
    when a tag is already present locally. Then prepares `~/.bitcoin` and
    deploys the stack (idempotent). Also waits for the `tor` service to
    publish its hidden service and prints the onion address.
  - `bitstack down` -- stop the stack; node data is left in place
  - `bitstack restart` -- `bitstack down` followed by `bitstack up`
  - `bitstack reset` -- stop the stack, remove the electrs volume, and DELETE
    `~/.bitcoin/*`. Requires two interactive confirmations before deleting
    `blocks/`, `chainstate/`, or `wallets/` (or `-f/--force` to skip, for
    scripted use). Does NOT remove the Tor hidden-service volume -- the
    onion address stays stable across resets.
  - `bitstack bitcoin-cli [args...]` -- run `bitcoin-cli` inside the running
    bitcoind container (`docker exec`, same datadir as the node, so cookie
    auth just works). All arguments are forwarded verbatim to `bitcoin-cli`;
    unlike the other subcommands this one does NOT intercept a bare `help`
    argument, since `bitcoin-cli help` is itself a real RPC command. Use
    `bitstack help bitcoin-cli` for this wrapper's own help.
  - `bitstack tor` -- print the onion address publishing electrs' Electrum
    RPC port (50001), querying the running `tor` service and caching it to
    `.bitstack-onion` (gitignored, machine-local) for `bitstack sparrow` to
    read later, including from a host that does not run the stack itself.
  - `bitstack sparrow [local|onion]` -- install Sparrow (host GUI wallet)
    into `/opt/sparrow` if not already present, verifying the release
    tarball via GPG signature + SHA256 manifest (idempotent -- skipped once
    already installed), then launch it, patching `~/.sparrow/config`'s
    server fields (via `jq`) to point at either the local electrs
    (`tcp://127.0.0.1:50001`) or the onion endpoint. With no argument,
    auto-detects by checking whether something is listening on
    `127.0.0.1:50001` -- local when electrs is co-resident with the caller,
    onion otherwise. Onion connections need no manual proxy setup: Sparrow
    starts its own bundled Tor client when the server URL is a `.onion`
    address.

Terminal help: `bitstack help`, `bitstack <command> help`, or
`bitstack help <command>` -- see `docs/help/bitstack*.txt`.

Shared config (`BITSTACK_NODE_USER`, `BITSTACK_BITCOIN_DIR`, `BITSTACK_STACK_NAME`,
version resolution, stack-state helpers, onion-hostname/local-reachability
helpers) lives in [scripts/bitstack-common.sh](../scripts/bitstack-common.sh),
sourced by both entry points.

## Tor hidden service

The `tor` service in `btc-stack.yml` publishes electrs' Electrum RPC port
(50001) as a Tor v3 hidden service, so a remote Sparrow can reach the node
without any firewall port-forwarding. It has no published ports of its own --
only outbound access to the Tor network plus the `btc` overlay network to
reach `electrs:50001`. The hidden-service private key lives in the
`tor-hidden-service` docker volume, keeping the onion address stable across
`bitstack up`/`down`/`reset`; it only changes if that volume is removed by
hand (`docker volume rm`).

`torrc` (`/etc/tor/torrc` in the image) sets `SocksPort 0`: this daemon only
*publishes* the hidden service, it does not proxy outbound connections for
anyone. Clients reach the onion address with their own Tor client -- for
Sparrow specifically, its bundled Tor starts automatically the moment its
configured server is a `.onion` address (see `bitstack sparrow` above), no
separate `SocksPort`/proxy configuration needed.

`tor-entrypoint.sh` runs as root (no `USER` in `tor.Dockerfile`) and chowns
`/var/lib/tor` -- including the `tor-hidden-service` volume, root-owned by
default on first mount -- to `debian-tor` before exec'ing `tor`. Tor fixes
`DataDirectory` ownership itself when started as root, but treats a
`HiddenServiceDir` it doesn't already own as a hard security error and
refuses to fix it, so the docker volume needs that chown done for it on
every container start.

Both scripts must run as the configured node user (`BITSTACK_NODE_USER`,
defaults to the invoking user), never as root -- they call `sudo` themselves
for the privileged steps (apt, docker).
