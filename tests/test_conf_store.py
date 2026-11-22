"""Reading configs (conf.py) and the store's names and rules (store.py)."""

from __future__ import annotations

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
    (client("a", mtu=1280).replace("1280", "big"), "MTU isn't a number"),
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


def test_warp_endpoint_device_then_store_then_cloudflare(store_root):
    s, dev = store_root
    assert store.warp_endpoint(dev) == store.WARP_ENDPOINT
    s.put(".warp-endpoint", "162.159.192.5:2408\n")
    assert store.warp_endpoint(dev) == "162.159.192.5:2408"
    s.put("devices/d/.warp-endpoint", " 162.159.192.9:500 \n")
    assert store.warp_endpoint(dev) == "162.159.192.9:500"
    s.put("devices/d/.warp-endpoint", "engage.cloudflareclient.com:2408")
    with pytest.raises(Error, match="IPv4:port"):
        store.warp_endpoint(dev)


@pytest.fixture
def store_root(store):
    return store, store.path(store.device("d"))


def test_sweep_owned_by_name():
    assert store.sweep_owned("warped.x.iphone", "iphone")
    assert store.sweep_owned("warp.iphone", "iphone")
    assert not store.sweep_owned("warp.mbp-1", "iphone")
    assert not store.sweep_owned("dengar.warp.iphone", "iphone")


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
