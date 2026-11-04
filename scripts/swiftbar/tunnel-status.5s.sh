#!/bin/bash
# SwiftBar plugin — VPN lock in the menu bar (refreshes every 5 seconds).
#   locked, green   a tunnel is up (wg-tunnels daemon, or one in the WireGuard app)
#   locked, orange  a tunnel is wanted but isn't up: kill switch on, traffic blocked
#   open, grey      no VPN
# Reads /var/run/wg-tunnels/status (written by tunnel.sh's daemon).
# The menu switches tunnels in the background: sudo asks with a dialog
# (askpass.sh) and a notification says how it went.
#
# Installed as a symlink into SwiftBar's plugin folder (install.sh --swiftbar);
# the scripts are wherever the link points (scripts/swiftbar/..).

src="${SWIFTBAR_PLUGIN_PATH:-$0}"
while [ -L "$src" ]; do
    l=$(readlink "$src")
    case "$l" in /*) src="$l" ;; *) src="$(dirname "$src")/$l" ;; esac
done
SCRIPTS="$(cd "$(dirname "$src")/.." && pwd)"
TUNNEL="$SCRIPTS/tunnel.sh"
STATUS=/var/run/wg-tunnels/status
SELF="${SWIFTBAR_PLUGIN_PATH:-$0}"
for TSV in /opt/homebrew/etc/wg-tunnels/tunnels.tsv /usr/local/etc/wg-tunnels/tunnels.tsv; do
    [ -f "$TSV" ] && break
done

st() { awk -v k="$1" '$1 == k {$1 = ""; sub(/^ /, ""); print; exit}' "$STATUS" 2>/dev/null; }

# Uptime: the daemon writes current once, when a tunnel is up (a reconnect or
# a watchdog restart starts the clock again)
uptime_of() {
    local t; t=$(stat -f %m "$(dirname "$STATUS")/current" 2>/dev/null) || return
    awk -v s=$(( $(date +%s) - t )) 'BEGIN { d = int(s / 86400); h = int(s % 86400 / 3600); m = int(s % 3600 / 60)
        if (d) printf "%dd %dh %dm", d, h, m; else if (h) printf "%dh %dm", h, m; else printf "%dm %ds", m, s % 60 }'
}

notify() {
    osascript - "$1" "$2" <<'OSA' >/dev/null
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
OSA
}

# Menu actions: tunnel up/down/breakglass with no terminal
if [ "$1" = run ]; then
    shift
    export SUDO_ASKPASS="$SCRIPTS/askpass.sh"
    # reconnect <name>: the same tunnel again; the daemon takes it down and up
    if [ "$1" = reconnect ]; then
        what="Reconnect $2"
        out=$("$TUNNEL" up "$2" < /dev/null 2>&1); rc=$?
    else
        out=$("$TUNNEL" "$@" < /dev/null 2>&1); rc=$?
    fi
    case "$1" in
        reconnect) ;;
        up)   what="Switch to $2" ;;
        down) what="VPN off" ;;
        rotate-warp) what="New WARP keys" ;;
        *)    what="$1" ;;
    esac
    if [ "$rc" -eq 0 ]; then
        notify "VPN" "${what}: done"
    else
        notify "VPN" "${what}: failed — $(grep -E 'fail:|failed|rotate-warp:|refuses|On Demand|No |Not |sorry|incorrect' <<< "$out" | tail -1 | sed 's/^ *//')"
    fi
    exit 0
fi

# Menu "Status": an alert with what matters, no Terminal
if [ "$1" = popup ]; then
    trace=$(curl -s --max-time 6 https://www.cloudflare.com/cdn-cgi/trace)
    tv() { awk -F= -v k="$1" '$1 == k {print $2}' <<< "$trace"; }
    name=$(st name)
    apps=$(scutil --nc list | sed -nE \
        's/.*\((Connected)\)[[:space:]]+[0-9A-F-]{36} VPN \(com\.wireguard\.macos\) "([^"]+)".*/\2/p' | paste -sd, -)
    icons=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources
    icon="$icons/LockedIcon.icns"
    if [ -n "$name" ]; then title="VPN on: ${name}"
    elif [ -n "$apps" ]; then title="VPN on (WireGuard app): ${apps//,/, }"
    elif [ "$(st desired | awk '{print $1}')" = up ]; then title="VPN wanted but not up — traffic blocked"
    else title="No VPN"; icon="$icons/UnlockedIcon.icns"; fi
    msg=""
    if [ -n "$trace" ]; then
        msg+="Exit: $(tv ip)"$'\n'"Location: $(tv loc) ($(tv colo))   WARP: $(tv warp)"$'\n'
    else
        msg+="Exit: no answer (blocked or offline)"$'\n'
    fi
    if [ -n "$name" ]; then
        msg+=$'\n'"Up: $(uptime_of)"
        msg+=$'\n'"Handshake: $(st iface | awk '{print ($3 == "" ? "never" : $3 "s ago")}')"
        [ -n "$(st warp)" ] && msg+=$'\n'"WARP handshake: $(st warp | awk '{print ($3 == "" ? "never" : $3 "s ago")}')"
        msg+=$'\n'"Kill switch: $(st armed)"
        [ -n "$(st pin)" ] && msg+=$'\n'"Server: $(st pin | awk '{print $1 " via " $2}')"
    fi
    # display dialog, not alert: only a dialog takes a custom icon
    osascript - "$title" "$msg" "$icon" <<'OSA' >/dev/null
on run argv
    display dialog (item 1 of argv) & return & return & (item 2 of argv) ¬
        with title "VPN" with icon (POSIX file (item 3 of argv) as alias) ¬
        buttons {"OK"} default button "OK"
end run
OSA
    exit 0
fi

# A stale status file means the daemon isn't running: trust nothing in it
fresh=""
upd=$(st updated)
[ -n "$upd" ] && [ $(( $(date +%s) - upd )) -le 15 ] && fresh=1

name="" want="" armed="" hs="" warp_hs=""
if [ -n "$fresh" ]; then
    name=$(st name)
    want=$(st desired | awk '{print $1}')
    armed=$(st armed)
    hs=$(st iface | awk '{print $3}')
    warp_hs=$(st warp | awk '{print $3}')
fi

# Traffic: the kernel's byte counters for the exit interface (WARP when warped,
# else the tunnel), no root needed. Rates from the last run's sample.
human() {
    awk -v b="$1" 'BEGIN { split("B KB MB GB TB", u); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}
# IP and city lookups (ipinfo.io), in the background so the menu never waits;
# the menu shows the cache.
#   exit: through the tunnel, when it changes and every 10 minutes
#   real: only while no VPN is up (the kill switch blocks it otherwise, as it
#         should). Kept per router (gateway MAC) so after moving networks it
#         says unknown rather than show an old address.
DATA="${SWIFTBAR_PLUGIN_DATA_PATH:-${TMPDIR:-/tmp}/tunnel-status}"
mkdir -p "$DATA" 2>/dev/null
now=$(date +%s)

lookup() {  # lookup <file> <key>: refresh <file> if its key differs or it's 10 minutes old
    local f="$DATA/$1" key="$2" k ts state rest
    read -r k ts state rest 2>/dev/null < "$f"
    [ "$k" = "$key" ] && [ $((now - ${ts:-0})) -le 600 ] && return
    # Mark it pending first so the next refresh doesn't start another
    if [ "$k" = "$key" ]; then echo "$key $now $state $rest" > "$f"; else echo "$key $now pending" > "$f"; fi
    (
        j=$(curl -s -m10 https://ipinfo.io/json)
        v() { sed -nE "s/.*\"$1\": *\"([^\"]*)\".*/\1/p" <<< "$j" | head -1; }
        ip=$(v ip)
        if [ -n "$ip" ]; then
            place=$(printf '%s, %s, %s' "$(v city)" "$(v region)" "$(v country)" | sed 's/^, //; s/, , /, /')
            echo "$key $(date +%s) ok $ip $place" > "$f"
        else
            echo "$key $(date +%s) none" > "$f"
        fi
    ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null
}

shown() {  # shown <file> <key> <label>: the cached line, if it's for <key>
    local k ts state ip place
    read -r k ts state ip place 2>/dev/null < "$DATA/$1"
    if [ "$k" != "$2" ]; then echo "$3: unknown (new network since the last check without VPN)"; return; fi
    case "$state" in
        ok)   echo "$3: ${ip} — ${place}" ;;
        none) echo "$3: no answer" ;;
        *)    echo "$3: checking…" ;;
    esac
}

# This network: the router's MAC (its IP alone repeats across networks)
gw=$(netstat -nr -f inet | awk '$1 == "default" && $2 !~ /^link#/ {print $2; exit}')
net=$(arp -n "$gw" 2>/dev/null | awk '{print $4; exit}')
net="${net:-${gw:-none}}"

exit_ip="" real_ip=""
if [ -n "$name" ]; then
    lookup exit "$name"
    exit_ip=$(shown exit "$name" Exit)
elif [ -n "$fresh" ] && [ -z "$apps" ] && [ "$want" != up ] \
    && [[ "$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/ {print $2}')" == en* ]]; then
    # Only when traffic really leaves through Wi-Fi/Ethernet, never a tunnel
    lookup real "$net"
fi
real_ip=$(shown real "$net" "Real IP")

traffic=""
if [ -n "$name" ]; then
    xu=$(st warp | awk '{print $2}'); [ -n "$xu" ] || xu=$(st iface | awk '{print $2}')
    # The Link line has no Address column: Ibytes is $6, Obytes $9
    read -r rx tx < <(netstat -ibn -I "$xu" 2>/dev/null | awk '/<Link#/ {print $6, $9; exit}')
    if [ -n "$rx" ]; then
        now=$(date +%s)
        cache="$DATA/traffic"
        read -r pu pt prx ptx 2>/dev/null < "$cache"
        rrx="" rtx=""
        if [ "$pu" = "$xu" ] && [ -n "$pt" ] && [ "$now" -gt "$pt" ] && [ "$rx" -ge "$prx" ]; then
            dt=$((now - pt))
            rrx="  ($(human $(( (rx - prx) / dt )))/s)"
            rtx="  ($(human $(( (tx - ptx) / dt )))/s)"
        fi
        echo "$xu $now $rx $tx" > "$cache"
        traffic="Tx: $(human "$tx")${rtx}"$'\n'"Rx: $(human "$rx")${rrx}"
    fi
fi
apps=$(scutil --nc list | sed -nE \
    's/.*\((Connected)\)[[:space:]]+[0-9A-F-]{36} VPN \(com\.wireguard\.macos\) "([^"]+)".*/\2/p' | paste -sd, -)

if [ -n "$name" ] || [ -n "$apps" ]; then
    echo " | sfimage=lock.fill sfcolor=#34C759"
elif [ "$want" = up ]; then
    echo " | sfimage=lock.fill sfcolor=#FF9500"
else
    echo " | sfimage=lock.open sfcolor=#8E8E93"
fi

echo "---"
if [ -n "$name" ]; then
    echo "${name} | color=green"
    up=$(uptime_of); [ -n "$up" ] && echo "up ${up} | size=12"
    [ -n "$exit_ip" ] && echo "${exit_ip} | size=12"
    echo "${real_ip} | size=12 color=gray"
    echo "handshake ${hs:-never}s ago | size=12"
    [ -n "$warp_hs" ] && echo "WARP handshake ${warp_hs}s ago | size=12"
    echo "kill switch: ${armed:-no} | size=12"
    [ -n "$traffic" ] && while IFS= read -r l; do echo "${l} | size=12 font=Menlo"; done <<< "$traffic"
elif [ "$want" = up ]; then
    echo "Wanted: $(st desired | cut -d' ' -f2-) — not up | color=orange"
    echo "kill switch: ${armed:-no} | size=12"
else
    echo "No tunnel"
    echo "${real_ip} | size=12"
fi
[ -n "$apps" ] && echo "WireGuard app: ${apps//,/, }"
[ -z "$fresh" ] && echo "wg-tunnels daemon not answering | color=red"
echo "---"
echo "Status | bash=$SELF param1=popup terminal=false"
# Reconnect: the tunnel that's up, or the one wanted but not up
again="${name:-$( [ "$want" = up ] && st desired | cut -d' ' -f2- )}"
[ -n "$again" ] && echo "Reconnect | bash=$SELF param1=run param2=reconnect param3=$again terminal=false refresh=true"
echo "Disconnect (Tunnel Down) | bash=$SELF param1=run param2=down terminal=false refresh=true"
echo "Breakglass (Reset No Tunnel) | bash=$SELF param1=run param2=breakglass terminal=false refresh=true"
echo "---"
# Switcher: every imported tunnel, the one up checked
for group in warped other; do
    [ "$group" = warped ] && echo "Warped (WARP inside a carrier tunnel) | size=11 color=gray" || echo "Other | size=11 color=gray"
    awk -F'\t' -v g="$group" '($3 == "warped") == (g == "warped") {print $1 "\t" $3}' "$TSV" 2>/dev/null \
        | while IFS=$'\t' read -r t kind; do
            extra=""
            [ "$kind" = split ] && extra=" (split)"
            if [ "$t" = "$name" ]; then
                echo "${t}${extra} | checked=true"
            else
                echo "${t}${extra} | bash=$SELF param1=run param2=up param3=$t terminal=false refresh=true"
            fi
        done
done
echo "---"
echo "More"
echo "--Status in Terminal | bash=$TUNNEL param1=status terminal=true"
echo "--Log | bash=$TUNNEL param1=log terminal=true"
echo "--Rotate WARP Keys | bash=$SELF param1=run param2=rotate-warp terminal=false refresh=true"
