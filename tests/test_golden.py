"""The old shell scripts' output, byte for byte: tests/golden/edge/ is the
store the shell sweep and singbox.sh left after running every device of
golden/edge_store.py's store, and edge.modes its modes. Change them only on
purpose, when what the scripts write is meant to change."""

from __future__ import annotations

import contextlib
import io
import os
import stat

from wgtun import singbox, store, sweep
from wgtun.store import Error

from .golden import edge_store

GOLDEN = os.path.join(os.path.dirname(__file__), "golden")


def tree(root: str) -> dict:
    out = {}
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            path = os.path.join(dirpath, f)
            with open(path, "rb") as fh:
                out[os.path.relpath(path, root)] = fh.read()
    return out


def modes(root: str) -> str:
    """As the shell listed them (find | sort): "<mode> ./<path>", by path."""
    paths = ["."] + ["./" + os.path.relpath(os.path.join(d, n), root)
                     for d, dirs, files in os.walk(root) for n in dirs + files]
    return "".join(f"{stat.S_IMODE(os.stat(os.path.join(root, p)).st_mode):o} {p}\n" for p in store.collated(paths))


def test_the_shells_output(tmp_path, monkeypatch):
    root = str(tmp_path / "store")
    edge_store.make(root)
    monkeypatch.setenv("WG_TUNNELS", root)
    old = os.umask(0o077)
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            sweep.Sweep(sweep.resolve("")).run()
            for device in store.all_devices():
                sweep.Sweep(sweep.resolve(device)).run()
                for _ in range(2):
                    with contextlib.suppress(Error):
                        singbox.cmd_build(device)
    finally:
        os.umask(old)
    assert tree(root) == tree(os.path.join(GOLDEN, "edge"))
    with open(os.path.join(GOLDEN, "edge.modes")) as f:
        assert modes(root) == f.read()
