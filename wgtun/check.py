"""check.sh — is the store as the scripts leave it, and does every tunnel follow
the rules? Changes nothing.

Usage:
  check.sh                every device
  check.sh <device>...    just those

For each device:
  - every config in carriers/, config/ and warp/ is a usable one-peer config
  - every file is 0600 and every folder 0700 (they hold private keys)
  - every config/ tunnel has a keepalive: the WireGuard app (qr.sh), tunnel.sh
    and sing-box all use config/ as it is, so one without has none anywhere
  - config/'s warped.* and warp.<device>.conf are what the sweep writes now
  - sing-box/, if the device has one, is what singbox.sh build writes now

Exits 1 when anything is wrong; warnings alone don't count.
"""

from __future__ import annotations

import os
import stat
import sys
from typing import List, Optional, Tuple

from . import singbox, store, sweep
from .conf import Conf
from .store import Error

Found = List[Tuple[str, str]]      # (error or warning, what)


def quiet(_text: str, _err: bool) -> None:
    """build's own notes and warnings: the check says its own."""


def mode(path: str) -> int:
    return stat.S_IMODE(os.stat(path).st_mode)


def check_device(name: str) -> Found:
    found: Found = []
    d = os.path.join(store.devices_dir(), name)
    folders = [d] + [os.path.join(d, s) for s in ("carriers", "config", "warp", "sing-box")]
    confs = store.confs_in(folders[1]) + store.confs_in(folders[2])
    profile = os.path.join(d, "warp", "wgcf-profile.conf")
    if os.path.isfile(profile):
        confs.append(profile)
    profiles = folders[4]
    jsons = [os.path.join(profiles, f) for f in os.listdir(profiles) if f.endswith(".json")] \
        if os.path.isdir(profiles) else []

    def label(path: str) -> str:
        return os.path.relpath(path, d)

    for f in folders:
        if os.path.isdir(f) and mode(f) != 0o700:
            found.append(("error", f"{label(f)}/ is {mode(f):o}, should be 700"))
    for f in confs + jsons:
        if mode(f) != 0o600:
            found.append(("error", f"{label(f)} is {mode(f):o}, should be 600"))
    for f in confs:
        c = Conf.read(f)
        why = c.problem()
        if why:
            found.append(("error", f"{label(f)}: {why}"))
        elif f.startswith(folders[2] + os.sep) and not c.keepalive():
            found.append(("warning", f"{label(f)}: no PersistentKeepalive, so none in the WireGuard app, "
                                     "tunnel.sh or its sing-box profile either"))

    fix = f"run singbox.sh build {name}" if os.path.isdir(profiles) else f"run wgwarp-sweep.sh {name}"
    try:
        swept = sweep.Sweep(d, for_singbox=True)
    except Error as e:
        return found + [("error", f"the sweep would stop: {e}")]
    for r in swept.written():
        if r.state != "unchanged":
            found.append(("error", f"{label(r.path)} is {'missing' if r.state == 'new' else 'out of date'}: {fix}"))
    dev = singbox.Device(name, "build")
    try:
        singbox.check_keys(dev, swept.configs(), quiet)    # wherever the device runs them
    except Error as e:
        return found + [("error", str(e))]
    if not os.path.isdir(profiles):
        return found
    try:
        built = singbox.plan(dev, swept, quiet)
    except Error as e:
        return found + [("error", f"singbox.sh build would stop: {e}")]
    for f, text in built.items():
        state = store.state_of(os.path.join(profiles, f), text)
        if state != "unchanged":
            found.append(("error", f"sing-box/{f} is {'missing' if state == 'new' else 'out of date'}: {fix}"))
    for f in jsons:
        if os.path.basename(f) not in built:
            found.append(("error", f"sing-box/{os.path.basename(f)} isn't a profile build makes: {fix}"))
    return found


def main(argv: Optional[List[str]] = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if args and args[0] in ("-h", "--help"):
        print(__doc__, end="")
        return 0
    names = args or store.all_devices()
    if not names:
        store.die("check.sh", f"no devices in {store.devices_dir()}")
    errors = 0
    for name in names:
        if not os.path.isdir(os.path.join(store.devices_dir(), name)):
            store.die("check.sh", f"no device {name}")
        found = check_device(name)
        errors += sum(1 for kind, _ in found if kind == "error")
        print(f"{name:<20} {'ok' if not found else ''}".rstrip())
        for kind, what in found:
            print(f"  {kind}: " + what.replace("\n", "\n    "))
    print(f"\n{errors} error{'s' * (errors != 1)} in {len(names)} device{'s' * (len(names) != 1)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
