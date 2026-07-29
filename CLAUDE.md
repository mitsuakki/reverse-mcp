# reverse-mcp — Claude Code agent system

## Start

```bash
docker compose up -d
```

Container named `toolbox`. MCP connection auto-configured via `.mcp.json`.

## Agents

| Agent | Trigger | What it does |
|---|---|---|
| `binary-triage` | "triage this binary", "first look at X" | Fast radare2 + shell assessment — format, strings, imports, suspicious indicators |
| `ghidra-importer` | "import X into Ghidra", "load this binary for analysis" | Import binary into Ghidra headless, run auto-analysis |
| `ghidra-analyst` | "analyze function X", "decompile Y", "trace xrefs" | Static RE — decompile, rename, annotate, cross-reference |
| `ghidra-debugger` | "debug X", "trace function Y", "set breakpoint at Z" | Dynamic analysis — attach, breakpoints, tracing, memory watch |
| `re-orchestrator` | "analyze this binary end-to-end", "full RE on X" | Master pipeline — triage → import → static → dynamic → report |

All agents use the MCP toolbox gateway — access to Ghidra, radare2, shell, and all CLI tools inside the container.

## Communication rules

- **NEVER use `docker exec`.** All container interaction goes through MCP tools:
  - Shell commands → `mcp__toolbox__shell__exec` (full CLI access, Docker socket available)
  - Binary analysis → `mcp__toolbox__r2__*` (radare2)
  - Static RE → `mcp__toolbox__ghidra__*` (Ghidra headless)
- Docker socket (`/var/run/docker.sock`) is available inside the container via `mcp__toolbox__shell__exec` — run nested containers, build images, or interact with the Docker daemon through the MCP shell tool.
- `Bash` tool runs on the HOST (WSL), not inside the container. Use only for git, file ops, and host-level tasks.

## Quick examples

```
triage this binary: /workspace/suspicious.elf
import /workspace/challenge.exe into Ghidra
decompile the function at 0x401000 and trace its xrefs
find all strings containing "http" in this binary
trace every call to D2Common.ordinal:10624 with arguments
full reverse engineering analysis on /workspace/malware.bin
```

## Adding new agents

Add `.md` files to `.claude/agents/`. Frontmatter:

```yaml
---
name: agent-name
description: One-line summary
model: haiku | sonnet | opus
tools: [Read, Bash, mcp__toolbox__ghidra__*, mcp__toolbox__r2__*, mcp__toolbox__shell__exec]
---
```

`tools` is optional — omit to inherit all tools from parent. MCP tools use the namespace prefix shown in the gateway: `mcp__toolbox__<namespace>__<tool_name>`.

## Architecture

```
Claude Code
  └─ docker exec -i toolbox python3 gateway.py    (.mcp.json)
       ├─ r2pm -r r2mcp               → r2__* tools
       ├─ bridge_mcp_ghidra.py         → ghidra__* tools (connects to :8089)
       └─ shell-mcp.py                 → shell__exec tool
```

Gateway auto-starts all children. Each child's tools get namespaced. Failed children don't block the gateway.

## Workspace

Drop binaries in `./workspace/` — mounted at `/workspace` inside container.
Ghidra projects persisted in Docker volume `ghidra-projects`.
