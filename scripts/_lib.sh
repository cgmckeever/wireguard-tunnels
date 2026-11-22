# _lib.sh — what nord.sh, qr.sh and install.sh share; they source it. (tunnel.sh doesn't:
# it's the root daemon, one self-contained file. The sweep, singbox.sh and
# check.sh are Python, in wgtun/.)
#
# The sourcing script sets SELF to its own path, links resolved:
#   SELF=$(readlink -f "$0"); . "$(dirname "$SELF")/_lib.sh"

PROG=$(basename "$SELF")                        # nord.sh, qr.sh: through a link too
HERE=$(dirname "$SELF")                         # the sourcing script's folder
WG_TUNNELS="${WG_TUNNELS:-$HOME/wg-tunnels}"    # the store shared with wireguard-tools
DEVICES="$WG_TUNNELS/devices"
MAC=$(cat "$DEVICES/.default" 2>/dev/null)      # this Mac's device (tunnel.sh default)

die() { echo "$PROG: $*" >&2; exit 1; }

# usage: the script's header comment, as its -h shows it
usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$SELF"; }

# folders <dir>: its subfolders' names, one per line
folders() {
    local d
    for d in "$1"/*/; do [ -d "$d" ] && basename "$d"; done
}

# pick <what> <choice> <names...>: the name chosen by number or name; asks
# (a numbered list) when there's no choice yet. Enter takes a lone option, or
# option $PICK_DEFAULT (a number) when set.
pick() {
    local what="$1" choice="$2" i n def="${PICK_DEFAULT:-}" prompt
    shift 2
    [ $# -gt 0 ] || die "no ${what}s"
    if [ -z "$choice" ]; then
        [ -t 0 ] || die "which ${what}? (no terminal to ask in; see $PROG --help)"
        i=1
        for n in "$@"; do printf '  %d) %s\n' "$i" "$n" >&2; i=$((i + 1)); done
        [ $# -eq 1 ] && def=1
        prompt="Pick a $what [1-$#]"; [ -n "$def" ] && prompt+=" (Enter = ${!def})"
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
