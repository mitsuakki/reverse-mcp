# Changelog

All notable changes to reverse-mcp

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- MCP gateway StreamableHTTP transport alongside stdio (#5)
- Claude Code RE agent system: triage, importer, analyst, debugger, orchestrator
- GitHub community health files: issue templates, PR template, dependabot, labeler
- NOTICE.md — third-party license catalog for all bundled tools
- CONTRIBUTING.md — contributor setup, PR process, code style guide
- SECURITY.md — vulnerability reporting, scope, security posture

### Changed
- MCP gateway: removed Docker socket dependency, switched to HTTP child transport
- MCP gateway: dynamic tool list refresh — new tools appear without restart
- README: rewritten for clarity on MCP HTTP endpoint, tool lifecycle, gateway architecture
- LICENSE: added scope clarification and pointer to NOTICE.md

### Removed
- Stale `docker/scripts/` directory — unused by Dockerfile
- Redundant `.claude/` from `.gitignore`

### Fixed
- Single MCP gateway entrypoint — no more scattered `.mcp.json` files
- Ghidra MCP classpath, `--bind` flag, auth token, health check at startup

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
- `load-ghidra.sh` CLI script for headless binary import

[Unreleased]: https://github.com/mitsuakki/reverse-mcp/compare/v1.0.0...main
[1.0.0]: https://github.com/mitsuakki/reverse-mcp/releases/tag/v1.0.0
