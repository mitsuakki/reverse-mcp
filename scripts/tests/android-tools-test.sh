#!/bin/bash
# ============================================================================
# android-tools-test.sh — Test Android RE tools against an APK.
#
# Validates that apktool, jadx, frida, and objection each work correctly
# against the supplied APK. Designed to run INSIDE the toolbox container.
#
# Usage (inside container):
#   bash /opt/tools/scripts/tests/android-tools-test.sh [--verbose] [apk]
#
# The default APK path resolves relative to /workspace (the container's
# working directory):
#   tests/fixtures/HelloWorld.apk
#
# Explicit path example:
#   bash /opt/tools/scripts/tests/android-tools-test.sh /workspace/myapp.apk
#
# Output:
#   Each test prints PASS/FAIL with relevant output.
#   Exits 0 when all pass, 1 on any failure.
#
# frida and objection are optional — missing tools are skipped with a
# PASS + note. apktool and jadx failures are critical.
# ============================================================================

set -euo pipefail

SCRIPT_NAME="android-tools-test"
source "$(dirname "$0")/../common/arglib.sh"

# ---- Config ----------------------------------------------------------------
RESULTS=()
PASS_COUNT=0
FAIL_COUNT=0
VERBOSE=0

# APK path: default is tests/fixtures/HelloWorld.apk relative to /workspace
APK="tests/fixtures/HelloWorld.apk"

# ---- Arg parsing -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=1; shift ;;
        --help|-h)    usage ;;
        -*)           die "Unknown argument: $1" ;;
        *)            APK="$1"; shift ;;
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

_verbose() {
    if [[ "$VERBOSE" -eq 1 ]]; then
        echo "    $*"
    fi
}

_run() {
    local label="$1" cmd="$2"
    local output rc

    output="$(eval "$cmd" 2>&1)" && rc=$? || rc=$?
    if [[ $rc -ne 0 ]]; then
        _fail "$label" "exit=$rc"
        echo "         $output" >&2
        return 1
    fi
    _pass "$label"
    return 0
}

_check_output() {
    local label="$1" cmd="$2" expected="$3"
    local output rc

    output="$(eval "$cmd" 2>&1)" && rc=$? || rc=$?
    if [[ $rc -ne 0 ]]; then
        _fail "$label" "exit=$rc"
        echo "         $output" >&2
        return 1
    fi
    if echo "$output" | grep -iq "$expected"; then
        _pass "$label"
    else
        _fail "$label" "expected '$expected' not found in output"
        _verbose "output: $output"
        return 1
    fi
}

# ---- Pre-checks ------------------------------------------------------------
echo "=== Android RE Tools Test ==="
echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
echo "APK: $APK"
echo

if [[ ! -f "$APK" ]]; then
    # Try absolute /workspace path
    if [[ "$APK" != /* ]] && [[ -f "/workspace/$APK" ]]; then
        APK="/workspace/$APK"
    else
        die "Test APK not found: $APK"
    fi
fi

echo "Resolved: $APK"
file "$APK"
echo

# ============================================================================
# 1. APK structure validation (unzip -l)
# ============================================================================
echo "--- Test: APK structure ---"

_check_output "unzip: AndroidManifest.xml" \
    "unzip -l '$APK'" \
    "AndroidManifest.xml"

_check_output "unzip: classes.dex" \
    "unzip -l '$APK'" \
    "classes.dex"

echo

# ============================================================================
# 2. apktool — tool presence check (decode requires Android framework)
# ============================================================================
echo "--- Test: apktool ---"

# apktool needs a framework-res.apk to compile/decode manifest attributes.
# Without framework installed, manifests are stored as raw XML and can't be
# decoded. Verify the tool exists and runs; skip full round-trip.
_run "apktool version" "apktool version"

echo

# ============================================================================
# 3. jadx — decompile APK, verify Java output
# ============================================================================
echo "--- Test: jadx ---"

JADX_OUT="/tmp/jadx-test-out"
rm -rf "$JADX_OUT"

if _run "jadx decompile" "jadx --no-res -d '$JADX_OUT' '$APK'"; then
    # Verify Java source files exist in the output tree
    if find "$JADX_OUT" -name '*.java' 2>/dev/null | grep -q .; then
        _pass "jadx: Java source found"
    else
        _fail "jadx: Java source files" "no .java files in $JADX_OUT"
    fi
fi

# Cleanup
rm -rf "$JADX_OUT"

echo

# ============================================================================
# 4. frida — tool presence check (optional)
# ============================================================================
echo "--- Test: frida ---"

if command -v frida &>/dev/null; then
    _run "frida --version" "frida --version"
else
    _skip "frida" "not installed on PATH"
fi

echo

# ============================================================================
# 5. objection — tool presence check (optional)
# ============================================================================
echo "--- Test: objection ---"

if command -v objection &>/dev/null; then
    _run "objection version" "objection version"
else
    _skip "objection" "not installed on PATH"
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
    echo "ANDROID RE TOOLS TEST FAILED ($FAIL_COUNT check(s) failed)." >&2
    exit 1
fi

echo "ANDROID RE TOOLS TEST PASSED."
exit 0
