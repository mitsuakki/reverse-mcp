#!/usr/bin/env python3
"""
Shell MCP server — exposes a single `exec` tool for running commands.

All tools exposed through the CLI: angr, AFL++, honggfuzz, bindiff, apktool,
jadx, radare2, ghidra headless, gcc, python3, gdb, etc.
"""

from __future__ import annotations

import asyncio
import logging
import os
import subprocess
import sys

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import TextContent, Tool

logging.basicConfig(
    level=logging.WARNING,
    format="%(asctime)s [shell-mcp] %(levelname)s: %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("shell-mcp")

BLOCKED_COMMANDS = [
    "rm -rf /",
    "mkfs.",
    "dd if=",
    ":(){ :|:& };:",  # fork bomb
]

MAX_OUTPUT_BYTES = 256 * 1024  # 256 KiB
DEFAULT_TIMEOUT = 60  # seconds
MAX_TIMEOUT = 300  # 5 minutes

CMD_DESCRIPTION = (
    "Execute a shell command inside the toolbox container. "
    "All CLI tools are available: angr, AFL++, honggfuzz, bindiff, apktool, "
    "jadx, radare2, Ghidra headless, gcc/clang, python3, gdb, strace, ltrace, etc. "
    "The command runs in a non-interactive shell (bash -c). "
    "Set workdir to change the working directory (default: /workspace)."
)

server = Server("shell-mcp")


@server.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="exec",
            description=CMD_DESCRIPTION,
            inputSchema={
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "Shell command to execute.",
                    },
                    "workdir": {
                        "type": "string",
                        "description": "Working directory. Defaults to /workspace.",
                    },
                    "timeout": {
                        "type": "integer",
                        "description": f"Timeout in seconds. Max {MAX_TIMEOUT}s. Default: {DEFAULT_TIMEOUT}s.",
                    },
                },
                "required": ["command"],
            },
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    if name != "exec":
        raise ValueError(f"Unknown tool: {name}")

    command: str = arguments["command"]
    workdir: str = arguments.get("workdir", "/workspace")
    timeout: int = min(
        int(arguments.get("timeout", DEFAULT_TIMEOUT)), MAX_TIMEOUT
    )

    for blocked in BLOCKED_COMMANDS:
        if blocked in command:
            return [TextContent(
                type="text",
                text=f"Blocked: command matches blocked pattern '{blocked}'",
            )]

    if not os.path.isdir(workdir):
        return [TextContent(
            type="text",
            text=f"Error: workdir does not exist: {workdir}",
        )]

    try:
        proc = await asyncio.create_subprocess_shell(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            cwd=workdir,
            executable="/bin/bash",
        )

        try:
            stdout, _ = await asyncio.wait_for(
                proc.communicate(), timeout=timeout
            )
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            return [TextContent(
                type="text",
                text=f"Command timed out after {timeout}s.\nPartial output:\n{_read_stdout(stdout) if 'stdout' in dir() else '(killed before output)'}",
            )]

        output = stdout.decode("utf-8", errors="replace") if stdout else "(no output)"
        if len(output) > MAX_OUTPUT_BYTES:
            output = output[:MAX_OUTPUT_BYTES] + f"\n\n[truncated at {MAX_OUTPUT_BYTES} bytes]"

        return [TextContent(
            type="text",
            text=f"Exit code: {proc.returncode}\n\n{output}",
        )]

    except FileNotFoundError:
        return [TextContent(type="text", text="Error: bash not found in container")]
    except Exception as exc:
        return [TextContent(type="text", text=f"Error: {exc}")]


def _read_stdout(stdout: bytes | None) -> str:
    if not stdout:
        return "(no output)"
    return stdout.decode("utf-8", errors="replace")[:MAX_OUTPUT_BYTES]


async def main() -> None:
    async with stdio_server() as (read, write):
        await server.run(read, write, server.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(main())
