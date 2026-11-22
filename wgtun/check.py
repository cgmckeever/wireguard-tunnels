"""check.sh — is the store as the scripts leave it, and does every tunnel follow
the rules? Changes nothing.

Usage:
  check.sh                every device
  check.sh <device>...    just those

For each device:
  - every config in carriers/ and config/, and warp/wgcf-profile.conf, is a
    usable one-peer config
  - every file in carriers/, config/, warp/, exports/ and sing-box/ is 0600,
    and the device's folders 0700 (they hold private keys)
  - no private key is on another device too (both would drop)
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

Found = List[Tuple[str, str]]      # (error or warning, what)


def quiet(_text: str, _err: bool = False) -> None:
    """build's own notes and warnings: the check says its own."""


def mode(path: str) -> int:
    return stat.S_IMODE(os.stat(path).st_mode)


def modes(f: store.Folder) -> Found:
    found: Found = []
    folders = [f.dir, *f.private]
    for d in (d for d in folders if os.path.isdir(d)):
        if mode(d) != 0o700:
            found.append(("error", f"{os.path.relpath(d, f.dir)}/ is {mode(d):o}, should be 700"))
        if d == f.dir:
            continue
        for name in sorted(n for n in os.listdir(d) if n != ".DS_Store"):     # Finder's, not ours
            path = os.path.join(d, name)
            if os.path.isfile(path) and mode(path) != 0o600:
                found.append(("error", f"{os.path.relpath(path, f.dir)} is {mode(path):o}, should be 600"))
    return found


def check_device(name: str) -> Found:
    f = store.Folder.of(name)
    found = modes(f)
    unreadable = False
    for path in store.files_in(f.carriers) + store.files_in(f.config) + \
            ([f.profile] if os.path.isfile(f.profile) else []):
        try:
            c = Conf.read(path)
        except store.FAILURES as e:
            found.append(("error", str(e)))
            unreadable = True
            continue
        why = c.problem()
        if why:
            found.append(("error", f"{os.path.relpath(path, f.dir)}: {why}"))
        elif os.path.dirname(path) == f.config and not c.keepalive():
            found.append(("warning", f"{os.path.relpath(path, f.dir)}: no PersistentKeepalive, so none in the "
                                     "WireGuard app, tunnel.sh or its sing-box profile either"))
    if unreadable:                     # the sweep and build would stop at it too: said once
        return found
    try:
        found += up_to_date(f)
    except store.FAILURES as e:        # the sweep or build would stop: a shared key, say
        found.append(("error", str(e)))
    return found


def up_to_date(f: store.Folder) -> Found:
    """config/ and sing-box/ against what the sweep and build would write now."""
    found: Found = []
    fix = f"run singbox.sh build {f.name}" if os.path.isdir(f.sing_box) else f"run wgwarp-sweep.sh {f.name}"
    swept = sweep.Sweep(f.dir, app_column=False)
    for r in swept.written():
        if r.state != "unchanged":
            what = "missing" if r.state == "new" else "out of date"
            found.append(("error", f"{os.path.relpath(r.path, f.dir)} is {what}: {fix}"))
    store.check_keys(f.name, swept.configs(), quiet)     # every config, wherever the device runs it
    if not os.path.isdir(f.sing_box):
        return found
    built = singbox.plan(singbox.Device(f.name, "build"), swept, quiet)
    for file, text in built.items():
        state = store.state_of(os.path.join(f.sing_box, file), text)
        if state != "unchanged":
            found.append(("error", f"sing-box/{file} is {'missing' if state == 'new' else 'out of date'}: {fix}"))
    for path in store.files_in(f.sing_box, ".json"):
        if os.path.basename(path) not in built:
            found.append(("error", f"sing-box/{os.path.basename(path)} isn't a profile build makes: {fix}"))
    return found


def report(name: str) -> int:
    """Print what's wrong with a device; how many errors."""
    try:
        found = check_device(name) if os.path.isdir(store.device_dir(name)) else [("error", f"no device {name}")]
    except store.FAILURES as e:        # one it can't finish (a folder it can't read): the rest go on
        found = [("error", str(e))]
    print(f"{name:<20} {'ok' if not found else ''}".rstrip())
    for kind, what in found:
        print(f"  {kind}: " + what.replace("\n", "\n    "))
    return sum(1 for kind, _ in found if kind == "error")


def main(argv: Optional[List[str]] = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if args and args[0] in ("-h", "--help"):
        print(__doc__, end="")
        return 0
    names = args or store.all_devices()
    if not names:
        store.die("check.sh", f"no devices in {store.devices_dir()}")
    errors = sum(report(name) for name in names)
    print(f"\n{errors} error{'s' * (errors != 1)} in {len(names)} device{'s' * (len(names) != 1)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
