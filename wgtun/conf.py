"""A WireGuard config as its lines: values read as wg-quick reads them (keys in
any case, CRLF ignored), and rewrites that keep every other line as it is."""

from __future__ import annotations

import os
import re
from typing import Callable, Dict, List


class Error(Exception):
    """A reason to stop, said once by the script's main() (store re-exports it)."""


class Conf:
    def __init__(self, text: str, path: str = "") -> None:
        self.path = path
        self.name = os.path.basename(path)[: -len(".conf")] if path.endswith(".conf") else os.path.basename(path)
        lines = text.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        self.lines = [ln[:-1] if ln.endswith("\r") else ln for ln in lines]

    @classmethod
    def read(cls, path: str) -> Conf:
        try:
            with open(path, newline="") as f:
                return cls(f.read(), path)
        except UnicodeDecodeError:
            raise Error(f"{path}: not UTF-8 text") from None

    def values(self, key: str) -> List[str]:
        """Every <key> line's value: all after the first "=" (base64 keys end in "=")."""
        return [line.split("=", 1)[1].strip() for line in self.lines if is_key(line, key)]

    def value(self, key: str) -> str:
        found = self.values(key)
        return found[0] if found else ""

    def items(self, key: str) -> List[str]:
        """Every comma-separated entry of every <key> line (Address, AllowedIPs)."""
        return [e.strip() for v in self.values(key) for e in v.split(",") if e.strip()]

    def keepalive(self) -> int:
        """PersistentKeepalive in seconds, 0 for none (or not a number)."""
        ka = self.value("PersistentKeepalive")
        return int(ka) if ka.isdigit() else 0

    def mtu(self, default: int) -> int:
        mtu = self.value("MTU")
        return int(mtu) if mtu.isdigit() else default

    def endpoint(self) -> tuple[str, int]:
        """(host, port), brackets taken off an IPv6 host."""
        host, _, port = self.value("Endpoint").rpartition(":")
        return host.strip("[]"), int(port)

    def problem(self) -> str:
        """Why this isn't a usable one-peer client config, or "" when it is."""
        if not any(re.match(r"\[Interface\]", ln, re.I) for ln in self.lines):
            return "no [Interface]"
        peers = sum(1 for ln in self.lines if re.match(r"\[Peer\]", ln, re.I))
        if peers != 1:
            return f"{peers} [Peer] sections, needs one"
        for key in ("PrivateKey", "PublicKey"):
            if not self.value(key):
                return f"no {key}"
        if not self.items("Address"):
            return "no Address"
        if not re.search(r":[0-9]+$", self.value("Endpoint")):
            return "Endpoint isn't host:port"
        if self.value("MTU") and not self.value("MTU").isdigit():
            return "MTU isn't a number"
        return ""

    def rewrite(self, edits: Dict[str, Callable[[str], List[str]]]) -> str:
        """The config with each line of a key in edits replaced by what its
        function returns for that line (none drops it); CR line ends dropped."""
        out: List[str] = []
        for line in self.lines:
            key = next((k for k in edits if is_key(line, k)), None)
            out += edits[key](line) if key else [line]
        return "".join(ln + "\n" for ln in out)


def is_key(line: str, key: str) -> bool:
    return re.match(rf"\s*{key}\s*=", line, re.I) is not None

