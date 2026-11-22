"""~/wg-tunnels ($WG_TUNNELS): where things are, what they're called, and the
rules every tunnel follows."""

from __future__ import annotations

import os
import re
import sys
from typing import List, NoReturn

KEEPALIVE = 25                       # seconds: every one-tunnel config has one
WARP_ENDPOINT = "162.159.192.1:2408"  # Cloudflare's, unless .warp-endpoint says otherwise
WARP_MTU = 1280                      # wgcf's, and IPv6's minimum
WARP_OVERHEAD = 80                   # what a carrier adds to each WARP packet
PLAIN_MTU = 1420                     # wg-quick's default
SCRIPTS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts")


class Error(Exception):
    """A reason to stop, said once by the script's main()."""


def die(prog: str, msg: str) -> NoReturn:
    print(f"{prog}: {msg}", file=sys.stderr)
    sys.exit(1)


def root() -> str:
    return os.environ.get("WG_TUNNELS") or os.path.expanduser("~/wg-tunnels")


def devices_dir() -> str:
    return os.path.join(root(), "devices")


def this_mac() -> str:
    """This Mac's device (tunnel.sh default), or ""."""
    try:
        with open(os.path.join(devices_dir(), ".default")) as f:
            return f.read().strip()
    except OSError:
        return ""


def by_name(names: List[str]) -> List[str]:
    """In the shell's order for a folder: by name, case aside."""
    return sorted(names, key=lambda n: (os.path.basename(n).lower(), n))


def confs_in(folder: str) -> List[str]:
    """The .conf files in a folder (none if it isn't one), by name."""
    if not os.path.isdir(folder):
        return []
    return by_name([os.path.join(folder, f) for f in os.listdir(folder)
                    if f.endswith(".conf") and not f.startswith(".")])


def all_devices() -> List[str]:
    d = devices_dir()
    if not os.path.isdir(d):
        return []
    return by_name([n for n in os.listdir(d) if not n.startswith(".") and os.path.isdir(os.path.join(d, n))])


def warp_endpoint(device_dir: str) -> str:
    """IPv4:port from <device>/.warp-endpoint, else <store>/.warp-endpoint, else
    Cloudflare's: per device for one whose network routes the shared address
    elsewhere (a router whose own WARP holds a route to it)."""
    for f in (os.path.join(device_dir, ".warp-endpoint"), os.path.join(root(), ".warp-endpoint")):
        if os.path.isfile(f):
            with open(f) as fh:
                ep = re.sub(r"[ \t\r\n]", "", fh.read())
            if not re.fullmatch(r"[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+", ep):
                raise Error(f"{f}: IPv4:port, e.g. {WARP_ENDPOINT} (not {ep})")
            return ep
    return WARP_ENDPOINT


def warped_name(carrier: str, device: str) -> str:
    """The tunnel a carrier becomes, the device always last: x.conf,
    warped.x.conf and warped-x.conf all become warped.x.<device>, and a device
    elsewhere in the name, as a word of its own (between . _ - or the ends),
    moves to the end (x_<device>-y becomes warped.x-y.<device>)."""
    n = re.sub(r"^warped[.-]", "", os.path.basename(carrier)[: -len(".conf")])
    d = re.escape(device)
    while True:
        m = re.fullmatch(rf"(.*)([._-]){d}([._-].*)", n)
        if not m:
            break
        n = m.group(1) + m.group(3)
    m = re.fullmatch(rf"{d}[._-](.*)", n)
    if m:
        n = m.group(1)
    if not re.search(rf"(^|[._-]){d}$", n):
        n += f".{device}"
    return f"warped.{n}"


def warp_alone(device: str) -> str:
    """The name of the device's WARP-only tunnel."""
    return f"warp.{device}"


def sweep_owned(name: str, device: str) -> bool:
    """The sweep writes these config/ names; wireguard-tools never does (it
    names its files <server>.<config>) and leaves warped.* alone."""
    return name.startswith("warped.") or name == warp_alone(device)


def state_of(path: str, text: str) -> str:
    """What writing text to path would be: new, updated or unchanged."""
    if not os.path.isfile(path):
        return "new"
    with open(path, newline="") as f:
        return "unchanged" if f.read() == text else "updated"


def write_private(path: str, text: str) -> None:
    """Put text at path, 0600, all at once (a temp file beside it, then a rename)."""
    tmp = os.path.join(os.path.dirname(path), f".{os.path.basename(path)}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", newline="") as f:
        f.write(text)
    os.replace(tmp, path)


def private_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)
    os.chmod(path, 0o700)


def main(argv: List[str]) -> int:
    """python3 -m wgtun.store warp-endpoint <device dir>: for install.sh, so it
    reads .warp-endpoint as the sweep does."""
    if len(argv) != 2 or argv[0] != "warp-endpoint":
        die("wgtun.store", "usage: python3 -m wgtun.store warp-endpoint <device dir>")
    try:
        print(warp_endpoint(argv[1]))
    except Error as e:
        die("install.sh", str(e))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
