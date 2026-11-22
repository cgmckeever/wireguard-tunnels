#!/bin/bash
# wgwarp-sweep.sh — see wgtun/sweep.py (or wgwarp-sweep.sh -h). Stdlib Python 3.9+, macOS's own.
src="$0"
while [ -L "$src" ]; do l=$(readlink "$src"); case "$l" in /*) src="$l" ;; *) src="$(dirname "$src")/$l" ;; esac; done
repo="$(cd "$(dirname "$src")/.." && pwd)"
PYTHONPATH="$repo${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m wgtun.sweep "$@"
