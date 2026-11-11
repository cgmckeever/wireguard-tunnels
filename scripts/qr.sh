#!/bin/bash
# qr.sh — show a device's tunnel as a QR code, to scan into the WireGuard app
# (iPhone, Android: + > Create from QR code).
#
# Usage:
#   qr.sh                        pick a device, then one of its config/ tunnels
#   qr.sh <device>               pick one of that device's tunnels
#   qr.sh <device> <tunnel>      that one (a name, or its number in the list)
#
# The QR holds the tunnel's private key: show it only to the device it's for,
# and clear the terminal after (it's in the scrollback until then).
#
# A warped.* tunnel only carries WARP: in the WireGuard app, which can't run
# one tunnel inside another, it does nothing alone. For WARP in the app use
# warp.<device>; for WARP inside a carrier use the sing-box profiles instead.
#
# Needs qrencode (install.sh installs it; or brew install qrencode).

die() { echo "qr.sh: $*" >&2; exit 1; }

TUNNELS_DIR="$HOME/wg-tunnels/devices"
MAC=$(cat "$TUNNELS_DIR/.default" 2>/dev/null)     # this Mac's device

case "$1" in -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;; esac
[ $# -le 2 ] || die "usage: qr.sh [<device> [<tunnel>]]"
command -v qrencode >/dev/null || die "qrencode missing (install.sh, or brew install qrencode)"

# pick <what> <choice> <names...>: the name chosen by number or name; asks
# (a numbered list) when there's no choice yet. Enter takes a lone option.
pick() {
    local what="$1" choice="$2" i n def="" prompt
    shift 2
    [ $# -gt 0 ] || die "no ${what}s"
    if [ -z "$choice" ]; then
        [ -t 0 ] || die "which ${what}? (no terminal to ask in)"
        i=1
        for n in "$@"; do printf '  %d) %s\n' "$i" "$n" >&2; i=$((i + 1)); done
        [ $# -eq 1 ] && def=1
        prompt="Pick a $what [1-$#]"; [ -n "$def" ] && prompt+=" (Enter = $1)"
        read -rp "${prompt}: " choice
        choice="${choice:-$def}"
        [ -n "$choice" ] || die "nothing picked"
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $# ]; then
        echo "${!choice}"; return
    fi
    for i; do [ "$i" = "$choice" ] && { echo "$i"; return; }; done
    die "no ${what} '${choice}'"
}

shopt -s nullglob

# 1. The device
devices=()
for d in "$TUNNELS_DIR"/*/; do devices+=("$(basename "$d")"); done
[ ${#devices[@]} -gt 0 ] || die "no devices in $TUNNELS_DIR (singbox.sh new <device>)"
if [ -z "$1" ] && [ -t 0 ]; then
    echo "Devices:" >&2
    [ -n "$MAC" ] && echo "  ($MAC is this Mac)" >&2
fi
device=$(pick device "$1" "${devices[@]}") || exit 1

# 2. One of its config/ tunnels
tunnels=()
for f in "$TUNNELS_DIR/$device"/config/*.conf; do tunnels+=("$(basename "$f" .conf)"); done
[ ${#tunnels[@]} -gt 0 ] || die "no tunnels in $TUNNELS_DIR/$device/config"
[ -z "$2" ] && [ -t 0 ] && echo "Tunnels on $device:" >&2
tunnel=$(pick tunnel "$2" "${tunnels[@]}") || exit 1
conf="$TUNNELS_DIR/$device/config/$tunnel.conf"

# 3. The QR
grep -qi '^[[:space:]]*\[Interface\]' "$conf" && grep -qi '^[[:space:]]*PrivateKey' "$conf" \
    || die "$conf isn't a WireGuard config"
echo
qrencode -t ansiutf8 < "$conf" || die "qrencode failed"
echo "$tunnel ($device): scan in the WireGuard app, + > Create from QR code"
case "$tunnel" in
    warped.*) echo "note: $tunnel only carries WARP; alone in the WireGuard app it does nothing (use sing-box)" ;;
esac
echo "It holds the private key: clear the terminal when done (Cmd-K)"
