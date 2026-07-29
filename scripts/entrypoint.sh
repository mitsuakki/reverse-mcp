#!/bin/bash
set -euo pipefail

# ============================================================================
# toolbox entrypoint — start background services, then hand off to CMD
# ============================================================================

# -- Ghidra headless MCP HTTP server -----------------------------------------
# Ghidra headless is now started lazily by scripts/tools/ghidra/lazy-start.sh on first
# ghidra__* tool call. The gateway child command invokes the wrapper, which
# cold-starts headless if it isn't already running.

# -- MCP Gateway (StreamableHTTP) --------------------------------------------
if [[ "${ENABLE_GATEWAY_HTTP:-0}" == "1" ]]; then
    GATEWAY_PORT="${GATEWAY_HTTP_PORT:-3100}"
    GATEWAY_HOST="${GATEWAY_HTTP_HOST:-0.0.0.0}"
    echo "[entrypoint] Starting MCP gateway HTTP on ${GATEWAY_HOST}:${GATEWAY_PORT}…"
    python3 /opt/tools/scripts/mcp/gateway.py \
        --transport http \
        --host "${GATEWAY_HOST}" \
        --port "${GATEWAY_PORT}" \
        &>/tmp/gateway-http.log &
    GATEWAY_PID=$!

    echo "[entrypoint] Waiting for MCP gateway to be ready…"
    for i in $(seq 1 15); do
        if curl -sf -o /dev/null "http://127.0.0.1:${GATEWAY_PORT}/mcp" 2>/dev/null; then
            echo "[entrypoint] MCP gateway ready (pid ${GATEWAY_PID})"
            break
        fi
        sleep 1
    done
fi

# -- Hand off ----------------------------------------------------------------
echo "[entrypoint] toolbox ready. Executing: $*"
exec "$@"
