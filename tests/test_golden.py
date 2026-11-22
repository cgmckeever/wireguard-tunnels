"""The old shell scripts' output, byte for byte. golden/edge_store.py makes a
store; the shell sweep and singbox.sh (git show 43dbd87~1:scripts/...) ran
every device of it, and left:

  golden/edge/        every file
  golden/edge.modes   their modes (find | sort)
  golden/edge.out     what each run printed, paths as <store> and <scripts>,
                      with the one message changed on purpose: a skipped
                      carrier says what's wrong with it

Change them only on purpose, when what the scripts write or say is meant to
change (and say so in the commit)."""

from __future__ import annotations

import contextlib
import io
import os
import stat

import pytest

from wgtun import singbox, store, sweep

from .golden import edge_store

GOLDEN = os.path.join(os.path.dirname(__file__), "golden")


def read(path: str, mode: str = "r"):
    with open(path, mode) as f:
        return f.read()


def tree(root: str) -> dict:
    return {os.path.relpath(os.path.join(d, f), root): read(os.path.join(d, f), "rb")
            for d, _dirs, files in os.walk(root) for f in files}


def modes(root: str) -> str:
    """As the shell listed them: "<mode> ./<path>", by path."""
    paths = ["."] + ["./" + os.path.relpath(os.path.join(d, n), root)
                     for d, dirs, files in os.walk(root) for n in dirs + files]
    return "".join(f"{stat.S_IMODE(os.stat(os.path.join(root, p)).st_mode):o} {p}\n" for p in store.collated(paths))


def run(label: str, main, args) -> str:
    """One run as the shell's was recorded: its exit code, stdout, stderr."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = main(args)
        except SystemExit as e:
            code = e.code
    return f"### {label} (exit {code})\n{out.getvalue()}--- stderr\n{err.getvalue()}"


@pytest.fixture
def ran(tmp_path, monkeypatch) -> tuple:
    """(the store, what was printed) after every run the shell's golden had."""
    root = str(tmp_path / "store")
    edge_store.make(root)
    monkeypatch.setenv("WG_TUNNELS", root)
    monkeypatch.setenv("LC_ALL", "en_US.UTF-8")      # the collation the goldens were made in
    old = os.umask(0o022)                             # a terminal's: each main() sets its own
    try:
        said = [run("sweep-default", sweep.main, [])]
        for d in store.all_devices():
            said += [run(f"sweep-{d}", sweep.main, [d]), run(f"build-{d}", singbox.main, ["build", d]),
                     run(f"rebuild-{d}", singbox.main, ["build", d])]
        said += [run("list", singbox.main, ["list"]), run("sweep-baddir", sweep.main, ["/nonexistent"]),
                 run("build-nodev", singbox.main, ["build", "nosuchdevice"])]
    finally:
        os.umask(old)
    return root, "".join(said).replace(root, "<store>").replace(store.SCRIPTS, "<scripts>")


def test_files_and_modes(ran):
    root, _ = ran
    assert tree(root) == tree(os.path.join(GOLDEN, "edge"))
    assert modes(root) == read(os.path.join(GOLDEN, "edge.modes"))


def test_what_it_says(ran):
    _, said = ran
    assert said == read(os.path.join(GOLDEN, "edge.out"))
