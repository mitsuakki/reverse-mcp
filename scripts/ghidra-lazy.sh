#!/bin/bash
set -euo pipefail

# ============================================================================
# ghidra-lazy.sh — start Ghidra headless on demand, then exec the MCP bridge.
#
# Called by gateway.py as the ghidra child command. If headless is already
# running, skips straight to the bridge. Otherwise cold-starts the Java
# headless server, waits for it, then hands off to bridge_mcp_ghidra.py.
# ============================================================================

GHIDRA_MCP_PORT="${GHIDRA_MCP_PORT:-8089}"
GHIDRA_MCP_HOST="${GHIDRA_MCP_HOST:-0.0.0.0}"
GHIDRA_MCP_TOKEN="${GHIDRA_MCP_AUTH_TOKEN:-re-toolbox-dev-secret}"

# -- If headless already running, skip to bridge --------------------------------
if curl -sf -o /dev/null -H "Authorization: Bearer ${GHIDRA_MCP_TOKEN}" \
        "http://127.0.0.1:${GHIDRA_MCP_PORT}/health" 2>/dev/null; then
    echo "[ghidra-lazy] Headless already running on :${GHIDRA_MCP_PORT}" >&2
    exec python3 /opt/tools/ghidra-mcp/bridge_mcp_ghidra.py "$@"
fi

# -- Cold-start headless --------------------------------------------------------
GHIDRA_HOME="${GHIDRA_INSTALL_DIR:-/opt/tools/ghidra}"
GHIDRA_JAR="/opt/tools/ghidra-mcp/docker/GhidraMCPHeadless.jar"

if [[ ! -f "${GHIDRA_JAR}" ]]; then
    echo "[ghidra-lazy] FATAL: ${GHIDRA_JAR} not found — rebuild container" >&2
    exit 1
fi

echo "[ghidra-lazy] Cold-starting Ghidra headless on ${GHIDRA_MCP_HOST}:${GHIDRA_MCP_PORT}…" >&2

# Build classpath (same logic as entrypoint.sh)
CLASSPATH="${GHIDRA_JAR}"
for jar in "${GHIDRA_HOME}"/Ghidra/Framework/*/lib/*.jar; do
    [ -f "$jar" ] && CLASSPATH="${CLASSPATH}:${jar}"
done
for jar in "${GHIDRA_HOME}"/Ghidra/Features/*/lib/*.jar; do
    [ -f "$jar" ] && CLASSPATH="${CLASSPATH}:${jar}"
done
for jar in "${GHIDRA_HOME}"/Ghidra/Processors/*/lib/*.jar; do
    [ -f "$jar" ] && CLASSPATH="${CLASSPATH}:${jar}"
done

export GHIDRA_MCP_AUTH_TOKEN="${GHIDRA_MCP_TOKEN}"

java -Xmx4g -XX:+UseG1GC \
    -Dghidra.home="${GHIDRA_HOME}" \
    -Dapplication.name=GhidraMCP \
    -classpath "${CLASSPATH}" \
    com.xebyte.headless.GhidraMCPHeadlessServer \
    --bind "${GHIDRA_MCP_HOST}" \
    --port "${GHIDRA_MCP_PORT}" \
    &>/tmp/ghidra-mcp.log &

GHIDRA_PID=$!

# Wait for health endpoint
echo "[ghidra-lazy] Waiting for headless to be ready (pid ${GHIDRA_PID})…" >&2
for i in $(seq 1 30); do
    if curl -sf -o /dev/null -H "Authorization: Bearer ${GHIDRA_MCP_TOKEN}" \
            "http://127.0.0.1:${GHIDRA_MCP_PORT}/health" 2>/dev/null; then
        echo "[ghidra-lazy] Headless ready (pid ${GHIDRA_PID})" >&2
        break
    fi
    if ! kill -0 "${GHIDRA_PID}" 2>/dev/null; then
        echo "[ghidra-lazy] FATAL: headless died during startup. Log:" >&2
        tail -20 /tmp/ghidra-mcp.log >&2
        exit 1
    fi
    sleep 1
done

if ! kill -0 "${GHIDRA_PID}" 2>/dev/null; then
    echo "[ghidra-lazy] FATAL: headless failed to start" >&2
    exit 1
fi

# -- Hand off to bridge ---------------------------------------------------------
exec python3 /opt/tools/ghidra-mcp/bridge_mcp_ghidra.py "$@"
