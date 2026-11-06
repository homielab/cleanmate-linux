"""Application entry point."""
import argparse
import os
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, Gtk  # noqa: E402

from . import messages, welcome  # noqa: E402
from .engine import Engine  # noqa: E402
from .i18n import _  # noqa: E402

APP_ID = "com.homielab.CleanMate"

CSS = """
.size-large  { color: @error_color; }
.size-medium { color: @warning_color; }
.size-small  { color: @success_color; }
levelbar block.filled { background-color: @accent_bg_color; }
levelbar.almost-full block.filled { background-color: @warning_bg_color; }
checkbutton.big-check check { min-width: 24px; min-height: 24px; }
row.item-row { min-height: 48px; }
.keep-badge { background-color: alpha(@accent_bg_color, 0.18); color: @accent_color; border-radius: 99px;
              padding: 2px 10px; font-weight: bold; font-size: smaller; }
.welcome-dot { background-color: alpha(@window_fg_color, 0.3); border-radius: 99px;
               min-width: 7px; min-height: 7px; }
.welcome-dot.active { background-color: @accent_bg_color; }
"""


class App(Adw.Application):
    """One CleanMate at a time: opening it again brings its window to the front (GApplication over D-Bus).
    The self-test and the screenshots run beside it."""

    def __init__(self, engine, selftest=False):
        super().__init__(application_id=APP_ID,
                         flags=Gio.ApplicationFlags.NON_UNIQUE if selftest else Gio.ApplicationFlags.DEFAULT_FLAGS)
        self.engine = engine
        self.selftest = selftest
        self.window = None
        self.next_argv = None  # started once this one has quit (restart)

    def do_startup(self):
        Adw.Application.do_startup(self)
        Gtk.Window.set_default_icon_name(APP_ID)  # installed by `cm --install`
        settings = Gtk.Settings.get_default()
        if settings.get_property("gtk-xft-dpi") <= 0:  # headless displays report no DPI
            settings.set_property("gtk-xft-dpi", 96 * 1024)
        provider = Gtk.CssProvider()
        provider.load_from_string(CSS)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        quit_action = Gio.SimpleAction(name="quit")
        quit_action.connect("activate", lambda *_: self.close_windows())
        self.add_action(quit_action)
        self.set_accels_for_action("app.quit", ["<Control>q"])

    def do_shutdown(self):
        self.engine.stop_all()  # whatever way it quits, no engine run goes on without the app
        Adw.Application.do_shutdown(self)

    @staticmethod
    def relaunch_argv():
        """The command that started this app (`cm --gui` runs `python3 …/cleanmate-gui --engine …`)."""
        return [sys.executable or "/usr/bin/python3", os.path.abspath(sys.argv[0]), *sys.argv[1:]]

    def close_windows(self):
        """Ctrl+Q: close the window, so a clean still going asks first; quit when there is none."""
        if not self.get_windows():
            self.quit()
        for win in self.get_windows():
            win.close()

    def spawn(self, argv):
        """Started after this one ends (main): started now, it would find this one and only raise its window."""
        self.next_argv = argv

    def restart(self):
        """Start a new CleanMate with the same arguments and quit this one (a new language shows)."""
        self.spawn(self.relaunch_argv())
        self.quit()

    def check_disk(self, engine=None, on_done=None):
        """The low disk alert: the engine decides (below Settings › Low disk alert, once a day at most) and the
        app sends it, so it also reaches you where the engine's notify-send can't (the Flatpak, a system
        without libnotify-bin)."""
        return (engine or self.engine).check(["low_disk"], self.on_check, on_done or (lambda ok, status: None))

    def on_check(self, e):
        note = e.get("notify") if e.get("event") == "check" else None
        if not note:
            return
        try:
            title, body = messages.notification(note.get("code"), note.get("args") or {})
        except (KeyError, TypeError, ValueError):
            title, body = note.get("title") or "CleanMate", note.get("body") or ""
        notification = Gio.Notification.new(title)
        notification.set_body(body)
        notification.set_icon(Gio.ThemedIcon.new(note.get("icon") or "dialog-warning"))
        if note.get("urgency") == "critical":
            notification.set_priority(Gio.NotificationPriority.URGENT)
        self.send_notification(f"check-{e.get('kind', 'alert')}", notification)

    def do_activate(self):
        if self.window is not None:  # opened again (a second `cm --gui`, the app icon): this window comes up
            self.window.present()
            return
        from .window import Window
        win = Window(self, self.engine)
        self.window = win
        win.connect("destroy", lambda *_a: setattr(self, "window", None))
        if getattr(self, "window_size", None):
            win.set_default_size(*self.window_size)
        if not self.selftest:  # the self-test and the screenshots always start on System Overview
            win.restore_state()
        win.present()
        if self.selftest:
            from .selftest import run
            run(self, win)
        elif os.geteuid() != 0:  # root has no settings: no low disk alert or welcome to save
            self.check_disk()  # in the background; no scan reminder while you have the app open
            if welcome.is_new():
                win.show_welcome(first_run=True)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="cleanmate --gui")
    parser.add_argument("--engine", default=os.environ.get("CLEANMATE_ENGINE"),
                        help="path to cleanmate.sh")
    parser.add_argument("--dry-run", action="store_true", help="show what would happen, delete nothing")
    parser.add_argument("--selftest", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--screenshot", metavar="PNG", help=argparse.SUPPRESS)
    parser.add_argument("--scene", default="results", help=argparse.SUPPRESS)  # results details confirm done privacy ai large uninstall lens duplicates startup settings
    parser.add_argument("--window-size", default="", help=argparse.SUPPRESS)  # e.g. 1280x800
    args = parser.parse_args(argv)
    engine_path = args.engine or os.path.join(os.path.dirname(__file__), "..", "..", "cleanmate.sh")
    if not os.path.isfile(engine_path):
        print(_("Engine not found: {path}").format(path=engine_path), file=sys.stderr)
        return 2
    app = App(Engine(engine_path, dry_run=args.dry_run), selftest=args.selftest or bool(args.screenshot))
    app.selftest_failed = False
    app.screenshot = args.screenshot
    app.scene = args.scene
    app.window_size = tuple(int(x) for x in args.window_size.split("x")) if args.window_size else None
    status = app.run([sys.argv[0]])
    if app.next_argv:  # a restart: this process becomes the new CleanMate (its D-Bus name is free by then)
        os.execv(app.next_argv[0], app.next_argv)
    return 1 if app.selftest_failed else status
