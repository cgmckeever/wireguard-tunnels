"""What install.sh asks of wgtun, so it reads the store as the sweep does:

  python3 -m wgtun.forinstall warp-endpoint <device dir>   the WARP endpoint (or why .warp-endpoint is wrong)
  python3 -m wgtun.forinstall daemon-warp <device dir>     this Mac's warp.conf for the daemon, from warp/
"""

from __future__ import annotations

import os
import sys
from typing import List

from . import store
from .conf import Conf
from .store import KEEPALIVE, WARP_MTU, Error


def daemon_warp(device_dir: str) -> str:
    """The daemon's WARP: carried inside a warped tunnel, so Table = off (the
    daemon routes), and always 1280 (tunnel.sh lowers it in a small carrier)."""
    path = os.path.join(device_dir, "warp", "wgcf-profile.conf")
    profile = Conf.read(path)
    key, pub, addresses = profile.value("PrivateKey"), profile.value("PublicKey"), profile.items("Address")
    if not (key and pub and addresses):
        raise Error(f"Can't read PrivateKey/PublicKey/Address from {path}")
    device = os.path.basename(os.path.abspath(device_dir))
    return f"""# Written by wireguard-tunnels install.sh from ~/wg-tunnels/devices/{device}/warp/wgcf-profile.conf.
#
# Cloudflare WARP exit, carried inside another WireGuard tunnel (warped.*). `tunnel.sh import`
# copies it for the wg-tunnels daemon, which does the
# routing; don't bring it up on its own. Table = off skips wg-quick's routing,
# which would send the endpoint straight out the NIC, around the carrier.
[Interface]
PrivateKey = {key}
Address = {", ".join(addresses)}
DNS = 1.1.1.1
# IPv6's minimum: fits in a carrier of 1360 or more (tunnel.sh lowers it in a smaller one)
MTU = {WARP_MTU}
Table = off

[Peer]
PublicKey = {pub}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = {store.warp_endpoint(device_dir)}
# A stale handshake then means trouble, not idleness (the daemon's watchdog)
PersistentKeepalive = {KEEPALIVE}
"""


def main(argv: List[str]) -> int:
    what = {"warp-endpoint": store.warp_endpoint, "daemon-warp": daemon_warp}
    if len(argv) != 2 or argv[0] not in what:
        store.die("install.sh", "usage: python3 -m wgtun.forinstall warp-endpoint|daemon-warp <device dir>")
    try:
        print(what[argv[0]](argv[1]), end="" if argv[0] == "daemon-warp" else "\n")
    except store.FAILURES as e:
        store.die("install.sh", str(e))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
