"""Talk to the cleaning engine: `cleanmate.sh --json …`.

The GUI never decides what to delete itself. It runs the same tested engine as
the terminal app and reads one JSON event per line from it, asynchronously, so
the window never freezes.
"""
import json
import os
import shutil
import signal
from collections import deque

from gi.repository import Gio, GLib

from .i18n import _, saved_setting
from .messages import human  # noqa: F401 (engine.human is used by every page)

# Same groups and order as the terminal app's Smart Scan.
CATEGORY_TITLES = {
    "system": _("System Junk"),
    "logs": _("Logs"),
    "user": _("User Junk"),
    "browser": _("Browsers"),
    "apps": _("App Caches"),
    "ai": _("AI Tools"),
    "models": _("AI Models"),
    "dev": _("Developer Junk"),
    "privacy": _("Privacy"),
}
SMART_SCAN = ["system", "logs", "user", "browser", "apps", "ai", "models", "dev"]
# each category's group: a sidebar page and a switch in Settings › Scan groups (the engine's CAT_GROUP)
CAT_GROUP = {"system": "system", "logs": "logs", "user": "user", "browser": "user", "apps": "user", "ai": "ai",
             "models": "ai", "dev": "dev", "privacy": "privacy"}

# The Flatpak (Flathub) reaches your home folder but not the system: the engine leaves out the items that
# need root or a host tool, and the window the pages that manage the system's packages and services.
IN_FLATPAK = os.environ.get("container") == "flatpak" or os.path.exists("/.flatpak-info")
FLATPAK_HIDDEN_PAGES = ("uninstall", "startup", "maintenance")
FLATPAK_LIMITS_URL = ("https://github.com/homielab/cleanmate-linux/blob/main/packaging/flathub/README.md"
                      "#what-the-flatpak-cant-do")


# the last lines the engine wrote to stderr, kept for the error page and the bug report
STDERR_LINES = 20
STDERR_GRACE_MS = 300  # after a failed run, how long to wait for its last stderr lines
# pkexec's own exit statuses: the password dialog was dismissed (126), not authorized or no dialog (127)
PKEXEC_DISMISSED, PKEXEC_REFUSED = 126, 127
# a run that needed root and was never started: this copy of the engine isn't root's (root_owned)
NEEDS_PACKAGE = -2
# the polkit action of each command run as root (packaging/polkit): the password dialog says what it is for
POLKIT_ACTIONS = {"clean": "clean-system", "uninstall": "uninstall-apps", "maintain": "maintenance"}
PACKAGE_NEEDED = _("Needs CleanMate installed from a package")
PACKAGE_HINT = _("This copy of CleanMate is in a folder you can change, so it doesn't ask for your password. "
                 "Install CleanMate from the PPA or the .deb package to do this here, or run “sudo cm” in a terminal.")


# commands that change something on the disk: closing the window while one runs asks first
WRITING = {"clean", "trash", "restore", "uninstall", "reset", "maintain", "startup-set"}


def _children():
    """pid → its child pids, from /proc."""
    kids = {}
    try:
        names = os.listdir("/proc")
    except OSError:
        return kids
    for name in names:
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/stat", encoding="utf-8", errors="replace") as f:
                ppid = int(f.read().rpartition(")")[2].split()[1])
        except (OSError, ValueError, IndexError):
            continue
        kids.setdefault(ppid, []).append(int(name))
    return kids


def kill_tree(pid):
    """Kill PID and everything it started (find, du, apt …): killing bash alone would leave those running.
    Stopped first, so it can't start another one meanwhile. A process of root's (pkexec) is beyond reach."""
    try:
        os.kill(pid, signal.SIGSTOP)
    except OSError:
        return
    kids, tree, todo = _children(), [pid], [pid]
    while todo:
        for child in kids.get(todo.pop(), ()):
            tree.append(child)
            todo.append(child)
    for p in tree:
        try:
            os.kill(p, signal.SIGKILL)
        except OSError:
            pass


def root_owned(path):
    """True when only root can change the file at PATH: it, and every folder above it, belongs to root and no
    group or other user can write to it. A copy in your home folder (`cm --install`, a git clone) is not: any
    program you run could edit it and wait for the next password you type."""
    p = os.path.realpath(path)
    if not os.path.isfile(p):
        return False
    while True:
        try:
            st = os.stat(p)
        except OSError:
            return False
        if st.st_uid != 0 or st.st_mode & 0o022:
            return False
        parent = os.path.dirname(p)
        if parent == p:
            return True
        p = parent


class Run(Gio.Cancellable):
    """One engine run: cancel() kills it and what it started at once; stop() asks it to end early and still
    report (a scan then lists the items it got to)."""
    proc = None
    stderr = ()  # the last STDERR_LINES lines the engine wrote to stderr
    command = ""  # the engine command: scan, clean, large …
    writes = False  # it changes something on the disk (WRITING)

    def stop(self):
        if self.proc and not self.is_cancelled():
            self.proc.send_signal(signal.SIGTERM)

    def kill(self):
        """End the engine and its children (cancel() does this too)."""
        pid = self.proc and self.proc.get_identifier()
        if pid:
            kill_tree(int(pid))


class Engine:
    """Runs `cleanmate.sh --json …` and streams its events."""

    def __init__(self, path, dry_run=False, env=None):
        self.path = os.path.abspath(path)
        self.dry_run = dry_run
        self.env = env or {}  # extra environment variables for the engine (the self-test's own HOME)
        self.live = set()  # the runs that haven't ended yet
        self.root_ok = None  # pkexec may run this engine (root_owned); None = not checked yet

    def can_ask_password(self):
        """Whether a command can run as root through pkexec: only root's own copy of the engine (the package's
        /usr/bin/cleanmate), or any copy when the app already runs as root."""
        if self.root_ok is None:
            self.root_ok = os.geteuid() == 0 or root_owned(self.path)
        return self.root_ok

    def writing(self):
        """The runs still changing something on the disk (cleaning, moving to the Trash, removing apps …)."""
        return [r for r in self.live if r.writes]

    def stop_all(self):
        """Kill every run still going, with what each started (the window is closing)."""
        for r in list(self.live):
            r.cancel()

    def run(self, args, on_event, on_done, as_root=False):
        """Start the engine. on_event(dict) per event, on_done(ok, exit_status) at the end.

        Returns a Run (a Gio.Cancellable) that stops it. With as_root, the command goes through pkexec (the
        standard Ubuntu password dialog), with the polkit action of its command as the first argument, so the
        dialog says what the password is for; only when can_ask_password(), else it never starts and ends with
        status NEEDS_PACKAGE. A run that fails (exit status not 0, not cancelled) sends one last event before
        on_done: {"event": "failed", "status": N, "stderr": [lines]} with the last lines the engine (or pkexec)
        wrote to stderr.
        """
        cancellable = Run()
        cancellable.command = next((a for a in args if not a.startswith("-")), "")
        cancellable.writes = cancellable.command in WRITING and "--check" not in args
        argv = ["bash", self.path, "--json"]
        if as_root:
            if not self.can_ask_password() or cancellable.command not in POLKIT_ACTIONS:
                GLib.idle_add(on_event, {"event": "failed", "status": NEEDS_PACKAGE, "stderr": []})
                GLib.idle_add(on_done, False, NEEDS_PACKAGE)
                return cancellable
            # pkexec from the engine's PATH (the self-test's stub), else the system's; the real path, which the
            # policy names (/usr/bin/cleanmate, not the cm link)
            argv = [shutil.which("pkexec", path=self.env.get("PATH")) or "pkexec", os.path.realpath(self.path),
                    f"--polkit={POLKIT_ACTIONS[cancellable.command]}", "--json"]
        if self.dry_run:
            argv.append("--dry-run")
        argv += list(args)
        try:
            launcher = Gio.SubprocessLauncher.new(
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            )
            for key, value in self.env.items():
                launcher.setenv(key, value, True)
            proc = launcher.spawnv(argv)
        except GLib.Error as e:
            GLib.idle_add(on_event, {"event": "error", "message": e.message, "code": "engine_failed",
                                     "args": {"detail": e.message}})
            GLib.idle_add(on_event, {"event": "failed", "status": -1, "stderr": [e.message]})
            GLib.idle_add(on_done, False, -1)
            return cancellable
        stream = Gio.DataInputStream.new(proc.get_stdout_pipe())
        errors = Gio.DataInputStream.new(proc.get_stderr_pipe())
        tail = deque(maxlen=STDERR_LINES)
        cancellable.proc = proc
        cancellable.stderr = tail
        cancellable.connect(lambda *_: cancellable.kill())
        self.live.add(cancellable)
        # stderr is read on its own: a child the engine left running may hold it open, so the run ends with
        # stdout and the exit, and waits for the rest of stderr only briefly
        err_cancel = Gio.Cancellable()
        cancellable.connect(lambda *_: err_cancel.cancel())
        state = {"stderr_open": True, "exited": None}

        def end():
            if state["exited"] is None:
                return
            status, state["exited"] = state["exited"], None
            self.live.discard(cancellable)
            err_cancel.cancel()
            if status != 0 and not cancellable.is_cancelled():
                on_event({"event": "failed", "status": status, "stderr": list(tail)})
            on_done(status == 0, status)

        def finished(p, result):
            try:
                p.wait_finish(result)
            except GLib.Error:
                pass
            state["exited"] = p.get_exit_status() if p.get_if_exited() else -1
            if not state["stderr_open"] or state["exited"] == 0:
                end()
            else:
                GLib.timeout_add(STDERR_GRACE_MS, lambda: end() and False)

        def got_error_line(s, result):  # bytes: a stray non-UTF-8 line must not stop the reading (and the engine)
            try:
                line, _len = s.read_line_finish(result)
            except GLib.Error:
                line = None
            if line is None:
                state["stderr_open"] = False
                end()
                return
            text = bytes(line).decode("utf-8", "replace").rstrip()
            if text.strip():
                tail.append(text)
            s.read_line_async(GLib.PRIORITY_DEFAULT, err_cancel, got_error_line)

        def got_line(s, result):
            try:
                line, _len = s.read_line_finish_utf8(result)
            except GLib.Error:
                line = None
            if line is None:  # end of output
                proc.wait_async(None, finished)
                return
            line = line.strip()
            if line:
                try:
                    on_event(json.loads(line))
                except ValueError:
                    pass  # never trust a stray line to be JSON
            s.read_line_async(GLib.PRIORITY_DEFAULT, cancellable, got_line)

        stream.read_line_async(GLib.PRIORITY_DEFAULT, cancellable, got_line)
        errors.read_line_async(GLib.PRIORITY_DEFAULT, err_cancel, got_error_line)
        return cancellable

    # ── convenience wrappers ──
    def scan(self, categories, on_event, on_done):
        """Scan these categories; None = Smart Scan, which leaves out the groups turned off in Settings."""
        only = ["--only", ",".join(categories)] if categories is not None else []
        return self.run([*only, "scan"], on_event, on_done)

    def group_on(self, group):
        """False when Settings › Scan groups turned GROUP off (read from the engine's settings file)."""
        config = self.env.get("XDG_CONFIG_HOME") or (os.path.join(self.env["HOME"], ".config")
                                                      if "HOME" in self.env else None)
        return saved_setting(f"group_{group}", config) != "0"

    def details(self, item_id, on_event, on_done):
        return self.run(["details", item_id], on_event, on_done)

    def clean(self, ids, on_event, on_done, as_root=False, entries=None):
        """Clean these items; with entries (IDs from `details` "entry" events), only those parts of one item."""
        extra = ["--entries", ",".join(entries)] if entries else []
        return self.run(["clean", *ids, *extra], on_event, on_done, as_root=as_root)

    def large(self, min_bytes, days, folder, on_event, on_done, all_drives=False):
        """The biggest files in folder; all_drives: the drives mounted inside it too."""
        return self.run(["large", "--min", str(min_bytes), "--days", str(days), "--path", folder,
                         *(["--all-drives"] if all_drives else [])], on_event, on_done)

    def dupes(self, min_bytes, folder, on_event, on_done):
        return self.run(["dupes", "--min", str(min_bytes), "--path", folder], on_event, on_done)

    def lens(self, folder, on_event, on_done):
        return self.run(["lens", "--path", folder], on_event, on_done)

    def places(self, on_event, on_done):
        """Where Space Lens can start: home, the system disk, each disk mounted ("place" events)."""
        return self.run(["places"], on_event, on_done)

    def trash(self, paths, on_event, on_done, home_only=False, source=None):
        """Move paths to the Trash; source names the page for `restore --list`."""
        args = ["trash", *(["--home-only"] if home_only else []), *(["--source", source] if source else [])]
        return self.run([*args, *paths], on_event, on_done)

    def restore(self, names, on_event, on_done):
        return self.run(["restore", *names], on_event, on_done)

    def startup(self, on_event, on_done):
        return self.run(["startup"], on_event, on_done)

    def startup_set(self, unit_id, action, on_event, on_done):
        return self.run(["startup-set", unit_id, action], on_event, on_done)

    def settings(self, on_event, on_done):
        return self.run(["settings"], on_event, on_done)

    def settings_set(self, key, value, on_event, on_done):
        """VALUE is a string, or a list for settings that take more (exclusions add|remove PATH)."""
        values = value if isinstance(value, list) else [value]
        return self.run(["settings-set", key, *values], on_event, on_done)

    def activity(self, on_event, on_done, limit=1000):
        return self.run(["activity", "--limit", str(limit)], on_event, on_done)

    def apps(self, on_event, on_done):
        return self.run(["apps"], on_event, on_done)

    def uninstall(self, ids, on_event, on_done, check=False, as_root=False):
        return self.run(["uninstall", *(["--check"] if check else []), *ids], on_event, on_done, as_root=as_root)

    def reset(self, app_id, on_event, on_done, check=False, folders=()):
        """Keep the app, move its data in your home (or these folders of it) to the Trash; check = only list them."""
        return self.run(["reset", *(["--check"] if check else []), app_id, *folders], on_event, on_done)

    def maintenance(self, on_event, on_done):
        return self.run(["maintenance"], on_event, on_done)

    def maintain(self, item_id, on_event, on_done, mode=None, user_steps=False, as_root=False):
        """Run one maintenance item; mode on/off for the lasting limits, user_steps = only the steps run as you."""
        extra = ([mode] if mode else []) + (["--user-steps"] if user_steps else [])
        return self.run(["maintain", item_id, *extra], on_event, on_done, as_root=as_root)

    def overview(self, on_event, on_done):
        return self.run(["overview"], on_event, on_done)

    def check(self, kinds, on_event, on_done):
        """Low disk alert / scan reminder: the engine sends the desktop notification itself."""
        return self.run(["check", *kinds], on_event, on_done)

    def version(self):
        """The engine's VERSION, read from the script: `--version` also gathers the system details."""
        try:
            with open(self.path, encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith('VERSION="'):
                        return line.split('"')[1]
        except OSError:
            pass
        return "?"


class Selection:
    """Remembered choices, shared with the terminal app
    (~/.config/cleanmate/selection, lines of `id=0|1`)."""

    def __init__(self):
        base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
        self.path = os.path.join(base, "cleanmate", "selection")

    def _read(self):
        prefs = {}
        try:
            with open(self.path, encoding="utf-8") as f:
                for line in f:
                    k, _sep, v = line.strip().partition("=")
                    if k and v in ("0", "1"):
                        prefs[k] = v
        except OSError:
            pass
        return prefs

    def remember(self, item_id, selected):
        prefs = self._read()
        prefs[item_id] = "1" if selected else "0"
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.writelines(f"{k}={v}\n" for k, v in sorted(prefs.items()))
        os.replace(tmp, self.path)
