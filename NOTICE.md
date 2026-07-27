# Third-party notices

reverse-mcp is MIT-licensed. The container image includes third-party tools with
their own licenses. None of these are linked into reverse-mcp code — they run as
separate processes inside the container.

## Bundled tools

| Tool | Version | License |
|---|---|---|
| Ghidra | 12.1.2 | Apache 2.0 |
| radare2 | 6.0.8 | LGPL-3.0 |
| r2ghidra | (r2pm) | LGPL-3.0 |
| AFL++ | 5.00c | Apache 2.0 |
| honggfuzz | 2.6 | Apache 2.0 |
| angr | 9.2.194 | BSD 2-Clause |
| jadx | 1.5.1 | Apache 2.0 |
| apktool | 2.10.0 | Apache 2.0 |
| Android platform-tools | 37.0.0 | Apache 2.0 |
| BinDiff | 8 | Proprietary |
| frida | 14.9.0 | wxWindows Library License |
| objection | 1.12.5 | GPL-3.0 |
| pwntools | 4.15.0 | MIT |
| LIEF | 0.17.6 | Apache 2.0 |
| capstone | (pip) | BSD 3-Clause |
| unicorn | (pip) | BSD 2-Clause |
| keystone-engine | 0.9.2 | MIT |
| ropper | 1.13.10 | BSD |
| ROPgadget | 7.6 | BSD |
| r2mcp | (r2pm) | MIT |
| ghidra-mcp | 5.13.1 | MIT |
| MCP Python SDK | 1.13.0 | MIT |
| pycparser | 2.22 | BSD |
| z3-solver | (pip) | MIT |
| claripy | (pip) | BSD 2-Clause |
| pyelftools | (pip) | Public Domain |

## License texts

Full license texts at upstream repositories:

- Apache 2.0: http://www.apache.org/licenses/LICENSE-2.0
- LGPL-3.0: https://www.gnu.org/licenses/lgpl-3.0.txt
- GPL-3.0: https://www.gnu.org/licenses/gpl-3.0.txt
- BSD 2-Clause: https://opensource.org/license/bsd-2-clause
- BSD 3-Clause: https://opensource.org/license/bsd-3-clause
- MIT: https://opensource.org/license/mit
- wxWindows: https://frida.re/docs/licensing/
- Public Domain (pyelftools): https://unlicense.org

## Binary-only component

BinDiff 8 is distributed as a prebuilt `.deb` from Google. It is not open source.
The Dockerfile downloads and installs it at build time. Users are responsible for
complying with Google's terms for BinDiff.

## No linkage

All third-party tools run as independent processes — no GPL or LGPL code is
linked into reverse-mcp's Python MCP servers. The container orchestrator
(`gateway.py`, `shell-mcp.py`, `bridge_mcp_ghidra.py`) communicates with tools
via stdio or HTTP.
