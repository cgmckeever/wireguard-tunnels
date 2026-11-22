#!/bin/bash
# _python.sh — runs wgtun/'s Python for the name it's called by:
# wgwarp-sweep.sh, singbox.sh and check.sh are links to it (each one's -h
# says what it does). Python 3.9+ (macOS's own python3), stdlib only.
# Follows links to find which one was meant and where the repo is (the menu
# bar plugin, wgtun.sh or your own ~/bin may hold a link to a link).
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
[ -n "$module" ] || { echo "_python.sh: run it as wgwarp-sweep.sh, singbox.sh or check.sh" >&2; exit 1; }
repo="$(cd "$(dirname "$src")/.." && pwd)"
PYTHONPATH="$repo${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m "wgtun.$module" "$@"
