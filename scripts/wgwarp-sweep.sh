#!/bin/bash
# wgwarp-sweep.sh — make WireGuard configs carry a Cloudflare WARP tunnel.
# Any WireGuard server works as the carrier.
#
# Usage:
#   wgwarp-sweep.sh
#
# Reads every ~/wg-tunnels/carriers/<name>.conf (as downloaded from the
# provider, named however you like) and writes
# ~/wg-tunnels/config/warped.<name>.conf with AllowedIPs set to the WARP
# endpoint (plus the addresses to reach the server by, see extras below), the DNS
# line removed and a keepalive, so the tunnel carries WARP and nothing else.
# Everything WARP-specific about a carrier is done here; import only checks it. The warped. prefix is how `tunnel.sh import` knows a tunnel carries
# WARP (a carrier already named warped.* or warped-* isn't prefixed twice).
# An existing config/ file is only replaced when the new render differs.
#
# The last column compares each one with the WireGuard app's tunnel of the same
# name (the app can't be scripted, so only its server address is visible) and
# says what to do there by hand. Only for tunnels you also keep in the app.
#
# Override with TUNNELS_DIR (default ~/wg-tunnels) and WARP_ENDPOINT
# (default 162.159.192.1, engage.cloudflareclient.com).

TUNNELS_DIR="${TUNNELS_DIR:-$HOME/wg-tunnels}"
CARRIER_DIR="$TUNNELS_DIR/carriers"
CONFIG_DIR="$TUNNELS_DIR/config"
WARP_ENDPOINT="${WARP_ENDPOINT:-162.159.192.1}"

# These hold private keys
umask 077
mkdir -p "$CARRIER_DIR" "$CONFIG_DIR"
chmod 700 "$TUNNELS_DIR" "$CARRIER_DIR" "$CONFIG_DIR"

valid() {
    grep -q '^\[Interface\]' "$1" && grep -q '^\[Peer\]' "$1" \
        && grep -qE '^[[:space:]]*PrivateKey[[:space:]]*=' "$1" \
        && grep -qE '^[[:space:]]*Endpoint[[:space:]]*=' "$1"
}

# A carrier's AllowedIPs beyond the WARP endpoint, from its header comments:
#   # device-network: 10.9.8.0/24     (wireguard-tools writes this)
#   # wg-tunnels: also 10.0.0.5/32    (add your own)
# wireguard-tools' static device addresses let the server and the Mac reach each
# other through the carrier. Rebuilt every sweep: delete a line and it's gone.
# extras <conf> narrow|wide: the entries a carrier may have, or the ones refused
# (wider than /8, or /16 for IPv6: those would take traffic away from WARP)
extras() {
    local e p
    sed -nE 's/^#[[:space:]]*(device-network:|wg-tunnels:[[:space:]]*also)[[:space:]]*//p' "$1" \
        | tr ', \t\r' '\n\n\n\n' | grep . | while read -r e; do
            p="${e#*/}"; [ "$p" = "$e" ] && p=128
            case "$e" in *:*) min=16 ;; *) min=8; [ "$p" = 128 ] && p=32 ;; esac
            if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge "$min" ]; then
                [ "$2" = narrow ] && echo "$e"
            else
                [ "$2" = wide ] && echo "$e"
            fi
        done
}

# The carrier carries WARP and its extras only: AllowedIPs set, DNS gone (it
# comes from WARP), a keepalive so a stale handshake means trouble
render() {
    local allowed="$WARP_ENDPOINT/32" e
    for e in $(extras "$1" narrow); do allowed+=", $e"; done
    awk -v allowed="$allowed" '
        { sub(/\r$/, "") }
        /^[[:space:]]*DNS[[:space:]]*=/                 { next }
        /^[[:space:]]*PersistentKeepalive[[:space:]]*=/ { next }
        /^[[:space:]]*AllowedIPs[[:space:]]*=/          { print "AllowedIPs = " allowed; next }
        /^[[:space:]]*Endpoint[[:space:]]*=/            { print; print "PersistentKeepalive = 25"; next }
        { print }
    ' "$1"
}

endpoint_of() {
    awk -F'[[:space:]]*=[[:space:]]*' '/^[[:space:]]*Endpoint[[:space:]]*=/ {print $2; exit}' "$1"
}

# The WireGuard app's copy of a tunnel (only matters if you use the app), given
# the config/ file's state (new/updated/unchanged). Nothing here is about
# tunnel.sh import, which reads config/ itself.
app_action() {
    local name="$1" endpoint="$2" state="$3" remote host ip
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
        echo "there, same server: add again in the app if it wasn't from config/"
    else
        echo "there, same server"
    fi
}

shopt -s nullglob
raws=("$CARRIER_DIR"/*.conf)
if [ ${#raws[@]} -eq 0 ]; then
    echo "No configs in ${CARRIER_DIR} — put WireGuard configs there, named <tunnel>.conf"
    echo
fi

printf '%-28s %-10s %s\n' "TUNNEL" "FILE" "WIREGUARD APP (only if you use it)"
for raw in "${raws[@]}"; do
    name="warped.$(basename "$raw" .conf | sed -E 's/^warped[.-]//')"
    out="$CONFIG_DIR/${name}.conf"

    if ! valid "$raw"; then
        printf '%-28s %-10s %s\n' "$name" "skipped" "not a WireGuard config (no Interface/Peer/PrivateKey/Endpoint)"
        continue
    fi

    tmp=$(mktemp "$CONFIG_DIR/.render.XXXXXX")
    render "$raw" > "$tmp"
    if [ -f "$out" ] && cmp -s "$tmp" "$out"; then
        rm -f "$tmp"
        state="unchanged"
    else
        [ -f "$out" ] && state="updated" || state="new"
        mv "$tmp" "$out"
    fi

    printf '%-28s %-10s %s\n' "$name" "$state" "$(app_action "$name" "$(endpoint_of "$out")" "$state")"
    e=$(extras "$raw" narrow | paste -sd, - | sed 's/,/, /g')
    [ -n "$e" ] && printf '%-28s %s\n' "" "└ also carries ${e}"
    e=$(extras "$raw" wide | paste -sd, - | sed 's/,/, /g')
    [ -n "$e" ] && printf '%-28s %s\n' "" "└ ignored, too wide (would bypass WARP): ${e}"
    # A small carrier MTU: the daemon runs WARP 80 smaller inside it (tunnel.sh)
    mtu=$(sed -nE 's/^[[:space:]]*MTU[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$out" | head -1)
    if [ -n "$mtu" ] && [ "$mtu" -lt 1360 ]; then
        printf '%-28s %s\n' "" "└ carrier MTU ${mtu}: WARP runs at $((mtu - 80)) inside (IPv6 and QUIC fall back)"
    fi
done

# config/ files with no carriers/ source: a WARP-pinned one lost its source
# (reported, never deleted); anything else was put there by hand
for out in "$CONFIG_DIR"/*.conf; do
    name=$(basename "$out" .conf)
    src=0
    for raw in "${raws[@]}"; do
        [ "warped.$(basename "$raw" .conf | sed -E 's/^warped[.-]//')" = "$name" ] && src=1 && break
    done
    [ "$src" = 1 ] && continue
    if grep -qE "^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*${WARP_ENDPOINT//./\\.}/32([[:space:]]*,.*)?[[:space:]]*$" "$out"; then
        printf '%-28s %-10s %s\n' "$name" "orphan" "(no carriers/ source: left in place)"
    else
        printf '%-28s %-10s %s\n' "$name" "manual" "$(app_action "$name" "$(endpoint_of "$out")" "unchanged")"
    fi
done

echo
echo "Next: tunnel.sh import   (installs everything in ${CONFIG_DIR} for the daemon)"
echo "The WireGuard app column is only for tunnels you also keep in the app; skip it otherwise."
