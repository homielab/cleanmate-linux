"""The app's own log of errors: `~/.cache/cleanmate/gui.log` (in a Flatpak, the app's cache folder).

It holds this session and the previous one, is capped in size, leaves out your home folder and user name, and
is never sent anywhere: Report a Bug… can copy it. Nothing here raises: a log that can't be written is skipped.
"""
import os
import re
import sys
import threading
import time
import traceback

from gi.repository import GLib

MAX_BYTES = 256 * 1024  # per session
CRASH_LINES = 30  # lines of a traceback the error dialog shows
_file = None
_written = 0


def log_path():
    return os.path.join(GLib.get_user_cache_dir(), "cleanmate", "gui.log")


def channel(engine_path):
    """How CleanMate was installed, as far as the environment tells."""
    if os.environ.get("FLATPAK_ID"):
        return "flatpak"
    if os.environ.get("SNAP"):
        return "snap"
    if os.environ.get("APPIMAGE"):
        return "appimage"
    real = os.path.realpath(engine_path)
    if real.startswith("/usr/"):
        return "package"
    if real.startswith(os.path.expanduser("~/.local/")):
        return "cm --install"
    return "source"


def engine_version(engine_path):
    try:
        with open(engine_path, encoding="utf-8", errors="replace") as f:
            for _n, line in zip(range(200), f):
                found = re.match(r'VERSION="([0-9.]+)"', line)
                if found:
                    return found.group(1)
    except OSError:
        pass
    return "?"


def start(engine_path):
    """Begin this session's log; the previous one is kept as gui.log.1."""
    global _file, _written
    try:
        path = log_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.exists(path):
            os.replace(path, path + ".1")
        _file = open(path, "w", encoding="utf-8", buffering=1)
        _written = 0
    except OSError:
        _file = None
        return
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
    from gi.repository import Adw, Gtk
    v = sys.version_info
    write(f"CleanMate {engine_version(engine_path)} ({channel(engine_path)}), Python {v[0]}.{v[1]}.{v[2]}, "
          f"GTK {Gtk.get_major_version()}.{Gtk.get_minor_version()}.{Gtk.get_micro_version()}, "
          f"libadwaita {Adw.get_major_version()}.{Adw.get_minor_version()}.{Adw.get_micro_version()}")


def write(text):
    """Append TEXT with the time, without the home folder or user name."""
    global _written
    if _file is None or _written > MAX_BYTES:
        return
    try:
        from .errorview import redact
        line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {redact(text)}\n"
        _file.write(line)
        _written += len(line.encode("utf-8"))
        if _written > MAX_BYTES:
            _file.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} log full: nothing more is recorded this session\n")
    except (OSError, ValueError):
        pass


def exception(where, error):
    write(f"{where}:\n" + "".join(traceback.format_exception(type(error), error, error.__traceback__)))


def read(limit=20000):
    """The previous session's log and this one's, the last LIMIT characters; "" when there is none."""
    try:
        if _file is not None:
            _file.flush()
    except (OSError, ValueError):
        pass
    parts = []
    path = log_path()
    for name, title in ((path + ".1", "--- previous session ---"), (path, "--- this session ---")):
        try:
            with open(name, encoding="utf-8", errors="replace") as f:
                parts.append(f"{title}\n{f.read()}")
        except OSError:
            pass
    return "\n".join(parts)[-limit:]


def crashed(app, error):
    """Show the error dialog once per error (same type and place)."""
    try:
        frames = traceback.extract_tb(error.__traceback__)
        key = (type(error).__name__, frames[-1].filename, frames[-1].lineno) if frames else (type(error).__name__, "", 0)
        if key in app.crash_seen:
            return
        app.crash_seen.add(key)

        def show():
            try:
                from . import errorview
                win = app.window
                if win is not None and getattr(win, "crash_dialog", None) is None:
                    text = "".join(traceback.format_exception(type(error), error, error.__traceback__))
                    details = errorview.redact("\n".join(text.splitlines()[-CRASH_LINES:]))
                    errorview.show_crash(win, details)
            except Exception as problem:
                write(f"showing the error dialog failed: {problem!r}")
            return False

        GLib.idle_add(show)
    except Exception as problem:
        write(f"recording an error failed: {problem!r}")


def install(app):
    """Log every uncaught error (main loop, signal handlers, threads) and show one dialog per error."""

    def hook(etype, error, tb):
        try:
            if issubclass(etype, KeyboardInterrupt):
                sys.__excepthook__(etype, error, tb)
                return
            sys.__excepthook__(etype, error, tb)
            exception("uncaught error", error)
            crashed(app, error)
        except Exception:
            pass

    def thread_hook(args):
        if args.exc_type is SystemExit:
            return
        GLib.idle_add(lambda: hook(args.exc_type, args.exc_value, args.exc_traceback) and False)

    sys.excepthook = hook
    threading.excepthook = thread_hook
