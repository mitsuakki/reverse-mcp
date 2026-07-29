#!/bin/bash
set -euo pipefail

# ============================================================================
# profile.sh — measure container startup time and per-component disk usage.
# Run inside the container:  docker exec toolbox /opt/tools/scripts/profile.sh
# ============================================================================

echo "=== reverse-mcp profile ==="
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

# --- Startup time ------------------------------------------------------------
echo "--- Startup time ---"
echo "Container uptime:"
uptime
echo

# Check how long each MCP child took to connect (from gateway log)
echo "Gateway connection timestamps:"
grep -E "connecting|connected|deferred|ready" /tmp/gateway-http.log 2>/dev/null | tail -20 || echo "  (no gateway log yet)"
echo

# --- Per-component disk usage ------------------------------------------------
echo "--- Disk usage by component ---"

du_comp() {
    local label="$1" path="$2"
    if [ -e "$path" ]; then
        local size
        size=$(du -sh "$path" 2>/dev/null | cut -f1)
        printf "%-30s %8s\n" "$label" "$size"
    else
        printf "%-30s %8s\n" "$label" "(absent)"
    fi
}

echo "Component                       Size"
echo "----------------------------------------"
du_comp "Ghidra headless"           /opt/tools/ghidra
du_comp "radare2 (build+source)"   /opt/tools/radare2
du_comp "radare2 source tree"      /opt/tools/radare2-src
du_comp "ghidra-mcp bridge"        /opt/tools/ghidra-mcp
du_comp "AFL++"                    /opt/tools/fuzzing/bin/afl-fuzz
du_comp "honggfuzz"                /opt/tools/fuzzing/bin/honggfuzz
du_comp "fuzzing (all)"            /opt/tools/fuzzing
du_comp "Android platform-tools"   /opt/tools/platform-tools
du_comp "jadx"                     /opt/tools/jadx
du_comp "apktool"                  /opt/tools/apktool.jar
du_comp "BinDiff"                  /opt/tools/bindiff 2>/dev/null || echo "bindiff"
du_comp "Python site-packages"     /usr/local/lib/python3*/dist-packages
du_comp "r2pm plugins"             /home/ctf/.local/share/radare2/r2pm
du_comp "Ghidra projects volume"   /home/ctf/.config/ghidra
echo

# --- Python package breakdown ------------------------------------------------
echo "--- Top Python packages ---"
pip3 list --format=columns 2>/dev/null | tail -n +3 | awk '{print $1}' | while read -r pkg; do
    pkg_path=$(python3 -c "import ${pkg//-/_}; print(${pkg//-/_}.__file__)" 2>/dev/null || true)
    if [ -n "$pkg_path" ] && [ -e "$pkg_path" ]; then
        du -sh "$(dirname "$pkg_path")" 2>/dev/null
    fi
done 2>/dev/null | sort -rh | head -20 || echo "  (pip unavailable or no packages)"
echo

# --- Image layers (host only) ------------------------------------------------
echo "--- Image size (run on host) ---"
echo "  docker images reverse-mcp --format '{{.Size}}'"
echo "  docker history reverse-mcp --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' | head -20"
echo

# --- Memory usage ------------------------------------------------------------
echo "--- Process memory (RSS) ---"
ps aux --sort=-%mem 2>/dev/null | awk 'NR==1 || /gateway|ghidra|r2mcp|shell-mcp|angr|java|python/ && !/awk/' | head -10
echo

echo "--- Memory summary ---"
free -h
echo

echo "=== done ==="
