#!/usr/bin/env python3
"""
angr-solve.py — Symbolic execution helper for finding inputs that reach a target.

Uses angr to explore a binary symbolically, find a path to the target address,
and output the concrete stdin/payload that triggers that path.

Usage:
  python3 /opt/tools/scripts/tools/angr/solve.py --binary /workspace/target.elf --find 0x401234
  python3 /opt/tools/scripts/tools/angr/solve.py --binary /workspace/target.elf --find 0x401234 --avoid 0x400000 --input-file payload.bin
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

# Allow importing from scripts/common/ even when run from outside the scripts dir.
_self_dir = Path(__file__).resolve().parent
_common_dir = _self_dir.parent.parent / "common"
if str(_common_dir) not in sys.path:
    sys.path.insert(0, str(_common_dir))

from arglib import add_common_args, setup_logging, validate_binary  # noqa: E402


def parse_hex(s: str) -> int:
    """Parse a hex string (with or without 0x prefix) to int."""
    return int(s, 16)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="angr symbolic execution — find inputs that reach a target address",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --binary /workspace/crackme.elf --find 0x401234
  %(prog)s --binary /workspace/crackme.elf --find 0x401234 --avoid 0x400000 --avoid 0x401000
  %(prog)s --binary /workspace/crackme.elf --find 0x401234 --input-file solution.bin -v
        """.strip(),
    )
    add_common_args(parser, binary_required=True, timeout_default=300)
    parser.add_argument(
        "--find",
        type=parse_hex,
        required=True,
        help="Target address to reach (hex, e.g. 0x401234)",
    )
    parser.add_argument(
        "--avoid",
        type=parse_hex,
        action="append",
        default=[],
        help="Address to avoid — repeatable (hex, e.g. 0x400000)",
    )
    parser.add_argument(
        "--input-file",
        type=Path,
        default=None,
        help="Write solved input to this file (default: stdout hexdump)",
    )
    parser.add_argument(
        "--no-auto-libs",
        action="store_true",
        help="Disable auto-loading of dependent libraries (faster, use for static binaries)",
    )
    args = parser.parse_args()

    binary_path = validate_binary(args.binary)
    log = setup_logging("angr-solve", args.verbose)

    log.info("Loading %s into angr…", binary_path)
    t0 = time.monotonic()

    # Heavy imports deferred until after arg validation.
    import angr  # noqa: E402
    import claripy  # noqa: E402

    try:
        project = angr.Project(
            str(binary_path),
            auto_load_libs=not args.no_auto_libs,
        )
    except Exception as exc:
        print(f"Error: failed to load binary: {exc}", file=sys.stderr)
        sys.exit(1)

    log.info("Project loaded in %.1fs. Arch: %s", time.monotonic() - t0, project.arch.name)

    # -- Set up initial state with symbolic stdin -------------------------------
    state = project.factory.entry_state()

    # Make stdin symbolic (up to 256 bytes; angr will narrow as needed).
    stdin_size = 256
    symbolic_stdin = claripy.BVS("stdin", stdin_size * 8)
    state.posix.files[0].content.from_bytes(symbolic_stdin)
    state.posix.files[0].size = stdin_size

    # -- Build simulation manager ----------------------------------------------
    simgr = project.factory.simulation_manager(state)

    log.info(
        "Exploring: find=%s, avoid=%s, timeout=%ds",
        hex(args.find) if args.find else "none",
        [hex(a) for a in args.avoid] if args.avoid else "none",
        args.timeout,
    )

    t_explore = time.monotonic()

    try:
        simgr.explore(
            find=args.find,
            avoid=tuple(args.avoid) if args.avoid else None,
            timeout=args.timeout,
        )
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        sys.exit(130)
    except Exception as exc:
        print(f"Error during exploration: {exc}", file=sys.stderr)
        sys.exit(1)

    elapsed = time.monotonic() - t_explore

    # -- Report results --------------------------------------------------------
    if not simgr.found:
        print(f"No path found to {hex(args.find)} after {elapsed:.1f}s.", file=sys.stderr)
        if simgr.active:
            print(f"  {len(simgr.active)} active states still exploring.", file=sys.stderr)
        if simgr.deadended:
            print(f"  {len(simgr.deadended)} paths dead-ended.", file=sys.stderr)
        if simgr.errored:
            print(f"  {len(simgr.errored)} paths errored.", file=sys.stderr)
            for err_state in simgr.errored[:3]:
                print(f"    {err_state.error}", file=sys.stderr)
        print(
            "Hints: try reducing avoid list, increasing timeout, or using --no-auto-libs",
            file=sys.stderr,
        )
        sys.exit(1)

    found_state = simgr.found[0]
    log.info("Found path in %.1fs!", elapsed)

    # Solve for concrete stdin.
    try:
        solution = found_state.solver.eval(symbolic_stdin, cast_to=bytes)
    except Exception as exc:
        print(f"Error: solver failed to produce concrete input: {exc}", file=sys.stderr)
        sys.exit(1)

    # Trim trailing null bytes for readability.
    solution = solution.rstrip(b"\x00")

    if args.input_file:
        args.input_file.write_bytes(solution)
        print(f"Wrote {len(solution)} bytes to {args.input_file}", file=sys.stderr)
    else:
        # Print hexdump-style output.
        print(f"# Solved input ({len(solution)} bytes):")
        for i in range(0, len(solution), 16):
            chunk = solution[i:i + 16]
            hex_part = " ".join(f"{b:02x}" for b in chunk)
            ascii_part = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
            print(f"  {i:04x}  {hex_part:<48s}  |{ascii_part}|")
        print(f"  ({len(solution)} bytes total)")

    log.info("Done in %.1fs total.", time.monotonic() - t0)


if __name__ == "__main__":
    main()
