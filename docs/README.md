# @DISPLAY_NAME@ -- project agent docs

Project-specific agent guidance for @DISPLAY_NAME@ (this is the `docs/` directory). Generic workflow, ask, conventions, and security live in the **.agentstack** submodule:

- `.agentstack/docs/workflow.md`
- `.agentstack/docs/ask.md`
- `.agentstack/docs/conventions.md`

## Session startup

1. Run `scripts/init_grok_session.sh` or `scripts/init_claude_session.sh`
2. Read root `CLAUDE.md`; load 1-3 files from this directory (`docs/`) for the task

## Add project topics here

| File | Load when |
|------|-----------|
| `architecture.md` | System design, components, data flow |
| `cli.md` | CLI commands, flags, logs |
| `gotchas.md` | Non-obvious behavior, timing, hardware quirks |
| `configuration.md` | Env files, config paths |
| `testing.md` | Hardware validation checklist (extends generic template) |

Append to the smallest applicable file. Update `CLAUDE.md` when adding a new file.