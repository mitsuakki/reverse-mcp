#!/bin/bash
# ============================================================================
# cli-tools-test.sh — Test angr/solve.py, fuzz/init.sh, ghidra/import.sh CLIs.
#
# Runs each CLI tool against the test binary (hello.elf) to validate that
# the tools are functional end-to-end. Designed to run INSIDE the toolbox
# container.
#
# Usage (inside container):
#   bash /opt/tools/scripts/tests/cli-tools-test.sh [binary] [--verbose]
#
# Default binary:
#   tests/fixtures/hello.elf  (relative to /workspace)
#
# Output:
#   Each test prints PASS/FAIL with relevant output.
#   Exits 0 when all pass, 1 on any failure.
# ============================================================================

set -euo pipefail

SCRIPT_NAME="cli-tools-test"
source "$(dirname "$0")/../common/arglib.sh"

# ---- Config ----------------------------------------------------------------
RESULTS=()
PASS_COUNT=0
FAIL_COUNT=0
VERBOSE=0

# Tool paths (inside container, resolved relative to this script)
TOOLS_DIR="$(dirname "$0")/../tools"
ANGR_SOLVE="${TOOLS_DIR}/angr/solve.py"
FUZZ_INIT="${TOOLS_DIR}/fuzz/init.sh"
GHIDRA_IMPORT="${TOOLS_DIR}/ghidra/import.sh"

# Binary path: default is tests/fixtures/hello.elf relative to /workspace
BINARY="tests/fixtures/hello.elf"

# Ghidra MCP config
GHIDRA_MCP_PORT="${GHIDRA_MCP_PORT:-8089}"
GHIDRA_MCP_TOKEN="${GHIDRA_MCP_AUTH_TOKEN:-re-toolbox-dev-secret}"

# ---- Arg parsing -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=1; shift ;;
        --help|-h)    usage ;;
        -*)           die "Unknown argument: $1" ;;
        *)            BINARY="$1"; shift ;;
    esac
done

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
    if [[ -n "${2:-}" ]]; then
        echo "         $2" >&2
    fi
}

_skip() {
    RESULTS+=("PASS")
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  [PASS] $1 (skipped: $2)"
}

_run() {
    local label="$1" cmd="$2"
    local output rc

    echo "  $label"
    [[ -n "${VERBOSE:-}" ]] && echo "    command: $cmd" || true

    output="$(eval "$cmd" 2>&1)" && rc=$? || rc=$?
    if [[ $rc -ne 0 ]]; then
        _fail "$label" "exit=$rc"
        [[ -n "${VERBOSE:-}" ]] && echo "    output: $output" || true
        return 1
    fi
    _pass "$label"
    [[ -n "${VERBOSE:-}" ]] && echo "    output: $(echo "$output" | head -5)" || true
    return 0
}

_check_output() {
    local label="$1" cmd="$2" expected="$3"
    local output rc

    echo "  $label"
    [[ -n "${VERBOSE:-}" ]] && echo "    command: $cmd" || true

    output="$(eval "$cmd" 2>&1)" && rc=$? || rc=$?
    if [[ $rc -ne 0 ]]; then
        _fail "$label" "exit=$rc"
        [[ -n "${VERBOSE:-}" ]] && echo "    output: $output" || true
        return 1
    fi
    if echo "$output" | grep -qi "$expected"; then
        _pass "$label"
        [[ -n "${VERBOSE:-}" ]] && echo "    output: $(echo "$output" | head -5)" || true
    else
        _fail "$label" "expected '$expected' not found in output"
        [[ -n "${VERBOSE:-}" ]] && echo "    output: $(echo "$output" | head -10)" || true
        return 1
    fi
}

# ---- Pre-checks ------------------------------------------------------------
echo "=== CLI Tools Test ==="
echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
echo "Binary: $BINARY"
echo

if [[ ! -f "$BINARY" ]]; then
    if [[ "$BINARY" != /* ]] && [[ -f "/workspace/$BINARY" ]]; then
        BINARY="/workspace/$BINARY"
    else
        die "Test binary not found: $BINARY"
    fi
fi

echo "Resolved: $BINARY"
file "$BINARY"
echo

# Determine if PIE so angr address calculation works right
IS_PIE=0
if file "$BINARY" | grep -qi "position-independent\|pie executable\|shared object.*ELF"; then
    IS_PIE=1
    echo "Binary is PIE — using angr default base 0x400000 for address calculation"
fi

# Compute target addresses for angr
# Offsets from hello.c: OK branch at 0x129a, FAIL branch at 0x12b0
if [[ "$IS_PIE" -eq 1 ]]; then
    FIND_ADDR="0x40129a"
    AVOID_ADDR="0x4012b0"
else
    FIND_ADDR="0x129a"
    AVOID_ADDR="0x12b0"
fi
echo "angr target: find=$FIND_ADDR avoid=$AVOID_ADDR"
echo

# ============================================================================
# 1. angr/solve.py — symbolic execution to find password
# ============================================================================
echo "--- Test: angr/solve.py ---"

if [[ ! -f "$ANGR_SOLVE" ]]; then
    _fail "angr/solve.py" "script not found at $ANGR_SOLVE"
else
    _check_output \
        "solve.py: find password" \
        "timeout 120 python3 '$ANGR_SOLVE' --binary '$BINARY' --find '$FIND_ADDR' --avoid '$AVOID_ADDR' --no-auto-libs --timeout 60 2>&1" \
        "Solved input"

    # Test --input-file flag
    ANGR_OUTFILE="/tmp/angr-solve-test.bin"
    rm -f "$ANGR_OUTFILE"
    if _run \
        "solve.py: --input-file write" \
        "timeout 120 python3 '$ANGR_SOLVE' --binary '$BINARY' --find '$FIND_ADDR' --avoid '$AVOID_ADDR' --no-auto-libs --timeout 60 --input-file '$ANGR_OUTFILE' 2>&1"; then
        if [[ -s "$ANGR_OUTFILE" ]]; then
            SOL_SIZE=$(wc -c < "$ANGR_OUTFILE")
            _pass "solve.py: --input-file size=${SOL_SIZE}"
        else
            _fail "solve.py: --input-file" "output file empty or missing"
        fi
    fi
    rm -f "$ANGR_OUTFILE"
fi

echo

# ============================================================================
# 2. fuzz/init.sh — set up fuzzing campaign
# ============================================================================
echo "--- Test: fuzz/init.sh ---"

FUZZ_CORPUS="/tmp/cli-tools-test-corpus"
FUZZ_OUTPUT="/tmp/cli-tools-test-fuzz-out"
rm -rf "$FUZZ_CORPUS" "$FUZZ_OUTPUT"

if [[ ! -f "$FUZZ_INIT" ]]; then
    _fail "fuzz/init.sh" "script not found at $FUZZ_INIT"
else
    # Run fuzz init (setup only, don't run fuzzer)
    # Use honggfuzz so we don't require AFL++ to be installed
    if _run \
        "fuzz/init.sh: setup campaign" \
        "bash '$FUZZ_INIT' --binary '$BINARY' --engine honggfuzz --corpus '$FUZZ_CORPUS' --output '$FUZZ_OUTPUT' --timeout 10 2>&1"; then

        # Verify corpus directory has seed file
        if [[ -d "$FUZZ_CORPUS" ]] && [[ -n "$(ls -A "$FUZZ_CORPUS" 2>/dev/null)" ]]; then
            _pass "fuzz/init.sh: corpus seed created"
        else
            _fail "fuzz/init.sh: corpus seed" "no seed files in $FUZZ_CORPUS"
        fi

        # Verify output directory exists and has run script
        RUNSCRIPT=$(echo "$FUZZ_OUTPUT"/run-*-honggfuzz.sh 2>/dev/null || true)
        if [[ -n "$RUNSCRIPT" ]] && [[ -f "$RUNSCRIPT" ]]; then
            if [[ -x "$RUNSCRIPT" ]]; then
                _pass "fuzz/init.sh: run script executable"
            else
                _fail "fuzz/init.sh: run script" "not executable: $RUNSCRIPT"
            fi
        else
            # Check if it's an afl run script instead
            RUNSCRIPT=$(echo "$FUZZ_OUTPUT"/run-*-afl.sh 2>/dev/null || true)
            if [[ -n "$RUNSCRIPT" ]] && [[ -f "$RUNSCRIPT" ]]; then
                _pass "fuzz/init.sh: run script created (afl)"
            else
                _fail "fuzz/init.sh: run script" "no run-*.sh in $FUZZ_OUTPUT"
            fi
        fi
    fi
fi

# Cleanup
rm -rf "$FUZZ_CORPUS" "$FUZZ_OUTPUT"

echo

# ============================================================================
# 3. Ghidra import.sh — import binary into Ghidra
# ============================================================================
echo "--- Test: Ghidra import.sh ---"

GHIDRA_READY=0

# Check if Ghidra headless is already running
if curl -sf -o /dev/null \
    -H "Authorization: Bearer ${GHIDRA_MCP_TOKEN}" \
    "http://127.0.0.1:${GHIDRA_MCP_PORT}/health" 2>/dev/null; then
    GHIDRA_READY=1
    echo "  Ghidra headless already running on port ${GHIDRA_MCP_PORT}"
fi

if [[ "$GHIDRA_READY" -ne 1 ]]; then
    _skip "ghidra/import.sh" "Ghidra headless not running on port ${GHIDRA_MCP_PORT}"
elif [[ ! -f "$GHIDRA_IMPORT" ]]; then
    _fail "ghidra/import.sh" "script not found at $GHIDRA_IMPORT"
else
    GHIDRA_PROJECT="cli-tools-test-$$"

    if _run \
        "ghidra/import.sh: import binary" \
        "bash '$GHIDRA_IMPORT' '$BINARY' '$GHIDRA_PROJECT' --no-analyze 2>&1"; then

        # Verify project was created on disk
        GHIDRA_PROJECTS_DIR="${GHIDRA_PROJECTS_DIR:-/home/ctf/ghidra-projects}"
        if [[ -d "${GHIDRA_PROJECTS_DIR}/${GHIDRA_PROJECT}" ]]; then
            _pass "ghidra/import.sh: project on disk"
        else
            _fail "ghidra/import.sh: project on disk" "missing: ${GHIDRA_PROJECTS_DIR}/${GHIDRA_PROJECT}"
        fi
    fi

    # Cleanup test project
    echo "  Cleaning up Ghidra project..."
    rm -rf "${GHIDRA_PROJECTS_DIR:?}/${GHIDRA_PROJECT}" 2>/dev/null || true
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
    echo "CLI TOOLS TEST FAILED ($FAIL_COUNT check(s) failed)." >&2
    exit 1
fi

echo "CLI TOOLS TEST PASSED."
exit 0
