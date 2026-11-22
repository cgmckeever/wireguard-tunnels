"""check.sh: the store as the scripts leave it, and the rules every tunnel follows."""

from __future__ import annotations

import contextlib
import os

from wgtun import check, singbox

from .conftest import client


def built_phone(store):
    store.device("ph")
    store.put("devices/ph/carriers/srv.conf", client("srv"))
    store.put("devices/ph/config/dengar.ph.conf", client("dengar"))
    with open(os.devnull, "w") as quiet, contextlib.redirect_stdout(quiet):
        singbox.cmd_build("ph")
    return store


def test_a_fresh_build_is_clean(store):
    built_phone(store)
    assert check.check_device("ph") == []


def test_stale_config_and_profile(store):
    built_phone(store)
    store.put("devices/ph/.warp-endpoint", "162.159.192.5:2408\n")      # the sweep and build haven't run since
    found = check.check_device("ph")
    assert ("error", "config/warp.ph.conf is out of date: run singbox.sh build ph") in found
    assert ("error", "sing-box/warp.ph.json is out of date: run singbox.sh build ph") in found


def test_a_profile_build_doesnt_make(store):
    built_phone(store)
    store.put("devices/ph/sing-box/extra.json", "{}\n")
    assert check.check_device("ph") == [
        ("error", "sing-box/extra.json isn't a profile build makes: run singbox.sh build ph")]


def test_modes_problems_keepalive(store):
    store.device("tv", carriers=False, warp=False)
    store.put("devices/tv/config/home.tv.conf", client("home", keepalive=None), mode=0o644)
    store.put("devices/tv/config/nopub.tv.conf", client("nopub").replace("PublicKey", "#"))
    found = check.check_device("tv")
    assert ("error", "config/home.tv.conf is 644, should be 600") in found
    assert ("error", "config/nopub.tv.conf: no PublicKey") in found
    assert any(kind == "warning" and "home.tv.conf: no PersistentKeepalive" in what for kind, what in found)


def test_a_shared_key_without_sing_box(store):
    for d in ("tv", "pc"):
        store.device(d, carriers=False, warp=False)
        store.put(f"devices/{d}/config/srv.{d}.conf", client("same"))
    assert check.check_device("tv")[0][1].startswith("same private key in:")


def test_main_exit(store, capsys):
    built_phone(store)
    assert check.main([]) == 0
    store.put("devices/ph/sing-box/extra.json", "{}\n")
    assert check.main(["ph"]) == 1
    assert "1 error in 1 device" in capsys.readouterr().out


def test_a_dotfile_isnt_a_profile(store):
    built_phone(store)
    store.put("devices/ph/sing-box/.ph.json.tmp.json", "{}\n")
    assert check.check_device("ph") == []


def test_a_device_name_build_cant_take(store):
    """Fine for the WireGuard app; an error once the device has sing-box profiles."""
    store.device("my phone", carriers=False, warp=False)
    store.put("devices/my phone/config/srv.conf", client("srv"))
    assert check.check_device("my phone") == []
    os.makedirs(store.path("devices/my phone/sing-box"), mode=0o700)
    assert check.check_device("my phone") == [
        ("error", "device names are letters, digits, . _ - (not starting with .)")]


def test_every_private_file_and_folder(store):
    built_phone(store)
    store.put("devices/ph/exports/tunnels.zip", "keys", mode=0o644)
    store.put("devices/ph/warp/wgcf-account.toml", "token", mode=0o644)
    store.put("devices/ph/carriers/.DS_Store", "finder", mode=0o644)
    os.chmod(store.path("devices/ph/config"), 0o755)
    found = check.check_device("ph")
    assert ("error", "exports/tunnels.zip is 644, should be 600") in found
    assert ("error", "warp/wgcf-account.toml is 644, should be 600") in found
    assert ("error", "config/ is 755, should be 700") in found
    assert not any(".DS_Store" in what for _, what in found)


def test_one_bad_device_doesnt_stop_the_rest(store, capsys):
    built_phone(store)
    path = store.put("devices/ph/config/bad.ph.conf", "")
    with open(path, "wb") as f:
        f.write(b"\xff")
    assert check.main(["nosuch", "ph"]) == 1
    out = capsys.readouterr().out
    assert "nosuch\n  error: no device nosuch" in out
    assert f"error: {path}: not UTF-8 text" in out
    assert out.count("not UTF-8 text") == 1          # once, on its own device
    assert out.endswith("2 errors in 2 devices\n")


def test_a_folder_it_cant_read(store, capsys):
    built_phone(store)
    os.chmod(store.path("devices/ph/carriers"), 0)
    try:
        assert check.main(["ph"]) == 1
    finally:
        os.chmod(store.path("devices/ph/carriers"), 0o700)
    assert "  error: [Errno 13] Permission denied" in capsys.readouterr().out


def test_a_bad_file_is_its_own_devices_problem(store, capsys):
    built_phone(store)
    store.device("tv", carriers=False, warp=False)
    store.put("devices/tv/config/srv.tv.conf", client("tv"))
    with open(store.put("devices/ph/config/bad.ph.conf", ""), "wb") as f:
        f.write(b"\xff")
    assert check.check_device("tv") == []
