# wireguard-tunnels

*Cloudflare exit IPs, tunneled through your WireGuard region*

## What it does

It runs Cloudflare WARP inside a WireGuard tunnel. The WireGuard tunnel (the
*carrier*) goes to a server you pick, a VPN provider's or your own; WARP rides
inside it; and your traffic leaves through Cloudflare within that region, not
your location:

```
device ──WireGuard (carrier)──▶ carrier server ──WARP──▶ Cloudflare ──▶ sites
         (WARP inside it)       (sees only encrypted WARP)   (exit IP)
```

Either tunnel alone falls short:

- **A VPN server alone** exits from a datacenter or VPN IP range. Sites treat
  those with suspicion: more CAPTCHAs, "unusual traffic" pages, blocks.
- **WARP alone** exits from a Cloudflare IP near *you*, so sites still see
  your region, and Cloudflare sees your home IP.

Together:

- **Sites see an ordinary Cloudflare IP.** Millions of everyday WARP users
  share those addresses, so they're rarely blocked.
- **You pick the region.** WARP exits from the Cloudflare data center nearest
  to where it's entered, which here is the carrier's server. A carrier in
  Toronto gives you an exit near Toronto.
- **The traffic is split between two parties.** The carrier sees your IP but
  only encrypted WARP traffic. Cloudflare sees the traffic, but from the
  carrier's IP. Your local network and ISP see only the carrier tunnel.
- **It works where WARP is blocked.** A network that blocks WARP still
  reaches the carrier.

The trade-offs: an extra hop (a little latency, and an MTU of 1280 inside the
carrier), Cloudflare still sees where your traffic goes, and a few sites block
WARP too. It hides your location from sites, but it isn't an anonymity tool:
each WARP account is tied to one device. Some streaming services flag WARP
addresses; for those, use a plain tunnel to the carrier's server (a second
config from the provider, with its own key). Plain tunnels work here too.

For the server side (a WireGuard server that exits through WARP itself), see
[wireguard-tools](https://github.com/cgmckeever/wireguard-tools).

## Two ways to run it

The same configs and folders serve two kinds of device:

| | This Mac | Phones, tablets, Apple TV |
|---|---|---|
| Runs the tunnels | A root daemon (`wg-quick` under launchd) | The [sing-box](https://sing-box.sagernet.org) app |
| You manage it with | `tunnel.sh` and the menu bar | `singbox.sh` on the Mac, then import in the app |
| Kill switch | Yes: nothing leaves outside a tunnel, even if it fails | Only while the app runs (`strict_route`) |
| Start at | [Install the management tools](#install-the-management-tools), then [Quick start](#quick-start) | [sing-box devices](#sing-box-devices) |

**This Mac: the scripts and the menu bar.** The WireGuard app's tunnels belong
to one macOS user and stop passing traffic after a user switch. Here a root
daemon runs them instead: they work for every user, come back after a reboot,
are restarted when they fail, and a kill switch blocks traffic whenever a
tunnel is wanted but down. `tunnel.sh` brings tunnels up and down; the
optional [menu bar lock](#menu-bar-optional) shows the state and switches
tunnels.

**Phones, tablets and Apple TV: sing-box.** iOS, tvOS and Android can't run
the daemon, and their WireGuard app can't put one tunnel inside another.
sing-box can. `singbox.sh` turns a device's configs into sing-box profiles on
the Mac; you import them in the sing-box app on the device. The Mac can use
sing-box too, instead of the daemon ([sing-box on this Mac](#sing-box-on-this-mac)).

Both share one layout: each device has a folder in `~/wg-tunnels/devices/`,
with its own keys and its own WARP account, and the same sweep
([Warped tunnels](#warped-tunnels)) builds the warped tunnels for either.

Terms used throughout:

- **Device**: a machine that runs tunnels (this Mac, an iPhone, an Apple TV).
  Each has its own folder, `~/wg-tunnels/devices/<device>/`.
- **`<mac>`**: this Mac's device name, such as `mbp-1`. It is saved in
  `~/wg-tunnels/devices/.default`.
- **Carrier**: a WireGuard tunnel to a VPN provider or your own server, used
  only to carry WARP.
- **Warped tunnel**: a carrier with WARP running inside it, named
  `warped.<name>`. Your traffic exits through WARP.
- **Extras**: addresses a carrier routes besides WARP, so its server and your
  device can reach each other ([Warped tunnels](#warped-tunnels)).
- **Profile**: a sing-box JSON file you import in the sing-box app. The
  **composite** profile holds all of a device's tunnels, with a picker.

Contents:

- [What it does](#what-it-does) and [Two ways to run it](#two-ways-to-run-it)
- This Mac: [Install the management tools](#install-the-management-tools) · [Quick start](#quick-start) ·
  [Commands](#commands) · [Warped tunnels](#warped-tunnels) ·
  [Menu bar](#menu-bar-optional) · [Troubleshooting](#troubleshooting) ·
  [How it works](#how-it-works)
- Phones, tablets, Apple TV: [sing-box devices](#sing-box-devices)
- [Uninstall](#uninstall)

## Install the management tools

`install.sh` sets up everything on this Mac: packages, your folders, a WARP
account and the daemon. It needs macOS, [Homebrew](https://brew.sh) and an
admin user.

```sh
git clone https://github.com/cgmckeever/wireguard-tunnels.git ~/Documents/code/wireguard-tunnels
~/Documents/code/wireguard-tunnels/install.sh              # tunnels only
~/Documents/code/wireguard-tunnels/install.sh --swiftbar   # plus the menu bar lock
```

The repo can live anywhere; this README uses
`~/Documents/code/wireguard-tunnels`. Run `install.sh` as yourself, not with
`sudo`: it asks for your password when it needs it. The first time, it asks
for this Mac's device name (`mbp-1`, say).

`install.sh` is safe to re-run, for example after a `git pull`. Each step
checks first, changes only what's missing or out of date, and prints `ok` or
`changed`:

| Step | What |
|------|------|
| Homebrew packages | `wireguard-tools` (`wg`, `wg-quick`, `wireguard-go`) and `wgcf` (the WARP account tool). Without Homebrew it prints how to install it and stops |
| `~/wg-tunnels/devices/<mac>/` | This Mac's folders ([Your folders](#your-folders)), all `0700` since they hold private keys. Writes `<mac>` to `.default` |
| WARP | Registers one free WARP account for this Mac (`wgcf register`, which accepts Cloudflare's terms of service) and writes `$(brew --prefix)/etc/wireguard/warp.conf` from it |
| Daemon | Installs `/usr/local/sbin/wg-tunnels` (a copy of `tunnel.sh`) and the `com.local.wg-tunnels` LaunchDaemon, using `sudo`. Only when the repo copy differs or the LaunchDaemon is missing |

| Option | What |
|--------|------|
| `--device <name>` | This Mac's device name, without asking. Needed the first time when there's no terminal (e.g. Ansible) |
| `--swiftbar` | Also the [menu bar lock](#menu-bar-optional): SwiftBar, the plugin, and a LaunchAgent that keeps SwiftBar running |
| `--no-daemon` | Skip the daemon step, for automation that can't answer a `sudo` prompt. Then install the daemon as root: `scripts/tunnel.sh _install <path/to/scripts/tunnel.sh>` |

**WARP endpoint.** `WARP_ENDPOINT` (IPv4 `address:port`, default
`162.159.192.1:2408`) sets where WARP connects: `WARP_ENDPOINT=ip:port
./install.sh`. `install.sh`, `wgwarp-sweep.sh`, `singbox.sh` and
`tunnel.sh rotate-warp` all read it, and they must agree: if the sweep used a
different endpoint from `warp.conf`, `import` skips every warped tunnel. To
change it, export it in your shell profile, then re-run `install.sh`,
`wgwarp-sweep.sh` and `tunnel.sh import`.

### The scripts

| Script | What |
|--------|------|
| `install.sh` | Sets everything up (above). Safe to re-run |
| `scripts/tunnel.sh` | The day-to-day command: `up`, `down`, `status`, `import`… ([Commands](#tunnelsh)). Also installed as the daemon |
| `scripts/wgwarp-sweep.sh` | Turns carrier configs into warped ones ([Warped tunnels](#warped-tunnels)) |
| `scripts/singbox.sh` | Builds profiles for an iPhone, Apple TV or other sing-box device ([sing-box devices](#sing-box-devices)) |
| `scripts/askpass.sh` | Password dialog for `sudo -A`, used by the menu bar; not run by hand |
| `scripts/swiftbar/tunnel-status.5s.sh` | The SwiftBar plugin; `install.sh --swiftbar` links it in |

### Your folders

All configs and keys live in `~/wg-tunnels/devices/`, one folder per device.
Name each folder the way wg-tools names its configs (`dengar.mbp-1.conf`
belongs in `mbp-1/`):

```
~/wg-tunnels/devices/
  .default     this Mac's device name (one line: mbp-1)
  mbp-1/       this Mac
  iphone/      a sing-box device (singbox.sh new iphone)
```

`tunnel.sh extract`, `import`, `rotate-warp` and `wgwarp-sweep.sh` work in the
folder `.default` names. `tunnel.sh default` shows or changes it. Changing it
doesn't touch the daemon; run `tunnel.sh import` to install the new device's
tunnels.

Inside `~/wg-tunnels/devices/<mac>/` (each `0700`):

| Folder | What goes there |
|--------|-----------------|
| `config/` | Every tunnel's `.conf`, one per tunnel; the file name is the tunnel name. `tunnel.sh import` installs these for the daemon; nothing runs from here directly |
| `carriers/` | Carrier configs, as downloaded from your provider or server. `wgwarp-sweep.sh` turns each into `config/warped.<name>.conf`. Only for warped tunnels |
| `exports/` | Zips from the WireGuard app's *Export Tunnels to Zip…*. `tunnel.sh extract` replaces `config/` with the newest. Only if you use the app; zips are kept |
| `warp/` | This Mac's WARP account (`wgcf-account.toml`) and profile (`wgcf-profile.conf`), made by `install.sh`. `warp.conf` is built from it |
| `sing-box/` | Only after `singbox.sh build <mac>`: this Mac's tunnels as sing-box profiles ([sing-box on this Mac](#sing-box-on-this-mac)) |

## Quick start

This takes you from a fresh install to a running tunnel.

The scripts are run by path; there are no aliases. Add your own if you like,
e.g. in `~/.zshrc`:

```sh
alias tunnel=~/Documents/code/wireguard-tunnels/scripts/tunnel.sh
alias wgwarp-sweep=~/Documents/code/wireguard-tunnels/scripts/wgwarp-sweep.sh
alias singbox=~/Documents/code/wireguard-tunnels/scripts/singbox.sh
```

After this section the README writes just `tunnel.sh`, `wgwarp-sweep.sh` and
`singbox.sh`.

1. **Add configs** to `~/wg-tunnels/devices/<mac>/config/`, in one or more of
   these ways:
   - **Plain tunnel:** copy `<name>.conf` from your VPN provider or server
     into `config/`.
   - **[Warped tunnel](#warped-tunnels):** copy the carrier's config into
     `~/wg-tunnels/devices/<mac>/carriers/`, then run
     `~/Documents/code/wireguard-tunnels/scripts/wgwarp-sweep.sh`.
     `carriers/chicago.conf` becomes `config/warped.chicago.conf`.
   - **From the WireGuard app:** *Export Tunnels to Zip…* into
     `~/wg-tunnels/devices/<mac>/exports/`, then run
     `~/Documents/code/wireguard-tunnels/scripts/tunnel.sh extract`.

   `extract` replaces all of `config/` with the zip's configs, removing any
   you copied or swept. If you mix it with the others, run `extract` first.
2. **Import** them for the daemon. It shows what will change and asks first:
   ```sh
   ~/Documents/code/wireguard-tunnels/scripts/tunnel.sh import
   ```
3. **Bring one up.** It asks `warped [Y/n]`, then which tunnel:
   ```sh
   ~/Documents/code/wireguard-tunnels/scripts/tunnel.sh up
   ```
4. **Check it** with `tunnel.sh status`. `tunnel.sh down` takes it down and
   returns you to your normal connection.

For an iPhone or Apple TV, see [sing-box devices](#sing-box-devices).

## Commands

This is the reference for each script's commands.

### tunnel.sh

`tunnel.sh <command>`:

| Command | What |
|---------|------|
| `up [n\|name]` | Asks `warped [Y/n]`, then which tunnel (Enter = the last one used, or the only one). A number picks from the warped list; a name skips both questions |
| `down` | Everything down, back to the normal connection |
| `status` (default) | Tunnels, what's up, handshakes, the kill switch, the exit IP |
| `list` | Number the warped and other tunnels |
| `import [dir] [-y]` | Install every `.conf` in `<mac>/config/` (or `dir`) for the daemon, and sort each into its [kind](#tunnel-kinds). Tunnels no longer there are removed, unless up right now. Shows what it would do (new, updated, unchanged, removed, and the WARP config) and asks; `-y`, or no terminal (the menu bar), skips the question |
| `extract [zip]` | Replace `<mac>/config/` with the `.conf` files in the newest zip in `<mac>/exports/` (or the one given). Configs not in the zip are removed. The zip is kept |
| `extract-import [zip]` | `extract`, then `import` |
| `default [device]` | Show or change this Mac's device ([Your folders](#your-folders)). Asked the first time a command needs it |
| `rotate-warp` | New WARP keys: registers a new WARP account (through `install.sh`), imports it, and reconnects a warped tunnel that's up. The old account's files are deleted once that works (Cloudflare isn't told), or put back if registering fails. This Mac only: sing-box devices keep their own accounts |
| `log` | Follow the daemon's log |
| `breakglass` | Lost the network? See [Troubleshooting](#troubleshooting) |
| `update` | Update the daemon from the repo's `tunnel.sh`, only if it differs (or its LaunchDaemon is missing), e.g. after a `git pull`. Restarts the daemon, so a tunnel that's up drops for a few seconds |
| `install` | Install just the daemon, even when it's current |
| `uninstall` | Take everything down and remove the daemon; configs are kept |

`up`, `down`, `import`, `rotate-warp`, `update`, `install`, `uninstall` and
`breakglass` use `sudo`. `up`, `down` and `import` also update the daemon
first when the repo copy differs, as `update` does.

### Tunnel kinds

`tunnel.sh import` sorts each tunnel into one of three kinds:

| Kind | What | Kill switch |
|------|------|-------------|
| **warped** | Named `warped.*`: a carrier with WARP inside. Sites see a Cloudflare IP in the carrier's city | yes |
| **full** | Routes all of IPv4 (`0.0.0.0/0`, or the two `/1` halves) | yes |
| **split** | Anything else: only the networks in its `AllowedIPs` | no |

The kill switch blocks all traffic outside the tunnel until you run
`tunnel.sh down`. A failing tunnel never falls back to your normal connection.

### wgwarp-sweep.sh

`wgwarp-sweep.sh [device|dir]` turns each carrier in `<mac>/carriers/` into a
warped config in `<mac>/config/` ([Warped tunnels](#warped-tunnels)). For
this Mac it also says, per tunnel, what to do about the WireGuard app's copy,
if you keep one there.

Given a device (`wgwarp-sweep.sh iphone`) or a folder with a `carriers/` in
it, it sweeps that one instead, with no WireGuard app advice. `singbox.sh
build` runs it this way. It reads `WARP_ENDPOINT`, as [install.sh](#install-the-management-tools) does.

### singbox.sh

`singbox.sh <command>`, for [sing-box devices](#sing-box-devices):

| Command | What |
|---------|------|
| `new <device>` | Make `~/wg-tunnels/devices/<device>/` and register the device's own WARP account (needs `wgcf`) |
| `build <device>` | Sweep its carriers, then write its profiles into its `sing-box/` (needs `jq`: `brew install jq`). Works for this Mac too ([sing-box on this Mac](#sing-box-on-this-mac)) |
| `list` | Each device's carriers, tunnels and profiles, whether it has a WARP account, and which is this Mac |

It reads `WARP_ENDPOINT`, as [install.sh](#install-the-management-tools) does.

## Warped tunnels

How a carrier becomes a warped tunnel, and the details that matter when one
doesn't work. For why you'd want one, see
[Why](#what-it-does).

**What the sweep writes.** `wgwarp-sweep.sh` turns each
`<mac>/carriers/<name>.conf` into `<mac>/config/warped.<name>.conf`. It sets
`AllowedIPs` to the WARP endpoint (plus extras, below), removes the `DNS`
line, and sets `PersistentKeepalive = 25`. The `warped.` prefix is how
`import` knows the tunnel carries WARP.

**What import checks.** All WARP-specific changes happen in the sweep.
`import` takes a `warped.*` config as it is and only checks it: the WARP
endpoint is in `AllowedIPs`, nothing is wider than a /8 (/16 for IPv6), and
there's no `DNS` line. A config that fails is skipped, not fixed.

**Extras.** A carrier routes only WARP, so the server can't reach your Mac,
or your Mac the server, unless that address is in `AllowedIPs` too. The sweep
adds these extras from two header lines in the carrier file:

```ini
# device-network: 10.9.8.0/24     # written by the wireguard-tools server repo
# wg-tunnels: also 10.0.0.5/32    # your own
```

`device-network` is the server's static device addresses (from the
wireguard-tools server repo, not the Homebrew package of the same name):
`10.9.8.1` is the server, `10.9.8.<number>` a device.

Extras are rebuilt on every sweep: delete a line and sweep again to remove
them. A `#` after the addresses starts a comment. Entries wider than a /8
(/16 for IPv6) would take traffic away from WARP, so they're ignored and
reported, as is anything that isn't an address (a hostname, a typo).

**Name clashes and leftovers.** `x.conf`, `warped.x.conf` and `warped-x.conf`
in `carriers/` all become `warped.x`; only the first is swept and the rest are
reported. A `config/` file is only rewritten when it changes. Other files in
`config/` are left alone: a swept file whose carrier is gone is listed as
`orphan`, anything else as `manual`.

**The WARP side** is `$(brew --prefix)/etc/wireguard/warp.conf`, written by
`install.sh`. Don't bring it up on its own; the daemon starts it inside the
carrier.

**Small carrier MTU.** WARP's packets grow by up to 80 bytes inside the
carrier. A carrier with an MTU under 1360 (a server set to 1280, say) can't
fit WARP's 1280: ping works and nothing else does. The daemon handles it: it
runs WARP at the carrier's MTU minus 80 (1200 inside a 1280 carrier) and logs
it. Below 1280 there's no IPv6 inside WARP and QUIC falls back to TCP; pages
still load. The sweep flags these carriers.

## Menu bar (optional)

`install.sh --swiftbar` adds a lock icon to the menu bar, through
[SwiftBar](https://github.com/swiftbar/SwiftBar), showing whether you're
protected:

| Lock | Meaning |
|------|---------|
| green, locked | A tunnel is up (the daemon's, or one in the WireGuard app) |
| orange, locked | A tunnel is wanted but not up: the kill switch is blocking traffic |
| grey, open | No VPN |

The menu shows the tunnel, its uptime, the exit and real IPs with their city
(from [ipinfo.io](https://ipinfo.io)), handshakes, the kill switch, and
Tx/Rx. It has:

- **Status**, **Reconnect**, **Disconnect** and **Breakglass**.
- Every imported tunnel, to switch to.
- **More**: status in Terminal, the log, Rotate WARP Keys, and Update Daemon
  (`tunnel.sh update`; it says "out of date" when the repo's `tunnel.sh`
  differs from the daemon's copy).

Actions outside Terminal run in the background, ask for your password in a
dialog when they need `sudo` (`askpass.sh`), and report the result as a
notification.

What it installs:

- SwiftBar, if `/Applications/SwiftBar.app` is missing.
- Its plugin folder, if none is set: `~/.config/swiftbar`.
- The plugin: a symlink to `scripts/swiftbar/tunnel-status.5s.sh`, so a
  `git pull` updates it.
- `~/Library/LaunchAgents/com.local.swiftbar.plist`, which starts SwiftBar at
  login and again if it crashes or is killed. Skipped when another LaunchAgent
  already runs SwiftBar. If SwiftBar is also a Login Item, remove it there, or
  two copies run.

## Troubleshooting

Start here when a tunnel or the network misbehaves.

- **What's going on?** Run `tunnel.sh status`, then `tunnel.sh log` (the
  daemon's log, `/var/log/wg-tunnels.log`).
- **No network, even after `down`?** Run `tunnel.sh breakglass`. It trusts no
  saved state: it stops WireGuard app tunnels, the daemon, `wg-quick` and
  `wireguard-go`; removes every route of ours and any reject route; resets
  tunnel DNS left on network services to DHCP; and power cycles Wi-Fi if it
  has no address. It runs from the repo, so it works even if the daemon is
  broken.
- **Also using the WireGuard app?** That's fine, with two rules. Turn off On
  Demand for its tunnels: it reconnects behind `up` and breaks the tunnel, so
  `up` refuses while it's on. And switch an app tunnel on only after `down`,
  or the kill switch swallows its traffic. `up` stops app tunnels for you.
- **A script stops about the old layout?** Folders used to be
  `~/wg-tunnels/local/` (this Mac) and `~/wg-tunnels/sing-box/<device>/`, with
  `profiles/` inside; earlier still, this Mac's sat in `~/wg-tunnels` itself.
  Run the `mv` commands it prints: every device goes in
  `~/wg-tunnels/devices/`, and `profiles/` becomes `sing-box/`.

## How it works

What the daemon does, for debugging or curiosity.

`tunnel.sh` is both the command and, installed as `/usr/local/sbin/wg-tunnels`,
the root daemon. `import` copies each config to
`$(brew --prefix)/etc/wg-tunnels` (root-owned, interfaces named `wtN`) and
resolves endpoint hostnames there, since DNS can be cut off while switching.
`up` and `down` record what's wanted and wake the daemon, which does the work
and reports progress back to the waiting command.

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

The daemon brings back the last `up` after a reboot and checks every 30s. It
re-pins the server when the gateway changes or the pinned route is gone. When
the exit (WARP, or the tunnel itself if it has a `PersistentKeepalive`) stops
handshaking, it gives it a new source port, then restarts it. It also restarts
anything that died. Every 5s it looks for a network change (Wi-Fi rejoined, a
new gateway) and runs those checks at once, so a tunnel recovers in seconds.

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

## sing-box devices

Use this to run the same tunnels, warped ones included, on an iPhone, iPad,
Apple TV or Android box. Those can't run the daemon, and the WireGuard app
there can't carry one tunnel inside another.
[sing-box](https://sing-box.sagernet.org) can (its app is on the App Store):
a WireGuard endpoint with a `detour` sends its packets through another, so
WARP rides inside the carrier in one VPN.

Each device's folder is laid out like the Mac's. The sweep turns `carriers/`
into `warped.*` files in `config/`, and `singbox.sh build` turns all of
`config/` into profiles in `sing-box/`.

A device with only plain tunnels can use the WireGuard app instead. iOS runs
one VPN at a time, though, so using a tunnel in that app means leaving
sing-box.

### Set up a device

1. Make the device folder and its own WARP account:
   ```sh
   singbox.sh new iphone
   ```
2. Put its carriers in `~/wg-tunnels/devices/iphone/carriers/` and its plain
   tunnels in `~/wg-tunnels/devices/iphone/config/`. Each needs its own key
   ([Keys](#keys)).
3. Build its profiles:
   ```sh
   singbox.sh build iphone
   ```
4. Send a profile to the device ([Getting a profile to the device](#getting-a-profile-to-the-device)).

| In `devices/<device>/` | What |
|--------|------|
| `carriers/` | The device's carriers: new WireGuard configs from your provider or server, made for this device |
| `warp/` | The device's own WARP account, made by `new` |
| `config/` | Every tunnel on the device: `warped.<carrier>.conf` from the sweep, and plain configs you put there, named as they came (`home.iphone.conf`) |
| `sing-box/` | What `build` writes, to import on the device |

Plain configs should be full tunnels (`AllowedIPs` with `0.0.0.0/0`). A
profile sends all of the device's traffic to the tunnel in use, so a split
config (a home LAN only, say) leaves the device with nothing past its own
networks, not even DNS. `build` warns about one.

`build` skips, and reports, a config it can't use. It needs one `[Peer]`, a
`PrivateKey`, `PublicKey`, `Address` and an `Endpoint` as `host:port`. It also
skips a `warped.*` file whose carrier is missing from `carriers/` or broken.
These tunnel names are reserved: `tunnel`, `warp`, `composite.<device>` and
`carrier.<carrier>`.

### Keys

Every config on a device needs its own WireGuard key, not used by any other
config, this Mac, or another device. Two configs on one key knock each other
off whenever both are up, and a lost device can be revoked on its own. Get one
by downloading a new config for this device from your provider or server.

`build` stops on a key shared with another device, and names the files
(never the key). A key used twice on one device (a carrier copied from a
config in `config/`, say) only gets a note: a device runs one tunnel at a
time, and the composite has no keepalives. A device's warped tunnels all share
its one WARP key, which is why `new` gives each device its own WARP account.

### Which profile to import

`build` writes two kinds of profile into `sing-box/`; the app runs one profile
at a time. `build` owns that folder: a `.json` there that it didn't write is
removed.

| Profile | What's in it | Switching tunnels |
|---------|--------------|-------------------|
| `composite.<device>.json` | Every tunnel, with a picker in the app (warped ones first, `warp` last) | In the picker, without dropping the VPN |
| `<tunnel>.json` (e.g. `warped.chicago.json`, `home.iphone.json`, `warp.json`) | One tunnel | By starting another profile: the VPN drops for a moment |

Every device also gets a `warp` tunnel, in the composite and as `warp.json`:
WARP alone, straight from the device's network, with no carrier. It uses the
device's own WARP account, so it needs no config. Traffic exits through
Cloudflare, but the network you're on can see you're using WARP; a warped
tunnel hides that inside the carrier.

Start with the composite: one import, and you switch tunnels in the picker.
Use one-tunnel profiles when a server must reach the device through an idle
tunnel (a home server, say), or when one tunnel's small MTU would slow the
rest. You can import both kinds.

sing-box starts every tunnel in a profile at once, not just the one picked.
So the composite leaves out keepalives: each tunnel talks to its server only
while it carries traffic. Otherwise every tunnel would stay connected, and the
warped ones, sharing the device's WARP key, would knock each other off. The
costs:

- a server can't reach the device through an idle tunnel;
- the whole VPN runs at the smallest MTU of any tunnel in it.

A one-tunnel profile keeps the config's keepalive and its own MTU.

### Getting a profile to the device

**iPhone or iPad**

1. AirDrop the profile from `sing-box/` to the device.
2. Open it in the sing-box app, which adds it as a new profile.
3. Delete the copy you sent: it holds private keys.

**Apple TV**

1. Give it its own device (`singbox.sh new appletv`), so it has its own keys.
2. An Apple TV can't receive AirDrop, so send its profile to an iPhone.
3. On the Apple TV, choose *Import profile from iPhone/iPad* (as the sing-box
   docs list it). Don't start that profile on the phone: the two would share
   keys.

The app's QR scanner only takes links, not a whole profile, so it won't work
for these.

### Updating a device

1. Change `carriers/` or `config/`: add, replace or delete a `.conf`.
2. Run `singbox.sh build <device>`. It lists each profile as `new`,
   `updated`, `unchanged`, or removed (its tunnel is gone).
3. Send only the `new` and `updated` ones. In the app, delete the old copy and
   import the new one.

A carrier removed from `carriers/` drops out of the profiles on the next
build, but its `warped.<carrier>.conf` stays in `config/` until you delete it.

### What build puts in a profile

- A `warped.<carrier>` is WARP detoured through that carrier, at 1280 as on
  the Mac, or the carrier's MTU minus 80 when that's smaller. `warp` is the
  same WARP endpoint with no carrier, at 1280. Any other config is an endpoint
  as it stands.
- DNS goes to 1.1.1.1 through the tunnel in use, whatever a config's own
  `DNS` line says.
- `strict_route` keeps traffic in the VPN. sing-box has no kill switch; this
  is the closest it gets.
- A server given by hostname is looked up on the device's own network, since
  through the tunnel it would need that tunnel up first.
- A carrier's [extras](#warped-tunnels) are swept as on a Mac, but
  `AllowedIPs` doesn't route in sing-box, so `build` adds a rule sending them
  to the carrier. In the composite the rule applies whichever tunnel is
  picked; if two carriers list the same network, the first keeps it and
  `build` warns (it only spots identical entries, not overlapping ones).
- When `sing-box` is installed on the Mac, `build` checks every profile with
  `sing-box check` before replacing any: if one fails, none change.

### sing-box on this Mac

The sing-box Mac app can run this Mac's tunnels instead of the daemon. Build
the Mac like any other device, using its device name:

```sh
singbox.sh build mbp-1
```

This sweeps its carriers (without the WireGuard app advice), then writes
`composite.mbp-1.json` and one profile per tunnel into its `sing-box/`.
Import them in the sing-box app on the Mac.

The profiles use the same keys as the daemon, so run one or the other: run
`tunnel.sh down` before turning sing-box on, and turn sing-box off before
`tunnel.sh up`.

What you give up while sing-box runs instead of the daemon:

- **The kill switch.** `strict_route` keeps traffic in the VPN while sing-box
  runs; if the app quits, traffic goes out directly.
- **The menu bar lock** and the `tunnel.sh` commands: they only see the
  daemon.

## Uninstall

These commands remove the daemon, its files and, if you choose, your configs.

```sh
tunnel.sh uninstall                                       # tunnels down, daemon removed
sudo rm -rf "$(brew --prefix)/etc/wg-tunnels"            # the daemon's config copies
rm -f "$(brew --prefix)/etc/wireguard/warp.conf"
rm -rf ~/wg-tunnels                                      # your configs and WARP accounts: keep a copy if you need them
```

With the menu bar:

```sh
launchctl bootout gui/$(id -u)/com.local.swiftbar
rm -f ~/Library/LaunchAgents/com.local.swiftbar.plist
rm -f "$(defaults read com.ameba.SwiftBar PluginDirectory)/tunnel-status.5s.sh"
brew uninstall --cask swiftbar                            # if nothing else uses it
```

And the packages, if nothing else uses them: `brew uninstall wgcf wireguard-tools`.
