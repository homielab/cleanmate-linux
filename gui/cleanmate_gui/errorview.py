"""What a page shows when the engine failed, instead of an empty result.

A run that ends with an error (an exit status that isn't 0) and no answer is never "nothing found": the page
says what went wrong, shows the engine's last lines, and offers Try Again, Copy Details and Report a Bug….
The details leave out your home folder and user name, like the system details of Report a Bug….
"""
import getpass
import os
import re

from gi.repository import Adw, Gtk

from . import bugreport
from .engine import PKEXEC_DISMISSED, PKEXEC_REFUSED
from .i18n import _


def redact(text, home=None, user=None):
    """TEXT without the home folder (→ ~), other users' folders or the user name."""
    home = (home or os.path.expanduser("~")).rstrip("/")
    if len(home) > 1:
        text = text.replace(home + "/", "~/")
        text = re.sub(re.escape(home) + r"\b", "~", text)
    text = re.sub(r"/(home|media|run/media)/[^/\s]+", r"/\1/user", text)
    try:
        user = user or getpass.getuser()
    except (KeyError, OSError):
        user = ""
    if len(user) >= 3:
        text = re.sub(rf"\b{re.escape(user)}\b", "user", text)
    return text


class Failure:
    """What an engine run said about failing: its "error" message and the "failed" event (exit status and the
    last lines of stderr). Feed every event to see(); failed is True once the run ended with an error."""

    def __init__(self, what, home=None):
        self.what = what  # the command, for the details ("cm --json large")
        self.home = home
        self.message = ""
        self.status = None
        self.stderr = []

    def see(self, e):
        if e.get("event") == "error":
            self.message = e.get("message") or ""
        elif e.get("event") == "failed":
            self.status = e.get("status")
            self.stderr = list(e.get("stderr") or [])

    @property
    def failed(self):
        return self.status is not None

    def reason(self):
        """One line for the page: the engine's own message, else its last line on stderr, else the exit status."""
        line = self.message or (self.stderr[-1] if self.stderr else "")
        if line:
            return redact(line, self.home)
        if self.status == -1:
            return _("The engine stopped unexpectedly.")
        return _("The engine stopped with exit status {n}.").format(n=self.status)

    def details(self):
        """The text Copy Details and Report a Bug… use."""
        lines = [f"{self.what}: exit status {self.status}"]
        if self.message:
            lines.append(f"error: {self.message}")
        if self.stderr:
            lines += ["", "stderr (last lines):", *self.stderr]
        return redact("\n".join(lines), self.home)


def pkexec_reason(status, stderr):
    """Why a run through pkexec did nothing: None when it ran (its own result counts), else the text for the rows."""
    text = "\n".join(stderr or ())
    if status == PKEXEC_DISMISSED:
        return _("Skipped — no password was entered")
    if status == PKEXEC_REFUSED:
        if "authentication agent" in text.lower():
            return _("Skipped — no password dialog could open (no polkit authentication agent is running)")
        return _("Skipped — no password was entered")
    return None


def last_line(stderr, status, home=None):
    """The engine's last line on stderr, for a row that failed; the exit status when it wrote nothing."""
    for line in reversed(stderr or ()):
        if line.strip():
            return redact(line.strip(), home)
    return _("The engine stopped with exit status {n}.").format(n=status)


class ErrorPage(Gtk.Box):
    """Something went wrong: the reason, Try Again, Copy Details, Report a Bug… and the details below.
    A box around an Adw.StatusPage, which can't be subclassed."""

    def __init__(self, window, retry, title=None):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.status = Adw.StatusPage(icon_name="dialog-error-symbolic", title=title or _("Something went wrong"),
                                     vexpand=True)
        self.append(self.status)
        self.window = window
        self.failure = None
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18, halign=Gtk.Align.CENTER)
        buttons = Gtk.Box(spacing=12, halign=Gtk.Align.CENTER)
        again = Gtk.Button(label=_("Try Again"), css_classes=["pill", "suggested-action"])
        again.connect("clicked", lambda *_a: retry())
        self.copy_button = Gtk.Button(label=_("Copy Details"), css_classes=["pill"])
        self.copy_button.connect("clicked", lambda *_a: self.copy())
        self.report_button = Gtk.Button(label=_("Report a Bug…"), css_classes=["pill"])
        self.report_button.connect("clicked", lambda *_a: self.report())
        for button in (again, self.copy_button, self.report_button):
            buttons.append(button)
        box.append(buttons)
        self.text = Gtk.Label(xalign=0, wrap=True, selectable=True, css_classes=["monospace", "caption"],
                              margin_top=6, margin_bottom=6, margin_start=6, margin_end=6)
        self.expander = Gtk.Expander(label=_("Details"), child=Gtk.ScrolledWindow(
            child=self.text, max_content_height=220, propagate_natural_height=True, min_content_width=420,
            hscrollbar_policy=Gtk.PolicyType.NEVER))
        box.append(self.expander)
        self.status.set_child(box)

    def get_description(self):
        return self.status.get_description()

    def show(self, failure):
        self.failure = failure
        self.status.set_description(failure.reason())
        self.text.set_label(failure.details())

    def copy(self):
        bugreport.copy(self.window, self.failure.details())
        self.window.toast(_("Details copied"))

    def report(self):
        bugreport.report_bug(self.window, extra=self.failure.details())
