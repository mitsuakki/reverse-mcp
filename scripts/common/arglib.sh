#!/bin/bash
# ============================================================================
# arglib.sh — shared argument parsing helpers for toolbox shell scripts.
#
# Usage:
#   source "$(dirname "$0")/../common/arglib.sh"
#
# Provides:
#   log()           — timestamped message to stderr
#   die()           — log "ERROR: ..." and exit 1
#   usage()         — override in your script; called by --help/-h
#   require_binary()— validate that --binary <path> exists
#   require_cmd()   — validate that a command is on PATH
# ============================================================================

# Callers should set SCRIPT_NAME for log prefix, or we derive it.
: "${SCRIPT_NAME:=$(basename "$0")}"

log() {
    echo "[${SCRIPT_NAME}] $*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

# Override in your script
usage() {
    echo "Usage: $(basename "$0") --binary <file> [options]"
    echo
    echo "Common options:"
    echo "  --binary PATH    Target binary file"
    echo "  --verbose, -v    Verbose output"
    echo "  --help, -h       Show this help"
    exit 0
}

require_binary() {
    local path="${1:-}"
    if [[ -z "$path" ]]; then
        die "--binary is required"
    fi
    if [[ ! -f "$path" ]]; then
        die "binary not found: $path"
    fi
    return 0
}

require_cmd() {
    local cmd="$1"
    local label="${2:-$cmd}"
    if ! command -v "$cmd" &>/dev/null; then
        die "$label not found on PATH — is the tool installed?"
    fi
    return 0
}

# ---- convention reference (NOT callable from a case statement) ---------------
# Bash functions can't shift the CALLER's positional parameters, so inline
# the flag handling in your script's while/case loop. The pattern is:
#
#   while [[ $# -gt 0 ]]; do
#       case "$1" in
#           --binary)    BINARY="$2"; shift 2 ;;
#           --output)    OUTPUT="$2"; shift 2 ;;
#           --verbose|-v) VERBOSE=1; shift ;;
#           --help|-h)   usage ;;
#           *)           die "Unknown argument: $1" ;;
#       esac
#   done
#
# This function documents the convention but is NOT used at runtime —
# it cannot shift the caller's args due to bash scoping.
