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

A carrier with WARP inside it is a *warped tunnel*. An ordinary WireGuard
config, used as it is, is a *plain tunnel*; those work here too, alongside the
warped ones.

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
  only encrypted WARP traffic. Cloudflare sees where the traffic goes, but
  from the carrier's IP. Your local network and ISP see only the carrier
  tunnel.
- **It works where WARP is blocked.** A network that blocks WARP still
  reaches the carrier.

The trade-offs: an extra hop (a little latency, and an MTU of 1280 inside the
carrier), and a few sites block WARP too. It hides your location from sites,
but it isn't an anonymity tool: Cloudflare sees where your traffic goes, and
each WARP account is tied to one device. Some streaming services flag WARP
addresses; for those, use a plain tunnel to the carrier's server (a second
config from the provider, with its own key).

For the server side (a WireGuard server that exits through WARP itself), see
[wireguard-tools](https://github.com/cgmckeever/wireguard-tools).

## Two ways to run it

There are two separate setups, one for this Mac and one for phones and other
devices. Use either, or both:

| | [Local Mac Tunnels](#local-mac-tunnels) | [Sing-Box Device Tunnels](#sing-box-device-tunnels) |
|---|---|---|
| For | This Mac's own traffic | iPhone, iPad, Apple TV, Android (the Mac too, if you like) |
| Runs the tunnels | A root daemon on the Mac (`wg-quick` under launchd) | The [sing-box](https://sing-box.sagernet.org) app on the device |
| You use | `tunnel.sh`, and an optional menu bar lock | `singbox.sh` on the Mac to build profiles, then the app |
| Kill switch | Yes: nothing leaves outside a tunnel, even if it fails | Only while the app runs |
| Install | `install.sh`, choice 1 | `install.sh`, choice 2 |

**Local Mac Tunnels.** The WireGuard app's tunnels on a Mac belong to one macOS
user and stop passing traffic after a user switch. Here a root daemon runs
them instead: they work for every user, come back after a reboot, are
restarted when they fail, and a kill switch blocks traffic whenever a tunnel
is wanted but down.

**Sing-Box Device Tunnels.** iOS, tvOS and Android can't run the daemon, and their
WireGuard app can't put one tunnel inside another. The sing-box app can.
`singbox.sh` turns a device's configs into sing-box profiles on your Mac; you
import them in the app on the device. The Mac is only a workbench here: the
device never talks to it, and nothing changes how the Mac itself connects.

## Quick start

On your Mac (macOS and [Homebrew](https://brew.sh) needed):

1. **Get the scripts.**
   ```sh
   git clone https://github.com/cgmckeever/wireguard-tunnels.git ~/Documents/code/wireguard-tunnels
   ```
   It can live anywhere; this README uses `~/Documents/code/wireguard-tunnels`.
2. **Install.** Run it as yourself, not with `sudo`:
   ```sh
   cd ~/Documents/code/wireguard-tunnels
   ./install.sh
   ```
   It asks which:
   ```
   1) Full Local Mac Tunnels (this Mac's traffic; sing-box devices too)
   2) Only Sing-Box Device Tunnels (phones, Apple TV: no daemon, no sudo)
   Choice [1]:
   ```
   Pick **1** if you want **this Mac's** traffic tunneled; it then offers the
   [menu bar lock](#menu-bar-optional). Pick **2** if you only want tunnels
   on **phones, tablets or an Apple TV**: the Mac's own connection is left
   alone, and you can run the full install later.

   Both make your folders ([Your folders](#your-folders)): 1 asks for this
   Mac's device name (`mbp-1`, say), 2 for a first device (`iphone`, say).
3. **Add tunnels:** [Mac quick start](#mac-quick-start) or
   [sing-box quick start](#sing-box-quick-start).

The scripts run by path. Aliases make that shorter, e.g. in `~/.zshrc`:

```sh
alias tunnel=~/Documents/code/wireguard-tunnels/scripts/tunnel.sh
alias singbox=~/Documents/code/wireguard-tunnels/scripts/singbox.sh
```

From here on this README writes just `tunnel.sh` and `singbox.sh`.

### install.sh

Safe to re-run, e.g. after a `git pull`: each step checks first, changes only
what's missing or out of date, and prints `ok` or `changed`.
The questions (1 or 2, then the menu bar lock) come only on a Mac without
Local Mac Tunnels yet, in a terminal, with no options. Otherwise the options
decide: the full install, `--swiftbar` for the menu bar lock, `--sing-box`
for 2.

| Step | `install.sh` | `--sing-box` |
|------|--------------|--------------|
| Homebrew packages | `wireguard-tools` (`wg`, `wg-quick`, `wireguard-go`), `wgcf` (WARP accounts), `jq` (sing-box profiles), `qrencode` ([qr.sh](#a-tunnel-as-a-qr-code)) | `wgcf`, `jq`, `qrencode` |
| Folders | This Mac's device, `~/wg-tunnels/devices/<mac>/`; writes `<mac>` to `.default` | A first device, `~/wg-tunnels/devices/<device>/` (`singbox.sh new`) |
| WARP | Registers a free WARP account for this Mac (`wgcf register`, which accepts Cloudflare's terms of service) and writes `$(brew --prefix)/etc/wireguard/warp.conf` from it | The first device's own account |
| Daemon | Installs `/usr/local/sbin/wg-tunnels` (a copy of `tunnel.sh`) and the `com.local.wg-tunnels` LaunchDaemon, using `sudo`, when the repo copy differs or the LaunchDaemon is missing | none |

| Option | What |
|--------|------|
| `--device <name>` | The device name, without asking: this Mac's, or with `--sing-box` the first device's. Needed the first time when there's no terminal (e.g. Ansible) |
| `--swiftbar` | Also the [menu bar lock](#menu-bar-optional): SwiftBar, the plugin, and a LaunchAgent that keeps SwiftBar running. Re-run with it to add the lock later |
| `--no-daemon` | Skip the daemon step, for automation that can't answer a `sudo` prompt. Then run `tunnel.sh install`, or as root (e.g. Ansible `become`): `scripts/tunnel.sh _install <path/to/scripts/tunnel.sh>` |
| `--sing-box` | Only what Sing-Box Device Tunnels need (above). Takes only `--device` |

## Your folders

Every *device* (this Mac, an iPhone, an Apple TV) gets a folder on this Mac,
in `~/wg-tunnels/devices/`, with its own keys and its own WARP account:

```
~/wg-tunnels/devices/
  .default     this Mac's device name, e.g. mbp-1 (Local Mac Tunnels only)
  mbp-1/       this Mac
  iphone/      a sing-box device
```

`install.sh` makes this Mac's folder (or, with `--sing-box`, a first
device's); `singbox.sh new <device>` makes the others. Name each the way your
configs name the device (wireguard-tools' `dengar.mbp-1.conf` belongs in
`mbp-1/`). Inside each:

| Folder | What goes there | Used by |
|--------|-----------------|---------|
| `carriers/` | Carrier configs, as downloaded from your provider or server: each becomes a [warped tunnel](#warped-tunnels), `config/warped.<name>.<device>.conf` | both |
| `config/` | Every tunnel, one `.conf` each; the file name is the tunnel name. Plain configs go here as they are; the `warped.*` files and `warp.<device>.conf` are written for you | both |
| `warp/` | The device's own WARP account (`wgcf-account.toml`, `wgcf-profile.conf`) | both |
| `exports/` | Zips from the WireGuard app's *Export Tunnels to Zip…*, if you keep tunnels there ([extract](#tunnelsh)) | Local Mac Tunnels |
| `sing-box/` | The sing-box profiles built from `config/`, to import in the app | Sing-Box Device Tunnels |

They're all `0700`: everything in `~/wg-tunnels` holds private keys. Nothing
here sends them anywhere; only the sing-box profiles you send yourself leave
the Mac.

### Keys

Every config needs its own WireGuard key, not used by any other config, on
this device or another. Two configs on one key knock each other off whenever
both are up, and a lost device can be revoked on its own. Get one by
downloading a new config for that device from your provider or server.

WARP keys work the same way, which is why each device has its own WARP
account: `install.sh` registers this Mac's, `singbox.sh new` each other
device's.

## Warped tunnels

A warped tunnel starts as a carrier: an ordinary WireGuard config from your
provider or server, saved in the device's `carriers/`. Each setup turns every
carrier into a warped tunnel in `config/` for you, whenever it updates its
tunnels; this step is called the *sweep*. How each setup runs it is in its own
section ([Local Mac Tunnels](#warped-tunnels-on-this-mac),
[Sing-Box Device Tunnels](#what-build-accepts-and-writes)).

**What the sweep writes.** On the `iphone` device, `carriers/proton.chicago.conf`
becomes `config/warped.proton.chicago.iphone.conf`, with `AllowedIPs` set to the WARP endpoint
(plus [extras](#extras)), the `DNS` line removed, and
`PersistentKeepalive = 25`, so the carrier carries WARP and nothing else. The
`warped.` prefix is what marks a tunnel as warped. The device's name (its
folder's) always goes last. If the carrier's name already has it elsewhere,
as a word of its own between `.`, `_` or `-`, it's moved there:
`carriers/proton.chicago_iphone-US-IL-802.conf` becomes
`warped.proton.chicago-US-IL-802.iphone`.

**WARP alone.** The sweep also writes `config/warp.<device>.conf`: the
device's WARP account from `warp/`, with no carrier, on the same
[endpoint](#warp-endpoint) as the warped tunnels. It's a plain tunnel: on
this Mac `tunnel.sh import` takes it as a full tunnel (in the menu under
OTHER), and it shares the WARP key safely because the daemon runs one tunnel
at a time. It also works in the WireGuard app. sing-box doesn't use it:
`build` makes `warp.<device>` from `warp/` directly. `singbox.sh new` runs the sweep
too, so a new device has its `warp.<device>.conf` right away.

**Edit the carrier, not the warped file.** Every sweep writes the warped file
again from its carrier (only when it changes). `x.conf`, `warped.x.conf` and
`warped-x.conf` in `carriers/` all become `warped.x.<device>`, so keep only one: if
there are several, one is used and the rest are reported as skipped. A carrier
that isn't a one-peer WireGuard config is skipped too. Other files in
`config/` are left alone: a
`warped.*` file whose carrier is gone is reported as an *orphan* (delete it
yourself), anything else (a plain tunnel) as *manual*.

### Extras

A carrier routes only WARP, so the server can't reach your device, or your
device the server, unless that address is in `AllowedIPs` too. The sweep adds
these *extras* from two kinds of header line in the carrier file:

```ini
# device-network: 10.9.8.0/24     # written by the wireguard-tools server repo
# tunnel-routes: 10.0.0.5/32      # your own: anything else to send through the carrier
```

`device-network` is the server's static device addresses (from the
wireguard-tools server repo, not the Homebrew package of the same name):
`10.9.8.1` is the server, `10.9.8.<number>` a device.

Extras are rebuilt on every sweep: delete a line and they're gone the next
time. A `#` after the addresses starts a
comment. Entries wider than a /8 (/16 for IPv6) would take traffic away from
WARP, so they're ignored and reported, as is anything that isn't an address
(a hostname, a typo).

### Small carrier MTU

WARP's packets grow by up to 80 bytes inside the carrier. A carrier with an
MTU under 1360 (a server set to 1280, say) can't fit WARP's 1280: ping works
and nothing else does. Both setups handle it: WARP runs at the carrier's MTU
minus 80 (1200 inside a 1280 carrier). The sweep's report flags these
carriers. Below 1280 there's no IPv6 inside WARP and QUIC falls
back to TCP; pages still load.

**WARP alone behind a tunnel you can't see.** `warp.<device>` on this Mac
can ride a carrier that isn't the Mac's: a travel router that tunnels
everything to a remote exit, say, so Cloudflare sees that exit. The daemon
can't read that carrier's MTU, so it measures instead. Once WARP is up, it
sends a full-size don't-fragment ping through it to `1.1.1.1` (WARP's
endpoint doesn't answer ping). If that's lost but a 1200-byte one gets
through, WARP runs at 1200. It measures again when the network changes and
every 5 minutes (a router can switch exits behind the same address), and
goes back to the config's MTU where that fits. The log says when it changes.
Pick a router exit that doesn't go through WARP on the server, or it's WARP
inside WARP.

### WARP endpoint

WARP connects to `162.159.192.1:2408` unless `~/wg-tunnels/.warp-endpoint`
says otherwise: one line, IPv4 `address:port`, for every device. The sweep
writes it into each warped tunnel, so a device's warped tunnels and its WARP
side must agree. To change it, edit the file, then redo each setup: on this
Mac, re-run `install.sh` (it rewrites the WARP config) and
[import](#tunnelsh); for each sing-box device, [build](#singboxsh). Until
then, this Mac skips warped tunnels whose endpoint doesn't match its WARP
config.

One device can have its own: `~/wg-tunnels/devices/<device>/.warp-endpoint`,
same format, read before the shared file by the sweep and `singbox.sh build`.
It's for a device whose own WARP would otherwise catch other devices' WARP: a
router running WARP on `162.159.192.1` keeps a route to it out its WAN, so a
Mac behind it that also uses `.1` has its WARP packets sent past the router's
tunnel and dropped. Give the router another Cloudflare address (say
`162.159.192.5:2408`) and leave everyone else on the shared one.

## Local Mac Tunnels

Tunnels on this Mac, run by a root daemon, with a kill switch and an optional
menu bar lock.

### Mac quick start

After `./install.sh`, with `<mac>` the device name it asked for:

1. **Add configs** to `~/wg-tunnels/devices/<mac>/`: carriers in `carriers/`
   (they become warped tunnels), plain tunnels in `config/`.
2. **Import** them for the daemon. It shows what will change and asks first:
   ```sh
   tunnel.sh import
   ```
3. **Bring one up.** It asks `warped [Y/n]` (`n` for a plain tunnel), then
   which:
   ```sh
   tunnel.sh up
   ```
4. **Check it** with `tunnel.sh status`; `tunnel.sh down` returns you to your
   normal connection.

Lost the network, or also using the WireGuard app? See
[Troubleshooting](#troubleshooting).

### tunnel.sh

`tunnel.sh <command>`:

| Command | What |
|---------|------|
| `up [n\|name]` | Asks `warped [Y/n]`, then which tunnel (Enter = the last one used, or the only one). A number picks from the warped list; a name skips both questions |
| `down` | Everything down, back to the normal connection |
| `pause [min]` | For a hotel or café sign-in page: the tunnel down and the kill switch off for `min` minutes (default 10, up to 1440), then the daemon brings the tunnel back by itself, also after a reboot. Again while paused sets a new end time |
| `resume` | End a pause now |
| `status` (default) | Tunnels, what's up, handshakes, the kill switch, the exit IP |
| `list` | Number the warped and other tunnels |
| `import [dir] [-y]` | Turn `<mac>/carriers/` into [warped tunnels](#warped-tunnels) in `config/`, then install every `.conf` in `<mac>/config/` for the daemon, and sort each into its [kind](#tunnel-kinds). Given a `dir`, installs the `.conf` files there instead, with no sweep. Tunnels no longer there are removed, unless up right now. Shows what it would do (new, updated, unchanged, removed, and the WARP config) and asks; `-y`, or no terminal, skips the question |
| `extract [zip]` | For tunnels kept in the WireGuard app: replace `<mac>/config/` with the `.conf` files in the newest zip from its *Export Tunnels to Zip…* in `<mac>/exports/` (or the one given). Configs not in the zip are removed (warped ones come back from `carriers/` on the next `import`). The zip is kept |
| `extract-import [zip]` | `extract`, then `import` |
| `default [device]` | Show or change this Mac's device, saved in `~/wg-tunnels/devices/.default`. `extract`, `import` and `rotate-warp` use it. Changing it doesn't touch the daemon; run `import` after |
| `rotate-warp` | New WARP keys: registers a new WARP account (through `install.sh`), imports it, and reconnects a warped tunnel that's up. The old account's files are deleted once that works (Cloudflare isn't told), or put back if registering fails. This Mac only: sing-box devices keep their own accounts |
| `diag [file]` | Write one file with what's needed to debug: the daemon's status, configs, `wg show`, interfaces, routes, DNS and the last 300 log lines. Private and preshared keys are removed; server IPs and networks aren't, so read it before you share it. Default `~/wg-tunnels/diag/diag-<time>.txt` |
| `log` | Follow the daemon's log |
| `breakglass` | Lost the network? See [Troubleshooting](#troubleshooting) |
| `update` | Update the daemon from the repo's `tunnel.sh`, only if it differs (or its LaunchDaemon is missing), e.g. after a `git pull`. Restarts the daemon, so a tunnel that's up drops for a few seconds |
| `install` | Install just the daemon, even when it's current |
| `uninstall` | Take everything down and remove the daemon; configs are kept |

`up`, `down`, `pause`, `resume`, `import`, `rotate-warp`, `diag`, `update`,
`install`, `uninstall` and `breakglass` use `sudo`. `up`, `down` and `import` also update the daemon
first when the repo copy differs, as `update` does.

#### Tunnel kinds

`tunnel.sh import` sorts each tunnel into one of three kinds:

| Kind | What | Kill switch |
|------|------|-------------|
| **warped** | Named `warped.*`: a carrier with WARP inside. Sites see a Cloudflare IP in the carrier's city | yes |
| **full** | Routes all of IPv4 (`0.0.0.0/0`, or the two `/1` halves) | yes |
| **split** | Anything else: only the networks in its `AllowedIPs` | no |

The kill switch blocks all traffic outside the tunnel until you run
`tunnel.sh down`. A failing tunnel never falls back to your normal connection.

### Warped tunnels on this Mac

`tunnel.sh import` runs the [sweep](#warped-tunnels) on
`~/wg-tunnels/devices/<mac>/carriers/` first, then installs everything in
`config/`, so a new or changed carrier needs only an `import`. The sweep's
report also says, per tunnel, what to do about the WireGuard app's copy, if
you keep one there. To see that report without importing, run
`scripts/wgwarp-sweep.sh`.

`import` installs a `warped.*` file only if it still looks swept: the WARP
endpoint in `AllowedIPs`, nothing wider than a /8 (/16 for IPv6), and no
`DNS` line. One that fails (usually edited by hand) is skipped, not fixed. An
orphan still looks swept, so it's imported until you delete it.

The daemon starts WARP inside the carrier at the right MTU
([Small carrier MTU](#small-carrier-mtu)) and logs when it lowers it.

### Menu bar (optional)

The full install offers it (or `install.sh --swiftbar` adds it later): a
lock icon in the menu bar, through
[SwiftBar](https://github.com/swiftbar/SwiftBar), showing whether you're
protected:

Each state has its own icon, and it comes from the daemon's status, so the
lock is green only once the daemon has seen a handshake:

| Icon | State |
|------|-------|
| green lock | Up: the exit has a recent handshake (or a tunnel in the WireGuard app is connected) |
| yellow turning lock | Connecting, or reconnecting an exit that's gone silent |
| orange lock with `!` | Blocked: a tunnel is wanted but not up, and the kill switch is holding traffic. The menu says why |
| red open lock | Failed: a split tunnel isn't up (no kill switch, so traffic goes out normally) |
| blue pause | Paused: no tunnel and no kill switch until the time shown |
| grey open lock | No VPN |
| red triangle | The daemon isn't answering |

While a tunnel is up the menu shows its uptime, the exit and real IPs with
their city (from [ipinfo.io](https://ipinfo.io)), handshakes, the kill
switch and Tx/Rx, and two checks:

- **WARP**: Cloudflare's own answer for the exit (`cdn-cgi/trace`): on, and
  the data center. A warped tunnel that isn't exiting through WARP is shown
  in red.
- **DNS**: the system's resolver and whether its packets go out through the
  tunnel's exit; red when they leave outside it, orange when the kill switch
  blocks them.

Both are checked again after every reconnect. The menu has:

- **Status**, **Reconnect**, **Disconnect** and **Breakglass**.
- **Pause Protection** for 5 minutes, 15 minutes or 1 hour, while the kill
  switch is on (`tunnel.sh pause`), and **Resume Now** while paused.
- Every imported tunnel, to switch to.
- **More**: status in Terminal, the log, Export Diagnostics (`tunnel.sh diag`;
  shows the file in Finder), Rotate WARP Keys, and Update Daemon
  (`tunnel.sh update`; it says "out of date" when the repo's `tunnel.sh`
  differs from the daemon's copy).

Actions outside Terminal run in the background, ask for your password in a
dialog when they need `sudo` (`scripts/askpass.sh`), and report the result as
a notification.

What it installs:

- SwiftBar, if `/Applications/SwiftBar.app` is missing.
- Its plugin folder, if none is set: `~/.config/swiftbar`.
- The plugin: a symlink to `scripts/swiftbar/tunnel-status.5s.sh`, so a
  `git pull` updates it.
- `~/Library/LaunchAgents/com.local.swiftbar.plist`, which starts SwiftBar at
  login and again if it crashes or is killed. Skipped when another LaunchAgent
  already runs SwiftBar. If SwiftBar is also a Login Item, remove it there, or
  two copies run.

### Troubleshooting

Start here when a tunnel or the network misbehaves.

- **What's going on?** Run `tunnel.sh status`, then `tunnel.sh log` (the
  daemon's log, `/var/log/wg-tunnels.log`). To send it to someone, use
  `tunnel.sh diag`.
- **Behind a hotel or café sign-in page?** The kill switch blocks it. Run
  `tunnel.sh pause` (or the menu's Pause Protection), sign in, and the tunnel
  comes back by itself.
- **No network, even after `down`?** Run `tunnel.sh breakglass`. It trusts no
  saved state: it stops WireGuard app tunnels, the daemon, `wg-quick` and
  `wireguard-go`; removes every route of ours and any reject route; resets
  tunnel DNS left on network services to DHCP; and power cycles Wi-Fi if it
  has no address. It runs from the repo, so it works even if the daemon is
  broken.
- **A warped tunnel connects but nothing loads?** See
  [Small carrier MTU](#small-carrier-mtu). If `import` skipped it, see
  [Warped tunnels on this Mac](#warped-tunnels-on-this-mac).
- **Also using the WireGuard app?** That's fine, with two rules. Turn off On
  Demand for its tunnels: it reconnects behind `up` and breaks the tunnel, so
  `up` refuses while it's on. And switch an app tunnel on only after `down`,
  or the kill switch swallows its traffic. `up` stops app tunnels for you.

### How it works

What the daemon does, for debugging or curiosity.

`tunnel.sh` is both the command and, installed as `/usr/local/sbin/wg-tunnels`,
the root daemon. `import` copies each config to
`$(brew --prefix)/etc/wg-tunnels` (root-owned, interfaces named `wtN`) and
resolves endpoint hostnames there, since DNS can be cut off while switching.
`up` and `down` record what's wanted and wake the daemon, which does the work
and reports progress back to the waiting command. The WARP side of a warped
tunnel is `$(brew --prefix)/etc/wireguard/warp.conf`; the daemon starts it
inside the carrier (don't bring it up on its own).

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

| Path | What |
|------|------|
| `$(brew --prefix)/etc/wireguard/warp.conf` | WARP for `wg-quick`, written by `install.sh` |
| `$(brew --prefix)/etc/wg-tunnels/` | The daemon's copies: `conf/`, `tunnels.tsv`, `state/` |
| `/usr/local/sbin/wg-tunnels` | The daemon (a copy of `tunnel.sh`) |
| `/Library/LaunchDaemons/com.local.wg-tunnels.plist` | Its LaunchDaemon |
| `/var/run/wg-tunnels/status` | Live state, read by `status` and the menu bar |
| `/var/log/wg-tunnels.log` | The daemon's log |

### Uninstall

```sh
tunnel.sh uninstall                                       # tunnels down, daemon removed
sudo rm -rf "$(brew --prefix)/etc/wg-tunnels"            # the daemon's config copies
rm -f "$(brew --prefix)/etc/wireguard/warp.conf"
rm -rf ~/wg-tunnels/devices/<mac>                         # this Mac's configs and WARP account: keep a copy if you need them
```

`~/wg-tunnels/devices/` also holds your sing-box devices; remove all of
`~/wg-tunnels` only if you don't use them.

With the menu bar:

```sh
launchctl bootout gui/$(id -u)/com.local.swiftbar
rm -f ~/Library/LaunchAgents/com.local.swiftbar.plist
rm -f "$(defaults read com.ameba.SwiftBar PluginDirectory)/tunnel-status.5s.sh"
brew uninstall --cask swiftbar                            # if nothing else uses it
```

And the packages, if nothing else uses them: `brew uninstall wgcf wireguard-tools jq qrencode`.

## Sing-Box Device Tunnels

Tunnels on an iPhone, iPad, Apple TV or Android device, warped ones included,
through the [sing-box](https://sing-box.sagernet.org) app: a WireGuard
endpoint there can send its packets through another (a `detour`), so WARP
rides inside the carrier in one VPN. `singbox.sh build` writes a device's
tunnels as *profiles*, JSON files you import in the app.

A device with only plain tunnels can use the WireGuard app instead. iOS runs
one VPN at a time, though, so using a tunnel in that app means leaving
sing-box.

### sing-box quick start

After `./install.sh` (choice 2), with `iphone` the device it asked for (no
device yet, or another one? `singbox.sh new <device>` first):

1. **Add its configs** to `~/wg-tunnels/devices/iphone/`: carriers in
   `carriers/` (they become warped tunnels), plain full tunnels in `config/`.
   At least one, each a new config made for this device ([Keys](#keys)).
2. **Build its profiles** into `~/wg-tunnels/devices/iphone/sing-box/`:
   ```sh
   singbox.sh build iphone
   ```
3. **On the phone**, install the sing-box app (1.12 or later), then AirDrop
   `iphone.json` to it and open it in the app: every tunnel, with a
   picker. More in [Getting a profile to the device](#getting-a-profile-to-the-device).

### Which profile to import

`build` writes three kinds of profile; the app runs one profile at a time:

| Profile | What's in it | Switching tunnels |
|---------|--------------|-------------------|
| `<device>.json` (the composite) | Every tunnel (warped ones first, `warp.<device>` last) | In the app's picker, without dropping the VPN |
| `<group>.list.<device>.json` | One group of tunnels (below) | In the picker, as in the composite |
| `<tunnel>.json` (e.g. `warped.proton.chicago.iphone.json`, `dengar.iphone.json`, `warp.iphone.json`) | One tunnel | By starting another profile: the VPN drops for a moment |

A group is every tunnel whose name starts with the same first word (in any
case), the server it goes to: `<server>.list.<device>.json`.

| Group profile | Tunnels in it |
|---------------|---------------|
| `dengar.list.iphone.json` | `dengar.chicago.iphone`, `dengar.warped.chicago.iphone` |
| `proton.list.iphone.json` | `proton.chicago`, `proton.toronto` (provider configs used directly) |
| `warped.list.iphone.json` | Every `warped.*` tunnel, whatever carries it, and `warp.iphone` |

A group is only written when it has two or more tunnels, even if it ends up
holding the same tunnels as the composite. So name every config
`<server>.<name>.conf`: `proton.chicago.conf`, not `chicago.conf`
(wireguard-tools' names already are). Carriers follow the same rule for
readable names, though their warped tunnels all group under `warped`:
`carriers/proton.chicago.conf` gives `warped.proton.chicago.iphone`.

Every device also gets a `warp.<device>` tunnel, as `warp.<device>.json`, in the composite, and
in `warped.list.<device>.json` when it has a warped tunnel to join:
WARP alone, straight from the device's network, with no carrier. It uses the
device's own WARP account, so it needs no config of its own. Traffic exits
through Cloudflare, but the network you're on can see you're using WARP; a
warped tunnel hides that inside the carrier.

Start with the composite: one import, and you switch tunnels in the picker.
Use a group to keep the picker short (only your own server's tunnels, say),
and one-tunnel profiles when a server must reach the device through an idle
tunnel (a home server, say), or when one tunnel's small MTU would slow the
rest. You can import any mix.

sing-box starts every tunnel in a profile at once, not just the one picked.
So the composite and the groups leave out keepalives: each tunnel talks to its server only
while it carries traffic. Otherwise every tunnel would stay connected, and the
warped ones, sharing the device's WARP key, would knock each other off. The
costs:

- a server can't reach the device through an idle tunnel;
- the whole VPN runs at the smallest MTU of any tunnel in it.

A one-tunnel profile keeps the config's keepalive and its own MTU.

### Getting a profile to the device

Profiles hold private keys: send them directly (AirDrop), not through email,
chat or a shared folder.

**iPhone or iPad**

1. AirDrop the profile from `sing-box/` to the device.
2. Open it in the sing-box app, which adds it as a new profile (or, in the
   app: *Profiles > New Profile > Import*).
3. Delete the copy you sent.

**Apple TV**

1. Give it its own device (`singbox.sh new appletv`), so it has its own keys.
2. An Apple TV can't receive AirDrop, so AirDrop its profile to an iPhone and
   import it in the iPhone's sing-box app. Don't start it there: the two would
   share keys.
3. On the Apple TV, choose *Import profile from iPhone/iPad* (as the sing-box
   docs list it).

The app's QR scanner only takes links, not a whole profile, so it won't work
for these.

### A tunnel as a QR code

For the WireGuard app rather than sing-box, `scripts/qr.sh` shows any
tunnel in a device's `config/` as a QR code, to scan with *+ > Create from QR
code*:

```
scripts/qr.sh                      # pick a device, then one of its tunnels
scripts/qr.sh iphone               # pick one of iphone's tunnels
scripts/qr.sh iphone warp.iphone   # that one (a name, or its number)
```

`warp.<device>` is WARP alone; any plain tunnel works too. A `warped.*`
tunnel only carries WARP, and the WireGuard app can't run one tunnel inside
another, so it does nothing there alone: use sing-box for those. The QR holds
the private key: show it only to the device it's for, and clear the terminal
after (Cmd-K).

### Updating a device

1. Change `carriers/` or `config/`: add, replace or delete a `.conf`.
2. Run `singbox.sh build <device>`. It lists each profile as `new`,
   `updated`, `unchanged`, or removed (no longer built: its tunnel is gone, or
   its group is down to one).
3. Send only the `new` and `updated` ones. In the app, delete the old profile
   and import the new one; an import adds a profile, it doesn't replace one.

A carrier removed from `carriers/` drops out of the profiles on the next
build, but its `warped.<carrier>.<device>.conf` stays in `config/` until you delete it.

### What build accepts and writes

**Configs.** Plain configs should be full tunnels (`AllowedIPs` with
`0.0.0.0/0`). A profile sends all of the device's traffic to the tunnel in
use, so a split config (a home LAN only, say) leaves the device with nothing
past its own networks, not even DNS; `build` warns about one. `build` skips,
and reports, a config it can't use: it needs `[Interface]`, one `[Peer]`, a
`PrivateKey`, `PublicKey`, `Address`, an `Endpoint` as `host:port`, and a
numeric `MTU` if one is set.

**Warped tunnels.** `build` runs the [sweep](#warped-tunnels) on the device's
`carriers/` first (`scripts/wgwarp-sweep.sh <device>` shows the same report on
its own). It skips a `warped.*` file whose carrier is missing from
`carriers/` or broken, so orphans drop out of the profiles.

**Keys.** `build` stops on a key shared with another device, and names the
files (never the key); see [Keys](#keys). A key used twice on one device (a
carrier copied from a config in `config/`, say) only gets a note: a device
runs one tunnel at a time.

**Names.** These tunnel names are reserved: `tunnel`, `warp.<device>`,
`<device>` (the composite), `<group>.list.<device>` and `carrier.<carrier>`.

**Profiles.**

- A `warped.<carrier>` is WARP detoured through that carrier, at 1280, or the
  carrier's MTU minus 80 when that's smaller
  ([Small carrier MTU](#small-carrier-mtu)). `warp.<device>` is the same WARP endpoint
  with no carrier, at 1280. Any other config is an endpoint as it stands.
- DNS goes to 1.1.1.1 through the tunnel in use, whatever a config's own
  `DNS` line says.
- `strict_route` keeps traffic in the VPN. sing-box has no kill switch; this
  is the closest it gets.
- A server given by hostname is looked up on the device's own network, since
  through the tunnel it would need that tunnel up first.
- A carrier's [extras](#extras) get a rule sending them to the carrier, since
  `AllowedIPs` doesn't route in sing-box. In the composite and the groups
  the rule applies whichever tunnel is picked; if two carriers list the same
  network, the first keeps it and `build` warns (it only spots identical entries, not
  overlapping ones).

**The folder.** `build` owns `sing-box/`: a `.json` there that it didn't
write is removed. When `sing-box` is installed on the Mac, `build` checks
every profile with `sing-box check` before replacing any: if one fails, none
change.

### singbox.sh

`singbox.sh <command>`:

| Command | What |
|---------|------|
| `new <device>` | Make `~/wg-tunnels/devices/<device>/` and register the device's own WARP account (needs `wgcf`) |
| `build <device>` | Sweep its carriers, then write its profiles into its `sing-box/` (needs `jq`) |
| `list` | Each device's carriers, tunnels and profiles, whether it has a WARP account, and which is this Mac |

### sing-box on this Mac

The sing-box Mac app can run this Mac's tunnels instead of the daemon. Build
the Mac like any other device (without Local Mac Tunnels, make it first with
`singbox.sh new mbp-1`):

```sh
singbox.sh build mbp-1
```

Import the profiles in the sing-box app on the Mac. If you also use Mac
tunnels, the profiles use the daemon's keys, so run one or the other:
`tunnel.sh down` before turning sing-box on, and sing-box off before
`tunnel.sh up`. While sing-box runs instead of the daemon you lose the kill
switch (if the app quits, traffic goes out directly), the menu bar lock and
the `tunnel.sh` commands.

### Removing a device

1. Delete its profiles in the sing-box app on the device.
2. Remove its folder: `rm -rf ~/wg-tunnels/devices/<device>`.
3. If the device is lost or gone for good, revoke its configs on your
   provider or server.
