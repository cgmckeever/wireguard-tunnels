#!/bin/bash
# nord.sh — make a NordVPN (NordLynx) WireGuard config for a device or server.
#
# Usage:
#   nord.sh                                    asks for everything
#   nord.sh device <device> carrier|config <country> [<city>]
#   nord.sh server <server> <country> [<city>]
#
# <country> is a code or a name (us, ca, "United States"). <city> is one of
# Nord's cities in it (honolulu, "new york"), or any (the default: Nord's pick
# in the whole country). Nord has cities, not states or regions. Anything left
# out is asked for: after the country, a numbered list of its cities.
#
# Writes one file per holder and place (nord.<cc> for any city in the
# country, nord.<cc>.<city> for one city):
#   device, carrier   devices/<device>/carriers/nord.<cc>[.<city>].conf: the sweep
#                     turns it into warped.nord.<cc>[.<city>].<device> (Nord carries WARP)
#   device, config    devices/<device>/config/nord.<cc>[.<city>].conf: a plain full
#                     tunnel, Nord as the exit
#   server            servers/<server>/carriers/nord.<cc>[.<city>].conf: an exit for
#                     wireguard-tools (wgt-ctl <server> jump-add), with a "# jump:
#                     <code> <city, country> (Nord <server>)" line. The code is
#                     nd-<cc>, or for a city its first letters and the country
#                     (hon-us), the way wgt-ctl names jumps.
# A device can have both a carrier and a config for one place.
#
# Running it again for the same holder and place regenerates that file. It
# keeps its Nord server while that one is still among Nord's recommended ones
# for the country and no other file uses it. Only files with a "# source: nord"
# line are ever regenerated; any other file of that name is left alone.
#
# One Nord server per file: Nord gives one WireGuard key per account, so every
# Nord config shares it. The same key on two Nord servers at once works; twice
# on one server, both break. So a server another Nord file (any holder, any
# device's carrier or config) already uses is skipped for the next recommended
# one.
#
# The access token comes from $WG_TUNNELS/.nord-token (Nord account >
# NordVPN > Manual setup > access token), never from an argument.
# Needs curl and jq.

set -o pipefail
umask 077
die() { echo "nord.sh: $*" >&2; exit 1; }

WG_TUNNELS="${WG_TUNNELS:-$HOME/wg-tunnels}"  # the store shared with wireguard-tools
TOKEN_FILE="$WG_TUNNELS/.nord-token"
API=https://api.nordvpn.com/v1
PORT=51820
ADDRESS=10.5.0.2/32                         # NordLynx gives every client this
DNS="103.86.96.100, 103.86.99.100"          # Nord's resolvers
POOL=50                                     # recommended servers to choose from

case "$1" in -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;; esac
command -v jq >/dev/null || die "jq missing (brew install jq)"
command -v curl >/dev/null || die "curl missing"

# pick <what> <choice> <names...>: the name chosen by number or name; asks
# (a numbered list) when there's no choice yet. Enter takes a lone option, or
# option $PICK_DEFAULT (a number) when set.
pick() {
    local what="$1" choice="$2" i n def="${PICK_DEFAULT:-}" prompt
    shift 2
    [ $# -gt 0 ] || die "no ${what}s"
    if [ -z "$choice" ]; then
        [ -t 0 ] || die "which ${what}? (no terminal to ask in; see nord.sh --help)"
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

# folders <dir>: its subfolders' names, one per line
folders() {
    local d
    for d in "$1"/*/; do [ -d "$d" ] && basename "$d"; done
}

# api <path> [curl args]: Nord's JSON
api() {
    local path="$1"
    shift
    curl -fsS --max-time 20 "$@" "$API/$path" || die "Nord's API didn't answer ($API/${path%%\?*})"
}

# endpoint_ip <conf>: the Endpoint's host
endpoint_ip() {
    awk -F'[[:space:]]*=[[:space:]]*' 'tolower($0) ~ /^[[:space:]]*endpoint[[:space:]]*=/ {print $2; exit}' "$1" \
        | sed 's/:[0-9]*$//'
}

is_nord() { grep -q '^# source: nord' "$1"; }

shopt -s nullglob

# 1. The holder: a device or a server
kind=$(pick "holder type" "$1" device server) || exit 1
if [ "$kind" = server ]; then base="$WG_TUNNELS/servers"; else base="$WG_TUNNELS/devices"; fi
names=()
while read -r n; do names+=("$n"); done < <(folders "$base")
[ ${#names[@]} -gt 0 ] || die "no ${kind}s in $base"
[ -n "$2" ] || [ ! -t 0 ] || echo "$([ "$kind" = server ] && echo Servers || echo Devices):" >&2
holder=$(pick "$kind" "$2" "${names[@]}") || exit 1

# 2. Carrier or config (a server's Nord file is always an exit: carriers/)
if [ "$kind" = server ]; then
    role=carrier country_arg="$3" city_arg="$4"
    [ $# -le 4 ] || die "usage: nord.sh server <server> <country> [<city>]"
else
    [ -n "$3" ] || [ ! -t 0 ] || echo "carrier: carries WARP (warped.nord.<cc>.$holder); config: a plain tunnel, Nord as the exit" >&2
    role=$(pick "kind of tunnel" "$3" carrier config) || exit 1
    country_arg="$4" city_arg="$5"
    [ $# -le 5 ] || die "usage: nord.sh device <device> carrier|config <country> [<city>]"
fi

# 3. The country
[ -f "$TOKEN_FILE" ] || die "no $TOKEN_FILE (Nord account > NordVPN > Manual setup > access token; one line)"
chmod 600 "$TOKEN_FILE"
if [ -z "$country_arg" ]; then
    [ -t 0 ] || die "which country? (no terminal to ask in)"
    read -rp "Country (a code or a name, e.g. us, Canada): " country_arg
    [ -n "$country_arg" ] || die "no country"
fi
country=$(api servers/countries | jq -c --arg q "$country_arg" '
    ($q | ascii_downcase) as $q
    | [.[] | select((.code | ascii_downcase) == $q or (.name | ascii_downcase) == $q)][0] // empty')
if [ -z "$country" ]; then
    near=$(api servers/countries | jq -r --arg q "$country_arg" '
        ($q | ascii_downcase) as $q
        | [.[] | select(.name | ascii_downcase | contains($q)) | "\(.code | ascii_downcase) (\(.name))"] | join(", ")')
    die "no Nord country '${country_arg}'${near:+; did you mean: $near}"
fi
cid=$(jq -r .id <<< "$country")
cc=$(jq -r '.code | ascii_downcase' <<< "$country")
cname=$(jq -r .name <<< "$country")

# 4. The city: any (Nord's pick in the whole country), or one of Nord's
cities=()
while IFS= read -r n; do cities+=("$n"); done < <(jq -r '.cities[]?.name' <<< "$country")
if [ -n "$city_arg" ]; then
    typed="$city_arg"
    # Any case, as typed
    city_arg=$(jq -r --arg q "$city_arg" '($q | ascii_downcase) as $q
        | if $q == "any" then "any" else ([.cities[]? | select(.name | ascii_downcase == $q) | .name][0] // empty) end' <<< "$country")
    [ -n "$city_arg" ] || die "no Nord city '$typed' in $cname; its cities: $(printf '%s, ' "${cities[@]}" | sed 's/, $//')"
elif [ ${#cities[@]} -gt 1 ] && [ -t 0 ]; then
    echo "Cities in $cname (any = Nord's pick in the whole country):" >&2
    city_arg=$(PICK_DEFAULT=1 pick city "" any "${cities[@]}") || exit 1
fi
want_city=""; [ -n "$city_arg" ] && [ "$city_arg" != any ] && want_city="$city_arg"

# 5. The file, and the Nord servers other files already use
dir="$base/$holder/config"; [ "$role" = carrier ] && dir="$base/$holder/carriers"
name="nord.$cc"
filter="filters\[country_id\]=$cid"
if [ -n "$want_city" ]; then
    slug=$(tr '[:upper:]' '[:lower:]' <<< "$want_city" | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')
    name+=".$slug"
    filter="filters\[country_city_id\]=$(jq -r --arg c "$want_city" '[.cities[] | select(.name == $c) | .id][0]' <<< "$country")"
fi
out="$dir/$name.conf"
current=""
if [ -f "$out" ]; then
    is_nord "$out" || die "$out has no \"# source: nord\" line: not replacing a file nord.sh didn't write"
    current=$(endpoint_ip "$out")
fi
# A device's carrier is also in its config/ as the sweep's warped copy: that's
# this file, not another holder
own_copy=""
[ "$kind/$role" = device/carrier ] && own_copy="$base/$holder/config/warped.$name.$holder.conf"
taken=" "
for f in "$WG_TUNNELS"/devices/*/{carriers,config}/*.conf "$WG_TUNNELS"/servers/*/carriers/*.conf; do
    [ "$f" = "$out" ] || [ "$f" = "$own_copy" ] && continue
    is_nord "$f" && taken+="$(endpoint_ip "$f") "
done

# 6. A Nord server: the current one if it's still recommended and free, else
# the first free recommendation
recs=$(api "servers/recommendations?filters\[servers_technologies\]\[identifier\]=wireguard_udp&$filter&limit=$POOL" \
    | jq -c '.[] | {host: .hostname, ip: .station, load,
                   city: (.locations[0].country.city.name // ""),
                   pub: ([.technologies[] | select(.identifier == "wireguard_udp") | .metadata[]? | select(.name == "public_key") | .value][0] // "")}
             | select(.pub != "")')
where="${want_city:+$want_city, }$cname"
[ -n "$recs" ] || die "Nord recommends no WireGuard servers in $where"
server=""
if [ -n "$current" ]; then
    case "$taken" in *" $current "*) ;; *) server=$(jq -c --arg ip "$current" 'select(.ip == $ip)' <<< "$recs" | head -1) ;; esac
fi
kept=${server:+1}
if [ -z "$server" ]; then
    while read -r s; do
        case "$taken" in *" $(jq -r .ip <<< "$s") "*) continue ;; esac
        server="$s"; break
    done <<< "$recs"
fi
[ -n "$server" ] || die "all $(wc -l <<< "$recs" | tr -d ' ') servers Nord recommends in $where are used by other Nord files"
host=$(jq -r .host <<< "$server")
short="${host%%.*}"
city=$(jq -r .city <<< "$server")
place="${city:+$city, }$cname"

# 7. A server's jump code: nd-<cc>, or for a city its first three letters and
# the country (hon-us), as wgt-ctl names jumps; 2-6 characters. One another
# file on that server already has gets a digit instead of its third letter.
if [ "$kind" = server ]; then
    codes=" "
    for f in "$dir"/*.conf; do
        [ "$f" = "$out" ] && continue
        codes+="$(sed -n 's/^# jump: \([^ ]*\) .*/\1/p' "$f" | head -1) "
    done
    if [ -n "$want_city" ]; then
        letters=$(tr -cd 'a-z' <<< "$slug")
        code="${letters:0:3}-$cc"
        for i in 2 3 4 5 6 7 8 9; do
            case "$codes" in *" $code "*) code="${letters:0:2}$i-$cc" ;; *) break ;; esac
        done
    else
        code="nd-$cc"
    fi
    case "$codes" in *" $code "*) die "jump code $code is already used by another file in $dir" ;; esac
fi

# 8. The key: one per Nord account, the same in every Nord config
key=$(api users/services/credentials -u "token:$(tr -d ' \t\r\n' < "$TOKEN_FILE")" | jq -r '.nordlynx_private_key // empty') \
    || die "no NordLynx key (is the token in $TOKEN_FILE still valid?)"
[ -n "$key" ] || die "no NordLynx key (is the token in $TOKEN_FILE still valid?)"

# 9. Write it (only if it changed)
mkdir -p "$dir" && chmod 700 "$dir" || die "can't create $dir"
tmp=$(mktemp "$dir/.nord.XXXXXX") || die "mktemp failed in $dir"
trap 'rm -f "$tmp"' EXIT
{
    [ "$kind" = server ] && echo "# jump: $code $place (Nord $short)"
    echo "# source: nord $cc${want_city:+ $slug}"
    echo "# nord: $host, $place"
    echo "[Interface]"
    echo "PrivateKey = $key"
    echo "Address = $ADDRESS"
    echo "DNS = $DNS"
    echo
    echo "[Peer]"
    echo "PublicKey = $(jq -r .pub <<< "$server")"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "Endpoint = $(jq -r .ip <<< "$server"):$PORT"
    echo "PersistentKeepalive = 25"
} > "$tmp"
chmod 600 "$tmp"
if [ -f "$out" ] && cmp -s "$tmp" "$out"; then
    state=unchanged
else
    state=new; [ -f "$out" ] && state=updated
    mv -f "$tmp" "$out" || die "can't write $out"
fi
note=""
[ -n "$current" ] && [ -z "$kept" ] && note=" (was on $current: no longer recommended, or another Nord file uses it)"
echo "$out: $state, $host, $place$note"

echo
case "$kind/$role" in
    server/*)       echo "Next: wgt-ctl $holder jump-add   (adds it to $holder as jump $code)" ;;
    device/carrier) echo "Next: wgwarp-sweep.sh $holder, then tunnel.sh import (this Mac) or singbox.sh build $holder" ;;
    device/config)  echo "Next: tunnel.sh import (this Mac), singbox.sh build $holder, or qr.sh $holder $name" ;;
esac
