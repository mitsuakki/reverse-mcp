# reverse-mcp

Docker container for reverse engineering — radare2, Ghidra headless, angr, AFL++, honggfuzz, BinDiff, and Android tools, all wired as MCP servers behind a single HTTP endpoint. 

Works with Claude Code, Claude Desktop, Cline, Continue, or anyStreamableHTTP MCP client.
Headless only. No GUI, no VNC.

## Requirements

- Docker 23.0+ (BuildKit required)
- Docker Compose 2.0+

## Quick start

```bash
docker compose build
docker compose up -d
```

Gateway listens on `localhost:3100`. Drop binaries in `./workspace` — mounted at
`/workspace` inside the container.

```bash
docker exec -it toolbox bash   # optional shell access
```

### Resource requirements

| Resource | Minimum | Recommended | Notes |
|---|---|---|---|
| RAM | 8 GB | 16 GB | Ghidra alone uses 4 GB heap by default (`-Xmx4g`). Large binaries push it higher. angr symbolic execution can spike memory unpredictably. Running Ghidra + angr + fuzzing simultaneously: 16 GB minimum. |
| CPU | 4 cores | 8+ cores | Ghidra auto-analysis is multi-threaded and CPU-heavy. AFL++ and angr use all cores they can get. |
| Disk (image) | 10 GB | 20 GB | Image is ~4 GB. Build cache and intermediate layers eat another 6–10 GB during `docker compose build`. |
| Disk (workspace) | 5 GB | 50 GB | Depends on your binaries. Ghidra projects (in `ghidra-projects` volume) grow with analysis — a large binary can produce 500 MB+ of derived data. AFL++ corpora also grow fast. |

**With 8 GB RAM:** fine for one tool at a time — radare2, shell tools, or a small Ghidra session. Don't fuzz and decompile simultaneously.

**With 16 GB RAM:** Ghidra + angr + light fuzzing all at once. This is the sweet spot.

**With 32 GB RAM:** everything simultaneously. Run Ghidra auto-analysis, angr symbolic execution, AFL++, and have CPU left for the MCP gateway. No swapping.

If Docker on macOS/Windows is limited to 8 GB (Docker Desktop default):
raise it to 12+ GB in Docker Desktop → Settings → Resources → Memory.

### Image size

Final image: ~3.5–4 GB. The multi-stage build keeps it lean — build toolchains
(gcc, cmake, maven, rust) are discarded. What ships: Ubuntu 24.04 base + RE
tools + Ghidra + radare2 + Python stack. Ghidra alone is ~1.2 GB.

## ⚠️ Security warning

This container runs with **`SYS_PTRACE`** and **`seccomp:unconfined`** — required
by debuggers and fuzzers, but they strip away two key Docker security boundaries:

| What you lose | Why it matters |
|---|---|
| `seccomp:unconfined` | Docker's default seccomp profile blocks ~44 of 300+ syscalls. Disabling it lets any process in the container call any syscall — including `ptrace`, `process_vm_readv`, `process_vm_writev`, and `kexec`. A compromised or malicious binary can use syscalls that a default Docker container can't. |
| `SYS_PTRACE` | Lets processes read/write other processes' memory, registers, and syscall state. A debugger needs this. So does a rootkit. |
| `--privileged` (not used) | We don't go this far — no host device access, no cgroup escape. But `seccomp:unconfined` + `SYS_PTRACE` is enough for kernel exploit primitives if a binary escapes userspace. |

### What this means in practice

- **Analyzing trusted binaries (CTF challenges, your own code, known-clean samples):** safe on your daily driver. The container still has network and filesystem isolation.
- **Analyzing untrusted binaries (malware, suspicious downloads, bug bounties):** run inside a dedicated VM. Docker's isolation is not a sandbox — a malicious binary that exploits a kernel vulnerability can escape the container with these capabilities.
- **Fuzzing with ASAN/UBSAN:** ASAN sometimes needs `ptrace` for symbolization. If you're fuzzing untrusted code, run the fuzzer in a VM too.

### Recommended setup for untrusted work

```bash
# Option A: VM + Docker (strong)
# Spin up an Ubuntu VM in VirtualBox/UTM, install Docker inside it, run toolbox there.

# Option B: cloud VM (air-gapped from your network)
# Spin up a $0.05/hr cloud instance, git clone, docker compose up.

# Option C: tighten what you can
# Drop seccomp:unconfined but keep SYS_PTRACE if you only need gdb:
#   security_opt: []           # restore default seccomp profile
#   cap_add: [SYS_PTRACE]      # keep just this
# Some fuzzing tools (AFL++) will break — test first.
```

### Network exposure

The gateway (`localhost:3100`) and Ghidra headless (`localhost:8089`) have **no
authentication**. Default compose only exposes them to your loopback — safe. If you
change `ports` to `0.0.0.0:3100:3100`, anyone on your network can call MCP tools
(including `shell__exec` — arbitrary command execution inside the container).
**Don't expose these ports to a public network interface.**

## MCP

Copy the `toolbox` entry from [`.mcp.json`](.mcp.json) into your MCP client config:

```json
{
  "mcpServers": {
    "toolbox": {
      "type": "http",
      "url": "http://localhost:3100/mcp"
    }
  }
}
```

Claude Code users: the project `.mcp.json` auto-configures this. Other clients:

| Client | Config file |
|---|---|
| Claude Desktop | `claude_desktop_config.json` |
| Cline (VS Code) | `cline_mcp_settings.json` |
| Continue | `~/.continue/config.json` |
| Zed | `settings.json` → `context_servers` |

Restart the client after editing.

### Architecture

```
MCP client
  │  HTTP POST /mcp
  ▼
localhost:3100
  │
  ▼
┌─────────────────────────────────────────┐
│ toolbox container                       │
│                                         │
│  gateway.py --transport http :3100      │
│    ├─ r2pm -r r2mcp          → r2__*    │
│    ├─ bridge_mcp_ghidra.py   → ghidra__*│
│    ├─ shell-mcp.py            → shell__*│
│    └─ python3 -m angr.mcp     → angr__* │
└─────────────────────────────────────────┘
```

Gateway auto-starts all child servers at boot. Tools are namespaced so they never collide. 
Failed children don't block the gateway; it degrades with whatever connected.

### Server catalog

| Namespace | Server | Tools |
|---|---|---|
| `r2__*` | r2mcp | Disassembly, decompilation (r2ghidra), hexdump, xrefs, symbols, search |
| `ghidra__*` | Ghidra headless MCP | Import, auto-analysis, 200+ tools: decompile, patch, types, debugger, Bindiff |
| `shell__*` | shell-mcp.py | Arbitrary shell commands — angr, AFL++, gdb, apktool, jadx, python3, etc. |
| `angr__*` | angr.mcp | Project loading, CFG, symbolic execution, data dependency, VFG |

### Ghidra tool availability

Ghidra tools are dynamic — instance-scoped tools appear after loading a program:

```
import_file → auto-connect → schema fetch → all 200+ tools available
```

| Category | When available | Examples |
|---|---|---|
| Static | Always | `import_file`, `list_instances`, `connect_instance` |
| Instance-scoped | After connecting to loaded program | `decompile_function`, `list_functions`, `xrefs_to`, `disassemble_function`, debugger tools |

Use `check_tools` to see what's callable right now. 
Use `list_tool_groups` to see all categories and their load state.

### Ghidra GUI (optional)

Run Ghidra GUI on your host with the GhidraMCP plugin on port 8080:

```yaml
environment:
  - GHIDRA_MCP_URL=http://host.docker.internal:8080
```

The gateway's Ghidra bridge routes to your GUI instead of headless.

## Agents

`.claude/agents/` ships with specialized RE agents — loaded automatically by
Claude Code:

| Agent | Model | What it does |
|---|---|---|
| `binary-triage` | haiku | Fast radare2 first-look at unknown binary |
| `ghidra-importer` | sonnet | Import binary into Ghidra, run auto-analysis |
| `ghidra-analyst` | sonnet | Static RE — decompile, xrefs, rename, annotate |
| `ghidra-debugger` | sonnet | Dynamic analysis — attach, breakpoints, trace |
| `re-orchestrator` | opus | Full pipeline: triage → import → static → dynamic → report |

See [CLAUDE.md](CLAUDE.md) for usage examples and how to add your own agents.

## Tools inside the container

All pre-installed and on PATH:

| Category | Tools |
|---|---|
| Disassembly | radare2 (with r2ghidra), Ghidra headless, BinDiff |
| Debugging | gdb, gdb-multiarch, lldb, strace, ltrace |
| Binary analysis | angr, pwntools, ropper, ROPgadget, capstone, unicorn, keystone, LIEF |
| Fuzzing | AFL++, honggfuzz |
| Android | apktool, jadx, adb, frida, objection |
| Build | gcc, g++, clang, nasm, make, cmake |
| Utilities | python3, strings, objdump, patchelf, elfutils, vim, tmux |

Shell in with `docker exec -it toolbox bash`.

### Key scripts

```bash
/opt/tools/scripts/load-ghidra.sh /workspace/my-binary          # import + analyze
/opt/tools/scripts/load-ghidra.sh /workspace/my-binary myproj   # named project
```

## Troubleshooting

### MCP client not connecting

**Symptom:** "failed to connect" or "connection refused."

```bash
curl http://localhost:3100/mcp          # gateway responding?
docker ps --filter name=toolbox          # container running?
docker compose up -d                     # start if down
docker compose logs toolbox | tail -20   # check startup
```

If the container is running but the port is unreachable:

- **Wrong URL.** The endpoint is `/mcp`, not `/`. Client config: `http://localhost:3100/mcp`.
- **Docker Desktop (Windows/macOS).** Docker sometimes binds to the internal VM IP. Try `host.docker.internal:3100`.
- **Firewall / VPN.** Some VPN clients block `localhost`. Try `127.0.0.1`.
- **Client not restarted.** Most clients need a restart after config changes.
- **Port mapping.** `docker-compose.yml` must have `ports: ["3100:3100"]`.

### Ghidra headless server won't start

**Symptom:** `ghidra__*` tools missing, or gateway log shows "ghidra MCP: connection timed out."

```bash
docker exec toolbox cat /tmp/ghidra-mcp.log
```

| Error | Cause | Fix |
|---|---|---|
| `GhidraMCPHeadless.jar not found` | Build stage failed | `docker compose build --no-cache` |
| `java.lang.OutOfMemoryError` | 4GB heap too small | Edit `entrypoint.sh`: raise `-Xmx4g` to `-Xmx8g` |
| `Address already in use` | Stale container holding port 8089 | `docker compose down -v && docker compose up -d` |
| `Could not find or load main class` | Corrupted JAR or classpath | `docker compose build --no-cache` |
| Gateway "timed out" (>20s) | Slow first boot with large projects | `docker compose restart toolbox` |

Health check Ghidra directly:

```bash
curl -H "Authorization: Bearer re-toolbox-dev-secret" http://localhost:8089/health
```

If that passes but `ghidra__*` tools are still missing, the bridge process
(`bridge_mcp_ghidra.py`) crashed. Restart the container.

### SYS_PTRACE and seccomp:unconfined

**Symptom:** gdb, strace, or AFL++ return "Operation not permitted."

These tools need capabilities in `docker-compose.yml`:

```yaml
cap_add:
  - SYS_PTRACE
security_opt:
  - seccomp:unconfined
```

Additional causes:

- **AppArmor (Ubuntu/Debian host).** Some profiles deny ptrace even with `SYS_PTRACE`. Temporary fix: `sudo aa-teardown` (dev only). Permanent: `--security-opt apparmor:unconfined`.
- **Docker rootless.** Limited ptrace support. Use root Docker daemon for full RE tooling.
- **Custom daemon seccomp profile.** Check `/etc/docker/daemon.json` for a global `seccomp-profile` that overrides per-container settings.

### Build failures

```bash
DOCKER_BUILDKIT=1 docker compose build        # force BuildKit
docker compose build --no-cache               # bust stale cache
```

| Error | Cause | Fix |
|---|---|---|
| `failed to fetch ...` / 404 | Upstream URL changed (Ghidra, BinDiff) | Update version ARG + URL in `docker/Dockerfile` |
| `gcc: fatal error` / `mvn: not found` | Missing build dep or wrong stage | `docker compose build --no-cache` |
| Out of disk | Build cache bloat | `docker builder prune --all --force` |

### Gateway degraded — tools missing

**Symptom:** some namespaces don't appear in your client's tool list.

The gateway degrades gracefully — failed children don't block healthy ones.
Check the log:

```bash
docker exec toolbox cat /tmp/gateway-http.log
```

Lines like `r2 MCP: connection timed out — skipped` tell you which child failed.
`docker compose restart toolbox` retries all connections.

Per-child causes:

- **`r2__*` missing.** r2pm database stale or r2mcp patch didn't apply. Rebuild.
- **`ghidra__*` missing.** See Ghidra section above.
- **`shell__*` missing.** Rare — check gateway log for a Python traceback.
- **`angr__*` missing.** angr import slow on first launch. Gateway gives it 15s. If it times out regularly, raise `timeout_connect` in `gateway.py` line 94.

### General diagnostics

```bash
docker compose ps
docker compose logs toolbox --tail 50
curl -s http://localhost:3100/mcp
curl -s -H "Authorization: Bearer re-toolbox-dev-secret" http://localhost:8089/health
docker exec toolbox cat /tmp/gateway-http.log
docker exec toolbox cat /tmp/ghidra-mcp.log
docker exec toolbox ps aux | grep -E "gateway|ghidra|r2mcp|shell-mcp|angr"
```

`docker compose down -v` wipes the Ghidra project volume for a clean state.

## Project structure

```
.
├── .mcp.json                    MCP config — single HTTP entry
├── CLAUDE.md                    Agent reference + quickstart
├── docker-compose.yml
├── docker/
│   └── Dockerfile               Multi-stage build, pinned versions
├── scripts/
│   ├── entrypoint.sh            Starts Ghidra MCP + gateway
│   ├── load-ghidra.sh           CLI binary import into Ghidra
│   └── mcp/
│       ├── gateway.py           Composes all MCP servers behind one endpoint
│       └── shell-mcp.py         Shell command MCP server
├── .claude/
│   ├── agents/                  RE agents (auto-loaded by Claude Code)
│   └── settings.json            Project MCP config
└── workspace/                   Mounted at /workspace — put binaries here
```

## Security

See [⚠️ Security warning](#security-warning) above. Container capabilities,
isolation model, and recommendations for untrusted binaries are covered there.

Vulnerability reporting and scope: [SECURITY.md](SECURITY.md).
License for bundled tools: [NOTICE.md](NOTICE.md).
