#!/bin/bash
# tunnel.sh — WireGuard tunnels run by wg-quick under a root LaunchDaemon,
# for every user on the Mac. Run it by its path (see README.md).
#
# Usage:
#   tunnel.sh up [n|name]   Ask "warped [Y/n]":
#                             Y  pick a warped.* tunnel: it, then WARP inside it
#                             n  pick any other tunnel and run it alone
#                           Enter at a menu takes the last one used, or the only one.
#                           A number picks from the warped list; a name, any tunnel.
#   tunnel.sh down          Everything down, back to the normal connection
#   tunnel.sh [status]      Tunnels, what's up, handshakes, the exit
#   tunnel.sh list          Number the warped and other tunnels
#   tunnel.sh extract [zip] Replace config/ with the .conf files in the newest
#                           zip in exports/ (or the one given): the zip is the
#                           authority, configs not in it are removed. The zip is kept.
#   tunnel.sh import [dir] [-y]
#                           Sweep carriers/ into config/ (wgwarp-sweep.sh; not
#                           with a dir), then install every .conf in config/
#                           (or dir) for the daemon. Tunnels gone from it are removed.
#                           Shows what it would do and asks first (-y: don't ask).
#   tunnel.sh default [device]
#                           Show or pick this Mac's device folder (asked the
#                           first time a command needs it)
#   tunnel.sh extract-import [zip]
#                           Both: extract, then import
#   tunnel.sh update        Update the daemon from this copy, only if it differs
#                           (every command that asks the daemon does this too)
#   tunnel.sh install       Install /usr/local/sbin/wg-tunnels and its LaunchDaemon
#   tunnel.sh uninstall     Take everything down, remove both (configs are kept)
#   tunnel.sh rotate-warp   New Cloudflare WARP keys: registers a new account
#                           (install.sh), imports it, and reconnects a warped
#                           tunnel that's up. The old account's files are
#                           removed once that works (Cloudflare isn't told),
#                           or put back if registering fails.
#   tunnel.sh pause [min]   Kill switch off and tunnel down for min minutes
#                           (default 10; for a hotel or café sign-in page), then
#                           the daemon brings the tunnel back by itself
#   tunnel.sh resume        End a pause now
#   tunnel.sh diag [file]   Diagnostics in one file (status, configs, routes, DNS,
#                           the log), private and preshared keys removed
#   tunnel.sh log           Follow the daemon's log
#   tunnel.sh breakglass    Lost the network? Stops app tunnels, the daemon,
#                           wg-quick and wireguard-go; removes every route of ours
#                           and any reject route; puts tunnel DNS back to DHCP;
#                           power cycles Wi-Fi if it has no address. Trusts no state.
#
# up, down, pause, resume, import, rotate-warp, diag, update, install, uninstall
# and breakglass use sudo (admin users).
#
# install.sh (in this repo) sets up what this needs: wireguard-tools, wgcf,
# this Mac's WARP account and config, and the daemon.
#
# ~/wg-tunnels/devices/<device>/ is one device's tunnels; devices/.default
# names this Mac's (`tunnel.sh default`). extract, import, rotate-warp and the sweep
# use that folder: config/ holds every tunnel's .conf, and `tunnel.sh import`
# installs them. Fill it by hand, or from the WireGuard app: Export Tunnels to
# Zip into exports/, then `tunnel.sh extract-import`. The app is optional.
# Activate tunnels with `tunnel.sh up`. A non-warped tunnel can still be switched
# on in the app, but only after `tunnel.sh down` (the kill switch below would
# swallow its traffic).
#
# Routing while a full tunnel is up (macOS uses the most specific route):
#   tunnel server /32      -> physical gateway   (pinned; re-pinned if the gateway changes)
#   WARP endpoint /32      -> carrier            (warped: the carrier carries only WARP)
#   WARP endpoint /31      -> reject             (carrier gone: WARP can't loop into itself)
#   0/2 64/2 128/2 192/2   -> exit (WARP, or the other tunnel); ::/2-sized for IPv6
#   0/1 128/1, ::/1 8000::/1 -> reject           (kill switch: nothing leaves outside a tunnel)
#   LAN, default           -> unchanged
# The kill switch stays until `tunnel.sh down`: a tunnel failing never falls back
# to the normal connection. A split tunnel (no 0.0.0.0/0) runs without it.
#
# The daemon brings back the last `up` after a reboot and checks every 30s:
# re-pins the server when the gateway changes or its route is gone (checked
# every 5s, so rejoining Wi-Fi recovers in seconds), gives the exit (WARP, or the
# tunnel itself, if it has a keepalive) a new source port when it stops
# handshaking, then restarts it, and restarts anything that died.

LABEL="com.local.wg-tunnels"
INSTALLED="/usr/local/sbin/wg-tunnels"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
LOG="/var/log/wg-tunnels.log"
TUNNEL_PREFIX="warped."
# is_warped <name>: a tunnel that carries WARP, by its prefix in any case (the
# Mac's file system ignores case: Warped.x is the file the sweep writes as warped.x)
lower() { tr '[:upper:]' '[:lower:]' <<< "$1"; }
is_warped() { case "$(lower "$1")" in "$TUNNEL_PREFIX"*) return 0 ;; esac; return 1; }

for PREFIX in /opt/homebrew /usr/local; do
    [ -x "$PREFIX/bin/wg-quick" ] && break
done
export PATH="${WGT_PATH:+$WGT_PATH:}$PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Root-owned. Testing without root: WGT_TEST=1 plus WGT_ETC, WGT_RUN,
# WGT_WG_RUN and WGT_PATH (stand-ins for route, wg, wg-quick, netstat)
ETC="${WGT_ETC:-$PREFIX/etc/wg-tunnels}"
RUN="${WGT_RUN:-/var/run/wg-tunnels}"
CONF="$ETC/conf"                       # <iface>.conf, 0600 (private keys)
TSV="$ETC/tunnels.tsv"                 # name iface kind endpoint-ip
STATE="$ETC/state"                     # desired (up <name> | down | pause <name> <until>), last-warped, last-other
WARP_SRC="$PREFIX/etc/wireguard/warp.conf"  # written by install.sh
WG_RUN="${WGT_WG_RUN:-/var/run/wireguard}"  # wg-quick's <iface>.name -> utunN

WG_TUNNELS="${WG_TUNNELS:-$HOME/wg-tunnels}"  # the store shared with wireguard-tools
TUNNELS="$WG_TUNNELS/devices"          # one folder per device
DEFAULT_FILE="$TUNNELS/.default"        # this Mac's device: one line, its folder name
WAIT_SECS=30
WATCH_SECS=30
NET_SECS=5      # how often to look for a network change (cheap: no wg calls)
STALE_SECS=180
PROBE_IP=1.1.1.1  # answers ping through WARP; for fit_path_mtu
MTU_EVERY=10      # WARP alone: measure again every 10 watchdog runs (about 5 min)
MTU_TICK=0
V4_HALVES="0.0.0.0/1 128.0.0.0/1"
V6_HALVES="::/1 8000::/1"
V4_QUARTERS="0.0.0.0/2 64.0.0.0/2 128.0.0.0/2 192.0.0.0/2"
V6_QUARTERS="::/2 4000::/2 8000::/2 c000::/2"

# --- small helpers ---

# No terminal (the SwiftBar menu) and an askpass helper given: ask with a dialog
sudo() {
    if [ -n "$SUDO_ASKPASS" ] && ! [ -t 0 ]; then command sudo -A "$@"; else command sudo "$@"; fi
}

die() { echo "$*" >&2; exit 1; }

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

need_root() {
    [ "$(id -u)" -eq 0 ] || [ -n "$WGT_TEST" ] || die "$1 needs root"
}

# --- this Mac's device folder ---

# devices: the device folders in $WG_TUNNELS/devices, one per line
devices() {
    local d
    for d in "$TUNNELS"/*/; do
        [ -d "$d" ] && basename "$d"
    done
}

# default [device]: show or pick this Mac's device folder, saved in
# $WG_TUNNELS/devices/.default. Changing it leaves the daemon's tunnels alone.
cmd_default() {
    local cur pick answer i devs=()
    cur=$(cat "$DEFAULT_FILE" 2>/dev/null)
    while read -r i; do devs+=("$i"); done < <(devices)
    pick="$1"
    if [ -z "$pick" ]; then
        [ ${#devs[@]} -gt 0 ] || die "No device folders in ${TUNNELS} yet: install.sh makes this Mac's"
        echo "Device folders in ${TUNNELS}; the default is this Mac's (extract, import,"
        echo "rotate-warp and wgwarp-sweep.sh use it):"
        for i in "${!devs[@]}"; do
            printf '  %d) %s%s\n' $((i + 1)) "${devs[i]}" "$([ "${devs[i]}" = "$cur" ] && echo '   (default)')"
        done
        [ -t 0 ] || { [ -n "$cur" ] || echo "No default yet: run tunnel.sh default in a terminal"; return 0; }
        read -rp "Default [${cur:-pick one}]: " answer
        if [ -z "$answer" ]; then
            [ -n "$cur" ] || die "Nothing picked"
            return 0
        elif [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le ${#devs[@]} ]; then
            pick="${devs[answer - 1]}"
        else
            pick="$answer"
        fi
    fi
    [ -d "$TUNNELS/$pick" ] && valid_device "$pick" \
        || die "No device folder ${TUNNELS}/${pick}"
    [ "$pick" = "$cur" ] && { echo "default: ${pick}"; return 0; }
    put "$DEFAULT_FILE" "$pick" 644 || die "Can't write ${DEFAULT_FILE}"
    echo "default: ${pick}"
    [ -z "$cur" ] || echo "The daemon's tunnels are unchanged: tunnel.sh import installs ${pick}'s"
}

# mac_dir: this Mac's device folder (asks for it the first time, in a terminal)
mac_dir() {
    local dev
    dev=$(cat "$DEFAULT_FILE" 2>/dev/null)
    if [ -z "$dev" ]; then
        [ -t 0 ] || die "No default device yet: run tunnel.sh default in a terminal"
        cmd_default >&2 || exit 1
        dev=$(cat "$DEFAULT_FILE" 2>/dev/null)
        [ -n "$dev" ] || exit 1
    fi
    valid_device "$dev" || die "${DEFAULT_FILE} doesn't hold a device name: tunnel.sh default to pick one"
    [ -d "$TUNNELS/$dev" ] || die "The default device ${dev} has no folder ${TUNNELS}/${dev}: tunnel.sh default to pick another"
    echo "$TUNNELS/$dev"
}

# Write $2 to $1 atomically (new inode), mode $3
put() {
    local tmp
    tmp=$(mktemp "$1.XXXXXX") || return 1
    { printf '%s\n' "$2" > "$tmp" && chmod "${3:-644}" "$tmp" && mv -f "$tmp" "$1"; } || { rm -f "$tmp"; return 1; }
}

# conf_vals <file> <key>: every value of key (any case), everything after
# the first "=" (so a base64 key keeps its "=" padding) up to a "#" (wg-quick
# drops a comment), CR line ends dropped: as wgtun's conf.py reads them
conf_vals() {
    awk -v k="$2" '
        { line = $0; sub(/\r$/, "", line) }
        tolower(line) ~ "^[[:space:]]*" tolower(k) "[[:space:]]*=" {
            v = substr(line, index(line, "=") + 1)
            sub(/#.*/, "", v)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            print v
        }' "$1"
}
conf_val() { conf_vals "$1" "$2" | head -1; }     # the first
# list_of <file> <key>: every comma-separated entry of every key line (AllowedIPs, DNS)
list_of() { conf_vals "$1" "$2" | tr ', \t' '\n\n\n' | grep .; }
# same_key <conf> <conf>: both on one private key (a WARP config, say)
same_key() { local a; a=$(conf_val "$1" PrivateKey); [ -n "$a" ] && [ "$a" = "$(conf_val "$2" PrivateKey)" ]; }
# has_keepalive <conf>: a PersistentKeepalive of a whole number over 0, as
# wgtun reads it (0, 00 and off are none). Only such a tunnel must keep
# handshaking: an idle one without has no handshakes.
has_keepalive() {
    local v
    [ -f "$1" ] || return 1
    v=$(conf_val "$1" PersistentKeepalive)
    [[ "$v" =~ ^[0-9]+$ ]] && [ $((10#$v)) -gt 0 ]
}
# valid_device <name>: a device folder's name (letters, digits, . _ -, not starting with .)
valid_device() { [[ "$1" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]]; }
# joined: stdin's lines as "a, b, c"
joined() { paste -sd, - | sed 's/,/, /g'; }

host_of() { sed -E 's/^\[?([^]]*)\]?:[0-9]+$/\1/'; }

gateway() {
    netstat -nr -f inet | awk '$1 == "default" && $2 !~ /^link#/ {print $2; exit}'
}

route_if() { route -n get "$1" 2>/dev/null | awk '/interface:/ {print $2}'; }
route_gw() { route -n get "$1" 2>/dev/null | awk '/gateway:/ {print $2}'; }

# Real utunN behind a wg-quick interface name, empty if it isn't up
utun_of() {
    local u
    u=$(cat "$WG_RUN/$1.name" 2>/dev/null)
    [ -n "$u" ] && [ -S "$WG_RUN/$u.sock" ] && echo "$u"
}

hs_age() {  # seconds since the newest handshake on wg-quick iface $1 (empty if none)
    local u ts
    u=$(utun_of "$1") || return
    ts=$(wg show "$u" latest-handshakes 2>/dev/null | awk '$2 > m {m = $2} END {print m + 0}')
    [ "${ts:-0}" -gt 0 ] && echo $(( $(date +%s) - ts ))
}

tsv_get() {  # tsv_get <name> — "iface kind endpoint"
    awk -F'\t' -v n="$1" '$1 == n {print $2, $3, $4; exit}' "$TSV" 2>/dev/null
}

# --- import (root) ---

# A warped carrier as wgwarp-sweep.sh makes it, which import checks but doesn't
# fix: AllowedIPs has the WARP endpoint and nothing wide (wider than /8, /16
# for IPv6, would route traffic around WARP), and no DNS. Prints why not.
swept_ok() {  # swept_ok <conf> <warp-endpoint>
    local ips e p min
    grep -qiE '^[[:space:]]*DNS[[:space:]]*=' "$1" && { echo "has a DNS line"; return 1; }
    ips=$(list_of "$1" AllowedIPs)
    grep -Fqx "$2/32" <<< "$ips" || { echo "AllowedIPs lacks the WARP endpoint $2/32"; return 1; }
    for e in $ips; do
        p="${e#*/}"
        case "$e" in *:*) [ "$p" = "$e" ] && p=128; min=16 ;; *) [ "$p" = "$e" ] && p=32; min=8 ;; esac
        { [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge "$min" ]; } || { echo "AllowedIPs ${e} is too wide"; return 1; }
    done
}

# kind_of <name> <conf>: warped (by name), full (all of IPv4: any x.x.x.x/0 —
# wg ignores the address bits, e.g. 192.168.1.0/0 — or the two /1 halves), or split
kind_of() {
    local ips
    is_warped "$1" && { echo warped; return; }
    ips=$(list_of "$2" AllowedIPs)
    if grep -qxE '[0-9.]+/0' <<< "$ips" \
        || { grep -qx '0\.0\.0\.0/1' <<< "$ips" && grep -qx '128\.0\.0\.0/1' <<< "$ips"; }; then
        echo full
    else
        echo split
    fi
}

# render <src> <kind> <endpoint-ip>: the daemon's copy of a tunnel (a warped
# one arrives as the sweep wrote it: swept_ok checked it)
#   full:   Table = off (the daemon does the routes), DNS kept
#   warped, split: as is
#   all:    Endpoint host resolved to the IP (DNS can be cut off while switching);
#           no PreUp/PostUp/PreDown/PostDown: they'd run as root, from a file
#           any user process of yours can edit
render() {
    awk -v kind="$2" -v ip="$3" '
        { sub(/\r$/, ""); l = tolower($0) }      # keys in any case, as wg-quick reads them
        l ~ /^[[:space:]]*(preup|postup|predown|postdown)[[:space:]]*=/ { next }
        l ~ /^[[:space:]]*\[interface\]/ { print; if (kind == "full") print "Table = off"; sec = "i"; next }
        l ~ /^[[:space:]]*\[peer\]/      { print; sec = "p"; next }
        sec == "i" && l ~ /^[[:space:]]*table[[:space:]]*=/ && kind == "full" { next }
        l ~ /^[[:space:]]*endpoint[[:space:]]*=/ {
            port = $0; sub(/#.*/, "", port); sub(/.*:/, "", port); gsub(/[[:space:]]/, "", port)
            print "Endpoint = " ip ":" port
            next
        }
        { print }
    ' "$1"
}

# add_keepalive: the config on stdin with a keepalive of 25s after its
# Endpoint (any other keepalive line dropped), so a stale handshake means
# trouble rather than idleness (the watchdog)
add_keepalive() {
    awk '{ l = tolower($0) } l ~ /^[[:space:]]*persistentkeepalive[[:space:]]*=/ { next } { print }
         l ~ /^[[:space:]]*endpoint[[:space:]]*=/ { print "PersistentKeepalive = 25" }'
}

# WARP for wg-quick: rendered as a full tunnel (no hooks, Table = off: the
# daemon does the routes) at its own endpoint, with a keepalive
render_warp() { render "$1" full "$(conf_val "$1" Endpoint | host_of)" | add_keepalive; }

resolve() {
    if [[ "$1" =~ ^[0-9.]+$ || "$1" == *:* ]]; then echo "$1"; return; fi
    dscacheutil -q host -a name "$1" | awk '/^ip_address:/ {print $2; exit}'
}

# _import <dir> [dry] [changes]: dry reports what an import would do and
# changes nothing; changes prints only what changed (the dry run before it
# showed the rest)
cmd_import_root() {
    local src="$1" dry="${2:-}" changes="${3:-}" f name kind host ip iface out tmp state n wep active want wanted why rows="" seen="" w same=0
    need_root import
    [ -d "$src" ] || die "No folder ${src}"
    if [ -z "$dry" ]; then
        mkdir -p "$CONF" "$STATE" && chmod 700 "$CONF" && chmod 755 "$ETC" "$STATE"
        touch "$TSV"
    fi
    # Helpers for this function alone (bash makes them global all the same)
    # A temp file next to its target (same filesystem, for mv), or anywhere when dry
    tmpfile() { if [ -n "$dry" ]; then mktemp -t wgt-import; else mktemp "$CONF/.$1.XXXXXX"; fi; }
    # new / updated / unchanged for $1 against $2; moves it into place unless dry
    settle() {
        chmod 600 "$1"
        if [ -f "$2" ] && cmp -s "$1" "$2"; then rm -f "$1"; echo unchanged; return; fi
        [ -f "$2" ] && echo updated || echo new
        if [ -n "$dry" ]; then rm -f "$1"; else mv -f "$1" "$2"; fi
    }

    [ -f "$WARP_SRC" ] || die "No ${WARP_SRC} — run install.sh"
    wep=$(conf_val "$WARP_SRC" Endpoint | host_of)
    tmp=$(tmpfile warp)
    render_warp "$WARP_SRC" > "$tmp"
    state=$(settle "$tmp" "$CONF/warp.conf")

    active=$(st name)
    # The tunnel asked for, up or not yet (a failed up, a pause): kept too, or
    # its routes would outlive its config
    read -r want wanted _ 2>/dev/null < "$STATE/desired"
    case "$want" in up|pause) ;; *) wanted="" ;; esac
    # The name column fits the longest name, new or old
    w=$( { for f in "$src"/*.conf; do basename "$f" .conf; done; cut -f1 "$TSV" 2>/dev/null; } \
        | awk '{ if (length > m) m = length } END { print (m > 28 ? m : 28) }')
    add_row() { rows+="$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\n'; }   # add_row <name> <iface> <kind> <ip>: the new TSV
    row() {  # row <name> <kind> <iface> <state>
        if [ -n "$changes" ] && [ "$4" = unchanged ]; then
            same=$((same + 1)); return
        fi
        printf "%-${w}s %-7s %-6s %s\n" "$@"
    }
    row TUNNEL KIND IFACE FILE
    row "(WARP)" - - "$state"
    for f in "$src"/*.conf; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .conf)
        # The daemon's state files are space-separated: a name is one word
        if ! [[ "$name" =~ ^[A-Za-z0-9._=+-]+$ ]]; then
            row "$name" - - "skipped: the name has a space or other character (rename the file)"
            continue
        fi
        if ! grep -qiE '^[[:space:]]*\[Interface\]' "$f" || ! grep -qiE '^[[:space:]]*\[Peer\]' "$f" \
            || [ -z "$(conf_val "$f" PrivateKey)" ] || [ -z "$(conf_val "$f" Endpoint)" ]; then
            row "$name" - - "skipped: not a WireGuard config"
            continue
        fi
        kind=$(kind_of "$name" "$f")
        if [ "$kind" = warped ] && ! why=$(swept_ok "$f" "$wep"); then
            row "$name" "$kind" - "skipped: ${why} (not as the sweep writes it: is its carrier in carriers/?)"
            continue
        fi
        host=$(conf_val "$f" Endpoint | host_of)
        ip=$(resolve "$host")
        if [ -z "$ip" ]; then
            # No DNS right now (the kill switch on, say): the copy from before stays
            read -r iface kind ip <<< "$(tsv_get "$name")"
            if [ -n "$iface" ]; then
                add_row "$name" "$iface" "$kind" "$ip"
                row "$name" "$kind" "$iface" "kept: can't resolve ${host} (the copy from before stays)"
            else
                row "$name" "$kind" - "skipped: can't resolve ${host}"
            fi
            continue
        fi
        # The daemon pins a full or warped tunnel's server to the IPv4 gateway
        if [ "$kind" != split ] && [[ "$ip" == *:* ]]; then
            row "$name" "$kind" - "skipped: IPv6 endpoint ${ip} (the daemon pins IPv4 servers only)"
            continue
        fi
        # Keep a tunnel's interface name across imports; new ones get the next free wtN
        read -r iface _ <<< "$(tsv_get "$name")"
        if [ -z "$iface" ]; then
            n=0
            while awk -F'\t' '{print $2}' "$TSV" 2>/dev/null | grep -qx "wt$n" || [[ " $seen " == *" wt$n "* ]]; do
                n=$((n + 1))
            done
            iface="wt$n"
        fi
        seen+=" $iface"

        out="$CONF/$iface.conf"
        tmp=$(tmpfile import)
        render "$f" "$kind" "$ip" > "$tmp"
        # WARP alone: a keepalive, as WARP has inside a warped tunnel. It
        # handshakes at once, and a stale handshake means trouble (the watchdog).
        # The sweep's warp.<device>.conf has one already: this is for a folder
        # imported from elsewhere.
        if same_key "$f" "$WARP_SRC" && ! has_keepalive "$tmp"; then
            add_keepalive < "$tmp" > "$tmp.ka" && mv -f "$tmp.ka" "$tmp"
        fi
        state=$(settle "$tmp" "$out")
        [ "$name" = "$active" ] && [ "$state" = updated ] && state="updated (up now: re-run tunnel.sh up)"
        add_row "$name" "$iface" "$kind" "$ip"
        row "$name" "$kind" "$iface" "$state"
    done

    # Tunnels gone from the export: removed, unless up or asked for, or kept above
    while IFS=$'\t' read -r name iface kind ip; do
        [ -n "$name" ] || continue
        printf '%s' "$rows" | awk -F'\t' -v n="$name" '$1 == n {f = 1} END {exit !f}' && continue
        if [ "$name" = "$active" ] || [ "$name" = "$wanted" ]; then
            add_row "$name" "$iface" "$kind" "$ip"
            row "$name" "$kind" "$iface" "kept: in use (tunnel.sh down, then import again)"
        else
            [ -n "$dry" ] || rm -f "$CONF/$iface.conf"
            row "$name" "$kind" "$iface" "removed"
        fi
    done < <(cat "$TSV" 2>/dev/null)

    [ "$same" -gt 0 ] && echo "(${same} more unchanged, as above)"
    if [ -n "$dry" ]; then :
    elif [ -n "$rows" ]; then put "$TSV" "$(printf '%s' "$rows" | sort -f -t$'\t' -k1,1)" 644
    else : > "$TSV"; fi
}

# --- routes (root, daemon) ---

add_routes() {  # add_routes <target args...> -- <prefixes...>
    local args=() p
    while [ "$1" != "--" ]; do args+=("$1"); shift; done
    shift
    for p in "$@"; do
        if [[ "$p" == *:* ]]; then
            route -q -n add -inet6 "$p" "${args[@]/127.0.0.1/::1}" >/dev/null 2>&1
        else
            route -q -n add -inet "$p" "${args[@]}" >/dev/null 2>&1
        fi
    done
}

del_routes() {
    local p
    for p in "$@"; do
        if [[ "$p" == *:* ]]; then route -q -n delete -inet6 "$p" >/dev/null 2>&1
        else route -q -n delete -inet "$p" >/dev/null 2>&1; fi
    done
}

warp_ep() { conf_val "$CONF/warp.conf" Endpoint | host_of; }

if_mtu() { ifconfig "$1" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "mtu") {print $(i + 1); exit}}'; }

# WARP's packets travel inside the carrier, up to 80 bytes bigger (IPv6 40 +
# UDP 8 + WireGuard 32). A carrier with a small MTU (a server set to 1280, say)
# needs WARP smaller still, or full-size packets are dropped: ping works,
# nothing else does. Uses the carrier's live MTU, so wg-quick's own choice
# (no MTU line) counts too. warp.conf itself isn't changed.
fit_warp_mtu() {  # fit_warp_mtu <carrier iface> <name>
    local cm wm
    cm=$(if_mtu "$(utun_of "$1")")
    wm=$(if_mtu "$(utun_of warp)")
    [ -n "$cm" ] && [ -n "$wm" ] && [ $((cm - 80)) -lt "$wm" ] || return 0
    ifconfig "$(utun_of warp)" mtu $((cm - 80)) \
        && log "WARP MTU $((cm - 80)), inside ${2} (MTU ${cm})"
}

# WARP alone (a tunnel on this Mac's WARP key, warp.<device>) has no carrier
# of ours, but there can be one we can't see: a travel router that tunnels
# everything, say. If that one can't fit WARP's packets, ping works and nothing
# else does. WARP's endpoint doesn't answer ping, so measure through WARP
# itself: a don't-fragment ping of the full MTU to PROBE_IP. Lost, but a
# 1200-byte one gets through: run WARP at 1200. Starts from the config's MTU
# each time, so a better network gets it back. Measured on up, on a gateway
# change, and every 5 minutes (a router may switch its exit behind the same
# gateway).
warp_alone() { same_key "$CONF/$1.conf" "$CONF/warp.conf"; }
probe() { ping -c2 -i0.2 -t3 -D -s $(( $1 - 28 )) "$PROBE_IP" >/dev/null 2>&1; }
fit_path_mtu() {  # fit_path_mtu <iface> <name>
    local u full prev
    u=$(utun_of "$1") || return 0
    full=$(conf_val "$CONF/$1.conf" MTU); full="${full:-1280}"
    prev=$(if_mtu "$u")
    [ "$prev" = "$full" ] || ifconfig "$u" mtu "$full"
    probe "$full" && { [ "$prev" = "$full" ] || log "${2}: MTU ${full} fits this network again"; return 0; }
    # A few tries: after a network change WARP may still be re-handshaking
    if [ "$full" -gt 1200 ] && ifconfig "$u" mtu 1200 && wait_until 3 probe 1200; then
        [ "$prev" = 1200 ] || log "${2}: ${full}-byte packets don't get through this network (a tunnel on the router?): MTU 1200"
    else
        # No answer at all (ICMP blocked, or the network is still settling): as it was
        ifconfig "$u" mtu "${prev:-$full}"
        [ -n "$SUPERSEDED" ] || log "${2}: no ping answer through it, MTU left at ${prev:-$full}"   # not cut short
    fi
}

# /31 around the WARP endpoint (more specific than the /2s, less than the carrier's /32)
warp_guard() {
    local ep a b c d
    ep=$(warp_ep)
    IFS=. read -r a b c d <<< "$ep"
    [ -n "$d" ] && echo "$a.$b.$c.$(( d & 254 ))/31"
}

# The kill switch. $RUN/armed holds the WARP guard it added, so a new WARP
# endpoint (rotate-warp, a new .warp-endpoint) moves the guard, and disarm
# takes off the one that's there (as pin/unpin do with $RUN/pin).
arm() {
    local g was
    g=$(warp_guard)
    if [ -f "$RUN/armed" ]; then
        was=$(cat "$RUN/armed")
        [ "$was" = "$g" ] && return
        log "kill switch: WARP guard ${was:-none} -> ${g:-none}"
        # The new guard first: the endpoint is never unguarded
        [ -n "$g" ] && add_routes 127.0.0.1 -reject -- "$g"
        [ -n "$was" ] && del_routes "$was"
    else
        log "kill switch on"
        add_routes 127.0.0.1 -reject -- $V4_HALVES $V6_HALVES
        [ -n "$g" ] && add_routes 127.0.0.1 -reject -- "$g"
    fi
    put "$RUN/armed" "$g"
}

disarm() {
    local g
    [ -f "$RUN/armed" ] || return
    log "kill switch off"
    del_routes $V4_HALVES $V6_HALVES
    # One armed before the guard was recorded holds nothing: today's guard
    g=$(cat "$RUN/armed"); [ -n "$g" ] || g=$(warp_guard)
    [ -n "$g" ] && del_routes "$g"
    rm -f "$RUN/armed"
}

pin() {  # pin <ip> — host route out the physical gateway
    local gw; gw=$(gateway)
    [ -n "$gw" ] || return 1
    route -q -n delete -host "$1" >/dev/null 2>&1
    route -q -n add -host "$1" "$gw" >/dev/null 2>&1 || return 1
    put "$RUN/pin" "$1 $gw"
}

unpin() {
    local ip gw
    read -r ip gw 2>/dev/null < "$RUN/pin"
    [ -n "$ip" ] && route -q -n delete -host "$ip" >/dev/null 2>&1
    rm -f "$RUN/pin"
}

# wgq up|down <iface> — wg-quick on our copy, output to the log. A file, not a
# pipe: wg-quick leaves its route monitor and wireguard-go holding the pipe open.
wgq() {
    local out rc
    # Before up and after down nothing live is <iface>: any monitor left is stale
    [ "$1" = up ] && reap_monitors "$2"
    out=$(mktemp "$RUN/.wgq.XXXXXX")
    wg-quick "$1" "$CONF/$2.conf" > "$out" 2>&1
    rc=$?
    wgq_filter "$2" < "$out"
    rm -f "$out"
    [ "$1" = down ] && reap_monitors "$2"
    return "$rc"
}

# wgq_filter <iface>: wg-quick's output for the log, its networksetup chatter
# dropped. wg quotes a key it rejects: never let one reach the log.
wgq_filter() { grep -v 'networksetup -' | sed -E "s/[A-Za-z0-9+/]{42,43}=?/<key>/g; s/^/  [$1] /"; }

# wg-quick leaves a route monitor behind each up; it quits on a route change
# once its utun is gone. A quick restart reuses the utun name, so it never sees
# it gone and lingers. SIGKILL, parent first: its exit trap (also run when its
# route -n monitor child dies) deletes every route through that utun name,
# which by then can be the live tunnel's.
reap_monitors() {  # reap_monitors <iface>
    local pid kids n=0
    for pid in $(pgrep -f "wg-quick up $CONF/$1\\.conf\$"); do
        kids=$(pgrep -P "$pid")
        kill -9 "$pid" 2>/dev/null && n=$((n + 1))
        [ -n "$kids" ] && kill -9 $kids 2>/dev/null
    done
    [ "$n" -eq 0 ] || log "removed ${n} stale wg-quick monitor(s) for ${1}"
}

# --- daemon ---

progress() {  # a line for the waiting `tunnel.sh up/down`, and the log
    log "$*"
    echo "$*" >> "$RUN/progress"
    write_status
}

# Every wg-quick interface of ours that's up: WARP first
teardown() {
    local i
    for i in warp $(awk -F'\t' '{print $2}' "$TSV" 2>/dev/null); do
        [ -n "$(utun_of "$i")" ] || continue
        progress "stopping ${i}"
        if [ -f "$CONF/$i.conf" ]; then
            wgq down "$i"
        else
            # Not one of our copies: down through wg-quick's own config
            wg-quick down "$i" 2>&1 | wgq_filter "$i"
        fi
    done
    unpin
    rm -f "$RUN/current"
}

# During an apply it gives up as soon as a new request comes in (a down while
# an up waits for its handshake), so the daemon can take that one at once.
wait_until() {  # wait_until <secs> <cmd...>
    local n="$1" i=0
    shift
    until "$@"; do
        [ "$i" -ge "$n" ] && return 1
        sleep 1; i=$((i + 1))
        write_status   # an apply can take a minute: the menu must not think the daemon died
        if [ -n "$APPLY_REQ" ] && [ "$(cat "$RUN/request" 2>/dev/null)" != "$APPLY_REQ" ]; then
            SUPERSEDED=1; return 1
        fi
    done
}

# A step of an up failed: say why, unless a newer request cut it short
failed() {
    if [ -n "$SUPERSEDED" ]; then progress "stopped: a newer request came in"; else progress "fail: $*"; fi
    return 1
}

# Bytes through a wg-quick interface, for a failed handshake: nothing received
# means the other end never answered (blocked on the way, or not listening)
traffic_of() {
    wg show "$(utun_of "$1")" transfer 2>/dev/null \
        | awk '{rx += $2; tx += $3} END {printf "sent %d bytes, received %d", tx, rx}'
}

has_hs() { [ -n "$(hs_age "$1")" ]; }
routes_via() { [ "$(route_if "$1")" = "$(utun_of "$2")" ]; }

# Give an exit interface the four /2s (and IPv6, if it has an IPv6 address)
take_traffic() {
    local u; u=$(utun_of "$1")
    add_routes -interface "$u" -- $V4_QUARTERS
    if list_of "$CONF/$1.conf" Address | grep -q ':'; then     # every line: wgcf writes one per family
        add_routes -interface "$u" -- $V6_QUARTERS
    fi
}

apply_up() {
    local name="$1" iface kind ip exit_if
    read -r iface kind ip <<< "$(tsv_get "$name")"
    [ -n "$iface" ] && [ -f "$CONF/$iface.conf" ] || { failed "no tunnel '${name}' (tunnel.sh import?)"; return 1; }

    if [ "$kind" = split ]; then
        teardown; disarm
    else
        arm; teardown
        progress "pinning ${ip} to the gateway"
        wait_until "$WAIT_SECS" pin "$ip" || { failed "no default gateway to pin ${ip} to"; return 1; }
    fi

    progress "starting ${name} (${iface})"
    wgq up "$iface" || { failed "wg-quick up ${iface}"; return 1; }
    exit_if="$iface"

    if [ "$kind" = warped ]; then
        wait_until 5 routes_via "$(warp_ep)" "$iface" \
            || { failed "WARP endpoint doesn't route into ${iface}"; return 1; }
        progress "starting WARP inside ${name}"
        wgq up warp || { failed "wg-quick up warp"; return 1; }
        fit_warp_mtu "$iface" "$name"
        exit_if=warp
    fi
    [ "$kind" = split ] || take_traffic "$exit_if"

    if [ "$kind" = split ] && ! has_keepalive "$CONF/$exit_if.conf"; then
        progress "no keepalive: not waiting for a handshake (an idle split tunnel has none)"
    else
        progress "waiting for a ${exit_if} handshake"
        wait_until "$WAIT_SECS" has_hs "$exit_if" \
            || { failed "no ${exit_if} handshake in ${WAIT_SECS}s ($(traffic_of "$exit_if"))"; return 1; }
    fi
    if [ "$kind" = full ] && warp_alone "$iface"; then
        progress "measuring what fits through ${name}"
        fit_path_mtu "$iface" "$name"
    fi

    put "$RUN/current" "$name $iface $kind $exit_if"
    if [ "$kind" = warped ]; then put "$STATE/last-warped" "$name"; else put "$STATE/last-other" "$name"; fi
    progress "up: ${name}"
}

apply_down() {
    teardown
    disarm
    progress "down"
}

apply() {  # apply <request-id> — the desired state; progress ends with ok/fail
    local want name until
    APPLY_REQ=$(cat "$RUN/request" 2>/dev/null)   # first: a newer request after this cuts it short
    read -r want name until 2>/dev/null < "$STATE/desired"
    put "$RUN/progress" "req $1"
    STALE=0 SUPERSEDED=""
    if [ "$want" = up ]; then
        CONNECTING=1
        if apply_up "$name"; then echo ok >> "$RUN/progress"; else echo fail >> "$RUN/progress"; fi
        CONNECTING=""
    elif [ "$want" = pause ]; then
        apply_down
        progress "paused: ${name} comes back at $(date -r "${until:-0}" +%H:%M)"
        echo ok >> "$RUN/progress"
    else
        apply_down; echo ok >> "$RUN/progress"
    fi
    APPLY_REQ=""
}

# A pause whose time is up: back to the tunnel it paused
resume_if_due() {
    local want name until
    read -r want name until 2>/dev/null < "$STATE/desired"
    [ "$want" = pause ] && [ "$(date +%s)" -ge "${until:-0}" ] || return 0
    log "pause over: resuming ${name}"
    put "$STATE/desired" "up ${name}"
    put "$RUN/request" "resume.$(date +%s)"
}

# Every $WATCH_SECS while up
watchdog() {
    local want name iface kind exit_if ip pgw gw cur
    read -r want _ 2>/dev/null < "$STATE/desired"
    [ "$want" = up ] || return
    if ! read -r name iface kind exit_if 2>/dev/null < "$RUN/current"; then
        log "watchdog: not up as asked — retrying"; apply watchdog; return
    fi
    if [ -z "$(utun_of "$iface")" ] || [ -z "$(utun_of "$exit_if")" ]; then
        log "watchdog: ${name} interface gone — restarting"; apply watchdog; return
    fi
    if [ "$kind" != split ]; then
        read -r ip pgw 2>/dev/null < "$RUN/pin"
        [ -n "$ip" ] || read -r _ _ ip <<< "$(tsv_get "$name")"
        gw=$(gateway)
        cur=$(route_gw "$ip")
        if [ -n "$gw" ] && [ "$gw" != "$pgw" ]; then
            log "watchdog: gateway ${pgw:-none} -> ${gw}, re-pinning ${ip}"
            pin "$ip"
            # A new network: what fits WARP alone may differ
            [ "$kind" = full ] && warp_alone "$iface" && { MTU_TICK=0; fit_path_mtu "$iface" "$name"; }
        elif [ -n "$gw" ] && [ "$cur" != "$gw" ]; then
            # macOS drops routes through an interface that goes down: rejoining
            # the same network leaves the gateway as it was, and the pin gone
            log "watchdog: route to ${ip} gone (network came back), re-pinning"
            pin "$ip"
        fi
    fi
    # WARP alone, again every MTU_EVERY watchdog runs: a router can switch its
    # own exit (and that tunnel's MTU) behind the same gateway
    if [ "$kind" = full ] && warp_alone "$iface"; then
        MTU_TICK=$((MTU_TICK + 1))
        [ "$MTU_TICK" -ge "$MTU_EVERY" ] && { MTU_TICK=0; fit_path_mtu "$iface" "$name"; }
    fi
    # The exit's handshake: WARP, or the tunnel itself
    if exit_stale "$exit_if"; then
        STALE=$((STALE + 1))
        if [ "$STALE" -eq 2 ]; then
            log "watchdog: ${exit_if} silent ${AGE:-?}s — new source port"
            wg set "$(utun_of "$exit_if")" listen-port 0
        elif [ "$STALE" -ge 4 ]; then
            log "watchdog: ${exit_if} still silent — restarting"; apply watchdog; return
        fi
    else
        STALE=0
    fi
}

# exit_stale <iface>: an exit with a keepalive that hasn't handshaken in
# STALE_SECS (AGE: seconds since its last, empty for never). One without a
# keepalive never is: an idle tunnel has no handshakes either.
exit_stale() {
    has_keepalive "$CONF/$1.conf" || return 1
    AGE=$(hs_age "$1")
    [ -z "$AGE" ] || [ "$AGE" -gt "$STALE_SECS" ]
}

# Between watchdog runs: has the network changed (gateway appeared or moved,
# or the pinned route went missing)? Then the watchdog runs now, not in 30s.
net_changed() {
    local gw ip cur
    gw=$(gateway)
    if [ "$gw" != "$NET_GW" ]; then
        NET_GW="$gw"
        [ -n "$gw" ] && return 0
    fi
    [ -n "$gw" ] || return 1
    read -r ip _ 2>/dev/null < "$RUN/pin" || return 1
    cur=$(route_gw "$ip")
    [ "$cur" != "$gw" ]
}

# state, a line whose first word is what the menu shows (only what the daemon has seen):
#   up <name>            the exit has a recent handshake
#   reconnecting <name>  up, but the exit has been silent over STALE_SECS
#   connecting <name>    applying an up (also a watchdog restart)
#   blocked <name>       wanted up, not up, kill switch on: nothing leaves
#   failed <name>        wanted up, not up, no kill switch (a split tunnel)
#   paused <name> <t>    pause: down, kill switch off, back at epoch t
#   down
write_status() {
    local name iface kind exit_if out want wname until state
    [ -n "$DAEMON" ] || return 0     # breakglass and install wait too, but aren't the daemon
    read -r want wname until 2>/dev/null < "$STATE/desired"
    out="armed $([ -f "$RUN/armed" ] && echo yes || echo no)"
    out+=$'\n'"desired ${want:-down}${wname:+ $wname}${until:+ $until}"
    if [ "$want" = pause ]; then
        state="paused ${wname} ${until}"
    elif [ -n "$CONNECTING" ]; then
        state="connecting ${wname}"
    elif [ "$want" = up ]; then
        [ -f "$RUN/armed" ] && state="blocked ${wname}" || state="failed ${wname}"
    else
        state="down"
    fi
    if read -r name iface kind exit_if 2>/dev/null < "$RUN/current"; then
        out+=$'\n'"name ${name}"$'\n'"kind ${kind}"
        out+=$'\n'"iface ${iface} $(utun_of "$iface") $(hs_age "$iface")"
        [ "$exit_if" = warp ] && out+=$'\n'"warp warp $(utun_of warp) $(hs_age warp)"
        # Only an up decides by what's running: mid-teardown is still down/paused
        if [ "$want" = up ] && [ -z "$CONNECTING" ]; then
            state="up ${name}"
            exit_stale "$exit_if" && state="reconnecting ${name}"   # as the watchdog judges it
        fi
    fi
    out+=$'\n'"state ${state}"
    [ -f "$RUN/pin" ] && out+=$'\n'"pin $(cat "$RUN/pin")"
    out+=$'\n'"updated $(date +%s)"
    put "$RUN/status" "$out"
}

cmd_daemon() {
    local req applied="" tick=0 g
    need_root daemon
    DAEMON=1 NET_GW=$(gateway)
    mkdir -p "$RUN" "$STATE" && chmod 755 "$RUN" "$STATE"
    # A request id from the start (a reboot empties $RUN): the boot apply, and
    # the watchdog's retries, can be cut short by a newer request like any other
    [ -s "$RUN/request" ] || put "$RUN/request" boot
    # The kill switch survives a restart (its routes do) but not a reboot:
    # trust the routes, not the file, or a down after a restart mid-apply
    # would leave traffic blocked. Off: take off the WARP guard recorded too.
    if netstat -rn -f inet | awk '$1 == "0/1" && $4 == "lo0" {f = 1} END {exit !f}'; then
        [ -f "$RUN/armed" ] || put "$RUN/armed" ""
    else
        g=$(cat "$RUN/armed" 2>/dev/null); [ -n "$g" ] && del_routes "$g"
        rm -f "$RUN/armed"
    fi
    # A restart re-applies what's wanted; temp files of an interrupted run go
    rm -f "$RUN/current" "$RUN"/.wgq.* "$CONF"/.import.* "$CONF"/.warp.*
    log "daemon start"
    while true; do
        resume_if_due
        req=$(cat "$RUN/request" 2>/dev/null)
        req="${req:-boot}"
        if [ "$req" != "$applied" ]; then
            applied="$req"
            log "applying: $(cat "$STATE/desired" 2>/dev/null || echo down) (${applied})"
            apply "$applied"
            tick=0
        elif [ "$tick" -ge "$WATCH_SECS" ] \
            || { [ $((tick % NET_SECS)) -eq 0 ] && net_changed; }; then
            watchdog
            tick=0
        fi
        write_status
        sleep 1
        tick=$((tick + 1))
    done
}

# root side of up/down/pause: record what's wanted and wake the daemon
cmd_request() {
    local want name
    need_root request
    case "$1" in
        up)
            [ -n "$(tsv_get "$2")" ] || die "No tunnel '$2'"
            put "$STATE/desired" "up $2"
            ;;
        pause)
            read -r want name _ 2>/dev/null < "$STATE/desired"
            case "$want" in up|pause) ;; *) die "Nothing to pause: no tunnel is wanted" ;; esac
            valid_minutes "$2" || die "pause: minutes from 1 to 1440"
            put "$STATE/desired" "pause ${name} $(( $(date +%s) + $2 * 60 ))"
            ;;
        *)
            put "$STATE/desired" "down"
            ;;
    esac
    put "$RUN/request" "$(date +%s).$$"
}

valid_minutes() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 1440 ]; }

# --- install (root) ---

cmd_install_root() {
    local src="$1"
    need_root install
    [ -d /usr/local/sbin ] || install -d -m 755 /usr/local/sbin   # Homebrew may own it: leave it be
    install -d -m 755 -o root -g wheel "$ETC" "$STATE"
    install -d -m 700 -o root -g wheel "$CONF"
    install -m 755 -o root -g wheel "$src" "$INSTALLED"
    [ -f "$STATE/desired" ] || put "$STATE/desired" "down"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array><string>${INSTALLED}</string><string>daemon</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <!-- wg-quick leaves its route monitor and wireguard-go running; a daemon
         restart must not kill the tunnels -->
    <key>AbandonProcessGroup</key><true/>
    <key>StandardOutPath</key><string>${LOG}</string>
    <key>StandardErrorPath</key><string>${LOG}</string>
</dict>
</plist>
EOF
    chown root:wheel "$PLIST"; chmod 644 "$PLIST"
    restart_daemon || die "launchctl bootstrap failed — try: sudo launchctl bootstrap system ${PLIST}"
    echo "Installed ${INSTALLED} and ${PLIST}; daemon log: ${LOG}"
}

# --- breakglass (root) ---

# DNS values from every tunnel config (wg-quick sets these on every network
# service and only puts the old ones back on a clean `down`)
# $1: the user's $WG_TUNNELS (sudo drops the environment), else ~user/wg-tunnels
tunnel_dns() {
    local f store
    store="${1:-$(eval echo "~${SUDO_USER:-root}")/wg-tunnels}"
    for f in "$WARP_SRC" "$CONF"/*.conf "$store"/devices/*/{warp,config,carriers}/*.conf; do
        [ -f "$f" ] || continue
        list_of "$f" DNS
    done | sort -u
}

# Back to the plain connection without trusting any state: no daemon state,
# no wg-quick, none of our routes, no leftover tunnel DNS. Tunnels in the
# WireGuard app are stopped by the user side before this.
cmd_breakglass_root() {
    local f ip svc dns known dev routes
    need_root breakglass
    echo "== daemon"
    [ -d "$STATE" ] && put "$STATE/desired" "down" \
        && echo "  wanted: down (a reboot won't bring a tunnel back)"
    stop_daemon && echo "  stopped ${LABEL}"

    echo "== wg-quick"
    # Route monitors first: they put routes and DNS back on every network change
    pkill -f 'bin/wg-quick' && echo "  killed wg-quick monitors"
    pkill -x wireguard-go && echo "  killed wireguard-go"
    for f in "$WG_RUN"/*.name "$WG_RUN"/*.sock; do
        [ -e "$f" ] && rm -f "$f" && echo "  removed ${f}"
    done

    echo "== routes"
    del_routes $V4_HALVES $V6_HALVES $V4_QUARTERS $V6_QUARTERS
    for f in "$(warp_guard 2>/dev/null)" "$(cat "$RUN/armed" 2>/dev/null)"; do [ -n "$f" ] && del_routes "$f"; done
    # Server pins: the recorded one, every imported endpoint, WARP's
    read -r ip _ 2>/dev/null < "$RUN/pin"
    for ip in $ip $(awk -F'\t' '{print $4}' "$TSV" 2>/dev/null) $(warp_ep 2>/dev/null) \
              $(conf_val "$WARP_SRC" Endpoint 2>/dev/null | host_of); do
        route -q -n delete -host "$ip" >/dev/null 2>&1 && echo "  removed host route ${ip}"
    done
    # Anything still rejecting traffic into lo0 (a kill switch from any version)
    routes=$(netstat -rn | awk '$4 == "lo0" && $3 ~ /[RB]/ {print $1}')
    for f in $routes; do
        del_routes "$f"; echo "  removed reject route ${f}"
    done

    echo "== dns"
    known=$(tunnel_dns "$1")
    while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        dns=$(networksetup -getdnsservers "$svc" 2>/dev/null | grep -E '^[0-9a-fA-F.:]+$')
        [ -n "$dns" ] || continue
        if [ -z "$(comm -23 <(echo "$dns" | sort -u) <(echo "$known"))" ]; then
            networksetup -setdnsservers "$svc" Empty
            echo "  ${svc}: $(echo "$dns" | paste -sd' ' -) (a tunnel's) -> from DHCP"
        else
            echo "  ${svc}: $(echo "$dns" | paste -sd' ' -) left alone (not a tunnel's)"
        fi
    done < <(networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//')
    dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null

    rm -f "$RUN/armed" "$RUN/current" "$RUN/pin" "$RUN/status" "$RUN/progress" "$RUN/request"

    echo "== wi-fi"
    dev=$(networksetup -listallhardwareports | awk '/^Hardware Port: Wi-Fi/ {getline; print $2; exit}')
    if [ -n "$dev" ] && networksetup -getairportpower "$dev" | grep -q On \
        && [ -z "$(ipconfig getifaddr "$dev")" ]; then
        echo "  ${dev} has no address — power cycling"
        networksetup -setairportpower "$dev" off; sleep 2
        networksetup -setairportpower "$dev" on
        wait_until 20 ipconfig getifaddr "$dev" >/dev/null
    fi
    [ -n "$dev" ] && echo "  ${dev}: $(ipconfig getifaddr "$dev" || echo 'no address')"

    if [ -f "$PLIST" ]; then
        echo "== daemon"
        restart_daemon && echo "  restarted ${LABEL}, wanted: down"
    fi

    echo "== check"
    echo "  default: $(gateway) via $(route_if 1.1.1.1)"
    ping -c1 -t3 1.1.1.1 >/dev/null 2>&1 && echo "  1.1.1.1: reachable" || echo "  1.1.1.1: NOT reachable"
    ping -c1 -t3 apple.com >/dev/null 2>&1 && echo "  apple.com: reachable (DNS ok)" || echo "  apple.com: NOT reachable"
}

loaded() { launchctl print system/"$LABEL" >/dev/null 2>&1; }
# stop_daemon: bootout, then wait until it's gone (bootout returns first, and
# until then the daemon can still add routes)
stop_daemon() { launchctl bootout system/"$LABEL" 2>/dev/null || return 1; wait_until 10 eval '! loaded'; }

# bootout returns before the job is gone; bootstrap too soon fails with
# "5: Input/output error"
restart_daemon() {
    local i
    stop_daemon
    for i in 1 2 3 4 5; do
        launchctl bootstrap system "$PLIST" 2>/dev/null && return 0
        loaded && return 0
        sleep 1
    done
    return 1
}

cmd_uninstall_root() {
    need_root uninstall
    put "$STATE/desired" "down" && put "$RUN/request" "uninstall.$$"
    sleep 3
    stop_daemon
    teardown; disarm
    rm -f "$PLIST" "$INSTALLED" "$RUN/status" "$RUN/progress" "$RUN/request"
    echo "Removed ${INSTALLED} and ${PLIST}; configs kept in ${ETC}"
}

# --- user side ---

NOT_INSTALLED="Not installed — run install.sh (or tunnel.sh install for just the daemon)"
# install_stale: run from the repo, and the installed daemon isn't this copy
install_stale() { [ "$0" != "$INSTALLED" ] && ! cmp -s "$0" "$INSTALLED"; }

root() {
    [ -x "$INSTALLED" ] || die "$NOT_INSTALLED"
    # The installed copy is older: update it first (this restarts the daemon,
    # which re-applies what's wanted)
    if install_stale; then
        echo "Updating ${INSTALLED} from $0"
        sudo "$0" _install "$0" >/dev/null || die "Update failed — run: tunnel.sh install"
    fi
    sudo "$INSTALLED" "$@"
}

# Before up: installed, and something imported
ready() {
    local dev
    dev="${TUNNELS}/$(cat "$DEFAULT_FILE" 2>/dev/null | grep . || echo "<this Mac's name>")"
    [ -x "$INSTALLED" ] || die "Not installed. First time:
  install.sh (in this repo)
  put .conf files in ${dev}/config (or WireGuard app → Export Tunnels to Zip… into ${dev}/exports, then tunnel.sh extract)
  tunnel.sh import"
    [ -s "$TSV" ] || die "No tunnels imported: tunnel.sh import (configs in ${dev}/config), or tunnel.sh extract-import (from an export zip)"
}

check_installed() {
    if [ -x "$INSTALLED" ] && install_stale; then
        echo "Note: ${INSTALLED} differs from $0 — tunnel.sh update (or any command that asks the daemon) updates it" >&2
    fi
}

NAMES=()
load_tunnels() {  # load_tunnels warped|other
    local name iface kind ip
    NAMES=()
    [ -f "$TSV" ] || return 0
    while IFS=$'\t' read -r name iface kind ip; do
        [ -n "$name" ] || continue
        if { [ "$1" = warped ] && [ "$kind" = warped ]; } || { [ "$1" = other ] && [ "$kind" != warped ]; }; then
            NAMES+=("$name")
        fi
    done < "$TSV"
}

st() { awk -v k="$1" '$1 == k {$1 = ""; sub(/^ /, ""); print; exit}' "$RUN/status" 2>/dev/null; }

list() {
    local i cur mark kind
    cur=$(st name)
    if [ ${#NAMES[@]} -eq 0 ]; then
        [ "$1" = warped ] && echo "  none named ${TUNNEL_PREFIX}* (tunnel.sh import)" || echo "  none"
        return 1
    fi
    for i in "${!NAMES[@]}"; do
        [ "${NAMES[$i]}" = "$cur" ] && mark="up" || mark=""
        kind=$(tsv_get "${NAMES[$i]}" | awk '{print $2}')
        [ "$kind" = split ] && kind="split" || kind=""
        printf '%3d) %-32s %-5s %s\n' $((i + 1)) "${NAMES[$i]}" "$kind" "$mark"
    done
}

default_choice() {
    local last i
    last=$(cat "$STATE/last-$1" 2>/dev/null)
    for i in "${!NAMES[@]}"; do
        [ "${NAMES[$i]}" = "$last" ] && { echo $((i + 1)); return; }
    done
    [ ${#NAMES[@]} -eq 1 ] && echo 1
}

pick() {  # pick <choice> <warped|other>
    local choice="$1" kind="$2" def prompt i
    load_tunnels "$kind"
    if [ -z "$choice" ]; then
        list "$kind" >&2 || return 1
        def=$(default_choice "$kind")
        prompt="Select [1-${#NAMES[@]}]"
        [ -n "$def" ] && prompt+=" (Enter = ${def}, ${NAMES[$((def - 1))]})"
        read -rp "${prompt}: " choice
        choice="${choice:-$def}"
        [ -z "$choice" ] && { echo "Nothing selected" >&2; return 1; }
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#NAMES[@]} ]; then
        echo "${NAMES[$((choice - 1))]}"; return
    fi
    for i in "${NAMES[@]}"; do [ "$i" = "$choice" ] && { echo "$i"; return; }; done
    echo "No ${kind} tunnel '${choice}'" >&2
    return 1
}

# Tunnels running in the WireGuard app (they'd fight the routes)
app_connected() {
    scutil --nc list | sed -nE \
        's/.*\((Connected|Connecting|Reasserting)\)[[:space:]]+[0-9A-F-]{36} VPN \(com\.wireguard\.macos\) "([^"]+)".*/\2/p'
}

# App tunnels with On Demand on: they reconnect behind `tunnel.sh up`, and the same
# key on two interfaces leaves only one of them answered by the server
app_on_demand() {
    local name
    while read -r name; do
        scutil --nc show "$name" 2>/dev/null | grep -q 'OnDemandEnabled : TRUE' && echo "$name"
    done < <(scutil --nc list | sed -nE 's/.*VPN \(com\.wireguard\.macos\) "([^"]+)".*/\1/p')
}

stop_app_tunnels() {
    local name i
    while read -r name; do
        [ -n "$name" ] || continue
        echo "Stopping ${name} in the WireGuard app..."
        scutil --nc stop "$name"
        for i in $(seq 1 10); do
            [ "$(scutil --nc status "$name" | head -1)" = Disconnected ] && break
            sleep 1
        done
    done < <(app_connected)
}

# ask <request...>: hand the daemon a request (as root), then follow it to the end
ask() { root request "$@" || return 1; follow "$(cat "$RUN/request")"; }

# Follow the daemon's progress on our request (its first line is "req <id>")
# until ok/fail
follow() {
    local req="$1" seen=1 n line i=0
    printf 'Waiting for the daemon '
    until [ "$(head -1 "$RUN/progress" 2>/dev/null)" = "req $req" ]; do
        # 30s: a watchdog MTU check on a network that drops pings takes about 18
        [ "$i" -ge 30 ] && { echo " no answer — is it running? (tunnel.sh log)" >&2; return 1; }
        printf '.'; sleep 1; i=$((i + 1))
    done
    echo
    i=0
    while [ "$i" -lt 120 ]; do
        [ "$(head -1 "$RUN/progress" 2>/dev/null)" = "req $req" ] || { echo "  (superseded by another request)"; return 1; }
        n=$(wc -l < "$RUN/progress")
        [ "$n" -lt "$seen" ] && seen=1     # a restarted daemon applying it again: from the top
        if [ "$n" -gt "$seen" ]; then
            while IFS= read -r line; do
                case "$line" in
                    # The full status (it looks up the exit IP, slow while
                    # the kill switch blocks) only for a person at a terminal
                    ok) echo; [ -t 1 ] && status; return 0 ;;
                    fail) echo; [ -t 1 ] && status; return 1 ;;
                    *) echo "  $line" ;;
                esac
            done < <(sed -n "$((seen + 1)),${n}p" "$RUN/progress")
            seen=$n
        fi
        sleep 1; i=$((i + 1))
    done
    echo "  no result after 120s — tunnel.sh log" >&2
    return 1
}

current() {
    local apps
    apps=$(app_connected | joined)
    echo "Current connection:"
    echo "  tunnel: $(st name | grep . || echo none)"
    [ -n "$apps" ] && echo "  WireGuard app: ${apps}"
    echo "  $(exit_line)"
}

cmd_up() {
    local answer kind tunnel od
    ready
    od=$(app_on_demand | joined)
    [ -z "$od" ] || die "On Demand is on in the WireGuard app for: ${od}
It reconnects behind the tunnel and breaks it. Turn it off (the tunnel → Edit → uncheck On-Demand), then tunnel.sh up."
    check_installed
    [ -t 1 ] && { current; echo; echo; }
    if [ -n "$1" ] && ! [[ "$1" =~ ^[0-9]+$ ]]; then
        tunnel="$1"
        [ -n "$(tsv_get "$tunnel")" ] || die "No tunnel '${tunnel}' (tunnel.sh list)"
    else
        [ -n "$1" ] || [ -t 0 ] || die "Which tunnel? (no terminal to ask in: tunnel.sh up <name>)"
        if [ -n "$1" ]; then answer=y; else read -rp "warped [Y/n]: " answer; fi
        [[ "$answer" =~ ^[Nn] ]] && kind=other || kind=warped
        tunnel=$(pick "$1" "$kind") || return 1
    fi
    stop_app_tunnels
    ask up "$tunnel"
}

# rotate-warp: a new WARP account in this Mac's warp/. The old one waits in
# warp.old until the new one is imported, and comes back if registering fails.
cmd_rotate_warp() {
    local warp old inst active kind
    [ "$(id -u)" -ne 0 ] || die "rotate-warp: run it as your user, not root"
    warp="$(mac_dir)/warp" || exit 1
    inst="$(cd "$(dirname "$0")/.." && pwd)/install.sh"
    [ -x "$inst" ] || die "rotate-warp: no install.sh next to $0 (run the repo's scripts/tunnel.sh)"
    old="$warp.old"
    [ -e "$old" ] && die "rotate-warp: ${old} is left from an earlier rotate. If WARP works, delete it; if not, put it back as ${warp}"
    check_installed

    echo "== New WARP account"
    mv "$warp" "$old" || die "rotate-warp: can't move ${warp} aside"
    if ! "$inst" --no-daemon; then
        rm -rf "$warp" && mv "$old" "$warp"
        die "rotate-warp: install.sh failed; the old account is back in ${warp}"
    fi

    echo "== Import"
    # A subshell: import's own errors exit it, not this, so the hint below shows
    ( cmd_import -y ) || die "rotate-warp: import failed. The new account is in place: run tunnel.sh import, then delete ${old}"
    rm -rf "$old"
    echo "Old WARP account's files removed (Cloudflare isn't told)"

    # A warped tunnel, or WARP alone (warp.<device>), that's up still runs the
    # old keys: reconnect it
    active=$(st name)
    kind=$(st kind)
    if [ -n "$active" ] && { [ "$kind" = warped ] \
        || [ "$(lower "$active")" = "$(lower "warp.$(basename "$(mac_dir)")")" ]; }; then
        echo "== Reconnect ${active}"
        ask up "$active"
    fi
}

# update: make the installed daemon this copy, only when it differs or its
# LaunchDaemon is missing. Installing restarts the daemon: a tunnel that's up
# drops for a few seconds, then comes back.
cmd_update() {
    [ "$0" != "$INSTALLED" ] || die "update: run the repo's scripts/tunnel.sh, not ${INSTALLED}"
    if [ -x "$INSTALLED" ] && cmp -s "$0" "$INSTALLED" && [ -f "$PLIST" ]; then
        echo "Daemon up to date: ${INSTALLED}"
        return 0
    fi
    echo "Updating ${INSTALLED} from $0 (restarts the daemon: a tunnel that's up drops for a few seconds)"
    sudo "$0" _install "$0"
}

# pause [min]: down with the kill switch off for min minutes (a sign-in page),
# then the daemon brings the tunnel back. Again while paused: a new end time.
cmd_pause() {
    local m="${1:-10}"
    valid_minutes "$m" || die "Usage: tunnel.sh pause [minutes, 1-1440] (default 10)"
    check_installed
    [ -x "$INSTALLED" ] || die "Not installed: nothing to pause"
    ask pause "$m"
}

cmd_resume() {
    local want name
    read -r want name _ 2>/dev/null < "$STATE/desired"
    [ "$want" = pause ] || die "Not paused (wanted: ${want:-down})"
    check_installed
    ask up "$name"
}

# diag [file]: everything needed to debug, in one file, keys removed. Runs the
# repo's copy as root (works when the daemon is broken); the file is yours.
cmd_diag() {
    local out="${1:-$WG_TUNNELS/diag/diag-$(date +%Y%m%d-%H%M%S).txt}"
    mkdir -p "$(dirname "$out")" || die "diag: can't make $(dirname "$out")"
    sudo "$0" _diag > "$out" || { rm -f "$out"; die "diag: failed"; }
    echo "$out"
}

# Private and preshared keys out of configs, wg output and the log
redact() {
    sed -E 's/^([[:space:]]*([Pp][Rr][Ii][Vv][Aa][Tt][Ee]|[Pp][Rr][Ee][Ss][Hh][Aa][Rr][Ee][Dd])[Kk][Ee][Yy][[:space:]]*=).*/\1 <removed>/
            s/((private|preshared) key:).*/\1 <removed>/'
}

cmd_diag_root() {
    local f
    need_root diag
    sec() { printf '\n== %s\n' "$*"; }
    echo "wg-tunnels diagnostics, $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "Private and preshared keys are removed. Server IPs, networks and the log"
    echo "are not: read it before you share it."
    sec system
    sw_vers; uname -m
    sec versions
    shasum -a 256 "$0" "$INSTALLED" 2>&1 | sed -E 's/^([0-9a-f]{12})[0-9a-f]+/\1/'
    wg --version 2>&1
    launchctl print system/"$LABEL" 2>&1 | grep -E '^[[:space:]]*(state|pid|last exit code|runs) ' || echo "daemon not loaded"
    sec status
    cat "$RUN/status" 2>&1
    sec "progress (last request)"
    cat "$RUN/progress" 2>&1
    sec state
    for f in "$STATE"/*; do [ -f "$f" ] && echo "$(basename "$f"): $(cat "$f")"; done
    sec tunnels.tsv
    cat "$TSV" 2>&1
    sec configs
    for f in "$CONF"/*.conf; do
        [ -f "$f" ] || continue
        echo "-- $(basename "$f")"; redact < "$f"
    done
    sec "wg show"
    wg show all 2>&1 | redact
    sec interfaces
    for f in $(ifconfig -l); do case "$f" in utun*|en*) ifconfig "$f" ;; esac; done
    sec routes
    netstat -rn
    sec dns
    scutil --dns | sed -n '1,/^DNS configuration (for scoped/p'
    sec "WireGuard app"
    scutil --nc list
    sec "log (last 300 lines)"
    tail -300 "$LOG" 2>&1 | redact
}

cmd_breakglass() {
    echo "Breakglass: stop every tunnel and put the normal connection back"
    stop_app_tunnels
    # The repo copy, not the installed one: works when that's missing or broken
    sudo "$0" _breakglass "$WG_TUNNELS"
}

cmd_down() {
    check_installed
    stop_app_tunnels
    if [ ! -x "$INSTALLED" ]; then
        echo "The daemon isn't installed, so no tunnel of ours is up. Network still broken? tunnel.sh breakglass"
        return 0
    fi
    ask down
}

exit_line() {
    local trace i
    # Right after up/down macOS is still settling routes and DNS: a few tries
    for i in 1 2 3; do
        trace=$(curl -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace) && [ -n "$trace" ] && break
        sleep 2
    done
    [ -z "$trace" ] && { echo "exit:   no answer (blocked or offline)"; return; }
    echo "$trace" | awk -F= '{v[$1] = $2} END {printf "exit:   %s colo=%s loc=%s warp=%s\n", v["ip"], v["colo"], v["loc"], v["warp"]}'
}

status() {
    local apps upd age od want wname until
    list_all
    echo
    [ -s "$DEFAULT_FILE" ] && echo "device: $(cat "$DEFAULT_FILE") (tunnel.sh default)"
    if [ ! -f "$RUN/status" ]; then
        echo "daemon: not running (install.sh, or tunnel.sh install for just the daemon)"
    else
        upd=$(st updated); age=$(( $(date +%s) - ${upd:-0} ))
        [ "$age" -gt 15 ] && echo "daemon: no update for ${age}s — tunnel.sh log"
        read -r want wname until <<< "$(st desired)"
        if [ "$want" = pause ]; then
            echo "paused: ${wname}, back at $(date -r "${until:-0}" +%H:%M) (tunnel.sh resume: now)"
        else
            echo "wanted: $(st desired)"
        fi
        [ -n "$(st state)" ] && echo "state:  $(st state | awk '{print $1}')"
        echo "kill switch: $(st armed)"
        [ -n "$(st name)" ] && echo "up:     $(st name) — $(st iface | awk '{printf "%s %s, handshake %s", $1, $2, ($3 == "" ? "never" : $3 "s ago")}')"
        [ -n "$(st warp)" ] && echo "warp:   $(st warp | awk '{printf "%s, handshake %s", $2, ($3 == "" ? "never" : $3 "s ago")}')"
        [ -n "$(st pin)" ] && echo "pinned: $(st pin | awk '{print $1 " via " $2}')"
    fi
    od=$(app_on_demand | joined)
    [ -n "$od" ] && echo "WireGuard app has On Demand on for ${od} — turn it off, tunnel.sh up refuses while it's on"
    apps=$(app_connected | joined)
    [ -n "$apps" ] && echo "WireGuard app has ${apps} on — tunnel.sh up stops it; switch app tunnels on only after tunnel.sh down"
    exit_line
}

# extract [zip]: the newest export zip in this Mac's exports/ (or the one
# given) becomes its config/. The zip is the authority: every .conf in config/
# is replaced, and ones not in the zip are removed. The zip is kept. Configs
# wireguard-tools issued ("# wireguard-tools client:" line) are left alone:
# they're wgt-ctl's to replace, and the app's export drops that line.

# tools_copy <conf>: one wireguard-tools issued, which extract keeps. A
# warped.* one has the line too (copied from its carrier), but it's the
# sweep's: it goes like the rest, and the next import writes it again.
tools_copy() {
    is_warped "$(basename "$1")" && return 1
    grep -q "^# wireguard-tools client:" "$1"
}

cmd_extract() {
    local zip="${1:-}" tmp f name n=0 rc dir exports configs
    dir=$(mac_dir) || exit 1
    exports="$dir/exports" configs="$dir/config"
    if [ -z "$zip" ]; then
        zip=$(ls -t "$exports"/*.zip 2>/dev/null | head -1)
        [ -n "$zip" ] || die "No zip in ${exports} — WireGuard app → Export Tunnels to Zip… into ${exports}"
    fi
    [ -f "$zip" ] || die "No zip ${zip}"
    # It holds every key: 0600 like the rest of exports/ (the app saves it 0644)
    case "$zip" in "$exports"/*) chmod 600 "$zip" ;; esac
    mkdir -p "$configs" && chmod 700 "$configs"
    tmp=$(mktemp -d "$configs/../.extract.XXXXXX") || die "mktemp failed"
    chmod 700 "$tmp"
    unzip -oqj "$zip" '*.conf' -d "$tmp" 2>/dev/null; rc=$?   # -o: never ask
    # 11: nothing matched (said just below)
    [ "$rc" -eq 0 ] || [ "$rc" -eq 11 ] || { rm -rf "$tmp"; die "Can't unzip ${zip}"; }
    for f in "$tmp"/*.conf; do [ -f "$f" ] && n=$((n + 1)); done
    [ "$n" -gt 0 ] || { rm -rf "$tmp"; die "No .conf files in ${zip}"; }

    echo "Extracting ${zip} into ${configs}"
    for f in "$tmp"/*.conf; do
        name=$(basename "$f")
        if [ -f "$configs/$name" ] && tools_copy "$configs/$name"; then
            echo "  ${name%.conf}: kept (wireguard-tools' copy)"; rm -f "$f"
        elif [ ! -f "$configs/$name" ]; then echo "  ${name%.conf}: new"
        elif cmp -s "$f" "$configs/$name"; then echo "  ${name%.conf}: unchanged"
        else echo "  ${name%.conf}: updated"; fi
    done
    for f in "$configs"/*.conf; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        [ -f "$tmp/$name" ] && continue
        tools_copy "$f" && continue
        echo "  ${name%.conf}: removed (not in the zip)"
        rm -f "$f"
    done
    # Over the old ones: if this fails, the zip's configs are still in $tmp
    if compgen -G "$tmp/*.conf" >/dev/null; then
        chmod 600 "$tmp"/*.conf
        mv -f "$tmp"/*.conf "$configs"/ || die "Can't move the configs into ${configs} (they're in ${tmp})"
    fi
    rm -rf "$tmp"
}

# import [dir] [-y]: install every .conf in this Mac's config/ (or dir) for
# the daemon. Tunnels no longer there are removed (unless up or asked for).
# Without a dir it first sweeps this Mac's carriers/ into config/
# (wgwarp-sweep.sh), as singbox.sh build does for its devices. It shows what
# it would do and asks first; -y, or no terminal (the menu bar), goes ahead.
cmd_import() {
    local src="" yes="" a f n=0 answer dir sweep previewed=""
    for a in "$@"; do
        case "$a" in -y|--yes) yes=1 ;; "") ;; *) src="$a" ;; esac
    done
    [ -n "$WGT_TEST" ] || [ -x "$INSTALLED" ] || die "$NOT_INSTALLED"
    if [ -z "$src" ]; then
        dir=$(mac_dir) || exit 1
        src="$dir/config"
        # The repo's sweep, beside this script (the daemon's copy has none)
        sweep="$(dirname "$0")/wgwarp-sweep.sh"
        # Also with no carriers: it writes warp.<device>.conf from warp/ (new
        # keys after rotate-warp, a new .warp-endpoint, back after extract)
        if ls "$dir"/carriers/*.conf >/dev/null 2>&1 || [ -f "$dir/warp/wgcf-profile.conf" ]; then
            [ -x "$sweep" ] || die "Can't sweep $dir: no $sweep (run tunnel.sh from the repo)"
            echo "Sweeping ${dir} into ${src}"
            SWEEP_NO_NEXT=1 "$sweep" "$dir" || die "Sweep failed: nothing imported"
            echo
        fi
    fi
    check_installed
    [ -d "$src" ] || die "No folder ${src} — tunnel.sh extract (from an export zip), or put .conf files there"
    for f in "$src"/*.conf; do [ -f "$f" ] && n=$((n + 1)); done
    [ "$n" -gt 0 ] || die "No .conf files in ${src} — tunnel.sh extract (from an export zip), or put them there"
    if [ -z "$yes" ] && [ -t 0 ]; then
        echo "Import from ${src} would do:"
        # The repo copy, dry: changes nothing, and doesn't update the daemon yet
        if [ -n "$WGT_TEST" ]; then "$0" _import "$src" dry; else sudo "$0" _import "$src" dry; fi || return 1
        echo
        read -rp "Go ahead? [y/N] " answer
        [[ "$answer" =~ ^[Yy] ]] || { echo "Nothing imported"; return 1; }
        echo
        previewed=changes
    fi
    echo "Importing from ${src}"
    if [ -n "$WGT_TEST" ]; then "$0" _import "$src" "" "$previewed"; else root _import "$src" "" "$previewed"; fi
}

usage() { echo "Usage: tunnel.sh -h | up [n|name] | down | pause [min] | resume | status | list | extract [zip] | import [dir] [-y] | extract-import [zip] | default [device] | update | install | uninstall | rotate-warp | diag [file] | log | breakglass"; }
list_all() {
    echo "warped:"; load_tunnels warped; list warped; echo
    echo "other:"; load_tunnels other; list other; echo
    echo "tunnel.sh up <n> picks from the warped list; up <name>, any tunnel"
}

case "${1:-}" in
    "")        check_installed; status; echo; usage ;;   # no command: status, and what else there is
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0" ;;
    up)        cmd_up "$2" ;;
    down)      cmd_down ;;
    pause)     cmd_pause "$2" ;;
    resume)    cmd_resume ;;
    diag)      cmd_diag "$2" ;;
    status)    check_installed; status ;;
    list)      list_all ;;
    extract)   cmd_extract "$2" ;;
    import)    shift; cmd_import "$@" ;;
    extract-import) cmd_extract "$2" && cmd_import ;;
    rotate-warp) cmd_rotate_warp ;;
    default)   cmd_default "$2" ;;
    update)    cmd_update ;;
    install)   sudo "$0" _install "$0" ;;
    uninstall) [ -x "$INSTALLED" ] || die "Not installed"; sudo "$INSTALLED" _uninstall ;;
    log)       tail -f "$LOG" ;;
    breakglass) cmd_breakglass ;;
    daemon)    cmd_daemon ;;
    request)   cmd_request "$2" "$3" ;;
    _import)   cmd_import_root "$2" "$3" "$4" ;;
    _install)  cmd_install_root "$2" ;;
    _uninstall) cmd_uninstall_root ;;
    _breakglass) cmd_breakglass_root "$2" ;;
    _diag)     cmd_diag_root ;;
    *) usage >&2; exit 1 ;;
esac
