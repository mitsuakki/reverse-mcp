#!/bin/bash
set -euo pipefail

# ============================================================================
# smoke-test.sh — verify every MCP server in the toolbox container responds.
#
# Builds the image, starts the container, then probes each child MCP server
# (gateway, radare2, Ghidra headless, shell, angr). Exits non-zero if any
# check fails.
#
# Usage:
#   ./scripts/tests/smoke-test.sh                # full build + test + cleanup
#   ./scripts/tests/smoke-test.sh --no-build     # skip docker compose build
#   ./scripts/tests/smoke-test.sh --no-cleanup   # leave container running
#   ./scripts/tests/smoke-test.sh --verbose      # show diagnostic output
# ============================================================================

SCRIPT_NAME="smoke-test"
source "$(dirname "$0")/../common/arglib.sh"

# --- defaults ---------------------------------------------------------------
DO_BUILD=1
DO_CLEANUP=1
GATEWAY_PORT="${GATEWAY_PORT:-3100}"
GHIDRA_MCP_PORT="${GHIDRA_MCP_PORT:-8089}"
GHIDRA_MCP_TOKEN="${GHIDRA_MCP_AUTH_TOKEN:-re-toolbox-dev-secret}"
STARTUP_WAIT=60
RESULTS=()

# --- usage ------------------------------------------------------------------
usage() {
    echo "Usage: $(basename "$0") [options]"
    echo
    echo "  Smoke-test every MCP server in the toolbox container."
    echo
    echo "Options:"
    echo "  --no-build     Skip docker compose build (use existing image)"
    echo "  --no-cleanup   Leave container running after test"
    echo "  --verbose, -v  Verbose output"
    echo "  --help, -h     Show this help"
    echo
    echo "CI example:"
    echo "  $0                     # full cycle: build, test, cleanup"
    echo "  $0 --no-build          # test existing image"
    exit 0
}

# --- args ------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build)   DO_BUILD=0; shift ;;
        --no-cleanup) DO_CLEANUP=0; shift ;;
        --verbose|-v) VERBOSE=1; shift ;;
        --help|-h)    usage ;;
        *)            die "Unknown argument: $1" ;;
    esac
done

# --- helpers ----------------------------------------------------------------

_pass() {
    RESULTS+=("PASS")
    echo "  [PASS] $1"
}

_fail() {
    RESULTS+=("FAIL")
    echo "  [FAIL] $1 — $2" >&2
}

_check() {
    local label="$1" cmd="$2"
    local output rc

    echo
    echo "--- $label ---"
    [[ -n "${VERBOSE:-}" ]] && echo "  command: $cmd" || true

    output="$(eval "$cmd" 2>&1)" && rc=$? || rc=$?

    if [[ $rc -eq 0 ]]; then
        _pass "$label"
        [[ -n "${VERBOSE:-}" ]] && echo "  output: $output" || true
    else
        _fail "$label" "exit=$rc"
        echo "  output: $output" >&2
    fi
}

# ---- main ------------------------------------------------------------------

echo "=== toolbox smoke test ==="
echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# -- build -------------------------------------------------------------------
if [[ "$DO_BUILD" -eq 1 ]]; then
    echo
    echo "--- Build ---"
    docker compose build 2>&1 | tail -5
    echo "Build done."
fi

# -- start -------------------------------------------------------------------
echo
echo "--- Start ---"
docker compose up -d 2>&1

# -- wait for gateway ---------------------------------------------------------
echo
echo "--- Wait for gateway (max ${STARTUP_WAIT}s) ---"
GATEWAY_READY=0
for i in $(seq 1 "$STARTUP_WAIT"); do
    # StreamableHTTP MCP returns 406 for bare GET — that's a live server.
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${GATEWAY_PORT}/mcp" 2>/dev/null | grep -qE "^(406|200)"; then
        echo "Gateway ready after ${i}s."
        GATEWAY_READY=1
        break
    fi
    sleep 1
done

if [[ "$GATEWAY_READY" -eq 0 ]]; then
    echo "FATAL: gateway did not respond within ${STARTUP_WAIT}s" >&2
    echo "Container logs:" >&2
    docker compose logs --tail=30 >&2
    exit 1
fi

# -- gateway HTTP check ------------------------------------------------------
_check "gateway-http" \
    "curl -s -o /dev/null -w '%{http_code}' http://localhost:${GATEWAY_PORT}/mcp | grep -qE '^(406|200)'"

# -- radare2 -----------------------------------------------------------------
# Verify r2 binary works — r2mcp child uses the same binary.
_check "radare2" \
    "docker exec toolbox r2 -q -c '?e smoke-ok' /bin/true 2>&1 | grep -q 'smoke-ok'"

# -- ghidra headless ---------------------------------------------------------
# Lazy-start: headless may not be running. If health endpoint is cold,
# start headless in the background, wait for health, then kill it.
_check_ghidra() {
    local label="ghidra-headless"

    echo
    echo "--- $label ---"

    # Already running?
    if docker exec toolbox curl -sf -o /dev/null \
        -H "Authorization: Bearer ${GHIDRA_MCP_TOKEN}" \
        "http://127.0.0.1:${GHIDRA_MCP_PORT}/health" 2>/dev/null; then
        echo "  headless already running — checking health response"
        local health
        health="$(docker exec toolbox curl -sf \
            -H "Authorization: Bearer ${GHIDRA_MCP_TOKEN}" \
            "http://127.0.0.1:${GHIDRA_MCP_PORT}/health" 2>&1)"
        if echo "$health" | grep -q '"status"'; then
            _pass "$label (already running)"
            return
        fi
    fi

    # Cold-start headless manually (don't use lazy-start.sh — it execs the bridge).
    echo "  cold-starting Ghidra headless…"
    local GHIDRA_HOME GHIDRA_JAR CLASSPATH pid

    GHIDRA_HOME="${GHIDRA_INSTALL_DIR:-/opt/tools/ghidra}"
    GHIDRA_JAR="/opt/tools/ghidra-mcp/docker/GhidraMCPHeadless.jar"

    docker exec toolbox bash -c "
        GHIDRA_HOME='${GHIDRA_HOME}'
        GHIDRA_JAR='${GHIDRA_JAR}'
        CLASSPATH='${GHIDRA_JAR}'
        for jar in \${GHIDRA_HOME}/Ghidra/Framework/*/lib/*.jar; do
            [ -f \"\$jar\" ] && CLASSPATH=\"\${CLASSPATH}:\${jar}\"
        done
        for jar in \${GHIDRA_HOME}/Ghidra/Features/*/lib/*.jar; do
            [ -f \"\$jar\" ] && CLASSPATH=\"\${CLASSPATH}:\${jar}\"
        done
        for jar in \${GHIDRA_HOME}/Ghidra/Processors/*/lib/*.jar; do
            [ -f \"\$jar\" ] && CLASSPATH=\"\${CLASSPATH}:\${jar}\"
        done
        java -Xmx2g -XX:+UseG1GC \
            -Dghidra.home=\"\${GHIDRA_HOME}\" \
            -Dapplication.name=GhidraMCP \
            -classpath \"\${CLASSPATH}\" \
            com.xebyte.headless.GhidraMCPHeadlessServer \
            --bind 0.0.0.0 --port ${GHIDRA_MCP_PORT} \
            &>/tmp/ghidra-smoke.log &
        echo \$!
    " > /tmp/ghidra-smoke-pid 2>&1

    pid="$(cat /tmp/ghidra-smoke-pid 2>/dev/null || echo '')"
    echo "  headless pid: ${pid:-unknown}"

    # Wait for health.
    local ready=0
    for i in $(seq 1 45); do
        if docker exec toolbox curl -sf -o /dev/null \
            -H "Authorization: Bearer ${GHIDRA_MCP_TOKEN}" \
            "http://127.0.0.1:${GHIDRA_MCP_PORT}/health" 2>/dev/null; then
            ready=1
            break
        fi
        if [[ -n "$pid" ]] && ! docker exec toolbox kill -0 "$pid" 2>/dev/null; then
            echo "  headless died during startup" >&2
            break
        fi
        sleep 1
    done

    if [[ "$ready" -eq 1 ]]; then
        local health
        health="$(docker exec toolbox curl -sf \
            -H "Authorization: Bearer ${GHIDRA_MCP_TOKEN}" \
            "http://127.0.0.1:${GHIDRA_MCP_PORT}/health" 2>&1)"
        echo "  health: $health"

        # Kill the smoke-test headless so the real lazy-start can claim the port later.
        if [[ -n "$pid" ]]; then
            docker exec toolbox kill "$pid" 2>/dev/null || true
        fi
        _pass "$label"
    else
        echo "  headless logs:" >&2
        docker exec toolbox cat /tmp/ghidra-smoke.log 2>/dev/null | tail -20 >&2 || true
        if [[ -n "$pid" ]]; then
            docker exec toolbox kill "$pid" 2>/dev/null || true
        fi
        _fail "$label" "headless did not respond to health check within 45s"
    fi
}

_check_ghidra

# -- shell-mcp ---------------------------------------------------------------
# Verify shell-mcp.py loads and constructs its server without error.
# File has a hyphen in the name — use importlib, not `import shell-mcp`.
_check "shell-mcp" \
    "docker exec toolbox python3 -c \"
import importlib.util, sys
spec = importlib.util.spec_from_file_location('shell_mcp', '/opt/tools/scripts/mcp/shell-mcp.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print('shell-mcp', mod.server.name)
\" 2>&1 | grep -q 'shell-mcp'"

# -- angr --------------------------------------------------------------------
# angr import is heavy — verify it loads without error (timeout higher).
# Capture output first, then grep. piping directly to grep -q causes
# SIGPIPE because angr prints warnings that match 'angr' early.
_check "angr" \
    "docker exec toolbox timeout 120 python3 -c 'import angr; print(\"angr\", angr.__version__)' > /tmp/angr-smoke.txt 2>&1; grep -q 'angr' /tmp/angr-smoke.txt"

# -- report ------------------------------------------------------------------
echo
echo "=== Results ==="

PASS_COUNT=0
FAIL_COUNT=0
for r in "${RESULTS[@]}"; do
    case "$r" in
        PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
        FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    esac
done

echo "  Passed: $PASS_COUNT"
echo "  Failed: $FAIL_COUNT"
echo

# -- cleanup -----------------------------------------------------------------
if [[ "$DO_CLEANUP" -eq 1 ]]; then
    echo "--- Cleanup ---"
    docker compose down 2>&1 | tail -3
fi

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "SMOKE TEST FAILED ($FAIL_COUNT check(s) failed)."
    exit 1
fi

echo "SMOKE TEST PASSED."
exit 0
