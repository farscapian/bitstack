# bitstack -- AI Development Notes (index)

**Load topic files on demand -- do not read this entire index repeatedly.**

## Quick rules

- Branding: always lowercase `bitstack`
- Text: ASCII-only in docs, logs, help, and code comments
- Agents work in session clones, NOT in the canonical local repo: Grok -> `~/.grok/worktrees/bitstack/<session-id>/`; Claude Code -> `~/.claude/worktrees/bitstack/<session-id>/`; CLI runs from `/home/derek/git/bitstack`
- Claude Code: NEVER edit files under `/home/derek/git/bitstack` -- use absolute paths to your session clone only
- New Grok session: run `scripts/init_grok_session.sh`; new Claude Code session: run `scripts/init_claude_session.sh` (see `.agentstack/docs/workflow.md`)
- After changes: commit in session clone; human runs `ask sync` then `git push origin main`. NEVER `git push origin` from agents (see `.agentstack/docs/ask.md`)

## Generic guidance (.agentstack submodule)

| File | Load when |
|------|-----------|
| [.agentstack/docs/workflow.md](.agentstack/docs/workflow.md) | Repos, session clones, git sync |
| [.agentstack/docs/ask.md](.agentstack/docs/ask.md) | `ask` handoff CLI |
| [.agentstack/docs/conventions.md](.agentstack/docs/conventions.md) | Naming, ASCII-only, output tags |
| [.agentstack/docs/terminal.md](.agentstack/docs/terminal.md) | Integrated-terminal copy-paste |
| [.agentstack/docs/security.md](.agentstack/docs/security.md) | Secrets, env files |
| [.agentstack/docs/code-quality.md](.agentstack/docs/code-quality.md) | shellcheck, git hooks |
| [.agentstack/docs/implementation.md](.agentstack/docs/implementation.md) | Common shell patterns |
| [.agentstack/docs/testing.md](.agentstack/docs/testing.md) | Generic pre-handoff checks |
| [.agentstack/docs/cli-conventions.md](.agentstack/docs/cli-conventions.md) | Extending `bitstack.sh` (CLI structure, flags, help) |
| [.agentstack/docs/cli-preamble.md](.agentstack/docs/cli-preamble.md) | The `cli-preamble.sh` provenance hook in `bitstack.sh main()` |

## Project guidance

| File | Load when |
|------|-----------|
| [docs/README.md](docs/README.md) | Project guidance index |
| [docs/cli.md](docs/cli.md) | `setup.sh` / `bitstack.sh` (up/down/reset), CLI layout |

Add project-specific topic files under `docs/` and extend this table.

## Project purpose

<!-- Describe what this project does in 2-3 sentences. -->

Origin: ``