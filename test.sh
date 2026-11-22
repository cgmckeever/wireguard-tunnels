#!/bin/bash
# test.sh — the tests (and lint): wgtun/, the Python behind the sweep,
# singbox.sh and check.sh, and the shell scripts. No root, no network, no real
# store: each test makes its own.
# The first run creates .venv/ with pytest, ruff and mypy; later runs reuse it.
#   ./test.sh            the tests (any pytest option works: ./test.sh -k keepalive)
#   ./test.sh lint       ruff and mypy (settings and pinned versions: pyproject.toml);
#                        the tests run bash -n (macOS's 3.2) on every shell script
#   ./test.sh all        lint, then the tests (the pre-commit hook and CI run this)
#   ./test.sh hooks      have git run ./test.sh all before each commit (.githooks/)
set -euo pipefail
cd "$(dirname "$0")"
if [ "${1:-}" = hooks ]; then
    git config core.hooksPath .githooks && echo "git runs .githooks/pre-commit (./test.sh all) before each commit"
    exit
fi
# The tools' versions, pinned in pyproject.toml: the hook and CI run the same ones
pin() { sed -n "s/^$1 *= *\"=*\([^\"]*\)\".*/\1/p" pyproject.toml | head -1; }
RUFF=$(pin required-version) PYTEST=$(pin pytest) MYPY=$(pin mypy)
# The oldest Python the scripts must run on: macOS's own (3.9), when it's here
PY=/usr/bin/python3; [ -x "$PY" ] || PY=python3
if [ ! -x .venv/bin/python ] || ! .venv/bin/python -c 'import pytest, ruff, mypy' 2>/dev/null \
    || [ "$(.venv/bin/ruff --version)" != "ruff $RUFF" ] \
    || [ "$(.venv/bin/python -m pytest --version 2>&1)" != "pytest $PYTEST" ] \
    || [ "$(.venv/bin/mypy --version | cut -d' ' -f2)" != "$MYPY" ] \
    || [ "$(.venv/bin/python -V 2>&1)" != "$("$PY" -V 2>&1)" ]; then
    echo "==> Setting up .venv ($("$PY" -V 2>&1)) with pytest, ruff and mypy"
    "$PY" -m venv --clear .venv
    .venv/bin/pip install -q "pytest==$PYTEST" "ruff==$RUFF" "mypy==$MYPY"
fi
lint() {
    .venv/bin/ruff check wgtun tests
    .venv/bin/mypy
}
case "${1:-}" in
    lint) lint ;;
    all)  shift; lint; exec .venv/bin/python -m pytest -q tests "$@" ;;
    *)    exec .venv/bin/python -m pytest -q tests "$@" ;;
esac
