"""wireguard-tunnels: the store's config work (the sweep, sing-box profiles, the check).

The store is ~/wg-tunnels ($WG_CONFIG_HOME), shared with wireguard-tools:

  devices/<device>/carriers/   WireGuard configs to carry WARP (as downloaded)
  devices/<device>/warp/       the device's own wgcf WARP account and profile
  devices/<device>/config/     every tunnel the device runs. The sweep owns
                               warped.* and warp.<device>.conf (by name, as
                               wireguard-tools and tunnel.sh tell them apart);
                               the rest come from wireguard-tools, nord.sh or you
  devices/<device>/sing-box/   singbox.sh build owns it

config/ is the one copy every consumer reads: the WireGuard app (qr.sh),
tunnel.sh import and singbox.sh build. So each rule about a tunnel (its
keepalive, its WARP endpoint) is applied once, where config/ is written, and
the consumers pass it through. The one exception is a sing-box group, which
runs every tunnel at once: it drops the keepalives (singbox.group_profile).

Stdlib only, Python 3.9 (macOS's own python3).
"""
