#!/usr/bin/env python3
"""
MCP Gateway — single entry point composing all toolbox MCP servers.

Spawns child MCP servers as subprocesses, proxies all tools/resources/prompts
with namespaced names so Claude Desktop needs only ONE MCP config entry.

Children:
  r2__*      — radare2 analysis (r2mcp via r2pm)
  ghidra__*  — Ghidra headless decompilation (bridge_mcp_ghidra.py)
  shell__*   — arbitrary shell commands
  angr__*    — angr binary analysis framework (angr.mcp)

Usage (in container):
  python3 /opt/tools/scripts/mcp/gateway.py

Claude Desktop config (single entry):
  {
    "toolbox": {
      "command": "docker",
      "args": ["exec", "-i", "toolbox", "python3", "/opt/tools/scripts/mcp/gateway.py"]
    }
  }
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys
from contextlib import AsyncExitStack
from dataclasses import dataclass, field
from typing import Any

try:
    from anyio import BrokenResourceError, ClosedResourceError
except ImportError:
    BrokenResourceError = Exception  # type: ignore[assignment,misc]
    ClosedResourceError = Exception  # type: ignore[assignment,misc]

from mcp import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import (
    CallToolResult,
    EmbeddedResource,
    ImageContent,
    TextContent,
    Tool,
)

# Logging to stderr so stdout stays clean for MCP transport
logging.basicConfig(
    level=logging.WARNING,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("gateway")

@dataclass
class ChildDef:
    namespace: str
    command: str
    args: list[str] = field(default_factory=list)
    env: dict[str, str] = field(default_factory=dict)
    timeout_connect: float = 15.0  # generous — ghidra bridge can be slow
    dynamic: bool = False  # True = tools change at runtime (e.g. after import_file)
    lazy: bool = False  # True = defer connection until first tool call
    # Crash recovery: max auto-restart attempts (0 = disabled, -1 = unlimited).
    # Restart spawns fresh child process and re-registers tools.
    max_restarts: int = 0
    restart_delay: float = 2.0  # seconds between restart attempts
    # For lazy children: tool names that are always available (registered as
    # placeholders so the MCP client can discover them before connection).
    static_tools: list[str] = field(default_factory=list)


CHILDREN: list[ChildDef] = [
    ChildDef(
        namespace="r2",
        command="r2pm",
        args=["-r", "r2mcp"],
    ),
    ChildDef(
        namespace="ghidra",
        command="/opt/tools/scripts/tools/ghidra/lazy-start.sh",
        args=[],
        env={"GHIDRA_MCP_URL": os.environ.get("GHIDRA_MCP_URL", "http://127.0.0.1:8089")},
        timeout_connect=45.0,  # headless cold-start is slow
        dynamic=True,
        lazy=True,  # only start Ghidra on first ghidra__* tool call
        max_restarts=3,  # auto-restart if headless crashes
        static_tools=[  # always-available tools — registered as placeholders
            "import_file",
            "list_instances",
            "connect_instance",
            "disconnect_instance",
            "list_tool_groups",
            "load_tool_group",
            "check_tools",
        ],
    ),
    ChildDef(
        namespace="shell",
        command="python3",
        args=["/opt/tools/scripts/mcp/shell-mcp.py"],
    ),
    ChildDef(
        namespace="angr",
        command="python3",
        args=["-m", "angr.mcp"],
        timeout_connect=15.0,
    ),
]

class Gateway:
    """Composes child MCP servers behind a single stdio transport."""

    # Tools whose success triggers a tool-list refresh on dynamic children
    _REFRESH_TRIGGERS = {"import_file", "connect_instance"}

    def __init__(self) -> None:
        self.server = Server("toolbox-gateway")
        self._exit_stack = AsyncExitStack()
        self._children: dict[str, ClientSession] = {}
        self._child_defs: dict[str, ChildDef] = {}
        # namespaced_name -> (namespace, original_name, Tool)
        self._tools: dict[str, tuple[str, str, Tool]] = {}
        self._tools_lock = asyncio.Lock()
        # Crash recovery: per-namespace restart counts and per-namespace locks
        # to prevent concurrent restarts from racing.
        self._restart_counts: dict[str, int] = {}
        self._restart_locks: dict[str, asyncio.Lock] = {}
        # Transport/session cleanup handles. Stored OUTSIDE _exit_stack because
        # lazy children connect from call_tool (different anyio task than start()),
        # and anyio rejects cross-task cancel-scope exit with RuntimeError.
        # Each entry: (transport_ctx, session_ctx) — async context managers.
        self._child_cleanup: dict[str, tuple[Any, Any]] = {}
        self._transports: dict[str, tuple[Any, Any]] = {}

    async def _connect_child(self, child: ChildDef) -> ClientSession:
        """Launch child process and return initialized session.

        Enters stdio_client/ClientSession directly in the CURRENT task.
        Does NOT use AsyncExitStack — lazy children connect from a
        different task than start(), and anyio rejects cross-task
        cancel-scope exit. Cleanup handles are stored in _child_cleanup.
        """
        env = os.environ.copy()
        env.update(child.env)

        params = StdioServerParameters(
            command=child.command,
            args=child.args,
            env=env,
        )

        # Enter contexts directly in the calling task
        transport_ctx = stdio_client(params)
        read, write = await transport_ctx.__aenter__()
        session_ctx = ClientSession(read, write)
        session = await session_ctx.__aenter__()

        self._child_cleanup[child.namespace] = (transport_ctx, session_ctx)
        self._transports[child.namespace] = (read, write)

        await session.initialize()
        return session

    @staticmethod
    def _is_transport_error(exc: BaseException) -> bool:
        """True when `exc` is a transport/connection failure, not a tool error.

        Tool-level errors return `isError: true` results — they don't raise.
        Exceptions from `session.call_tool` mean the transport itself is dead:
        subprocess crashed, pipe closed, or timeout.
        """
        if isinstance(exc, (BrokenResourceError, ClosedResourceError,
                            BrokenPipeError, ConnectionResetError, EOFError)):
            return True
        # MCP SDK wraps some transport errors in RuntimeError
        if isinstance(exc, RuntimeError):
            msg = str(exc).lower()
            if any(kw in msg for kw in ("not connected", "closed", "broken",
                                         "connection", "transport")):
                return True
        return False

    async def _disconnect_child(self, ns: str) -> None:
        """Tear down one child's session and transport. Best-effort.

        Uses the stored async context managers from _child_cleanup so
        cleanup happens in the correct anyio task context.
        """
        self._children.pop(ns, None)
        self._transports.pop(ns, None)
        transport_ctx, session_ctx = self._child_cleanup.pop(ns, (None, None))

        if session_ctx is not None:
            try:
                await session_ctx.__aexit__(None, None, None)
            except Exception:
                pass
        if transport_ctx is not None:
            try:
                await transport_ctx.__aexit__(None, None, None)
            except Exception:
                pass

    async def _restart_child(self, ns: str) -> ClientSession:
        """Disconnect a dead child, spawn fresh process, re-register tools.

        Returns the new session. Raises on failure — caller should guard
        with the restart limit.
        """
        child_def = self._child_defs.get(ns)
        if child_def is None:
            raise RuntimeError(f"No child definition for namespace: {ns}")

        log.warning("%s: restarting crashed child process…", ns)

        # Tear down old transport
        await self._disconnect_child(ns)

        # Remove stale tools for this namespace
        async with self._tools_lock:
            stale = [k for k, v in self._tools.items() if v[0] == ns]
            for k in stale:
                del self._tools[k]

        # Spawn fresh child
        await asyncio.sleep(child_def.restart_delay)
        session = await asyncio.wait_for(
            self._connect_child(child_def),
            timeout=child_def.timeout_connect,
        )
        self._children[ns] = session

        # Re-register tools
        tools_result = await session.list_tools()
        async with self._tools_lock:
            for tool in tools_result.tools:
                ns_name = self._ns_name(ns, tool.name)
                self._tools[ns_name] = (ns, tool.name, tool)

        log.info("%s: restarted successfully (%d tools)", ns, len(tools_result.tools))
        return session

    async def _connect_and_register(self, child_def: ChildDef) -> None:
        """Connect one child and register its tools. Shared by start() and lazy connect."""
        ns = child_def.namespace
        log.info("connecting %s MCP (%s %s)…", ns, child_def.command, " ".join(child_def.args))
        session = await asyncio.wait_for(
            self._connect_child(child_def),
            timeout=child_def.timeout_connect,
        )
        self._children[ns] = session
        self._child_defs[ns] = child_def

        tools_result = await session.list_tools()
        async with self._tools_lock:
            for tool in tools_result.tools:
                ns_name = self._ns_name(ns, tool.name)
                self._tools[ns_name] = (ns, tool.name, tool)
                log.info("  tool: %s", ns_name)

        if not tools_result.tools:
            log.warning("  %s MCP: no tools exposed (may be dynamic)", ns)

        log.info("%s MCP connected (%d tools)", ns, len(tools_result.tools))

    async def start(self) -> None:
        """Connect eager children and register their tools. Lazy children wait."""

        for child_def in CHILDREN:
            if child_def.lazy:
                self._child_defs[child_def.namespace] = child_def
                # Register placeholder tools so MCP client can discover the
                # namespace before connection. Real tools replace these on
                # first call (via _connect_and_register).
                async with self._tools_lock:
                    for tool_name in child_def.static_tools:
                        ns_name = self._ns_name(child_def.namespace, tool_name)
                        self._tools[ns_name] = (
                            child_def.namespace,
                            tool_name,
                            Tool(name=tool_name, description="", inputSchema={"type": "object", "properties": {}}),
                        )
                log.info("%s MCP: deferred (lazy, %d placeholder tools)",
                         child_def.namespace, len(child_def.static_tools))
                continue
            try:
                await self._connect_and_register(child_def)
            except asyncio.TimeoutError:
                log.error("%s MCP: connection timed out after %ss — skipped",
                          child_def.namespace, child_def.timeout_connect)
            except Exception:
                log.exception("%s MCP: failed to start — skipped", child_def.namespace)

        if not self._children:
            log.error("No child MCPs connected — gateway is empty")

        self._register_handlers()

    async def _refresh_child_tools(self, ns: str) -> None:
        """Re-fetch tool list from a dynamic child after instance state change."""
        session = self._children.get(ns)
        if not session:
            return
        try:
            tools_result = await session.list_tools()
            async with self._tools_lock:
                # Remove old tools for this namespace
                stale = [k for k, v in self._tools.items() if v[0] == ns]
                for k in stale:
                    del self._tools[k]
                # Register current tools
                for tool in tools_result.tools:
                    ns_name = self._ns_name(ns, tool.name)
                    self._tools[ns_name] = (ns, tool.name, tool)
            log.info("refreshed %s tools: %d total", ns, len(tools_result.tools))
        except Exception:
            log.exception("failed to refresh %s tools", ns)

    @staticmethod
    def _ns_name(ns: str, name: str) -> str:
        return f"{ns}__{name}"

    def _register_handlers(self) -> None:
        server = self.server

        @server.list_tools()
        async def list_tools() -> list[Tool]:
            async with self._tools_lock:
                tools: list[Tool] = []
                for ns_name, (_ns, _orig, tool) in sorted(self._tools.items()):
                    tools.append(Tool(
                        name=ns_name,
                        description=f"[{_ns}] {tool.description or ''}",
                        inputSchema=tool.inputSchema,
                    ))
                return tools

        @server.call_tool()
        async def call_tool(
            name: str, arguments: dict[str, Any]
        ) -> list[TextContent | ImageContent | EmbeddedResource]:
            async with self._tools_lock:
                if name not in self._tools:
                    raise ValueError(f"Unknown tool: {name}")
                ns, orig_name, _tool = self._tools[name]

            # Lazy connect: child not started yet — start it now.
            # Only possible for static tools registered via child_def placeholder.
            if ns not in self._children:
                child_def = self._child_defs.get(ns)
                if child_def and child_def.lazy:
                    try:
                        await self._connect_and_register(child_def)
                    except Exception:
                        log.exception("lazy connect failed for %s", ns)
                        raise ValueError(f"Failed to start {ns} MCP server")
                else:
                    raise ValueError(f"MCP server not connected: {ns}")

            session = self._children[ns]

            child_def = self._child_defs.get(ns)
            max_restarts = child_def.max_restarts if child_def else 0

            try:
                result: CallToolResult = await session.call_tool(orig_name, arguments)
            except Exception as exc:
                if max_restarts > 0 and self._is_transport_error(exc):
                    # Serialise restarts per namespace so concurrent calls
                    # don't spawn N child processes.
                    lock = self._restart_locks.setdefault(ns, asyncio.Lock())
                    async with lock:
                        count = self._restart_counts.get(ns, 0)
                        if count >= max_restarts:
                            log.error("%s: restart limit reached (%d/%d) — giving up",
                                      ns, count, max_restarts)
                            raise
                        self._restart_counts[ns] = count + 1
                        log.warning("%s: child crashed (%s), restarting (%d/%d)…",
                                    ns, exc, count + 1, max_restarts)
                        session = await self._restart_child(ns)
                    # Retry the call once after restart
                    result = await session.call_tool(orig_name, arguments)
                else:
                    raise

            # Ghidra tools are dynamic: after import_file or connect_instance,
            # new instance-scoped tools (decompile, list_functions, debugger, …)
            # become available on the bridge. Refresh so they appear in list_tools.
            if child_def and child_def.dynamic and orig_name in self._REFRESH_TRIGGERS:
                await self._refresh_child_tools(ns)

            return result.content

        @server.list_resources()
        async def list_resources():
            resources: list[Any] = []
            for ns, session in sorted(self._children.items()):
                try:
                    res = await session.list_resources()
                    for r in res.resources:
                        r.name = self._ns_name(ns, r.name)
                        if hasattr(r, "uri"):
                            r.uri = f"{ns}__{r.uri}"
                        resources.append(r)
                except Exception as exc:
                    child_def = self._child_defs.get(ns)
                    if child_def and child_def.max_restarts > 0 and self._is_transport_error(exc):
                        log.warning("%s: dead during list_resources, skipping", ns)
                    else:
                        pass  # child may not support resources
            return resources

        @server.list_prompts()
        async def list_prompts():
            prompts: list[Any] = []
            for ns, session in sorted(self._children.items()):
                try:
                    res = await session.list_prompts()
                    for p in res.prompts:
                        p.name = self._ns_name(ns, p.name)
                        prompts.append(p)
                except Exception as exc:
                    child_def = self._child_defs.get(ns)
                    if child_def and child_def.max_restarts > 0 and self._is_transport_error(exc):
                        log.warning("%s: dead during list_prompts, skipping", ns)
                    else:
                        pass
            return prompts

        # read_resource and get_prompt are routed dynamically
        @server.read_resource()
        async def read_resource(uri: str):
            for ns, session in self._children.items():
                prefix = f"{ns}__"
                if uri.startswith(prefix):
                    child_uri = uri[len(prefix):]
                    return await session.read_resource(child_uri)
            raise ValueError(f"No child handles resource: {uri}")

        @server.get_prompt()
        async def get_prompt(name: str, arguments: dict[str, str] | None = None):
            for ns, session in self._children.items():
                prefix = f"{ns}__"
                if name.startswith(prefix):
                    child_name = name[len(prefix):]
                    return await session.get_prompt(child_name, arguments)
            raise ValueError(f"No child handles prompt: {name}")

    async def close(self) -> None:
        # Tear down children managed outside _exit_stack first
        for ns in list(self._child_cleanup.keys()):
            await self._disconnect_child(ns)
        # Then clean up any remaining exit-stack resources
        await self._exit_stack.aclose()

    async def run_stdio(self) -> None:
        """Serve via stdio (docker exec transport)."""
        async with stdio_server() as (read, write):
            await self.server.run(
                read, write, self.server.create_initialization_options()
            )

    async def run_http(self, host: str = "0.0.0.0", port: int = 3100) -> None:
        """Serve via StreamableHTTP (browser/remote transport)."""
        import uvicorn
        from mcp.server.streamable_http import StreamableHTTPServerTransport

        transport = StreamableHTTPServerTransport(mcp_session_id=None)

        # Minimal ASGI wrapper so uvicorn can serve at /mcp
        async def asgi_app(scope, receive, send):
            if scope["type"] == "lifespan":
                # Accept lifespan startup/shutdown — no-op
                while True:
                    message = await receive()
                    if message["type"] == "lifespan.startup":
                        await send({"type": "lifespan.startup.complete"})
                    elif message["type"] == "lifespan.shutdown":
                        await send({"type": "lifespan.shutdown.complete"})
                        return
            else:
                await transport.handle_request(scope, receive, send)

        config = uvicorn.Config(
            asgi_app, host=host, port=port, log_level="warning",
        )
        httpd = uvicorn.Server(config)

        async with transport.connect() as (read, write):
            await asyncio.gather(
                httpd.serve(),
                self.server.run(
                    read, write, self.server.create_initialization_options(),
                ),
            )


# Entry point

async def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="MCP Gateway")
    parser.add_argument(
        "--transport", choices=("stdio", "http"), default="stdio",
        help="Transport mode (default: stdio)",
    )
    parser.add_argument(
        "--host", default="0.0.0.0", help="HTTP bind address (default: 0.0.0.0)",
    )
    parser.add_argument(
        "--port", type=int, default=3100, help="HTTP port (default: 3100)",
    )
    args = parser.parse_args()

    gateway = Gateway()
    try:
        await gateway.start()
        if args.transport == "http":
            await gateway.run_http(host=args.host, port=args.port)
        else:
            await gateway.run_stdio()
    finally:
        await gateway.close()


if __name__ == "__main__":
    asyncio.run(main())
