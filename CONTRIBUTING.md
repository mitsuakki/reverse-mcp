# Contributing

Thanks for wanting to contribute. This is a short guide.

## Setup

```bash
git clone git@github:mitsuakki/reverse-mcp
cd reverse-mcp
docker compose build
docker compose up -d
```

Gateway listens on `localhost:3100`. Drop test binaries in `./workspace`.

## PR process

1. **Open an issue first** for anything bigger than a typo fix. Saves us both
   time.
2. **Branch from `main`.** Use a descriptive branch name: `fix/gateway-timeout`,
   `feat/python-tool`, `docs/contributing`.
3. **Keep PRs focused.** One thing per PR. Refactors mixed with features get
   held up.
4. **Write what you changed and why.** The PR template covers the rest.

## Build validation

```bash
docker compose build      # must succeed
docker compose up -d      # must start without errors
curl http://localhost:3100/check_connection  # gateway health check
```

If you change the Dockerfile, also verify:
```bash
docker compose down -v && docker compose build --no-cache && docker compose up -d
```

## Where things go

| What | Where |
|---|---|
| New MCP tool (ghidra bridge) | `scripts/mcp/bridge_mcp_ghidra.py` |
| New MCP tool (shell) | `scripts/mcp/shell-mcp.py` |
| Gateway logic | `scripts/mcp/gateway.py` |
| Docker packages / build | `docker/Dockerfile` |
| Agent definitions | `.claude/agents/*.md` |
| CI | `.github/workflows/` |
| Docs | `README.md`, `CLAUDE.md`, or new `.md` in root |

## Adding a new agent

Create `.claude/agents/<name>.md`:

```yaml
---
name: agent-name
description: One-line summary
model: haiku | sonnet | opus
tools: [Read, Bash, mcp__toolbox__ghidra__*, mcp__toolbox__r2__*]
---
```

Then write the agent instructions below the frontmatter. Keep agents
single-purpose — one agent per `.md`.

## Adding a new MCP server

1. Write the server (Python script that speaks MCP stdio or HTTP).
2. Wire it in `gateway.py` — add a `ServerProcess` entry.
3. Pick a namespace prefix that won't collide with existing ones.
4. Update the architecture diagram in `README.md` and the server catalog
   table plus CLAUDE.md.

## Code style

- Python: follow the surrounding code. `gateway.py` and `bridge_mcp_ghidra.py`
  are the reference.
- Shell scripts: `set -euo pipefail`, `shellcheck` clean.
- Markdown: one sentence per line. Fenced code blocks with language tags.

## Labels

The labeler bot auto-tags PRs by changed paths (`labeler.yml`). Core labels:

- `bug`, `enhancement` — issue type
- `docker`, `gateway`, `ghidra`, `shell-mcp`, `r2mcp`, `angr`, `agents`, `docs`, `ci` — component touched
- `triage` — auto-applied to new issues; removed on first human review
- `breaking-change` — manual; marks PRs that need migration

## License

MIT. By contributing, you agree your code goes under the same license.
