# bitstack CLI

Two entry points at the repo root, replacing the old `deploy-bitcoin-node.sh`:

- **`./setup.sh`** -- one-time (re-runnable) dependency install: apt prereqs,
  docker-ce, single-node swarm, builds the `local/bitcoind` and `local/electrs`
  images (GPG+SHA256 verified), installs Sparrow (host GUI wallet). Writes
  resolved image versions to `.bitstack-versions` (gitignored, machine-local)
  for `bitstack.sh` to read. Not a subcommand CLI -- just run it directly.

- **`./bitstack.sh`** -- runtime control of the docker-swarm stack, built to
  [.agentstack/docs/cli-conventions.md](../.agentstack/docs/cli-conventions.md)
  (single entrypoint + subcommand dispatch, external help files, tagged
  output via `.agentstack/scripts/lib/cli-log.sh`, the shared `cli-preamble.sh`
  provenance hook). Commands:
  - `bitstack up` -- prepare `~/.bitcoin` and deploy the stack (idempotent)
  - `bitstack down` -- stop the stack; node data is left in place
  - `bitstack reset` -- stop the stack, remove the electrs volume, and DELETE
    `~/.bitcoin/*`. Requires two interactive confirmations before deleting
    `blocks/`, `chainstate/`, or `wallets/` (or `-f/--force` to skip, for
    scripted use)

Terminal help: `bitstack help`, `bitstack <command> help`, or
`bitstack help <command>` -- see `docs/help/bitstack*.txt`.

Shared config (`BITSTACK_NODE_USER`, `BITSTACK_BITCOIN_DIR`, `BITSTACK_STACK_NAME`,
version resolution, stack-state helpers) lives in
[scripts/bitstack-common.sh](../scripts/bitstack-common.sh), sourced by both
entry points.

Both scripts must run as the configured node user (`derek`), never as root --
they call `sudo` themselves for the privileged steps (apt, docker).
