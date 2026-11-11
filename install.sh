#!/bin/bash
# install.sh — install what wireguard-tunnels needs on macOS, and the daemon.
# Safe to re-run: every step checks first and only changes what's missing or
# out of date. Each step prints "ok" or "changed".
#
# Usage:
#   ./install.sh [--device <name>] [--swiftbar] [--no-daemon]
#   ./install.sh --sing-box [--device <name>]
#
#   With no options, in a terminal, on a Mac without Local Mac Tunnels yet, it
#   asks which: 1) Full Local Mac Tunnels (the default), 2) Only Sing-Box Device
#   Tunnels; after 1, whether to add the menu bar lock (--swiftbar). Any
#   option, or no terminal, skips the questions.
#
#   (default)     Local Mac Tunnels, and what Sing-Box Device Tunnels need too.
#                 Homebrew packages wireguard-tools, wgcf, jq and qrencode; this Mac's device
#                 folder ~/wg-tunnels/devices/<name> (asked the first time, then
#                 kept in ~/wg-tunnels/devices/.default);
#                 a Cloudflare WARP account and $(brew --prefix)/etc/wireguard/warp.conf;
#                 the daemon (/usr/local/sbin/wg-tunnels + LaunchDaemon, sudo)
#   --device <name>
#                 This Mac's device name, without asking (e.g. mbp-1: the name
#                 its wg-tools configs end in). Needed the first time when
#                 there's no terminal to ask in (Ansible)
#   --swiftbar    Also the menu bar lock: SwiftBar, the tunnel-status plugin
#                 (a symlink into SwiftBar's plugin folder) and a LaunchAgent
#                 that keeps SwiftBar running (skipped if one already does)
#   --no-daemon   Skip the daemon step (e.g. Ansible runs it separately with
#                 become: scripts/tunnel.sh _install <path/to/scripts/tunnel.sh>)
#   --sing-box [--device <name>]
#                 Only what building sing-box profiles needs (singbox.sh): wgcf,
#                 jq (and qrencode, for qr.sh), ~/wg-tunnels/devices and a first device (asked, or
#                 --device; singbox.sh new makes more). No Local Mac Tunnels: no
#                 WARP account for this Mac, no daemon, no sudo. Run it again
#                 without --sing-box to add Local Mac Tunnels later
#
# The WARP endpoint comes from ~/wg-tunnels/.warp-endpoint (IPv4:port; default
# 162.159.192.1:2408).

set -u

REPO="$(cd "$(dirname "$0")" && pwd)"
TUNNELS_DIR="$HOME/wg-tunnels"
DEVICES="$TUNNELS_DIR/devices"         # one folder per device
DEFAULT_FILE="$DEVICES/.default"       # this Mac's device (tunnel.sh default)
INSTALLED="/usr/local/sbin/wg-tunnels"
PLIST="/Library/LaunchDaemons/com.local.wg-tunnels.plist"
SWIFTBAR_APP="/Applications/SwiftBar.app"
SWIFTBAR_AGENT="$HOME/Library/LaunchAgents/com.local.swiftbar.plist"

swiftbar=0 daemon=1 device="" singbox_only=0 opts=$#
while [ $# -gt 0 ]; do
    case "$1" in
        --swiftbar)  swiftbar=1 ;;
        --no-daemon) daemon=0 ;;
        --sing-box)  singbox_only=1 ;;
        --device)    [ -n "${2:-}" ] || { echo "--device needs a name (see --help)" >&2; exit 1; }
                     device="$2"; shift ;;
        --device=*)  device="${1#--device=}" ;;
        -h|--help)   sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
    esac
    shift
done

die() { echo "$*" >&2; exit 1; }
ok() { printf '  ok       %s\n' "$*"; }
changed() { printf '  changed  %s\n' "$*"; }

[ "$(uname -s)" = Darwin ] || die "macOS only"
# Which install, when nothing says: only asked before Local Mac Tunnels are
# set up (no .default yet), so re-runs after a git pull don't ask
if [ "$opts" = 0 ] && [ -t 0 ] && [ ! -f "$DEFAULT_FILE" ]; then
    echo "Install:"
    echo "  1) Full Local Mac Tunnels (this Mac's traffic; sing-box devices too)"
    echo "  2) Only Sing-Box Device Tunnels (phones, Apple TV: no daemon, no sudo)"
    read -rp "Choice [1]: " answer
    case "${answer:-1}" in
        1) read -rp "Menu bar lock (SwiftBar: shows whether you're protected, switches tunnels)? [Y/n] " answer
           [[ "$answer" =~ ^[Nn] ]] || swiftbar=1 ;;
        2) singbox_only=1 ;;
        *) die "1 or 2, please" ;;
    esac
fi
[ "$singbox_only" = 0 ] || { [ "$swiftbar" = 0 ] && [ "$daemon" = 1 ]; } \
    || die "--sing-box takes only --device: it sets up no Local Mac Tunnels"
# The WARP endpoint: ~/wg-tunnels/.warp-endpoint (one line, IPv4:port), else
# Cloudflare's default. A file, not a variable, so the menu bar sees it too.
WARP_ENDPOINT=162.159.192.1:2408
[ -f "$TUNNELS_DIR/.warp-endpoint" ] && WARP_ENDPOINT=$(tr -d ' \t\r\n' < "$TUNNELS_DIR/.warp-endpoint")
[[ "$WARP_ENDPOINT" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+$ ]] \
    || die "~/wg-tunnels/.warp-endpoint: IPv4:port, e.g. 162.159.192.1:2408 (not $WARP_ENDPOINT)"
[ "$(id -u)" -ne 0 ] || die "Run as your user, not root (Homebrew refuses root); it uses sudo where needed"

echo "== Homebrew"
if ! command -v brew >/dev/null 2>&1; then
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -x "$b" ] && eval "$("$b" shellenv)" && break
    done
fi
command -v brew >/dev/null 2>&1 || die "Homebrew is required. Install it (https://brew.sh):
  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
then run ./install.sh again."
BREW_PREFIX="$(brew --prefix)"
ok "brew ($BREW_PREFIX)"

# wireguard-tools brings wg, wg-quick, wireguard-go and the bash wg-quick needs
# (Local Mac Tunnels); wgcf makes WARP accounts; jq writes sing-box profiles;
# qrencode shows a tunnel as a QR for the WireGuard app (scripts/qr.sh)
pkgs="wireguard-tools wgcf jq qrencode"
[ "$singbox_only" = 1 ] && pkgs="wgcf jq qrencode"
for pkg in $pkgs; do
    if brew list --formula "$pkg" >/dev/null 2>&1; then
        ok "$pkg"
    else
        brew install "$pkg" || die "brew install $pkg failed"
        changed "$pkg installed"
    fi
done

echo "== ~/wg-tunnels"

if [ "$singbox_only" = 1 ]; then
    for d in "$TUNNELS_DIR" "$DEVICES"; do
        if [ -d "$d" ] && [ "$(stat -f %Lp "$d")" = 700 ]; then
            ok "$d"
        else
            mkdir -p "$d" && chmod 700 "$d" || die "Can't create $d"
            changed "$d"
        fi
    done
    if [ -z "$device" ] && [ -t 0 ]; then
        read -rp "  First sing-box device name (e.g. iphone; Enter to skip): " device
    fi
    echo
    if [ -n "$device" ]; then
        echo "== device $device"
        "$REPO/scripts/singbox.sh" new "$device" || die "singbox.sh new $device failed"
    else
        echo "Done (Sing-Box Device Tunnels only). Next:"
        echo "  $REPO/scripts/singbox.sh new <device>      e.g. iphone"
        echo "  put its configs in $DEVICES/<device>/carriers (or config)"
        echo "  $REPO/scripts/singbox.sh build <device>"
    fi
    echo "Local Mac Tunnels later: $REPO/install.sh (without --sing-box)"
    exit 0
fi

# This Mac's device: --device, else ~/wg-tunnels/devices/.default, else ask
valid_name() { [[ "$1" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]]; }
existing=$(cd "$DEVICES" 2>/dev/null && ls -d */ 2>/dev/null | tr -d / | paste -sd' ' -)
[ -n "$device" ] || device=$(cat "$DEFAULT_FILE" 2>/dev/null)
if [ -z "$device" ]; then
    [ -t 0 ] || die "This Mac's device name, please: ./install.sh --device <name> (e.g. mbp-1, the name its wg-tools configs end in)"
    [ -n "$existing" ] && echo "  device folders: $existing"
    read -rp "  This Mac's device name (a folder in ~/wg-tunnels/devices; e.g. mbp-1, the name its wg-tools configs end in): " device
fi
valid_name "$device" || die "Device names are letters, digits, . _ - (not starting with .): $device"
# A new folder means a new WARP account and warp.conf: a typo for an existing
# device shouldn't do that quietly
if [ ! -d "$DEVICES/$device" ] && [ -n "$existing" ] && [ -t 0 ]; then
    read -rp "  $device is a new device folder (with a new WARP account), next to: $existing. Create it? [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]] || die "Nothing changed"
fi
DEV_DIR="$DEVICES/$device"
WARP_DIR="$DEV_DIR/warp"

umask 077    # until warp.conf is written: everything here holds private keys
# 0700: everything under ~/wg-tunnels holds private keys
#   devices/         one folder per device; .default names this Mac's
#     <device>/      this Mac's tunnels (other devices' sit beside it: singbox.sh new)
#       carriers/    WireGuard configs to carry WARP (wgwarp-sweep.sh)
#       config/      every tunnel's .conf: what tunnel.sh import installs
#       exports/     WireGuard app "Export Tunnels to Zip" (every private key, plain text)
#       warp/        the wgcf WARP account and profile
#       sing-box/    profiles from singbox.sh build, if you use sing-box here
for d in "$TUNNELS_DIR" "$DEVICES" "$DEV_DIR" "$DEV_DIR/carriers" "$DEV_DIR/config" "$DEV_DIR/exports" "$WARP_DIR"; do
    if [ -d "$d" ] && [ "$(stat -f %Lp "$d")" = 700 ]; then
        ok "$d"
    else
        mkdir -p "$d" && chmod 700 "$d" || die "Can't create $d"
        changed "$d"
    fi
done
if [ "$(cat "$DEFAULT_FILE" 2>/dev/null)" = "$device" ]; then
    ok "default device $device"
else
    printf '%s\n' "$device" > "$DEFAULT_FILE" && chmod 644 "$DEFAULT_FILE" || die "Can't write $DEFAULT_FILE"
    changed "default device $device ($DEFAULT_FILE; tunnel.sh default changes it)"
fi

echo "== Cloudflare WARP"
# This Mac's free WARP account, created once in its device's warp/ (every
# other device has its own: singbox.sh new)
if [ -f "$WARP_DIR/wgcf-account.toml" ]; then
    ok "account"
else
    (cd "$WARP_DIR" && wgcf register --accept-tos) || die "wgcf register failed"
    rm -f "$WARP_DIR/wgcf-profile.conf"     # one left from an earlier account
    changed "account registered"
fi
if [ -f "$WARP_DIR/wgcf-profile.conf" ]; then
    ok "profile"
else
    (cd "$WARP_DIR" && wgcf generate) || die "wgcf generate failed"
    changed "profile generated"
fi
# The account (its API token) and the profile (its private key): owner only,
# whatever wgcf wrote them as
for f in "$WARP_DIR/wgcf-account.toml" "$WARP_DIR/wgcf-profile.conf"; do
    if [ "$(stat -f %Lp "$f")" != 600 ]; then
        chmod 600 "$f"
        changed "$f 0600"
    fi
done

# warp.conf for wg-quick, from the wgcf profile
profile="$WARP_DIR/wgcf-profile.conf"
# conf_val <Key>: the value after the first "=", up to whitespace (an awk split
# on "=" would drop the keys' base64 "=" padding)
conf_val() { sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p" "$profile" | head -1; }
private_key=$(conf_val PrivateKey)
public_key=$(conf_val PublicKey)
# wgcf writes one Address line per family
addresses=$(awk -F'[[:space:]]*=[[:space:]]*' '$1 == "Address" {print $2}' "$profile" \
    | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep . | paste -sd, - | sed 's/,/, /g')
[ -n "$private_key" ] && [ -n "$public_key" ] && [ -n "$addresses" ] \
    || die "Can't read PrivateKey/PublicKey/Address from $profile"

warp_conf="$BREW_PREFIX/etc/wireguard/warp.conf"
mkdir -p "$BREW_PREFIX/etc/wireguard" && chmod 700 "$BREW_PREFIX/etc/wireguard"
umask 077
tmp=$(mktemp "$BREW_PREFIX/etc/wireguard/.warp.XXXXXX") || die "mktemp failed"
cat > "$tmp" <<EOF
# Written by wireguard-tunnels install.sh from ~/wg-tunnels/devices/${device}/warp/wgcf-profile.conf.
#
# Cloudflare WARP exit, carried inside another WireGuard tunnel (warped.*). \`tunnel.sh import\`
# copies it for the wg-tunnels daemon, which does the
# routing; don't bring it up on its own. Table = off skips wg-quick's routing,
# which would send the endpoint straight out the NIC, around the carrier.
[Interface]
PrivateKey = ${private_key}
Address = ${addresses}
DNS = 1.1.1.1
# IPv6's minimum: fits in a carrier of 1360 or more (tunnel.sh lowers it in a smaller one)
MTU = 1280
Table = off

[Peer]
PublicKey = ${public_key}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${WARP_ENDPOINT}
# A stale handshake then means trouble, not idleness (the daemon's watchdog)
PersistentKeepalive = 25
EOF
chmod 600 "$tmp"
if [ -f "$warp_conf" ] && cmp -s "$tmp" "$warp_conf"; then
    rm -f "$tmp"
    ok "$warp_conf"
else
    mv -f "$tmp" "$warp_conf"
    changed "$warp_conf (tunnel.sh import to pass it to the daemon)"
fi
umask 022

if [ "$daemon" = 1 ]; then
    echo "== daemon"
    # Only when missing or different from the repo copy: installing restarts the
    # daemon (a tunnel that's up drops for a few seconds)
    if cmp -s "$REPO/scripts/tunnel.sh" "$INSTALLED" && [ -f "$PLIST" ]; then
        ok "$INSTALLED"
    else
        sudo "$REPO/scripts/tunnel.sh" _install "$REPO/scripts/tunnel.sh" || die "Daemon install failed"
        changed "$INSTALLED and $PLIST"
    fi
fi

if [ "$swiftbar" = 1 ]; then
    echo "== SwiftBar"
    if [ -d "$SWIFTBAR_APP" ]; then
        ok "$SWIFTBAR_APP"
    else
        brew install --cask swiftbar || die "brew install --cask swiftbar failed"
        changed "SwiftBar installed"
    fi

    plugins=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null)
    if [ -n "$plugins" ]; then
        ok "plugin folder $plugins"
    else
        plugins="$HOME/.config/swiftbar"
        defaults write com.ameba.SwiftBar PluginDirectory -string "$plugins"
        changed "plugin folder $plugins"
    fi
    mkdir -p "$plugins"

    # A symlink: the plugin finds the repo through it, and repo updates show
    # up without re-installing. Replaces a copied plugin of the same name.
    link="$plugins/tunnel-status.5s.sh"
    target="$REPO/scripts/swiftbar/tunnel-status.5s.sh"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
        ok "$link"
    else
        rm -f "$link" && ln -s "$target" "$link" || die "Can't link $link"
        changed "$link -> $target"
    fi

    # Keep SwiftBar running: launchd restarts it when it crashes or is killed
    # (quitting it from its menu leaves it quit until the next login). Any
    # LaunchAgent that already runs SwiftBar is left to do that job: a second
    # one would start a second copy.
    other=$(grep -l "$SWIFTBAR_APP" "$HOME"/Library/LaunchAgents/*.plist 2>/dev/null | grep -vx "$SWIFTBAR_AGENT" | head -1)
    if [ -n "$other" ]; then
        ok "SwiftBar kept running by $other"
    else
        mkdir -p "$HOME/Library/LaunchAgents"
        tmp=$(mktemp "$HOME/Library/LaunchAgents/.swiftbar.XXXXXX") || die "mktemp failed"
        cat > "$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.swiftbar</string>
    <!-- SwiftBar at login, and again whenever it crashes or is killed.
         Quitting it from its menu (a clean exit) leaves it quit until the
         next login. Written by wireguard-tunnels install.sh. -->
    <key>ProgramArguments</key>
    <array>
        <string>${SWIFTBAR_APP}/Contents/MacOS/SwiftBar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
EOF
        chmod 644 "$tmp"
        if [ -f "$SWIFTBAR_AGENT" ] && cmp -s "$tmp" "$SWIFTBAR_AGENT" \
            && launchctl print "gui/$(id -u)/com.local.swiftbar" >/dev/null 2>&1; then
            rm -f "$tmp"
            ok "$SWIFTBAR_AGENT"
        else
            mv -f "$tmp" "$SWIFTBAR_AGENT"
            # A SwiftBar started some other way (open, Finder, a Login Item)
            # would be a second copy
            launchctl bootout "gui/$(id -u)/com.local.swiftbar" 2>/dev/null
            pkill -x SwiftBar
            sleep 1
            launchctl bootstrap "gui/$(id -u)" "$SWIFTBAR_AGENT" || die "launchctl bootstrap $SWIFTBAR_AGENT failed"
            changed "$SWIFTBAR_AGENT (loaded)"
        fi
    fi
fi

echo
echo "Done. Next:"
echo "  put tunnel .conf files in $DEV_DIR/config (or carriers in $DEV_DIR/carriers, then $REPO/scripts/wgwarp-sweep.sh)"
echo "  $REPO/scripts/tunnel.sh import"
echo "  $REPO/scripts/tunnel.sh up"
echo "  other devices (iPhone, Apple TV): $REPO/scripts/singbox.sh new <device>"
