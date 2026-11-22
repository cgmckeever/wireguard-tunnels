# CLAUDE.md — working on wireguard-tunnels

macOS tooling for WireGuard configs kept in a folder store (`~/wg-tunnels`,
or `$WG_TUNNELS`) that's shared with wireguard-tools. The README describes
the behavior; this file says how to change it without tangling it again.

## The contract between the parts

- **`config/` is the one copy every consumer reads.** That's the WireGuard
  app (`qr.sh`), `tunnel.sh import` and `singbox.sh build`.
  - A tunnel's settings, its keepalive included, are decided once, where
    `config/` is written: the sweep, `nord.sh`, wireguard-tools. Consumers
    pass them through.
  - The one exception is a sing-box group. It drops keepalives because it
    runs every tunnel at once.
- **Ownership goes by name.**
  - The sweep writes `config/warped.*` and `config/warp.<device>.conf`.
  - wireguard-tools writes `<server>.<config>.conf` and never touches
    `warped.*`.
  - Nothing else in `config/` is ours to rewrite.
- **`tunnel.sh` stays one standalone bash file.** It's the root daemon,
  copied to `/usr/local/sbin/wg-tunnels`, so it must never source or import
  code from this user-writable repo.
  - Its few copies of shared rules (keepalive 25, WARP's 80-byte overhead,
    what a swept config looks like) are pinned to `wgtun/` by
    `tests/test_tunnel_sh.py`.
- **Generated output only changes on purpose.** `tests/test_golden.py` pins
  every file, mode and printed line against the old shell scripts. If a
  change is meant to alter output, update `tests/golden/` in the same commit
  and say why.

## Rules

1. **One home per rule.** Before writing logic, look for its home: `wgtun/store.py` (names, paths, numbers, the WARP endpoint, keys, ordering), `wgtun/conf.py` (reading configs), `scripts/_lib.sh` (nord.sh and qr.sh). Call it; don't copy it. Something already done twice is extracted now, not later.
2. **Change a rule everywhere it's read.** Before changing behavior, grep for every writer and consumer of the same files (`config/`, `sing-box/`, `$RUN/*` in tunnel.sh) and check they still agree.
3. **Small commits, one concern each.** A change touching one rule is easy to verify; a large batch is where mistakes hide (a call site edited and its function never defined, say).
4. **Verify, don't assume.** `./test.sh all` (the pre-commit hook runs it; `./test.sh hooks` sets that up), and `scripts/check.sh` on a real store after any change to what's written. Shell lines that need root or the daemon aren't run by tests: read them twice, and keep `tests/test_shell.py` passing (every command a script runs exists).
5. **Live-system caution.** `tunnel.sh` controls this Mac's network. Prefer refactors whose equivalence is clear by reading; test pure helpers by extracting them (see `tests/test_tunnel_sh.py`). Never run root commands, `install.sh` or `nord.sh` (it calls Nord's API) from a session without asking.
6. **Constraints.**
   - Python: stdlib only, 3.9 (macOS's `/usr/bin/python3`).
   - Shell: `/bin/bash` is 3.2.
   - Private keys and tokens never go on a command line (`ps` shows them to every user).

## Layout

| Where | What |
|-------|------|
| `wgtun/` | Python behind `wgwarp-sweep.sh`, `singbox.sh`, `check.sh` (links to `scripts/_python.sh`) and `install.sh`'s store steps (`forinstall.py`) |
| `scripts/tunnel.sh` | The daemon and this Mac's CLI (standalone bash) |
| `scripts/_lib.sh` | What `nord.sh` and `qr.sh` share |
| `tests/` | pytest; `golden/` is the recorded shell output |
| `.githooks/pre-commit`, `.github/workflows/tests.yml` | Both run `./test.sh all` |
