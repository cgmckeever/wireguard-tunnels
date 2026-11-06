#!/bin/bash
# singbox.sh — warped tunnels for devices that run sing-box (iPhone, iPad,
# Apple TV, Android...), where the daemon can't.
#
# The WireGuard app on those can't carry one tunnel inside another. sing-box
# (App Store: "sing-box VT") can: its WireGuard endpoints take a detour, so WARP
# rides inside the carrier, in one VPN. This builds that profile.
#
# Usage:
#   singbox.sh new <device>      make ~/wg-tunnels/sing-box/<device>/ and its own WARP account
#   singbox.sh build <device>    sweep its carriers, write config/sing-box.json
#   singbox.sh list              the devices and what each has
#
# ~/wg-tunnels/sing-box/<device>/   (0700, it all holds private keys)
#   carriers/   the device's own WireGuard configs to carry WARP (e.g. Proton,
#               made for this device: a key shared with another makes both drop)
#   warp/       the device's own wgcf WARP account and profile (same reason)
#   config/     what build writes: warped.<carrier>.conf (wgwarp-sweep.sh
#               --sing-box) and sing-box.json, the profile to import
#
# Override with TUNNELS_DIR (default ~/wg-tunnels) and WARP_ENDPOINT.

set -o pipefail
TUNNELS_DIR="${TUNNELS_DIR:-$HOME/wg-tunnels}"
SINGBOX_DIR="$TUNNELS_DIR/sing-box"
WARP_ENDPOINT="${WARP_ENDPOINT:-162.159.192.1}"
WARP_PORT=2408
HERE="$(cd "$(dirname "$0")" && pwd)"

umask 077
die() { echo "singbox.sh: $*" >&2; exit 1; }

device_dir() {
    [ -n "$1" ] || die "a device name, please (singbox.sh $2 <device>)"
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "device names are letters, digits, . _ -"
    echo "$SINGBOX_DIR/$1"
}

cmd_new() {
    local dir d
    dir=$(device_dir "$1" new) || exit 1
    for d in "$TUNNELS_DIR" "$SINGBOX_DIR" "$dir" "$dir/carriers" "$dir/warp" "$dir/config"; do
        mkdir -p "$d" && chmod 700 "$d" || die "can't create $d"
    done
    command -v wgcf >/dev/null || die "wgcf missing (install.sh, or brew install wgcf)"
    if [ -f "$dir/warp/wgcf-account.toml" ]; then
        echo "WARP account: already there"
    else
        (cd "$dir/warp" && wgcf register --accept-tos) || die "wgcf register failed"
        echo "WARP account: registered"
    fi
    chmod 600 "$dir/warp/wgcf-account.toml"
    if [ ! -f "$dir/warp/wgcf-profile.conf" ]; then
        (cd "$dir/warp" && wgcf generate) || die "wgcf generate failed"
    fi
    chmod 600 "$dir/warp/wgcf-profile.conf"
    echo
    echo "Next: put this device's carrier configs in ${dir}/carriers/"
    echo "      (Proton: account.proton.me > Downloads > WireGuard configuration, a new one named $1)"
    echo "then: singbox.sh build $1"
}

# conf_val <file> <Key>: the first value (everything after the first "=", keys
# end in base64 "=" padding)
conf_val() {
    sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p" "$1" | head -1
}
# conf_list <file> <Key>: every value of every <Key> line, one per line
conf_list() {
    sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$1" \
        | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep .
}
json_list() { jq -R . | jq -sc .; }

# carrier_json <conf> <tag>: a sing-box WireGuard endpoint from a swept config
carrier_json() {
    local conf="$1" ep host port mtu psk ka
    ep=$(conf_val "$conf" Endpoint)
    host="${ep%:*}"; host="${host#[}"; host="${host%]}"; port="${ep##*:}"
    mtu=$(conf_val "$conf" MTU); mtu="${mtu:-1420}"
    psk=$(conf_val "$conf" PresharedKey)
    ka=$(conf_val "$conf" PersistentKeepalive)
    jq -n --arg tag "$2" --arg key "$(conf_val "$conf" PrivateKey)" \
        --argjson address "$(conf_list "$conf" Address | json_list)" \
        --argjson mtu "$mtu" --arg host "$host" --argjson port "$port" \
        --arg pub "$(conf_val "$conf" PublicKey)" --arg psk "$psk" \
        --argjson allowed "$(conf_list "$conf" AllowedIPs | json_list)" \
        --argjson ka "${ka:-0}" '
        { type: "wireguard", tag: $tag, mtu: $mtu, address: $address, private_key: $key,
          peers: [ { address: $host, port: $port, public_key: $pub, allowed_ips: $allowed }
                   + (if $psk != "" then { pre_shared_key: $psk } else {} end)
                   + (if $ka > 0 then { persistent_keepalive_interval: $ka } else {} end) ] }'
}

# warp_json <profile> <tag> <carrier tag> <mtu>: WARP, carried by the carrier.
# No keepalive: every warped endpoint shares the device's one WARP key, so only
# the one in use should talk to Cloudflare.
warp_json() {
    jq -n --arg tag "$2" --arg detour "$3" --argjson mtu "$4" \
        --arg key "$(conf_val "$1" PrivateKey)" \
        --argjson address "$(conf_list "$1" Address | json_list)" \
        --arg host "$WARP_ENDPOINT" --argjson port "$WARP_PORT" \
        --arg pub "$(conf_val "$1" PublicKey)" '
        { type: "wireguard", tag: $tag, mtu: $mtu, address: $address, private_key: $key,
          detour: $detour,
          peers: [ { address: $host, port: $port, public_key: $pub,
                     allowed_ips: ["0.0.0.0/0", "::/0"] } ] }'
}

cmd_build() {
    local dir name profile conf src carrier tag cmtu wmtu min_mtu=9000 out tmp
    local endpoints=() tags=()
    name="$1"
    dir=$(device_dir "$1" build) || exit 1
    [ -d "$dir" ] || die "no device $1 (singbox.sh new $1)"
    command -v jq >/dev/null || die "jq missing (brew install jq)"
    profile="$dir/warp/wgcf-profile.conf"
    [ -f "$profile" ] || die "no WARP profile in $dir/warp (singbox.sh new $1)"

    echo "== Sweep ${dir}/carriers"
    TUNNELS_DIR="$TUNNELS_DIR" WARP_ENDPOINT="$WARP_ENDPOINT" "$HERE/wgwarp-sweep.sh" --sing-box "$name" || die "sweep failed"

    shopt -s nullglob
    for conf in "$dir"/config/warped.*.conf; do
        tag=$(basename "$conf" .conf)          # warped.<carrier>
        # Only carriers still in carriers/: the sweep leaves an orphan's file in place
        src="$dir/carriers/${tag#warped.}"
        [ -f "$src.conf" ] || [ -f "$dir/carriers/$tag.conf" ] \
            || [ -f "$dir/carriers/warped-${tag#warped.}.conf" ] || continue
        carrier="carrier.${tag#warped.}"
        cmtu=$(conf_val "$conf" MTU); cmtu="${cmtu:-1420}"
        # A WARP packet is up to 80 bytes bigger inside the carrier
        wmtu=$((cmtu - 80))
        [ "$wmtu" -lt "$min_mtu" ] && min_mtu=$wmtu
        endpoints+=("$(carrier_json "$conf" "$carrier")") || die "can't read $conf"
        endpoints+=("$(warp_json "$profile" "$tag" "$carrier" "$wmtu")") || die "can't read $profile"
        tags+=("$tag")
    done
    [ ${#tags[@]} -gt 0 ] || die "nothing to build: put carrier configs in $dir/carriers"

    out="$dir/config/sing-box.json"
    tmp=$(mktemp "$dir/config/.sing-box.XXXXXX") || die "mktemp failed"
    # Everything goes through the picked tunnel, DNS included (1.1.1.1 via
    # WARP); strict_route keeps traffic in the VPN, the nearest sing-box gets
    # to the kill switch
    printf '%s\n' "${endpoints[@]}" | jq -s \
        --argjson tags "$(printf '%s\n' "${tags[@]}" | json_list)" \
        --argjson mtu "$min_mtu" '
        { log: { level: "warn" },
          dns: { servers: [ { type: "udp", tag: "cloudflare", server: "1.1.1.1", detour: "tunnel" } ],
                 final: "cloudflare" },
          inbounds: [ { type: "tun", tag: "tun-in", address: ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                        mtu: $mtu, auto_route: true, strict_route: true } ],
          endpoints: .,
          outbounds: [ { type: "selector", tag: "tunnel", outbounds: $tags, default: $tags[0] } ],
          route: { auto_detect_interface: true, final: "tunnel",
                   rules: [ { inbound: "tun-in", action: "sniff" },
                            { protocol: "dns", action: "hijack-dns" } ] } }' > "$tmp" \
        || { rm -f "$tmp"; die "can't write the profile"; }
    if [ -f "$out" ] && cmp -s "$tmp" "$out"; then
        rm -f "$tmp"; echo; echo "sing-box.json unchanged"
    else
        mv "$tmp" "$out"; echo; echo "sing-box.json written: ${#tags[@]} tunnel(s), ${tags[*]}"
    fi
    if command -v sing-box >/dev/null; then
        sing-box check -c "$out" && echo "sing-box check: ok"
    fi
    echo
    echo "Next: get ${out} to the device (AirDrop, iCloud Drive) and import it in sing-box"
    echo "      (Profiles > New Profile > Import). It holds private keys: delete the copy after."
}

cmd_list() {
    local dir n c
    shopt -s nullglob
    for dir in "$SINGBOX_DIR"/*/; do
        n=$(basename "$dir")
        c=$(ls "$dir"carriers/*.conf 2>/dev/null | wc -l | tr -d ' ')
        printf '%-16s carriers %-3s warp %-4s profile %s\n' "$n" "$c" \
            "$([ -f "$dir/warp/wgcf-profile.conf" ] && echo yes || echo no)" \
            "$([ -f "$dir/config/sing-box.json" ] && echo yes || echo no)"
    done
}

case "$1" in
    new)   cmd_new "$2" ;;
    build) cmd_build "$2" ;;
    list)  cmd_list ;;
    *)     sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 1 ;;
esac
