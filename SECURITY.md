# Security

## Reporting a vulnerability

**Do not open a public issue.** Report vulnerabilities privately via
[GitHub Security Advisories](https://github.com/mitsuakki/reverse-mcp/security/advisories/new).

Include:

- Affected component and version
- Steps to reproduce
- Impact assessment (what the attacker gains)
- Any workaround you've found

Expect acknowledgment within 72 hours. We'll coordinate disclosure timing with you —
default 90-day window unless you request otherwise.

## Scope

Security reports are welcome for:

| Component | Notes |
|---|---|
| `gateway.py` | HTTP MCP gateway — request parsing, namespacing, child-server lifecycle |
| `shell-mcp.py` | Command execution — argument escaping, path traversal |
| `bridge_mcp_ghidra.py` | Bridge to Ghidra headless — auth, tool routing |
| `Dockerfile` and `docker-compose.yml` | Build-time and runtime hardening |
| `.mcp.json` and client config paths | Credential exposure, misconfiguration |
| `.claude/agents/` | Agent prompt injection vectors |

## What we don't consider in-scope

- Attacks that require the attacker to already have shell access inside the
  container (`docker exec`) — this is "root in the VM" equivalent.
- Vulnerabilities in upstream tools (Ghidra, radare2, angr, AFL++) unless our
  configuration or bridge code makes them exploitable in a way the upstream
  default doesn't.
- DoS by resource exhaustion (unlimited containers/CPU) on a locally-running
  development instance.

## Security posture

This is a **local development tool** — it runs on your machine, not in
production or on a public network. Key points:

1. **No authentication on the gateway.** It listens on `0.0.0.0:3100` inside
   the container. Only expose the port to your host loopback (`127.0.0.1`) —
   the default `docker-compose.yml` mapping. Never expose it to a public
   network interface.

2. **SYS_PTRACE and `seccomp:unconfined`.** Required by debuggers and fuzzers.
   These are standard for RE tooling containers but mean the container has
   elevated privileges. Run in an isolated VM when analyzing untrusted binaries.

3. **Binary safety.** The container provides interactive debugging and fuzzing
   tools. Analyzing malware or untrusted binaries should happen inside a
   dedicated VM, not on your daily driver.

4. **Dependencies.** `Dockerfile` pins specific versions of Ghidra, radare2,
   and other tools. We upgrade on a controlled cadence. If you find an outdated
   package with a known CVE, report it — we treat dependency CVEs the same as
   code vulnerabilities.
