#!/bin/bash
# install.sh — install what wireguard-tunnels needs on macOS, and the daemon.
# Safe to re-run: every step checks first and only changes what's missing or
# out of date. Each step prints "ok" or "changed".
#
# Usage:
#   ./install.sh [--swiftbar] [--no-daemon]
#
#   (default)     Homebrew packages wireguard-tools and wgcf; ~/wg-tunnels;
#                 a Cloudflare WARP account and $(brew --prefix)/etc/wireguard/warp.conf;
#                 the daemon (/usr/local/sbin/wg-tunnels + LaunchDaemon, sudo)
#   --swiftbar    Also the menu bar lock: SwiftBar, the tunnel-status plugin
#                 (a symlink into SwiftBar's plugin folder) and a LaunchAgent
#                 that keeps SwiftBar running (skipped if one already does)
#   --no-daemon   Skip the daemon step (e.g. Ansible runs it separately with
#                 become: scripts/tunnel.sh _install <path/to/scripts/tunnel.sh>)
#
# Override the WARP endpoint with WARP_ENDPOINT (default 162.159.192.1:2408).

set -u

REPO="$(cd "$(dirname "$0")" && pwd)"
TUNNELS_DIR="$HOME/wg-tunnels"
WARP_DIR="$TUNNELS_DIR/warp"
WARP_ENDPOINT="${WARP_ENDPOINT:-162.159.192.1:2408}"
INSTALLED="/usr/local/sbin/wg-tunnels"
PLIST="/Library/LaunchDaemons/com.local.wg-tunnels.plist"
SWIFTBAR_APP="/Applications/SwiftBar.app"
SWIFTBAR_AGENT="$HOME/Library/LaunchAgents/com.local.swiftbar.plist"

swiftbar=0 daemon=1
for arg in "$@"; do
    case "$arg" in
        --swiftbar)  swiftbar=1 ;;
        --no-daemon) daemon=0 ;;
        -h|--help)   sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (see --help)" >&2; exit 1 ;;
    esac
done

die() { echo "$*" >&2; exit 1; }
ok() { printf '  ok       %s\n' "$*"; }
changed() { printf '  changed  %s\n' "$*"; }

[ "$(uname -s)" = Darwin ] || die "macOS only"
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
for pkg in wireguard-tools wgcf; do
    if brew list --formula "$pkg" >/dev/null 2>&1; then
        ok "$pkg"
    else
        brew install "$pkg" || die "brew install $pkg failed"
        changed "$pkg installed"
    fi
done

echo "== ~/wg-tunnels"
# 0700: everything under ~/wg-tunnels holds private keys
#   carriers/  WireGuard configs to carry WARP (wgwarp-sweep.sh)
#   config/    every tunnel's .conf: what tunnel.sh import installs
#   exports/   WireGuard app "Export Tunnels to Zip" (every private key, plain text)
#   warp/      the wgcf WARP account and profile
for d in "$TUNNELS_DIR" "$TUNNELS_DIR/carriers" "$TUNNELS_DIR/config" "$TUNNELS_DIR/exports" "$WARP_DIR"; do
    if [ -d "$d" ] && [ "$(stat -f %Lp "$d")" = 700 ]; then
        ok "$d"
    else
        mkdir -p "$d" && chmod 700 "$d" || die "Can't create $d"
        changed "$d"
    fi
done

echo "== Cloudflare WARP"
# One free WARP account per machine, created once and kept in ~/wg-tunnels/warp
if [ -f "$WARP_DIR/wgcf-account.toml" ]; then
    ok "account"
else
    (cd "$WARP_DIR" && wgcf register --accept-tos) || die "wgcf register failed"
    changed "account registered"
fi
# wgcf writes the account (its API token) 0644
if [ "$(stat -f %Lp "$WARP_DIR/wgcf-account.toml")" != 600 ]; then
    chmod 600 "$WARP_DIR/wgcf-account.toml"
    changed "account file 0600"
fi
if [ -f "$WARP_DIR/wgcf-profile.conf" ]; then
    ok "profile"
else
    (cd "$WARP_DIR" && wgcf generate) || die "wgcf generate failed"
    changed "profile generated"
fi

# warp.conf for wg-quick, from the wgcf profile
profile="$WARP_DIR/wgcf-profile.conf"
val() { awk -F'[[:space:]]*=[[:space:]]*' -v k="$1" '$1 == k {print $2; exit}' "$profile"; }
private_key=$(val PrivateKey)
public_key=$(val PublicKey)
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
# Written by wireguard-tunnels install.sh from ~/wg-tunnels/warp/wgcf-profile.conf.
#
# Cloudflare WARP exit, carried inside another WireGuard tunnel (warped.*). \`tunnel.sh import\`
# copies it for the wg-tunnels daemon, which does the
# routing; don't bring it up on its own. Table = off skips wg-quick's routing,
# which would send the endpoint straight out the NIC, around the carrier.
[Interface]
PrivateKey = ${private_key}
Address = ${addresses}
DNS = 1.1.1.1
# Inside the carrier's 1420
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
    # Only when missing or older than the repo copy: installing restarts the
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
echo "  put tunnel .conf files in $TUNNELS_DIR/config (or carriers/ + $REPO/scripts/wgwarp-sweep.sh)"
echo "  $REPO/scripts/tunnel.sh import"
echo "  $REPO/scripts/tunnel.sh up"
