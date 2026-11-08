#!/bin/bash
# singbox.sh — tunnels for devices that run sing-box (iPhone, iPad, Apple TV,
# Android...), where the daemon can't, WARP inside a carrier included.
#
# The WireGuard app on those can't carry one tunnel inside another. sing-box
# can: its WireGuard endpoints take a detour, so WARP rides inside the
# carrier, in one VPN. This builds the profiles to import there.
#
# Usage:
#   singbox.sh new <device>      make ~/wg-tunnels/devices/<device>/ and its own WARP account
#   singbox.sh build <device>    sweep its carriers, write its sing-box/ profiles
#   singbox.sh list              the devices and what each has
#
# ~/wg-tunnels/devices/<device>/   (0700: it all holds private keys)
#   carriers/   the device's own WireGuard configs to carry WARP, made for this
#               device (a key shared with another device makes both drop)
#   warp/       the device's own wgcf WARP account and profile (same reason)
#   config/     every tunnel on the device: warped.<carrier>.conf (from the
#               sweep), and plain configs you put there, used as they are
#   sing-box/   what build writes, to import in the device's sing-box app:
#                 composite.<device>.json   every tunnel, picked in the app
#                 <server>.all.<device>.json  one server's tunnels (dengar.*)
#                 local.all.<device>.json   the local ones: warped.*, local.*
#                                           and warp (groups of 2+ only)
#                 <tunnel>.json             one tunnel each
#                 warp.json                 WARP alone, no carrier (in the
#                                           composite and local.all too)
#               build owns this folder: a .json it didn't write is removed
#
# This Mac is a device too (its folder is the one in devices/.default,
# set by tunnel.sh default). Its profiles use the daemon's keys: run one or
# the other, never both (tunnel.sh down before turning sing-box on).
#
# Override the WARP endpoint with WARP_ENDPOINT (IPv4:port, default
# 162.159.192.1:2408).

set -o pipefail
TUNNELS_DIR="$HOME/wg-tunnels/devices"
MAC=$(cat "$TUNNELS_DIR/.default" 2>/dev/null)     # this Mac's device
HERE="$(cd "$(dirname "$0")" && pwd)"

umask 077
die() { echo "singbox.sh: $*" >&2; exit 1; }

WARP_ENDPOINT="${WARP_ENDPOINT:-162.159.192.1:2408}"
[[ "$WARP_ENDPOINT" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+$ ]] \
    || die "WARP_ENDPOINT is IPv4:port, e.g. 162.159.192.1:2408"
WARP_HOST="${WARP_ENDPOINT%:*}"
WARP_PORT="${WARP_ENDPOINT##*:}"
WARP_NET="$WARP_HOST/32"

device_dir() {
    [ -n "$1" ] || die "a device name, please (singbox.sh $2 <device>)"
    [[ "$1" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]] \
        || die "device names are letters, digits, . _ - (not starting with .)"
    echo "$TUNNELS_DIR/$1"
}

# old_layout: stop on a layout from before ~/wg-tunnels/devices/ (nothing is
# moved for you). The same function is in tunnel.sh, wgwarp-sweep.sh and install.sh.
old_layout() {
    local top="$HOME/wg-tunnels" d
    for d in carriers config exports warp; do
        [ -e "$top/$d" ] && die "$top/$d is an old layout: this Mac's folders go in $top/devices/<this Mac's name, e.g. mbp-1>. Move it first:
  mkdir -p $top/devices/<name> && mv $top/$d $top/devices/<name>/"
    done
    [ -d "$top/local" ] || [ -d "$top/sing-box" ] || return 0
    die "$top has the old layout (local/, sing-box/): every device gets its own folder in devices/ now. Move them first:
  mkdir -p $top/devices
  mv $top/local $top/devices/<this Mac's name, e.g. mbp-1>
  mv $top/sing-box/* $top/devices/ && rmdir $top/sing-box
  (and in each device folder: mv profiles sing-box)"
}

# quiet_wgcf <dir> <args>: its chatter (a device table) only shows if it fails
quiet_wgcf() {
    local dir="$1" output
    shift
    command -v wgcf >/dev/null || die "wgcf missing (install.sh --sing-box, or brew install wgcf)"
    output=$(cd "$dir" && wgcf "$@" 2>&1) || { echo "$output" >&2; die "wgcf $1 failed"; }
}

cmd_new() {
    local dir d
    dir=$(device_dir "$1" new) || exit 1
    for d in "${TUNNELS_DIR%/*}" "$TUNNELS_DIR" "$dir" "$dir/carriers" "$dir/warp" "$dir/config"; do
        mkdir -p "$d" && chmod 700 "$d" || die "can't create $d"
    done
    if [ -f "$dir/warp/wgcf-account.toml" ]; then
        echo "WARP account: already there"
    else
        quiet_wgcf "$dir/warp" register --accept-tos
        rm -f "$dir/warp/wgcf-profile.conf"     # one left from an earlier account
        echo "WARP account: registered"
    fi
    chmod 600 "$dir/warp/wgcf-account.toml"
    [ -f "$dir/warp/wgcf-profile.conf" ] || quiet_wgcf "$dir/warp" generate
    chmod 600 "$dir/warp/wgcf-profile.conf"
    echo
    echo "Next: put this device's carriers in ${dir}/carriers/ and its plain tunnels"
    echo "      in ${dir}/config/ (new WireGuard configs made for this device)"
    echo "then: $HERE/singbox.sh build $1"
}

# --- reading configs ---

# conf_vals <file> <Key>: every <Key> line's value, everything after the first
# "=" (keys end in base64 "=" padding). Keys in any case, as wg-quick reads them.
conf_vals() {
    awk -v k="$(tr '[:upper:]' '[:lower:]' <<< "$2")" '
        { line = $0; sub(/\r$/, "", line) }
        tolower(line) ~ "^[[:space:]]*" k "[[:space:]]*=" {
            v = substr(line, index(line, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            print v
        }' "$1"
}
# conf_val <file> <Key>: the first <Key>'s value
conf_val() { conf_vals "$1" "$2" | head -1; }
# conf_list <file> <Key>: every value of every <Key> line, one per line
conf_list() {
    conf_vals "$1" "$2" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep .
}
json_list() { jq -R . | jq -sc .; }
count() { echo $#; }

# unusable <conf>: why build can't turn a config into an endpoint, or nothing
unusable() {
    local peers ep mtu
    grep -qi '^\[Interface\]' "$1" || { echo "no [Interface]"; return; }
    peers=$(grep -ci '^\[Peer\]' "$1")
    [ "$peers" = 1 ] || { echo "${peers} [Peer] sections, needs one"; return; }
    [ -n "$(conf_val "$1" PrivateKey)" ] || { echo "no PrivateKey"; return; }
    [ -n "$(conf_val "$1" PublicKey)" ] || { echo "no PublicKey"; return; }
    [ -n "$(conf_list "$1" Address)" ] || { echo "no Address"; return; }
    ep=$(conf_val "$1" Endpoint)
    [[ "$ep" =~ :[0-9]+$ ]] || { echo "Endpoint isn't host:port"; return; }
    mtu=$(conf_val "$1" MTU)
    [ -z "$mtu" ] || [[ "$mtu" =~ ^[0-9]+$ ]] || echo "MTU isn't a number"
}

# warped_name <carrier file>: the tunnel the sweep makes of it (the sweep has
# the same one-liner)
warped_name() { echo "warped.$(basename "$1" .conf | sed -E 's/^warped[.-]//')"; }

# --- sing-box JSON. Private keys go to jq in its environment, never its
# arguments: any user on the Mac can read another's arguments in ps. ---

# endpoint_json <conf> <tag> <mtu>: a sing-box WireGuard endpoint from a
# config (a swept carrier, or a plain tunnel), keepalive included
endpoint_json() {
    local conf="$1" ep host port ka
    ep=$(conf_val "$conf" Endpoint)
    host="${ep%:*}"; host="${host#[}"; host="${host%]}"; port="${ep##*:}"
    ka=$(conf_val "$conf" PersistentKeepalive); [[ "$ka" =~ ^[0-9]+$ ]] || ka=0
    KEY=$(conf_val "$conf" PrivateKey) PSK=$(conf_val "$conf" PresharedKey) \
    jq -n --arg tag "$2" --argjson mtu "$3" \
        --argjson address "$(conf_list "$conf" Address | json_list)" \
        --arg host "$host" --argjson port "$port" --arg pub "$(conf_val "$conf" PublicKey)" \
        --argjson allowed "$(conf_list "$conf" AllowedIPs | json_list)" --argjson ka "$ka" '
        { type: "wireguard", tag: $tag, mtu: $mtu, address: $address, private_key: env.KEY,
          peers: [ { address: $host, port: $port, public_key: $pub, allowed_ips: $allowed }
                   + (if env.PSK != "" then { pre_shared_key: env.PSK } else {} end)
                   + (if $ka > 0 then { persistent_keepalive_interval: $ka } else {} end) ] }'
}

# warp_json <WARP profile> <tag> <carrier tag> <mtu>: WARP, carried by the
# carrier (or straight from the device's network when the carrier tag is "").
# No keepalive: every WARP tunnel on a device shares its one WARP key, so only
# the one in use may talk to Cloudflare.
warp_json() {
    KEY=$(conf_val "$1" PrivateKey) \
    jq -n --arg tag "$2" --arg detour "$3" --argjson mtu "$4" \
        --argjson address "$(conf_list "$1" Address | json_list)" \
        --arg host "$WARP_HOST" --argjson port "$WARP_PORT" --arg pub "$(conf_val "$1" PublicKey)" '
        { type: "wireguard", tag: $tag, mtu: $mtu, address: $address, private_key: env.KEY }
        + (if $detour != "" then { detour: $detour } else {} end)
        + { peers: [ { address: $host, port: $port, public_key: $pub,
                       allowed_ips: ["0.0.0.0/0", "::/0"] } ] }'
}

# route_rules <outbound> [cidr...]: a JSON list with a rule sending the cidrs
# to the outbound, or an empty list
route_rules() {
    local out="$1"; shift
    [ $# -gt 0 ] || { echo '[]'; return; }
    printf '%s\n' "$@" | json_list | jq -c --arg out "$out" '[ { ip_cidr: ., outbound: $out } ]'
}

# --- collecting tunnels. Each one is a unit: its tag, its endpoints (a JSON
# list), its extra route rules and its tun MTU. These change cmd_build's
# locals (bash functions see their caller's): unit_add appends to tags,
# unit_eps, unit_rules and unit_mtu; add_warped also keeps cidrs_seen. ---

unit_add() { tags+=("$1"); unit_eps+=("$2"); unit_rules+=("$3"); unit_mtu+=("$4"); }

# add_warped <conf> <tag> <carrier MTU> <WARP profile>: WARP detoured through
# the carrier. The carrier's extras (device-network, tunnel-routes) need a rule:
# AllowedIPs doesn't route in sing-box, so without one they'd go into WARP. In
# a profile with several tunnels the rule applies whichever tunnel is picked,
# so a network two carriers claim goes to the first (group_rules).
add_warped() {
    local conf="$1" tag="$2" carrier="carrier.${2#warped.}" profile="$4" cidr eps wmtu
    # WARP runs at its own MTU (1280 from wgcf), as on the Mac; the carrier adds
    # up to 80 bytes to each WARP packet, so a carrier under that + 80 lowers it
    wmtu=$(warp_mtu "$profile")
    [ $(( $3 - 80 )) -lt "$wmtu" ] && wmtu=$(( $3 - 80 ))
    local own=()
    while read -r cidr; do
        own+=("$cidr")
        case "$cidrs_seen" in
            *" $cidr "*) echo "warning: $cidr is in two carriers: profiles with both send it to the first, not $carrier" >&2 ;;
            *) cidrs_seen+="$cidr " ;;
        esac
    done < <(conf_list "$conf" AllowedIPs | grep -vxF "$WARP_NET" | sort -u)
    eps=$( { endpoint_json "$conf" "$carrier" "$3" && warp_json "$profile" "$tag" "$carrier" "$wmtu"; } \
        | jq -sc .) || die "can't read $conf or $profile"
    unit_add "$tag" "$eps" "$(route_rules "$carrier" "${own[@]}")" "$wmtu"
}

# add_plain <conf> <tag> <MTU>: a tunnel used as it stands. A profile sends
# everything to the tunnel in use, so a split config (a home LAN only, say)
# leaves the device with nothing past its own networks, not even DNS.
add_plain() {
    local eps
    conf_list "$1" AllowedIPs | grep -qxF 0.0.0.0/0 \
        || echo "warning: $2 is a split tunnel (no 0.0.0.0/0): in sing-box it takes all traffic, and only its own networks work" >&2
    eps=$(endpoint_json "$1" "$2" "$3" | jq -sc .) || die "can't read $1"
    unit_add "$2" "$eps" '[]' "$3"
}

# warp_mtu <WARP profile>: its MTU (wgcf writes 1280)
warp_mtu() {
    local mtu
    mtu=$(conf_val "$1" MTU); [[ "$mtu" =~ ^[0-9]+$ ]] || mtu=1280
    echo "$mtu"
}

# add_warp <WARP profile>: WARP alone, straight from the device's network (no
# carrier): the device's own WARP account, at its MTU
add_warp() {
    local mtu eps
    mtu=$(warp_mtu "$1")
    eps=$(warp_json "$1" warp "" "$mtu" | jq -sc .) || die "can't read $1"
    unit_add warp "$eps" '[]' "$mtu"
}

# --- checks before writing ---

# key_lines <file>...: "<key><TAB><file>" for every file with a PrivateKey
key_lines() {
    local f k
    for f in "$@"; do
        [ -f "$f" ] || continue
        k=$(conf_val "$f" PrivateKey)
        [ -n "$k" ] && printf '%s\t%s\n' "$k" "${f#"$TUNNELS_DIR"/}"
    done
}

# check_keys <dir> <file>...: no private key shared with another device (two
# devices on one key knock each other off). Names the files, never the key.
#
# A key used twice on one device (a carrier copied from a config in config/,
# say) only gets a note: a device runs one tunnel at a time, and the composite
# profile has no keepalives, so only the tunnel in use talks to its server.
check_keys() {
    local dir="$1" d others=() dup self
    shift
    shopt -s nullglob
    for d in "$TUNNELS_DIR"/*/; do
        [ "${d%/}" = "$dir" ] && continue
        others+=("$d"carriers/*.conf "$d"config/*.conf "$d"warp/wgcf-profile.conf)
    done
    dup=$( { key_lines "$@" | awk '{ print "M\t" $0 }'; key_lines "${others[@]}" | awk '{ print "O\t" $0 }'; } \
        | awk -F'\t' '$1 == "M" { if ($2 in mine) print "S  " mine[$2] " and " $3; else mine[$2] = $3; next }
                      ($2 in mine)  { print "O  " mine[$2] " and " $3 }')
    self=$(sed -n 's/^S//p' <<< "$dup")
    dup=$(grep '^O' <<< "$dup")
    [ -z "$dup" ] || die "same private key in:
$(cut -c2- <<< "$dup")
each config needs its own (make a new one for this device)"
    [ -z "$self" ] || echo "note: same private key in (fine on one device: one tunnel at a time):
$self" >&2
}

# check_tags <device>: endpoint names are unique ("tunnel" is the picker's,
# "warp" the WARP-only tunnel's, carrier.<name> a warped tunnel's carrier),
# and no tunnel is named like the composite or a group profile
check_tags() {
    local dup
    dup=$( { printf '%s\n' "${unit_eps[@]}" | jq -r '.[].tag'; echo tunnel; } | sort | uniq -d | paste -sd' ' -)
    [ -z "$dup" ] || die "more than one tunnel would be named: $dup (rename the config; \"tunnel\", \"warp\" and \"carrier.<name>\" are taken)"
    case " ${tags[*]} " in
        *" composite.$1 "*) die "a tunnel can't be named composite.$1 (rename the config)" ;;
    esac
    local t
    for t in "${tags[@]}"; do
        case "$t" in *.all."$1") die "a tunnel can't be named $t: <name>.all.$1 is a group profile (rename the config)" ;; esac
    done
}

# --- writing ---

# Profiles are staged as temp files and only replace the old ones once every
# one is written (and passes sing-box check): a failed check changes nothing.
STAGED_TMP=() STAGED_OUT=()
trap 'rm -f "${STAGED_TMP[@]}"' EXIT

# stage_profile <file> <rules> <tags> <tun MTU>: a profile from the endpoints
# on stdin (a JSON list), extra route rules and the tunnels the picker lists,
# written to a temp file next to <file>.
#
# Everything goes through the picked tunnel, DNS included (1.1.1.1, hijacked
# from the tun). strict_route keeps traffic in the VPN: the nearest sing-box
# gets to a kill switch. A server given by hostname is looked up on the
# device's own network (default_domain_resolver): through the tunnel, it would
# need itself up first.
stage_profile() {
    local out="$1" tmp
    tmp=$(mktemp "$(dirname "$out")/.profile.XXXXXX") || die "mktemp failed"
    STAGED_TMP+=("$tmp"); STAGED_OUT+=("$out")
    jq --argjson rules "$2" --argjson tags "$3" --argjson mtu "$4" '. as $endpoints |
        { log: { level: "warn" },
          dns: { servers: [ { type: "udp", tag: "cloudflare", server: "1.1.1.1", detour: "tunnel" },
                            { type: "local", tag: "local" } ],
                 final: "cloudflare" },
          inbounds: [ { type: "tun", tag: "tun-in", address: ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                        mtu: $mtu, auto_route: true, strict_route: true } ],
          endpoints: $endpoints,
          outbounds: [ { type: "selector", tag: "tunnel", outbounds: $tags, default: $tags[0] } ],
          route: { auto_detect_interface: true, final: "tunnel", default_domain_resolver: "local",
                   rules: ([ { inbound: "tun-in", action: "sniff" },
                             { protocol: "dns", action: "hijack-dns" } ] + $rules) } }' > "$tmp" \
        || die "can't write $out"
}

# commit_profiles: check every staged profile with sing-box (when it's
# installed), then put each in place, printing new, updated or unchanged
commit_profiles() {
    local i tmp out state
    if command -v sing-box >/dev/null; then
        for i in "${!STAGED_TMP[@]}"; do
            sing-box check -c "${STAGED_TMP[i]}" >&2 \
                || die "sing-box check failed for $(basename "${STAGED_OUT[i]}"): no profile changed"
        done
    fi
    for i in "${!STAGED_TMP[@]}"; do
        tmp="${STAGED_TMP[i]}" out="${STAGED_OUT[i]}"
        if [ -f "$out" ] && cmp -s "$tmp" "$out"; then
            rm -f "$tmp"; state=unchanged
        else
            state=new; [ -f "$out" ] && state=updated
            mv "$tmp" "$out" || die "can't write $out (the profiles listed above were already replaced)"
        fi
        printf '%-44s %s\n' "$(basename "$out")" "$state"
    done
    STAGED_TMP=() STAGED_OUT=()
}

# group_key <tag>: the group profile a tunnel also goes in, from the first
# word of its name: warped.*, local.* and warp (WARP alone) are the device's
# local tunnels; anything else, e.g. dengar.chicago.iphone, its server's
group_key() {
    local k
    k=$(printf '%s' "${1%%.*}" | tr '[:upper:]' '[:lower:]')
    case "$k" in warp|warped) k=local ;; esac
    echo "$k"
}

# stage_group <file> <unit index>...: one profile with those tunnels, picked
# in the app. sing-box starts every endpoint in a profile, so no keepalives:
# an endpoint only talks to its server while it carries traffic. The tun's
# MTU is the smallest, so a packet fits whichever tunnel is picked. A network
# two carriers' extras claim goes to the first.
stage_group() {
    local out="$1" i min eps rules picks=()
    shift
    min=${unit_mtu[$1]}
    for i; do
        [ "${unit_mtu[i]}" -lt "$min" ] && min=${unit_mtu[i]}
        picks+=("${tags[i]}")
    done
    eps=$(for i; do echo "${unit_eps[i]}"; done \
        | jq -sc 'add | map(del(.peers[]?.persistent_keepalive_interval))') \
        || die "can't put $(basename "$out") together"
    rules=$(for i; do echo "${unit_rules[i]}"; done | jq -sc 'add // [] |
        reduce .[] as $r ({seen: {}, rules: []};
            . as $acc | ($r.ip_cidr | map(select($acc.seen[.] | not))) as $new
            | if ($new | length) > 0
              then .rules += [ { ip_cidr: $new, outbound: $r.outbound } ]
                   | .seen += ($new | map({ (.): true }) | add)
              else . end) | .rules') || die "can't put $(basename "$out") together"
    stage_profile "$out" "$rules" "$(printf '%s\n' "${picks[@]}" | json_list)" "$min" <<< "$eps"
}

cmd_build() {
    local name="$1" dir profile conf tag why cmtu i min out eps setup files=() written=" "
    local tags=() unit_eps=() unit_rules=() unit_mtu=() used=() members=()
    local carrier_names=" " cidrs_seen=" " keys=" " k
    dir=$(device_dir "$name" build) || exit 1
    setup="$HERE/singbox.sh new $name"; [ "$name" = "$MAC" ] && setup="install.sh"
    [ -d "$dir" ] || die "no device $dir ($setup)"
    command -v jq >/dev/null || die "jq missing (install.sh --sing-box, or brew install jq)"
    profile="$dir/warp/wgcf-profile.conf"
    [ -f "$profile" ] || die "no WARP profile in $dir/warp ($setup)"
    why=$(unusable "$profile"); [ -z "$why" ] || die "WARP profile $profile: $why"

    echo "== Sweep $dir/carriers"
    WARP_ENDPOINT="$WARP_ENDPOINT" SWEEP_FOR_SINGBOX=1 "$HERE/wgwarp-sweep.sh" "$dir" || die "sweep failed"
    echo

    shopt -s nullglob
    # Only carriers build could use: a broken one (the sweep skipped it) leaves
    # its old warped.*.conf without a carrier, so it isn't built from that
    for conf in "$dir"/carriers/*.conf; do
        [ -z "$(unusable "$conf")" ] && carrier_names+="$(warped_name "$conf") "
    done
    # Warped first: the composite's default (first) tunnel is a warped one when there is one
    files=("$dir"/config/warped.*.conf)
    for conf in "$dir"/config/*.conf; do
        case "$(basename "$conf")" in warped.*) ;; *) files+=("$conf") ;; esac
    done
    for conf in "${files[@]}"; do
        tag=$(basename "$conf" .conf)
        why=$(unusable "$conf")
        if [ -n "$why" ]; then echo "skipped $tag: $why"; continue; fi
        cmtu=$(conf_val "$conf" MTU); cmtu="${cmtu:-1420}"
        case "$tag" in
            warped.*)
                case "$carrier_names" in
                    *" $tag "*) add_warped "$conf" "$tag" "$cmtu" "$profile" ;;
                    *) echo "skipped $tag: no usable carrier for it in carriers/ (delete it if that's for good)"; continue ;;
                esac ;;
            *)  add_plain "$conf" "$tag" "$cmtu" ;;
        esac
        used+=("$conf")
    done
    [ ${#tags[@]} -gt 0 ] || die "nothing to build: put configs in $dir/carriers or $dir/config"
    add_warp "$profile"
    check_keys "$dir" "${used[@]}" "$profile"
    check_tags "$name"

    out="$dir/sing-box"
    mkdir -p "$out" && chmod 700 "$out" || die "can't create $out"
    echo "== Profiles in $out"
    # One per tunnel, with the configs' keepalives: only one runs at a time
    for i in "${!tags[@]}"; do
        out="${tags[i]}.json"
        # <<<, not a pipe: stage_profile records its temp file in this shell
        stage_profile "$dir/sing-box/$out" "${unit_rules[i]}" \
            "$(echo "${tags[i]}" | json_list)" "${unit_mtu[i]}" <<< "${unit_eps[i]}"
        written+="$out "
    done
    # The composite: every tunnel
    out="composite.$name.json"
    stage_group "$dir/sing-box/$out" "${!tags[@]}"
    written+="$out "
    # Groups: <server>.all.<device> for a server's tunnels, local.all.<device>
    # for the local ones (warped, local.*, warp). Only with two or more.
    for i in "${!tags[@]}"; do
        k=$(group_key "${tags[i]}")
        case "$keys" in *" $k "*) ;; *) keys+="$k " ;; esac
    done
    for k in $keys; do
        members=()
        for i in "${!tags[@]}"; do
            [ "$(group_key "${tags[i]}")" = "$k" ] && members+=("$i")
        done
        [ ${#members[@]} -ge 2 ] || continue
        out="$k.all.$name.json"
        stage_group "$dir/sing-box/$out" "${members[@]}"
        written+="$out "
    done
    commit_profiles
    # Profiles no longer built (a tunnel or a group gone)
    for out in "$dir"/sing-box/*.json; do
        case "$written" in *" $(basename "$out") "*) continue ;; esac
        rm -f "$out" && printf '%-44s %s\n' "$(basename "$out")" "removed (no longer built)"
    done
    command -v sing-box >/dev/null || echo "(not checked: sing-box isn't installed on this Mac)"

    echo
    if [ "$name" = "$MAC" ]; then
        echo "Next: import the profiles you want in the sing-box app on this Mac"
        echo "      (Profiles > New Profile > Import). They use the daemon's keys: run"
        echo "      tunnel.sh down before turning sing-box on, and turn sing-box off"
        echo "      before tunnel.sh up. sing-box has no kill switch once it stops."
        return
    fi
    echo "Next: AirDrop the profiles you want to the device and import each in sing-box"
    echo "      (Profiles > New Profile > Import). The composite (every tunnel) and the"
    echo "      .all. groups (one server's, or the local ones) switch tunnels in the app's"
    echo "      picker without dropping the VPN; a one-tunnel profile switches by switching"
    echo "      profiles. They hold private keys: delete the copies you send."
}

cmd_list() {
    local dir name
    shopt -s nullglob
    set -- "$TUNNELS_DIR"/*/
    [ $# -gt 0 ] || { echo "no devices yet ($HERE/singbox.sh new <device>)"; return; }
    printf '%-20s %-9s %-8s %-5s %s\n' DEVICE CARRIERS TUNNELS WARP PROFILES
    for dir; do
        name=$(basename "$dir"); [ "$name" = "$MAC" ] && name+=" (this Mac)"
        printf '%-20s %-9s %-8s %-5s %s\n' "$name" \
            "$(count "$dir"carriers/*.conf)" "$(count "$dir"config/*.conf)" \
            "$([ -f "${dir}warp/wgcf-profile.conf" ] && echo yes || echo no)" \
            "$(count "$dir"sing-box/*.json)"
    done
}

case "$1" in
    new|build|list) old_layout ;;
esac
case "$1" in
    new)   cmd_new "$2" ;;
    build) cmd_build "$2" ;;
    list)  cmd_list ;;
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0" ;;
    *)     sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 1 ;;
esac
