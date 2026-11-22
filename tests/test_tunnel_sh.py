"""tunnel.sh is the root daemon, one bash file: it can't share wgtun's code,
so it keeps its own copies of a few rules. These keep the copies in step."""

from __future__ import annotations

import os
import re
import subprocess

import pytest

from wgtun import store
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


def swept_ok(conf: str, warp_host: str) -> subprocess.CompletedProcess:
    """tunnel.sh's own check of a warped config, run alone."""
    fn = re.search(r"^swept_ok\(\) \{.*?^\}$", source(), re.M | re.S)
    assert fn, "swept_ok is gone from tunnel.sh"
    return subprocess.run(["bash", "-c", fn.group(0) + '\nswept_ok "$1" "$2"', "_", conf, warp_host],
                          capture_output=True, text=True)


@pytest.mark.parametrize("conf", [os.path.join(d, f) for d, _, files in os.walk(GOLDEN) for f in files
                                  if os.path.basename(d) == "config" and f.startswith("warped.") and "gone" not in f])
def test_tunnel_sh_takes_what_the_sweep_writes(conf):
    device_dir = os.path.dirname(os.path.dirname(conf))
    host = store.warp_endpoint(device_dir).rsplit(":", 1)[0]
    result = swept_ok(conf, host)
    assert result.returncode == 0, result.stdout


def test_tunnel_sh_refuses_what_the_sweep_wouldnt(tmp_path):
    good = next(os.path.join(d, f) for d, _, files in os.walk(GOLDEN) for f in files if f == "warped.x.edge1.conf")
    wide = Conf.read(good).rewrite({"AllowedIPs": lambda _l: ["AllowedIPs = 162.159.192.7/32, 10.0.0.0/4"]})
    path = tmp_path / "wide.conf"
    path.write_text(wide)
    assert "too wide" in swept_ok(str(path), "162.159.192.7").stdout
