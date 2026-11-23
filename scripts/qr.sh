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

SELF=$(readlink -f "$0"); . "$(dirname "$SELF")/_lib.sh"

case "$1" in -h|--help) usage; exit 0 ;; esac
[ $# -le 2 ] || usage_error "qr.sh [<device> [<tunnel>]]"
command -v qrencode >/dev/null || die "qrencode missing (install.sh, or brew install qrencode)"

shopt -s nullglob

# 1. The device
devices=()
while read -r d; do devices+=("$d"); done < <(folders "$DEVICES")
[ ${#devices[@]} -gt 0 ] || die "no devices in $DEVICES (singbox.sh new <device>)"
if [ -z "$1" ] && [ -t 0 ]; then
    echo "Devices:" >&2
    [ -n "$MAC" ] && echo "  ($MAC is this Mac)" >&2
fi
device=$(pick device "$1" "${devices[@]}") || exit 1

# 2. One of its config/ tunnels
tunnels=()
for f in "$DEVICES/$device"/config/*.conf; do tunnels+=("$(basename "$f" .conf)"); done
[ ${#tunnels[@]} -gt 0 ] || die "no tunnels in $DEVICES/$device/config"
[ -z "$2" ] && [ -t 0 ] && echo "Tunnels on $device:" >&2
tunnel=$(pick tunnel "$2" "${tunnels[@]}") || exit 1
conf="$DEVICES/$device/config/$tunnel.conf"

# 3. The QR
grep -qi '^[[:space:]]*\[Interface\]' "$conf" && grep -qi '^[[:space:]]*PrivateKey' "$conf" \
    || die "$conf isn't a WireGuard config"
echo
qrencode -t ansiutf8 < "$conf" || die "qrencode failed"
echo "$tunnel ($device): scan in the WireGuard app, + > Create from QR code"
is_warped "$tunnel" && echo "note: $tunnel only carries WARP; alone in the WireGuard app it does nothing (use sing-box)"
echo "It holds the private key: clear the terminal when done (Cmd-K)"
