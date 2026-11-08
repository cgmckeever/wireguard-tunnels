#!/bin/bash
# wgwarp-sweep.sh — make WireGuard configs carry a Cloudflare WARP tunnel.
# Any WireGuard server works as the carrier.
#
# Usage:
#   wgwarp-sweep.sh             this Mac's device folder (~/wg-tunnels/devices/
#                               .default, set by tunnel.sh default): carriers/ -> config/
#   wgwarp-sweep.sh <device>    ~/wg-tunnels/devices/<device> (singbox.sh build runs this)
#   wgwarp-sweep.sh <dir>       any folder with carriers/ in it
#
# Reads every carriers/<name>.conf (as downloaded from the provider) and writes
# config/warped.<name>.conf: AllowedIPs set to the WARP endpoint (plus the
# extras below), the DNS line removed and a keepalive, so the tunnel carries
# WARP and nothing else. A carrier already named warped.x or warped-x becomes
# warped.x, not warped.warped.x. A config/ file is only rewritten when the new
# one differs.
#
# Everything WARP-specific about a carrier is done here; tunnel.sh import and
# singbox.sh build only check it. The warped. prefix is how they know a tunnel
# carries WARP.
#
# For this Mac's device, the last column compares each one with the WireGuard app's
# tunnel of the same name (the app can't be scripted, so only its server
# address is visible) and says what to do there by hand. Only for tunnels you
# also keep in the app.
#
# singbox.sh build runs it with SWEEP_FOR_SINGBOX=1: no WireGuard app column
# and no "Next" lines, which are about this Mac's daemon. tunnel.sh import runs
# it for this Mac with SWEEP_NO_NEXT=1 (no "Next: tunnel.sh import" line).
# Neither needs it run by hand.
#
# The WARP endpoint comes from ~/wg-tunnels/.warp-endpoint (IPv4:port; default
# 162.159.192.1:2408; only the address is used here).

die() { echo "wgwarp-sweep.sh: $*" >&2; exit 1; }

TUNNELS="$HOME/wg-tunnels/devices"
MAC=$(cat "$TUNNELS/.default" 2>/dev/null)     # this Mac's device (tunnel.sh default)
[ $# -le 1 ] || die "usage: wgwarp-sweep.sh [<device>|<dir>]"
case "$1" in
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    -*) die "usage: wgwarp-sweep.sh [<device>|<dir>]" ;;
    "") [ -n "$MAC" ] || die "no default device yet: tunnel.sh default (or give a device or folder)"
        DIR="$TUNNELS/$MAC" ;;
    */*|.|..) DIR="$1" ;;
    *)  DIR="$TUNNELS/$1"; [ -d "$DIR" ] || DIR="$1" ;;
esac
[ -d "$DIR" ] || die "no folder $DIR"
# Only a device folder gets swept: never make carriers/ and config/ (and chmod
# 700) in some other folder that was named by mistake
[ -d "$DIR/carriers" ] || die "no carriers/ in $DIR (singbox.sh new <device> makes a device)"
# The WireGuard app column: this Mac's device only, and not for singbox.sh
APP=""
[ -z "$SWEEP_FOR_SINGBOX" ] && [ -n "$MAC" ] && [ -d "$TUNNELS/$MAC" ] \
    && [ "$(cd "$DIR" && pwd -P)" = "$(cd "$TUNNELS/$MAC" && pwd -P)" ] && APP=1
CARRIER_DIR="$DIR/carriers"
CONFIG_DIR="$DIR/config"
# The WARP endpoint: ~/wg-tunnels/.warp-endpoint (one line, IPv4:port), else
# Cloudflare's default. A file, not a variable, so the menu bar sees it too.
WARP_ENDPOINT=162.159.192.1:2408
[ -f "$HOME/wg-tunnels/.warp-endpoint" ] && WARP_ENDPOINT=$(tr -d ' \t\r\n' < "$HOME/wg-tunnels/.warp-endpoint")
[[ "$WARP_ENDPOINT" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+$ ]] \
    || die "~/wg-tunnels/.warp-endpoint: IPv4:port, e.g. 162.159.192.1:2408 (not $WARP_ENDPOINT)"
WARP_NET="${WARP_ENDPOINT%:*}/32"

# These hold private keys
umask 077
mkdir -p "$CONFIG_DIR" || die "can't create $CONFIG_DIR"
chmod 700 "$DIR" "$CARRIER_DIR" "$CONFIG_DIR"

# warped_name <carrier file>: the tunnel it becomes (x.conf, warped.x.conf and
# warped-x.conf all become warped.x). singbox.sh has the same one-liner.
warped_name() { echo "warped.$(basename "$1" .conf | sed -E 's/^warped[.-]//')"; }

# valid <conf>: a one-peer client config with a key and an endpoint (keys in
# any case, as wg-quick and tunnel.sh read them)
valid() {
    grep -qi '^\[Interface\]' "$1" && [ "$(grep -ci '^\[Peer\]' "$1")" = 1 ] \
        && grep -qiE '^[[:space:]]*PrivateKey[[:space:]]*=' "$1" \
        && grep -qiE '^[[:space:]]*Endpoint[[:space:]]*=' "$1"
}

# A carrier's AllowedIPs beyond the WARP endpoint come from these header lines:
#   # device-network: 10.9.8.0/24     (the wireguard-tools server repo writes this)
#   # tunnel-routes: 10.0.0.5/32       (add your own; a "#" after them is a comment)
# device-network is the server's static device addresses: with it the server
# and this device reach each other through the carrier. tunnel-routes is
# anything else that should go through the carrier instead of WARP. Rebuilt every sweep:
# delete a line and it's gone.
#
# extras <conf>: each entry on those lines as "<verdict> <entry>":
#   kept   an address or network the carrier takes
#   wide   wider than /8 (/16 for IPv6): it would take traffic away from WARP
#   bad    not an address (a hostname, a typo)
V4='^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$'
V6='^[0-9A-Fa-f]*:[0-9A-Fa-f:.]*(/[0-9]{1,3})?$'
extras() {
    local e p min max o1 o2 o3 o4
    sed -nE 's/^#[[:space:]]*(device-network|tunnel-routes):[[:space:]]*//p' "$1" \
        | sed 's/#.*//' | tr ', \t\r' '\n\n\n\n' | grep . | while read -r e; do
            if [[ "$e" =~ $V4 ]]; then min=8; max=32
                # Each of the four numbers fits in a byte
                IFS=./ read -r o1 o2 o3 o4 _ <<< "$e"
                [ "$o1" -le 255 ] && [ "$o2" -le 255 ] && [ "$o3" -le 255 ] && [ "$o4" -le 255 ] \
                    || { echo "bad $e"; continue; }
            elif [[ "$e" =~ $V6 ]]; then min=16; max=128
            else echo "bad $e"; continue
            fi
            p=$max; case "$e" in */*) p="${e#*/}" ;; esac
            if [ "$p" -gt "$max" ]; then echo "bad $e"
            elif [ "$p" -lt "$min" ]; then echo "wide $e"
            else echo "kept $e"
            fi
        done
}
# extras_of <conf> kept|wide|bad: just those entries, one per line
extras_of() { extras "$1" | sed -n "s/^$2 //p"; }

# render <carrier>: the warped config. It carries WARP and its extras only: one
# AllowedIPs line, DNS gone (it comes from WARP), a keepalive so a stale
# handshake means trouble.
render() {
    local allowed="$WARP_NET" e has=0
    while read -r e; do allowed+=", $e"; done < <(extras_of "$1" kept)
    grep -qiE '^[[:space:]]*AllowedIPs[[:space:]]*=' "$1" && has=1
    awk -v allowed="$allowed" -v has="$has" '
        { sub(/\r$/, ""); l = tolower($0) }
        l ~ /^[[:space:]]*dns[[:space:]]*=/                 { next }
        l ~ /^[[:space:]]*persistentkeepalive[[:space:]]*=/ { next }
        l ~ /^[[:space:]]*allowedips[[:space:]]*=/ { if (!done) print "AllowedIPs = " allowed; done = 1; next }
        l ~ /^[[:space:]]*endpoint[[:space:]]*=/ {
            print
            if (!has) print "AllowedIPs = " allowed
            print "PersistentKeepalive = 25"
            next
        }
        { print }
    ' "$1"
}

endpoint_of() {
    awk -F'[[:space:]]*=[[:space:]]*' 'tolower($0) ~ /^[[:space:]]*endpoint[[:space:]]*=/ {print $2; exit}' "$1"
}

# app_action <name> <endpoint> <new|updated|unchanged>: what to do about the
# WireGuard app's copy of a tunnel (only matters if you use the app). Nothing
# here is about tunnel.sh import, which reads config/ itself.
app_action() {
    local name="$1" endpoint="$2" state="$3" remote host ip
    [ -n "$APP" ] || return 0
    if [ -z "$(scutil --nc status "$name" 2>/dev/null | head -1)" ]; then
        echo "not there: add it in the app"
        return
    fi
    remote=$(scutil --nc show "$name" 2>/dev/null | awk -F' : ' '/RemoteAddress/ {print $2; exit}')
    # The app keeps the address a hostname resolved to: compare that too
    host="${endpoint%:*}"
    ip=$(dscacheutil -q host -a name "$host" 2>/dev/null | awk '/^ip_address:/ {print $2; exit}')
    if [ "$remote" != "$endpoint" ] && [ "$remote" != "${ip:-$host}:${endpoint##*:}" ]; then
        echo "there, other server (${remote:-?}): remove it and add again in the app"
    elif [ "$state" = "updated" ]; then
        echo "there, but changed: remove it and add again in the app"
    elif [ "$state" = "new" ]; then
        echo "there, same server: if the app's copy isn't this config, remove it and add again"
    else
        echo "there, same server"
    fi
}

row()  { printf '%-28s %-10s %s\n' "$@"; }
note() { printf '%-28s %s\n' "" "└ $*"; }
list() { paste -sd, - | sed 's/,/, /g'; }

shopt -s nullglob
raws=("$CARRIER_DIR"/*.conf)
if [ ${#raws[@]} -eq 0 ]; then
    echo "No configs in ${CARRIER_DIR}: put WireGuard configs there (x.conf becomes warped.x)"
    echo
fi

row "TUNNEL" "FILE" "$([ -n "$APP" ] && echo "WIREGUARD APP (only if you use it)")"
names=" "                       # every warped name a carrier claims
for raw in "${raws[@]}"; do
    name=$(warped_name "$raw")
    out="$CONFIG_DIR/${name}.conf"
    # Checked first: a broken carrier doesn't take the name from a good one
    if ! valid "$raw"; then
        row "$name" "skipped" "$(basename "$raw"): not a one-peer WireGuard config (Interface, one Peer, PrivateKey, Endpoint)"
        continue
    fi
    case "$names" in
        *" $name "*) row "$name" "skipped" "$(basename "$raw"): another carrier already makes $name"; continue ;;
    esac
    names+="$name "

    tmp=$(mktemp "$CONFIG_DIR/.render.XXXXXX") || die "mktemp failed in $CONFIG_DIR"
    render "$raw" > "$tmp" || { rm -f "$tmp"; die "can't render $raw"; }
    if [ -f "$out" ] && cmp -s "$tmp" "$out"; then
        rm -f "$tmp"
        state="unchanged"
    else
        [ -f "$out" ] && state="updated" || state="new"
        mv "$tmp" "$out" || { rm -f "$tmp"; die "can't write $out"; }
    fi

    row "$name" "$state" "$(app_action "$name" "$(endpoint_of "$out")" "$state")"
    e=$(extras_of "$raw" kept | list); [ -n "$e" ] && note "also carries ${e}"
    e=$(extras_of "$raw" wide | list); [ -n "$e" ] && note "ignored, too wide (would bypass WARP): ${e}"
    e=$(extras_of "$raw" bad | list);  [ -n "$e" ] && note "ignored, not an address: ${e}"
    # WARP needs 1280 inside (IPv6's minimum), so a carrier under 1360 makes
    # tunnel.sh and singbox.sh run it at the carrier's MTU - 80
    mtu=$(sed -nE 's/^[[:space:]]*[Mm][Tt][Uu][[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$out" | head -1)
    if [ -n "$mtu" ] && [ "$mtu" -lt 1360 ]; then
        note "carrier MTU ${mtu}: WARP runs at $((mtu - 80)) inside (IPv6 and QUIC fall back)"
    fi
done

# config/ files no carrier claims: one carrying only the WARP endpoint (plus
# extras) was swept and lost its carrier (an orphan: reported, never deleted);
# anything else was put there by hand
for out in "$CONFIG_DIR"/*.conf; do
    name=$(basename "$out" .conf)
    case "$names" in *" $name "*) continue ;; esac
    if grep -qiE "^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*${WARP_NET//./\\.}([[:space:]]*,.*)?[[:space:]]*$" "$out"; then
        row "$name" "orphan" "(no usable carrier in carriers/: left in place)"
    else
        row "$name" "manual" "$(app_action "$name" "$(endpoint_of "$out")" "unchanged")"
    fi
done

[ -n "$APP" ] || exit 0
echo
[ -n "$SWEEP_NO_NEXT" ] || echo "Next: tunnel.sh import   (installs everything in ${CONFIG_DIR} for the daemon)"
echo "The WireGuard app column is only for tunnels you also keep in the app; skip it otherwise."
