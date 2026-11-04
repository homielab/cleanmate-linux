"""Maintenance: updates, package repair, TRIM, font cache, locate, and two lasting limits — the terminal
app's Maintenance menu as a page.

The engine lists the items with their state (`--json maintenance`) and runs one (`--json maintain ID
[on|off]`), streaming each step and its output into a log dialog. Steps that need root run through pkexec
(one password per item); the others run as you, after the root part (`--user-steps`).
"""
import os

from gi.repository import Adw, GLib, Gtk, Pango

from . import findbar
from .engine import NEEDS_PACKAGE, PACKAGE_HINT, PACKAGE_NEEDED
from .findbar import FindBar
from .i18n import _, ngettext
from . import messages
from .rows import plain_row

# id → (title, description, icon); the engine's English labels are the fallback
TEXTS = {
    "update": (_("Update everything"), _("Upgrade apt, snap and flatpak packages"),
               "software-update-available-symbolic"),
    "repair": (_("Repair packages"), _("Finish interrupted installs, fix broken dependencies"),
               "emblem-system-symbolic"),
    "flatpak_unused": (_("Unused Flatpak runtimes"), _("Remove runtimes no installed app uses"),
                       "application-x-addon-symbolic"),
    "fstrim": (_("TRIM SSDs"), _("Tell SSDs which blocks are free (fstrim)"), "drive-harddisk-solidstate-symbolic"),
    "free_ram": (_("Free up RAM"), _("Drop the page cache — Linux reclaims it anyway"), "view-refresh-symbolic"),
    "fonts": (_("Rebuild font cache"), _("Fix missing or stale fonts (fc-cache)"), "font-x-generic-symbolic"),
    "locate": (_("Update locate database"), _("Refresh the index used by locate"), "system-search-symbolic"),
    "snap_versions": (_("Keep fewer snap versions"), _("Keep 2 versions of each snap instead of 3"),
                      "view-list-symbolic"),
    "journal_limit": (_("Limit journal size"), _("Never let system logs grow past a size"), "text-x-generic-symbolic"),
}
MISSING = messages.maint_missing()
LOG_LINES = 5000  # the dialog keeps the last lines of a long apt upgrade


def title_of(m):
    return TEXTS.get(m["id"], (m["label"],))[0]


class LogDialog(Adw.Dialog):
    """The output of one run, live; it can only be closed once the run is over."""

    def __init__(self, title):
        super().__init__(title=title, content_width=680, content_height=460, can_close=False)
        self.spinner = Gtk.Spinner(spinning=True)
        self.status = Gtk.Label(label=_("Working…"), xalign=0, hexpand=True, wrap=True)
        top = Gtk.Box(spacing=12, margin_start=12, margin_end=12, margin_top=6, margin_bottom=6)
        top.append(self.spinner)
        top.append(self.status)
        self.view = Gtk.TextView(editable=False, cursor_visible=False, monospace=True,
                                 wrap_mode=Gtk.WrapMode.WORD_CHAR, top_margin=8, bottom_margin=8,
                                 left_margin=12, right_margin=12)
        self.buffer = self.view.get_buffer()
        self.buffer.create_tag("step", weight=Pango.Weight.BOLD)
        self.buffer.create_tag("result", foreground="gray")
        self.end = self.buffer.create_mark("end", self.buffer.get_end_iter(), False)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.append(top)
        box.append(Gtk.ScrolledWindow(child=self.view, vexpand=True, css_classes=["card"],
                                      margin_start=12, margin_end=12, margin_bottom=12))
        view = Adw.ToolbarView(content=box)
        view.add_top_bar(Adw.HeaderBar())
        self.set_child(view)

    def add(self, text, tag=None):
        it = self.buffer.get_end_iter()
        if tag:
            self.buffer.insert_with_tags_by_name(it, text + "\n", tag)
        else:
            self.buffer.insert(it, text + "\n")
        extra = self.buffer.get_line_count() - LOG_LINES
        if extra > 0:
            self.buffer.delete(self.buffer.get_start_iter(), self.buffer.get_iter_at_line(extra)[1])
        self.view.scroll_to_mark(self.end, 0, False, 0, 1)

    def text(self):
        return self.buffer.get_text(self.buffer.get_start_iter(), self.buffer.get_end_iter(), False)

    def finish(self, summary):
        self.spinner.set_spinning(False)
        self.spinner.set_visible(False)
        self.status.set_text(summary)
        self.set_can_close(True)


class MaintenancePage(Gtk.Box):
    """One row per item with a Run button; the two lasting limits have a switch."""

    def __init__(self, window, title, icon, description):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self.engine = window.engine
        self.title, self.description = title, description
        self.items = {}  # id → "maint" event
        self.rows = {}  # id → Adw.ActionRow
        self.controls = {}  # id → its Run button or switch
        self.syncing = False  # a switch moved by the page, not by you
        self.busy = False  # an item runs (or the list loads)
        self.running = None  # Gio.Cancellable of the current engine run
        self.log = None  # LogDialog of the last run
        self.last_toast = None

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True)
        self.append(self.stack)
        spinner = Gtk.Spinner(spinning=True, width_request=32, height_request=32, halign=Gtk.Align.CENTER)
        self.stack.add_named(Adw.StatusPage(icon_name=icon, title=title, description=description, child=spinner),
                             "loading")
        self.failed = Adw.StatusPage(icon_name="dialog-warning-symbolic", title=_("Can't list the maintenance tasks"))
        self.stack.add_named(self.failed, "failed")
        self.results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24,
                               margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        self.find_bar = FindBar(self.apply_filter, _("Search tasks"))
        results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        results.append(self.find_bar)
        results.append(Gtk.ScrolledWindow(child=Adw.Clamp(maximum_size=900, child=self.results),
                                          vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER))
        self.stack.add_named(results, "results")
        self.load()

    # ── loading ──
    def reload(self):
        if not self.busy:
            self.load()

    def load(self):
        items, info = [], {}
        if not self.items:
            self.stack.set_visible_child_name("loading")
        self.busy = True
        self.window.set_busy(True)

        def on_event(e):
            if e["event"] == "maint":
                items.append(e)
            elif e["event"] == "error":
                info.update(e)

        def on_done(ok, status):
            self.running, self.busy = None, False
            self.window.set_busy(False)
            if info or not items:
                self.failed.set_description(GLib.markup_escape_text(messages.text(info)))
                self.stack.set_visible_child_name("failed")
                return
            self.show_results(items)

        self.running = self.engine.maintenance(on_event, on_done)

    # ── results ──
    def show_results(self, items):
        child = self.results.get_first_child()
        while child:
            self.results.remove(child)
            child = self.results.get_first_child()
        self.items = {m["id"]: m for m in items}
        self.rows.clear()
        self.controls.clear()

        header = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        header.append(Gtk.Label(label=self.title, xalign=0, wrap=True, css_classes=["title-1"]))
        header.append(Gtk.Label(label=self.description, xalign=0, wrap=True, css_classes=["dim-label"]))
        self.results.append(header)
        tasks = Adw.PreferencesGroup(title=_("Tasks"))
        limits = Adw.PreferencesGroup(title=_("Lasting limits"),
                                      description=_("So the same junk doesn't pile up again after a clean."))
        for m in items:
            (limits if m["toggle"] else tasks).add(self.item_row(m))
        self.results.append(tasks)
        self.results.append(limits)
        self.stack.set_visible_child_name("results")
        self.apply_filter()

    def find(self):
        """Ctrl+F: show only the rows whose name or description has every word typed."""
        if self.stack.get_visible_child_name() == "results":
            self.find_bar.open()

    def apply_filter(self):
        words = self.find_bar.words()
        for key, row in self.rows.items():
            row.set_visible(findbar.matches(words, row.get_title(), row.get_subtitle(), key))

    def held(self, m):
        """The item has steps that need root and this copy of the engine can't ask for the password (not
        installed from a package); a dry run needs no root."""
        return m["root"] and not self.engine.dry_run and not self.engine.can_ask_password()

    def subtitle(self, m):
        if not m["available"]:
            return MISSING.get(m["id"], m["reason"])
        if self.held(m):
            return PACKAGE_NEEDED
        if m["id"] == "snap_versions":
            if m["on"]:
                return _("On: 2 versions of each snap are kept. Turn off to go back to snapd's default.")
            if m["value"]:
                return _("Keep 2 versions of each snap instead of {now}").format(now=m["value"])
        if m["id"] == "journal_limit":
            if m["on"]:
                return _("On: system logs stay under {mb} MB").format(mb=m["value"])
            return _("Never let system logs grow past {mb} MB (Settings → Journal size limit)").format(mb=m["target"])
        return TEXTS.get(m["id"], (None, m["description"]))[1]

    def item_row(self, m):
        title, _desc, icon = TEXTS.get(m["id"], (m["label"], m["description"], "emblem-system-symbolic"))
        row = plain_row(Adw.ActionRow, title=title, subtitle=self.subtitle(m), css_classes=["item-row"])
        row.add_prefix(Gtk.Image(icon_name=icon, pixel_size=24))
        usable = m["available"] and not self.held(m)
        if not m["available"]:
            row.add_suffix(Gtk.Image(icon_name="changes-prevent-symbolic", tooltip_text=MISSING.get(m["id"], m["reason"]),
                                     css_classes=["dim-label"]))
        elif not usable:
            row.add_suffix(Gtk.Image(icon_name="changes-prevent-symbolic", tooltip_text=PACKAGE_HINT,
                                     css_classes=["warning"]))
        elif m["root"]:
            row.add_suffix(Gtk.Image(icon_name="system-lock-screen-symbolic", tooltip_text=_("Needs your password"),
                                     css_classes=["dim-label"]))
        if m["toggle"]:
            if m["id"] == "journal_limit" and m["on"] and m["value"] != m["target"]:
                use = Gtk.Button(label=_("Use {mb} MB").format(mb=m["target"]), valign=Gtk.Align.CENTER,
                                 sensitive=usable,
                                 tooltip_text=_("The limit set in Settings → Journal size limit"))
                use.connect("clicked", lambda *_a: self.start(m, "on"))
                row.add_suffix(use)
            control = Gtk.Switch(active=m["on"], valign=Gtk.Align.CENTER, sensitive=usable)
            control.connect("notify::active", self.on_switched, m)
        else:
            control = Gtk.Button(label=_("Run"), valign=Gtk.Align.CENTER, sensitive=usable)
            control.connect("clicked", lambda *_a: self.confirm(m) if m["id"] == "update" else self.start(m))
        row.add_suffix(control)
        if usable:
            row.set_activatable_widget(control)
        self.rows[m["id"]] = row
        self.controls[m["id"]] = control
        return row

    def set_switch(self, item_id, active):
        switch = self.controls.get(item_id)
        if isinstance(switch, Gtk.Switch):
            self.syncing = True
            switch.set_active(active)
            self.syncing = False

    def on_switched(self, switch, _pspec, m):
        if self.syncing:
            return
        if self.busy:  # one run at a time
            return self.set_switch(m["id"], m["on"])
        self.start(m, "on" if switch.get_active() else "off")

    # ── running ──
    def confirm(self, m):
        dialog = Adw.AlertDialog(
            heading=_("Update everything?"),
            body=_("Upgrades your apt packages, snaps and flatpaks. It needs your password once and can take "
                   "a while; you can watch it in the log."))
        dialog.add_response("cancel", _("Cancel"))
        dialog.add_response("run", _("Update"))
        dialog.set_response_appearance("run", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("run")
        dialog.set_close_response("cancel")
        dialog.connect("response", lambda d, r: r == "run" and self.start(m))
        dialog.present(self.window)

    def start(self, m, mode=None):
        """Run one item: the root steps through pkexec (not in a dry run, which changes nothing), then yours."""
        if self.busy:
            return
        self.busy = True
        self.results.set_sensitive(False)
        self.window.set_busy(True)
        title = title_of(m)
        dry = self.engine.dry_run
        parts = [(False, False)]  # (as_root, user_steps)
        if m["root"] and not dry:  # yours after the root part; as root there are none (the engine refuses them)
            parts = [(True, False)] + ([(False, True)] if m["user"] and os.geteuid() != 0 else [])
        counts = {"ok": 0, "failed": 0, "skipped": 0}
        state = {"cancelled": False, "error": None}
        log = self.log = LogDialog(title)
        log.present(self.window)

        def on_event(e):
            ev = e["event"]
            if ev == "task":
                if e["state"] == "run":
                    log.add("▸ " + e["label"], "step")
                else:
                    mark = {"ok": "✔", "skip": "–"}.get(e["state"], "✘")
                    log.add(f"{mark} {messages.text(e)}", "result")
            elif ev == "log":
                log.add(e["line"])
            elif ev == "error":
                state["error"] = messages.text(e)
                log.add("✘ " + messages.text(e), "result")
            elif ev == "done":
                for k in counts:
                    counts[k] += e.get(k, 0)

        def run_part(i):
            as_root, user_steps = parts[i]
            if as_root:
                log.status.set_text(_("Waiting for your password…"))
            else:
                log.status.set_text(_("Working…"))
            self.running = self.engine.maintain(m["id"], on_event, lambda ok, status: part_done(i, status),
                                                mode=mode, user_steps=user_steps, as_root=as_root)

        def part_done(i, status):
            if parts[i][0] and status == NEEDS_PACKAGE:  # this copy can't ask for the password
                state["error"] = PACKAGE_NEEDED
                return finish()
            if parts[i][0] and status in (126, 127):  # password dialog dismissed / not authorized
                state["cancelled"] = True
                return finish()
            if i + 1 < len(parts) and not state["error"]:
                return run_part(i + 1)
            finish()

        def finish():
            self.running, self.busy = None, False
            self.window.set_busy(False)
            self.results.set_sensitive(True)
            if state["cancelled"]:
                msg = _("{title}: no password was entered, nothing was changed").format(title=title)
            elif state["error"]:
                msg = f"{title}: {state['error']}"
            elif counts["failed"]:
                msg = ngettext("{title}: {n} step failed — see the log", "{title}: {n} steps failed — see the log",
                               counts["failed"], title=title)
            elif dry:
                msg = _("Dry run: {title} — nothing was changed").format(title=title)
            else:
                msg = _("{title}: done").format(title=title)
            log.finish(msg)
            self.last_toast = self.window.toast(msg, timeout=6)
            self.window.refresh_disk()
            self.load()  # the limits show what is in effect now

        run_part(0)
