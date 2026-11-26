# wireguard-tunnels: Troubleshooting

For the [wireguard-tunnels README](README.md).

Start here when a tunnel on this Mac or the network misbehaves. Sing-box
profiles are [at the end](#sing-box-profiles).

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
  [Small carrier MTU](README.md#small-carrier-mtu), or for `warp.<mac>` behind a
  travel router, [WARP alone behind a router](README.md#warp-alone-behind-a-router).
  If `import` skipped it (or any tunnel), its line says why; see
  [Warped tunnels on this Mac](README.md#warped-tunnels-on-this-mac).
- **Also using the WireGuard app?** That's fine, with two rules. Turn off On
  Demand for its tunnels: it reconnects behind `up` and breaks the tunnel, so
  `up` refuses while it's on. And turn an app tunnel on only after `down`, or
  the kill switch swallows its traffic (`up` turns app tunnels off for you).
- **`nord.sh server` lists no servers?** It offers only the servers
  wireguard-tools lists (a `fleet/servers/<server>/login` file); `wgt-ctl init`
  adds one.

## Sing-box profiles

- **A tunnel is missing from the profiles?** `singbox.sh build` lists each
  config it skipped, with the reason; `check.sh <device>` says the same
  without building. See
  [What build accepts and writes](README.md#what-build-accepts-and-writes).
- **The app still runs the old tunnels after a build?** Importing adds a
  profile, it doesn't replace one: delete the old profile in the app first
  ([Updating a device](README.md#updating-a-device)).
- **Connected, but nothing past a few networks loads, not even DNS?** The
  config is a split tunnel, and a profile sends all traffic to it. Use a full
  tunnel (`AllowedIPs = 0.0.0.0/0, ::/0`); `build` warns about a split one.
- **`build` stops on a key?** Another device has the same key: give each
  device configs made for it ([Keys](README.md#keys)).
