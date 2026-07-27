# Contributing

Thanks for wanting to contribute. This is a short guide.

## Setup

```bash
git clone https://github.com/mitsuakki/reverse-mcp.git
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
curl http://localhost:3100/mcp  # gateway responding?
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

1. Write the server (Python script that speaks MCP over stdio). Use
   `scripts/mcp/shell-mcp.py` as a minimal reference — `Server` + `list_tools` +
   `call_tool` + `stdio_server`. For HTTP servers, the gateway only speaks stdio
   to children; run your server's HTTP transport separately if needed.

2. Wire it in `gateway.py` — add a `ChildDef` entry at line ~90:

   ```python
   ChildDef(
       namespace="mytool",
       command="python3",
       args=["/opt/tools/scripts/mcp/my-tool.py"],
       timeout_connect=10.0,
   ),
   ```

3. Install any dependencies in the Dockerfile. Add a `RUN pip3 install` line in
   the `python` stage, or `apt-get install` in `base`. If your tool needs a build
   step, add a new stage (see `r2-ghidra` or `fuzzing` for patterns) and
   `COPY --from` in the `final` stage.

4. Pick a namespace prefix that won't collide (`r2`, `ghidra`, `shell`, `angr` are
   taken).

5. Update the server catalog in `README.md` and the architecture diagram in both
   `README.md` and `CLAUDE.md`.

6. If your tools change at runtime (appear/disappear after a state change), set
   `dynamic=True` on the `ChildDef` and add trigger tool names to
   `_REFRESH_TRIGGERS` in `gateway.py`.

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
