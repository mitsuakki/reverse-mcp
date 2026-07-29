#!/usr/bin/env python3
"""
arglib.py — shared argument parsing helpers for toolbox Python scripts.

Usage:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
    from arglib import add_common_args, validate_binary, setup_logging

Provides:
    add_common_args(parser, **kw)  — add --binary, --verbose, --timeout args
    validate_binary(path)          — raise SystemExit if file missing
    setup_logging(name, verbose)   — configure logging to stderr
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path


def add_common_args(
    parser: argparse.ArgumentParser,
    *,
    binary_required: bool = True,
    timeout_default: int = 300,
) -> None:
    """Add standard toolbox arguments to an argparse parser.

    Args:
        parser: The ArgumentParser to augment.
        binary_required: Whether --binary is a required argument (default True).
        timeout_default: Default timeout in seconds (default 300).
    """
    parser.add_argument(
        "--binary",
        required=binary_required,
        help="Path to target binary file",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Verbose output",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=timeout_default,
        help=f"Timeout in seconds (default: {timeout_default})",
    )


def validate_binary(path: str | None) -> Path:
    """Check that --binary points to a real file. Exits on failure.

    Returns the resolved Path on success.
    """
    if not path:
        print("Error: --binary is required", file=sys.stderr)
        sys.exit(1)
    p = Path(path)
    if not p.is_file():
        print(f"Error: binary not found: {path}", file=sys.stderr)
        sys.exit(1)
    return p.resolve()


def setup_logging(name: str, verbose: bool = False) -> logging.Logger:
    """Configure logging to stderr at WARNING (or DEBUG if verbose).

    Returns a logger ready for use.
    """
    level = logging.DEBUG if verbose else logging.WARNING
    logging.basicConfig(
        level=level,
        format=f"%(asctime)s [{name}] %(levelname)s: %(message)s",
        stream=sys.stderr,
    )
    return logging.getLogger(name)
