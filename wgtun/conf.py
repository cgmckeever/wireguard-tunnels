"""A WireGuard config as its lines: values read as wg-quick reads them (keys in
any case, CRLF ignored, a trailing # comment dropped), and rewrites that keep
every other line as it is."""

from __future__ import annotations

import os
import re
from typing import Callable, Dict, List, Tuple


class Error(Exception):
    """A reason to stop, said once by the script's main() (store re-exports it)."""


class Conf:
    def __init__(self, text: str, path: str = "") -> None:
        self.path = path
        self.name = stem(path)
        lines = text.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        self.lines = [ln[:-1] if ln.endswith("\r") else ln for ln in lines]

    @classmethod
    def read(cls, path: str) -> Conf:
        return cls(read_text(path), path)

    def values(self, key: str) -> List[str]:
        """Every <key> line's value: all after the first "=" (base64 keys end in
        "="), up to a "#" (wg-quick drops a comment; no key or address has one)."""
        return [line.split("=", 1)[1].split("#", 1)[0].strip() for line in self.lines if is_key(line, key)]

    def value(self, key: str) -> str:
        found = self.values(key)
        return found[0] if found else ""

    def items(self, key: str) -> List[str]:
        """Every comma-separated entry of every <key> line (Address, AllowedIPs)."""
        return [e.strip() for v in self.values(key) for e in v.split(",") if e.strip()]

    def number(self, key: str, default: int) -> int:
        """<key> as a whole number, or default when it's missing or isn't one."""
        v = self.value(key)
        return int(v) if is_number(v) else default

    def keepalive(self) -> int:
        """PersistentKeepalive in seconds, 0 for none (or off)."""
        return self.number("PersistentKeepalive", 0)

    def mtu(self, default: int) -> int:
        return self.number("MTU", default)

    def endpoint(self) -> Tuple[str, int]:
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
        endpoint = re.fullmatch(r".+:([0-9]+)", self.value("Endpoint"))
        if not endpoint or not 1 <= int(endpoint.group(1)) <= 65535:
            return "Endpoint isn't host:port"
        mtu = self.value("MTU")
        if mtu and not (is_number(mtu) and 576 <= int(mtu) <= 65535):
            return "MTU isn't a number from 576 to 65535"
        return ""

    def rewrite(self, edits: Dict[str, Callable[[str], List[str]]]) -> str:
        """The config with each line of a key in edits replaced by what its
        function returns for that line (none drops it); CR line ends dropped."""
        out: List[str] = []
        for line in self.lines:
            key = next((k for k in edits if is_key(line, k)), None)
            out += edits[key](line) if key else [line]
        return "".join(ln + "\n" for ln in out)


def stem(path: str) -> str:
    """A config's name: its file name without .conf."""
    name = os.path.basename(path)
    return name[: -len(".conf")] if name.endswith(".conf") else name


def read_text(path: str) -> str:
    """A file as UTF-8 text, line ends as they are; one that isn't UTF-8 is an
    Error naming it (whatever the locale's encoding)."""
    try:
        with open(path, encoding="utf-8", newline="") as f:
            return f.read()
    except UnicodeDecodeError:
        raise Error(f"{path}: not UTF-8 text") from None


def is_number(v: str) -> bool:
    """ASCII digits only (str.isdigit takes ¹³⁰⁰, which int() refuses)."""
    return re.fullmatch(r"[0-9]+", v) is not None


def is_key(line: str, key: str) -> bool:
    return re.match(rf"\s*{key}\s*=", line, re.I) is not None
