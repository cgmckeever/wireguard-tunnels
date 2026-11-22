"""singbox.sh — tunnels for devices that run sing-box (iPhone, iPad, Apple TV,
Android...), where the daemon can't, WARP inside a carrier included.

The WireGuard app on those can't carry one tunnel inside another. sing-box
can: its WireGuard endpoints take a detour, so WARP rides inside the
carrier, in one VPN. This builds the profiles to import there.

Usage:
  singbox.sh new <device>      make ~/wg-tunnels/devices/<device>/ and its own WARP account
  singbox.sh build <device>    sweep its carriers, write its sing-box/ profiles
  singbox.sh list              the devices and what each has

~/wg-tunnels/devices/<device>/   (0700: it all holds private keys)
  carriers/   the device's own WireGuard configs to carry WARP, made for this
              device (a key shared with another device makes both drop)
  warp/       the device's own wgcf WARP account and profile (same reason)
  config/     every tunnel on the device: warped.<carrier>.<device>.conf and
              warp.<device>.conf (from the sweep), and plain configs you put
              there, used as they are
  sing-box/   what build writes, to import in the device's sing-box app:
                <device>.json             the composite: every tunnel,
                                          picked in the app
                <server>.list.<device>.json  one server's tunnels, from the
                                          first word of their names (dengar.*,
                                          proton.*; warped.* and warp.* go in
                                          warped.list; groups of 2+ only)
                <tunnel>.json             one tunnel each
                warp.<device>.json        WARP alone, no carrier (in the
                                          composite and warped.list too)
              build owns this folder: a .json it didn't write is removed

Every profile is made from config/ as it stands, so a tunnel is the same in
sing-box, the WireGuard app and tunnel.sh (its keepalive included). The one
exception: the composite and the groups have no keepalives, because sing-box
starts every tunnel in a profile at once.

This Mac is a device too (its folder is the one in devices/.default,
set by tunnel.sh default). Its profiles use the daemon's keys: run one or
the other, never both (tunnel.sh down before turning sing-box on).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional

from . import store, sweep
from .conf import Conf
from .store import Error

PROG = "singbox.sh"
HERE = os.path.join(store.SCRIPTS, "singbox.sh")
Say = Callable[[str, bool], None]      # say(text, to_stderr)


def loud(text: str, err: bool = False) -> None:
    print(text, file=sys.stderr if err else sys.stdout)


@dataclass
class Unit:
    """One tunnel: its endpoints, its extra route rules and the tun's MTU for it."""
    tag: str
    endpoints: List[dict]
    rules: List[dict]
    mtu: int


# --- sing-box JSON ---

def endpoint(c: Conf, tag: str, mtu: int, detour: str = "") -> dict:
    """A sing-box WireGuard endpoint, as the config says (keepalive included)."""
    host, port = c.endpoint()
    ep: dict = {"type": "wireguard", "tag": tag, "mtu": mtu, "address": c.items("Address"),
                "private_key": c.value("PrivateKey")}
    if detour:
        ep["detour"] = detour
    peer: dict = {"address": host, "port": port, "public_key": c.value("PublicKey"),
                  "allowed_ips": c.items("AllowedIPs")}
    if c.value("PresharedKey"):
        peer["pre_shared_key"] = c.value("PresharedKey")
    if c.keepalive():
        peer["persistent_keepalive_interval"] = c.keepalive()
    ep["peers"] = [peer]
    return ep


def profile(endpoints: List[dict], rules: List[dict], picks: List[str], mtu: int) -> str:
    """A whole profile. Everything goes through the picked tunnel, DNS included
    (1.1.1.1, hijacked from the tun). strict_route keeps traffic in the VPN:
    the nearest sing-box gets to a kill switch. The tun uses the system stack
    (the OS's own, not gVisor). A server given by hostname is looked up on the
    device's own network (default_domain_resolver): through the tunnel, it
    would need itself up first."""
    doc = {
        "log": {"level": "warn"},
        "dns": {"servers": [{"type": "udp", "tag": "cloudflare", "server": "1.1.1.1", "detour": "tunnel"},
                            {"type": "local", "tag": "local"}],
                "final": "cloudflare"},
        "inbounds": [{"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                      "mtu": mtu, "stack": "system", "auto_route": True, "strict_route": True}],
        "endpoints": endpoints,
        "outbounds": [{"type": "selector", "tag": "tunnel", "outbounds": picks, "default": picks[0]}],
        "route": {"auto_detect_interface": True, "final": "tunnel", "default_domain_resolver": "local",
                  "rules": [{"inbound": "tun-in", "action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"}]
                  + rules},
    }
    return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"


def single_profile(u: Unit) -> str:
    """One tunnel, keepalives as its configs have them: only it runs."""
    return profile(u.endpoints, u.rules, [u.tag], u.mtu)


def group_profile(units: List[Unit]) -> str:
    """Tunnels picked in the app. sing-box starts every endpoint in a profile,
    so no keepalives: an endpoint only talks to its server while it carries
    traffic (and warped ones, sharing the device's WARP key, would knock each
    other off). The tun's MTU is the smallest, so a packet fits whichever
    tunnel is picked. A network two carriers' extras claim goes to the first."""
    endpoints = [{**ep, "peers": [{k: v for k, v in p.items() if k != "persistent_keepalive_interval"}
                                  for p in ep["peers"]]}
                 for u in units for ep in u.endpoints]
    rules, seen = [], set()
    for r in (r for u in units for r in u.rules):
        new = [c for c in r["ip_cidr"] if c not in seen]
        if new:
            rules.append({"ip_cidr": new, "outbound": r["outbound"]})
            seen.update(new)
    return profile(endpoints, rules, [u.tag for u in units], min(u.mtu for u in units))


def group_key(tag: str) -> str:
    """The group a tunnel also goes in, from the first word of its name
    (dengar.chi-us.iphone in dengar's); warp.<device> goes with the warped ones."""
    k = tag.split(".", 1)[0].lower()
    return "warped" if k == "warp" else k


# --- the tunnels of a device ---

class Device:
    def __init__(self, name: str, verb: str) -> None:
        if not name:
            raise Error(f"a device name, please (singbox.sh {verb} <device>)")
        if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]*", name):
            raise Error("device names are letters, digits, . _ - (not starting with .)")
        self.name = name
        self.dir = os.path.join(store.devices_dir(), name)
        self.profile = os.path.join(self.dir, "warp", "wgcf-profile.conf")
        self.setup = "install.sh" if name == store.this_mac() else f"{HERE} new {name}"

    def label(self, path: str) -> str:
        return os.path.relpath(path, store.devices_dir())


def units(dev: Device, swept: sweep.Sweep, say: Say) -> List[Unit]:
    """Every tunnel build makes, from config/ as the sweep leaves it: warped
    first (the composite's default is a warped one when there is one), then
    the plain ones, then WARP alone."""
    configs = swept.configs()
    warp = next((c for c in configs if c.name == store.warp_alone(dev.name)), None)
    if warp is not None and warp.problem():        # a stale copy of a profile the sweep skipped
        say(f"skipped {warp.name}: {warp.problem()}", False)
        warp = None
    usable = {r.name for r in swept.written()}       # warped tunnels with a carrier the sweep could use
    out: List[Unit] = []
    seen_cidrs: set = set()
    for c in [c for c in configs if c.name.startswith("warped.")] + \
             [c for c in configs if not store.sweep_owned(c.name, dev.name)]:
        why = c.problem()
        if why:
            say(f"skipped {c.name}: {why}", False)
            continue
        mtu = c.mtu(store.PLAIN_MTU)
        if not c.name.startswith("warped."):
            out.append(plain(c, mtu, say))
        elif warp is None:
            say(f"skipped {c.name}: no WARP profile", False)
        elif c.name not in usable:
            say(f"skipped {c.name}: no usable carrier for it in carriers/ (delete it if that's for good)", False)
        else:
            out.append(warped(c, mtu, warp, seen_cidrs, say))
    if warp is not None:
        out.append(Unit(warp.name, [endpoint(warp, warp.name, warp.mtu(store.WARP_MTU))], [], warp.mtu(store.WARP_MTU)))
    return out


def plain(c: Conf, mtu: int, say: Say) -> Unit:
    """A tunnel used as it stands. A profile sends everything to the tunnel in
    use, so a split config (a home LAN only, say) leaves the device with
    nothing past its own networks, not even DNS."""
    if "0.0.0.0/0" not in c.items("AllowedIPs"):
        say(f"warning: {c.name} is a split tunnel (no 0.0.0.0/0): in sing-box it takes all traffic, "
            "and only its own networks work", True)
    if not c.keepalive():
        say(f"warning: {c.name} has no PersistentKeepalive: its one-tunnel profile has none "
            f"(nor the WireGuard app's or tunnel.sh's copy); add one to {c.name}.conf", True)
    return Unit(c.name, [endpoint(c, c.name, mtu)], [], mtu)


def warped(c: Conf, mtu: int, warp: Conf, seen_cidrs: set, say: Say) -> Unit:
    """WARP detoured through the carrier. The carrier's extras (device-network,
    tunnel-routes) need a rule: AllowedIPs doesn't route in sing-box, so
    without one they'd go into WARP. WARP runs at its own MTU (1280 from
    wgcf), lowered when the carrier can't fit that plus its 80 bytes."""
    carrier = "carrier." + c.name[len("warped."):]
    wmtu = store.inner_mtu(mtu, warp.mtu(store.WARP_MTU))
    warp_net = f"{warp.endpoint()[0]}/32"
    own = store.collated({cidr for cidr in c.items("AllowedIPs") if cidr != warp_net})
    for cidr in own:
        if cidr in seen_cidrs:
            say(f"warning: {cidr} is in two carriers: profiles with both send it to the first, not {carrier}", True)
        seen_cidrs.add(cidr)
    rules = [{"ip_cidr": own, "outbound": carrier}] if own else []
    return Unit(c.name, [endpoint(c, carrier, mtu), endpoint(warp, c.name, wmtu, detour=carrier)], rules, wmtu)


# --- checks before writing ---

def check_keys(dev: Device, used: List[Conf], say: Say) -> None:
    """No private key shared with another device (two devices on one key knock
    each other off). Names the files, never the key. Not Nord's ("# source:
    nord"): Nord gives one key per account, so nord.sh keeps each on its own
    server instead. A key used twice on one device only gets a note: a device
    runs one tunnel (one profile) at a time, and groups have no keepalives."""
    def keyed(confs: List[Conf]) -> List[tuple]:
        return [(c.value("PrivateKey"), dev.label(c.path)) for c in confs
                if c.value("PrivateKey") and not any(ln.startswith("# source: nord") for ln in c.lines)]

    mine: Dict[str, str] = {}
    same_device = []
    for key, label in keyed(used):
        if key in mine:
            same_device.append(f"  {mine[key]} and {label}")
        else:
            mine[key] = label
    others = []
    for name in store.all_devices():
        if name == dev.name:
            continue
        d = os.path.join(store.devices_dir(), name)
        paths = store.files_in(os.path.join(d, "carriers")) + store.files_in(os.path.join(d, "config"))
        paths += [p for p in [os.path.join(d, "warp", "wgcf-profile.conf")] if os.path.isfile(p)]
        others += [f"  {mine[k]} and {label}" for k, label in keyed([Conf.read(p) for p in paths]) if k in mine]
    if others:
        raise Error("same private key in:\n" + "\n".join(others)
                    + "\neach config needs its own (make a new one for this device)")
    if same_device:
        say("note: same private key in (fine on one device: one tunnel at a time):\n" + "\n".join(same_device), True)


def check_tags(dev: Device, made: List[Unit]) -> None:
    """Endpoint names are unique ("tunnel" is the picker's), and no tunnel is
    named like the composite or a group profile."""
    tags = [ep["tag"] for u in made for ep in u.endpoints] + ["tunnel"]
    dup = store.collated({t for t in tags if tags.count(t) > 1})
    if dup:
        raise Error(f"more than one tunnel would be named: {' '.join(dup)} (rename the config; \"tunnel\", "
                    f"\"warp.{dev.name}\" and \"carrier.<name>\" are taken)")
    for u in made:
        if u.tag == dev.name:
            raise Error(f"a tunnel can't be named {u.tag}: {u.tag}.json is the composite (rename the config)")
        if u.tag.endswith(f".list.{dev.name}"):
            raise Error(f"a tunnel can't be named {u.tag}: <name>.list.{dev.name} is a group profile "
                        "(rename the config)")


# --- build ---

def plan(dev: Device, swept: sweep.Sweep, say: Say) -> Dict[str, str]:
    """Every profile build writes, by file name; changes nothing."""
    made = units(dev, swept, say)
    if not [u for u in made if u.tag != store.warp_alone(dev.name)]:
        raise Error(f"nothing to build: put configs in {dev.dir}/carriers or {dev.dir}/config")
    confs = {c.name: c for c in swept.configs()}
    check_keys(dev, [confs[u.tag] for u in made], say)
    check_tags(dev, made)
    files = {f"{u.tag}.json": single_profile(u) for u in made}
    files[f"{dev.name}.json"] = group_profile(made)
    groups: Dict[str, List[Unit]] = {}
    for u in made:
        groups.setdefault(group_key(u.tag), []).append(u)
    for k, members in groups.items():
        if len(members) >= 2:
            files[f"{k}.list.{dev.name}.json"] = group_profile(members)
    return files


def sweep_for(dev: Device) -> sweep.Sweep:
    try:
        return sweep.Sweep(dev.dir, app_column=False)
    except Error as e:
        print(f"{sweep.PROG}: {e}", file=sys.stderr)
        raise Error("sweep failed") from None


def cmd_build(name: str) -> None:
    dev = Device(name, "build")
    if not os.path.isdir(dev.dir):
        raise Error(f"no device {dev.dir} ({dev.setup})")
    if os.path.isfile(dev.profile):
        why = Conf.read(dev.profile).problem()
        if why:
            raise Error(f"WARP profile {dev.profile}: {why}")
    else:
        # A device with only config/ (wireguard-tools delivers those): its plain tunnels, no WARP
        print(f"No WARP profile in {dev.dir}/warp: plain tunnels only ({dev.setup} adds WARP)")
    print(f"== Sweep {dev.dir}")
    swept = sweep_for(dev)
    swept.run()
    print()
    files = plan(dev, swept, loud)

    out = os.path.join(dev.dir, "sing-box")
    store.private_dir(out)
    print(f"== Profiles in {out}")
    checked = sing_box_check(files)
    for f, text in files.items():
        path = os.path.join(out, f)
        state = store.state_of(path, text)
        if state != "unchanged":
            store.write_private(path, text)
        print(f"{f:<48} {state}")
    for path in store.files_in(out, ".json"):
        f = os.path.basename(path)
        if f not in files:
            os.remove(path)
            print(f"{f:<48} removed (no longer built)")
    if not checked:
        print("(not checked: sing-box isn't installed on this Mac)")
    print()
    if name == store.this_mac():
        print("Next: import the profiles you want in the sing-box app on this Mac\n"
              "      (Profiles > New Profile > Import). They use the daemon's keys: run\n"
              "      tunnel.sh down before turning sing-box on, and turn sing-box off\n"
              "      before tunnel.sh up. sing-box has no kill switch once it stops.")
        return
    print("Next: AirDrop the profiles you want to the device and import each in sing-box\n"
          "      (Profiles > New Profile > Import). The composite (every tunnel) and the\n"
          "      .list. groups (one server's, or the warped ones) switch tunnels in the app's\n"
          "      picker without dropping the VPN; a one-tunnel profile switches by switching\n"
          "      profiles. They hold private keys: delete the copies you send.")


def sing_box_check(files: Dict[str, str]) -> bool:
    """sing-box check on every profile before any is written (a failure changes
    nothing); False when sing-box isn't installed."""
    if not shutil.which("sing-box"):
        return False
    with tempfile.TemporaryDirectory() as tmp:
        for f, text in files.items():
            path = os.path.join(tmp, f)
            store.write_private(path, text)
            if subprocess.run(["sing-box", "check", "-c", path]).returncode != 0:
                raise Error(f"sing-box check failed for {f}: no profile changed")
    return True


# --- new, list ---

def wgcf(folder: str, *args: str) -> None:
    """wgcf, its chatter (a device table) shown only if it fails."""
    if not shutil.which("wgcf"):
        raise Error("wgcf missing (install.sh --sing-box, or brew install wgcf)")
    run = subprocess.run(["wgcf", *args], cwd=folder, capture_output=True, text=True)
    if run.returncode != 0:
        print(run.stdout + run.stderr, file=sys.stderr, end="")
        raise Error(f"wgcf {args[0]} failed")


def cmd_new(name: str) -> None:
    dev = Device(name, "new")
    subs = [os.path.join(dev.dir, s) for s in ("carriers", "warp", "config")]
    for d in (store.root(), store.devices_dir(), dev.dir, *subs):
        store.private_dir(d)
    warp = os.path.join(dev.dir, "warp")
    account = os.path.join(warp, "wgcf-account.toml")
    if os.path.isfile(account):
        print("WARP account: already there")
    else:
        wgcf(warp, "register", "--accept-tos")
        if os.path.exists(dev.profile):
            os.remove(dev.profile)          # one left from an earlier account
        print("WARP account: registered")
    os.chmod(account, 0o600)
    if not os.path.isfile(dev.profile):
        wgcf(warp, "generate")
    os.chmod(dev.profile, 0o600)
    # config/warp.<device>.conf (WARP alone, for the WireGuard app) now, for a device that never runs build
    with open(os.devnull, "w") as quiet:
        sweep_for(dev).run(out=quiet)
    print(f"WireGuard app config: {dev.dir}/config/warp.{name}.conf (WARP alone)\n")
    print(f"Next: put this device's carriers in {dev.dir}/carriers/ and its plain tunnels\n"
          f"      in {dev.dir}/config/ (new WireGuard configs made for this device)\n"
          f"then: {HERE} build {name}")


def cmd_list() -> None:
    names = store.all_devices()
    if not names:
        print(f"no devices yet ({HERE} new <device>)")
        return
    print(f"{'DEVICE':<20} {'CARRIERS':<9} {'TUNNELS':<8} {'WARP':<5} PROFILES")
    mac = store.this_mac()
    for name in names:
        d = os.path.join(store.devices_dir(), name)
        profiles = os.path.join(d, "sing-box")
        n_profiles = len(store.files_in(profiles, ".json"))
        shown = name + (" (this Mac)" if name == mac else "")
        warp = "yes" if os.path.isfile(os.path.join(d, "warp", "wgcf-profile.conf")) else "no"
        print(f"{shown:<20} {len(store.files_in(os.path.join(d, 'carriers'))):<9} "
              f"{len(store.files_in(os.path.join(d, 'config'))):<8} {warp:<5} {n_profiles}")


def main(argv: Optional[List[str]] = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    os.umask(0o077)
    verb = args[0] if args else ""
    try:
        if verb == "new":
            cmd_new(args[1] if len(args) > 1 else "")
        elif verb == "build":
            cmd_build(args[1] if len(args) > 1 else "")
        elif verb == "list":
            cmd_list()
        else:
            print(__doc__, end="")
            return 0 if verb in ("-h", "--help") else 1
    except store.FAILURES as e:
        store.die(PROG, str(e))
    return 0


if __name__ == "__main__":
    sys.exit(main())
