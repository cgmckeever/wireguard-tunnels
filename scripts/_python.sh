#!/bin/bash
# _python.sh — runs wgtun/'s Python for the name it's called by:
# wgwarp-sweep.sh, singbox.sh and check.sh are links to it (each one's -h
# says what it does). Python 3.9+ (macOS's own python3), stdlib only.
# Follows links to find which one was meant and where the repo is (wgtun.sh
# or your own ~/bin may hold a link to a link). install.sh runs it by its own
# name: _python.sh forinstall <args>.
src="$0" module=""
while :; do
    case "$(basename "$src" .sh)" in
        wgwarp-sweep) module=${module:-sweep} ;;
        singbox)      module=${module:-singbox} ;;
        check)        module=${module:-check} ;;
    esac
    [ -L "$src" ] || break
    l=$(readlink "$src"); case "$l" in /*) src="$l" ;; *) src="$(dirname "$src")/$l" ;; esac
done
if [ -z "$module" ]; then
    [ "${1:-}" = forinstall ] || { echo "_python.sh: run it as wgwarp-sweep.sh, singbox.sh or check.sh" >&2; exit 1; }
    module=forinstall; shift
fi
repo="$(cd "$(dirname "$src")/.." && pwd)"
# This repo's wgtun first, in place of the current directory (python3 -m would
# put that first: run from another checkout, it would run that one's code)
exec python3 -c 'import runpy, sys; sys.path[0] = sys.argv.pop(1)
runpy.run_module("wgtun." + sys.argv.pop(1), run_name="__main__", alter_sys=True)' "$repo" "$module" "$@"
