"""Uninstaller: your apps (apt, Snap, Flatpak) with the folders they leave in your home.

The engine lists the apps (`--json apps`, parts of Ubuntu are never listed),
checks and removes them (`--json uninstall`, apt and Snap through pkexec) and
moves the chosen leftover folders to the Trash (`--json trash`) once the app
is gone. Folders of apps removed earlier (`leftover` events) are a group of
their own at the end, never ticked. This page only shows them and keeps the choice.
"""
import os
import time

from gi.repository import Adw, Gio, GLib, Gtk, Pango

from .engine import human
from .i18n import _, ngettext
from .largefiles import short_path
from .scanpage import size_widgets

SORTS = [(_("Size"), "size"), (_("Last used"), "used"), (_("Name"), "name")]
UNUSED = [(_("All apps"), 0), (_("Unused for 1+ month"), 1), (_("Unused for 3+ months"), 3),
          (_("Unused for 6+ months"), 6), (_("Unused for 12+ months"), 12)]
KIND_LABELS = {"apt": "apt", "snap": "Snap", "flatpak": "Flatpak"}
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
        self.remove_button.connect("clicked", lambda *_: self.check())
        self.bar.pack_end(self.remove_button)
        again = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text=_("List apps again"))
        again.connect("clicked", lambda *_: self.load())
        self.bar.pack_end(again)
        self.append(self.bar)
        self.load()

    # ── listing ──
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
        if self.apps:
            group = Adw.PreferencesGroup()
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
        tip = _("{kind} package {package}\nApp {size} · your data {data}").format(
            kind=kind, package=package, size=human(a["bytes"]), data=human(a["data_bytes"]))
        if a["kind"] != "flatpak":
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
        self.update_summary()

    def on_left_toggled(self, check, path):
        if check.get_active():
            self.left_selected.add(path)
        else:
            self.left_selected.discard(path)
        self.update_summary()

    def chosen(self):
        apps = [self.apps[i] for i in self.selected if i in self.apps]
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
        self.remove_button.set_sensitive(bool(apps) and not self.busy)

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
        lines = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        for a in apps[:12]:
            row = Gtk.Box(spacing=12)
            row.append(Gtk.Label(label=a["name"], xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.END))
            if a["kind"] != "flatpak":
                row.append(Gtk.Image(icon_name="system-lock-screen-symbolic", tooltip_text=_("Needs your password")))
            row.append(Gtk.Label(label=human(a["bytes"]), css_classes=["numeric", "dim-label"]))
            lines.append(row)
        if len(apps) > 12:
            lines.append(Gtk.Label(label=_("… and {n} more").format(n=len(apps) - 12), xalign=0, css_classes=["dim-label"]))
        heading = ngettext("Uninstall {n} app?", "Uninstall {n} apps?", len(apps))
        body = []
        if check["extra"]:
            heading = ngettext("Also removes {n} other package!", "Also removes {n} other packages!", check["extra"])
            body.append(_("apt will also remove: {packages}.").format(packages=check["extra_text"]))
        if folders:
            body.append(ngettext("{n} folder ({size}) will go to the Trash — you can undo that.",
                                 "{n} folders ({size}) will go to the Trash — you can undo that.", len(folders),
                                 size=human(sum(l["bytes"] for l in folders))))
        else:
            body.append(_("Your folders in your home are kept."))
        if any(a["kind"] != "flatpak" for a in apps):
            body.append(_("Apps with a lock need your password."))
        dialog = Adw.AlertDialog(heading=heading, body=" ".join(body), extra_child=lines)
        dialog.add_response("cancel", _("Cancel"))
        dialog.add_response("remove", _("Uninstall"))
        dialog.set_response_appearance("remove", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.set_close_response("cancel")
        dialog.connect("response", lambda d, r: r == "remove" and self.uninstall(apps, folders))
        dialog.present(self.window)

    def uninstall(self, apps, folders):
        if self.busy:
            return
        self.busy = True
        dry = self.engine.dry_run
        user_ids = [a["id"] for a in apps if a["kind"] == "flatpak"]
        # apt and Snap need root: the standard password dialog (never in a dry run, which changes nothing)
        root_ids = [a["id"] for a in apps if a["kind"] != "flatpak"]
        removed = set()
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
        self.work_title.set_text(_("Uninstalling…"))
        self.stack.set_visible_child_name("working")
        self.bar.set_revealed(False)
        self.window.set_busy(True)

        def set_row(row, state, text):
            icon = {"ok": "emblem-ok-symbolic", "skip": "dialog-warning-symbolic"}.get(state, "dialog-error-symbolic")
            row.icon.set_from_icon_name(icon)
            row.icon.set_css_classes([{"ok": "success", "skip": "warning"}.get(state, "error")])
            row.set_subtitle(text)

        def on_event(e):
            if e["event"] == "error":
                self.window.toast(e["message"], timeout=8)
            if e["event"] != "task" or e["id"] not in rows:
                return
            if e["state"] == "run":
                rows[e["id"]].set_subtitle(_("removing…"))
                return
            set_row(rows[e["id"]], e["state"],
                    e["info"] or {"ok": _("removed"), "skip": _("skipped")}.get(e["state"], _("failed")))
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
            self.work_title.set_text(msg)
            if moved:
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

    def restore(self, moved):
        """Put the leftover folders of the last uninstall back (the apps stay removed)."""
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
            else:
                self.window.toast(ngettext("Put back {n} folder from the Trash", "Put back {n} folders from the Trash",
                                           len(back)))
            self.load()

        self.running = self.engine.restore(list(moved), on_event, on_done)
