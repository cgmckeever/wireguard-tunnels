"""~/wg-tunnels ($WG_TUNNELS): where things are, what they're called, and the
rules every tunnel follows."""

from __future__ import annotations

import contextlib
import ipaddress
import locale
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Callable, Dict, Iterable, List, Optional, Tuple

from .conf import Conf, Error, is_number, read_text, stem

KEEPALIVE = 25                       # seconds: every one-tunnel config has one
WARP_ENDPOINT = "162.159.192.1:2408"  # Cloudflare's, unless .warp-endpoint says otherwise
WARP_MTU = 1280                      # wgcf's, and IPv6's minimum
WARP_OVERHEAD = 80                   # what a carrier adds to each WARP packet
WIDEST_V4, WIDEST_V6 = 8, 16          # a carrier's extras: wider would take traffic from WARP
PLAIN_MTU = 1420                     # wg-quick's default
WARPED = "warped."                   # the name of a tunnel that carries WARP starts with it
NORD_MARK = "# source: nord"          # nord.sh's line: a Nord config (it shares the account's key)
SCRIPTS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts")

# What a main() reports as one line instead of a traceback: its own reasons
# (a file that isn't UTF-8 is one: conf.read_text) and a file it can't read or
# write (permissions, a race)
FAILURES = (Error, OSError)


def run_main(prog: str, body: Callable[[], Optional[int]]) -> int:
    """A script's main(): umask 077 (everything here holds private keys), and
    a failure as one line, "<prog>: <why>"."""
    os.umask(0o077)
    try:
        return body() or 0
    except FAILURES as e:
        print(f"{prog}: {e}", file=sys.stderr)
        return 1


# --- where things are ---

def root() -> str:
    return os.environ.get("WG_TUNNELS") or os.path.expanduser("~/wg-tunnels")


def devices_dir() -> str:
    return os.path.join(root(), "devices")


def device_dir(device: str) -> str:
    return os.path.join(devices_dir(), device)


def valid_device(name: str) -> bool:
    """A name a device folder can have (tunnel.sh keeps a copy, pinned by its tests)."""
    return re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]*", name) is not None


def require_device_name(name: str) -> None:
    """valid_device, or the Error that says why not."""
    if not valid_device(name):
        raise Error(f"device names are letters, digits, . _ - (not starting with .): {name}")


def mode(path: str) -> int:
    """A file's or folder's permission bits (0o600, say)."""
    return stat.S_IMODE(os.stat(path).st_mode)


class Folder:
    """A device's folder and what's in it."""

    def __init__(self, path: str) -> None:
        self.dir = path
        self.name = os.path.basename(os.path.abspath(path))   # the device, always last in its tunnels' names
        self.carriers = os.path.join(path, "carriers")       # WireGuard configs to carry WARP
        self.config = os.path.join(path, "config")           # every tunnel the device runs
        self.warp = os.path.join(path, "warp")               # its wgcf WARP account and profile
        self.account = os.path.join(self.warp, "wgcf-account.toml")
        self.profile = os.path.join(self.warp, "wgcf-profile.conf")
        self.sing_box = os.path.join(path, "sing-box")       # singbox.sh build's
        self.exports = os.path.join(path, "exports")         # WireGuard app exports (tunnel.sh extract)
        # What holds private keys (as their folders do: 0700, files 0600)
        self.private = (self.carriers, self.config, self.warp, self.exports, self.sing_box)

    @classmethod
    def of(cls, device: str) -> Folder:
        return cls(device_dir(device))

    def confs(self) -> List[str]:
        """Every config the device has: carriers/, config/, and its WARP profile."""
        profile = [self.profile] if os.path.isfile(self.profile) else []
        return files_in(self.carriers) + files_in(self.config) + profile


def this_mac() -> str:
    """This Mac's device (tunnel.sh default), or ""."""
    path = os.path.join(devices_dir(), ".default")
    return read_text(path).strip() if os.path.isfile(path) else ""


def collated(items: Iterable[str]) -> List[str]:
    """In the shell's order: the locale's collation (LC_COLLATE), as bash
    lists <folder>/*.conf and sort sorts. Which tunnel a composite profile
    picks first, and the order of a carrier's routes, follow it."""
    try:
        locale.setlocale(locale.LC_COLLATE, "")
    except locale.Error:            # a locale this Mac doesn't have: bash falls back to C too
        locale.setlocale(locale.LC_COLLATE, "C")
    return sorted(items, key=locale.strxfrm)


def files_in(folder: str, ext: str = ".conf") -> List[str]:
    """The <ext> files in a folder (none if it isn't one), by name, as the
    shell's <folder>/*<ext> lists them: dotfiles (temp files) aren't."""
    if not os.path.isdir(folder):
        return []
    return collated([os.path.join(folder, f) for f in os.listdir(folder)
                    if f.endswith(ext) and not f.startswith(".") and os.path.isfile(os.path.join(folder, f))])


def all_devices() -> List[str]:
    d = devices_dir()
    if not os.path.isdir(d):
        return []
    return collated([n for n in os.listdir(d) if not n.startswith(".") and os.path.isdir(os.path.join(d, n))])


# --- names and numbers ---

def is_warped(name: str) -> bool:
    """A tunnel that carries WARP, by its name's prefix in any case: the Mac's file
    system ignores case, so Warped.x is the file the sweep writes as warped.x."""
    return name[:len(WARPED)].lower() == WARPED


def is_warp_alone(name: str, device: str) -> bool:
    """<name> is the device's WARP-only tunnel, in any case (as is_warped)."""
    return name.lower() == warp_alone(device).lower()


def warped_name(carrier: str, device: str) -> str:
    """The tunnel a carrier becomes, the device always last: x.conf,
    warped.x.conf and warped-x.conf all become warped.x.<device>, and a device
    elsewhere in the name, as a word of its own (between . _ - or the ends),
    moves to the end (x_<device>-y becomes warped.x-y.<device>)."""
    n = re.sub(r"^warped[.-]", "", stem(carrier), flags=re.I)
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
    return WARPED + n


def warp_alone(device: str) -> str:
    """The name of the device's WARP-only tunnel."""
    return f"warp.{device}"


def sweep_owned(name: str, device: str) -> bool:
    """The sweep writes these config/ names, in any case (the Mac's file system
    ignores it); wireguard-tools never does (it names its files <server>.<config>)
    and leaves them alone (its tunnels.sweep_owned: the same rule)."""
    return is_warped(name) or is_warp_alone(name, device)


def warp_endpoint(folder: str) -> str:
    """IPv4:port from <device>/.warp-endpoint, else <store>/.warp-endpoint, else
    Cloudflare's: per device for one whose network routes the shared address
    elsewhere (a router whose own WARP holds a route to it)."""
    for f in (os.path.join(folder, ".warp-endpoint"), os.path.join(root(), ".warp-endpoint")):
        if os.path.isfile(f):
            ep = re.sub(r"[ \t\r\n]", "", read_text(f))
            if not valid_endpoint(ep):
                raise Error(f"{f}: IPv4:port, e.g. {WARP_ENDPOINT} (not {ep})")
            return ep
    return WARP_ENDPOINT


def valid_endpoint(ep: str) -> bool:
    """An IPv4 address and a port (1-65535), as in 162.159.192.1:2408."""
    host, _, port = ep.rpartition(":")
    try:
        ipaddress.IPv4Address(host)
    except ValueError:
        return False
    return is_number(port) and 1 <= int(port) <= 65535


def warp_net(endpoint: str) -> str:
    """The route to a WARP endpoint (host:port): what a carrier carries."""
    return endpoint.rsplit(":", 1)[0] + "/32"


def inner_mtu(carrier_mtu: int, warp_mtu: int = WARP_MTU) -> int:
    """WARP's MTU inside a carrier: its own, lowered when the carrier can't
    fit that plus what it adds to each packet. (tunnel.sh has its own copy.)"""
    return min(warp_mtu, carrier_mtu - WARP_OVERHEAD)


# --- writing ---

def state_of(path: str, text: str) -> str:
    """What writing text to path would be: new, updated or unchanged. A file
    there under another case (the Mac's file system finds it) is updated: its
    name changes, and the name is what tunnel.sh and the WireGuard app go by."""
    if not os.path.isfile(path):
        return "new"
    if os.path.basename(path) not in os.listdir(os.path.dirname(path) or "."):
        return "updated"
    with open(path, "rb") as f:
        return "unchanged" if f.read() == text.encode() else "updated"


def write_private(path: str, text: str) -> None:
    """Put text at path, 0600, all at once: a temp file of its own beside it
    (mkstemp makes it 0600), then a rename; never a half-written file."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def case_twins(paths: Iterable[str], wanted: Iterable[str]) -> List[str]:
    """The paths that are a wanted path with different case: the same file on
    the Mac's file system, which a write would keep under its old name."""
    lower = {w.lower(): w for w in wanted}
    return [p for p in paths if lower.get(p.lower(), p) != p]


def update_private(path: str, text: str) -> str:
    """write_private, only when it would change anything: new, updated or unchanged."""
    state = state_of(path, text)
    if state != "unchanged":
        write_private(path, text)
    return state


def private_dir(path: str) -> bool:
    """Make path a 0700 folder; whether that changed anything. devices/ then
    gets its README (write_readme)."""
    if os.path.isdir(path) and mode(path) == 0o700:
        write_readme()
        return False
    os.makedirs(path, exist_ok=True)
    os.chmod(path, 0o700)
    write_readme()
    return True


README = "README-tunnels.md"     # wireguard-tools writes its own README-tools.md beside it


def write_readme() -> None:
    """devices/, if it exists, gets README-tunnels.md if it has none (one already
    there is kept, edited or not)."""
    path = os.path.join(devices_dir(), README)
    if not os.path.isdir(devices_dir()) or os.path.lexists(path):
        return
    with open(os.path.join(os.path.dirname(__file__), "readmes", "devices.md"), encoding="utf-8") as f:
        text = f.read()
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        out.write(text)


# --- the device's WARP account ---

def wgcf(folder: str, *args: str) -> None:
    """wgcf, its chatter (a device table) shown only if it fails."""
    if not shutil.which("wgcf"):
        raise Error("wgcf missing (brew install wgcf)")
    run = subprocess.run(["wgcf", *args], cwd=folder, capture_output=True, text=True)
    if run.returncode != 0:
        print(run.stdout + run.stderr, file=sys.stderr, end="")
        raise Error(f"wgcf {args[0]} failed")


def warp_account(f: Folder) -> Tuple[bool, bool, List[str]]:
    """The device's own WARP account and profile in warp/, made if missing
    (every device has its own: one account on two devices knocks both off).
    Returns (registered now, profile generated now, files tightened to 0600)."""
    private_dir(f.warp)
    registered = not os.path.isfile(f.account)
    if registered:
        wgcf(f.warp, "register", "--accept-tos")
        with contextlib.suppress(FileNotFoundError):
            os.remove(f.profile)            # one left from an earlier account
    generated = not os.path.isfile(f.profile)
    if generated:
        wgcf(f.warp, "generate")
    # The account (its API token) and the profile (its private key): owner only, whatever wgcf wrote them as
    tightened = [p for p in (f.account, f.profile) if mode(p) != 0o600]
    for p in tightened:
        os.chmod(p, 0o600)
    return registered, generated, tightened


# --- keys ---

def key_clashes(device: str, used: List[Conf]) -> Tuple[str, str]:
    """(an error, a note), each "" for none. No private key on two devices
    (two devices on one key knock each other off), wherever they run it: the
    error names the files, never the key. Not Nord's (NORD_MARK): Nord
    gives one key per account, so nord.sh keeps each on its own server
    instead. A key used twice on one device only gets a note: a device runs
    one tunnel (one profile) at a time, and sing-box groups have no keepalives."""
    def keyed(confs: Iterable[Conf]) -> List[Tuple[str, str]]:
        return [(key, os.path.relpath(c.path, devices_dir())) for c in confs
                for key in [c.value("PrivateKey")] if key and not any(ln.startswith(NORD_MARK) for ln in c.lines)]

    mine: Dict[str, str] = {}
    same_device = []
    for key, label in keyed(used):
        if key in mine:
            same_device.append(f"  {mine[key]} and {label}")
        else:
            mine[key] = label
    others = [f"  {mine[k]} and {label}" for name in all_devices() if name != device
              for k, label in keyed(_readable(name)) if k in mine]
    error = ("same private key in:\n" + "\n".join(others)
             + "\neach config needs its own (make a new one for this device)") if others else ""
    note = ("note: same private key in (fine on one device: one tunnel at a time):\n"
            + "\n".join(same_device)) if same_device else ""
    return error, note


def _readable(device: str) -> List[Conf]:
    """Another device's configs, less any it can't read (a file, or a folder):
    that device's own sweep, build and check say so, not this one's."""
    out: List[Conf] = []
    with contextlib.suppress(*FAILURES):
        for p in Folder.of(device).confs():
            with contextlib.suppress(*FAILURES):
                out.append(Conf.read(p))
    return out
