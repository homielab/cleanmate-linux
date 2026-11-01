"""Settings: language, low disk alert, scan reminder, automatic cleaning, updates and how long things are kept.

These are the terminal app's settings. The engine reads them (`--json settings`) and changes them
(`--json settings-set KEY VALUE`) in the same file and systemd user timer, with the same ranges;
this page only shows them. A change is saved at once (numbers a moment after you stop typing).
"Remember recent files" is GNOME's own setting (gsettings), as in the terminal app; the activity log is
the engine's (`--json activity`). The language is the desktop app's own (the terminal app stays English); it shows after a restart.
Never clean lists the folders of `~/.config/cleanmate/exclude` (`settings-set exclusions add|remove PATH`).
The low disk alert and the scan reminder are notifications the engine sends from a daily systemd user timer
(`cleanmate-check.timer`, on while either is on) and, for the low disk alert, when the app opens.
"""
import datetime
import os

from gi.repository import Adw, Gio, GLib, Gtk

from . import i18n
from .i18n import _, ngettext

# each language by its own name, so you can find yours whatever the app is in now
LANGUAGE_TITLES = {"system": _("Same as system"), "en": "English", "vi": "Tiếng Việt"}

SCHEDULES = ["off", "daily", "weekly", "monthly"]
SCHEDULE_TITLES = {"off": _("Off"), "daily": _("Daily"), "weekly": _("Weekly"), "monthly": _("Monthly")}
REMINDERS = ["off", "weekly", "monthly"]
LOW_DISK = [0, 5, 10, 15, 20]  # % of free space; the engine takes 0–50 (the terminal app can set any)


def low_disk_title(pct):
    return _("Off") if pct == 0 else _("Below {pct} free").format(pct=f"{pct}%")


# key → (title, subtitle); the groups and order of the terminal app's Settings
NUMBERS = {
    "journal_days": (_("Journal logs"), _("Days of system logs to keep")),
    "journal_mb": (_("Journal size limit"), _("Megabytes of system logs to keep at most")),
    "log_max_mb": (_("Oversized logs"), _("Empty live logs larger than this many megabytes")),
    "app_log_days": (_("App logs"), _("Clean when not written for this many days")),
    "tmp_days": (_("Temporary files"), _("Clean when older than this many days")),
    "cache_days": (_("App caches"), _("Clean when not used for this many days")),
    "node_modules_days": (_("Project build folders"),
                          _("node_modules, Cargo target/, Python .venv/ and Pods/ of projects idle for this "
                            "many days")),
    "installer_days": (_("Old installers"), _("Offer installers in Downloads older than this many days")),
    "download_days": (_("Old downloads"), _("Offer files and folders in Downloads, and screenshots, not opened or "
                                            "changed for this many days")),
    "ai_history_days": (_("AI chat history"), _("Clean AI sessions older than this many days")),
}
KEEP_FOR = ["journal_days", "journal_mb", "log_max_mb", "app_log_days", "tmp_days", "cache_days",
            "node_modules_days", "installer_days", "download_days", "ai_history_days"]
DELAY_MS = 700  # a number is saved this long after its last change

# why the engine refuses a folder for Never clean (the other reasons name the folder and stay as they are)
EXCLUSION_REASONS = {
    "Your home folder or a folder above it is too broad to exclude":
        _("Your home folder or a folder above it is too broad to exclude"),
    "Only folders inside your home folder can be excluded": _("Only folders inside your home folder can be excluded"),
    "Folders reached through a symbolic link can't be excluded":
        _("Folders reached through a symbolic link can't be excluded"),
}


def short_path(path):
    home = GLib.get_home_dir()
    return "~" + path[len(home):] if path.startswith(home + "/") else path


class SettingsPage(Adw.PreferencesPage):
    """One row per setting; shown in a preferences dialog from the main menu."""

    def __init__(self, window):
        super().__init__(title=_("Settings"), icon_name="emblem-system-symbolic")
        self.window = window
        self.engine = window.engine
        self.settings = {}  # key → the engine's "setting" event
        self.info = {}  # the "done" or "error" event of the last load
        self.rows = {}  # key → row
        self.groups = []
        self.syncing = False  # a row moved by the page, not by you
        self.running = None  # Gio.Cancellable of the current engine run
        self.loading = False
        self.waiting = {}  # key → GLib source id: a number saved after a short pause
        self.queue = []  # (key, value) for the engine, one at a time
        self.generation = 0

        self.status = Adw.PreferencesGroup()
        self.status.add(Gtk.Spinner(spinning=True, width_request=32, height_request=32, halign=Gtk.Align.CENTER,
                                    margin_top=48))
        self.add(self.status)
        self.load()

    def busy(self):
        return self.loading or self.running is not None or bool(self.queue) or bool(self.waiting)

    # ── loading ──
    def load(self):
        if self.running:
            self.running.cancel()
            self.window.set_busy(False)
        self.generation += 1
        gen = self.generation
        settings, info = {}, {}
        self.loading = True
        self.window.set_busy(True)

        def on_event(e):
            if e["event"] == "setting":
                settings[e["key"]] = e
            elif e["event"] in ("done", "error"):
                info.update(e)

        def on_done(ok, status):
            if gen != self.generation:
                return
            self.running, self.loading = None, False
            self.window.set_busy(False)
            self.settings, self.info = settings, info
            self.build()

        self.running = self.engine.settings(on_event, on_done)

    def clear(self):
        for group in [self.status, *self.groups]:
            if group.get_parent():
                self.remove(group)
        self.groups, self.rows = [], {}

    def build(self):
        self.clear()
        if "message" in self.info or not self.settings:
            self.status = Adw.PreferencesGroup(
                title=_("Can't read your settings"),
                description=self.info.get("message") or _("The cleaning engine didn't answer."))
            self.add(self.status)
            return

        general = self.group(_("General"))
        language = Adw.ComboRow(title=_("Language"),
                                model=Gtk.StringList.new([LANGUAGE_TITLES[c] for c in i18n.LANGUAGES]))
        restart = Gtk.Button(label=_("Restart"), valign=Gtk.Align.CENTER, visible=False)
        restart.add_css_class("suggested-action")
        restart.connect("clicked", lambda *_a: self.restart())
        language.add_suffix(restart)
        language.restart_button = restart
        language.connect("notify::selected", self.on_language)
        self.rows["language"] = language
        general.add(language)

        systemd = self.info.get("systemd", True)
        values = sorted(set(LOW_DISK) | {self.settings.get("low_disk_pct", {}).get("value", 10)})
        low = Adw.ComboRow(title=_("Low disk alert"),
                           subtitle=_("A notification when the system disk is almost full. Checked daily and when "
                                      "CleanMate opens.") if systemd else
                           _("A notification when the system disk is almost full. Checked when CleanMate opens."),
                           model=Gtk.StringList.new([low_disk_title(v) for v in values]))
        low.values = values
        low.connect("notify::selected", self.on_low_disk)
        self.rows["low_disk_pct"] = low
        general.add(low)

        remind = Adw.ComboRow(title=_("Scan reminder"),
                              subtitle=_("A notification when you haven't scanned for a while. Click it to open "
                                         "CleanMate."),
                              model=Gtk.StringList.new([SCHEDULE_TITLES[r] for r in REMINDERS]))
        if not systemd:
            remind.set_sensitive(False)
            remind.set_subtitle(_("Needs systemd, which isn't available here"))
        remind.connect("notify::selected", self.on_remind)
        self.rows["remind"] = remind
        general.add(remind)

        general = self.group(_("Automatic cleaning"))
        combo = Adw.ComboRow(title=_("Automatic cleaning"),
                             subtitle=_("Runs a Smart Clean of user and developer junk and tells you what it freed"),
                             model=Gtk.StringList.new([SCHEDULE_TITLES[s] for s in SCHEDULES]))
        if not self.info.get("systemd", True):
            combo.set_sensitive(False)
            combo.set_subtitle(_("Needs systemd, which isn't available here"))
        combo.connect("notify::selected", self.on_schedule)
        self.rows["schedule"] = combo
        general.add(combo)

        updates = self.group(_("Updates"))
        check = Adw.SwitchRow(title=_("Daily update check"),
                              subtitle=_("A quiet check for a new version once a day"))
        if self.info.get("packaged"):
            check.set_sensitive(False)
            check.set_subtitle(_("Your package manager keeps CleanMate up to date"))
        check.connect("notify::active", self.on_switch, "update_check")
        self.rows["update_check"] = check
        updates.add(check)

        keep = self.group(_("Keep for"), _("What cleaning leaves alone. Smart Scan uses the new values "
                                           "on its next scan."))
        for key in KEEP_FOR:
            keep.add(self.number_row(key))

        never = self.group(_("Never clean"), _("Large & Old Files, Duplicates, Space Lens, project build folders, "
                                               "old installers and old downloads skip these folders, and nothing in "
                                               "them is moved to the Trash."))
        add = Gtk.Button(child=Adw.ButtonContent(icon_name="list-add-symbolic", label=_("Add Folder…")),
                         valign=Gtk.Align.CENTER, css_classes=["flat"])
        add.connect("clicked", lambda *_a: self.choose_exclusion())
        never.set_header_suffix(add)
        never.add_button = add
        never.folder_rows = []
        self.rows["exclusions"] = never

        data = self.group(_("Your data"))
        selections = Adw.ActionRow(title=_("Remembered selections"))
        reset = Gtk.Button(label=_("Reset"), valign=Gtk.Align.CENTER)
        reset.connect("clicked", lambda *_a: self.confirm_reset())
        selections.add_suffix(reset)
        selections.reset_button = reset
        self.rows["selections"] = selections
        data.add(selections)

        recent = Adw.SwitchRow(title=_("Remember recent files"),
                               subtitle=_("Files and Open dialogs list the files you used lately"))
        if "recent_files" not in self.settings:
            recent.set_sensitive(False)
            recent.set_subtitle(_("Needs GNOME's gsettings, which isn't available here"))
        recent.connect("notify::active", self.on_switch, "recent_files")
        self.rows["recent_files"] = recent
        data.add(recent)

        activity = Adw.ActionRow(title=_("Activity log"), subtitle=_("What was cleaned and when"),
                                 activatable=True)
        activity.add_suffix(Gtk.Image(icon_name="go-next-symbolic"))
        activity.connect("activated", lambda *_a: self.show_activity())
        self.rows["activity"] = activity
        data.add(activity)

        for key in self.settings:
            self.show_value(key)

    def group(self, title, description=None):
        group = Adw.PreferencesGroup(title=title, description=description)
        self.add(group)
        self.groups.append(group)
        return group

    def number_row(self, key):
        s = self.settings[key]
        title, subtitle = NUMBERS[key]
        row = Adw.SpinRow(title=title, subtitle=subtitle, numeric=True, climb_rate=1,
                          adjustment=Gtk.Adjustment(lower=s["min"], upper=s["max"], step_increment=1,
                                                    page_increment=10, value=s["value"]))
        row.set_tooltip_text(_("From {min} to {max}, default {default}").format(
            min=s["min"], max=s["max"], default=s["default"]))
        row.connect("notify::value", self.on_number, key)
        self.rows[key] = row
        return row

    def show_value(self, key):
        """Put the engine's value of KEY into its row, unless you changed it again meanwhile."""
        s, row = self.settings.get(key), self.rows.get(key)
        if not s or not row or key in self.waiting or any(k == key for k, _v in self.queue):
            return
        self.syncing = True
        if key == "schedule":
            row.set_selected(SCHEDULES.index(s["value"]) if s["value"] in SCHEDULES else 0)
        elif key == "remind":
            row.set_selected(REMINDERS.index(s["value"]) if s["value"] in REMINDERS else 0)
        elif key == "low_disk_pct":
            if s["value"] not in row.values:  # set in the terminal app
                row.values = sorted(set(row.values) | {s["value"]})
                row.set_model(Gtk.StringList.new([low_disk_title(v) for v in row.values]))
            row.set_selected(row.values.index(s["value"]))
        elif key == "language":
            value = s["value"] if s["value"] in i18n.LANGUAGES else "system"
            row.set_selected(i18n.LANGUAGES.index(value))
            pending = value != i18n.AT_LAUNCH  # saved, not shown yet
            row.restart_button.set_visible(pending)
            row.set_subtitle(_("Restart CleanMate to use the new language. The system's language does not change.")
                             if pending else "")
        elif key in ("update_check", "recent_files"):
            row.set_active(bool(s["value"]))
        elif key == "exclusions":
            for old in row.folder_rows:
                row.remove(old)
            row.folder_rows = [self.exclusion_row(path) for path in s["value"]] or [
                Adw.ActionRow(title=_("No folders yet"), css_classes=["dim-label"])]
            for new in row.folder_rows:
                row.add(new)
        elif key == "selections":
            row.set_subtitle(ngettext("{n} remembered choice for Smart Scan", "{n} remembered choices for Smart Scan",
                                      s["value"]))
            row.reset_button.set_sensitive(s["value"] > 0)
        else:
            row.set_value(s["value"])
        self.syncing = False

    # ── changes ──
    def on_schedule(self, row, _pspec):
        if not self.syncing:
            self.change("schedule", SCHEDULES[row.get_selected()])

    def on_remind(self, row, _pspec):
        if not self.syncing:
            self.change("remind", REMINDERS[row.get_selected()])

    def on_low_disk(self, row, _pspec):
        if not self.syncing:
            self.change("low_disk_pct", str(row.values[row.get_selected()]))

    def on_language(self, row, _pspec):
        if not self.syncing:
            self.change("language", i18n.LANGUAGES[row.get_selected()])

    def restart(self):
        """Open CleanMate again in the saved language, once every change is saved."""
        self.flush()
        self.rows["language"].restart_button.set_sensitive(False)

        def when_saved():
            if self.busy():
                return True
            self.window.get_application().restart()
            return False

        GLib.timeout_add(100, when_saved)

    def on_switch(self, row, _pspec, key):
        if not self.syncing:
            self.change(key, "1" if row.get_active() else "0")

    def on_number(self, row, _pspec, key):
        if self.syncing:
            return
        if key in self.waiting:
            GLib.source_remove(self.waiting[key])

        def save():
            del self.waiting[key]
            self.change(key, str(int(row.get_value())))
            return False

        self.waiting[key] = GLib.timeout_add(DELAY_MS, save)

    def flush(self):
        """Save the numbers still waiting for their pause (the dialog is closing)."""
        for key, source in list(self.waiting.items()):
            GLib.source_remove(source)
            del self.waiting[key]
            self.change(key, str(int(self.rows[key].get_value())))

    def exclusion_row(self, path):
        row = Adw.ActionRow(title=os.path.basename(path), subtitle=short_path(path), use_markup=False,
                            tooltip_text=path)
        row.add_prefix(Gtk.Image(icon_name="folder-symbolic"))
        remove = Gtk.Button(icon_name="list-remove-symbolic", valign=Gtk.Align.CENTER, css_classes=["flat"],
                            tooltip_text=_("Remove from the list"))
        remove.connect("clicked", lambda *_a: self.change_exclusion("remove", path))
        row.add_suffix(remove)
        row.path, row.remove_button = path, remove
        return row

    def choose_exclusion(self):
        dialog = Gtk.FileDialog(title=_("Folder to never clean"),
                                initial_folder=Gio.File.new_for_path(GLib.get_home_dir()))

        def chosen(d, result):
            try:
                folder = d.select_folder_finish(result)
            except GLib.Error:
                return  # cancelled
            if folder and folder.get_path():
                self.change_exclusion("add", folder.get_path())

        dialog.select_folder(self.get_root(), None, chosen)

    def change_exclusion(self, action, path):
        """Add or remove a Never clean folder; each change is its own engine run, in order."""
        self.queue.append(("exclusions", [action, path]))
        self.next_change()

    def change(self, key, value):
        self.queue = [(k, v) for k, v in self.queue if k != key] + [(key, value)]
        self.next_change()

    def next_change(self):
        if self.running or self.loading or not self.queue:
            return
        key, value = self.queue.pop(0)
        result = {}

        def on_event(e):
            if e["event"] == "setting":
                self.settings[e["key"]] = e
            elif e["event"] in ("task", "error"):
                result.update(e)

        def on_done(ok, status):
            self.running = None
            self.window.set_busy(False)
            if result.get("state") != "ok":
                reason = result.get("info") or result.get("message", "")
                self.toast(_("Could not change it: {reason}").format(reason=EXCLUSION_REASONS.get(reason, reason)))
            elif self.engine.dry_run:
                self.toast(_("Dry run: nothing was saved"))
            elif key == "schedule":
                self.toast(_("Automatic cleaning: {when}").format(when=SCHEDULE_TITLES[value])
                           if value != "off" else _("Automatic cleaning is off"))
            elif key == "remind":
                self.toast(_("Scan reminder: {when}").format(when=SCHEDULE_TITLES[value])
                           if value != "off" else _("Scan reminder is off"))
            elif key == "low_disk_pct":
                self.toast(_("Low disk alert below {pct} free").format(pct=f"{value}%")
                           if value != "0" else _("Low disk alert is off"))
            elif key == "selections":
                self.toast(_("Smart Scan is back to its default choices"))
            elif key == "exclusions":
                folder = short_path(value[1])
                self.toast(_("{folder} is never cleaned now").format(folder=folder) if value[0] == "add"
                           else _("{folder} can be cleaned again").format(folder=folder))
            self.show_value(key)
            self.next_change()

        self.window.set_busy(True)
        self.running = self.engine.settings_set(key, value, on_event, on_done)

    def confirm_reset(self):
        dialog = Adw.AlertDialog(heading=_("Forget remembered selections?"),
                                 body=_("Smart Scan goes back to its default choices."))
        dialog.add_response("cancel", _("Cancel"))
        dialog.add_response("reset", _("Reset"))
        dialog.set_response_appearance("reset", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.set_close_response("cancel")
        dialog.connect("response", lambda d, r: r == "reset" and self.change("selections", "reset"))
        dialog.present(self)

    # ── activity log ──
    def show_activity(self):
        """The engine's activity log, newest first, as a sub-page of the dialog."""
        self.activity = ActivityPage(self)
        dialog = self.get_ancestor(Adw.PreferencesDialog)
        if dialog:
            dialog.push_subpage(self.activity)
        return self.activity

    def toast(self, text):
        dialog = self.get_ancestor(Adw.PreferencesDialog)
        if dialog:
            dialog.add_toast(Adw.Toast(title=GLib.markup_escape_text(text)))
        else:
            self.window.toast(text)


class ActivityPage(Adw.NavigationPage):
    """What the terminal app shows under Settings › Activity log: every line, newest first."""

    def __init__(self, settings):
        super().__init__(title=_("Activity log"))
        self.settings = settings
        self.lines = []  # (epoch, text)
        self.path = None
        self.loading = True
        self.stack = Gtk.Stack()
        self.stack.add_named(Adw.StatusPage(title=_("Reading the log…"),
                                            child=Gtk.Spinner(spinning=True, width_request=32, height_request=32,
                                                              halign=Gtk.Align.CENTER)), "loading")
        self.empty = Adw.StatusPage(icon_name="document-open-recent-symbolic", title=_("Nothing yet"),
                                    description=_("Nothing has been cleaned yet."))
        self.stack.add_named(self.empty, "empty")
        self.list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE, css_classes=["boxed-list"],
                                margin_start=12, margin_end=12, margin_top=12, margin_bottom=12)
        self.stack.add_named(Gtk.ScrolledWindow(child=Adw.Clamp(child=self.list), vexpand=True), "list")

        self.folder = Gtk.Button(icon_name="folder-open-symbolic", tooltip_text=_("Open the log folder"),
                                 sensitive=False)
        self.folder.connect("clicked", lambda *_a: self.open_folder())
        header = Adw.HeaderBar()
        header.pack_end(self.folder)
        view = Adw.ToolbarView(content=self.stack)
        view.add_top_bar(header)
        self.set_child(view)

        def on_event(e):
            if e["event"] == "activity":
                self.lines.append((e["epoch"], e["text"]))
            elif e["event"] == "done":
                self.path = e.get("path")

        self.settings.engine.activity(on_event, self.loaded)

    def loaded(self, ok, status):
        self.loading = False
        for epoch, text in self.lines:
            when = datetime.datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M") if epoch else ""
            row = Adw.ActionRow(title=GLib.markup_escape_text(text), subtitle=when, title_lines=3)
            self.list.append(row)
        self.stack.set_visible_child_name("list" if self.lines else "empty")
        self.folder.set_sensitive(bool(self.path) and os.path.isdir(os.path.dirname(self.path)))

    def open_folder(self):
        Gtk.FileLauncher.new(Gio.File.new_for_path(os.path.dirname(self.path))).launch(
            self.get_root(), None, None)
