"""What install.sh asks of wgtun, so it reads and writes the store as the
sweep and singbox.sh do. Each prints install.sh's "ok"/"changed" lines.

  python3 -m wgtun.forinstall device-name <name>              nothing, or why a device can't be called that
  python3 -m wgtun.forinstall warp-endpoint <device dir>       the WARP endpoint (or why .warp-endpoint is wrong)
  python3 -m wgtun.forinstall folders <dir>...                 each a 0700 folder
  python3 -m wgtun.forinstall warp-account <device dir>        the device's WARP account and profile in warp/
  python3 -m wgtun.forinstall daemon-warp <device dir> <file>  this Mac's warp.conf for the daemon, from warp/
"""

from __future__ import annotations

import os
import sys
from typing import Callable, Dict, List, Optional

from . import store
from .conf import Conf
from .store import KEEPALIVE, WARP_MTU, WARP_OVERHEAD, Error

PROG = "install.sh"


def line(changed: bool, what: str) -> str:
    return f"  {'changed' if changed else 'ok':<8} {what}"


def daemon_warp(device_dir: str) -> str:
    """The daemon's WARP: carried inside a warped tunnel, so Table = off (the
    daemon routes), and always 1280 (tunnel.sh lowers it in a small carrier)."""
    f = store.Folder(device_dir)
    profile = Conf.read(f.profile)
    why = profile.problem()             # as the sweep would skip it
    if why:
        raise Error(f"{f.profile}: {why}")
    return f"""# Written by wireguard-tunnels install.sh from ~/wg-tunnels/devices/{f.name}/warp/wgcf-profile.conf.
#
# Cloudflare WARP exit, carried inside another WireGuard tunnel (warped.*). `tunnel.sh import`
# copies it for the wg-tunnels daemon, which does the
# routing; don't bring it up on its own. Table = off skips wg-quick's routing,
# which would send the endpoint straight out the NIC, around the carrier.
[Interface]
PrivateKey = {profile.value("PrivateKey")}
Address = {", ".join(profile.items("Address"))}
DNS = 1.1.1.1
# IPv6's minimum: fits in a carrier of {WARP_MTU + WARP_OVERHEAD} or more (tunnel.sh lowers it in a smaller one)
MTU = {WARP_MTU}
Table = off

[Peer]
PublicKey = {profile.value("PublicKey")}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = {store.warp_endpoint(device_dir)}
# A stale handshake then means trouble, not idleness (the daemon's watchdog)
PersistentKeepalive = {KEEPALIVE}
"""


def device_name(args: List[str]) -> List[str]:
    if not store.valid_device(args[0]):
        raise Error(f"Device names are letters, digits, . _ - (not starting with .): {args[0]}")
    return []


def warp_endpoint(args: List[str]) -> List[str]:
    return [store.warp_endpoint(args[0])]


def folders(args: List[str]) -> List[str]:
    return [line(store.private_dir(d), d) for d in args]


def warp_account(args: List[str]) -> List[str]:
    registered, generated, tightened = store.warp_account(store.Folder(args[0]))
    return [line(registered, "account registered" if registered else "account"),
            line(generated, "profile generated" if generated else "profile"),
            *(line(True, f"{p} 0600") for p in tightened)]


def write_daemon_warp(args: List[str]) -> List[str]:
    device_dir, path = args
    store.private_dir(os.path.dirname(path))
    changed = store.update_private(path, daemon_warp(device_dir)) != "unchanged"
    return [line(changed, f"{path} (tunnel.sh import to pass it to the daemon)" if changed else path)]


COMMANDS: Dict[str, Callable[[List[str]], List[str]]] = {
    "device-name": device_name, "warp-endpoint": warp_endpoint, "folders": folders,
    "warp-account": warp_account, "daemon-warp": write_daemon_warp}
ARGS = {"device-name": 1, "warp-endpoint": 1, "warp-account": 1, "daemon-warp": 2}       # folders takes any number


def main(argv: Optional[List[str]] = None) -> int:
    args = sys.argv[1:] if argv is None else argv

    def body() -> int:
        cmd, rest = (args[0], args[1:]) if args else ("", [])
        if cmd not in COMMANDS or len(rest) != ARGS.get(cmd, len(rest)) or not rest:
            raise Error("usage: python3 -m wgtun.forinstall " + "|".join(COMMANDS) + " <args> (see its docstring)")
        for out in COMMANDS[cmd](rest):
            print(out)
        return 0

    return store.run_main(PROG, body)


if __name__ == "__main__":
    sys.exit(main())
