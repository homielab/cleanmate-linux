#!/usr/bin/env python3
"""TUI smoke test: drive cleanmate.sh in a virtual terminal (dry-run).

Walks through the main screens and checks that each one renders and that bash
never prints an error. Self-contained: a throwaway HOME, and `sudo`/`pkexec`
stubs that always fail, so the screens are the same on every machine. Works as
an ordinary user and as root. Needs the `pyte` module (pip install pyte).
"""
import fcntl, os, pty, re, select, shutil, signal, struct, sys, tempfile, termios, time

import pyte

SCRIPT = sys.argv[1]
ROWS, COLS = 34, 110
ERRORS = re.compile(r"command not found|syntax error|unbound variable|bad array subscript|line \d+: ")

screen = pyte.Screen(COLS, ROWS)
stream = pyte.ByteStream(screen)
raw = bytearray()

ROOT = os.geteuid() == 0
tmp = tempfile.mkdtemp(prefix="cleanmate-tui.")
home, stubs = os.path.join(tmp, "home"), os.path.join(tmp, "stubs")
os.makedirs(os.path.join(home, ".config", "cleanmate"))
os.makedirs(stubs)
for name in ("sudo", "pkexec"):  # no password prompts, no cached credentials
    with open(os.path.join(stubs, name), "w") as f:
        f.write("#!/bin/sh\nexit 1\n")
    os.chmod(os.path.join(stubs, name), 0o755)

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM="xterm-256color", CLEANMATE_NO_UPDATE_CHECK="1", HOME=home,
                      PATH=stubs + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"))
    os.environ.pop("XDG_STATE_HOME", None)
    os.environ.pop("XDG_CONFIG_HOME", None)
    os.execvp("bash", ["bash", SCRIPT, "--dry-run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))


def pump(seconds):
    """Read output for `seconds`; True if any arrived."""
    got = False
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return got
            raw.extend(data)
            stream.feed(data)
            got = True
    return got


def text():
    return "\n".join(screen.display)


def step(keys, expect, timeout=60.0):
    """Send keys, then wait until the screen has changed and shows `expect` (regex)."""
    before = text()
    if keys:
        os.write(fd, keys.encode())
    end = time.time() + timeout
    while time.time() < end and not ((not keys or text() != before) and re.search(expect, text())):
        pump(0.1)
    found = (not keys or text() != before) and re.search(expect, text()) is not None
    quiet = time.time() + 3  # let the screen finish drawing before the next key
    while found and time.time() < quiet and pump(0.3):
        pass
    print(f"{'ok  ' if found else 'FAIL'} {keys!r:12} → /{expect}/")
    if not found:
        print(text())
    return found


start = [("", r"Smart Scan.*\n(.*\n)*.*CLEANUP")]  # home menu with sections
scan = [("1", r"Scan system folders with sudo"),  # smart scan asks about sudo first
        ("n", r"of junk found|Your system is clean")]  # … then shows the review
if ROOT:  # root is warned first, and has no sudo to ask for
    start = [("", r"Continue anyway\?"), ("y\n", start[0][1])]
    scan = [("1", r"of junk found|Your system is clean")]
checks = start + [
    ("?", r"Moving around"),                        # help overlay
    ("q", r"CLEANUP"),
] + scan + [
    ("h", r"hide clean|show clean"),                # toggle clean rows
    ("q", r"CLEANUP"),
    ("7", r"history list|Nothing to clear"),        # privacy
    ("q", r"CLEANUP"),
    ("s", r"Settings[\s\S]*ABOUT"),                 # settings with sections
    ("q", r"CLEANUP"),
    ("i", r"Largest folders"),                      # system overview
    ("q", r"CLEANUP"),
    ("t", r"start at login"),                       # startup items
    ("q", r"CLEANUP"),
    ("u", r"Uninstaller[\s\S]*apps? · all apps · by size"),  # app list, no search needed
    ("s", r"· by used"),                            # sort by last used
    ("f", r"not used for 90\+ days"),               # filter
    ("q", r"CLEANUP"),
    ("m", r"Keep fewer snap versions[\s\S]*Limit journal size"),
    ("q", r"CLEANUP"),
    ("/", r"Find:"),                                # find a menu row by name
    ("dupl\n", r"▸ 0\s+Duplicates"),
]
ok = all(step(k, e) for k, e in checks)
os.write(fd, b"q")
pump(1.0)


def exited(seconds):
    end = time.time() + seconds
    while time.time() < end:
        if os.waitpid(pid, os.WNOHANG) != (0, 0):
            return True
        pump(0.1)
    return False


if not exited(3):  # it should quit on its own; else stop it
    os.kill(pid, signal.SIGTERM)
    if not exited(3):
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
shutil.rmtree(tmp, ignore_errors=True)

errors = ERRORS.findall(raw.decode(errors="replace"))
if errors:
    print("FAIL bash errors in output:", sorted(set(errors)))
    ok = False
sys.exit(0 if ok else 1)
