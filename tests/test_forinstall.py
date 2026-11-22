"""forinstall: what install.sh asks of wgtun (it prints install.sh's ok/changed lines)."""

from __future__ import annotations

import os
import stat

import pytest

from wgtun import forinstall


def run(capsys, *args: str) -> str:
    assert forinstall.main(list(args)) == 0
    return capsys.readouterr().out


def test_warp_endpoint(tmp_store, capsys):
    dev = tmp_store.path(tmp_store.device("mac"))
    assert run(capsys, "warp-endpoint", dev) == "162.159.192.1:2408\n"
    tmp_store.put("devices/mac/.warp-endpoint", "engage.cloudflareclient.com:2408")
    with pytest.raises(SystemExit):
        forinstall.main(["warp-endpoint", dev])
    err = capsys.readouterr().err
    assert err.startswith("install.sh: ") and "IPv4:port" in err


def test_folders(tmp_store, capsys):
    new = tmp_store.path("devices/mac/exports")
    devices = tmp_store.path("devices")         # the fixture made it 0700
    assert run(capsys, "folders", devices, new) == f"  ok       {devices}\n  changed  {new}\n"
    assert stat.S_IMODE(os.stat(new).st_mode) == 0o700
    assert run(capsys, "folders", new) == f"  ok       {new}\n"


def test_warp_account(tmp_store, capsys, fake_wgcf):
    dev = tmp_store.path("devices/mac")
    out = run(capsys, "warp-account", dev)
    assert out.split("\n")[:2] == ["  changed  account registered", "  changed  profile generated"]
    assert f"  changed  {dev}/warp/wgcf-account.toml 0600" in out        # wgcf wrote it 644
    assert run(capsys, "warp-account", dev) == "  ok       account\n  ok       profile\n"


def test_daemon_warp(tmp_store, capsys, fake_wgcf, tmp_path):
    dev = tmp_store.path("devices/mac")
    run(capsys, "warp-account", dev)
    dest = str(tmp_path / "etc" / "wireguard" / "warp.conf")
    assert run(capsys, "daemon-warp", dev, dest) == f"  changed  {dest} (tunnel.sh import to pass it to the daemon)\n"
    with open(dest, encoding="utf-8") as f:
        text = f.read()
    assert "Table = off\n" in text and "MTU = 1280\n" in text and "PersistentKeepalive = 25\n" in text
    assert "Endpoint = 162.159.192.1:2408\n" in text and "Address = 172.16.0.2/32, 2606:4700::2/128\n" in text
    assert stat.S_IMODE(os.stat(dest).st_mode) == 0o600
    assert run(capsys, "daemon-warp", dev, dest) == f"  ok       {dest}\n"


def test_daemon_warp_refuses_what_the_sweep_would_skip(tmp_store, capsys, tmp_path):
    tmp_store.put("devices/mac/warp/wgcf-profile.conf", "[Interface]\nPrivateKey = x\n")
    with pytest.raises(SystemExit):
        forinstall.main(["daemon-warp", tmp_store.path("devices/mac"), str(tmp_path / "w.conf")])
    assert "wgcf-profile.conf: 0 [Peer] sections, needs one" in capsys.readouterr().err


@pytest.mark.parametrize("args", [[], ["nope", "x"], ["warp-endpoint"], ["daemon-warp", "a"], ["folders"]])
def test_usage(args, capsys):
    with pytest.raises(SystemExit):
        forinstall.main(args)
    assert capsys.readouterr().err.startswith("install.sh: usage: python3 -m wgtun.forinstall ")


def test_warp_account_left_from_an_earlier_one(tmp_store, capsys, fake_wgcf):
    """A profile with no account (the account was removed): registering again
    replaces it, so the profile is the new account's."""
    tmp_store.put("devices/mac/warp/wgcf-profile.conf", "old\n")
    run(capsys, "warp-account", tmp_store.path("devices/mac"))
    assert tmp_store.read("devices/mac/warp/wgcf-profile.conf").startswith("[Interface]")
