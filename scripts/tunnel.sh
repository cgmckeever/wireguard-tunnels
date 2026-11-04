#!/bin/bash
# tunnel.sh — WireGuard tunnels run by wg-quick under a root LaunchDaemon,
# for every user on the Mac. Run it by its path (see README.md).
#
# Usage:
#   tunnel.sh up [n|name]   Ask "warped [Y/n]":
#                             Y  pick a warped.* tunnel: it, then WARP inside it
#                             n  pick any other tunnel and run it alone
#                           Enter at a menu takes the last one used, or the only one.
#   tunnel.sh down          Everything down, back to the normal connection
#   tunnel.sh [status]      Tunnels, what's up, handshakes, the exit
#   tunnel.sh list          Number the warped and other tunnels
#   tunnel.sh extract [zip] Replace ~/wg-tunnels/config with the .conf files in
#                           the newest zip in ~/wg-tunnels/exports (or the one
#                           given): the zip is the authority, configs not in it
#                           are removed. The zip is kept.
#   tunnel.sh import [dir]  Install every .conf in ~/wg-tunnels/config (or dir)
#                           for the daemon. Tunnels gone from it are removed.
#   tunnel.sh extract-import
#                           Both: extract, then import
#   tunnel.sh install       Install /usr/local/sbin/wg-tunnels and its LaunchDaemon
#   tunnel.sh uninstall     Take everything down, remove both (configs are kept)
#   tunnel.sh rotate-warp   New Cloudflare WARP keys: registers a new account
#                           (install.sh), imports it, and reconnects a warped
#                           tunnel that's up. The old account is deleted once
#                           that works, or put back if registering fails.
#   tunnel.sh log           Follow the daemon's log
#   tunnel.sh breakglass    Lost the network? Stops app tunnels, the daemon,
#                           wg-quick and wireguard-go; removes every route of ours
#                           and any reject route; puts tunnel DNS back to DHCP;
#                           power cycles Wi-Fi if it has no address. Trusts no state.
#
# up, down, import, rotate-warp, install, uninstall and breakglass use sudo
# (admin users).
#
# install.sh (in this repo) sets up what this needs: wireguard-tools, the WARP
# config and the daemon.
#
# ~/wg-tunnels/config holds every tunnel's .conf; `tunnel.sh import` installs them.
# Fill it by hand, or from the WireGuard app: Export Tunnels to Zip into
# ~/wg-tunnels/exports, then `tunnel.sh extract-import`. The app is optional.
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
# re-pins the server when the gateway changes, gives WARP a new source port when
# it stops handshaking (then restarts it), and restarts anything that died.

LABEL="com.local.wg-tunnels"
INSTALLED="/usr/local/sbin/wg-tunnels"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
LOG="/var/log/wg-tunnels.log"
TUNNEL_PREFIX="warped."

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
STATE="$ETC/state"                     # desired, last-warped, last-other
WARP_SRC="$PREFIX/etc/wireguard/warp.conf"  # written by install.sh
WG_RUN="${WGT_WG_RUN:-/var/run/wireguard}"  # wg-quick's <iface>.name -> utunN

EXPORTS="$HOME/wg-tunnels/exports"   # WireGuard app "Export Tunnels to Zip"
CONFIGS="$HOME/wg-tunnels/config"    # every tunnel's .conf: what import installs
WAIT_SECS=30
WATCH_SECS=30
STALE_SECS=180
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

# Write $2 to $1 atomically (new inode), mode $3
put() {
    local tmp
    tmp=$(mktemp "$1.XXXXXX") || return 1
    printf '%s\n' "$2" > "$tmp" && chmod "${3:-644}" "$tmp" && mv -f "$tmp" "$1"
}

conf_val() {  # conf_val <file> <key> — first value of key
    awk -F'[[:space:]]*=[[:space:]]*' -v k="$2" \
        'tolower($1) ~ "^[[:space:]]*" tolower(k) "$" {sub(/[[:space:]]+$/, "", $2); print $2; exit}' "$1"
}

host_of() { sed -E 's/^\[?([^]]*)\]?:[0-9]+$/\1/'; }

gateway() {
    netstat -nr -f inet | awk '$1 == "default" && $2 !~ /^link#/ {print $2; exit}'
}

route_if() { route -n get "$1" 2>/dev/null | awk '/interface:/ {print $2}'; }

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

# kind of a config: warped (by name), full (all of IPv4: any x.x.x.x/0 — wg
# ignores the address bits, e.g. 192.168.1.0/0 — or the two /1 halves), or split
kind_of() {
    local ips
    case "$1" in "$TUNNEL_PREFIX"*) echo warped; return ;; esac
    ips=$(grep -iE '^[[:space:]]*AllowedIPs[[:space:]]*=' "$2" | sed 's/^[^=]*=//' | tr ', \t\r' '\n\n\n\n')
    if grep -qxE '[0-9.]+/0' <<< "$ips" \
        || { grep -qx '0\.0\.0\.0/1' <<< "$ips" && grep -qx '128\.0\.0\.0/1' <<< "$ips"; }; then
        echo full
    else
        echo split
    fi
}

# render <src> <kind> <warp-endpoint-host> <endpoint-ip>
#   warped: AllowedIPs = WARP endpoint only, no DNS, keepalive
#   full:   Table = off (the daemon does the routes), DNS kept
#   split:  as is
#   all:    Endpoint host resolved to the IP (DNS can be cut off while switching)
render() {
    awk -v kind="$2" -v wep="$3" -v ip="$4" '
        { sub(/\r$/, "") }
        /^[[:space:]]*\[Interface\]/ { print; if (kind == "full") print "Table = off"; sec = "i"; next }
        /^[[:space:]]*\[Peer\]/      { print; sec = "p"; next }
        sec == "i" && /^[[:space:]]*Table[[:space:]]*=/ && kind == "full" { next }
        kind == "warped" && /^[[:space:]]*DNS[[:space:]]*=/ { next }
        kind == "warped" && /^[[:space:]]*AllowedIPs[[:space:]]*=/ { print "AllowedIPs = " wep "/32"; next }
        kind == "warped" && /^[[:space:]]*PersistentKeepalive[[:space:]]*=/ { next }
        /^[[:space:]]*Endpoint[[:space:]]*=/ {
            port = $0; sub(/.*:/, "", port)
            print "Endpoint = " ip ":" port
            if (kind == "warped") print "PersistentKeepalive = 25"
            next
        }
        { print }
    ' "$1"
}

# WARP for wg-quick: no PostUp (the daemon does the routes), keepalive so a
# stale handshake means trouble rather than idleness
render_warp() {
    awk '
        { sub(/\r$/, "") }
        /^[[:space:]]*(PostUp|PostDown|PreUp|PreDown|Table|PersistentKeepalive)[[:space:]]*=/ { next }
        /^[[:space:]]*\[Interface\]/ { print; print "Table = off"; next }
        /^[[:space:]]*Endpoint[[:space:]]*=/ { print; print "PersistentKeepalive = 25"; next }
        { print }
    ' "$1"
}

resolve() {
    if [[ "$1" =~ ^[0-9.]+$ || "$1" == *:* ]]; then echo "$1"; return; fi
    dscacheutil -q host -a name "$1" | awk '/^ip_address:/ {print $2; exit}'
}

cmd_import_root() {
    local src="$1" f name kind ep host ip iface out tmp state n wep active rows="" seen=""
    need_root import
    [ -d "$src" ] || die "No folder ${src}"
    mkdir -p "$CONF" "$STATE" && chmod 700 "$CONF" && chmod 755 "$ETC" "$STATE"
    touch "$TSV"

    [ -f "$WARP_SRC" ] || die "No ${WARP_SRC} — run install.sh"
    wep=$(conf_val "$WARP_SRC" Endpoint | host_of)
    tmp=$(mktemp "$CONF/.warp.XXXXXX")
    render_warp "$WARP_SRC" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$CONF/warp.conf"

    active=$(awk '$1 == "name" {print $2}' "$RUN/status" 2>/dev/null)
    printf '%-28s %-7s %-6s %s\n' TUNNEL KIND IFACE FILE
    for f in "$src"/*.conf; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .conf)
        if ! grep -q '^\[Interface\]' "$f" || ! grep -q '^\[Peer\]' "$f" \
            || [ -z "$(conf_val "$f" PrivateKey)" ] || [ -z "$(conf_val "$f" Endpoint)" ]; then
            printf '%-28s %-7s %-6s %s\n' "$name" - - "skipped: not a WireGuard config"
            continue
        fi
        kind=$(kind_of "$name" "$f")
        host=$(conf_val "$f" Endpoint | host_of)
        ip=$(resolve "$host")
        if [ -z "$ip" ]; then
            printf '%-28s %-7s %-6s %s\n' "$name" "$kind" - "skipped: can't resolve ${host}"
            continue
        fi
        # Keep a tunnel's interface name across imports; new ones get the next free wtN
        iface=$(awk -F'\t' -v n="$name" '$1 == n {print $2; exit}' "$TSV")
        if [ -z "$iface" ]; then
            n=0
            while awk -F'\t' '{print $2}' "$TSV" | grep -qx "wt$n" || [[ " $seen " == *" wt$n "* ]]; do
                n=$((n + 1))
            done
            iface="wt$n"
        fi
        seen+=" $iface"

        out="$CONF/$iface.conf"
        tmp=$(mktemp "$CONF/.import.XXXXXX")
        render "$f" "$kind" "$wep" "$ip" > "$tmp"
        chmod 600 "$tmp"
        if [ -f "$out" ] && cmp -s "$tmp" "$out"; then
            rm -f "$tmp"; state=unchanged
        else
            [ -f "$out" ] && state=updated || state=new
            mv -f "$tmp" "$out"
        fi
        [ "$name" = "$active" ] && [ "$state" = updated ] && state="updated (up now: re-run tunnel.sh up)"
        rows+="${name}"$'\t'"${iface}"$'\t'"${kind}"$'\t'"${ip}"$'\n'
        printf '%-28s %-7s %-6s %s\n' "$name" "$kind" "$iface" "$state"
    done

    # Tunnels gone from the export: removed, unless up right now
    while IFS=$'\t' read -r name iface kind ip; do
        [ -n "$name" ] || continue
        printf '%s' "$rows" | awk -F'\t' -v n="$name" '$1 == n {f = 1} END {exit !f}' && continue
        if [ "$name" = "$active" ]; then
            rows+="${name}"$'\t'"${iface}"$'\t'"${kind}"$'\t'"${ip}"$'\n'
            printf '%-28s %-7s %-6s %s\n' "$name" "$kind" "$iface" "kept: up now (tunnel.sh down, then import again)"
        else
            rm -f "$CONF/$iface.conf"
            printf '%-28s %-7s %-6s %s\n' "$name" "$kind" "$iface" "removed"
        fi
    done < "$TSV"

    put "$TSV" "$(printf '%s' "$rows" | sort -f -t$'\t' -k1,1)" 644
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

# /31 around the WARP endpoint (more specific than the /2s, less than the carrier's /32)
warp_guard() {
    local ep a b c d
    ep=$(warp_ep)
    IFS=. read -r a b c d <<< "$ep"
    [ -n "$d" ] && echo "$a.$b.$c.$(( d & 254 ))/31"
}

arm() {
    [ -f "$RUN/armed" ] && return
    log "kill switch on"
    add_routes 127.0.0.1 -reject -- $V4_HALVES $V6_HALVES
    local g; g=$(warp_guard); [ -n "$g" ] && add_routes 127.0.0.1 -reject -- "$g"
    : > "$RUN/armed"
}

disarm() {
    [ -f "$RUN/armed" ] || return
    log "kill switch off"
    del_routes $V4_HALVES $V6_HALVES
    local g; g=$(warp_guard); [ -n "$g" ] && del_routes "$g"
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
    out=$(mktemp "$RUN/.wgq.XXXXXX")
    wg-quick "$1" "$CONF/$2.conf" > "$out" 2>&1
    rc=$?
    # wg quotes a key it rejects: never let one reach the log
    grep -v 'networksetup -' "$out" \
        | sed -E "s/[A-Za-z0-9+/]{42,43}=?/<key>/g; s/^/  [$2] /"
    rm -f "$out"
    return "$rc"
}

# --- daemon ---

progress() {  # a line for the waiting `tunnel.sh up/down`, and the log
    log "$*"
    echo "$*" >> "$RUN/progress"
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
            wg-quick down "$i" 2>&1 | grep -v 'networksetup -' | sed "s/^/  [$i] /"
        fi
    done
    unpin
    rm -f "$RUN/current"
}

wait_until() {  # wait_until <secs> <cmd...>
    local n="$1" i=0
    shift
    until "$@"; do
        [ "$i" -ge "$n" ] && return 1
        sleep 1; i=$((i + 1))
    done
}

has_hs() { [ -n "$(hs_age "$1")" ]; }
routes_via() { [ "$(route_if "$1")" = "$(utun_of "$2")" ]; }

# Give an exit interface the four /2s (and IPv6, if it has an IPv6 address)
take_traffic() {
    local u; u=$(utun_of "$1")
    add_routes -interface "$u" -- $V4_QUARTERS
    if conf_val "$CONF/$1.conf" Address | grep -q ':'; then
        add_routes -interface "$u" -- $V6_QUARTERS
    fi
}

apply_up() {
    local name="$1" iface kind ip exit_if
    read -r iface kind ip <<< "$(tsv_get "$name")"
    [ -n "$iface" ] && [ -f "$CONF/$iface.conf" ] || { progress "fail: no tunnel '${name}' (tunnel.sh import?)"; return 1; }

    if [ "$kind" = split ]; then
        teardown; disarm
    else
        arm; teardown
        progress "pinning ${ip} to the gateway"
        wait_until "$WAIT_SECS" pin "$ip" || { progress "fail: no default gateway to pin ${ip} to"; return 1; }
    fi

    progress "starting ${name} (${iface})"
    wgq up "$iface" || { progress "fail: wg-quick up ${iface}"; return 1; }
    exit_if="$iface"

    if [ "$kind" = warped ]; then
        wait_until 5 routes_via "$(warp_ep)" "$iface" \
            || { progress "fail: WARP endpoint doesn't route into ${iface}"; return 1; }
        progress "starting WARP inside ${name}"
        wgq up warp || { progress "fail: wg-quick up warp"; return 1; }
        exit_if=warp
    fi
    [ "$kind" = split ] || take_traffic "$exit_if"

    progress "waiting for a ${exit_if} handshake"
    wait_until "$WAIT_SECS" has_hs "$exit_if" || { progress "fail: no ${exit_if} handshake in ${WAIT_SECS}s"; return 1; }

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
    local want name
    read -r want name 2>/dev/null < "$STATE/desired"
    put "$RUN/progress" "req $1"
    WARP_STALE=0
    if [ "$want" = up ]; then
        if apply_up "$name"; then echo ok >> "$RUN/progress"; else echo fail >> "$RUN/progress"; fi
    else
        apply_down; echo ok >> "$RUN/progress"
    fi
}

# Every $WATCH_SECS while up
watchdog() {
    local name iface kind exit_if ip pgw gw age
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
        gw=$(gateway)
        if [ -n "$gw" ] && [ "$gw" != "$pgw" ]; then
            log "watchdog: gateway ${pgw:-none} -> ${gw}, re-pinning ${ip}"
            pin "$ip"
        fi
    fi
    if [ "$exit_if" = warp ]; then
        age=$(hs_age warp)
        if [ -z "$age" ] || [ "$age" -gt "$STALE_SECS" ]; then
            WARP_STALE=$((WARP_STALE + 1))
            if [ "$WARP_STALE" -eq 2 ]; then
                log "watchdog: WARP silent ${age:-?}s — new source port"
                wg set "$(utun_of warp)" listen-port 0
            elif [ "$WARP_STALE" -ge 4 ]; then
                log "watchdog: WARP still silent — restarting"; apply watchdog; return
            fi
        else
            WARP_STALE=0
        fi
    fi
}

write_status() {
    local name iface kind exit_if out
    out="armed $([ -f "$RUN/armed" ] && echo yes || echo no)"
    out+=$'\n'"desired $(cat "$STATE/desired" 2>/dev/null || echo down)"
    if read -r name iface kind exit_if 2>/dev/null < "$RUN/current"; then
        out+=$'\n'"name ${name}"$'\n'"kind ${kind}"
        out+=$'\n'"iface ${iface} $(utun_of "$iface") $(hs_age "$iface")"
        [ "$exit_if" = warp ] && out+=$'\n'"warp warp $(utun_of warp) $(hs_age warp)"
    fi
    [ -f "$RUN/pin" ] && out+=$'\n'"pin $(cat "$RUN/pin")"
    out+=$'\n'"updated $(date +%s)"
    put "$RUN/status" "$out"
}

cmd_daemon() {
    local req applied="" tick=0
    need_root daemon
    mkdir -p "$RUN" "$STATE" && chmod 755 "$RUN" "$STATE"
    rm -f "$RUN/armed" "$RUN/current"   # routes don't survive a reboot; a restart re-applies
    log "daemon start"
    while true; do
        req=$(cat "$RUN/request" 2>/dev/null)
        req="${req:-boot}"
        if [ "$req" != "$applied" ]; then
            applied="$req"
            log "applying: $(cat "$STATE/desired" 2>/dev/null || echo down) (${applied})"
            apply "$applied"
            tick=0
        elif [ "$tick" -ge "$WATCH_SECS" ]; then
            watchdog
            tick=0
        fi
        write_status
        sleep 1
        tick=$((tick + 1))
    done
}

# root side of up/down: record what's wanted and wake the daemon
cmd_request() {
    need_root request
    if [ "$1" = up ]; then
        [ -n "$(tsv_get "$2")" ] || die "No tunnel '$2'"
        put "$STATE/desired" "up $2"
    else
        put "$STATE/desired" "down"
    fi
    put "$RUN/request" "$(date +%s).$$"
}

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
tunnel_dns() {
    local f home
    home=$(eval echo "~${SUDO_USER:-root}")
    for f in "$WARP_SRC" "$CONF"/*.conf "$home"/wg-tunnels/{warp,config,carriers}/*.conf; do
        [ -f "$f" ] || continue
        awk -F'[[:space:]]*=[[:space:]]*' 'tolower($1) ~ /^[[:space:]]*dns$/ {print $2}' "$f"
    done | tr ', ' '\n\n' | grep . | sort -u
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
    launchctl bootout system/"$LABEL" 2>/dev/null && echo "  stopped ${LABEL}"

    echo "== wg-quick"
    # Route monitors first: they put routes and DNS back on every network change
    pkill -f 'bin/wg-quick' && echo "  killed wg-quick monitors"
    pkill -x wireguard-go && echo "  killed wireguard-go"
    for f in "$WG_RUN"/*.name "$WG_RUN"/*.sock; do
        [ -e "$f" ] && rm -f "$f" && echo "  removed ${f}"
    done

    echo "== routes"
    del_routes $V4_HALVES $V6_HALVES $V4_QUARTERS $V6_QUARTERS
    f=$(warp_guard 2>/dev/null); [ -n "$f" ] && del_routes "$f"
    # Server pins: the recorded one, every imported endpoint, WARP's
    read -r ip _ 2>/dev/null < "$RUN/pin"
    for ip in $ip $(awk -F'\t' '{print $4}' "$TSV" 2>/dev/null) $(warp_ep 2>/dev/null) \
              $(conf_val "$WARP_SRC" Endpoint 2>/dev/null | host_of); do
        route -q -n delete -host "$ip" >/dev/null 2>&1 && echo "  removed host route ${ip}"
    done
    # Anything still rejecting traffic into lo0 (a kill switch from any version)
    routes=$(netstat -rn | awk '$4 == "lo0" && $3 ~ /[RB]/ {print $1}')
    for f in $routes; do
        if [[ "$f" == *:* ]]; then route -q -n delete -inet6 "$f" >/dev/null 2>&1
        else route -q -n delete -inet "$f" >/dev/null 2>&1; fi
        echo "  removed reject route ${f}"
    done

    echo "== dns"
    known=$(tunnel_dns)
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

# bootout returns before the job is gone; bootstrap too soon fails with
# "5: Input/output error"
restart_daemon() {
    local i
    launchctl bootout system/"$LABEL" 2>/dev/null
    wait_until 10 eval '! loaded'
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
    launchctl bootout system/"$LABEL" 2>/dev/null
    teardown; disarm
    rm -f "$PLIST" "$INSTALLED"
    echo "Removed ${INSTALLED} and ${PLIST}; configs kept in ${ETC}"
}

# --- user side ---

root() {
    [ -x "$INSTALLED" ] || die "Not installed — run: tunnel.sh install"
    # Run from the repo and the installed copy is older: update it first (this
    # restarts the daemon, which re-applies what's wanted)
    if [ "$0" != "$INSTALLED" ] && ! cmp -s "$0" "$INSTALLED"; then
        echo "Updating ${INSTALLED} from $0"
        sudo "$0" _install "$0" >/dev/null || die "Update failed — run: tunnel.sh install"
    fi
    sudo "$INSTALLED" "$@"
}

# Before up: installed, and something imported
ready() {
    [ -x "$INSTALLED" ] || die "Not installed. First time:
  install.sh (in this repo)
  put .conf files in ${CONFIGS} (or WireGuard app → Export Tunnels to Zip… into ${EXPORTS}, then tunnel.sh extract)
  tunnel.sh import"
    [ -s "$TSV" ] || die "No tunnels imported: tunnel.sh import (configs in ${CONFIGS}), or tunnel.sh extract-import (from an export zip)"
}

check_installed() {
    if [ -x "$INSTALLED" ] && [ "$0" != "$INSTALLED" ] && ! cmp -s "$0" "$INSTALLED"; then
        echo "Note: ${INSTALLED} differs from $0 — the next up/down/import updates it" >&2
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

# Follow the daemon's progress on our request (its first line is "req <id>")
# until ok/fail
follow() {
    local req="$1" seen=1 n line i=0
    printf 'Waiting for the daemon '
    until [ "$(head -1 "$RUN/progress" 2>/dev/null)" = "req $req" ]; do
        [ "$i" -ge 15 ] && { echo " no answer — is it running? (tunnel.sh log)" >&2; return 1; }
        printf '.'; sleep 1; i=$((i + 1))
    done
    echo
    i=0
    while [ "$i" -lt 120 ]; do
        [ "$(head -1 "$RUN/progress" 2>/dev/null)" = "req $req" ] || { echo "  (superseded by another request)"; return 1; }
        n=$(wc -l < "$RUN/progress")
        if [ "$n" -gt "$seen" ]; then
            while IFS= read -r line; do
                case "$line" in
                    ok) echo; status; return 0 ;;
                    fail) echo; status; return 1 ;;
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
    apps=$(app_connected | paste -sd, - | sed 's/,/, /g')
    echo "Current connection:"
    echo "  tunnel: $(st name | grep . || echo none)"
    [ -n "$apps" ] && echo "  WireGuard app: ${apps}"
    echo "  $(exit_line)"
}

cmd_up() {
    local answer kind tunnel req od
    ready
    od=$(app_on_demand | paste -sd, - | sed 's/,/, /g')
    [ -z "$od" ] || die "On Demand is on in the WireGuard app for: ${od}
It reconnects behind the tunnel and breaks it. Turn it off (the tunnel → Edit → uncheck On-Demand), then tunnel.sh up."
    check_installed
    current; echo; echo
    if [ -n "$1" ] && ! [[ "$1" =~ ^[0-9]+$ ]]; then
        tunnel="$1"
        [ -n "$(tsv_get "$tunnel")" ] || die "No tunnel '${tunnel}' (tunnel.sh list)"
    else
        if [ -n "$1" ]; then answer=y; else read -rp "warped [Y/n]: " answer; fi
        [[ "$answer" =~ ^[Nn] ]] && kind=other || kind=warped
        tunnel=$(pick "$1" "$kind") || return 1
    fi
    stop_app_tunnels
    root request up "$tunnel" || return 1
    follow "$(cat "$RUN/request")"
}

# rotate-warp: a new WARP account in ~/wg-tunnels/warp. The old one waits in
# warp.old until the new one is imported, and comes back if registering fails.
cmd_rotate_warp() {
    local warp="$HOME/wg-tunnels/warp" old inst active kind
    [ "$(id -u)" -ne 0 ] || die "rotate-warp: run it as your user, not root"
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
    cmd_import || die "rotate-warp: import failed. The new account is in place: run tunnel.sh import, then delete ${old}"
    rm -rf "$old"
    echo "Old WARP account deleted"

    # A warped tunnel that's up still runs the old keys: reconnect it
    active=$(awk '$1 == "name" {print $2}' "$RUN/status" 2>/dev/null)
    kind=$(awk '$1 == "kind" {print $2}' "$RUN/status" 2>/dev/null)
    if [ -n "$active" ] && [ "$kind" = warped ]; then
        echo "== Reconnect ${active}"
        root request up "$active" || return 1
        follow "$(cat "$RUN/request")"
    fi
}

cmd_breakglass() {
    echo "Breakglass: stop every tunnel and put the normal connection back"
    stop_app_tunnels
    # The repo copy, not the installed one: works when that's missing or broken
    sudo "$0" _breakglass
}

cmd_down() {
    check_installed
    stop_app_tunnels
    if [ ! -x "$INSTALLED" ]; then
        echo "The daemon isn't installed, so no tunnel of ours is up. Network still broken? tunnel.sh breakglass"
        return 0
    fi
    root request down || return 1
    follow "$(cat "$RUN/request")"
}

exit_line() {
    local trace i
    # Right after up/down macOS is still settling routes and DNS: a few tries
    for i in 1 2 3; do
        trace=$(curl -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace) && [ -n "$trace" ] && break
        sleep 2
    done
    [ -z "$trace" ] && { echo "exit:   no answer (blocked or offline)"; return; }
    echo "exit:   $(echo "$trace" | awk -F= '/^ip=/ {print $2}') colo=$(echo "$trace" | awk -F= '/^colo=/ {print $2}') loc=$(echo "$trace" | awk -F= '/^loc=/ {print $2}') warp=$(echo "$trace" | awk -F= '/^warp=/ {print $2}')"
}

status() {
    local apps upd age od
    echo "warped:"; load_tunnels warped; list warped
    echo "other:"; load_tunnels other; list other
    echo
    if [ ! -f "$RUN/status" ]; then
        echo "daemon: not running (tunnel.sh install)"
    else
        upd=$(st updated); age=$(( $(date +%s) - ${upd:-0} ))
        [ "$age" -gt 10 ] && echo "daemon: no update for ${age}s — tunnel.sh log"
        echo "wanted: $(st desired)"
        echo "kill switch: $(st armed)"
        [ -n "$(st name)" ] && echo "up:     $(st name) — $(st iface | awk '{printf "%s %s, handshake %ss ago", $1, $2, ($3 == "" ? "never " : $3)}')"
        [ -n "$(st warp)" ] && echo "warp:   $(st warp | awk '{printf "%s, handshake %ss ago", $2, ($3 == "" ? "never " : $3)}')"
        [ -n "$(st pin)" ] && echo "pinned: $(st pin | awk '{print $1 " via " $2}')"
    fi
    od=$(app_on_demand | paste -sd, - | sed 's/,/, /g')
    [ -n "$od" ] && echo "WireGuard app has On Demand on for ${od} — turn it off, tunnel.sh up refuses while it's on"
    apps=$(app_connected | paste -sd, - | sed 's/,/, /g')
    [ -n "$apps" ] && echo "WireGuard app has ${apps} on — tunnel.sh up stops it; switch app tunnels on only after tunnel.sh down"
    exit_line
}

# extract [zip]: the newest export zip (or the one given) becomes ~/wg-tunnels/config.
# The zip is the authority: every .conf in config/ is replaced, and ones not
# in the zip are removed. The zip is kept.
cmd_extract() {
    local zip="${1:-}" tmp f name n=0
    if [ -z "$zip" ]; then
        zip=$(ls -t "$EXPORTS"/*.zip 2>/dev/null | head -1)
        [ -n "$zip" ] || die "No zip in ${EXPORTS} — WireGuard app → Export Tunnels to Zip… into ${EXPORTS}"
    fi
    [ -f "$zip" ] || die "No zip ${zip}"
    mkdir -p "$CONFIGS" && chmod 700 "$CONFIGS"
    tmp=$(mktemp -d "$CONFIGS/../.extract.XXXXXX") || die "mktemp failed"
    chmod 700 "$tmp"
    unzip -qj "$zip" '*.conf' -d "$tmp" 2>/dev/null || { rm -rf "$tmp"; die "Can't unzip ${zip}"; }
    for f in "$tmp"/*.conf; do [ -f "$f" ] && n=$((n + 1)); done
    [ "$n" -gt 0 ] || { rm -rf "$tmp"; die "No .conf files in ${zip}"; }

    echo "Extracting ${zip} into ${CONFIGS}"
    for f in "$tmp"/*.conf; do
        name=$(basename "$f")
        if [ ! -f "$CONFIGS/$name" ]; then echo "  ${name%.conf}: new"
        elif cmp -s "$f" "$CONFIGS/$name"; then echo "  ${name%.conf}: unchanged"
        else echo "  ${name%.conf}: updated"; fi
    done
    for f in "$CONFIGS"/*.conf; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        [ -f "$tmp/$name" ] || echo "  ${name%.conf}: removed (not in the zip)"
        rm -f "$f"
    done
    chmod 600 "$tmp"/*.conf
    mv "$tmp"/*.conf "$CONFIGS"/
    rm -rf "$tmp"
}

# import [dir]: install every .conf in ~/wg-tunnels/config (or dir) for the
# daemon. Tunnels no longer there are removed (unless up right now).
cmd_import() {
    local src="${1:-$CONFIGS}" f n=0
    check_installed
    [ -d "$src" ] || die "No folder ${src} — tunnel.sh extract (from an export zip), or put .conf files there"
    for f in "$src"/*.conf; do [ -f "$f" ] && n=$((n + 1)); done
    [ "$n" -gt 0 ] || die "No .conf files in ${src} — tunnel.sh extract (from an export zip), or put them there"
    echo "Importing from ${src}"
    if [ -n "$WGT_TEST" ]; then "$0" _import "$src"; else root _import "$src"; fi
}

case "${1:-status}" in
    up)        cmd_up "$2" ;;
    down)      cmd_down ;;
    status)    check_installed; status; echo; echo "Usage: tunnel.sh up [n|name] | down | status | list | extract [zip] | import [dir] | extract-import | install | uninstall | rotate-warp | log | breakglass" ;;
    list)      echo "warped:"; load_tunnels warped; list warped; echo "other:"; load_tunnels other; list other ;;
    extract)   cmd_extract "$2" ;;
    import)    cmd_import "$2" ;;
    extract-import) cmd_extract "$2" && cmd_import ;;
    rotate-warp) cmd_rotate_warp ;;
    install)   sudo "$0" _install "$0" ;;
    uninstall) [ -x "$INSTALLED" ] && sudo "$INSTALLED" _uninstall ;;
    log)       tail -f "$LOG" ;;
    breakglass) cmd_breakglass ;;
    daemon)    cmd_daemon ;;
    request)   cmd_request "$2" "$3" ;;
    _import)   cmd_import_root "$2" ;;
    _install)  cmd_install_root "$2" ;;
    _uninstall) cmd_uninstall_root ;;
    _breakglass) cmd_breakglass_root ;;
    *) echo "Usage: tunnel.sh up [n|name] | down | status | list | extract [zip] | import [dir] | extract-import | install | uninstall | rotate-warp | log | breakglass" >&2; exit 1 ;;
esac
