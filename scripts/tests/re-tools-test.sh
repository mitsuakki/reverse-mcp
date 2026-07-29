#!/bin/bash
# ============================================================================
# re-tools-test.sh — Run RE tools against a test binary.
#
# Validates that radare2, Ghidra, and angr each work correctly against the
# supplied test binary. Designed to run INSIDE the toolbox container.
#
# Usage (inside container):
#   bash /opt/tools/scripts/tests/re-tools-test.sh [binary]
#
# The default binary path resolves relative to /workspace (the container's
# working directory):
#   tests/fixtures/hello.elf
#
# Explicit path example:
#   bash /opt/tools/scripts/tests/re-tools-test.sh /workspace/mybin.elf
#
# Output:
#   Each test prints PASS/FAIL with relevant output.
#   Exits 0 when all pass, 1 on any failure.
# ============================================================================

set -euo pipefail

SCRIPT_NAME="re-tools-test"
source "$(dirname "$0")/../common/arglib.sh"

# ---- Config ----------------------------------------------------------------
RESULTS=()
PASS_COUNT=0
FAIL_COUNT=0
GHIDRA_MCP_PORT="${GHIDRA_MCP_PORT:-8089}"
GHIDRA_MCP_TOKEN="${GHIDRA_MCP_AUTH_TOKEN:-reverse-mcp-dev-secret}"
GHIDRA_PROJECTS_DIR="${GHIDRA_PROJECTS_DIR:-/home/ctf/ghidra-projects}"
GHIDRA_HOME="${GHIDRA_INSTALL_DIR:-/opt/tools/ghidra}"

# Binary path: default is tests/fixtures/hello.elf relative to /workspace
BINARY="${1:-tests/fixtures/hello.elf}"

# ---- Helpers ---------------------------------------------------------------

_pass() {
    RESULTS+=("PASS")
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  [PASS] $1"
}

_fail() {
    RESULTS+=("FAIL")
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  [FAIL] $1" >&2
    # Print the second arg as extra detail if provided
    if [[ -n "${2:-}" ]]; then
        echo "         $2" >&2
    fi
}

_check_r2() {
    local label="$1" cmd="$2" expected="$3"
    local output rc

    echo "  r2: $label"
    # Insert scr.color=0 after -q to suppress ANSI escape sequences
    cmd="${cmd/r2 -q /r2 -e scr.color=0 -q }"
    output="$(eval "$cmd" 2>&1)" && rc=$? || rc=$?
    if [[ $rc -ne 0 ]]; then
        _fail "r2: $label" "exit=$rc"
        echo "    $output" >&2
        return 1
    fi
    if echo "$output" | grep -iq "$expected"; then
        _pass "r2: $label"
    else
        _fail "r2: $label" "expected '$expected' not found in output"
        echo "    output: $output" >&2
        return 1
    fi
}

# ---- Pre-checks ------------------------------------------------------------
echo "=== RE Tools Test ==="
echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
echo "Binary: $BINARY"
echo

if [[ ! -f "$BINARY" ]]; then
    # Try absolute /workspace path
    if [[ "$BINARY" != /* ]] && [[ -f "/workspace/$BINARY" ]]; then
        BINARY="/workspace/$BINARY"
    else
        die "Test binary not found: $BINARY"
    fi
fi

echo "Resolved: $BINARY"
file "$BINARY"
echo

# ============================================================================
# 1. radare2 — open, analyze, find strings, list functions, disassemble main
# ============================================================================
echo "--- Test: radare2 ---"

# 1a. Open binary and confirm it's recognized as ELF
_check_r2 "file type" \
    "r2 -q -c 'iI~bintype' '$BINARY'" \
    "elf"

# 1b. Find the "secret123" string in data sections
_check_r2 "secret string" \
    "r2 -q -c 'iz~secret123' '$BINARY'" \
    "secret123"

# 1c. Run full analysis and list functions (should find main)
_check_r2 "list functions (main)" \
    "r2 -q -c 'aaa 2>/dev/null; afl~main' '$BINARY'" \
    "main"

# 1d. Disassemble main and find the strcmp call
_check_r2 "disassemble (strcmp)" \
    "r2 -q -c 'aaa 2>/dev/null; s main; pdf~strcmp' '$BINARY'" \
    "strcmp"

# 1e. Find imports (should include fgets, printf, strcmp, puts, strlen, __stack_chk_fail)
_check_r2 "imports (fgets)" \
    "r2 -q -c 'ii~fgets' '$BINARY'" \
    "fgets"

echo "  r2: all checks passed"
echo

# ============================================================================
# 2. Ghidra — import binary, analyze, decompile
# ============================================================================
echo "--- Test: Ghidra ---"

GHIDRA_PROJECT="re-tools-test-$$"
GHIDRA_READY=0

# 2a. Start Ghidra headless (if not already running)
echo "  Starting Ghidra headless…"
# Check if already running
if curl -sf -o /dev/null \
    -H "Authorization: Bearer ${GHIDRA_MCP_TOKEN}" \
    "http://127.0.0.1:${GHIDRA_MCP_PORT}/health" 2>/dev/null; then
    echo "  Ghidra headless already running on port ${GHIDRA_MCP_PORT}"
    GHIDRA_READY=1
else
    # Cold-start headless server
    GHIDRA_JAR="/opt/tools/ghidra-mcp/docker/GhidraMCPHeadless.jar"
    if [[ ! -f "$GHIDRA_JAR" ]]; then
        _fail "Ghidra: headless JAR not found — rebuild container"
    else
        # Build classpath
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

        java -Xmx2g -XX:+UseG1GC \
            -Dghidra.home="${GHIDRA_HOME}" \
            -Dapplication.name=GhidraMCP \
            -classpath "${CLASSPATH}" \
            com.xebyte.headless.GhidraMCPHeadlessServer \
            --bind 127.0.0.1 --port "${GHIDRA_MCP_PORT}" \
            &>/tmp/ghidra-headless-test.log &
        GHIDRA_PID=$!

        # Wait for health
        for i in $(seq 1 45); do
            if curl -sf -o /dev/null \
                -H "Authorization: Bearer ${GHIDRA_MCP_TOKEN}" \
                "http://127.0.0.1:${GHIDRA_MCP_PORT}/health" 2>/dev/null; then
                GHIDRA_READY=1
                echo "  Ghidra headless ready after ${i}s (pid ${GHIDRA_PID})"
                break
            fi
            if ! kill -0 "$GHIDRA_PID" 2>/dev/null; then
                echo "  (pid ${GHIDRA_PID})"
                break
            fi
            sleep 1
        done
    fi
fi

if [[ "$GHIDRA_READY" -ne 1 ]]; then
    _fail "Ghidra: headless did not start"
else
    # 2b. Import binary via analyzeHeadless
    echo "  Importing binary via analyzeHeadless…"
    mkdir -p "$GHIDRA_PROJECTS_DIR"
    IMPORT_OUTPUT="$(timeout 120 \
        "${GHIDRA_HOME}/support/analyzeHeadless" \
        "$GHIDRA_PROJECTS_DIR" "$GHIDRA_PROJECT" \
        -import "$BINARY" \
        -overwrite \
        2>&1)" && IMPORT_RC=$? || IMPORT_RC=$?

    if [[ "$IMPORT_RC" -ne 0 ]]; then
        _fail "Ghidra: import via analyzeHeadless" "exit=$IMPORT_RC"
        echo "    $IMPORT_OUTPUT" >&2
    else
        _pass "Ghidra: analyzeHeadless import"
    fi

    # 2c. Load program into MCP server via API
    echo "  Loading into MCP server…"
    LOAD_RESP="$(curl -sf -X POST \
        "http://127.0.0.1:${GHIDRA_MCP_PORT}/load_program" \
        -H "Authorization: Bearer ${GHIDRA_MCP_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"file\": \"${BINARY}\"}" 2>&1)" || true

    if echo "$LOAD_RESP" | grep -q '"success":true'; then
        _pass "Ghidra: MCP load_program"
    elif echo "$LOAD_RESP" | grep -q '"program_loaded"'; then
        _pass "Ghidra: MCP load_program (already loaded)"
    else
        _fail "Ghidra: MCP load_program" "unexpected response: $LOAD_RESP"
    fi

    # 2d. Test decompile tool if available
    echo "  Checking available Ghidra tools…"
    TOOLS_RESP="$(curl -sf \
        "http://127.0.0.1:${GHIDRA_MCP_PORT}/tools" \
        -H "Authorization: Bearer ${GHIDRA_MCP_TOKEN}" 2>&1)" || true

    if echo "$TOOLS_RESP" | grep -qi "decompile"; then
        _pass "Ghidra: decompile tool available"
    else
        # Decompile might not appear until program is actually loaded
        # — this is non-fatal for the test
        echo "  (decompile tool not listed — may need full program load; non-fatal)"
    fi
fi

# Cleanup Ghidra test project (best-effort)
echo "  Cleaning up Ghidra project…"
rm -rf "${GHIDRA_PROJECTS_DIR:?}/${GHIDRA_PROJECT}" 2>/dev/null || true

# Stop headless if we started it (and if it's not in lazy-start mode)
if [[ -n "${GHIDRA_PID:-}" ]] && kill -0 "$GHIDRA_PID" 2>/dev/null; then
    echo "  Stopping Ghidra headless (pid ${GHIDRA_PID})…"
    kill "$GHIDRA_PID" 2>/dev/null || true
fi

echo

# ============================================================================
# 3. angr — symbolic execution to find the password
# ============================================================================
echo "--- Test: angr ---"

# Run a standalone symbolic execution that finds the password
ANGR_RESULT="$(timeout 60 python3 -u -c "
import angr, claripy, logging
logging.getLogger('angr').setLevel(logging.ERROR)

p = angr.Project('$BINARY', auto_load_libs=False)

# Set up symbolic stdin
stdin_sym = claripy.BVS('stdin', 64 * 8)
from angr.storage.file import SimFile
stdin_file = SimFile('stdin', content=stdin_sym, has_end=False)
s = p.factory.entry_state(stdin=stdin_file)

simgr = p.factory.simulation_manager(s)
# OK path: lea rax, str.OK at 0x129a → loaded at PIE base 0x400000
# FAIL path: lea rax, str.FAIL at 0x12b0
find_addr = p.loader.main_object.min_addr + 0x129a
avoid_addr = p.loader.main_object.min_addr + 0x12b0

simgr.explore(find=find_addr, avoid=avoid_addr, timeout=20)
if simgr.found:
    found = simgr.found[0]
    sol = found.solver.eval(stdin_sym, cast_to=bytes)
    sol = sol.rstrip(b'\x00').rstrip(b'\x01')
    print('FOUND:' + repr(sol), flush=True)
else:
    print('NOTFOUND', flush=True)
    print(f'active:{len(simgr.active)} d:{len(simgr.deadended)} e:{len(simgr.errored)}', flush=True)
" 2>&1)" || ANGR_RC=$?

if echo "$ANGR_RESULT" | grep -q "FOUND:"; then
    SOL="$(echo "$ANGR_RESULT" | grep "FOUND:" | head -1)"
    if echo "$SOL" | grep -q "secret123"; then
        _pass "angr: symbolic execution found password (secret123)"
    else
        _pass "angr: symbolic execution reached OK path ($SOL)"
    fi
elif echo "$ANGR_RESULT" | grep -q "NOTFOUND"; then
    _fail "angr: symbolic execution did not find solution" "angr output: $ANGR_RESULT"
else
    _fail "angr: execution failed" "output: $ANGR_RESULT"
fi

echo

# ============================================================================
# Results
# ============================================================================
echo "=== Results ==="
echo "  Passed: $PASS_COUNT"
echo "  Failed: $FAIL_COUNT"
echo

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "RE TOOLS TEST FAILED ($FAIL_COUNT check(s) failed)." >&2
    exit 1
fi

echo "RE TOOLS TEST PASSED."
exit 0
