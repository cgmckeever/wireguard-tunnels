"""A throwaway store per test ($WG_TUNNELS in tmp_path), with fake keys."""

from __future__ import annotations

import base64
import hashlib
import os
from typing import Iterator, Optional

import pytest


def key(seed: str) -> str:
    return base64.b64encode(hashlib.sha256(seed.encode()).digest()).decode()


def client(seed: str, *, head: str = "", endpoint: str = "vpn.example.net:51820",
           allowed: Optional[str] = "0.0.0.0/0, ::/0",
           keepalive: Optional[int] = 25, mtu: Optional[int] = None, psk: bool = False) -> str:
    """A one-peer client config; seed makes its keys (same seed, same keys)."""
    lines = [head] if head else []
    lines += ["[Interface]", f"PrivateKey = {key(seed)}", "Address = 10.0.0.2/32, fd00::2/128", "DNS = 9.9.9.9"]
    if mtu:
        lines.append(f"MTU = {mtu}")
    lines += ["", "[Peer]", f"PublicKey = {key(seed + '.pub')}"]
    if psk:
        lines.append(f"PresharedKey = {key(seed + '.psk')}")
    if allowed is not None:
        lines.append(f"AllowedIPs = {allowed}")
    lines.append(f"Endpoint = {endpoint}")
    if keepalive:
        lines.append(f"PersistentKeepalive = {keepalive}")
    return "\n".join(lines) + "\n"


def wgcf(seed: str) -> str:
    """A wgcf-profile.conf as wgcf writes it (no keepalive, Cloudflare's hostname)."""
    return (f"[Interface]\nPrivateKey = {key(seed)}\nAddress = 172.16.0.2/32\nAddress = 2606:4700::2/128\n"
            "DNS = 1.1.1.1\nMTU = 1280\n[Peer]\nPublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=\n"
            "AllowedIPs = 0.0.0.0/0\nAllowedIPs = ::/0\nEndpoint = engage.cloudflareclient.com:2408\n")


class Store:
    def __init__(self, root: str) -> None:
        self.root = root

    def path(self, rel: str) -> str:
        return os.path.join(self.root, rel)

    def put(self, rel: str, text: str, mode: int = 0o600) -> str:
        p = self.path(rel)
        os.makedirs(os.path.dirname(p), mode=0o700, exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
        os.chmod(p, mode)
        return p

    def read(self, rel: str) -> str:
        with open(self.path(rel)) as f:
            return f.read()

    def device(self, name: str, *, carriers: bool = True, warp: bool = True) -> str:
        """devices/<name>/ as singbox.sh new leaves it."""
        d = f"devices/{name}"
        for sub in ["", "/config"] + (["/carriers"] if carriers else []):
            os.makedirs(self.path(d + sub), mode=0o700, exist_ok=True)
        if warp:
            self.put(f"{d}/warp/wgcf-profile.conf", wgcf(name + ".warp"))
        return d


@pytest.fixture
def store(tmp_path, monkeypatch) -> Iterator[Store]:
    root = str(tmp_path / "wg-tunnels")
    os.makedirs(os.path.join(root, "devices"), mode=0o700)
    monkeypatch.setenv("WG_TUNNELS", root)
    old = os.umask(0o077)       # as the scripts' main()s set it
    yield Store(root)
    os.umask(old)
