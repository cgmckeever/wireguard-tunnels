"""singbox.sh build: profiles made from config/ as the sweep leaves it."""

from __future__ import annotations

import json
import os

import pytest

from wgtun import singbox, sweep
from wgtun.conf import Conf
from wgtun.store import Error

from .conftest import client, fake_command


def build(tmp_store, device: str):
    """(profiles by file name, parsed; what build said)"""
    said = []
    swept = sweep.Sweep(tmp_store.path(f"devices/{device}"), app_column=False)
    files = singbox.plan(singbox.Device(device, "build"), swept, lambda text, err: said.append(text))
    return {f: json.loads(t) for f, t in files.items()}, said


@pytest.fixture
def phone(tmp_store):
    tmp_store.device("ph")
    tmp_store.put("devices/ph/carriers/proton.chi.conf",
                  client("proton", mtu=1280, head="# device-network: 10.9.8.0/24"))
    tmp_store.put("devices/ph/config/dengar.chi.ph.conf", client("dengar.chi", keepalive=30, psk=True))
    tmp_store.put("devices/ph/config/dengar.ph.conf", client("dengar"))
    return tmp_store


def picks(profile: dict) -> list:
    return profile["outbounds"][0]["outbounds"]


def keepalives(profile: dict) -> dict:
    return {ep["tag"]: ep["peers"][0].get(singbox.KEEPALIVE_KEY) for ep in profile["endpoints"]}


def test_files(phone):
    files, _ = build(phone, "ph")
    assert sorted(files) == sorted([
        "warped.proton.chi.ph.json", "dengar.chi.ph.json", "dengar.ph.json", "warp.ph.json",
        "ph.json", "warped.list.ph.json", "dengar.list.ph.json"])


def test_singles_keep_their_configs_keepalives_groups_have_none(phone):
    """The rule: a tunnel's keepalive is its config/ file's in every one-tunnel
    profile (the sweep gives warped and WARP 25); a group runs every tunnel at
    once, so it has none."""
    files, _ = build(phone, "ph")
    assert keepalives(files["dengar.chi.ph.json"]) == {"dengar.chi.ph": 30}
    assert keepalives(files["dengar.ph.json"]) == {"dengar.ph": 25}
    assert keepalives(files["warp.ph.json"]) == {"warp.ph": 25}
    assert keepalives(files["warped.proton.chi.ph.json"]) == {"carrier.proton.chi.ph": 25, "warped.proton.chi.ph": 25}
    for f in ("ph.json", "warped.list.ph.json", "dengar.list.ph.json"):
        assert set(keepalives(files[f]).values()) == {None}, f


def test_a_config_without_a_keepalive_has_none_in_its_profile(phone):
    phone.put("devices/ph/config/home.ph.conf", client("home", keepalive=None))
    files, _ = build(phone, "ph")
    assert keepalives(files["home.ph.json"]) == {"home.ph": None}


def test_warped_rides_its_carrier(phone):
    files, _ = build(phone, "ph")
    carrier, warp = files["warped.proton.chi.ph.json"]["endpoints"]
    assert (carrier["tag"], warp["tag"]) == ("carrier.proton.chi.ph", "warped.proton.chi.ph")
    assert warp["detour"] == carrier["tag"]
    assert warp["mtu"] == 1200                          # carrier 1280 - 80
    assert files["warped.proton.chi.ph.json"]["route"]["rules"][-1] == {"ip_cidr": ["10.9.8.0/24"],
                                                                       "outbound": "carrier.proton.chi.ph"}


def test_composite_warped_first_warp_last_smallest_mtu(phone):
    files, _ = build(phone, "ph")
    assert picks(files["ph.json"]) == ["warped.proton.chi.ph", "dengar.chi.ph", "dengar.ph", "warp.ph"]
    assert files["ph.json"]["outbounds"][0]["default"] == "warped.proton.chi.ph"
    assert files["ph.json"]["inbounds"][0]["mtu"] == 1200
    assert picks(files["warped.list.ph.json"]) == ["warped.proton.chi.ph", "warp.ph"]


def test_a_network_two_carriers_claim_goes_to_the_first(phone):
    phone.put("devices/ph/carriers/proton.nyc.conf", client("nyc", head="# device-network: 10.9.8.0/24"))
    files, said = build(phone, "ph")
    rules = [r for r in files["ph.json"]["route"]["rules"] if "ip_cidr" in r]
    assert rules == [{"ip_cidr": ["10.9.8.0/24"], "outbound": "carrier.proton.chi.ph"}]
    assert any("10.9.8.0/24 is in two carriers" in s for s in said)


def test_warnings_split_and_no_keepalive(phone):
    phone.put("devices/ph/config/home.ph.conf", client("home", allowed="192.168.1.0/24", keepalive=None))
    _, said = build(phone, "ph")
    assert any("home.ph is a split tunnel" in s for s in said)
    assert any("home.ph has no PersistentKeepalive" in s for s in said)


def test_a_key_on_two_devices_stops_it(phone):
    phone.device("tv", carriers=False, warp=False)
    phone.put("devices/tv/config/dengar.tv.conf", client("dengar"))
    with pytest.raises(Error, match="same private key in:\n  ph/config/dengar.ph.conf and tv/config/dengar.tv.conf"):
        build(phone, "ph")


def test_nord_configs_share_their_key(phone):
    phone.device("tv", carriers=False, warp=False)
    phone.put("devices/tv/config/nord.tv.conf", "# source: nord us\n" + client("nord"))
    phone.put("devices/ph/config/nord.ph.conf", "# source: nord us\n" + client("nord"))
    phone.put("devices/ph/config/nord2.ph.conf", "# source: nord us\n" + client("nord"))
    _, said = build(phone, "ph")
    assert not any("same private key" in s for s in said)


def test_a_key_twice_on_one_device_is_a_note(phone):
    phone.put("devices/ph/config/proton.chi.ph.conf", client("proton"))
    _, said = build(phone, "ph")
    assert any(s.startswith("note: same private key in") for s in said)


@pytest.mark.parametrize("name,why", [("ph", "is the composite"), ("x.list.ph", "is a group profile")])
def test_names_profiles_take(phone, name, why):
    phone.put(f"devices/ph/config/{name}.conf", client(name))
    with pytest.raises(Error, match=why):
        build(phone, "ph")


def test_an_orphan_isnt_built(phone):
    phone.put("devices/ph/config/warped.gone.ph.conf", client("gone"))
    files, said = build(phone, "ph")
    assert "warped.gone.ph.json" not in files
    assert "skipped warped.gone.ph: no usable carrier for it in carriers/ (delete it if that's for good)" in said


def test_plain_device_and_nothing_to_build(tmp_store):
    tmp_store.device("tv", carriers=False, warp=False)
    with pytest.raises(Error, match="nothing to build"):
        build(tmp_store, "tv")
    tmp_store.put("devices/tv/config/srv.tv.conf", client("srv"))
    assert sorted(build(tmp_store, "tv")[0]) == ["srv.tv.json", "tv.json"]


def profile_states(out: str) -> dict:
    """build's "<file> <state>" lines."""
    return {ln.split()[0]: " ".join(ln.split()[1:]) for ln in out.split("\n") if ln.split()[:1]
            and ln.split()[0].endswith(".json")}


def test_cmd_build_writes_and_removes(phone, capsys):
    phone.put("devices/ph/sing-box/old.json", "{}\n")
    singbox.cmd_build("ph")
    states = profile_states(capsys.readouterr().out)
    assert states["old.json"] == "removed (no longer built)"
    assert states["ph.json"] == "new"
    singbox.cmd_build("ph")
    assert set(profile_states(capsys.readouterr().out).values()) == {"unchanged"}


def test_warp_without_its_profile_isnt_built(phone):
    """A config/warp.<device>.conf left after warp/ is gone is an orphan, not WARP."""
    singbox.cmd_build("ph")
    os.remove(phone.path("devices/ph/warp/wgcf-profile.conf"))
    files, said = build(phone, "ph")
    assert "warp.ph.json" not in files
    assert "skipped warped.proton.chi.ph: no WARP profile" in said


def test_a_broken_warp_profile_isnt_built(phone, capsys):
    phone.put("devices/ph/warp/wgcf-profile.conf", "[Interface]\nPrivateKey = x\n")
    files, said = build(phone, "ph")
    assert "warp.ph.json" not in files
    assert "skipped warped.proton.chi.ph: no WARP profile" in said
    with pytest.raises(Error, match=r"WARP profile .*wgcf-profile.conf: 0 \[Peer\] sections, needs one"):
        singbox.cmd_build("ph")


def test_cli(tmp_store, capsys):
    assert singbox.main(["--help"]) == 0
    assert "singbox.sh build <device>" in capsys.readouterr().out
    for args in (["nope"], ["list", "x"], ["build", "a", "b"]):
        assert singbox.main(args) == 1
        assert "usage: singbox.sh" in capsys.readouterr().err
    assert singbox.main([]) == 1
    assert singbox.main(["build", "bad name"]) == 1
    assert "device names are letters, digits, . _ - (not starting with .): bad name" in capsys.readouterr().err


def test_list(phone, capsys):
    phone.put("devices/.default", "ph\n")
    singbox.cmd_list()
    assert capsys.readouterr().out.split("\n")[1].split() == ["ph", "(this", "Mac)", "1", "2", "yes", "0"]


def test_a_name_two_endpoints_would_share(phone):
    phone.put("devices/ph/config/tunnel.conf", client("t"))          # "tunnel" is the picker's
    with pytest.raises(Error, match="more than one tunnel would be named: tunnel "):
        build(phone, "ph")


def test_sing_box_check_failing_changes_nothing(phone, tmp_path, monkeypatch):
    fake_command(tmp_path, monkeypatch, "sing-box",
                 'grep -q warped "$3" && { echo "bad profile" >&2; exit 1; }; exit 0')
    with pytest.raises(Error, match=r"sing-box check failed for warped\.proton\.chi\.ph\.json: no profile changed"):
        singbox.cmd_build("ph")
    assert not os.path.exists(phone.path("devices/ph/sing-box/ph.json"))


def test_new(tmp_store, fake_wgcf, capsys):
    singbox.cmd_new("tv")
    out = capsys.readouterr().out
    assert out.startswith("WARP account: registered\nWireGuard app config: ")
    assert os.path.isfile(tmp_store.path("devices/tv/config/warp.tv.conf"))
    singbox.cmd_new("tv")
    assert capsys.readouterr().out.startswith("WARP account: already there\n")


def test_a_name_the_composite_has_case_aside(phone):
    """The Mac's file system ignores case: PH.json would be ph.json."""
    phone.put("devices/ph/config/PH.conf", client("upper"))
    with pytest.raises(Error, match="is the composite"):
        build(phone, "ph")


def test_new_claims_only_what_it_wrote(tmp_store, fake_wgcf, capsys):
    tmp_store.device("tv", carriers=True, warp=False)
    tmp_store.put("devices/tv/warp/wgcf-account.toml", "t")
    tmp_store.put("devices/tv/warp/wgcf-profile.conf", "[Interface]\nPrivateKey = x\n")      # broken
    singbox.cmd_new("tv")
    assert "WireGuard app config" not in capsys.readouterr().out


def test_a_tunnel_renamed_by_case_keeps_its_profile(phone, capsys):
    """APFS: writing dengar.ph.json over Dengar.ph.json keeps the old name."""
    os.rename(phone.path("devices/ph/config/dengar.ph.conf"), phone.path("devices/ph/config/Dengar.ph.conf"))
    singbox.cmd_build("ph")
    os.rename(phone.path("devices/ph/config/Dengar.ph.conf"), phone.path("devices/ph/config/dengar.ph.conf"))
    singbox.cmd_build("ph")
    assert "dengar.ph.json" in os.listdir(phone.path("devices/ph/sing-box"))
    assert "Dengar.ph.json" not in os.listdir(phone.path("devices/ph/sing-box"))


def test_a_bare_allowed_ip_gets_its_prefix():
    """wg reads a bare address as one host; sing-box's peer allowed_ips needs the prefix."""
    c = Conf(client("bare", allowed="10.0.0.5, fd00::5, 10.9.8.0/24"), "x/config/bare.conf")
    assert singbox.endpoint(c, "t", 1420)["peers"][0]["allowed_ips"] == ["10.0.0.5/32", "fd00::5/128", "10.9.8.0/24"]
