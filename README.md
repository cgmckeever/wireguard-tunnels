# wireguard-tunnels

WireGuard tunnels on macOS, run by `wg-quick` under a root LaunchDaemon, with
optional Cloudflare WARP inside any tunnel, a kill switch, and a menu bar lock.

- [Why](#why)
- [Install](#install)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Warped tunnels](#warped-tunnels)
- [Menu bar (optional)](#menu-bar-optional)
- [Troubleshooting](#troubleshooting)
- [How it works](#how-it-works)
- [Uninstall](#uninstall)

## Why

### Run tunnels under a daemon

Tunnels in the WireGuard app are per-login-session Network Extensions: they
belong to one macOS user and stop passing traffic after a user switch. Here the
tunnels run under a root daemon instead, so they work for every user on the
Mac, come back after a reboot, and are watched and restarted when they fail.

### Wrap WARP inside another tunnel

A *warped* tunnel puts Cloudflare WARP inside any WireGuard tunnel (the
*carrier*: a VPN provider, your own server). The carrier carries only WARP,
and your traffic exits through WARP:

```
your Mac ──carrier tunnel──▶ carrier server ──WARP tunnel──▶ Cloudflare ──▶ sites
          (WARP inside it)    (sees only encrypted WARP)       (exit IP)
```

Either tunnel alone falls short:

- **A VPN server alone** exits from a datacenter or VPN IP range. Sites treat
  those with suspicion: more CAPTCHAs, "unusual traffic" pages, outright
  blocks.
- **WARP alone** exits from a Cloudflare IP near *you*, so sites still see
  your region, and Cloudflare sees your home IP.

Wrapped, you get both halves:

- **Sites see an ordinary Cloudflare IP.** WARP addresses are shared by
  millions of everyday WARP users, so they're rarely blocked, unlike VPN and
  datacenter ranges.
- **You pick the location.** WARP exits from the Cloudflare data center
  nearest to where it's entered from, and here that's the carrier's server,
  not you. A carrier in Toronto gives you a Cloudflare exit near Toronto.
- **The traffic is split between two parties.** The carrier sees your IP but
  only encrypted WARP traffic, not the sites you visit. Cloudflare sees the
  traffic, but coming from the carrier's IP, not yours. Your local network and
  ISP see only the carrier tunnel.
- **It works where WARP is blocked.** A network that blocks WARP directly
  still reaches the carrier.

The trade-offs: an extra hop (a little latency, and a smaller MTU of 1280
inside the carrier), Cloudflare still sees where your traffic goes, and a few
sites block WARP too. It hides where you are from sites, but it isn't an
anonymity tool: the WARP account is tied to this Mac.

### Tunnel kinds

Each tunnel is one of three kinds, worked out when it's imported:

| Kind | What | Kill switch |
|------|------|-------------|
| **warped** | Named `warped.*`. Any WireGuard tunnel (the *carrier*) that carries only Cloudflare WARP; your traffic exits through WARP, so sites see an ordinary Cloudflare IP in the carrier's city | yes |
| **full** | Routes all of IPv4 (`0.0.0.0/0`, or the two `/1` halves) | yes |
| **split** | Anything else: only the networks in its `AllowedIPs` | no |

The kill switch blocks everything outside the tunnel until you take it down:
a tunnel failing never falls back to your normal connection.

For the server side (a WireGuard server that exits through WARP), see
[wireguard-tools](https://github.com/cgmckeever/wireguard-tools).

## Install

Requires macOS, [Homebrew](https://brew.sh) and an admin user.

```sh
git clone https://github.com/cgmckeever/wireguard-tunnels.git ~/Documents/code/wireguard-tunnels
~/Documents/code/wireguard-tunnels/install.sh              # tunnels only
~/Documents/code/wireguard-tunnels/install.sh --swiftbar   # plus the menu bar lock
```

The repo can live anywhere; the examples here use
`~/Documents/code/wireguard-tunnels`. Run `install.sh` as yourself, not with
`sudo`: it asks for your password when it needs it.

`install.sh` is safe to re-run (after a `git pull`, say). Each step checks
first, changes only what's missing or out of date, and prints `ok` or
`changed`:

| Step | What |
|------|------|
| Homebrew packages | `wireguard-tools` (`wg`, `wg-quick`, `wireguard-go`) and `wgcf` (Cloudflare WARP account tool). Without Homebrew it prints how to install it and stops |
| `~/wg-tunnels` | Your working folders, [below](#your-folders), all `0700` (they hold private keys) |
| WARP | Registers one free WARP account for this Mac (`wgcf register`, which accepts Cloudflare's terms of service) and writes `$(brew --prefix)/etc/wireguard/warp.conf` from it |
| Daemon | `/usr/local/sbin/wg-tunnels` (a copy of `tunnel.sh`) and the `com.local.wg-tunnels` LaunchDaemon, using `sudo`. Reinstalled only when the repo copy differs |

| Option | What |
|--------|------|
| `--swiftbar` | Also the [menu bar lock](#menu-bar-optional): SwiftBar (Homebrew cask), the plugin and a LaunchAgent that keeps SwiftBar running |
| `--no-daemon` | Skip the daemon step, for automation that can't answer a `sudo` prompt (e.g. Ansible). Install the daemon separately as root: `scripts/tunnel.sh _install <path/to/scripts/tunnel.sh>` |
| `WARP_ENDPOINT=host:port` | WARP endpoint for `warp.conf` (default `162.159.192.1:2408`) |

### The scripts

Run them by their path (see [Quick start](#quick-start)):

| Script | What |
|--------|------|
| `install.sh` | Sets everything up: prerequisites, your folders, WARP, the daemon; `--swiftbar` for the menu bar. Safe to re-run |
| `scripts/tunnel.sh` | The command you use day to day: `up`, `down`, `status`, `import`… ([Commands](#tunnelsh)). Installed as the daemon too |
| `scripts/wgwarp-sweep.sh` | Turns carrier configs into warped ones ([Warped tunnels](#warped-tunnels)) |
| `scripts/askpass.sh` | Password dialog for `sudo -A`, used by the menu bar; not run by hand |
| `scripts/swiftbar/tunnel-status.5s.sh` | The SwiftBar plugin; `install.sh --swiftbar` links it in |

### Your folders

`install.sh` creates these under `~/wg-tunnels`, each `0700`:

| Folder | What goes there |
|--------|-----------------|
| `config/` | Every tunnel's `.conf`, one file per tunnel (the file name is the tunnel's name). This is what `tunnel.sh import` installs for the daemon; nothing runs from here directly |
| `carriers/` | WireGuard configs to wrap WARP inside, as downloaded from your provider or server. `wgwarp-sweep.sh` turns each into `config/warped.<name>.conf`. Only needed for warped tunnels |
| `exports/` | Zips from the WireGuard app's *Export Tunnels to Zip…*. `tunnel.sh extract` replaces `config/` with the newest one. Only needed if you use the app; zips are kept |
| `warp/` | Your Cloudflare WARP account (`wgcf-account.toml`) and profile (`wgcf-profile.conf`), made by `install.sh`. One per Mac; `warp.conf` is built from it |

## Quick start

The scripts are run by their path; there are no aliases. Add your own if you
like, e.g. in `~/.zshrc`:

```sh
alias tunnel=~/Documents/code/wireguard-tunnels/scripts/tunnel.sh
alias wgwarp-sweep=~/Documents/code/wireguard-tunnels/scripts/wgwarp-sweep.sh
```

1. **Add configs** to `~/wg-tunnels/config/`, in any of these ways:
   - Copy `<name>.conf` files from your VPN provider or server there.
   - For [warped tunnels](#warped-tunnels): put the carrier's config in
     `~/wg-tunnels/carriers/`, then run
     `~/Documents/code/wireguard-tunnels/scripts/wgwarp-sweep.sh`.
   - From the WireGuard app: *Export Tunnels to Zip…* into
     `~/wg-tunnels/exports/`, then run
     `~/Documents/code/wireguard-tunnels/scripts/tunnel.sh extract`.
2. **Import** them for the daemon:
   ```sh
   ~/Documents/code/wireguard-tunnels/scripts/tunnel.sh import
   ```
3. **Bring one up**:
   ```sh
   ~/Documents/code/wireguard-tunnels/scripts/tunnel.sh up
   ```
   It asks `warped [Y/n]`, then which tunnel. `down` takes it back down.

## Commands

### tunnel.sh

`~/Documents/code/wireguard-tunnels/scripts/tunnel.sh <command>`:

| Command | What |
|---------|------|
| `up [n\|name]` | Asks `warped [Y/n]`, then which tunnel (Enter = the last one used, or the only one). A number picks from the warped list; a name skips both questions |
| `down` | Everything down, back to the normal connection |
| `status` (default) | Tunnels, what's up, handshakes, the kill switch, the exit IP |
| `list` | Number the warped and other tunnels |
| `import [dir]` | Install every `.conf` in `~/wg-tunnels/config` (or `dir`) for the daemon and work out each one's kind. Tunnels no longer there are removed, unless up right now |
| `extract [zip]` | Replace `~/wg-tunnels/config` with the `.conf` files in the newest zip in `~/wg-tunnels/exports` (or the one given). The zip is the authority: configs not in it are removed. The zip is kept |
| `extract-import` | `extract`, then `import` |
| `log` | Follow the daemon's log |
| `breakglass` | Lost the network? See [Troubleshooting](#troubleshooting) |
| `install` | Install just the daemon (`install.sh` does this) |
| `uninstall` | Take everything down and remove the daemon; configs are kept |

`up`, `down`, `import`, `install`, `uninstall` and `breakglass` use `sudo`.
`up`, `down` and `import` first update the installed daemon when the repo copy
differs.

### wgwarp-sweep.sh

`~/Documents/code/wireguard-tunnels/scripts/wgwarp-sweep.sh` (no arguments) turns
carrier configs into warped ones; see [Warped tunnels](#warped-tunnels).

| Env | Default |
|-----|---------|
| `TUNNELS_DIR` | `~/wg-tunnels` |
| `WARP_ENDPOINT` | `162.159.192.1` |

## Warped tunnels

A warped tunnel is two WireGuard tunnels, one inside the other: the carrier
(any WireGuard server: a VPN provider, your own server) carries only the WARP
tunnel, and your traffic exits through WARP. See
[Why](#wrap-warp-inside-another-tunnel) for what that buys you.

`wgwarp-sweep.sh` makes the carrier configs: each
`~/wg-tunnels/carriers/<name>.conf` becomes
`~/wg-tunnels/config/warped.<name>.conf`, with `AllowedIPs` set to the WARP
endpoint only and the `DNS` line removed. The `warped.` prefix is how `import`
knows the tunnel carries WARP. A `config/` file is only replaced when it
differs, and any other configs there are left alone (listed as `manual`).

The WARP side is `$(brew --prefix)/etc/wireguard/warp.conf`, written by
`install.sh`. Don't bring it up on its own; the daemon starts it inside the
carrier.

## Menu bar (optional)

`install.sh --swiftbar` adds a lock to the menu bar through
[SwiftBar](https://github.com/swiftbar/SwiftBar):

| Lock | Meaning |
|------|---------|
| green, locked | A tunnel is up |
| orange, locked | A tunnel is wanted but not up: the kill switch is blocking traffic |
| grey, open | No VPN |

The menu shows the tunnel, the exit and real IPs with their city, handshakes
and Tx/Rx, and has Status, Reconnect, Disconnect, Breakglass and every
imported tunnel to switch to. These run in the background and ask for your
password in a dialog (`askpass.sh`). The exit and real IPs come from
[ipinfo.io](https://ipinfo.io).

What it installs:

- SwiftBar, if `/Applications/SwiftBar.app` is missing.
- Its plugin folder, if none is set: `~/.config/swiftbar`.
- The plugin: a symlink to `scripts/swiftbar/tunnel-status.5s.sh`, so a `git pull`
  updates it.
- `~/Library/LaunchAgents/com.local.swiftbar.plist`, which starts SwiftBar at
  login and again if it crashes or is killed. Skipped when another LaunchAgent
  already runs SwiftBar. If SwiftBar is also a Login Item, remove it there, or
  two copies run.

## Troubleshooting

- **What's going on?** `tunnel.sh status`, then `tunnel.sh log` (the daemon's
  log, `/var/log/wg-tunnels.log`).
- **No network, even after `down`?** `tunnel.sh breakglass` trusts no saved
  state: it stops WireGuard app tunnels, the daemon, `wg-quick` and
  `wireguard-go`; removes every route of ours and any reject route; resets
  tunnel DNS left on network services to DHCP; and power cycles Wi-Fi if it has
  no address. It runs from the repo, so it works even if the daemon is broken.
- **Also using the WireGuard app?** That's fine, with two rules. Turn off On
  Demand for its tunnels: it reconnects behind `up` and breaks the tunnel, so
  `up` refuses while it's on. And switch an app tunnel on only after `down`:
  the kill switch would swallow its traffic. `up` stops app tunnels for you.

## How it works

`tunnel.sh` is both the command and, installed as `/usr/local/sbin/wg-tunnels`,
the root daemon. `import` copies each config to
`$(brew --prefix)/etc/wg-tunnels` (root-owned, interfaces named `wtN`). Endpoint
hostnames are resolved there, since DNS can be cut off while switching. `up`
and `down` record what's wanted and wake the daemon, which does the work and
reports progress back to the waiting command.

Routing while a full or warped tunnel is up (macOS uses the most specific
route):

| Route | Goes to |
|-------|---------|
| tunnel server `/32` | the physical gateway (re-pinned when the gateway changes) |
| WARP endpoint `/32` | the carrier (warped: the carrier carries only WARP) |
| WARP endpoint `/31` | reject (carrier gone: WARP can't escape around it) |
| `0/2 64/2 128/2 192/2` (and the IPv6 `/2`s) | the exit: WARP, or the tunnel |
| `0/1 128/1`, `::/1 8000::/1` | reject: the **kill switch**, nothing leaves outside a tunnel |
| LAN, default | unchanged |

The daemon brings back the last `up` after a reboot and checks every 30s: it
re-pins the server when the gateway changes, gives WARP a new source port when
it stops handshaking (then restarts it), and restarts anything that died.

### Files

| Path | What |
|------|------|
| `~/wg-tunnels/` | [Your folders](#your-folders): `config/`, `carriers/`, `exports/`, `warp/` |
| `$(brew --prefix)/etc/wireguard/warp.conf` | WARP for `wg-quick`, written by `install.sh` |
| `$(brew --prefix)/etc/wg-tunnels/` | The daemon's copies: `conf/`, `tunnels.tsv`, `state/` |
| `/usr/local/sbin/wg-tunnels` | The daemon (a copy of `tunnel.sh`) |
| `/Library/LaunchDaemons/com.local.wg-tunnels.plist` | Its LaunchDaemon |
| `/var/run/wg-tunnels/status` | Live state, read by `status` and the menu bar |
| `/var/log/wg-tunnels.log` | The daemon's log |

Everything under `~/wg-tunnels` and `etc/` holds private keys and stays on
your Mac; nothing here sends them anywhere.

## Uninstall

```sh
~/Documents/code/wireguard-tunnels/scripts/tunnel.sh uninstall   # tunnels down, daemon removed
sudo rm -rf "$(brew --prefix)/etc/wg-tunnels"            # the daemon's config copies
rm -f "$(brew --prefix)/etc/wireguard/warp.conf"
rm -rf ~/wg-tunnels                                      # your configs and WARP account: keep a copy if you need them
```

With the menu bar:

```sh
launchctl bootout gui/$(id -u)/com.local.swiftbar
rm -f ~/Library/LaunchAgents/com.local.swiftbar.plist
rm -f "$(defaults read com.ameba.SwiftBar PluginDirectory)/tunnel-status.5s.sh"
brew uninstall --cask swiftbar                            # if nothing else uses it
```

And the packages, if nothing else uses them: `brew uninstall wgcf wireguard-tools`.
