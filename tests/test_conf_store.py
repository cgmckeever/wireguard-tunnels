"""Reading configs (conf.py) and the store's names and rules (store.py)."""

from __future__ import annotations

import os

import pytest

from wgtun import store
from wgtun.conf import Conf
from wgtun.store import Error

from .conftest import client


def test_values_as_wg_quick_reads_them():
    c = Conf("[Interface]\r\nprivatekey = abc=\r\n  Address=10.0.0.1/32 , fd00::1/128\r\nAddress = 10.0.0.9/32\r\n")
    assert c.value("PrivateKey") == "abc="        # any case, the "=" padding kept, CR gone
    assert c.items("Address") == ["10.0.0.1/32", "fd00::1/128", "10.0.0.9/32"]


def test_keepalive_mtu_endpoint():
    c = Conf(client("a", endpoint="[2001:db8::1]:51820", keepalive=30, mtu=1300))
    assert (c.keepalive(), c.mtu(1420), c.endpoint()) == (30, 1300, ("2001:db8::1", 51820))
    assert Conf(client("a", keepalive=None)).keepalive() == 0
    assert Conf(client("a")).mtu(1420) == 1420


@pytest.mark.parametrize("text,why", [
    ("[Peer]\nPublicKey = x\n", "no [Interface]"),
    (client("a") + "[Peer]\nPublicKey = y\n", "2 [Peer] sections, needs one"),
    (client("a").replace("PublicKey", "#"), "no PublicKey"),
    (client("a").replace("51820", "port"), "Endpoint isn't host:port"),
    (client("a", mtu=1280).replace("1280", "big"), "MTU isn't a number from 576 to 65535"),
    (client("a", mtu=1280).replace("1280", "0"), "MTU isn't a number from 576 to 65535"),
    (client("a").replace("51820", "99999999"), "Endpoint isn't host:port"),
    (client("a").replace("51820", "0"), "Endpoint isn't host:port"),
    (client("a"), ""),
])
def test_problem(text, why):
    assert Conf(text).problem() == why


def test_rewrite_keeps_other_lines():
    c = Conf("# note\r\n[Peer]\r\nEndpoint = a:1\r\nDNS = 1.1.1.1\r\n")
    assert c.rewrite({"DNS": lambda _l: [], "Endpoint": lambda line: [line, "X = 1"]}) == \
        "# note\n[Peer]\nEndpoint = a:1\nX = 1\n"


@pytest.mark.parametrize("carrier,name", [
    ("x.conf", "warped.x.iphone"),
    ("warped.x.conf", "warped.x.iphone"),
    ("warped-x.conf", "warped.x.iphone"),
    ("x_iphone-y.conf", "warped.x-y.iphone"),
    ("iphone-x.conf", "warped.x.iphone"),
    ("x.iphone.conf", "warped.x.iphone"),
    ("xiphone.conf", "warped.xiphone.iphone"),      # only as a word of its own
])
def test_warped_name(carrier, name):
    assert store.warped_name(carrier, "iphone") == name


def test_warped_name_device_is_literal():
    assert store.warped_name("xaby.conf", "a.b") == "warped.xaby.a.b"   # "." in a device isn't "any character"


@pytest.fixture
def store_root(tmp_store):
    return tmp_store, tmp_store.path(tmp_store.device("d"))


def test_warp_endpoint_device_then_store_then_cloudflare(store_root):
    s, dev = store_root
    assert store.warp_endpoint(dev) == store.WARP_ENDPOINT
    s.put(".warp-endpoint", "162.159.192.5:2408\n")
    assert store.warp_endpoint(dev) == "162.159.192.5:2408"
    s.put("devices/d/.warp-endpoint", " 162.159.192.9:500 \n")
    assert store.warp_endpoint(dev) == "162.159.192.9:500"
    for bad in ("engage.cloudflareclient.com:2408", "999.1.1.1:2408", "162.159.192.1:99999", "162.159.192.1:0"):
        s.put("devices/d/.warp-endpoint", bad)
        with pytest.raises(Error, match="IPv4:port"):
            store.warp_endpoint(dev)


def test_sweep_owned_by_name():
    assert store.sweep_owned("warped.x.iphone", "iphone")
    assert store.sweep_owned("warp.iphone", "iphone")
    assert not store.sweep_owned("warp.mbp-1", "iphone")
    assert not store.sweep_owned("dengar.warp.iphone", "iphone")
    # In any case: the Mac's file system ignores it (wireguard-tools refuses these too)
    assert store.sweep_owned("Warped.x.iphone", "iphone") and store.sweep_owned("WARP.iPhone", "iphone")
    assert store.warped_name("Warped.x.conf", "iphone") == "warped.x.iphone"


def test_collated_is_the_shells_order(monkeypatch):
    """bash's *.conf and sort, in an en_US.UTF-8 terminal: case folded, and
    punctuation before digits before letters (not bytewise)."""
    monkeypatch.setenv("LC_ALL", "en_US.UTF-8")
    names = ["srv", "Upper", "home", "warped.q", "warped-y", "warped_z"]
    assert store.collated(names) == ["home", "srv", "Upper", "warped_z", "warped-y", "warped.q"]
    assert store.collated(["fd00:1::/48", "FE80::/10", "fd00::/8", "10.9.8.0/24", "100.64.0.0/10"]) == \
        ["10.9.8.0/24", "100.64.0.0/10", "fd00::/8", "fd00:1::/48", "FE80::/10"]


def test_collated_on_a_locale_this_mac_doesnt_have(monkeypatch):
    monkeypatch.setenv("LC_ALL", "xx_NOPE.UTF-8")
    assert store.collated(["b", "a", "B"]) == ["B", "a", "b"]     # C, as bash falls back to


def test_warped_name_device_in_it_twice():
    """Once at the front (dropped) and once at the end, where it stays with its separator."""
    assert store.warped_name("iphone-x_iphone.conf", "iphone") == "warped.x_iphone"
    assert store.warped_name("a.iphone.b.iphone.c.conf", "iphone") == "warped.a.b.c.iphone"


def test_an_endpoint_needs_a_host():
    assert Conf(client("a", endpoint=":51820")).problem() == "Endpoint isn't host:port"


@pytest.mark.parametrize("line,ka", [("PersistentKeepalive = 25 # every 25s", 25), ("PersistentKeepalive = ¹³", 0)])
def test_keepalive_as_wg_quick_reads_it(line, ka):
    assert Conf(f"[Peer]\n{line}\n").keepalive() == ka


def test_a_number_is_ascii_digits():
    assert Conf(client("a", mtu=1280).replace("1280", "¹²⁸⁰")).problem() == "MTU isn't a number from 576 to 65535"


def test_files_in_is_files(tmp_path):
    (tmp_path / "x.conf").mkdir()
    (tmp_path / "y.conf").write_text("")
    assert [os.path.basename(p) for p in store.files_in(str(tmp_path))] == ["y.conf"]


def test_write_private_leaves_nothing_when_it_fails(tmp_path, monkeypatch):
    def broken(_src, _dst):
        raise OSError("disk full")
    monkeypatch.setattr(os, "replace", broken)
    with pytest.raises(OSError):
        store.write_private(str(tmp_path / "a.conf"), "x")
    assert os.listdir(tmp_path) == []


def test_an_indented_section_header_counts():
    """As wg-quick and tunnel.sh read it."""
    text = "  [Interface]\nPrivateKey = a\nAddress = 10.0.0.2/32\n  [Peer]\nPublicKey = b\nEndpoint = h:1\n"
    assert Conf(text).problem() == ""
