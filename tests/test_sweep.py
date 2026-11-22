"""The sweep: carriers/ into config/warped.*, warp/ into config/warp.<device>."""

from __future__ import annotations

import os
import stat

import pytest

from wgtun import sweep
from wgtun.conf import Conf
from wgtun.store import Error

from .conftest import client


def run(store, device: str) -> sweep.Sweep:
    s = sweep.Sweep(store.path(f"devices/{device}"), app_column=False)
    with open(os.devnull, "w") as quiet:
        s.run(out=quiet)
    return s


def test_warped_carries_warp_and_its_extras_only(store):
    store.device("ph")
    store.put("devices/ph/carriers/srv.conf", client(
        "srv", keepalive=15, head="# device-network: 10.9.8.0/24\n# tunnel-routes: 192.168.5.0/24, 10.0.0.0/4 # wide"))
    run(store, "ph")
    out = Conf(store.read("devices/ph/config/warped.srv.ph.conf"))
    assert out.items("AllowedIPs") == ["162.159.192.1/32", "10.9.8.0/24", "192.168.5.0/24"]
    assert out.values("DNS") == []
    assert out.values("PersistentKeepalive") == ["25"]          # the sweep's, not the carrier's 15


def test_carrier_without_allowed_ips_gets_one(store):
    store.device("ph")
    store.put("devices/ph/carriers/srv.conf", client("srv", allowed=None, keepalive=None))
    run(store, "ph")
    out = store.read("devices/ph/config/warped.srv.ph.conf")
    assert "Endpoint = vpn.example.net:51820\nAllowedIPs = 162.159.192.1/32\nPersistentKeepalive = 25\n" in out


@pytest.mark.parametrize("entry,verdict", [
    ("10.9.8.0/24", "kept"), ("10.0.0.5", "kept"), ("fd00:1::/48", "kept"),
    ("10.0.0.0/4", "wide"), ("fd00::/8", "wide"),
    ("300.1.1.1", "bad"), ("vpn.example.net", "bad"), ("10.0.0.0/33", "bad"),
])
def test_extras_verdict(entry, verdict):
    assert sweep.verdict(entry) == verdict


def test_warp_alone_on_the_device_endpoint_with_a_keepalive(store):
    store.device("ph")
    store.put("devices/ph/.warp-endpoint", "162.159.192.5:2408\n")
    run(store, "ph")
    out = Conf(store.read("devices/ph/config/warp.ph.conf"))
    assert out.value("Endpoint") == "162.159.192.5:2408"
    assert out.keepalive() == 25


def test_written_private_and_only_when_changed(store):
    store.device("ph")
    store.put("devices/ph/carriers/srv.conf", client("srv"))
    first = run(store, "ph")
    assert {r.state for r in first.written()} == {"new"}
    path = store.path("devices/ph/config/warped.srv.ph.conf")
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    assert {r.state for r in run(store, "ph").written()} == {"unchanged"}


def test_a_carrier_from_wireguard_tools_sweeps_again(store):
    """Its "# wireguard-tools client:" line is copied into the warped config;
    that mustn't make the next sweep take its own output for someone else's."""
    store.device("mac")
    carrier = store.put("devices/mac/carriers/dengar.chi-us.mac.conf",
                        client("d", head="# wireguard-tools client: chi-us.mac on dengar"))
    run(store, "mac")
    with open(carrier, "a") as f:
        f.write("# tunnel-routes: 10.1.0.0/16\n")
    assert {r.state for r in run(store, "mac").written() if r.name.startswith("warped.")} == {"updated"}


def test_rows_skipped_manual_orphan(store):
    store.device("ph")
    store.put("devices/ph/carriers/broken.conf", client("b") + "[Peer]\nPublicKey = x\n")
    store.put("devices/ph/carriers/q.conf", client("q"))
    store.put("devices/ph/carriers/warped.q.conf", client("q2"))
    store.put("devices/ph/config/srv.ph.conf", client("plain"))
    store.put("devices/ph/config/warped.gone.ph.conf", client("gone"))
    rows = {(r.name, r.state, r.detail) for r in run(store, "ph").rows}
    assert ("warped.broken.ph", "skipped", "broken.conf: 2 [Peer] sections, needs one") in rows
    assert ("warped.q.ph", "skipped", "warped.q.conf: another carrier already makes warped.q.ph") in rows
    assert ("srv.ph", "manual", "") in rows
    assert ("warped.gone.ph", "orphan", "") in rows
    assert not os.path.exists(store.path("devices/ph/config/warped.broken.ph.conf"))


def test_configs_as_the_sweep_leaves_them_without_writing(store):
    store.device("ph")
    store.put("devices/ph/carriers/srv.conf", client("srv"))
    store.put("devices/ph/config/srv.ph.conf", client("plain"))
    planned = sweep.Sweep(store.path("devices/ph"), app_column=False)
    assert [c.name for c in planned.configs()] == ["srv.ph", "warp.ph", "warped.srv.ph"]
    assert not os.path.exists(store.path("devices/ph/config/warp.ph.conf"))


def test_only_a_device_folder_without_carriers(store, tmp_path):
    (tmp_path / "elsewhere").mkdir()
    with pytest.raises(Error, match="no carriers/"):
        sweep.Sweep(str(tmp_path / "elsewhere"))
    store.device("plain", carriers=False, warp=False)
    assert sweep.Sweep(store.path("devices/plain")).no_carriers


def test_resolve(store):
    store.device("ph")
    assert sweep.resolve("ph") == store.path("devices/ph")
    with pytest.raises(Error, match="no default device"):
        sweep.resolve("")
    store.put("devices/.default", "ph\n")
    assert sweep.resolve("") == store.path("devices/ph")
    with pytest.raises(Error, match="no folder"):
        sweep.resolve("/nonexistent")


def test_a_broken_warp_profile_is_skipped(store):
    store.device("ph")
    store.put("devices/ph/warp/wgcf-profile.conf", "[Interface]\nPrivateKey = x\n[Peer]\nPublicKey = y\n")
    rows = {r.name: r for r in run(store, "ph").rows}
    assert (rows["warp.ph"].state, rows["warp.ph"].detail) == ("skipped", "warp/wgcf-profile.conf: no Address")
    assert not os.path.exists(store.path("devices/ph/config/warp.ph.conf"))


def test_small_carrier_mtu_note(store):
    store.device("ph")
    store.put("devices/ph/carriers/srv.conf", client("srv", mtu=1300))
    rows = {r.name: r for r in run(store, "ph").rows}
    assert rows["warped.srv.ph"].notes == ["carrier MTU 1300: WARP runs at 1220 inside (IPv6 and QUIC fall back)"]
    assert rows["warp.ph"].notes == []


def test_cli(store, capsys):
    assert sweep.main(["-h"]) == 0
    assert capsys.readouterr().out.startswith("wgwarp-sweep.sh — ")
    for args in (["-x"], ["a", "b"]):
        with pytest.raises(SystemExit):
            sweep.main(args)
        assert "usage: wgwarp-sweep.sh" in capsys.readouterr().err
    store.device("ph")
    store.put("devices/ph/carriers/srv.conf", "\xff not utf-8")
    os.chmod(store.path("devices/ph/carriers"), 0o700)
    with open(store.path("devices/ph/carriers/srv.conf"), "wb") as f:
        f.write(b"\xff\xfe")
    with pytest.raises(SystemExit):
        sweep.main(["ph"])
    assert capsys.readouterr().err.startswith("wgwarp-sweep.sh: ")     # a line, not a traceback
