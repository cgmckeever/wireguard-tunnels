# CLAUDE.md — working on wireguard-tunnels

macOS tooling for WireGuard configs kept in a folder store (`~/wg-tunnels`,
or `$WG_CONFIG_HOME`) that's shared with wireguard-tools. The README describes
the behavior; this file says how to change it without tangling it again.

## The contract between the parts

- **`config/` is the one copy every consumer reads.** That's the WireGuard
  app (`qr.sh`), `tunnel.sh import` and `singbox.sh build`.
  - A tunnel's settings, its keepalive included, are decided once, where
    `config/` is written: the sweep, `nord.sh`, wireguard-tools. Consumers
    pass them through.
  - Two exceptions. A sing-box group drops keepalives because it runs every
    tunnel at once. And `tunnel.sh` gives WARP 25 when its config has none
    (the daemon's `warp.conf`, and a WARP-alone config imported from a
    `dir`).
- **Ownership goes by name, without case** (the Mac's file system ignores
  it: `Warped.x` is the file the sweep writes as `warped.x`). One rule:
  `store.is_warped`, `is_warp_alone` and `sweep_owned`, with copies in
  `tunnel.sh` and `_lib.sh` (`is_warped`), and wireguard-tools'
  `tunnels.sweep_owned`; both repos' tests pin the same examples.
  - The sweep writes `config/warped.*` and `config/warp.<device>.conf`.
  - wireguard-tools writes `<server>.<config>.conf`, and never touches
    `warped.*` or `warp.<device>.conf`. It delivers them after a client
    change, `device rename`, `jump add`, `sync`, `setup`, `restore` and
    `move`, byte for byte, and keeps them UTF-8 (a config that isn't is
    refused here: `conf.read_text`).
  - `nord.sh` writes `nord.<cc>[.<city>].conf`, and rewrites only a file
    with a `# source: nord` line.
  - `tunnel.sh extract` is the exception that goes by a line, not a name: it
    replaces this Mac's `config/` from a WireGuard-app export zip, keeping
    only files with a `# wireguard-tools client:` line. A `warped.*` file
    has that line too (copied from its carrier), but it's the sweep's:
    extract replaces it like the rest.
  - Nothing else in `config/` is ours to rewrite.
- **Each repo writes its own README in `devices/`:** `README-tunnels.md`
  here (`store.write_readme`, from `wgtun/readmes/`), `README-tools.md` by
  wireguard-tools. Each is written when missing and never changed, and
  neither is a device: everything that lists `devices/` takes folders only.
- **`tunnel.sh` stays one standalone bash file.** It's the root daemon,
  copied to `/usr/local/sbin/wg-tunnels`, so it must never source or import
  code from this user-writable repo.
  - Its copies of shared rules are pinned to `wgtun/` by
    `tests/test_tunnel_sh.py`: keepalive 25, WARP's MTU and 80-byte
    overhead, the `warped.` prefix (in any case, `_lib.sh`'s too), WARP alone's name, device names, what a
    swept config looks like, and how a config value is read. `nord.sh`'s
    keepalive is pinned there too.
- **The menu bar plugin reads what `tunnel.sh` leaves.** That's `$RUN/*`
  and `tunnels.tsv`, and some of its messages ("Daemon up to date", diag's
  last line, failure lines). Change those together with
  `scripts/swiftbar/tunnel-status.5s.sh`.
- **Generated output only changes on purpose.** `tests/test_golden.py` pins
  every file, mode and printed line against the old shell scripts. If a
  change is meant to alter output, update `tests/golden/` in the same commit
  and say why.

## Rules

1. **One home per rule.** Before writing logic, look for its home: `wgtun/store.py` (names, paths, numbers, the WARP endpoint, keys, ordering), `wgtun/conf.py` (reading configs), `scripts/_lib.sh` (nord.sh, qr.sh and install.sh). Call it; don't copy it. Something already done twice is extracted now, not later.
2. **Change a rule everywhere it's read.** Before changing behavior, grep for every writer and consumer of the same files (`config/`, `sing-box/`, `$RUN/*` in tunnel.sh) and check they still agree.
3. **Small commits, one concern each.** A change touching one rule is easy to verify; a large batch is where mistakes hide (a call site edited and its function never defined, say).
4. **Verify, don't assume.** `./test.sh all` (the pre-commit hook runs it; `./test.sh hooks` sets that up), and `scripts/check.sh` on a real store after any change to what's written. Shell lines that need root or the daemon aren't run by tests: read them twice, and keep `tests/test_shell.py` passing (every command a script runs exists).
5. **Live-system caution.** `tunnel.sh` controls this Mac's network. Prefer refactors whose equivalence is clear by reading; test pure helpers by extracting them (see `tests/test_tunnel_sh.py`). Never run root commands, `install.sh` or `nord.sh` (it calls Nord's API) from a session without asking.
6. **Constraints.**
   - Python: stdlib only, 3.9 (macOS's `/usr/bin/python3`).
   - Shell: `/bin/bash` is 3.2.
   - Test tools: ruff, pytest and mypy are pinned in `pyproject.toml`; `test.sh` reads them there.
   - Private keys and tokens never go on a command line (`ps` shows them to every user).

## Layout

| Where | What |
|-------|------|
| `wgtun/conf.py` | A WireGuard config: values read as `wg-quick` reads them, line rewrites, whether it's usable |
| `wgtun/store.py` | The store: a device's folders, names, ordering, the WARP endpoint, the shared numbers, the key rule |
| `wgtun/sweep.py`, `singbox.py`, `check.py` | `wgwarp-sweep.sh`, `singbox.sh`, `check.sh` (all three links to `scripts/_python.sh`); the sweep and build each have a `plan()` that changes nothing, which check compares with the disk |
| `wgtun/forinstall.py` | `install.sh`'s store steps: device names, the WARP endpoint, folders, the WARP account, the daemon's `warp.conf` |
| `scripts/tunnel.sh` | The daemon and this Mac's CLI (standalone bash) |
| `scripts/_lib.sh` | What `nord.sh`, `qr.sh` and `install.sh` share |
| `scripts/nord.sh`, `qr.sh`, `wgtun.sh`, `swiftbar/`, `askpass.sh` | Nord configs, QR codes, the one entry point, the menu bar plugin, its sudo password dialog |
| `tests/` | pytest; `golden/` is the recorded shell output |
| `.githooks/pre-commit`, `.github/workflows/tests.yml` | Both run `./test.sh all` |
