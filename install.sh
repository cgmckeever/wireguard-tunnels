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
#                 Homebrew packages wireguard-tools, wgcf, jq and qrencode;
#                 this Mac's device folder $WG_TUNNELS/devices/<name> (default
#                 ~/wg-tunnels; asked the first time, then kept in devices/.default);
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
#                 Only what Sing-Box Device Tunnels need: wgcf, jq (nord.sh),
#                 qrencode (qr.sh), the store's devices/ and a first device
#                 (asked, or --device; singbox.sh new makes more). No Local Mac Tunnels: no
#                 WARP account for this Mac, no daemon, no sudo. Run it again
#                 without --sing-box to add Local Mac Tunnels later
#
# The WARP endpoint comes from <store>/devices/<device>/.warp-endpoint, else
# <store>/.warp-endpoint (IPv4:port), else Cloudflare's default.

set -u

REPO=$(dirname "$(readlink -f "$0")")
SELF="$REPO/install.sh"; . "$REPO/scripts/_lib.sh"   # WG_TUNNELS, DEVICES, DEFAULT_FILE, MAC, die, usage
SWIFTBAR_APP="/Applications/SwiftBar.app"
SWIFTBAR_AGENT="$HOME/Library/LaunchAgents/com.local.swiftbar.plist"

swiftbar=0 daemon=1 device="" singbox_only=0 opts=$#
while [ $# -gt 0 ]; do
    case "$1" in
        --swiftbar)  swiftbar=1 ;;
        --no-daemon) daemon=0 ;;
        --sing-box)  singbox_only=1 ;;
        --device)    [ -n "${2:-}" ] && [[ "$2" != -* ]] || die "--device needs a name (see --help)"
                     device="$2"; shift ;;
        --device=*)  device="${1#--device=}"; [ -n "$device" ] || die "--device needs a name (see --help)" ;;
        -h|--help)   usage; exit 0 ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
done

ok() { printf '  ok       %s\n' "$*"; }
changed() { printf '  changed  %s\n' "$*"; }
# The store's own steps, done by the code the sweep and singbox.sh use (wgtun/forinstall.py)
forinstall() { PYTHONPATH="$REPO${PYTHONPATH:+:$PYTHONPATH}" python3 -m wgtun.forinstall "$@"; }

[ "$(uname -s)" = Darwin ] || die "macOS only"
[ "$(id -u)" -ne 0 ] || die "Run as your user, not root (Homebrew refuses root); it uses sudo where needed"
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
# (Local Mac Tunnels); wgcf makes WARP accounts; jq reads Nord's API (nord.sh);
# qrencode shows a tunnel as a QR for the WireGuard app (scripts/qr.sh)
pkgs="wgcf jq qrencode"
[ "$singbox_only" = 1 ] || pkgs="wireguard-tools $pkgs"
for pkg in $pkgs; do
    if brew list --formula "$pkg" >/dev/null 2>&1; then
        ok "$pkg"
    else
        brew install "$pkg" || die "brew install $pkg failed"
        changed "$pkg installed"
    fi
done

echo "== $WG_TUNNELS"

if [ "$singbox_only" = 1 ]; then
    forinstall folders "$WG_TUNNELS" "$DEVICES" || exit 1
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

# This Mac's device: --device, else devices/.default, else ask
existing=$(folders "$DEVICES" | paste -sd' ' -)
[ -n "$device" ] || device=$MAC
if [ -z "$device" ]; then
    [ -t 0 ] || die "This Mac's device name, please: ./install.sh --device <name> (e.g. mbp-1, the name its wg-tools configs end in)"
    [ -n "$existing" ] && echo "  device folders: $existing"
    read -rp "  This Mac's device name (a folder in $DEVICES; e.g. mbp-1, the name its wg-tools configs end in): " device
fi
forinstall device-name "$device" || exit 1
# A new folder means a new WARP account and warp.conf: a typo for an existing
# device shouldn't do that quietly
if [ ! -d "$DEVICES/$device" ] && [ -n "$existing" ] && [ -t 0 ]; then
    read -rp "  $device is a new device folder (with a new WARP account), next to: $existing. Create it? [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]] || die "Nothing changed"
fi
DEV_DIR="$DEVICES/$device"
WARP_DIR="$DEV_DIR/warp"
# The WARP endpoint (see the header), read by the same code as the sweep's so
# this Mac's WARP and its config/ agree: checked now, before anything changes
forinstall warp-endpoint "$DEV_DIR" > /dev/null || exit 1

umask 077    # until warp.conf is written: everything here holds private keys
# 0700: everything in the store holds private keys
#   devices/         one folder per device; .default names this Mac's
#     <device>/      this Mac's tunnels (other devices' sit beside it: singbox.sh new)
#       carriers/    WireGuard configs to carry WARP (wgwarp-sweep.sh)
#       config/      every tunnel's .conf: what tunnel.sh import installs
#       exports/     WireGuard app "Export Tunnels to Zip" (every private key, plain text)
#       warp/        the wgcf WARP account and profile
#       sing-box/    profiles from singbox.sh build, if you use sing-box here
forinstall folders "$WG_TUNNELS" "$DEVICES" "$DEV_DIR" "$DEV_DIR/carriers" "$DEV_DIR/config" \
    "$DEV_DIR/exports" "$WARP_DIR" || exit 1
if [ "$(cat "$DEFAULT_FILE" 2>/dev/null)" = "$device" ]; then
    ok "default device $device"
else
    printf '%s\n' "$device" > "$DEFAULT_FILE" && chmod 644 "$DEFAULT_FILE" || die "Can't write $DEFAULT_FILE"
    changed "default device $device ($DEFAULT_FILE; tunnel.sh default changes it)"
fi

echo "== Cloudflare WARP"
# This Mac's free WARP account, created once in its device's warp/ (every
# other device has its own: singbox.sh new), then warp.conf for wg-quick from it
forinstall warp-account "$DEV_DIR" || exit 1
forinstall daemon-warp "$DEV_DIR" "$BREW_PREFIX/etc/wireguard/warp.conf" || exit 1
umask 022

if [ "$daemon" = 1 ]; then
    echo "== daemon"
    # tunnel.sh update installs it only when it's missing or differs from the
    # repo copy: installing restarts the daemon (a tunnel that's up drops for a few seconds)
    "$REPO/scripts/tunnel.sh" update | sed 's/^/  /'
    [ "${PIPESTATUS[0]}" -eq 0 ] || die "Daemon install failed"
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
    other=$(grep -l "$SWIFTBAR_APP" "$HOME"/Library/LaunchAgents/*.plist 2>/dev/null | grep -vxF "$SWIFTBAR_AGENT" | head -1)
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
echo "  put tunnel .conf files in $DEV_DIR/config, and carriers in $DEV_DIR/carriers"
echo "  $REPO/scripts/tunnel.sh import   (sweeps carriers/ first)"
echo "  $REPO/scripts/tunnel.sh up"
echo "  other devices (iPhone, Apple TV): $REPO/scripts/singbox.sh new <device>"
