"""tunnel.sh is the root daemon, one bash file: it can't share wgtun's code,
so it keeps its own copies of a few rules. These keep the copies in step."""

from __future__ import annotations

import os
import re
import subprocess

import pytest

from wgtun import store, sweep
from wgtun.conf import Conf

TUNNEL_SH = os.path.join(store.SCRIPTS, "tunnel.sh")
GOLDEN = os.path.join(os.path.dirname(__file__), "golden", "edge", "devices")


def source() -> str:
    with open(TUNNEL_SH) as f:
        return f.read()


def test_the_same_keepalive_and_warp_overhead():
    sh = source()
    assert re.findall(r"PersistentKeepalive = (\d+)", sh) == [str(store.KEEPALIVE)] * 2
    assert set(re.findall(r"\$\(\(cm - (\d+)\)\)", sh)) == {str(store.WARP_OVERHEAD)}


def functions(*names: str) -> str:
    """Those functions' definitions from tunnel.sh, to run on their own."""
    out = []
    for n in names:
        fn = re.search(rf"^{n}\(\) \{{.*?^\}}$|^{n}\(\) \{{[^\n]*\}}$", source(), re.M | re.S)
        assert fn, f"{n} is gone from tunnel.sh"
        out.append(fn.group(0))
    return "\n".join(out)


BASH = "/bin/bash" if os.path.exists("/bin/bash") else "bash"     # macOS's 3.2 runs #!/bin/bash scripts


def bash(defs: str, call: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([BASH, "-c", f"{defs}\n{call}", "_", *args], capture_output=True, text=True)


def swept_ok(conf: str, warp_host: str) -> subprocess.CompletedProcess:
    """tunnel.sh's own check of a warped config, run alone."""
    return bash(functions("conf_vals", "list_of", "swept_ok"), 'swept_ok "$1" "$2"', conf, warp_host)


@pytest.mark.parametrize("line,on", [("PersistentKeepalive = 25", True), ("persistentkeepalive=25\r", True),
                                     ("PersistentKeepalive = 0", False), ("PersistentKeepalive = off", False),
                                     ("PersistentKeepalive = 00", False), ("PersistentKeepalive = Off", False),
                                     ("", False)])
def test_has_keepalive_as_wgtun_reads_it(tmp_path, line, on):
    path = tmp_path / "t.conf"
    path.write_text(f"[Peer]\nEndpoint = h:1\n{line}\n")
    sh = bash(functions("conf_vals", "conf_val", "has_keepalive"), 'has_keepalive "$1"', str(path)).returncode == 0
    assert sh == on == bool(Conf.read(str(path)).keepalive())


@pytest.mark.parametrize("conf", [os.path.join(d, f) for d, _, files in os.walk(GOLDEN) for f in files
                                  if os.path.basename(d) == "config" and f.startswith("warped.") and "gone" not in f])
def test_tunnel_sh_takes_what_the_sweep_writes(conf):
    device_dir = os.path.dirname(os.path.dirname(conf))
    host = store.warp_net(store.warp_endpoint(device_dir)).split("/")[0]
    result = swept_ok(conf, host)
    assert result.returncode == 0, result.stdout


def test_tunnel_sh_refuses_what_the_sweep_wouldnt(tmp_path):
    good = os.path.join(GOLDEN, "edge1", "config", "warped.x.edge1.conf")
    wide = Conf.read(good).rewrite({"AllowedIPs": lambda _l: ["AllowedIPs = 162.159.192.7/32, 10.0.0.0/4"]})
    path = tmp_path / "wide.conf"
    path.write_text(wide)
    assert "too wide" in swept_ok(str(path), "162.159.192.7").stdout


def test_the_same_names_and_numbers():
    """tunnel.sh's own copies: the warped prefix, WARP alone's name, WARP's MTU."""
    sh = source()
    assert re.search(r'^TUNNEL_PREFIX="([^"]+)"', sh, re.M).group(1) == store.WARPED
    assert f'full="${{full:-{store.WARP_MTU}}}"' in sh
    assert '"warp.$(basename "$(mac_dir)")"' in sh and store.warp_alone("x") == "warp.x"


@pytest.mark.parametrize("name", ["iphone", "mbp-1", "a.b_c", ".hidden", "-x", "x y", "_x", ""])
def test_valid_device_as_wgtun_judges_it(name):
    sh = bash(functions("valid_device"), 'valid_device "$1"', name).returncode == 0
    assert sh == store.valid_device(name)


@pytest.mark.parametrize("entry", ["10.0.0.0/8", "10.0.0.0/7", "fd00::/16", "fc00::/15", "10.9.8.0/24"])
def test_swept_ok_widths_as_the_sweep_judges_them(tmp_path, entry):
    path = tmp_path / "w.conf"
    path.write_text(f"[Interface]\n[Peer]\nAllowedIPs = 162.159.192.1/32, {entry}\nEndpoint = h:1\n")
    ok = swept_ok(str(path), "162.159.192.1").returncode == 0
    assert ok == (sweep.verdict(entry) == "kept")


def test_conf_val_drops_a_comment_as_wgtun_does(tmp_path):
    path = tmp_path / "c.conf"
    path.write_text("[Peer]\nPersistentKeepalive = 25 # every 25s\n")
    out = bash(functions("conf_vals", "conf_val"), 'conf_val "$1" PersistentKeepalive', str(path)).stdout.strip()
    assert out == "25" == str(Conf.read(str(path)).keepalive())


def test_nord_sh_writes_the_same_keepalive():
    with open(os.path.join(store.SCRIPTS, "nord.sh"), encoding="utf-8") as f:
        assert re.findall(r"PersistentKeepalive = (\d+)", f.read()) == [str(store.KEEPALIVE)]
