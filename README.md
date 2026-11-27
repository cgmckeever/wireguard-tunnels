# wireguard-tunnels

*Cloudflare exit IPs, tunneled through your WireGuard region*

## Contents

- [Overview](#overview): [terms](#terms), [two ways to run it](#two-ways-to-run-it)
- [Quick start](#quick-start): [install.sh](#installsh), [conventions](#conventions)
- [Your folders](#your-folders): [devices](#devices), [servers](#servers), [keys](#keys)
- [Warped tunnels](#warped-tunnels) and the sweep: [extras](#extras), [small carrier MTU](#small-carrier-mtu), [WARP endpoint](#warp-endpoint)
- [Local Mac Tunnels](#local-mac-tunnels): [Mac quick start](#mac-quick-start), [`tunnel.sh`](#tunnelsh) ([tunnel kinds](#tunnel-kinds)), [warped tunnels on this Mac](#warped-tunnels-on-this-mac), [WARP alone behind a router](#warp-alone-behind-a-router), [the menu bar lock](#menu-bar-optional), [how it works](#how-it-works), [uninstall](#uninstall)
- [Sing-Box Device Tunnels](#sing-box-device-tunnels): [sing-box quick start](#sing-box-quick-start), [which profile](#which-profile-to-import), [getting it to the device](#getting-a-profile-to-the-device), [updating](#updating-a-device), [what build accepts](#what-build-accepts-and-writes), [`singbox.sh`](#singboxsh), [sing-box on this Mac](#sing-box-on-this-mac), [removing a device](#removing-a-device)
- [QR codes](#a-tunnel-as-a-qr-code), [NordVPN](#nordvpn), [the folder shared with wireguard-tools](#shared-folder), [checking the store](#checking-the-store)
- [Troubleshooting](TROUBLESHOOTING.md)
- [Developing](#developing)

## Overview

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
[wireguard-tools](https://github.com/cgmckeever/wireguard-tools), a separate
repo (not the Homebrew package of the same name, which `install.sh` installs
for `wg` and `wg-quick`). It's optional: everything here works without it. If
you use it, the two share one folder: its client configs land with your
devices' configs, and this repo can set up its servers' exits
([Servers](#servers)).

### Terms

- **Carrier:** an ordinary WireGuard config, from a VPN provider or your own
  server, that WARP rides inside.
- **Warped tunnel:** a carrier with WARP inside it, `warped.<name>.<device>`.
  The *sweep* writes it from the carrier ([Warped tunnels](#warped-tunnels)).
- **Plain tunnel:** any other WireGuard config, used as it is.
- **WARP alone:** `warp.<device>`, the device's own WARP account with no
  carrier. It counts as a plain tunnel (`n` at `tunnel.sh up`).
- **Device:** anything that runs tunnels (this Mac, a phone, an Apple TV). Each
  has its own folder, keys and WARP account ([Devices](#devices)).
- **Kill switch:** on this Mac, routes that block all traffic outside the
  tunnel while one is wanted, so a failing tunnel never falls back to your
  normal connection.

### Two ways to run it

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

On your Mac (macOS 12.3 or later, and [Homebrew](https://brew.sh)):

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

   Both make your folders: 1 asks for this Mac's device name (`mbp-1`, say),
   2 for a first device (`iphone`, say). To keep them somewhere other than
   `~/wg-tunnels`, see [Your folders](#your-folders) first.
3. **Add your WireGuard configs.** The `.conf` files you download from
   your VPN provider or server go in the device's folder, in one of two
   places:
   ```
   ~/wg-tunnels/devices/<device>/      mbp-1 (this Mac) or iphone, say
     config/     plain tunnels: each .conf is used as it is
     carriers/   carriers: processed into warped tunnels (WARP inside)
   ```
   A config in `carriers/` isn't used as it is: `tunnel.sh import` and
   `singbox.sh build` process it into a warped tunnel,
   `config/warped.<name>.<device>.conf`, which is the one you run. Not sure
   which? Use `config/`. Each device needs configs made for it,
   not copies of another device's ([Keys](#keys)).
4. **Use them**, from the repo folder (or set up the aliases in
   [Conventions](#conventions) first):
   - This Mac: `scripts/tunnel.sh import`, then `scripts/tunnel.sh up`
     ([Mac quick start](#mac-quick-start)).
   - A phone or Apple TV: `scripts/singbox.sh build <device>`, then open the
     profile in the sing-box app ([sing-box quick start](#sing-box-quick-start)).

### install.sh

Safe to re-run, e.g. after a `git pull`: each step checks first, changes only
what's missing or out of date, and prints `ok` or `changed`.
It asks (1 or 2, then the menu bar lock) only on a Mac without Local Mac
Tunnels yet, in a terminal, with no options. Otherwise the options decide:
none is the full install, `--swiftbar` adds the lock, `--sing-box` is
choice 2.

| Step | `install.sh` | `--sing-box` |
|------|--------------|--------------|
| Homebrew packages | `wireguard-tools` (`wg`, `wg-quick`, `wireguard-go`), `wgcf` (WARP accounts), `jq` (`nord.sh`), `qrencode` ([qr.sh](#a-tunnel-as-a-qr-code)) | `wgcf`, `jq`, `qrencode` |
| Folders | This Mac's device, `~/wg-tunnels/devices/<mac>/`; writes `<mac>` to `.default` | A first device, if you name one: `~/wg-tunnels/devices/<device>/` (`singbox.sh new`) |
| WARP | Registers a free WARP account for this Mac (`wgcf register`, which accepts Cloudflare's terms of service) and writes `$(brew --prefix)/etc/wireguard/warp.conf` from it | The first device's own account |
| Daemon | Installs `/usr/local/sbin/wg-tunnels` (a copy of `tunnel.sh`) and the `com.local.wg-tunnels` LaunchDaemon, using `sudo`, when the repo copy differs or the LaunchDaemon is missing | none |

| Option | What |
|--------|------|
| `--device <name>` | The device name, without asking: this Mac's, or with `--sing-box` the first device's. Needed the first time when there's no terminal (e.g. Ansible) |
| `--swiftbar` | Also the [menu bar lock](#menu-bar-optional): SwiftBar, the plugin, and a LaunchAgent that keeps SwiftBar running. Re-run with it to add the lock later |
| `--no-daemon` | Skip the daemon step, for automation that can't answer a `sudo` prompt. Then run `tunnel.sh install`, or as root (e.g. Ansible `become`): `scripts/tunnel.sh _install <path/to/scripts/tunnel.sh>` |
| `--sing-box` | Only what Sing-Box Device Tunnels need (above). Takes only `--device` |

### Conventions

- **Running the scripts:** they run by path. `scripts/wgtun.sh` is one entry
  point for them: with no arguments it lists them, each with what it does, and
  asks which to run; `wgtun.sh <script> [args]` runs one (`wgtun.sh tunnel up`,
  `wgtun.sh nord`), and `wgtun.sh <script> -h` shows its commands. One alias
  covers it, e.g. in `~/.zshrc`:

  ```sh
  alias wgtun=~/Documents/code/wireguard-tunnels/scripts/wgtun.sh
  ```

  Or alias each script directly:

  ```sh
  alias tunnel=~/Documents/code/wireguard-tunnels/scripts/tunnel.sh
  alias singbox=~/Documents/code/wireguard-tunnels/scripts/singbox.sh
  alias nord=~/Documents/code/wireguard-tunnels/scripts/nord.sh
  alias qr=~/Documents/code/wireguard-tunnels/scripts/qr.sh
  alias check=~/Documents/code/wireguard-tunnels/scripts/check.sh
  ```

  From here on this README writes just the script name (`tunnel.sh`,
  `singbox.sh`, `nord.sh`, `qr.sh`, `wgwarp-sweep.sh`, `check.sh`): with the
  aliases, type `tunnel` for `tunnel.sh`, and so on.
- **Safe to re-run:** `install.sh`, `import`, `build`, the sweep and
  `nord.sh` change only what's missing or out of date, and say what they
  changed.
- **Scripts and AI agents (no terminal):** nothing waits on a prompt. Give
  what it would ask: `install.sh --device <name>` (and `--no-daemon` where
  `sudo` can't ask for a password), `tunnel.sh up <name>`, and the arguments
  to `nord.sh` and `qr.sh`; `import` goes ahead without asking. A command
  that needs an answer it wasn't given stops and says which. `sudo` still
  needs a password, or a dialog (`SUDO_ASKPASS`, as the menu bar lock uses).
- **Examples:** `mbp-1` is this Mac, `iphone` a sing-box device, `dengar` a
  wireguard-tools server. `<mac>` stands for this Mac's device name, and
  `<device>` for any device's.

## Your folders

Everything lives in `~/wg-tunnels`, and its folders are all `0700`: they
hold private keys. Nothing here sends them anywhere; only the sing-box
profiles you send yourself leave the Mac.

To keep it elsewhere, set `$WG_CONFIG_HOME` to an absolute path (not `~/…`) in
your shell profile before the first `install.sh`; every script here, and
wireguard-tools, reads it. This
README writes `~/wg-tunnels` either way. The
[menu bar lock](#menu-bar-optional) doesn't read it, so its Rotate WARP Keys
and Export Diagnostics only work with the default location.

This repo needs only `devices/`, one folder per device that runs tunnels.
`~/wg-tunnels` is also where [wireguard-tools](#shared-folder) keeps its
files: `fleet/` holds the systems it manages, its
[servers](#servers-wireguard-tools) and [pucks](#pucks-wireguard-tools).
Without wireguard-tools there's no `fleet/`, and nothing here needs one. With
it, this repo reads only each server's `login` and `carriers/`.

```
~/wg-tunnels/
  .warp-endpoint   WARP endpoint for every device (optional)
  .nord-token      NordVPN access token, for nord.sh (optional)
  diag/            tunnel.sh diag output (keys removed)
  devices/
    .default       this Mac's device name, e.g. mbp-1 (Local Mac Tunnels only)
    README-tunnels.md  what this folder is (wireguard-tools adds its own README-tools.md)
    mbp-1/         this Mac
    iphone/        a sing-box device
  fleet/           the systems wireguard-tools manages; not needed here
    servers/
      dengar/      one of its servers
        login      wgt-ctl's SSH login; nord.sh offers only servers with one
        carriers/  its exits (below)
        backups/   wireguard-tools' own (archives, private keys)
    pucks/
      puck1/       one puck's settings (tunnel-puck's own, below)
    device-list.json wireguard-tools' device numbers
```

### Devices

Every *device* (this Mac, an iPhone, an Apple TV) gets a folder in
`devices/`, with its own keys and its own WARP account. `install.sh` makes
this Mac's folder (or, with `--sing-box`, a first device's); `singbox.sh new
<device>` makes the others. Name each the way your configs name the device
(wireguard-tools' `dengar.mbp-1.conf` belongs in `mbp-1/`). Inside each:

| Folder or file | What goes there | Used by |
|--------|-----------------|---------|
| `carriers/` | Carrier configs, as downloaded from your provider or server: each becomes a [warped tunnel](#warped-tunnels), `config/warped.<name>.<device>.conf` | both |
| `config/` | Every tunnel, one `.conf` each; the file name is the tunnel name. Plain configs go here as they are; the `warped.*` files and `warp.<device>.conf` are written for you | both |
| `warp/` | The device's own WARP account (`wgcf-account.toml`, `wgcf-profile.conf`) | both |
| `exports/` | Zips from the WireGuard app's *Export Tunnels to Zip…*, if you keep tunnels there ([extract](#tunnelsh)) | Local Mac Tunnels |
| `sing-box/` | The sing-box profiles built from `config/`, to import in the app | Sing-Box Device Tunnels |
| `.warp-endpoint` | This device's WARP endpoint, if it differs from the global one ([WARP endpoint](#warp-endpoint)) | both |

Only `config/` is required. A device with nothing else (as wireguard-tools
leaves one when it delivers a config) is a normal device with plain configs:
the sweep has nothing to do, `import` and `build` use the configs as they are
(`build` makes no WARP tunnel without `warp/`), and `singbox.sh new <device>`
adds `carriers/`, `warp/` and `config/warp.<device>.conf`, leaving the configs
already there alone.

### Servers

Only with wireguard-tools: see [Servers](#servers-wireguard-tools) under the
folder shared with it.

### Pucks

Only with wireguard-tools: see [Pucks](#pucks-wireguard-tools) under the
folder shared with it.

### Keys

Every config needs its own WireGuard key, not used by any other config, on
this device or another. Two configs on one key knock each other off whenever
both are up, and a lost device can be revoked on its own. Get one by
downloading a new config for that device from your provider or server.

WARP keys work the same way, which is why each device has its own WARP
account: `install.sh` registers this Mac's, `singbox.sh new` each other
device's.

Nord is the exception: see [NordVPN](#nordvpn).

## Warped tunnels

A warped tunnel starts as a carrier: an ordinary WireGuard config from your
provider or server, saved in the device's `carriers/`. `tunnel.sh import`
(this Mac) and `singbox.sh build` (sing-box devices) first turn every carrier
into a warped tunnel in `config/`; this step is the *sweep*. More in each
setup's own section ([Local Mac Tunnels](#warped-tunnels-on-this-mac),
[Sing-Box Device Tunnels](#what-build-accepts-and-writes)).

**What the sweep writes.** On the `iphone` device, `carriers/proton.chicago.conf`
becomes `config/warped.proton.chicago.iphone.conf`, with `AllowedIPs` set to the WARP endpoint
(plus [extras](#extras)), the `DNS` line removed, and
`PersistentKeepalive = 25`, so the carrier carries WARP and nothing else. The
`warped.` prefix is what marks a tunnel as warped. The device's name (its
folder's) always goes last, and is moved there if the carrier's name already
has it as a separate word (between `.`, `_` or `-`):
`carriers/proton.chicago_iphone-US-IL-802.conf` becomes
`warped.proton.chicago-US-IL-802.iphone`.

**WARP alone.** The sweep also writes `config/warp.<device>.conf`: the
device's WARP account from `warp/`, with no carrier, on the same
[endpoint](#warp-endpoint) as the warped tunnels. It's a plain tunnel: on
this Mac `tunnel.sh import` takes it as a full tunnel (in the menu under
OTHER), and it shares the WARP key safely because the daemon runs one tunnel
at a time. It also works in the WireGuard app, and `build` makes sing-box's
`warp.<device>` from it, so WARP is the same everywhere. It has
`PersistentKeepalive = 25`, as every one-tunnel config should.
`singbox.sh new` runs the sweep too, so a new device has `warp.<device>.conf`
at once. On this Mac every `import` sweeps again, picking up new keys after
`rotate-warp`, or a new [endpoint](#warp-endpoint) once `install.sh` has
rewritten the WARP config.

**Edit the carrier, not the warped file.** Every sweep writes the warped file
again from its carrier (only when it changes). `x.conf`, `warped.x.conf` and
`warped-x.conf` in `carriers/` all become `warped.x.<device>`, so keep only one: if
there are several, one is used and the rest are reported as skipped. A carrier
the sweep can't use is skipped with the reason (`2 [Peer] sections, needs one`,
say): it needs what [build](#what-build-accepts-and-writes) needs. Other files
in `config/` are left alone: a `warped.*` file whose carrier is gone is
reported as an *orphan* (delete it yourself), anything else (a plain tunnel)
as *manual*.

### Extras

A carrier routes only WARP, so the server can't reach your device, or your
device the server, unless that address is in `AllowedIPs` too. The sweep adds
these *extras* from two kinds of header line in the carrier file:

```ini
# device-network: 10.9.8.0/24     # written by wireguard-tools
# tunnel-routes: 10.0.0.5/32      # your own: anything else to send through the carrier
```

`device-network` is the server's static device addresses, written by
wireguard-tools: `10.9.8.1` is the server, `10.9.8.<number>` a device.

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
carriers. With WARP below 1280 (a carrier under 1360) there's no IPv6 inside
WARP and QUIC falls back to TCP; pages still load.

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
same format, read before the shared file by the sweep, `singbox.sh build` and
`install.sh` (for this Mac's WARP config).
Give a device its own when its WARP would catch other devices' WARP. Say a
router runs its own `warp.<router>.conf` on `162.159.192.1`. It keeps a route
to that address out its WAN, so the WARP packets of a Mac behind it, on the
same address, skip the router's tunnel and are dropped. Give the router
another Cloudflare address (`162.159.192.5:2408`, say) and leave everyone else
on the shared one (see also [WARP alone behind a router](#warp-alone-behind-a-router)).

## Local Mac Tunnels

Tunnels on this Mac, run by a root daemon, with a kill switch and an optional
menu bar lock.

### Mac quick start

After `./install.sh`, with `<mac>` the device name it asked for:

1. **Add your configs** (the `.conf` files from your provider or server)
   to `~/wg-tunnels/devices/<mac>/`: plain tunnels in `config/`, carriers
   in `carriers/` (the next step processes them into warped tunnels).
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
[Troubleshooting](TROUBLESHOOTING.md).

### tunnel.sh

`tunnel.sh <command>`:

| Command | What |
|---------|------|
| `up [n\|name]` | Asks `warped [Y/n]`, then which tunnel (Enter = the last one used, or the only one). A number picks from the warped list; a name skips both questions (and is needed with no terminal) |
| `down` | Everything down, back to the normal connection |
| `pause [min]` | For a hotel or café sign-in page: the tunnel down and the kill switch off for `min` minutes (default 10, up to 1440), then the daemon brings the tunnel back by itself, also after a reboot. Again while paused sets a new end time |
| `resume` | End a pause now |
| `status` (default) | Tunnels, what's up, handshakes, the kill switch, the exit IP |
| `list` | Number the warped and other tunnels |
| `import [dir] [-y]` | Run the [sweep](#warped-tunnels) (`<mac>/carriers/` into warped tunnels in `config/`, and `warp.<mac>.conf`), then install every `.conf` in `<mac>/config/` for the daemon, and sort each into its [kind](#tunnel-kinds). Given a `dir`, installs the `.conf` files there instead, with no sweep. Tunnels no longer there are removed, unless up or wanted (paused, or a failed `up`). Shows what it would do (new, updated, unchanged, removed, and the WARP config) and asks; `-y`, or no terminal, skips the question |
| `extract [zip]` | For tunnels kept in the WireGuard app: replace `<mac>/config/` with the `.conf` files in the newest zip from its *Export Tunnels to Zip…* in `<mac>/exports/` (or the one given). Configs not in the zip are removed, `nord.sh`'s included; only wireguard-tools' are kept ([Shared folder](#shared-folder)). Warped ones and `warp.<mac>.conf` come back on the next `import`. The zip is kept |
| `extract-import [zip]` | `extract`, then `import` |
| `default [device]` | Show or change this Mac's device, saved in `~/wg-tunnels/devices/.default`. `extract`, `import` and `rotate-warp` use it. Changing it doesn't touch the daemon; run `import` after |
| `rotate-warp` | New WARP keys: registers a new WARP account (through `install.sh`), imports it, and reconnects a warped tunnel or `warp.<mac>` that's up. The old account's files are deleted once that works (Cloudflare isn't told), or put back if registering fails. This Mac only: sing-box devices keep their own accounts |
| `diag [file]` | Write one file with what's needed to debug: the daemon's status, configs, `wg show`, interfaces, routes, DNS and the last 300 log lines. Private and preshared keys are removed; server IPs and networks aren't, so read it before you share it. Default `~/wg-tunnels/diag/diag-<time>.txt` |
| `log` | Follow the daemon's log |
| `breakglass` | Lost the network? See [Troubleshooting](TROUBLESHOOTING.md) |
| `update` | Update the daemon from the repo's `tunnel.sh`, only if it differs (or its LaunchDaemon is missing), e.g. after a `git pull`. Restarts the daemon, so a tunnel that's up drops for a few seconds |
| `install` | Install just the daemon, even when it's current |
| `uninstall` | Take everything down and remove the daemon; configs are kept |

`up`, `down`, `pause`, `resume`, `import`, `rotate-warp`, `diag`, `update`,
`install`, `uninstall` and `breakglass` use `sudo`. `up`, `down`, `pause`,
`resume`, `import` and `rotate-warp` also update the daemon first when the
repo copy differs, as `update` does.

#### Tunnel kinds

`tunnel.sh import` sorts each tunnel into one of three kinds:

| Kind | What | Kill switch |
|------|------|-------------|
| **warped** | Named `warped.*`: a carrier with WARP inside. Sites see a Cloudflare IP in the carrier's city | yes |
| **full** | Routes all of IPv4 (`0.0.0.0/0`, or the two `/1` halves) | yes |
| **split** | Anything else: only the networks in its `AllowedIPs` | no |

The kill switch blocks all traffic outside the tunnel until you run
`tunnel.sh down` (or `pause` it). A failing tunnel never falls back to your normal connection.

### Warped tunnels on this Mac

`tunnel.sh import` runs the [sweep](#warped-tunnels) on
`~/wg-tunnels/devices/<mac>/carriers/` first, then installs everything in
`config/`, so a new or changed carrier needs only an `import`. The sweep's
report also says, per tunnel, what to do about the WireGuard app's copy, if
you keep one there. `wgwarp-sweep.sh [<device>]` runs the sweep alone: it
updates `config/` and prints the report, but installs nothing.

`import` installs a `warped.*` file only if it still looks swept: the WARP
endpoint in `AllowedIPs`, nothing wider than a /8 (/16 for IPv6), and no
`DNS` line. One that fails (usually edited by hand) is skipped, not fixed. An
orphan still looks swept, so it's imported until you delete it.

`import` also skips, and says why, a config whose file name has a space or
another character outside `A-Z a-z 0-9 . _ = + -` (rename it), and a full or
warped tunnel whose `Endpoint` is an IPv6 address (the daemon routes servers
over IPv4; a hostname is looked up as IPv4).

The daemon starts WARP inside the carrier at the right MTU
([Small carrier MTU](#small-carrier-mtu)) and logs when it lowers it.

### WARP alone behind a router

`warp.<mac>` can ride a carrier that isn't the Mac's: a travel router that tunnels
everything to a remote exit, say, so Cloudflare sees that exit. The daemon
can't read that carrier's MTU, so it measures instead. Once WARP is up, it
sends a full-size don't-fragment ping through it to `1.1.1.1` (WARP's
endpoint doesn't answer ping). If that's lost but a 1200-byte one gets
through, WARP runs at 1200. It measures again when the network changes and
every 5 minutes (a router can switch exits behind the same address), and
goes back to the config's MTU where that fits. The log says when it changes.
Pick a router exit that doesn't go through WARP on the server, or it's WARP
inside WARP.

If the router runs WARP itself, give it its own
[WARP endpoint](#warp-endpoint). sing-box's `warp.<device>` isn't measured: it
runs at the profile's MTU.

### Menu bar (optional)

The full install offers it (or `install.sh --swiftbar` adds it later): a
lock icon in the menu bar, through
[SwiftBar](https://github.com/swiftbar/SwiftBar), showing whether you're
protected. Each state has its own icon, and it comes from the daemon's
status, so the lock is green only once the daemon has seen a handshake:

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
rm -f ~/wg-tunnels/devices/.default                       # or point it at another device: tunnel.sh default
rm -rf ~/wg-tunnels/diag                                  # diag files
sudo rm -f /var/log/wg-tunnels.log
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

1. **Add its configs** (the `.conf` files from your provider or server)
   to `~/wg-tunnels/devices/iphone/`: plain full tunnels in `config/`,
   carriers in `carriers/` (the next step processes them into warped
   tunnels). At least one, each a
   new config made for this device ([Keys](#keys)).
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
| `dengar.list.iphone.json` | `dengar.chi-us.iphone`, `dengar.warp.chi-us.iphone`, `dengar.warp.iphone` |
| `proton.list.iphone.json` | `proton.chicago`, `proton.toronto` (provider configs used directly) |
| `warped.list.iphone.json` | Every `warped.*` tunnel, whatever carries it, and `warp.iphone` |

A group is written only when it has two or more tunnels, even if it then
matches the composite. So name configs `<server>.<name>.conf`
(`proton.chicago.conf`, not `chicago.conf`); wireguard-tools' already are.
Name carriers the same way for readable names, though their warped tunnels
all group under `warped`:
`carriers/proton.chicago.conf` gives `warped.proton.chicago.iphone`.

Every device with a `warp/` account also gets `warp.<device>`
([WARP alone](#warped-tunnels), built from `warp/`), as `warp.<device>.json`,
in the composite, and in `warped.list.<device>.json` when it has a warped
tunnel to join. The network you're on can see you're using WARP; a warped
tunnel hides that inside the carrier.

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

A one-tunnel profile keeps its own MTU and its keepalives: the config's (as the
WireGuard app and `tunnel.sh` get it; `build` warns about a config without one),
and 25s for WARP, as everywhere else.

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
`PrivateKey`, `PublicKey`, `Address`, an `Endpoint` as `host:port`, and an
`MTU` from 576 to 65535 if one is set.

**Warped tunnels.** `build` runs the [sweep](#warped-tunnels) on the device's
`carriers/` first. It skips a `warped.*` file whose carrier is missing from
`carriers/` or broken, so orphans drop out of the profiles. A device with no
`warp/` (only configs from wireguard-tools, say) gets its plain tunnels only.

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
- The tun uses the `system` stack (the OS's own network stack, not gVisor).
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
| `new <device>` | Make `~/wg-tunnels/devices/<device>/` (or add to one that exists), register the device's own WARP account (needs `wgcf`), and write `config/warp.<device>.conf` (WARP alone, for the WireGuard app) |
| `build <device>` | Sweep its carriers, then write its profiles into its `sing-box/` |
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

## A tunnel as a QR code

For the WireGuard app (any device) rather than sing-box, `qr.sh` shows any
tunnel in a device's `config/` as a QR code, to scan with *+ > Create from QR
code*:

```
qr.sh                      # pick a device, then one of its tunnels
qr.sh iphone               # pick one of iphone's tunnels
qr.sh iphone warp.iphone   # that one (a name, or its number)
```

`warp.<device>` is [WARP alone](#warped-tunnels); any plain tunnel works too. A `warped.*`
tunnel only carries WARP, and the WireGuard app can't run one tunnel inside
another, so it does nothing there alone: use sing-box for those. The QR holds
the private key: show it only to the device it's for, and clear the terminal
after (Cmd-K).

## NordVPN

`nord.sh` makes NordLynx (WireGuard) configs from your Nord account.
Put the access token (Nord account > NordVPN > Manual setup) in
`~/wg-tunnels/.nord-token`, one line; it's never an argument. Run it with no
arguments and it asks: a device or a [server](#servers), which
one, carrier or config (a device only: a carrier
[carries WARP](#warped-tunnels), a config is a plain tunnel), the country,
then a numbered list of that country's cities (Enter = any: Nord's pick in
the whole country). Nord has cities, not states
or regions; in the US that's about one per state (Hawaii is Honolulu).

```
nord.sh                                   # asks
nord.sh device mbp-1 carrier us           # devices/mbp-1/carriers/nord.us.conf -> warped.nord.us.mbp-1
nord.sh device iphone config ca           # devices/iphone/config/nord.ca.conf: a plain tunnel
nord.sh server dengar us                  # fleet/servers/dengar/carriers/nord.us.conf: jump nd-us
nord.sh device mbp-1 config us honolulu   # devices/mbp-1/config/nord.us.honolulu.conf
nord.sh server dengar us "new york"       # fleet/servers/dengar/carriers/nord.us.new-york.conf: jump new-us
```

- **One file per device or server and place** (a country, or a city in it). Running it
  again regenerates that file, keeping its Nord server while Nord still
  recommends it and no other Nord file uses it. A device can have both a carrier and a config for one place.
  Only files with a `# source: nord` line are regenerated; another file of the
  same name is left alone. `tunnel.sh extract` removes Nord configs from
  `config/` (they aren't in the WireGuard app's zip): run `nord.sh` again.
- **One Nord server per file.** Nord gives one key per account, so every Nord
  config shares it (the exception to [Keys](#keys); `build` doesn't count it
  as shared). On two Nord servers at once that works; twice on one server,
  both break. So a server any other Nord file uses (any device or server) is
  skipped for the next one Nord recommends.
- **Servers** get a `# jump: <code> <city, country> (Nord <server>)` line, so
  `wgt-ctl <server> jump-add` adds it under that code: `nd-<cc>` for any city,
  or the city's first three letters and the country (`hon-us`) the way wgt-ctl
  names jumps, with a digit if that code is taken (`new-us`, `ne2-us`). Nord's
  own server names, like `us11553`, are too long for a jump code.
- Nord recommends servers near the Mac that runs `nord.sh`, not near the
  device or server the config is for: for a server elsewhere, the country is
  what you choose.

## Shared folder

Only with [wireguard-tools](https://github.com/cgmckeever/wireguard-tools);
without it, skip this section. `~/wg-tunnels` is the storage both repos
share: `devices/` for the configs, plus `fleet/`, the systems only
wireguard-tools manages. wireguard-tools reads each server's exits from
`fleet/servers/<server>/carriers/` ([below](#servers-wireguard-tools)) and puts the client configs
it issues in `devices/<device>/config/` ([Devices](#devices)). Whichever runs
first creates `~/wg-tunnels`, and both read its location from `$WG_CONFIG_HOME`
([Your folders](#your-folders)).

**Configs wireguard-tools issued** start with
`# wireguard-tools client: <config> on <server>`. They're wgt-ctl's to
replace: the live copy is on the server, and `wgt-ctl sync` puts it back.
Nothing here changes, renames or deletes one. The sweep writes only
`warped.*` and `warp.<device>.conf`. wireguard-tools never uses those names,
in any case (it names its files `<server>.<config>.conf`), so neither can
overwrite the other. A warped tunnel made from a
wireguard-tools carrier keeps its `# wireguard-tools client:` line; that's
fine, both sides go by the name. `tunnel.sh extract` goes by that line
instead: it keeps a config that has it (the WireGuard app's export drops
it), except a `warped.*` one, and replaces the rest from the zip.

**Who writes what in `config/`.** wireguard-tools, `nord.sh` and the sweep
each write a tunnel with `PersistentKeepalive = 25`, and the WireGuard app,
`tunnel.sh` and sing-box run it as written. Two exceptions: a sing-box group
drops keepalives (it runs every tunnel at once), and `tunnel.sh` gives WARP
one when its config has none. [CLAUDE.md](CLAUDE.md) has the full contract.

**Backups.** When wgt-ctl replaces or removes a config, the old one becomes
`<name>.conf.<time>.bak`. Everything here reads only `*.conf`, so backups are
never listed, imported or built. Delete them when you no longer need them.

### Servers (wireguard-tools)

Each server wireguard-tools manages has a folder in `fleet/servers/`. A
`login` file marks it as one of wgt-ctl's servers, and only those are offered
here. Its `carriers/` holds that server's exits (wireguard-tools calls them
*jumps*), one `.conf` each. They run on the server, not on your devices.

You can add exits by hand or with [`nord.sh`](#nordvpn): save a config from
your VPN provider in `fleet/servers/<server>/carriers/`, then run `wgt-ctl
<server> jump-add`. The first time, it asks what the file is and writes a
`# jump: <code> <label>` line into it; `nord.sh` writes that line for you. See
wireguard-tools' [Adding jumps from your machine](https://github.com/cgmckeever/wireguard-tools#adding-jumps-from-your-machine).

### Pucks (wireguard-tools)

A *puck* is a small computer, such as a Raspberry Pi, left on a friend's home
network. Clients of one of your wireguard-tools servers can then exit from the
friend's home IP, or reach that home's network. Pucks are part of
wireguard-tools: its [tunnel-puck](https://github.com/cgmckeever/wireguard-tools/tree/main/tunnel-puck#readme)
sets them up, and its `tpk-ctl.sh` keeps each puck's settings in
`fleet/pucks/<puck>/`. This repo never reads them.

The configs a puck's clients use come from the server, so wgt-ctl delivers
them to `devices/<device>/config/` like any other (`bossk.puck1.iphone.conf`),
and they're tunnels here like the rest.

## Checking the store

`check.sh` (or `wgtun.sh check`) reads every device, or the ones you
name, and changes nothing:

- every config in `carriers/` and `config/`, and `warp/wgcf-profile.conf`, is
  one build can use;
- every file in `carriers/`, `config/`, `warp/`, `exports/` and `sing-box/` is
  0600, and the device's folders 0700 (they hold private keys);
- no private key is on two devices (two devices on one key knock each other off);
- every `config/` tunnel has a keepalive (a warning: one without has none in
  the WireGuard app, `tunnel.sh` or sing-box either);
- `config/`'s `warped.*` and `warp.<device>.conf` are what the sweep writes
  now, and `sing-box/` is what `build` writes now: it says which to run when
  they aren't.

A device it can't finish (a file it can't read, say) gets that as an error,
and the rest are still checked. It exits 1 on any error, so it can gate a script.

## Troubleshooting

In [TROUBLESHOOTING.md](TROUBLESHOOTING.md): where to start when a tunnel on this
Mac or the network misbehaves, `breakglass`, sign-in pages, the WireGuard app,
and sing-box profiles.

## Developing

The sweep, `singbox.sh` and `check.sh` are Python in `wgtun/` (stdlib only,
Python 3.9 or later: macOS's own `/usr/bin/python3` will do; the scripts run
whichever `python3` is first on your `PATH`). `tunnel.sh` stays standalone
bash: it's the root daemon, installed as one file.

- `./test.sh all` runs the tests and lint; `./test.sh hooks` has git run it
  before each commit, and GitHub Actions runs it on every push (on macOS).
- `tests/golden/` pins every file, mode and line the old shell scripts wrote:
  change it only when what the scripts write or say is meant to change.
- [CLAUDE.md](CLAUDE.md) has the layout, the contract between the parts, and the rules
  for changing them without tangling them.
