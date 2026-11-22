"""The sweep: carriers/ into config/warped.*, warp/ into config/warp.<device>."""

from __future__ import annotations

import os
import stat

import pytest

from wgtun import sweep
from wgtun.conf import Conf
from wgtun.store import Error

from .conftest import client


def run(tmp_store, device: str) -> sweep.Sweep:
    s = sweep.Sweep(tmp_store.path(f"devices/{device}"), app_column=False)
    s.write()
    return s


def test_warped_carries_warp_and_its_extras_only(tmp_store):
    tmp_store.device("ph")
    tmp_store.put("devices/ph/carriers/srv.conf", client(
        "srv", keepalive=15, head="# device-network: 10.9.8.0/24\n# tunnel-routes: 192.168.5.0/24, 10.0.0.0/4 # wide"))
    run(tmp_store, "ph")
    out = Conf(tmp_store.read("devices/ph/config/warped.srv.ph.conf"))
    assert out.items("AllowedIPs") == ["162.159.192.1/32", "10.9.8.0/24", "192.168.5.0/24"]
    assert out.values("DNS") == []
    assert out.values("PersistentKeepalive") == ["25"]          # the sweep's, not the carrier's 15


def test_carrier_without_allowed_ips_gets_one(tmp_store):
    tmp_store.device("ph")
    tmp_store.put("devices/ph/carriers/srv.conf", client("srv", allowed=None, keepalive=None))
    run(tmp_store, "ph")
    out = tmp_store.read("devices/ph/config/warped.srv.ph.conf")
    assert "Endpoint = vpn.example.net:51820\nAllowedIPs = 162.159.192.1/32\nPersistentKeepalive = 25\n" in out


@pytest.mark.parametrize("entry,verdict", [
    ("10.9.8.0/24", "kept"), ("10.0.0.5", "kept"), ("fd00:1::/48", "kept"),
    ("10.0.0.0/4", "wide"), ("fd00::/8", "wide"),
    ("300.1.1.1", "bad"), ("vpn.example.net", "bad"), ("10.0.0.0/33", "bad"),
    (":", "bad"), ("::::", "bad"), ("1:2:3:4:5:6:7:8:9:a:b", "bad"),
    ("10.0.0.0/8", "kept"), ("10.0.0.0/7", "wide"), ("fd00::/16", "kept"), ("fc00::/15", "wide"),
])
def test_extras_verdict(entry, verdict):
    assert sweep.verdict(entry) == verdict


def test_warp_alone_on_the_device_endpoint_with_a_keepalive(tmp_store):
    tmp_store.device("ph")
    tmp_store.put("devices/ph/.warp-endpoint", "162.159.192.5:2408\n")
    run(tmp_store, "ph")
    out = Conf(tmp_store.read("devices/ph/config/warp.ph.conf"))
    assert out.value("Endpoint") == "162.159.192.5:2408"
    assert out.keepalive() == 25


def test_written_private_and_only_when_changed(tmp_store):
    tmp_store.device("ph")
    tmp_store.put("devices/ph/carriers/srv.conf", client("srv"))
    first = run(tmp_store, "ph")
    assert {r.state for r in first.written()} == {"new"}
    path = tmp_store.path("devices/ph/config/warped.srv.ph.conf")
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    assert {r.state for r in run(tmp_store, "ph").written()} == {"unchanged"}


def test_a_carrier_from_wireguard_tools_sweeps_again(tmp_store):
    """Its "# wireguard-tools client:" line is copied into the warped config;
    that mustn't make the next sweep take its own output for someone else's."""
    tmp_store.device("mac")
    carrier = tmp_store.put("devices/mac/carriers/dengar.chi-us.mac.conf",
                        client("d", head="# wireguard-tools client: chi-us.mac on dengar"))
    run(tmp_store, "mac")
    with open(carrier, "a") as f:
        f.write("# tunnel-routes: 10.1.0.0/16\n")
    assert {r.state for r in run(tmp_store, "mac").written() if r.name.startswith("warped.")} == {"updated"}


def test_rows_skipped_manual_orphan(tmp_store):
    tmp_store.device("ph")
    tmp_store.put("devices/ph/carriers/broken.conf", client("b") + "[Peer]\nPublicKey = x\n")
    tmp_store.put("devices/ph/carriers/q.conf", client("q"))
    tmp_store.put("devices/ph/carriers/warped.q.conf", client("q2"))
    tmp_store.put("devices/ph/config/srv.ph.conf", client("plain"))
    tmp_store.put("devices/ph/config/warped.gone.ph.conf", client("gone"))
    rows = {(r.name, r.state, r.detail) for r in run(tmp_store, "ph").rows}
    assert ("warped.broken.ph", "skipped", "broken.conf: 2 [Peer] sections, needs one") in rows
    assert ("warped.q.ph", "skipped", "warped.q.conf: another carrier already makes warped.q.ph") in rows
    assert ("srv.ph", "manual", "") in rows
    assert ("warped.gone.ph", "orphan", "") in rows
    assert not os.path.exists(tmp_store.path("devices/ph/config/warped.broken.ph.conf"))


def test_configs_as_the_sweep_leaves_them_without_writing(tmp_store):
    tmp_store.device("ph")
    tmp_store.put("devices/ph/carriers/srv.conf", client("srv"))
    tmp_store.put("devices/ph/config/srv.ph.conf", client("plain"))
    planned = sweep.Sweep(tmp_store.path("devices/ph"), app_column=False)
    assert [c.name for c in planned.configs()] == ["srv.ph", "warp.ph", "warped.srv.ph"]
    assert not os.path.exists(tmp_store.path("devices/ph/config/warp.ph.conf"))


def test_only_a_device_folder_without_carriers(tmp_store, tmp_path):
    (tmp_path / "elsewhere").mkdir()
    with pytest.raises(Error, match="no carriers/"):
        sweep.Sweep(str(tmp_path / "elsewhere"))
    tmp_store.device("plain", carriers=False, warp=False)
    assert sweep.Sweep(tmp_store.path("devices/plain")).no_carriers


def test_resolve(tmp_store):
    tmp_store.device("ph")
    assert sweep.resolve("ph") == tmp_store.path("devices/ph")
    with pytest.raises(Error, match="no default device"):
        sweep.resolve("")
    tmp_store.put("devices/.default", "ph\n")
    assert sweep.resolve("") == tmp_store.path("devices/ph")
    with pytest.raises(Error, match="no folder"):
        sweep.resolve("/nonexistent")


def test_a_broken_warp_profile_is_skipped(tmp_store):
    tmp_store.device("ph")
    tmp_store.put("devices/ph/warp/wgcf-profile.conf", "[Interface]\nPrivateKey = x\n[Peer]\nPublicKey = y\n")
    rows = {r.name: r for r in run(tmp_store, "ph").rows}
    assert (rows["warp.ph"].state, rows["warp.ph"].detail) == ("skipped", "warp/wgcf-profile.conf: no Address")
    assert not os.path.exists(tmp_store.path("devices/ph/config/warp.ph.conf"))


def test_small_carrier_mtu_note(tmp_store):
    tmp_store.device("ph")
    tmp_store.put("devices/ph/carriers/srv.conf", client("srv", mtu=1300))
    rows = {r.name: r for r in run(tmp_store, "ph").rows}
    assert rows["warped.srv.ph"].notes == ["carrier MTU 1300: WARP runs at 1220 inside (IPv6 and QUIC fall back)"]
    assert rows["warp.ph"].notes == []


def test_cli(tmp_store, capsys):
    assert sweep.main(["-h"]) == 0
    assert capsys.readouterr().out.startswith("wgwarp-sweep.sh — ")
    for args in (["-x"], ["a", "b"]):
        assert sweep.main(args) == 1
        assert "usage: wgwarp-sweep.sh" in capsys.readouterr().err
    tmp_store.device("ph")
    path = tmp_store.put("devices/ph/carriers/srv.conf", b"\xff\xfe")
    assert sweep.main(["ph"]) == 1
    assert capsys.readouterr().err == f"wgwarp-sweep.sh: {path}: not UTF-8 text\n"     # a line, not a traceback


def test_warp_alone_without_a_profile_is_an_orphan(tmp_store, capsys):
    tmp_store.device("ph")
    run(tmp_store, "ph")
    os.remove(tmp_store.path("devices/ph/warp/wgcf-profile.conf"))
    s = sweep.Sweep(tmp_store.path("devices/ph"), app_column=False)
    s.report()
    assert "warp.ph                                  orphan     (no warp/wgcf-profile.conf: left in place)" \
        in capsys.readouterr().out
    assert s.written() == []


def test_a_non_utf8_config_is_replaced(tmp_store, capsys):
    """Not only carriers: the sweep compares what it writes with config/'s copy."""
    tmp_store.device("ph")
    tmp_store.put("devices/ph/carriers/srv.conf", client("srv"))
    tmp_store.put("devices/ph/config/warped.srv.ph.conf", b"\xff")
    run(tmp_store, "ph")
    assert tmp_store.read("devices/ph/config/warped.srv.ph.conf").startswith("[Interface]")   # replaced, no traceback


@pytest.mark.parametrize("remote,state,says", [
    ("", "new", "not there: add it in the app"),
    ("vpn.example.net:51820", "new",
     "there, same server: if the app's copy isn't this config, remove it and add again"),
    ("203.0.113.9:51820", "unchanged", "there, same server"),            # the hostname's address
    ("198.51.100.1:51820", "unchanged",
     "there, other server (198.51.100.1:51820): remove it and add again in the app"),
    ("vpn.example.net:51820", "updated", "there, but changed: remove it and add again in the app"),
])
def test_app_action(tmp_store, monkeypatch, remote, state, says):
    """What the table says about the WireGuard app's copy (scutil and dscacheutil faked)."""
    def command(argv):
        if argv[:3] == ["scutil", "--nc", "status"]:
            return "Connected\n" if remote else ""
        if argv[:3] == ["scutil", "--nc", "show"]:
            return f"  RemoteAddress : {remote}\n"
        return "name: vpn.example.net\nip_address: 203.0.113.9\n"
    monkeypatch.setattr(sweep, "command", command)
    tmp_store.device("mac")
    tmp_store.put("devices/.default", "mac\n")
    tmp_store.put("devices/mac/carriers/srv.conf", client("srv"))
    s = sweep.Sweep(tmp_store.path("devices/mac"))
    row = next(r for r in s.rows if r.name == "warped.srv.mac")
    row.state = state
    assert s.app_action(row) == says


def test_written_as_utf8_whatever_the_locale(tmp_store, monkeypatch):
    """A carrier with a non-ASCII comment settles (unchanged on the next sweep) in a Latin-1 locale too."""
    monkeypatch.setenv("LC_ALL", "en_US.ISO8859-1")
    tmp_store.device("ph")
    tmp_store.put("devices/ph/carriers/srv.conf", "# café\n" + client("srv"))
    run(tmp_store, "ph")
    assert {r.state for r in run(tmp_store, "ph").written()} == {"unchanged"}
    assert tmp_store.read("devices/ph/config/warped.srv.ph.conf").startswith("# café\n")


def test_a_carrier_renamed_by_case(tmp_store):
    """The old warped file is the new one (APFS), not an orphan to delete."""
    tmp_store.device("ph")
    tmp_store.put("devices/ph/carriers/Srv.conf", client("srv"))
    run(tmp_store, "ph")
    os.rename(tmp_store.path("devices/ph/carriers/Srv.conf"), tmp_store.path("devices/ph/carriers/srv.conf"))
    s = run(tmp_store, "ph")
    assert not [r for r in s.rows if r.state == "orphan"]
    assert [c.name for c in s.configs() if c.name.lower() == "warped.srv.ph"] == ["warped.srv.ph"]
    assert "warped.srv.ph.conf" in os.listdir(tmp_store.path("devices/ph/config"))
