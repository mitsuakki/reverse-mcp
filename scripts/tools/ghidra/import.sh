#!/usr/bin/env bash
#
# import.sh — Import a binary into Ghidra headless + load into MCP server.
#
# Usage:
#   ./scripts/tools/ghidra/import.sh /workspace/ch2.bin                    # auto project name
#   ./scripts/tools/ghidra/import.sh /workspace/ch2.bin my-project         # named project
#   ./scripts/tools/ghidra/import.sh /workspace/ch2.bin my-project --no-analyze
#
# Env vars:
#   GHIDRA_MCP_URL        MCP server URL (default http://127.0.0.1:8089)
#   GHIDRA_MCP_AUTH_TOKEN Bearer token (default re-toolbox-dev-secret)

set -euo pipefail

SCRIPT_NAME="ghidra-import"
source "$(dirname "$0")/../../common/arglib.sh"

GHIDRA_HOME="${GHIDRA_INSTALL_DIR:-/opt/tools/ghidra}"
ANALYZE_HEADLESS="${GHIDRA_HOME}/support/analyzeHeadless"
PROJECTS_DIR="${GHIDRA_PROJECTS_DIR:-/home/ctf/ghidra-projects}"
MCP_URL="${GHIDRA_MCP_URL:-http://127.0.0.1:8089}"
AUTH_TOKEN="${GHIDRA_MCP_AUTH_TOKEN:-re-toolbox-dev-secret}"

BINARY=""
PROJECT=""
ANALYZE="--analyze"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-analyze) ANALYZE=""; shift ;;
    --help|-h)
      echo "Usage: $0 <binary> [project-name] [--no-analyze]"
      echo "  binary       Path to binary to import"
      echo "  project-name Ghidra project name (default: basename of binary dir)"
      echo "  --no-analyze Skip auto-analysis (faster import)"
      exit 0
      ;;
    *)
      if [[ -z "$BINARY" ]]; then
        BINARY="$1"
      elif [[ -z "$PROJECT" ]]; then
        PROJECT="$1"
      else
        die "Too many arguments: $1"
      fi
      shift
      ;;
  esac
done

[[ -n "$BINARY" ]] || die "No binary specified. Usage: $0 <binary> [project-name]"
[[ -f "$BINARY" ]]   || die "Binary not found: $BINARY"

BINARY_NAME="$(basename "$BINARY")"
PROJECT="${PROJECT:-$(basename "$(dirname "$BINARY")" | tr ' ' '_')}"

log "Binary:        $BINARY"
log "Project:       $PROJECT"
log "Projects dir:  $PROJECTS_DIR"
log "MCP server:    $MCP_URL"
log "Analyze:       ${ANALYZE:--no-analyze}"

log "Checking MCP server..."
HEALTH="$(curl -sf "${MCP_URL}/health" 2>&1 || true)"
if echo "$HEALTH" | grep -q '"status".*"healthy"'; then
  log "  MCP server healthy: $HEALTH"
else
  die "MCP server not healthy at ${MCP_URL}: ${HEALTH:-no response}"
fi

log "Importing $BINARY_NAME into project '$PROJECT'..."
if [[ ! -d "$PROJECTS_DIR/$PROJECT" ]]; then
  log "  Creating new project: $PROJECTS_DIR/$PROJECT"
else
  log "  Project exists, overwriting $BINARY_NAME"
fi

"$ANALYZE_HEADLESS" "$PROJECTS_DIR" "$PROJECT" \
  -import "$BINARY" \
  -overwrite \
  $ANALYZE \
  2>&1 | while IFS= read -r line; do
    case "$line" in
      *ERROR*) log "  $line" ;;
      *REPORT*) log "  $line" ;;
    esac
  done

EXIT_CODE="${PIPESTATUS[0]}"
if [[ "$EXIT_CODE" -ne 0 ]]; then
  die "analyzeHeadless failed with exit code $EXIT_CODE"
fi
log "  Import done."

log "Loading $BINARY_NAME into MCP server..."
RESP="$(curl -sf -X POST "${MCP_URL}/load_program" \
  -H "Authorization: Bearer ${AUTH_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"file\": \"${BINARY}\"}" 2>&1)"

if echo "$RESP" | grep -q '"success":true'; then
  log "  Load success: $RESP"
else
  log "  Load response: $RESP"
  # Non-fatal — analyzeHeadless already created the project on disk.
  # load_program just makes it available to the MCP bridge.
fi

log "Verifying..."
HEALTH="$(curl -sf "${MCP_URL}/health" 2>&1)"
if echo "$HEALTH" | grep -q '"program_loaded":true'; then
  log "  ✓ Program loaded: $(echo "$HEALTH" | grep -o '"program_name":"[^"]*"')"
else
  log "  ⚠ Program may not be loaded in MCP server: $HEALTH"
  log "  Project on disk is ready. Restart MCP server or call:"
  log "    curl -X POST ${MCP_URL}/load_program -H 'Authorization: Bearer TOKEN' -d '{\"file\":\"${BINARY}\"}'"
fi

log "Done. Ghidra project: $PROJECTS_DIR/$PROJECT"
