# wireguard-tunnels

WireGuard tunnels on macOS, run by `wg-quick` under a root LaunchDaemon, with
optional Cloudflare WARP inside any tunnel, a kill switch, and a menu bar lock.
The same tunnels, WARP inside included, can go to an iPhone or Apple TV as
sing-box profiles.

- [Why](#why)
- [Install](#install)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Warped tunnels](#warped-tunnels)
- [sing-box devices](#sing-box-devices)
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
anonymity tool: the WARP account is tied to this Mac. Some streaming services
flag WARP addresses; for those, a plain tunnel to the carrier's server (a
second config from the provider, with its own key) is the better pick.

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

`install.sh` is safe to re-run (such as after a `git pull`). Each step checks
first, changes only what's missing or out of date, and prints `ok` or
`changed`:

| Step | What |
|------|------|
| Homebrew packages | `wireguard-tools` (`wg`, `wg-quick`, `wireguard-go`) and `wgcf` (Cloudflare WARP account tool). Without Homebrew it prints how to install it and stops |
| `~/wg-tunnels/devices/<mac>` | This Mac's folders, [below](#your-folders), all `0700` (they hold private keys). The first time, it asks for this Mac's device name |
| WARP | Registers one free WARP account for this Mac (`wgcf register`, which accepts Cloudflare's terms of service) and writes `$(brew --prefix)/etc/wireguard/warp.conf` from it |
| Daemon | `/usr/local/sbin/wg-tunnels` (a copy of `tunnel.sh`) and the `com.local.wg-tunnels` LaunchDaemon, using `sudo`. Reinstalled when the repo copy differs or the LaunchDaemon is missing |

| Option | What |
|--------|------|
| `--device <name>` | This Mac's device name, without asking. Needed the first time when there's no terminal to ask in (e.g. Ansible) |
| `--swiftbar` | Also the [menu bar lock](#menu-bar-optional): SwiftBar (Homebrew cask), the plugin and a LaunchAgent that keeps SwiftBar running |
| `--no-daemon` | Skip the daemon step, for automation that can't answer a `sudo` prompt (e.g. Ansible). Install the daemon separately as root: `scripts/tunnel.sh _install <path/to/scripts/tunnel.sh>` |

`WARP_ENDPOINT` (`host:port`, default `162.159.192.1:2408`, IPv4) is where
`warp.conf` points: `WARP_ENDPOINT=host:port ./install.sh`. `wgwarp-sweep.sh`,
`singbox.sh` and `tunnel.sh rotate-warp` (which re-runs `install.sh`) read it
too, and it has to be the same for all of them, or `import` skips every warped
tunnel. If you change it, export it in your shell profile.

### The scripts

| Script | What |
|--------|------|
| `install.sh` | Sets everything up: prerequisites, your folders, WARP, the daemon; `--swiftbar` for the menu bar. Safe to re-run |
| `scripts/tunnel.sh` | The command you use day to day: `up`, `down`, `status`, `import`… ([Commands](#tunnelsh)). Installed as the daemon too |
| `scripts/wgwarp-sweep.sh` | Turns carrier configs into warped ones ([Warped tunnels](#warped-tunnels)) |
| `scripts/singbox.sh` | Profiles for an iPhone, Apple TV or other sing-box device, warped tunnels included ([sing-box devices](#sing-box-devices)) |
| `scripts/askpass.sh` | Password dialog for `sudo -A`, used by the menu bar; not run by hand |
| `scripts/swiftbar/tunnel-status.5s.sh` | The SwiftBar plugin; `install.sh --swiftbar` links it in |

### Your folders

Every device gets a folder in `~/wg-tunnels/devices/`, named the way wg-tools
names its configs (`dengar.mbp-1.conf` belongs in `mbp-1/`):

```
~/wg-tunnels/devices/
  .default     this Mac's device name: the folder tunnel.sh works in
  mbp-1/       this Mac
  iphone/      a sing-box device (singbox.sh new iphone)
```

In this README `<mac>` stands for this Mac's device name. `install.sh` asks
for it the first time and saves it in `.default`; `tunnel.sh default` shows
or changes it. `extract`, `import`, `rotate-warp` and `wgwarp-sweep.sh` use
that folder. Changing it doesn't touch the daemon; `import` then installs the
new device's tunnels.

`install.sh` creates these folders in `~/wg-tunnels/devices/<mac>/`, each
`0700` (they hold private keys):

| Folder | What goes there |
|--------|-----------------|
| `config/` | Every tunnel's `.conf`, one file per tunnel (the file name is the tunnel's name). This is what `tunnel.sh import` installs for the daemon; nothing runs from here directly |
| `carriers/` | WireGuard configs to wrap WARP inside, as downloaded from your provider or server. `wgwarp-sweep.sh` turns each into `config/warped.<name>.conf`. Only needed for warped tunnels |
| `exports/` | Zips from the WireGuard app's *Export Tunnels to Zip…*. `tunnel.sh extract` replaces `config/` with the newest one. Only needed if you use the app; zips are kept |
| `warp/` | Your Cloudflare WARP account (`wgcf-account.toml`) and profile (`wgcf-profile.conf`), made by `install.sh`. One per Mac; `warp.conf` is built from it |
| `sing-box/` | Only if you run `singbox.sh build <mac>`: these tunnels as sing-box profiles for the Mac ([sing-box on this Mac](#sing-box-on-this-mac)) |

## Quick start

The scripts are run by their path; there are no aliases. Add your own if you
like, e.g. in `~/.zshrc`:

```sh
alias tunnel=~/Documents/code/wireguard-tunnels/scripts/tunnel.sh
alias wgwarp-sweep=~/Documents/code/wireguard-tunnels/scripts/wgwarp-sweep.sh
alias singbox=~/Documents/code/wireguard-tunnels/scripts/singbox.sh
```

1. **Add configs** to `~/wg-tunnels/devices/<mac>/config/`, in any of these ways (if you
   use both of the last two, `extract` first: it replaces all of `config/`,
   swept `warped.*` files included):
   - Copy `<name>.conf` files from your VPN provider or server there.
   - For [warped tunnels](#warped-tunnels): put the carrier's config in
     `~/wg-tunnels/devices/<mac>/carriers/`, then run
     `~/Documents/code/wireguard-tunnels/scripts/wgwarp-sweep.sh`.
   - From the WireGuard app: *Export Tunnels to Zip…* into
     `~/wg-tunnels/devices/<mac>/exports/`, then run
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

For an iPhone or Apple TV, see [sing-box devices](#sing-box-devices).

## Commands

### tunnel.sh

`~/Documents/code/wireguard-tunnels/scripts/tunnel.sh <command>`:

| Command | What |
|---------|------|
| `up [n\|name]` | Asks `warped [Y/n]`, then which tunnel (Enter = the last one used, or the only one). A number picks from the warped list; a name skips both questions |
| `down` | Everything down, back to the normal connection |
| `status` (default) | Tunnels, what's up, handshakes, the kill switch, the exit IP |
| `list` | Number the warped and other tunnels |
| `import [dir] [-y]` | Install every `.conf` in `~/wg-tunnels/devices/<mac>/config` (or `dir`) for the daemon and work out each one's kind. Tunnels no longer there are removed, unless up right now. First shows what it would do (new, updated, unchanged, removed, and the WARP config) and asks; `-y` (or no terminal, as from the menu bar) skips the question |
| `extract [zip]` | Replace `~/wg-tunnels/devices/<mac>/config` with the `.conf` files in the newest zip in `~/wg-tunnels/devices/<mac>/exports` (or the one given). The zip is the authority: configs not in it are removed. The zip is kept |
| `extract-import` | `extract`, then `import` |
| `default [device]` | Show or change this Mac's device folder ([Your folders](#your-folders)). Asked the first time a command needs it |
| `rotate-warp` | New Cloudflare WARP keys: registers a new WARP account (through `install.sh`), imports it, and reconnects a warped tunnel that's up. The old account's files are deleted once that works (Cloudflare isn't told), or put back if registering fails. This Mac only: sing-box devices keep their own accounts |
| `log` | Follow the daemon's log |
| `breakglass` | Lost the network? See [Troubleshooting](#troubleshooting) |
| `update` | Bring the daemon up to date with the repo's `tunnel.sh`, only when it differs (or its LaunchDaemon is missing): after a `git pull`, say. Restarts the daemon, so a tunnel that's up drops for a few seconds |
| `install` | Install just the daemon, even when it's current (`install.sh` does this) |
| `uninstall` | Take everything down and remove the daemon; configs are kept |

`up`, `down`, `import`, `rotate-warp`, `update`, `install`, `uninstall` and
`breakglass` use `sudo`.
`up`, `down` and `import` first update the installed daemon when the repo copy
differs, as `update` does on its own.

### wgwarp-sweep.sh

`~/Documents/code/wireguard-tunnels/scripts/wgwarp-sweep.sh` turns the carrier
configs in `~/wg-tunnels/devices/<mac>/` into warped ones; see
[Warped tunnels](#warped-tunnels). For each one it also says what to do about
the WireGuard app's copy, if you keep one there. Given another device
(`wgwarp-sweep.sh iphone`) or a folder, it sweeps that one's `carriers/` into
its `config/` instead, with nothing about the app: that's how `singbox.sh
build` sweeps a [sing-box device](#sing-box-devices). It reads `WARP_ENDPOINT`, as
[install.sh](#install) does.

### singbox.sh

`~/Documents/code/wireguard-tunnels/scripts/singbox.sh <command>`, for
[sing-box devices](#sing-box-devices):

| Command | What |
|---------|------|
| `new <device>` | Make `~/wg-tunnels/devices/<device>/` and register the device's own WARP account (needs `wgcf`) |
| `build <device>` | Sweep its carriers, then write its profiles into its `sing-box/` (needs `jq`). This Mac is a device too ([sing-box on this Mac](#sing-box-on-this-mac)) |
| `list` | The devices, with how many carriers, tunnels and profiles each has |

It reads `WARP_ENDPOINT`, as [install.sh](#install) does.

## Warped tunnels

A warped tunnel is two WireGuard tunnels, one inside the other: the carrier
(any WireGuard server: a VPN provider, your own server) carries only the WARP
tunnel, and your traffic exits through WARP. See
[Why](#wrap-warp-inside-another-tunnel) for what that buys you.

`wgwarp-sweep.sh` makes the carrier configs: each
`~/wg-tunnels/devices/<mac>/carriers/<name>.conf` becomes
`~/wg-tunnels/devices/<mac>/config/warped.<name>.conf`, with `AllowedIPs` set to the WARP
endpoint (plus the extras below), the `DNS` line removed and
`PersistentKeepalive = 25`. Everything WARP-specific about a carrier happens
here: `import` takes a `warped.*` config as it is, and only checks it (the WARP
endpoint is in `AllowedIPs`, nothing wider than a /8, no `DNS`), skipping one
that isn't swept rather than fixing it.

**Extras: reaching the server through the carrier.** A carrier carries only
WARP, so the server can't reach your Mac (or the Mac reach the server) unless
the address is in `AllowedIPs` too. The sweep adds these *extras* from two
header lines of the carrier file:

```ini
# device-network: 10.9.8.0/24     # written by the wireguard-tools server repo
# wg-tunnels: also 10.0.0.5/32    # your own
```

`device-network` is the server's static device addresses (from the
wireguard-tools server repo, not the Homebrew package of the same name):
`10.9.8.1` is the server and `10.9.8.<number>` a device, whichever config
it's using.

They're rebuilt on every sweep, so deleting a line and sweeping again removes
them. A `#` after the addresses starts a comment. Anything wider than a /8 (/16
for IPv6) is ignored and reported, since it would take traffic away from WARP,
and so is anything that isn't an address (a hostname, a typo). Two carriers
that would make the same `warped.` name (`x.conf` and `warped-x.conf`) aren't
both swept: the second is skipped and reported. The `warped.` prefix is how
`import` knows the tunnel carries WARP. A `config/` file is only replaced when
it differs, and other files there are left alone: a `warped.*` file whose
carrier is gone is listed as `orphan`, anything else as `manual`.

The WARP side is `$(brew --prefix)/etc/wireguard/warp.conf`, written by
`install.sh`. Don't bring it up on its own; the daemon starts it inside the
carrier.

WARP's packets get up to 80 bytes bigger inside the carrier, so a carrier with
an MTU under 1360 (a server set to 1280, say) can't fit WARP's 1280: ping
works and nothing else does. The daemon handles it: when the carrier's MTU is
under 1360 it runs WARP at the carrier's MTU minus 80 (1200 inside a 1280
carrier) and logs it. Below 1280 there's no IPv6 inside WARP and QUIC falls
back to TCP; pages still load. The sweep flags these carriers.

## sing-box devices

An iPhone, iPad, Apple TV or Android box can't run the daemon, and the
WireGuard app there can't carry one tunnel inside another.
[sing-box](https://sing-box.sagernet.org) can (its app is on the App Store): a
WireGuard endpoint with a `detour` sends its packets through another one, so
WARP rides inside the carrier in one VPN.

Every device has a folder in `~/wg-tunnels/devices/`, laid out like the Mac's:
the sweep turns `carriers/` into `warped.*` files in `config/`, and
`singbox.sh build` turns all of `config/` into profiles in `sing-box/`, to
import in the app.

A device with only plain tunnels can use the WireGuard app instead. iOS runs
one VPN at a time, though, so using a tunnel in that app means leaving
sing-box.

### Set up a device

```sh
~/Documents/code/wireguard-tunnels/scripts/singbox.sh new iphone
# put its carriers in ~/wg-tunnels/devices/iphone/carriers/
# and its plain tunnels in ~/wg-tunnels/devices/iphone/config/
~/Documents/code/wireguard-tunnels/scripts/singbox.sh build iphone
```

| In `devices/<device>/` | What |
|--------|------|
| `carriers/` | The device's carriers: new WireGuard configs from your provider or server, made for this device |
| `warp/` | The device's own WARP account, made by `new` |
| `config/` | Every tunnel on the device: `warped.<carrier>.conf` from the sweep, and plain configs you put there, named as they came (`home.iphone.conf`) |
| `sing-box/` | What `build` writes, to import on the device |

Plain configs should be full tunnels (`AllowedIPs` with `0.0.0.0/0`). A
profile sends all of the device's traffic to the tunnel in use, so a split
config (a home LAN only, say) leaves the device with nothing past its own
networks, not even DNS; `build` warns about one.

`build` skips, and reports, a config it can't use: it needs one `[Peer]`, a
`PrivateKey`, `PublicKey`, `Address` and an `Endpoint` as `host:port`. It also
skips a `warped.*` file whose carrier is gone from `carriers/`. A few names are
taken: `tunnel`, `composite.<device>` and `carrier.<carrier>`.

### Keys

Every config on a device needs its own WireGuard key: one not used by any
other config, by this Mac, or by another device. Two configs on one key knock
each other off whenever both are up, and a lost device can be revoked on its
own. Get one by downloading a new config from your provider or server for
this device. `build` stops on a key that's used twice, and names the files
(never the key). A key used twice on one device (a carrier that's a copy of
a config in `config/`, say) only gets a note: a device runs one tunnel at a
time, and the composite has no keepalives. The device's warped tunnels all share its one
WARP key, which is why `new` gives each device its own WARP account.

### Which profile to import

A profile is one file you import in the sing-box app; the app runs one profile
at a time. `build` writes two kinds into `sing-box/`:

| Profile | What's in it | Switching tunnels |
|---------|--------------|-------------------|
| `composite.<device>.json` | Every tunnel, with a picker in the app (warped ones first) | In the picker, without dropping the VPN |
| `<tunnel>.json` (e.g. `warped.chicago.json`, `home.iphone.json`) | One tunnel | By starting another profile: the VPN drops for a moment |

Start with the composite: one import, and you switch tunnels in the picker.
Use one-tunnel profiles when a server needs to reach the device through an
idle tunnel (a home server, say), or when one tunnel's small MTU would slow
the rest. Nothing stops you importing both kinds.

sing-box starts every tunnel in a profile at once, not just the one picked. So
the composite leaves out keepalives: each tunnel talks to its server only while
it carries traffic. Otherwise every tunnel would stay connected, and the
warped ones, on the device's one WARP key, would knock each other off. The
costs:

- a server can't reach the device through an idle tunnel;
- the whole VPN runs at the smallest MTU of any tunnel in it.

A one-tunnel profile keeps the config's keepalive and its own MTU.

### Getting a profile to the device

**iPhone or iPad**

1. AirDrop the profile from `sing-box/` to the device.
2. Open it in the sing-box app, which adds it as a new profile.
3. Delete the copy you sent: it holds private keys.

**Apple TV.** Give it its own device folder (`singbox.sh new appletv`), so it
has its own keys. An Apple TV can't receive AirDrop, so send its profile to an
iPhone, then on the Apple TV choose *Import profile from iPhone/iPad* (as the
sing-box docs list it). Don't start that profile on the phone: the two would
share keys.

The app's QR scanner only takes links, not a whole profile, so it won't work
for these.

### Updating a device

1. Change `carriers/` or `config/`: add, replace or delete a `.conf`.
2. Run `singbox.sh build <device>`. It lists each profile as `new`, `updated`,
   `unchanged`, or removed (its tunnel is gone).
3. Send only the `new` and `updated` ones. In the app, delete the old copy and
   import the new one.

A carrier taken out of `carriers/` leaves the profiles, but its
`warped.<carrier>.conf` stays in `config/` until you delete it.

### What build puts in a profile

- A `warped.<carrier>` is WARP detoured through that carrier, at the carrier's
  MTU minus 80. Any other config is an endpoint as it stands.
- DNS goes to 1.1.1.1 through the tunnel in use, whatever a config's own `DNS`
  line says.
- `strict_route` keeps traffic in the VPN. sing-box has no kill switch; this
  is the closest it gets.
- A server given by hostname is looked up on the network the device is on,
  since through the tunnel it would need that tunnel up first.
- A carrier's [extras](#warped-tunnels) are swept as on a Mac, but
  `AllowedIPs` doesn't route in sing-box, so `build` adds a rule sending them
  to the carrier. In the composite the rule applies whichever tunnel is
  picked; if two carriers list the same network, the first keeps it and
  `build` warns (it only spots identical entries, not overlapping ones).
- When `sing-box` is installed on the Mac, `build` checks every profile with
  `sing-box check` before replacing any: if one fails, none change.

### sing-box on this Mac

sing-box has a Mac app too, and it can run this Mac's tunnels instead of the
daemon:

```sh
~/Documents/code/wireguard-tunnels/scripts/singbox.sh build mbp-1   # this Mac's device name
```

The Mac is built like any other device: its sweep (with the WireGuard app
column, as when you run it yourself), then every tunnel in its `config/` into
its `sing-box/`, `composite.mbp-1.json` and one profile per tunnel. Import them
in the sing-box app on the Mac.

The profiles use the same keys as the daemon, so run one or the other:
`tunnel.sh down` before turning sing-box on, and turn sing-box off before
`tunnel.sh up`.

What you give up while sing-box runs instead of the daemon:

- **The kill switch.** `strict_route` keeps traffic in the VPN while sing-box
  runs; if the app quits, traffic goes out directly.
- **The menu bar lock** and the `tunnel.sh` commands: they only see the daemon.

## Menu bar (optional)

`install.sh --swiftbar` adds a lock to the menu bar through
[SwiftBar](https://github.com/swiftbar/SwiftBar):

| Lock | Meaning |
|------|---------|
| green, locked | A tunnel is up (the daemon's, or one in the WireGuard app) |
| orange, locked | A tunnel is wanted but not up: the kill switch is blocking traffic |
| grey, open | No VPN |

The menu shows the tunnel, the exit and real IPs with their city, handshakes
and Tx/Rx, and has Status, Reconnect, Disconnect, Breakglass and every
imported tunnel to switch to; More has the status in Terminal, the log and
Rotate WARP Keys. These run in the background and ask for your
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
- **A script stops about the old layout?** Folders used to be
  `~/wg-tunnels/local/` (this Mac) and `~/wg-tunnels/sing-box/<device>/`, with
  `profiles/` inside; earlier still, this Mac's sat in `~/wg-tunnels` itself.
  Run the `mv` commands it prints: every device goes in
  `~/wg-tunnels/devices/`, and `profiles/` becomes `sing-box/`.

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
re-pins the server when the gateway changes or the pinned route is gone, gives
the exit (WARP, or the tunnel itself when it has a `PersistentKeepalive`) a new
source port when it stops handshaking (then restarts it), and restarts anything
that died. Every 5s it also looks for a network change (Wi-Fi rejoined, a new
gateway) and runs those checks straight away, so a tunnel recovers in seconds.

### Files

| Path | What |
|------|------|
| `~/wg-tunnels/devices/` | [Your folders](#your-folders): `.default`, and one folder per device (`carriers/`, `config/`, `warp/`, `sing-box/`, and on this Mac `exports/`) |
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
