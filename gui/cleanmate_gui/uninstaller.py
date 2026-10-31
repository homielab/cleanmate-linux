"""Uninstaller: your apps (apt, Snap, Flatpak, AppImage) with the folders they leave in your home.

The engine lists the apps (`--json apps`, parts of Ubuntu are never listed),
checks and removes them (`--json uninstall`: several at once, apt and Snap
through one pkexec, Flatpak and AppImage as you, running apps skipped; an
AppImage, its launcher and icon go to the Trash) and moves the chosen leftover folders
to the Trash (`--json trash`) once the app is gone. Reset keeps one app and moves its data
in your home to the Trash (`--json reset`: listed first, refused while it runs). Folders of apps removed earlier (`leftover` events) are a group of
their own at the end, never ticked. This page only shows them and keeps the choice.
"""
import os
import re
import time
from urllib.parse import unquote

from gi.repository import Adw, Gio, GLib, Gtk, Pango

from .engine import human
from .i18n import _, ngettext
from .largefiles import short_path
from .scanpage import size_widgets

SORTS = [(_("Size"), "size"), (_("Last used"), "used"), (_("Name"), "name")]
UNUSED = [(_("All apps"), 0), (_("Unused for 1+ month"), 1), (_("Unused for 3+ months"), 3),
          (_("Unused for 6+ months"), 6), (_("Unused for 12+ months"), 12)]
KIND_LABELS = {"apt": "apt", "snap": "Snap", "flatpak": "Flatpak", "appimage": "AppImage"}
USER_KINDS = ("flatpak", "appimage")  # removed as you; apt and Snap need your password
LEFTOVER_REASONS = {"flatpak": _("This Flatpak app is no longer installed"),
                    "snap": _("This snap is no longer installed")}


def unused_visible(app, months, show_undated, now=None):
    """Whether an app passes the "unused for N months" filter (0 = all apps).
    Apps without a last-used date are unknown, not unused: only shown when asked."""
    if not months:
        return True
    if not app["last_used"]:
        return show_undated
    return (now or time.time()) - app["last_used"] >= months * 30 * 86400


def used_ago(epoch):
    if not epoch:
        return _("last use unknown")
    days = int((time.time() - epoch) // 86400)
    if days < 1:
        return _("used today")
    if days < 60:
        return ngettext("used {n} day ago", "used {n} days ago", days)
    if days < 730:
        return ngettext("used {n} month ago", "used {n} months ago", days // 30)
    return ngettext("used {n} year ago", "used {n} years ago", days // 365)


def running_text(program):
    return _("Skipped: {program} is running — close it and try again").format(program=program)


def app_icon(desktop_id):
    try:
        info = Gio.DesktopAppInfo.new(desktop_id + ".desktop") if desktop_id else None
    except TypeError:
        info = None
    icon = info.get_icon() if info else None
    return Gtk.Image(gicon=icon, pixel_size=32) if icon else \
        Gtk.Image(icon_name="application-x-executable-symbolic", pixel_size=32)


class UninstallerPage(Gtk.Box):
    """Search and sort on top; apps below, each with its leftover folders as ticked sub-rows."""

    def __init__(self, window, title, icon, description):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self.engine = window.engine
        self.apps = {}  # id → app event
        self.hidden = 0
        self.orphans = []  # leftover events: folders of apps removed earlier
        self.orphan_selected = set()  # their paths
        self.orphan_checks = {}  # path → Gtk.CheckButton
        self.orphan_rows = {}  # path → its row
        self.orphan_button = None
        self.selected = set()  # app ids
        self.left_selected = set()  # leftover paths (only used for selected apps)
        self.checks = {}  # app id → Gtk.CheckButton
        self.left_checks = {}  # path → Gtk.CheckButton
        self.rows = {}  # app id → its row (filtered by the search)
        self.all_check = None  # ticks every app shown: none / some (inconsistent) / all
        self.syncing = False  # the page moves the boxes itself: don't react
        self.bulk = False  # many boxes change at once: update the summary once at the end
        self.batch_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)  # the selected apps, when more than one
        self.batch_rows = {}  # app id → its row in that panel
        self.running = None
        self.busy = False  # listing, checking or uninstalling: nothing else starts
        self.undo_toast = None
        self.show_undated = False  # reveal apps without a date under an "unused" filter

        self.search_entry = Gtk.SearchEntry(placeholder_text=_("Search apps"), hexpand=True)
        self.search_entry.connect("search-changed", lambda *_: self.apply_filter())
        self.sort_drop = Gtk.DropDown.new_from_strings([label for label, _ in SORTS])
        self.sort_drop.set_tooltip_text(_("Sort by"))
        self.sort_drop.connect("notify::selected", lambda *_: self.apps and self.show_results())
        top = Gtk.Box(spacing=12, margin_top=12, margin_bottom=12, margin_start=12, margin_end=12)
        self.unused_drop = Gtk.DropDown.new_from_strings([label for label, _ in UNUSED])
        self.unused_drop.set_tooltip_text(_("Filter by last use"))
        self.unused_drop.connect("notify::selected", self.on_unused_changed)
        top.append(self.search_entry)
        top.append(self.unused_drop)
        top.append(self.sort_drop)
        self.append(top)
        self.append(Gtk.Separator())

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True)
        self.append(self.stack)
        spinner = Gtk.Spinner(spinning=True, width_request=32, height_request=32, halign=Gtk.Align.CENTER)
        self.stack.add_named(Adw.StatusPage(icon_name=icon, title=_("Finding your apps…"),
                                            description=_("And the space each one uses."), child=spinner), "loading")
        self.empty = Adw.StatusPage(icon_name="emblem-ok-symbolic", title=_("No apps found"),
                                    description=_("Only apps with a launcher are listed."))
        self.stack.add_named(self.empty, "empty")
        self.results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24,
                               margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        self.stack.add_named(Gtk.ScrolledWindow(child=Adw.Clamp(maximum_size=900, child=self.results),
                                                vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER), "results")
        self.work_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE, css_classes=["boxed-list"])
        self.work_title = Gtk.Label(css_classes=["title-2"], xalign=0, wrap=True)
        wbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18,
                       margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        wbox.append(self.work_title)
        wbox.append(self.work_list)
        self.stack.add_named(Gtk.ScrolledWindow(child=Adw.Clamp(maximum_size=900, child=wbox), vexpand=True),
                             "working")

        self.bar = Gtk.ActionBar(revealed=False)
        self.summary = Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.END)
        self.bar.pack_start(self.summary)
        self.remove_button = Gtk.Button(label=_("Uninstall"), css_classes=["destructive-action"])
        self.remove_button.set_tooltip_text(_("Asks once, and for your password once for all apt and Snap apps"))
        self.remove_button.connect("clicked", lambda *_: self.check())
        self.bar.pack_end(self.remove_button)
        self.reset_button = Gtk.Button(label=_("Reset…"))
        self.reset_button.set_tooltip_text(_("Keeps the app and moves its data in your home to the Trash, "
                                             "so it starts as if new. Select one app."))
        self.reset_button.connect("clicked", lambda *_: self.reset_check())
        self.bar.pack_end(self.reset_button)
        again = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text=_("List apps again"))
        again.connect("clicked", lambda *_: self.load())
        self.bar.pack_end(again)
        self.append(self.bar)
        self.load()

    # ── listing ──
    def reload(self):
        self.load()  # no-op while busy

    def load(self):
        if self.busy:
            return
        self.busy = True
        apps, info, orphans = {}, {}, []
        self.stack.set_visible_child_name("loading")
        self.bar.set_revealed(False)
        self.window.set_busy(True)

        def on_event(e):
            if e["event"] == "app":
                apps[e["id"]] = e
            elif e["event"] == "leftover":
                orphans.append(e)
            elif e["event"] in ("done", "error"):
                info.update(e)

        def on_done(ok, status):
            self.running, self.busy = None, False
            self.window.set_busy(False)
            if "message" in info:
                self.window.toast(info["message"])
            self.apps, self.hidden, self.orphans = apps, info.get("hidden", 0), orphans
            self.selected &= set(apps)
            self.orphan_selected &= {o["path"] for o in orphans}
            self.show_results()

        self.running = self.engine.apps(on_event, on_done)

    def sorted_apps(self):
        how = SORTS[self.sort_drop.get_selected()][1]
        apps = list(self.apps.values())
        if how == "used":  # least recently used first; never opened at the end
            return sorted(apps, key=lambda a: (a["last_used"] == 0, a["last_used"], a["name"].lower()))
        if how == "name":
            return sorted(apps, key=lambda a: a["name"].lower())
        return sorted(apps, key=lambda a: -(a["bytes"] + a["data_bytes"]))

    def show_results(self):
        child = self.results.get_first_child()
        while child:
            self.results.remove(child)
            child = self.results.get_first_child()
        self.checks.clear()
        self.left_checks.clear()
        self.rows.clear()
        self.all_check = None
        self.orphan_checks.clear()
        self.orphan_rows.clear()
        if not self.apps and not self.orphans:
            self.stack.set_visible_child_name("empty")
            self.bar.set_revealed(False)
            return
        total = sum(a["bytes"] + a["data_bytes"] for a in self.apps.values())
        header = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        header.append(Gtk.Label(label=ngettext("{n} app · {size}", "{n} apps · {size}", len(self.apps), size=human(total)),
                                xalign=0, wrap=True,
                                css_classes=["title-1"]))
        sub = _("Size = the app + its folders in your home.")
        if self.hidden:
            sub += " " + ngettext("{n} part of Ubuntu itself can't be removed safely and isn't listed.",
                                  "{n} parts of Ubuntu itself can't be removed safely and aren't listed.", self.hidden)
        header.append(Gtk.Label(label=sub, xalign=0, wrap=True, css_classes=["dim-label"]))
        self.results.append(header)
        if self.batch_box.get_parent():
            self.batch_box.get_parent().remove(self.batch_box)
        self.results.append(self.batch_box)
        if self.apps:
            group = Adw.PreferencesGroup(title=_("Apps"))
            self.all_check = Gtk.CheckButton(label=_("All shown"), valign=Gtk.Align.CENTER, css_classes=["big-check"],
                                             tooltip_text=_("Select or deselect every app the list shows"))
            self.all_check.connect("toggled", self.on_all_toggled)
            group.set_header_suffix(self.all_check)
            biggest = max(a["bytes"] + a["data_bytes"] for a in self.apps.values())
            for a in self.sorted_apps():
                row = self.app_row(a, biggest)
                self.rows[a["id"]] = row
                group.add(row)
            self.results.append(group)
            self.undated_button = Gtk.Button(halign=Gtk.Align.START, css_classes=["flat"])
            self.undated_button.connect("clicked", self.on_show_undated)
            self.results.append(self.undated_button)
        if self.orphans:
            self.results.append(self.orphan_group())
        self.stack.set_visible_child_name("results")
        self.bar.set_revealed(True)
        self.apply_filter()
        self.update_summary()

    def app_row(self, a, biggest):
        kind = KIND_LABELS.get(a["kind"], a["kind"])
        package = a["id"].split(":", 1)[1]
        subtitle = " · ".join(x for x in (kind, used_ago(a["last_used"])) if x)
        if a["kind"] == "appimage":
            tip = _("AppImage file {path}\nApp {size} · your data {data}").format(
                path=short_path(unquote(package)), size=human(a["bytes"]), data=human(a["data_bytes"]))
        else:
            tip = _("{kind} package {package}\nApp {size} · your data {data}").format(
                kind=kind, package=package, size=human(a["bytes"]), data=human(a["data_bytes"]))
        if a["kind"] not in USER_KINDS:
            tip += "\n" + _("Needs your password")
        if a["leftovers"]:
            row = Adw.ExpanderRow(title=a["name"], subtitle=subtitle, use_markup=False, tooltip_text=tip,
                                  css_classes=["item-row"])
        else:
            row = Adw.ActionRow(title=a["name"], subtitle=subtitle, use_markup=False, tooltip_text=tip,
                                css_classes=["item-row"])
        check = Gtk.CheckButton(active=a["id"] in self.selected, valign=Gtk.Align.CENTER, css_classes=["big-check"])
        check.connect("toggled", self.on_app_toggled, a["id"])
        self.checks[a["id"]] = check
        prefixes = [check, app_icon(a["desktop"])]  # the box first, then the icon
        suffixes = list(size_widgets(a["bytes"] + a["data_bytes"], biggest))
        if isinstance(row, Adw.ActionRow):  # an ActionRow stacks both leftwards, an ExpanderRow rightwards
            prefixes.reverse()
            row.set_activatable_widget(check)
        else:
            suffixes.reverse()
        for widget in prefixes:
            row.add_prefix(widget)
        for widget in suffixes:
            row.add_suffix(widget)
        for left in a["leftovers"]:
            row.add_row(self.leftover_row(a, left))
        return row

    def leftover_row(self, a, left):
        path = left["path"]
        row = Adw.ActionRow(title=short_path(path), subtitle=_("Moved to the Trash after uninstalling"),
                            use_markup=False, title_lines=1, css_classes=["item-row"])
        check = Gtk.CheckButton(active=path in self.left_selected, valign=Gtk.Align.CENTER,
                                css_classes=["big-check"], sensitive=a["id"] in self.selected,
                                tooltip_text=_("Also move this folder to the Trash"))
        check.connect("toggled", self.on_left_toggled, path)
        self.left_checks[path] = check
        row.add_prefix(Gtk.Image(icon_name="folder-symbolic"))
        row.add_prefix(check)
        row.set_activatable_widget(check)
        row.add_suffix(Gtk.Label(label=human(left["bytes"]), width_chars=9, xalign=1,
                                 css_classes=["numeric", "dim-label"]))
        return row

    def orphan_group(self):
        """Leftovers of removed apps: one unticked row per folder, and a Move to Trash button."""
        group = Adw.PreferencesGroup(
            title=_("Leftovers of removed apps"),
            description=_("Folders in your home that no installed app uses. Nothing is ticked; "
                          "they go to the Trash, so you can put them back."))
        self.orphan_button = Gtk.Button(label=_("Move to Trash"), valign=Gtk.Align.CENTER,
                                        css_classes=["destructive-action"])
        self.orphan_button.connect("clicked", lambda *_: self.trash_orphans())
        group.set_header_suffix(self.orphan_button)
        biggest = max(o["bytes"] for o in self.orphans)
        for o in self.orphans:
            path = o["path"]
            row = Adw.ActionRow(title=short_path(path), use_markup=False, title_lines=1, css_classes=["item-row"],
                                subtitle=LEFTOVER_REASONS.get(o["kind"], _("No app with this name is installed")),
                                tooltip_text=path)
            check = Gtk.CheckButton(active=path in self.orphan_selected, valign=Gtk.Align.CENTER,
                                    css_classes=["big-check"])
            check.connect("toggled", self.on_orphan_toggled, path)
            self.orphan_checks[path] = check
            row.add_prefix(Gtk.Image(icon_name="folder-symbolic", pixel_size=32))
            row.add_prefix(check)
            row.set_activatable_widget(check)
            for widget in size_widgets(o["bytes"], biggest):
                row.add_suffix(widget)
            self.orphan_rows[path] = row
            group.add(row)
        self.update_orphan_button()
        return group

    def on_orphan_toggled(self, check, path):
        if check.get_active():
            self.orphan_selected.add(path)
        else:
            self.orphan_selected.discard(path)
        self.update_orphan_button()

    def update_orphan_button(self):
        if not self.orphan_button:
            return
        chosen = [o for o in self.orphans if o["path"] in self.orphan_selected]
        size = sum(o["bytes"] for o in chosen)
        self.orphan_button.set_label(_("Move {size} to Trash").format(size=human(size)) if chosen else _("Move to Trash"))
        self.orphan_button.set_sensitive(bool(chosen) and not self.busy)

    def trash_orphans(self):
        paths = [o["path"] for o in self.orphans if o["path"] in self.orphan_selected]
        if not paths or self.busy:
            return
        self.busy = True
        self.orphan_button.set_sensitive(False)
        self.window.set_busy(True)
        moved, done, failed = {}, [], []

        def on_event(e):
            if e["event"] == "error":
                failed.append(e["message"])
            elif e["event"] == "task" and e["state"] == "ok":
                done.append(e["id"])
                if e["trash"]:
                    moved[e["trash"]] = e["id"]
            elif e["event"] == "task":
                failed.append(f"{short_path(e['id'])}: {e['info']}")

        def on_done(ok, status):
            self.running, self.busy = None, False
            self.window.set_busy(False)
            self.orphan_selected -= set(done)
            if failed:
                self.window.toast(failed[0], timeout=8)
            elif self.engine.dry_run:
                self.window.toast(ngettext("Dry run: {n} folder would be moved to the Trash",
                                           "Dry run: {n} folders would be moved to the Trash", len(done)))
            if moved:
                msg = ngettext("Moved {n} folder to the Trash", "Moved {n} folders to the Trash", len(done))
                self.undo_toast = self.window.toast(msg, _("Undo"), lambda: self.restore(moved), timeout=10)
                self.window.refresh_disk()
            self.load()

        self.running = self.engine.trash(paths, on_event, on_done, home_only=True)

    def apply_filter(self):
        q = self.search_entry.get_text().strip().lower()
        months = UNUSED[self.unused_drop.get_selected()][1]
        now = time.time()
        undated = 0
        for app_id, row in self.rows.items():
            a = self.apps[app_id]
            match = not q or q in a["name"].lower() or q in app_id.lower()
            if months and not a["last_used"] and match:
                undated += 1
            row.set_visible(match and unused_visible(a, months, self.show_undated, now))
        hide = bool(months and undated and not self.show_undated)
        if self.rows:
            self.undated_button.set_visible(hide)
            self.undated_button.set_label(ngettext(
                "{n} app has no last-used date — Show", "{n} apps have no last-used date — Show", undated))
        for path, row in self.orphan_rows.items():
            row.set_visible(not q or q in os.path.basename(path).lower())
        self.sync_all_check()

    def shown_ids(self):
        return [i for i, row in self.rows.items() if row.get_visible()]

    def sync_all_check(self):
        """The box above the list follows the apps shown: none / some (inconsistent) / all."""
        if not self.all_check:
            return
        shown = self.shown_ids()
        n = sum(1 for i in shown if i in self.selected)
        self.syncing = True
        self.all_check.set_sensitive(bool(shown) and not self.busy)
        self.all_check.set_inconsistent(0 < n < len(shown))
        self.all_check.set_active(bool(shown) and n == len(shown))
        self.syncing = False

    def on_all_toggled(self, check):
        if self.syncing:
            return
        target = check.get_active()  # read once: each app re-syncs the box
        self.bulk = True
        for i in self.shown_ids():  # apps the search or filter hides keep their tick
            self.checks[i].set_active(target)
        self.bulk = False
        self.update_summary()

    def on_unused_changed(self, *_args):
        self.show_undated = False
        if self.apps:
            self.apply_filter()

    def on_show_undated(self, *_args):
        self.show_undated = True
        self.apply_filter()

    def on_app_toggled(self, check, app_id):
        on = check.get_active()
        if on:
            self.selected.add(app_id)
        else:
            self.selected.discard(app_id)
        for left in self.apps[app_id]["leftovers"]:  # its folders follow the app
            box = self.left_checks.get(left["path"])
            if box:
                box.set_sensitive(on)
                box.set_active(on)
        if not self.bulk:
            self.update_summary()

    def on_left_toggled(self, check, path):
        if check.get_active():
            self.left_selected.add(path)
        else:
            self.left_selected.discard(path)
        if not self.bulk:
            self.update_summary()

    def chosen(self):
        apps = [a for a in self.sorted_apps() if a["id"] in self.selected]  # in the list's order
        folders = [l for a in apps for l in a["leftovers"] if l["path"] in self.left_selected]
        return apps, folders

    def update_summary(self):
        apps, folders = self.chosen()
        size = sum(a["bytes"] for a in apps) + sum(l["bytes"] for l in folders)
        text = ngettext("Selected <b>{size}</b> in {n} app", "Selected <b>{size}</b> in {n} apps", len(apps),
                        size=human(size))
        if folders:
            text += " + " + ngettext("{n} folder", "{n} folders", len(folders))
        self.summary.set_markup(text)
        self.remove_button.set_label(ngettext("Uninstall {n} app…", "Uninstall {n} apps…", len(apps))
                                     if len(apps) > 1 else _("Uninstall"))
        self.remove_button.set_sensitive(bool(apps) and not self.busy)
        self.reset_button.set_sensitive(len(apps) == 1 and not self.busy)
        self.sync_all_check()
        self.update_batch(apps)

    def update_batch(self, apps):
        """More than one app ticked: a panel at the top with each one, its size and its folders,
        also those the search or filter hides."""
        child = self.batch_box.get_first_child()
        while child:
            self.batch_box.remove(child)
            child = self.batch_box.get_first_child()
        self.batch_rows.clear()
        if len(apps) < 2:
            return
        apps = sorted(apps, key=lambda a: a["name"].lower())
        sizes = {a["id"]: a["bytes"] + sum(l["bytes"] for l in a["leftovers"] if l["path"] in self.left_selected)
                 for a in apps}
        group = Adw.PreferencesGroup(
            title=ngettext("{n} app selected", "{n} apps selected", len(apps)),
            description=_("Removed together: one confirmation, and your password once for apt and Snap apps."))
        biggest = max(sizes.values()) or 1
        for a in apps:
            folders = [l for l in a["leftovers"] if l["path"] in self.left_selected]
            if folders:
                note = ngettext("{n} folder to the Trash", "{n} folders to the Trash", len(folders))
            elif a["leftovers"]:
                note = _("folders kept")
            else:
                note = _("no folders in your home")
            row = Adw.ActionRow(title=a["name"], use_markup=False, css_classes=["item-row"],
                                subtitle=" · ".join((KIND_LABELS.get(a["kind"], a["kind"]), note)))
            row.add_prefix(app_icon(a["desktop"]))
            for widget in size_widgets(sizes[a["id"]], biggest):
                row.add_suffix(widget)
            drop = Gtk.Button(icon_name="window-close-symbolic", valign=Gtk.Align.CENTER, css_classes=["flat"],
                              tooltip_text=_("Leave this app out"))
            drop.connect("clicked", lambda _b, i=a["id"]: self.checks[i].set_active(False))
            row.add_suffix(drop)
            group.add(row)
            self.batch_rows[a["id"]] = row
        self.batch_box.append(group)

    # ── uninstalling ──
    def check(self):
        apps, folders = self.chosen()
        if not apps or self.busy:
            return
        self.busy = True
        self.remove_button.set_sensitive(False)
        self.window.set_busy(True)
        result = {}

        def on_event(e):
            if e["event"] in ("check", "error"):
                result.update(e)

        def on_done(ok, status):
            self.running, self.busy = None, False
            self.window.set_busy(False)
            self.update_summary()
            if result.get("event") == "check" and result["ok"]:
                self.confirm(apps, folders, result)
            else:
                self.window.toast(result.get("message") or _("Couldn't check what removing these apps does."),
                                  timeout=8)

        self.running = self.engine.uninstall([a["id"] for a in apps], on_event, on_done, check=True)

    def confirm(self, apps, folders, check):
        running = {r["id"]: r["program"] for r in check.get("running", [])}
        if all(a["id"] in running for a in apps):
            self.window.toast(_("Close {names} first: apps that are running aren't removed.").format(
                names=", ".join(a["name"] for a in apps)), timeout=8)
            return
        lines = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        for a in apps[:12]:
            row = Gtk.Box(spacing=12)
            row.append(Gtk.Label(label=a["name"], xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.END))
            if a["id"] in running:
                row.append(Gtk.Label(label=_("running — skipped"), css_classes=["dim-label"]))
            elif a["kind"] not in USER_KINDS:
                row.append(Gtk.Image(icon_name="system-lock-screen-symbolic", tooltip_text=_("Needs your password")))
            row.append(Gtk.Label(label=human(a["bytes"]), css_classes=["numeric", "dim-label"]))
            lines.append(row)
        if len(apps) > 12:
            lines.append(Gtk.Label(label=_("… and {n} more").format(n=len(apps) - 12), xalign=0, css_classes=["dim-label"]))
        heading = ngettext("Uninstall {n} app?", "Uninstall {n} apps?", len(apps) - len(running))
        body = []
        if running:
            body.append(ngettext("{n} app is running and will be skipped: {names}.",
                                 "{n} apps are running and will be skipped: {names}.", len(running),
                                 names=", ".join(a["name"] for a in apps if a["id"] in running)))
        if check["extra"]:
            heading = ngettext("Also removes {n} other package!", "Also removes {n} other packages!", check["extra"])
            body.append(_("apt will also remove: {packages}.").format(packages=check["extra_text"]))
        if folders:
            body.append(ngettext("{n} folder ({size}) will go to the Trash — you can undo that.",
                                 "{n} folders ({size}) will go to the Trash — you can undo that.", len(folders),
                                 size=human(sum(l["bytes"] for l in folders))))
        else:
            body.append(_("Your folders in your home are kept."))
        if any(a["kind"] == "appimage" and a["id"] not in running for a in apps):
            body.append(_("AppImage apps go to the Trash with their launcher — you can undo that."))
        if any(a["kind"] not in USER_KINDS and a["id"] not in running for a in apps):
            body.append(_("Apps with a lock need your password, asked once for all of them."))
        dialog = Adw.AlertDialog(heading=heading, body=" ".join(body), extra_child=lines)
        dialog.add_response("cancel", _("Cancel"))
        dialog.add_response("remove", _("Uninstall"))
        dialog.set_response_appearance("remove", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.set_close_response("cancel")
        dialog.connect("response", lambda d, r: r == "remove" and self.uninstall(apps, folders, running))
        dialog.present(self.window)

    def uninstall(self, apps, folders, running=None):
        """Flatpak and AppImage apps as you, then every apt and Snap app in one engine run through pkexec
        (one password). `running` (app id → program, from the check) are skipped without asking for a password."""
        if self.busy:
            return
        self.busy = True
        dry = self.engine.dry_run
        running = running or {}
        user_ids = [a["id"] for a in apps if a["kind"] in USER_KINDS and a["id"] not in running]
        # apt and Snap need root: the standard password dialog (never in a dry run, which changes nothing)
        root_ids = [a["id"] for a in apps if a["kind"] not in USER_KINDS and a["id"] not in running]
        removed, skipped = set(), set()
        app_moved = {}  # trash name → path of the AppImage files that went to the Trash
        rows = {}
        child = self.work_list.get_first_child()
        while child:
            self.work_list.remove(child)
            child = self.work_list.get_first_child()
        for a in apps:
            row = Adw.ActionRow(title=a["name"], subtitle=_("waiting"), use_markup=False)
            row.icon = Gtk.Image(icon_name="content-loading-symbolic", css_classes=["dim-label"])
            row.add_prefix(row.icon)
            self.work_list.append(row)
            rows[a["id"]] = row
        self.sync_all_check()
        self.work_title.set_text(_("Uninstalling…"))
        self.stack.set_visible_child_name("working")
        self.bar.set_revealed(False)
        self.window.set_busy(True)

        def set_row(row, state, text):
            icon = {"ok": "emblem-ok-symbolic", "skip": "dialog-warning-symbolic"}.get(state, "dialog-error-symbolic")
            row.icon.set_from_icon_name(icon)
            row.icon.set_css_classes([{"ok": "success", "skip": "warning"}.get(state, "error")])
            row.set_subtitle(text)

        for i, program in running.items():
            if i in rows:
                set_row(rows[i], "skip", running_text(program))
                skipped.add(i)

        def on_event(e):
            if e["event"] == "error":
                self.window.toast(e["message"], timeout=8)
            if e["event"] == "trashed" and e["trash"]:
                app_moved[e["trash"]] = e["path"]
            if e["event"] != "task" or e["id"] not in rows:
                return
            if e["state"] == "run":
                rows[e["id"]].set_subtitle(_("removing…"))
                return
            info = e["info"]
            if e["state"] == "skip":  # started after the check
                skipped.add(e["id"])
                m = re.match(r"Skipped: (.+) is running", info or "")
                info = running_text(m.group(1)) if m else info
            set_row(rows[e["id"]], e["state"],
                    info or {"ok": _("removed"), "skip": _("skipped")}.get(e["state"], _("failed")))
            if e["state"] == "ok":
                removed.add(e["id"])

        def run_root():
            if not root_ids:
                return trash_leftovers()
            for i in root_ids:
                rows[i].set_subtitle(_("waiting for your password…"))
            self.running = self.engine.uninstall(root_ids, on_event, root_done, as_root=not dry)

        def root_done(ok, status):
            for i in root_ids:
                row = rows[i]
                if row.get_subtitle() in (_("waiting"), _("waiting for your password…"), _("removing…")):
                    if status in (126, 127):  # password dialog dismissed / not authorized
                        set_row(row, "skip", _("Skipped — no password was entered"))
                    else:
                        set_row(row, "fail", _("Not removed"))
            trash_leftovers()

        def trash_leftovers():
            paths = [l["path"] for a in apps if a["id"] in removed for l in a["leftovers"]
                     if l["path"] in self.left_selected]
            if not paths:
                return finish({}, 0)
            moved, done = {}, []

            def on_trash(e):
                if e["event"] == "error":
                    self.window.toast(e["message"], timeout=8)
                elif e["event"] == "task" and e["state"] == "ok":
                    done.append(e["id"])
                    if e["trash"]:
                        moved[e["trash"]] = e["id"]
                elif e["event"] == "task":
                    self.window.toast(f"{short_path(e['id'])}: {e['info']}", timeout=8)

            self.running = self.engine.trash(paths, on_trash, lambda ok, st: finish(moved, len(done)))

        def finish(moved, folders_done):
            self.running, self.busy = None, False
            self.window.set_busy(False)
            n = len(removed)
            if dry:
                msg = ngettext("Dry run: {n} app would be uninstalled", "Dry run: {n} apps would be uninstalled", n)
                if folders_done:
                    msg += ngettext(", {n} folder would be moved to the Trash",
                                    ", {n} folders would be moved to the Trash", folders_done)
            else:
                msg = ngettext("Uninstalled {n} app", "Uninstalled {n} apps", n)
                if folders_done:
                    msg += ngettext("; moved {n} folder to the Trash", "; moved {n} folders to the Trash",
                                    folders_done)
            if skipped:
                msg += ngettext("; {n} app skipped because it is running", "; {n} apps skipped because they are running",
                                len(skipped))
            self.work_title.set_text(msg)
            if app_moved:  # the AppImage files and their folders: one Restore puts them all back
                everything = {**app_moved, **moved}
                self.undo_toast = self.window.toast(msg, _("Restore"), lambda: self.restore(everything, apps=True),
                                                    timeout=10)
            elif moved:
                self.undo_toast = self.window.toast(msg, _("Restore folders"), lambda: self.restore(moved), timeout=10)
            else:
                self.window.toast(msg)
            self.window.refresh_disk()
            self.selected -= removed
            GLib.timeout_add(1500, lambda: (self.load(), False)[1])

        if user_ids:
            self.running = self.engine.uninstall(user_ids, on_event, lambda ok, st: run_root())
        else:
            run_root()

    # ── resetting ──
    def reset_check(self):
        """One app ticked: list its data in your home (the engine says whether it runs), then ask."""
        apps, _folders = self.chosen()
        if len(apps) != 1 or self.busy:
            return
        app = apps[0]
        self.busy = True
        self.update_summary()
        self.window.set_busy(True)
        data, info = [], {}

        def on_event(e):
            if e["event"] == "data":
                data.append(e)
            elif e["event"] in ("done", "error"):
                info.update(e)

        def on_done(ok, status):
            self.running, self.busy = None, False
            self.window.set_busy(False)
            self.update_summary()
            if info.get("event") != "done":
                self.window.toast(info.get("message") or _("Couldn't find the data of this app."), timeout=8)
            elif info.get("running"):
                self.window.toast(_("Close {program} first: resetting {name} while it runs can lose what is open "
                                    "in it.").format(program=info["running"], name=app["name"]), timeout=8)
            elif not data:
                self.window.toast(_("{name} keeps no data in your home: nothing to reset.").format(name=app["name"]))
            else:
                self.confirm_reset(app, data)

        self.running = self.engine.reset(app["id"], on_event, on_done, check=True)

    def confirm_reset(self, app, data):
        """Each folder with its size, all ticked; Reset moves the ticked ones to the Trash. Returns the dialog."""
        checks = []
        lines = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        dialog = Adw.AlertDialog(
            heading=_("Reset {name}?").format(name=app["name"]),
            body=_("The app stays installed. The ticked folders of its data go to the Trash, so it starts as if "
                   "new — you can put them back."),
            extra_child=Gtk.ScrolledWindow(child=lines, propagate_natural_height=True, max_content_height=260,
                                           hscrollbar_policy=Gtk.PolicyType.NEVER))

        def on_toggled(*_args):
            dialog.set_response_enabled("reset", any(c.get_active() for c in checks))

        for d in data:
            row = Gtk.Box(spacing=12)
            check = Gtk.CheckButton(active=True, hexpand=True, tooltip_text=d["path"])
            check.set_child(Gtk.Label(label=short_path(d["path"]), xalign=0, ellipsize=Pango.EllipsizeMode.MIDDLE))
            check.path = d["path"]
            check.connect("toggled", on_toggled)
            checks.append(check)
            row.append(check)
            row.append(Gtk.Label(label=human(d["bytes"]), css_classes=["numeric", "dim-label"]))
            lines.append(row)
        dialog.checks = checks
        dialog.add_response("cancel", _("Cancel"))
        dialog.add_response("reset", _("Reset"))
        dialog.set_response_appearance("reset", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.set_close_response("cancel")
        dialog.connect("response", lambda d, r: r == "reset" and self.reset(app, [c.path for c in checks
                                                                                  if c.get_active()]))
        dialog.present(self.window)
        return dialog

    def reset(self, app, folders):
        """Move these folders of the app to the Trash; a toast offers Restore for 10 s."""
        if self.busy or not folders:
            return
        self.busy = True
        self.update_summary()
        self.window.set_busy(True)
        moved, done, failed = {}, [], []

        def on_event(e):
            if e["event"] == "error":
                failed.append(e["message"])
            elif e["event"] == "task" and e["state"] == "ok":
                done.append(e["id"])
                if e["trash"]:
                    moved[e["trash"]] = e["id"]
            elif e["event"] == "task":
                failed.append(f"{short_path(e['id'])}: {e['info']}")

        def on_done(ok, status):
            self.running, self.busy = None, False
            self.window.set_busy(False)
            if self.engine.dry_run:
                self.window.toast(ngettext("Dry run: {n} folder would be moved to the Trash",
                                           "Dry run: {n} folders would be moved to the Trash", len(done)))
            elif moved:
                msg = ngettext("Reset {name}: moved {n} folder to the Trash",
                               "Reset {name}: moved {n} folders to the Trash", len(moved), name=app["name"])
                if failed:
                    msg += " · " + failed[0]
                self.undo_toast = self.window.toast(msg, _("Restore"), lambda: self.restore(moved), timeout=10)
                self.window.refresh_disk()
            elif failed:
                self.window.toast(failed[0], timeout=8)
            self.load()

        self.running = self.engine.reset(app["id"], on_event, on_done, folders=folders)

    def restore(self, moved, apps=False):
        """Put the leftover folders of the last uninstall back; apt, Snap and Flatpak apps stay removed,
        AppImage apps (`apps`: they are among `moved`) come back with them."""
        if self.busy or not moved:
            return
        self.busy = True
        self.undo_toast = None
        back, failed = [], []
        self.window.set_busy(True)

        def on_event(e):
            if e["event"] == "error":
                failed.append({"info": e["message"]})
            elif e["event"] == "task":
                (back if e["state"] == "ok" else failed).append(e)

        def on_done(ok, status):
            self.running, self.busy = None, False
            self.window.set_busy(False)
            if failed:
                self.window.toast(_("Put back {back}, {failed} could not be restored: {reason}").format(
                    back=len(back), failed=len(failed), reason=failed[0]["info"]))
            elif apps:
                self.window.toast(ngettext("Put back {n} item from the Trash", "Put back {n} items from the Trash",
                                           len(back)))
            else:
                self.window.toast(ngettext("Put back {n} folder from the Trash", "Put back {n} folders from the Trash",
                                           len(back)))
            self.load()

        self.running = self.engine.restore(list(moved), on_event, on_done)
