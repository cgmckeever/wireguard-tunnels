"""wgwarp-sweep.sh — make WireGuard configs carry a Cloudflare WARP tunnel.
Any WireGuard server works as the carrier.

Usage:
  wgwarp-sweep.sh             this Mac's device folder (~/wg-tunnels/devices/
                              .default, set by tunnel.sh default): carriers/ -> config/
  wgwarp-sweep.sh <device>    ~/wg-tunnels/devices/<device>
  wgwarp-sweep.sh <dir>       any folder with carriers/ in it

Reads every carriers/<name>.conf (as downloaded from the provider) and writes
config/warped.<name>.<device>.conf: AllowedIPs set to the WARP endpoint (plus
the extras below), the DNS line removed and a keepalive, so the tunnel
carries WARP and nothing else. The device (the folder's name) always goes
last: one elsewhere in <name> is moved there. A carrier already named warped.x or
warped-x becomes warped.x.<device>, not warped.warped.x.<device>.

Also writes config/warp.<device>.conf: the device's WARP alone (from warp/),
a plain tunnel (tunnel.sh import runs it like any other; or the WireGuard app;
singbox.sh build makes its warp.<device> from it).

A config/ file is only rewritten when the new one differs. The sweep owns
warped.* and warp.<device>.conf; every other config/ file is left as it is.
Everything WARP-specific about a config is done here; tunnel.sh import checks
it, and singbox.sh build makes its sing-box form (the detour, the inner MTU).

A carrier's AllowedIPs beyond the WARP endpoint come from its header lines:
  # device-network: 10.9.8.0/24     (the wireguard-tools server repo writes this)
  # tunnel-routes: 10.0.0.5/32       (add your own; a "#" after them is a comment)
device-network is the server's static device addresses: with it the server
and this device reach each other through the carrier. tunnel-routes is
anything else that should go through the carrier instead of WARP. Rebuilt
every sweep: delete a line and it's gone.

For this Mac's device, the last column compares each one with the WireGuard
app's tunnel of the same name (the app can't be scripted, so only its server
address is visible) and says what to do there by hand. Only for tunnels you
also keep in the app.

tunnel.sh import runs it for this Mac, singbox.sh build for its device:
neither needs it run by hand.

The WARP endpoint comes from <device>/.warp-endpoint, else
~/wg-tunnels/.warp-endpoint (IPv4:port; default 162.159.192.1:2408).
"""

from __future__ import annotations

import ipaddress
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Dict, List, Optional

from . import store
from .conf import Conf, stem
from .store import KEEPALIVE, Error

PROG = "wgwarp-sweep.sh"
USAGE = "usage: wgwarp-sweep.sh [<device>|<dir>]"


@dataclass
class Row:
    """One tunnel in the sweep's table."""
    name: str
    state: str                  # new, updated, unchanged, skipped, manual or orphan
    path: str = ""              # its config/ file
    text: str = ""              # what the sweep writes there ("" for none)
    detail: str = ""            # the table's last column, when it's fixed
    source: str = ""            # the carrier or profile it's made from
    notes: List[str] = field(default_factory=list)


# --- a carrier's extras: the networks it takes besides the WARP endpoint ---


def extras(carrier: Conf) -> Dict[str, List[str]]:
    """The entries on its device-network and tunnel-routes lines, by verdict:
    kept (the carrier takes it), wide or bad (see verdict)."""
    found: Dict[str, List[str]] = {"kept": [], "wide": [], "bad": []}
    for line in carrier.lines:
        m = re.match(r"#\s*(?:device-network|tunnel-routes):\s*(.*)", line)
        for e in re.split(r"[, \t]+", m.group(1).split("#", 1)[0]) if m else []:
            if e:
                found[verdict(e)].append(e)
    return found


def verdict(e: str) -> str:
    """kept, wide (wider than store.WIDEST_V4/_V6: it would take traffic away
    from WARP) or bad (not an address or network). tunnel.sh swept_ok has the
    same limits."""
    try:
        net = ipaddress.ip_network(e, strict=False)
    except ValueError:
        return "bad"
    return "wide" if net.prefixlen < (store.WIDEST_V4 if net.version == 4 else store.WIDEST_V6) else "kept"


def carrier_notes(carrier: Conf, found: Dict[str, List[str]], warp_mtu: int) -> List[str]:
    """What the table says under a carrier: its extras, and a small MTU."""
    notes = [say.format(", ".join(found[v])) for v, say in (
        ("kept", "also carries {}"),
        ("wide", "ignored, too wide (would bypass WARP): {}"),
        ("bad", "ignored, not an address: {}")) if found[v]]
    # A carrier too small for WARP's MTU (the profile's) plus its overhead
    # makes tunnel.sh and singbox.sh run WARP smaller
    mtu = carrier.mtu(0)
    inner = store.inner_mtu(mtu, warp_mtu)
    if mtu and inner < warp_mtu:
        notes.append(f"carrier MTU {mtu}: WARP runs at {inner} inside (IPv6 and QUIC fall back)")
    return notes


# --- what the sweep writes ---

def drop(_line: str) -> List[str]:
    return []


def render_warped(carrier: Conf, warp_net: str, kept: List[str]) -> str:
    """The warped config: it carries WARP and its extras only (one AllowedIPs
    line), DNS gone (it comes from WARP), a keepalive so a stale handshake
    means trouble."""
    allowed = f"AllowedIPs = {', '.join([warp_net] + kept)}"
    has_allowed = bool(carrier.values("AllowedIPs"))
    first = True

    def allowed_once(_line: str) -> List[str]:
        nonlocal first
        if not first:
            return []
        first = False
        return [allowed]

    return carrier.rewrite({
        "DNS": drop,
        "PersistentKeepalive": drop,
        "AllowedIPs": allowed_once,
        "Endpoint": lambda line: [line] + ([] if has_allowed else [allowed]) + [f"PersistentKeepalive = {KEEPALIVE}"],
    })


def render_warp_alone(profile: Conf, endpoint: str) -> str:
    """WARP alone from the wgcf profile, on the device's WARP endpoint, with a keepalive."""
    return profile.rewrite({
        "PersistentKeepalive": drop,
        "Endpoint": lambda _line: [f"Endpoint = {endpoint}", f"PersistentKeepalive = {KEEPALIVE}"],
    })


# --- the sweep of one folder ---

def resolve(arg: str) -> str:
    """The folder an argument names: none is this Mac's device, a bare name a device."""
    if not arg:
        mac = store.this_mac()
        if not mac:
            raise Error("no default device yet: tunnel.sh default (or give a device or folder)")
        folder = store.device_dir(mac)
    elif "/" in arg or arg in (".", ".."):
        folder = arg
    else:
        folder = store.device_dir(arg)
        if not os.path.isdir(folder):
            folder = arg
    if not os.path.isdir(folder):
        raise Error(f"no folder {folder}")
    return folder


class Sweep:
    """The sweep of one folder: planned when made (plan changes nothing),
    then write() and report() (run() is both)."""

    def __init__(self, folder: str, app_column: bool = True) -> None:
        self.f = store.Folder(folder)
        # Only a device folder gets swept: never make config/ in some other
        # folder named by mistake. A device with no carriers/ has plain
        # configs only (wireguard-tools makes those): nothing to sweep.
        self.no_carriers = not os.path.isdir(self.f.carriers)
        if self.no_carriers and not same_dir(os.path.dirname(os.path.abspath(folder)), store.devices_dir()):
            raise Error(f"no carriers/ in {folder} (singbox.sh new <device> makes a device)")
        mac = store.this_mac()
        self.app = app_column and bool(mac) and same_dir(folder, store.Folder.of(mac).dir)
        self.endpoint = store.warp_endpoint(folder)
        self.rows = self.plan()

    def plan(self) -> List[Row]:
        """Every row of the table, with what to write; changes nothing."""
        rows: List[Row] = []
        claimed = set()
        profile = Conf.read(self.f.profile) if os.path.isfile(self.f.profile) else None
        warp_mtu = profile.mtu(store.WARP_MTU) if profile else store.WARP_MTU
        for path in store.files_in(self.f.carriers):
            name = store.warped_name(path, self.f.name)
            carrier = Conf.read(path)
            # The carrier's own problem first: a broken one doesn't take the name from a good one
            why = carrier.problem() or (f"another carrier already makes {name}" if name in claimed else "")
            if why:
                rows.append(Row(name, "skipped", detail=f"{os.path.basename(path)}: {why}", source=path))
                continue
            claimed.add(name)
            found = extras(carrier)
            rows.append(self.output(name, render_warped(carrier, store.warp_net(self.endpoint), found["kept"]),
                                    path, notes=carrier_notes(carrier, found, warp_mtu)))
        if profile:
            name = store.warp_alone(self.f.name)
            claimed.add(name)
            why = profile.problem()
            rows.append(Row(name, "skipped", detail=f"warp/wgcf-profile.conf: {why}", source=self.f.profile) if why
                        else self.output(name, render_warp_alone(profile, self.endpoint), self.f.profile,
                                         detail="(WARP alone, a plain tunnel)"))
        # config/ files no carrier claims: a warped one lost its carrier (an
        # orphan: reported, never deleted); anything else is someone else's
        for path in store.files_in(self.f.config):
            name = stem(path)
            if name not in claimed:
                rows.append(Row(name, "orphan" if store.sweep_owned(name, self.f.name) else "manual", path=path))
        return rows

    def output(self, name: str, text: str, source: str, detail: str = "", notes: Optional[List[str]] = None) -> Row:
        path = os.path.join(self.f.config, f"{name}.conf")
        return Row(name, store.state_of(path, text), path=path, text=text, detail=detail, source=source,
                   notes=notes or [])

    def written(self) -> List[Row]:
        return [r for r in self.rows if r.text]

    def orphan_reason(self, r: Row) -> str:
        """Why an orphan has nothing to come from."""
        return "no warp/wgcf-profile.conf" if r.name == store.warp_alone(self.f.name) \
            else "no usable carrier in carriers/"

    def configs(self) -> List[Conf]:
        """config/ as it is once the sweep has run (read now, or as it will be)."""
        planned = {r.path: r.text for r in self.written()}
        paths = store.collated(set(store.files_in(self.f.config)) | set(planned))
        return [Conf(planned[p], p) if p in planned else Conf.read(p) for p in paths]

    def write(self) -> None:
        """What changed into config/ (0600), the folders 0700."""
        store.private_dir(self.f.dir)
        store.private_dir(self.f.config)
        if not self.no_carriers:
            store.private_dir(self.f.carriers)
        for r in self.written():
            store.update_private(r.path, r.text)

    def report(self, no_next: bool = False) -> None:
        """The table: each tunnel, what happened to its file, and for this
        Mac the WireGuard app column."""

        def say(name: str, state: str, last: str) -> None:
            print(f"{name:<40} {state:<10} {last}")

        if self.no_carriers:
            print(f"No carriers/ in {self.f.dir}: plain configs only "
                  f"(singbox.sh new {self.f.name} adds carriers/)\n")
        elif not store.files_in(self.f.carriers):
            print(f"No configs in {self.f.carriers}: put WireGuard configs there "
                  f"(x.conf becomes warped.x.{self.f.name})\n")
        say("TUNNEL", "FILE", "WIREGUARD APP (only if you use it)" if self.app else "")
        for r in self.rows:
            if r.detail:
                say(r.name, r.state, r.detail)
            elif r.state == "orphan":
                say(r.name, r.state, f"({self.orphan_reason(r)}: left in place)")
            else:
                say(r.name, r.state, self.app_action(r))
            for n in r.notes:
                print(f"{'':<40} └ {n}")
        if not self.app:
            return
        print()
        if not no_next:
            print(f"Next: tunnel.sh import   (installs everything in {self.f.config} for the daemon)")
        print("The WireGuard app column is only for tunnels you also keep in the app; skip it otherwise.")

    def run(self, no_next: bool = False) -> None:
        self.write()
        self.report(no_next)

    def app_action(self, r: Row) -> str:
        """What to do about the WireGuard app's copy of a tunnel (only if you
        use the app). Nothing here is about tunnel.sh import, which reads config/."""
        if not self.app:
            return ""
        if not command(["scutil", "--nc", "status", r.name]).split("\n")[0]:
            return "not there: add it in the app"
        remote = next((ln.split(" : ", 1)[1] for ln in command(["scutil", "--nc", "show", r.name]).split("\n")
                       if "RemoteAddress" in ln and " : " in ln), "")
        endpoint = (Conf(r.text) if r.text else Conf.read(r.path)).value("Endpoint")
        host, _, port = endpoint.rpartition(":")
        # The app keeps the address a hostname resolved to: compare that too
        ip = next((ln.split()[1] for ln in command(["dscacheutil", "-q", "host", "-a", "name", host]).split("\n")
                   if ln.startswith("ip_address:")), "")
        if remote not in (endpoint, f"{ip or host}:{port}"):
            return f"there, other server ({remote or '?'}): remove it and add again in the app"
        return {"updated": "there, but changed: remove it and add again in the app",
                "new": "there, same server: if the app's copy isn't this config, remove it and add again"}.get(
                    r.state, "there, same server")


def same_dir(a: str, b: str) -> bool:
    return os.path.isdir(a) and os.path.isdir(b) and os.path.realpath(a) == os.path.realpath(b)


def command(argv: List[str]) -> str:
    try:
        return subprocess.run(argv, capture_output=True, text=True).stdout
    except OSError:
        return ""


def main(argv: Optional[List[str]] = None) -> int:
    args = sys.argv[1:] if argv is None else argv

    def body() -> int:
        if args[:1] in (["-h"], ["--help"]):
            print(__doc__, end="")
            return 0
        if len(args) > 1 or (args and args[0].startswith("-")):
            raise Error(USAGE)
        Sweep(resolve(args[0] if args else "")).run(no_next=bool(os.environ.get("SWEEP_NO_NEXT")))
        return 0

    return store.run_main(PROG, body)


if __name__ == "__main__":
    sys.exit(main())
