#!/bin/bash
# wgtun.sh — one entry point for the scripts here: lists them, or runs one.
#
# Usage:
#   wgtun.sh                       list them, then pick one to run
#   wgtun.sh <script> [args...]    run it with those arguments, e.g.
#                                  wgtun.sh tunnel up, wgtun.sh nord device mbp-1
#   wgtun.sh <script> -h           that script's own usage
#   wgtun.sh -h                    this list
#
# <script> is tunnel, singbox, nord, qr, wgwarp-sweep or check (".sh" optional). Each runs exactly
# as it would by its own path.

set -euo pipefail

# The real folder, even when this is run through a link
here=$(dirname "$(readlink -f "$0")")

# name|summary
TOOLS=(
    "tunnel|This Mac's tunnels: up, down, pause, status, import, extract, rotate-warp, diag"
    "singbox|Devices on sing-box (iPhone, Apple TV...): new, build, list"
    "nord|A NordVPN config for a device (carrier or config) or a server (an exit)"
    "qr|A device's tunnel as a QR code, to scan into the WireGuard app"
    "wgwarp-sweep|Sweep a device's carriers into warped tunnels (import and build run it for you)"
    "check|Is the store as the scripts leave it? configs, keys, keepalives, profiles"
)

list() {
    local t i=1
    echo "wgtun.sh <script> [args]   (wgtun.sh <script> -h for its commands)"
    echo
    for t in "${TOOLS[@]}"; do
        printf '  %d) %-12s %s\n' "$i" "${t%%|*}" "${t#*|}"
        i=$((i + 1))
    done
}

run() {
    local name="${1%.sh}" t
    shift
    for t in "${TOOLS[@]}"; do
        if [ "${t%%|*}" = "$name" ]; then
            [ "${1:-}" = help ] && set -- --help      # every script takes -h/--help
            exec "$here/$name.sh" "$@"
        fi
    done
    echo "wgtun.sh: no script '$name'" >&2
    list >&2
    exit 1
}

case "${1:-}" in
    -h|--help|help) list; exit 0 ;;
    "")
        list
        [ -t 0 ] || exit 0
        echo
        read -rp "Pick one [1-${#TOOLS[@]}] (Enter = quit): " choice
        [ -n "$choice" ] || exit 0
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#TOOLS[@]} ]; then
            choice="${TOOLS[$((choice - 1))]%%|*}"
        fi
        run "$choice"
        ;;
    *) run "$@" ;;
esac
