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
import sys
from typing import List, Optional, Set, Tuple

from . import singbox, store, sweep
from .conf import Conf

Found = List[Tuple[str, str]]      # (error or warning, what)
PROG = "check.sh"


def quiet(_text: str, _err: bool = False) -> None:
    """build's own warnings: the check says its own (or they're the user's call)."""


def modes(f: store.Folder) -> Found:
    found: Found = []
    for d in (d for d in (f.dir, *f.private) if os.path.isdir(d)):
        m = store.mode(d)
        if m != 0o700:
            found.append(("error", f"{os.path.relpath(d, f.dir)}/ is {m:o}, should be 700"))
    for d in (d for d in f.private if os.path.isdir(d)):
        for name in store.collated(n for n in os.listdir(d) if n != ".DS_Store"):     # Finder's, not ours
            path = os.path.join(d, name)
            if os.path.isfile(path) and store.mode(path) != 0o600:
                found.append(("error", f"{os.path.relpath(path, f.dir)} is {store.mode(path):o}, should be 600"))
    return found


def check_device(name: str) -> Found:
    f = store.Folder.of(name)
    found = modes(f)
    broken: Set[str] = set()           # configs already reported: the sweep or build skips them
    unreadable = False
    for path in f.confs():
        try:
            c = Conf.read(path)
        except store.FAILURES as e:
            found.append(("error", str(e)))
            unreadable = True
            continue
        why = c.problem()
        if why:
            found.append(("error", f"{os.path.relpath(path, f.dir)}: {why}"))
            broken.add(path)
        elif os.path.dirname(path) == f.config and not c.keepalive():
            found.append(("warning", f"{os.path.relpath(path, f.dir)}: no PersistentKeepalive, so none in the "
                                     "WireGuard app, tunnel.sh or its sing-box profile either"))
    if unreadable:                     # the sweep or build would stop at it too: said once
        return found
    try:
        found += up_to_date(f, broken)
    except store.FAILURES as e:        # a shared key, say
        found.append(("error", str(e)))
    return found


def stale(path: str, state: str, fix: str) -> Tuple[str, str]:
    return ("error", f"{path} is {'missing' if state == 'new' else 'out of date'}: {fix}")


def up_to_date(f: store.Folder, broken: Set[str]) -> Found:
    """config/ and sing-box/ against what the sweep and build would write now,
    and what they'd skip. Configs already reported broken aren't said again."""
    found: Found = []
    fix = f"run singbox.sh build {f.name}" if os.path.isdir(f.sing_box) else f"run wgwarp-sweep.sh {f.name}"
    swept = sweep.Sweep(f.dir, app_column=False)
    for r in swept.rows:
        if r.text and r.state != "unchanged":
            found.append(stale(os.path.relpath(r.path, f.dir), r.state, fix))
        elif r.state == "skipped" and r.source not in broken:     # a duplicate name
            found.append(("warning", f"{r.name}: skipped, {r.detail}"))
        elif r.state == "orphan":
            found.append(("warning", f"{os.path.relpath(r.path, f.dir)}: an orphan ({swept.orphan_reason(r)}): "
                                     "delete it if that's for good"))
    # Every config/ tunnel (an orphan too: the WireGuard app or tunnel.sh may
    # still run it), not only those build makes; nothing past this is sure then
    error, _ = store.key_clashes(f.name, swept.configs())
    if error:
        return found + [("error", error)]
    if not os.path.isdir(f.sing_box):
        return found
    built = singbox.plan(singbox.Device(f.name, "build"), swept, quiet)
    for file, text in built.items():
        state = store.state_of(os.path.join(f.sing_box, file), text)
        if state != "unchanged":
            found.append(stale(f"sing-box/{file}", state, fix))
    for path in store.files_in(f.sing_box, ".json"):
        if os.path.basename(path) not in built:
            found.append(("error", f"sing-box/{os.path.basename(path)} isn't a profile build makes: {fix}"))
    return found


def report(name: str) -> int:
    """Print what's wrong with a device; how many errors."""
    try:
        real = name in store.all_devices()        # a folder in devices/, whatever its name
        found = check_device(name) if real else [("error", f"no device {name}")]
    except store.FAILURES as e:        # one it can't finish (a folder it can't read): the rest go on
        found = [("error", str(e))]
    print(f"{name:<20} {'ok' if not found else ''}".rstrip())
    for kind, what in found:
        print(f"  {kind}: " + what.replace("\n", "\n    "))
    return sum(1 for kind, _ in found if kind == "error")


def main(argv: Optional[List[str]] = None) -> int:
    args = sys.argv[1:] if argv is None else argv

    def body() -> int:
        if args[:1] in (["-h"], ["--help"]):
            print(__doc__, end="")
            return 0
        names = args or store.all_devices()
        if not names:
            raise store.Error(f"no devices in {store.devices_dir()}")
        errors = sum(report(name) for name in names)
        print(f"\n{errors} error{'s' * (errors != 1)} in {len(names)} device{'s' * (len(names) != 1)}")
        return 1 if errors else 0

    return store.run_main(PROG, body)


if __name__ == "__main__":
    sys.exit(main())
