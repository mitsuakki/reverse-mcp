#!/bin/bash
set -euo pipefail

# ============================================================================
# lazy-start.sh — start Ghidra headless on demand, then exec the MCP bridge.
#
# Called by gateway.py as the ghidra child command. If headless is already
# running, skips straight to the bridge. Otherwise cold-starts the Java
# headless server, waits for it, then hands off to bridge_mcp_ghidra.py.
# ============================================================================

SCRIPT_NAME="ghidra-lazy"
source "$(dirname "$0")/../../common/arglib.sh"

GHIDRA_MCP_PORT="${GHIDRA_MCP_PORT:-8089}"
GHIDRA_MCP_HOST="${GHIDRA_MCP_HOST:-0.0.0.0}"
GHIDRA_MCP_TOKEN="${GHIDRA_MCP_AUTH_TOKEN:-re-toolbox-dev-secret}"

# If already running, skip to bridge
if curl -sf -o /dev/null -H "Authorization: Bearer ${GHIDRA_MCP_TOKEN}" \
        "http://127.0.0.1:${GHIDRA_MCP_PORT}/health" 2>/dev/null; then
    log "Headless already running on :${GHIDRA_MCP_PORT}"
    exec python3 /opt/tools/ghidra-mcp/bridge_mcp_ghidra.py "$@"
fi

# Cold-start headless
GHIDRA_HOME="${GHIDRA_INSTALL_DIR:-/opt/tools/ghidra}"
GHIDRA_JAR="/opt/tools/ghidra-mcp/docker/GhidraMCPHeadless.jar"

if [[ ! -f "${GHIDRA_JAR}" ]]; then
    die "${GHIDRA_JAR} not found — rebuild container"
fi

log "Cold-starting Ghidra headless on ${GHIDRA_MCP_HOST}:${GHIDRA_MCP_PORT}…"

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
log "Waiting for headless to be ready (pid ${GHIDRA_PID})…"
for i in $(seq 1 30); do
    if curl -sf -o /dev/null -H "Authorization: Bearer ${GHIDRA_MCP_TOKEN}" \
            "http://127.0.0.1:${GHIDRA_MCP_PORT}/health" 2>/dev/null; then
        log "Headless ready (pid ${GHIDRA_PID})"
        break
    fi
    if ! kill -0 "${GHIDRA_PID}" 2>/dev/null; then
        log "FATAL: headless died during startup. Log:"
        tail -20 /tmp/ghidra-mcp.log >&2
        die "headless died during startup"
    fi
    sleep 1
done

if ! kill -0 "${GHIDRA_PID}" 2>/dev/null; then
    die "headless failed to start"
fi

# Hand off to bridge
exec python3 /opt/tools/ghidra-mcp/bridge_mcp_ghidra.py "$@"
