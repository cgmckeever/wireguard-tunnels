"""The shell scripts: every command they run exists (a function they define or
source, a bash builtin, or a program on this Mac). bash only finds a missing
one when that line runs, and most of these lines need root, a network or the
daemon, so nothing else here would."""

from __future__ import annotations

import glob
import os
import re
import shutil
import subprocess

import pytest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Every shell script (links to _python.sh aren't scripts of their own)
SCRIPTS = sorted(
    os.path.relpath(p, REPO)
    for pattern in ("install.sh", "test.sh", ".githooks/pre-commit", "scripts/*.sh", "scripts/swiftbar/*.sh")
    for p in glob.glob(os.path.join(REPO, pattern))
    if not os.path.islink(p)
)
# Programs only some Macs have, or that install.sh installs: not on PATH everywhere
OPTIONAL = {
    "wg",
    "wg-quick",
    "wireguard-go",
    "wgcf",
    "qrencode",
    "sing-box",
    "shellcheck",
    "brew",
    "jq",
    "wgt-ctl",
    "open",
    "SwiftBar",
}
QUOTED = " _quoted_ "  # a quoted word stands in place: "$TUNNEL" up runs $TUNNEL, not up
KEYWORDS = {
    "_quoted_",
    "if",
    "then",
    "else",
    "elif",
    "fi",
    "for",
    "while",
    "until",
    "do",
    "done",
    "case",
    "esac",
    "in",
    "function",
    "select",
    "time",
    "coproc",
    "!",
    "[[",
    "]]",
    "{",
    "}",
}


def read(rel: str) -> str:
    with open(os.path.join(REPO, rel), encoding="utf-8") as f:
        return f.read()


# Which scripts source _lib.sh, as they say so themselves (not _lib.sh's own header)
SOURCED = {s: "scripts/_lib.sh" for s in SCRIPTS if s != "scripts/_lib.sh" and '/_lib.sh"' in read(s)}


def code(text: str) -> str:
    """The script as commands only: heredoc bodies, comments, case patterns and
    quoted text taken out, keeping the $( ... ) inside double quotes (that's
    code). Single-quoted text is programs for awk, sed and jq, not commands."""
    lines, end = [], None
    for line in text.split("\n"):
        if end is not None:
            end = None if line.strip() == end else end
            continue
        m = re.search(r"<<-?\s*['\"]?(\w+)['\"]?", line)
        if m and "<<<" not in line:
            end = m.group(1)
        # a case arm's pattern: at a line's start, or after "case ... in"
        line = re.sub(r"^\s*\(?[^\s()]+(\|[^\s()]+)*\)(?=\s|$)", " ", line)
        line = re.sub(r"(\bin\s+)\(?[^\s()]+(\|[^\s()]+)*\)(?=\s|$)", r"\1 ", line)
        lines.append(line)
    # an array's words aren't commands: shells=(a b c)
    src = re.sub(r"=\([^)]*\)", "=_quoted_", commands_only("\n".join(lines)))
    # variable names after local and read, not commands (one may be called until)
    return re.sub(r"^(\s*(?:local|declare|readonly|read)\b)[^;&|\n]*", r"\1", src, flags=re.M)


def commands_only(src: str) -> str:
    """src with only what bash runs as commands: a stack of contexts, code and
    double quotes; $( ) inside either is code again. Single quotes, comments,
    arithmetic $(( )) and quoted text are dropped."""
    out: list = []
    stack = [["code", 0]]  # [kind, open parens] per context
    i = 0
    while i < len(src):
        kind, parens = stack[-1]
        c = src[i]
        if c == "\\":
            out.append(" " if kind == "dq" else src[i : i + 2])
            i += 2
            continue
        if src.startswith("$((", i) or (kind == "code" and src.startswith("((", i)):
            depth, i = 0, i + (3 if src[i] == "$" else 2)
            while i < len(src) and not (depth == 0 and src.startswith("))", i)):
                depth += (src[i] == "(") - (src[i] == ")")
                i += 1
            out.append(" ")
            i += 2
            continue
        if src.startswith("$(", i):
            stack.append(["code", 0])
            out.append(" $(")
            i += 2
            continue
        if kind == "dq":
            if c == '"':
                stack.pop()
            i += 1
            continue
        if c == "'":
            j = src.find("'", i + 1)
            i = len(src) if j == -1 else j + 1
            out.append(QUOTED)
            continue
        if c == '"':
            stack.append(["dq", 0])
            out.append(QUOTED)
            i += 1
            continue
        if c == "#" and (i == 0 or src[i - 1] in " \t\n;("):
            j = src.find("\n", i)
            i = len(src) if j == -1 else j
            continue
        if c == "(":
            stack[-1][1] += 1
        elif c == ")":
            if parens == 0 and len(stack) > 1:
                stack.pop()
                out.append(")")
                i += 1
                continue
            stack[-1][1] -= 1
        out.append(c)
        i += 1
    return "".join(out)


def defined(text: str) -> set:
    return set(re.findall(r"^\s*([A-Za-z_][\w-]*)\(\)\s*\{", text, re.M))


def called(text: str) -> set:
    """The first word of each command: at a line's start, or after ; & | ( { $( and the keywords."""
    found = set()
    for m in re.finditer(
        r"(?:^|[;&|({`]|\$\(|\b(?:then|do|else|elif|if|while|until|!)\s)\s*([A-Za-z_][\w.-]*)(?=[\s;)|&]|$)", text, re.M
    ):
        word = m.group(1)
        rest = text[m.end() : m.end() + 1]
        if rest == "=" or re.match(rf"{re.escape(word)}\+?=", text[m.start(1) : m.start(1) + len(word) + 2]):
            continue  # an assignment
        found.add(word)
    return found - KEYWORDS


def builtins() -> set:
    out = subprocess.run(["/bin/bash", "-c", "compgen -b; compgen -k"], capture_output=True, text=True).stdout
    return set(out.split())


@pytest.mark.parametrize("script", SCRIPTS)
def test_every_command_exists(script):
    text = code(read(script))
    known = defined(read(script)) | builtins() | OPTIONAL
    if script in SOURCED:
        known |= defined(read(SOURCED[script]))
    missing = sorted(w for w in called(text) - known if not shutil.which(w) and not re.fullmatch(r"[A-Z_]+", w))
    assert missing == [], f"{script} runs commands that don't exist: {missing}"


def test_it_catches_a_missing_one():
    text = code('cmd_up() {\n    stop_apps\n    ask up "$1" || return 1\n}\nstop_apps() { :; }\n')
    assert sorted(called(text) - defined(text) - builtins()) == ["ask"]


@pytest.mark.parametrize("script", SCRIPTS)
def test_parses_in_macos_bash(script):
    """bash -n under /bin/bash (3.2): what runs the #!/bin/bash scripts."""
    run = subprocess.run(["/bin/bash", "-n", os.path.join(REPO, script)], capture_output=True, text=True)
    assert run.returncode == 0, run.stderr


def test_sources_found():
    assert set(SOURCED) == {"install.sh", "scripts/nord.sh", "scripts/qr.sh"}


def test_the_python_scripts_run_their_own_wgtun(tmp_path):
    """Not a wgtun/ in the current folder (another checkout, say), which python3 -m would take first."""
    (tmp_path / "wgtun").mkdir()
    for name in ("__init__.py", "check.py", "forinstall.py"):
        (tmp_path / "wgtun" / name).write_text('raise SystemExit("the wrong wgtun")\n')
    for cmd in (["check.sh", "-h"], ["_python.sh", "forinstall", "device-name", "ok"]):
        out = subprocess.run([os.path.join(REPO, "scripts", cmd[0]), *cmd[1:]], cwd=tmp_path,
                             capture_output=True, text=True)
        assert out.returncode == 0 and "wrong wgtun" not in out.stdout + out.stderr, (cmd, out)


@pytest.mark.skipif(not shutil.which("jq"), reason="nord.sh needs jq before it picks")
def test_nord_offers_only_the_servers_wireguard_tools_lists(tmp_path):
    """A server folder counts once wireguard-tools lists it (its login file), as
    wgt-ctl's own list does; a removed server's backups don't bring it back. Both
    runs stop before Nord's API."""
    servers = tmp_path / "fleet" / "servers"
    (servers / "listed").mkdir(parents=True)
    (servers / "listed" / "login").write_text("root@h\n")
    (servers / "removed" / "backups").mkdir(parents=True)

    def nord(*args):
        env = dict(os.environ, WG_TUNNELS=str(tmp_path))
        return subprocess.run(["bash", os.path.join(REPO, "scripts", "nord.sh"), *args], env=env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True)

    r = nord("server", "removed", "us")
    assert r.returncode != 0 and "no server 'removed'" in r.stderr
    (servers / "listed" / "login").unlink()
    r = nord("server", "listed", "us")
    assert r.returncode != 0 and "wireguard-tools lists" in r.stderr
