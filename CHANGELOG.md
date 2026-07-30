# Changelog

All notable changes to reverse-mcp

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] — 2026-07-30

### Added
- MCP gateway StreamableHTTP transport alongside stdio (#5)
- Claude Code RE agent system: triage, importer, analyst, debugger, orchestrator
- GitHub community health files: issue templates, PR template, dependabot, labeler
- NOTICE.md — third-party license catalog for all bundled tools
- CONTRIBUTING.md — contributor setup, PR process, code style guide
- SECURITY.md — vulnerability reporting, scope, security posture
- CI smoke test expanded: RE tools test, CLI tools test, Android tools test
- CI conditional rebuild: skip full Docker build when image files unchanged, pull from GHCR
- CI profiler: build timing breakdown per step
- README: environment variables reference table (ENABLE_GATEWAY_HTTP, GATEWAY_HTTP_PORT, etc.)
- Shared argument parsing helpers (`arglib.sh`, `arglib.py`)
- Entrypoint gateway crash detection — stops retrying when gateway PID dies

### Changed
- MCP gateway: removed Docker socket dependency, switched to HTTP child transport
- MCP gateway: dynamic tool list refresh — new tools appear without restart
- MCP gateway: auto-restart crashed child MCP processes
- MCP gateway: lazy-start Ghidra headless on first tool call
- MCP gateway: improved error message for instance-scoped tools before binary load
- README: rewritten for clarity on MCP HTTP endpoint, tool lifecycle, gateway architecture
- README: added troubleshooting section, resource requirements, security tradeoffs, third-party config examples
- LICENSE: added scope clarification and pointer to NOTICE.md
- Dockerfile: apt/pip layer caching optimized for faster rebuilds
- Project naming normalized: "re-toolbox" → "reverse-mcp" across CLAUDE.md, auth tokens, issue templates

### Removed
- Stale `docker/scripts/` directory — unused by Dockerfile
- Redundant `.claude/` from `.gitignore`

### Fixed
- Single MCP gateway entrypoint — no more scattered `.mcp.json` files
- Ghidra MCP classpath, `--bind` flag, auth token, health check at startup
- Gateway crash at boot: `--transport http` flag removed from entrypoint (gateway.py dropped it in 75f907c)
- Gateway child process lifecycle: bypass AsyncExitStack to prevent orphaned MCP children
- ENABLE_GATEWAY_HTTP default mismatch: entrypoint.sh (`:-0`) now matches docker-compose.yml (`:-1`)
- angr 9.3+ compatibility: stdin API, fastmcp dependency
- Docker: python3-pygments added for Android tools test output
- Docker: jadx binary permissions fixed
- Docker: AFL++ and honggfuzz fetched via wget instead of git clone (more reliable)
- BUILD_FUZZING enabled by default in docker-compose.yml
- CI: merged into single job, fixed cross-runner image leak
- HelloWorld.apk test fixture: DEX adler32 checksum corrected

## [1.0.0] — 2026-07-27

### Added
- Docker container with Ubuntu 24.04 base
- MCP gateway composing r2, Ghidra, shell, and angr MCP servers
- Ghidra 12.1.2 headless with ghidra-mcp bridge
- radare2 6.0.8 from source with r2mcp, r2ghidra, r2ghidra-sleigh plugins
- angr 9.2.194 MCP integration
- Shell MCP server for arbitrary command execution inside container
- AFL++ 5.00c and honggfuzz 2.6 fuzzing tools
- Android platform-tools, apktool, jadx for APK analysis
- BinDiff 8 for binary diffing
- frida 14.9.0 and objection 1.12.5 for dynamic instrumentation
- pwntools 4.15.0, ropper, ROPgadget, keystone, LIEF, capstone, unicorn
- Project `.mcp.json` for Claude Code auto-configuration
- `tools/ghidra/import.sh` CLI script for headless binary import

[Unreleased]: https://github.com/mitsuakki/reverse-mcp/compare/v1.1.0...main
[1.1.0]: https://github.com/mitsuakki/reverse-mcp/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/mitsuakki/reverse-mcp/releases/tag/v1.0.0
