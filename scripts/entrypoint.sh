#!/bin/bash
set -euo pipefail

# ============================================================================
# toolbox entrypoint — start background services, then hand off to CMD
# ============================================================================

if [[ "${ENABLE_GATEWAY_HTTP:-1}" == "1" ]]; then
    GATEWAY_PORT="${GATEWAY_HTTP_PORT:-3100}"
    GATEWAY_HOST="${GATEWAY_HTTP_HOST:-0.0.0.0}"
    echo "[entrypoint] Starting MCP gateway HTTP on ${GATEWAY_HOST}:${GATEWAY_PORT}…"
    python3 /opt/tools/scripts/mcp/gateway.py \
        --host "${GATEWAY_HOST}" \
        --port "${GATEWAY_PORT}" \
        &>/tmp/gateway-http.log &
    GATEWAY_PID=$!

    echo "[entrypoint] Waiting for MCP gateway to be ready…"
    GATEWAY_READY=0
    for i in $(seq 1 15); do
        if curl -sf -o /dev/null "http://127.0.0.1:${GATEWAY_PORT}/mcp" 2>/dev/null; then
            echo "[entrypoint] MCP gateway ready (pid ${GATEWAY_PID})"
            GATEWAY_READY=1
            break
        fi
        # If gateway process died, stop waiting — no point retrying.
        if ! kill -0 "${GATEWAY_PID}" 2>/dev/null; then
            echo "[entrypoint] WARNING: gateway process died. Check /tmp/gateway-http.log"
            break
        fi
        sleep 1
    done
    if [[ "${GATEWAY_READY}" -eq 0 ]]; then
        echo "[entrypoint] WARNING: gateway did not become ready within 15s"
    fi
fi

echo "[entrypoint] toolbox ready. Executing: $*"
exec "$@"
