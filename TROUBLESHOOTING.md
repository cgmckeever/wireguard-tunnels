# wireguard-tunnels: Troubleshooting

For the [wireguard-tunnels README](README.md).

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
  [Small carrier MTU](README.md#small-carrier-mtu). If `import` skipped it, see
  [Warped tunnels on this Mac](README.md#warped-tunnels-on-this-mac).
- **Also using the WireGuard app?** That's fine, with two rules. Turn off On
  Demand for its tunnels: it reconnects behind `up` and breaks the tunnel, so
  `up` refuses while it's on. And switch an app tunnel on only after `down`,
  or the kill switch swallows its traffic. `up` stops app tunnels for you.
