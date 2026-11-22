"""The input of the golden test: a store with fake keys and the edge cases the
shell scripts handled (CRLF, extras, small MTUs, odd names, orphans, a shared
key, Nord, a reserved name). golden/edge/ is what the old shell sweep and
singbox.sh left after running every device; golden/edge.modes its modes."""

import base64
import hashlib
import os


def make(root):
    def key(seed):
        return base64.b64encode(hashlib.sha256(seed.encode()).digest()).decode()

    def write(rel, text, mode=0o600):
        p = os.path.join(root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", newline="") as f:
            f.write(text)
        os.chmod(p, mode)

    def conf(
        seed,
        endpoint="vpn.example.net:51820",
        allowed="0.0.0.0/0, ::/0",
        extra_if="",
        extra_peer="",
        head="",
        ka="25",
        psk=False,
        eol="\n",
    ):
        lines = [
            *filter(None, head.split("\n")),
            "[Interface]",
            f"PrivateKey = {key(seed)}",
            "Address = 10.0.0.2/32, fd00::2/128",
            "DNS = 9.9.9.9",
            *filter(None, extra_if.split("\n")),
            "",
            "[Peer]",
            f"PublicKey = {key(seed + 'pub')}",
        ]
        if psk:
            lines.append(f"PresharedKey = {key(seed + 'psk')}")
        if allowed is not None:
            lines.append(f"AllowedIPs = {allowed}")
        lines.append(f"Endpoint = {endpoint}")
        if ka:
            lines.append(f"PersistentKeepalive = {ka}")
        lines += [*filter(None, extra_peer.split("\n"))]
        return eol.join(lines) + eol

    def wgcf(seed):
        return (
            f"[Interface]\nPrivateKey = {key(seed)}\nAddress = 172.16.0.2/32\n"
            "Address = 2606:4700:110:8f::2/128\nDNS = 1.1.1.1\nMTU = 1280\n"
            "[Peer]\nPublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=\n"
            "AllowedIPs = 0.0.0.0/0\nAllowedIPs = ::/0\nEndpoint = engage.cloudflareclient.com:2408\n"
        )

    write("devices/.default", "edge1\n")
    for d in ["devices", "devices/edge1", "devices/edge1/carriers", "devices/edge1/config", "devices/edge1/warp"]:
        os.makedirs(os.path.join(root, d), exist_ok=True)
    write("devices/edge1/.warp-endpoint", "162.159.192.7:2408\n")
    write("devices/edge1/warp/wgcf-profile.conf", wgcf("edge1-warp"))
    # carriers: extras (kept, wide, bad), CRLF, small MTU, custom keepalive, DNS
    write(
        "devices/edge1/carriers/x.conf",
        conf(
            "x",
            head="# wireguard-tools client: x.edge1 on srv\n# device-network: 10.9.8.0/24\n"
            "# tunnel-routes: 192.168.5.0/24, 10.0.0.0/4 # wide one\n"
            "# tunnel-routes: not-an-ip, 300.1.1.1, fd00:1::/48",
            extra_if="MTU = 1300",
            ka="15",
            eol="\r\n",
        ),
    )
    write("devices/edge1/carriers/warped-y.conf", conf("y", allowed=None, ka=""))  # no AllowedIPs line, no keepalive
    write(
        "devices/edge1/carriers/edge1-z.conf", conf("z", endpoint="[2001:db8::1]:51820", psk=True)
    )  # device in name, IPv6 endpoint
    write("devices/edge1/carriers/q.conf", conf("q"))
    write("devices/edge1/carriers/warped.q.conf", conf("q2"))  # same warped name as q.conf
    write("devices/edge1/carriers/broken.conf", conf("b") + "[Peer]\nPublicKey = x\n")  # two peers
    write("devices/edge1/carriers/open.conf", conf("open"), mode=0o644)  # loose perms
    # config/: plain tunnels
    write("devices/edge1/config/srv.full.edge1.conf", conf("full", ka="30", psk=True))
    write(
        "devices/edge1/config/home.lan.edge1.conf", conf("home", allowed="192.168.1.0/24", ka="")
    )  # split, no keepalive
    write("devices/edge1/config/Upper.edge1.conf", conf("upper", extra_if="MTU = 1380"))
    write("devices/edge1/config/srv.zz.edge1.conf", conf("zz"))
    write("devices/edge1/config/warped.gone.edge1.conf", conf("gone", allowed="162.159.192.7/32"))  # orphan
    write(
        "devices/edge1/config/nopub.edge1.conf",
        f"[Interface]\nPrivateKey = {key('nopub')}\nAddress = 10.1.1.1/32\n[Peer]\nEndpoint = a:1\n",
    )
    # edge2: plain configs only (no carriers/, no warp/), as wireguard-tools delivers
    write(
        "devices/edge2/config/srv.chi.edge2.conf",
        conf("e2", head="# wireguard-tools client: chi.edge2 on srv\n# exit: chi"),
    )
    write("devices/edge2/config/srv.nyc.edge2.conf", conf("e2b"))
    # edge3: a key another device uses (build must stop)
    write("devices/edge3/config/dup.edge3.conf", conf("e2"))
    os.makedirs(os.path.join(root, "devices/edge3/carriers"), exist_ok=True)
    # edge4: a tunnel named like the composite (build must stop)
    write("devices/edge4/config/edge4.conf", conf("e4"))
    # edge5: warp only + nord configs sharing one key (exempt from the key check)
    write("devices/edge5/warp/wgcf-profile.conf", wgcf("edge5-warp"))
    os.makedirs(os.path.join(root, "devices/edge5/carriers"), exist_ok=True)
    write("devices/edge5/config/nord.us1.edge5.conf", "# source: nord us\n" + conf("nord"))
    write("devices/edge5/config/nord.us2.edge5.conf", "# source: nord us\n" + conf("nord", endpoint="5.6.7.8:51820"))
    for dp, _dirs, _files in os.walk(root):
        os.chmod(dp, 0o700)
