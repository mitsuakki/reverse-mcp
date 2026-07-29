#!/bin/bash
set -euo pipefail

# ============================================================================
# init.sh — initialize a fuzzing campaign for a target binary.
#
# Sets up corpus/output directories, generates a minimal seed input, and
# writes a ready-to-run fuzzer command.
#
# Usage:
#   ./scripts/tools/fuzz/init.sh --binary /workspace/target.elf --engine afl
#   ./scripts/tools/fuzz/init.sh --binary /workspace/target.elf --engine honggfuzz --jobs 4
#
# Supported engines: afl (AFL++), honggfuzz.
# Env vars:
#   FUZZING_DIR           Path to fuzzing tool install (default /opt/tools/fuzzing)
# ============================================================================

SCRIPT_NAME="fuzz-init"
source "$(dirname "$0")/../../common/arglib.sh"

FUZZING_DIR="${FUZZING_DIR:-/opt/tools/fuzzing}"
AFL_FUZZ="${AFL_FUZZ:-${FUZZING_DIR}/bin/afl-fuzz}"
HONGGFUZZ="${HONGGFUZZ:-${FUZZING_DIR}/bin/honggfuzz}"

# --- usage ------------------------------------------------------------------
usage() {
    echo "Usage: $(basename "$0") --binary <file> --engine <afl|honggfuzz> [options]"
    echo
    echo "Options:"
    echo "  --binary PATH       Target binary to fuzz (required)"
    echo "  --engine ENGINE     Fuzzing engine: afl or honggfuzz (required)"
    echo "  --corpus DIR        Seed corpus directory (default: ./corpus)"
    echo "  --output DIR        Output directory (default: ./fuzz-out)"
    echo "  --timeout SECONDS   Max fuzz time in seconds (default: 3600)"
    echo "  --jobs N            Parallel fuzzer jobs (default: 1)"
    echo "  --args ARGS         Arguments passed to target binary (@@ = input file)"
    echo "  --verbose, -v       Verbose output"
    echo "  --help, -h          Show this help"
    echo
    echo "Examples:"
    echo "  $0 --binary /workspace/crashme.elf --engine afl"
    echo "  $0 --binary /workspace/crashme.elf --engine honggfuzz --jobs 4 --timeout 7200"
    echo "  $0 --binary /workspace/crashme.elf --engine afl --corpus seeds/ --args '@@'"
    exit 0
}

BINARY=""
ENGINE=""
CORPUS="./corpus"
OUTPUT="./fuzz-out"
TIMEOUT=3600
JOBS=1
TARGET_ARGS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary)   BINARY="$2"; shift 2 ;;
        --engine)   ENGINE="$2"; shift 2 ;;
        --corpus)   CORPUS="$2"; shift 2 ;;
        --output)   OUTPUT="$2"; shift 2 ;;
        --timeout)  TIMEOUT="$2"; shift 2 ;;
        --jobs)     JOBS="$2"; shift 2 ;;
        --args)     TARGET_ARGS="$2"; shift 2 ;;
        --help|-h)  usage ;;
        --verbose|-v) VERBOSE=1; shift ;;
        *)          die "Unknown argument: $1" ;;
    esac
done

require_binary "${BINARY}"
[[ -n "${ENGINE}" ]] || die "--engine is required (afl or honggfuzz)"

case "${ENGINE}" in
    afl)
        require_cmd "${AFL_FUZZ}" "AFL++ (afl-fuzz)"
        ;;
    honggfuzz)
        require_cmd "${HONGGFUZZ}" "honggfuzz"
        ;;
    *)
        die "Unknown engine: ${ENGINE}. Supported: afl, honggfuzz"
        ;;
esac

BINARY_NAME="$(basename "${BINARY}")"
CAMPAIGN_NAME="${BINARY_NAME}-${ENGINE}"

log "Binary:       ${BINARY}"
log "Engine:       ${ENGINE}"
log "Corpus dir:   ${CORPUS}"
log "Output dir:   ${OUTPUT}"
log "Timeout:      ${TIMEOUT}s"
log "Jobs:         ${JOBS}"
log "Target args:  ${TARGET_ARGS:-(none)}"

mkdir -p "${CORPUS}" "${OUTPUT}"

# Generate a minimal seed if corpus is empty.
if [[ -z "$(ls -A "${CORPUS}" 2>/dev/null)" ]]; then
    SEED_FILE="${CORPUS}/seed.bin"
    log "Corpus empty — generating minimal seed: ${SEED_FILE}"

    # Try to detect input format for smarter seed.
    FTYPE="$(file -b "${BINARY}" 2>/dev/null || true)"

    if echo "${FTYPE}" | grep -qi "elf"; then
        # ELF binary — produce a minimal valid-ish ELF header + newline.
        # Most fuzzing targets that read files handle newlines gracefully.
        printf "\n" > "${SEED_FILE}"
        log "  ELF binary detected — seed is single newline (fuzzer will mutate)."
    elif echo "${FTYPE}" | grep -qi "pe32\|pe64"; then
        printf "\n" > "${SEED_FILE}"
        log "  PE binary detected — seed is single newline."
    else
        # Generic: a few bytes of varied content.
        printf "AAAA\n" > "${SEED_FILE}"
        log "  Generic seed."
    fi
else
    SEED_COUNT="$(find "${CORPUS}" -type f | wc -l)"
    log "Corpus has ${SEED_COUNT} seed file(s)."
fi

RUN_SCRIPT="${OUTPUT}/run-${CAMPAIGN_NAME}.sh"
log "Writing run script: ${RUN_SCRIPT}"

cat > "${RUN_SCRIPT}" << 'RUNEOF'
#!/bin/bash
set -euo pipefail
RUNEOF

# The heredoc delimiter approach above won't substitute vars. Use explicit
# cat with variable interpolation for the dynamic parts.
cat >> "${RUN_SCRIPT}" << EOF

# Fuzzing campaign: ${CAMPAIGN_NAME}
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Target:  ${BINARY}
# Engine:  ${ENGINE}
# Timeout: ${TIMEOUT}s
# Jobs:    ${JOBS}

BINARY="${BINARY}"
CORPUS="${CORPUS}"
OUTPUT="${OUTPUT}"
TIMEOUT=${TIMEOUT}
JOBS=${JOBS}
TARGET_ARGS="${TARGET_ARGS}"
EOF

case "${ENGINE}" in
    afl)
        cat >> "${RUN_SCRIPT}" << 'EOF'

echo "=== AFL++ fuzzing: ${BINARY} ==="
echo "Corpus: ${CORPUS}   Output: ${OUTPUT}   Timeout: ${TIMEOUT}s"

# AFL++ runs until timeout or crash.
# Use @@ to substitute the input file path.
AFL_ARGS=(
    -i "${CORPUS}"
    -o "${OUTPUT}"
    -V "${TIMEOUT}"      # max runtime in seconds
)

# If target args contain @@, use it; otherwise target reads from stdin.
if echo "${TARGET_ARGS}" | grep -q "@@"; then
    ${AFL_FUZZ} "${AFL_ARGS[@]}" -- "${BINARY}" ${TARGET_ARGS}
else
    ${AFL_FUZZ} "${AFL_ARGS[@]}" -- "${BINARY}" ${TARGET_ARGS} < /dev/null
fi
EOF
        ;;
    honggfuzz)
        cat >> "${RUN_SCRIPT}" << 'EOF'

echo "=== honggfuzz fuzzing: ${BINARY} ==="
echo "Corpus: ${CORPUS}   Output: ${OUTPUT}   Timeout: ${TIMEOUT}s"

HONGGFUZZ_ARGS=(
    -i "${CORPUS}"
    --output "${OUTPUT}"
    --timeout "${TIMEOUT}"
    --threads "${JOBS}"
)

if [ -n "${TARGET_ARGS}" ]; then
    ${HONGGFUZZ} "${HONGGFUZZ_ARGS[@]}" -- "${BINARY}" ${TARGET_ARGS}
else
    ${HONGGFUZZ} "${HONGGFUZZ_ARGS[@]}" -- "${BINARY}"
fi
EOF
        ;;
esac

chmod +x "${RUN_SCRIPT}"

echo
log "Campaign ready."
log "  Corpus:      ${CORPUS}"
log "  Output:      ${OUTPUT}"
log "  Run script:  ${RUN_SCRIPT}"
echo
echo "  To start fuzzing:"
echo "    $ ${RUN_SCRIPT}"
echo
echo "  Or manually:"
case "${ENGINE}" in
    afl)
        echo "    ${AFL_FUZZ} -i ${CORPUS} -o ${OUTPUT} -V ${TIMEOUT} -- ${BINARY} ${TARGET_ARGS}"
        ;;
    honggfuzz)
        echo "    ${HONGGFUZZ} -i ${CORPUS} --output ${OUTPUT} --timeout ${TIMEOUT} -- ${BINARY} ${TARGET_ARGS}"
        ;;
esac
echo
log "Note: press Ctrl+C to stop fuzzing. Crashes land in ${OUTPUT}/crashes/."
