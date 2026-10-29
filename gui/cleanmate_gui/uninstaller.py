"""Uninstaller: your apps (apt, Snap, Flatpak) with the folders they leave in your home.

The engine lists the apps (`--json apps`, parts of Ubuntu are never listed),
checks and removes them (`--json uninstall`, apt and Snap through pkexec) and
moves the chosen leftover folders to the Trash (`--json trash`) once the app
is gone. This page only shows them and keeps the choice.
"""
import os
import time

from gi.repository import Adw, Gio, GLib, Gtk, Pango

from .engine import human
from .largefiles import plural, short_path
from .scanpage import size_widgets

SORTS = [("Size", "size"), ("Last used", "used"), ("Name", "name")]
KIND_LABELS = {"apt": "apt", "snap": "Snap", "flatpak": "Flatpak"}


def used_ago(epoch):
    if not epoch:
        return ""  # unknown
    days = int((time.time() - epoch) // 86400)
    if days < 1:
        return "used today"
    if days < 60:
        return f"used {plural(days, 'day')} ago"
    if days < 730:
        return f"used {days // 30} months ago"
    return f"used {days // 365} years ago"


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
        self.selected = set()  # app ids
        self.left_selected = set()  # leftover paths (only used for selected apps)
        self.checks = {}  # app id → Gtk.CheckButton
        self.left_checks = {}  # path → Gtk.CheckButton
        self.rows = {}  # app id → its row (filtered by the search)
        self.running = None
        self.busy = False  # listing, checking or uninstalling: nothing else starts
        self.undo_toast = None

        self.search_entry = Gtk.SearchEntry(placeholder_text="Search apps", hexpand=True)
        self.search_entry.connect("search-changed", lambda *_: self.apply_filter())
        self.sort_drop = Gtk.DropDown.new_from_strings([label for label, _ in SORTS])
        self.sort_drop.set_tooltip_text("Sort by")
        self.sort_drop.connect("notify::selected", lambda *_: self.apps and self.show_results())
        top = Gtk.Box(spacing=12, margin_top=12, margin_bottom=12, margin_start=12, margin_end=12)
        top.append(self.search_entry)
        top.append(self.sort_drop)
        self.append(top)
        self.append(Gtk.Separator())

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True)
        self.append(self.stack)
        spinner = Gtk.Spinner(spinning=True, width_request=32, height_request=32, halign=Gtk.Align.CENTER)
        self.stack.add_named(Adw.StatusPage(icon_name=icon, title="Finding your apps…",
                                            description="And the space each one uses.", child=spinner), "loading")
        self.empty = Adw.StatusPage(icon_name="emblem-ok-symbolic", title="No apps found",
                                    description="Only apps with a launcher are listed.")
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
        self.remove_button = Gtk.Button(label="Uninstall", css_classes=["destructive-action"])
        self.remove_button.connect("clicked", lambda *_: self.check())
        self.bar.pack_end(self.remove_button)
        again = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text="List apps again")
        again.connect("clicked", lambda *_: self.load())
        self.bar.pack_end(again)
        self.append(self.bar)
        self.load()

    # ── listing ──
    def load(self):
        if self.busy:
            return
        self.busy = True
        apps, info = {}, {}
        self.stack.set_visible_child_name("loading")
        self.bar.set_revealed(False)
        self.window.set_busy(True)

        def on_event(e):
            if e["event"] == "app":
                apps[e["id"]] = e
            elif e["event"] in ("done", "error"):
                info.update(e)

        def on_done(ok, status):
            self.running, self.busy = None, False
            self.window.set_busy(False)
            if "message" in info:
                self.window.toast(info["message"])
            self.apps, self.hidden = apps, info.get("hidden", 0)
            self.selected &= set(apps)
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
        if not self.apps:
            self.stack.set_visible_child_name("empty")
            self.bar.set_revealed(False)
            return
        total = sum(a["bytes"] + a["data_bytes"] for a in self.apps.values())
        header = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        header.append(Gtk.Label(label=f"{plural(len(self.apps), 'app')} · {human(total)}", xalign=0, wrap=True,
                                css_classes=["title-1"]))
        sub = "Size = the app + its folders in your home."
        if self.hidden:
            sub += f" {plural(self.hidden, 'part')} of Ubuntu itself can't be removed safely and aren't listed."
        header.append(Gtk.Label(label=sub, xalign=0, wrap=True, css_classes=["dim-label"]))
        self.results.append(header)
        group = Adw.PreferencesGroup()
        biggest = max(a["bytes"] + a["data_bytes"] for a in self.apps.values())
        for a in self.sorted_apps():
            row = self.app_row(a, biggest)
            self.rows[a["id"]] = row
            group.add(row)
        self.results.append(group)
        self.stack.set_visible_child_name("results")
        self.bar.set_revealed(True)
        self.apply_filter()
        self.update_summary()

    def app_row(self, a, biggest):
        kind = KIND_LABELS.get(a["kind"], a["kind"])
        package = a["id"].split(":", 1)[1]
        subtitle = " · ".join(x for x in (kind, used_ago(a["last_used"])) if x)
        tip = f"{kind} package {package}\nApp {human(a['bytes'])} · your data {human(a['data_bytes'])}"
        if a["kind"] != "flatpak":
            tip += "\nNeeds your password"
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
        row = Adw.ActionRow(title=short_path(path), subtitle="Moved to the Trash after uninstalling",
                            use_markup=False, title_lines=1, css_classes=["item-row"])
        check = Gtk.CheckButton(active=path in self.left_selected, valign=Gtk.Align.CENTER,
                                css_classes=["big-check"], sensitive=a["id"] in self.selected,
                                tooltip_text="Also move this folder to the Trash")
        check.connect("toggled", self.on_left_toggled, path)
        self.left_checks[path] = check
        row.add_prefix(Gtk.Image(icon_name="folder-symbolic"))
        row.add_prefix(check)
        row.set_activatable_widget(check)
        row.add_suffix(Gtk.Label(label=human(left["bytes"]), width_chars=9, xalign=1,
                                 css_classes=["numeric", "dim-label"]))
        return row

    def apply_filter(self):
        q = self.search_entry.get_text().strip().lower()
        for app_id, row in self.rows.items():
            a = self.apps[app_id]
            row.set_visible(not q or q in a["name"].lower() or q in app_id.lower())

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
        text = f"Selected <b>{human(size)}</b> in {plural(len(apps), 'app')}"
        if folders:
            text += f" + {plural(len(folders), 'folder')}"
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
                self.window.toast(result.get("message") or "Couldn't check what removing these apps does.",
                                  timeout=8)

        self.running = self.engine.uninstall([a["id"] for a in apps], on_event, on_done, check=True)

    def confirm(self, apps, folders, check):
        lines = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        for a in apps[:12]:
            row = Gtk.Box(spacing=12)
            row.append(Gtk.Label(label=a["name"], xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.END))
            if a["kind"] != "flatpak":
                row.append(Gtk.Image(icon_name="system-lock-screen-symbolic", tooltip_text="Needs your password"))
            row.append(Gtk.Label(label=human(a["bytes"]), css_classes=["numeric", "dim-label"]))
            lines.append(row)
        if len(apps) > 12:
            lines.append(Gtk.Label(label=f"… and {len(apps) - 12} more", xalign=0, css_classes=["dim-label"]))
        heading = f"Uninstall {plural(len(apps), 'app')}?"
        body = []
        if check["extra"]:
            heading = f"Also removes {plural(check['extra'], 'other package')}!"
            body.append(f"apt will also remove: {check['extra_text']}.")
        if folders:
            body.append(f"{plural(len(folders), 'folder')} ({human(sum(l['bytes'] for l in folders))}) "
                        "will go to the Trash — you can undo that.")
        else:
            body.append("Your folders in your home are kept.")
        if any(a["kind"] != "flatpak" for a in apps):
            body.append("Apps with a lock need your password.")
        dialog = Adw.AlertDialog(heading=heading, body=" ".join(body), extra_child=lines)
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("remove", "Uninstall")
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
            row = Adw.ActionRow(title=a["name"], subtitle="waiting", use_markup=False)
            row.icon = Gtk.Image(icon_name="content-loading-symbolic", css_classes=["dim-label"])
            row.add_prefix(row.icon)
            self.work_list.append(row)
            rows[a["id"]] = row
        self.work_title.set_text("Uninstalling…")
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
                rows[e["id"]].set_subtitle("removing…")
                return
            set_row(rows[e["id"]], e["state"], e["info"] or e["state"])
            if e["state"] == "ok":
                removed.add(e["id"])

        def run_root():
            if not root_ids:
                return trash_leftovers()
            for i in root_ids:
                rows[i].set_subtitle("waiting for your password…")
            self.running = self.engine.uninstall(root_ids, on_event, root_done, as_root=not dry)

        def root_done(ok, status):
            for i in root_ids:
                row = rows[i]
                if row.get_subtitle().startswith(("waiting", "removing")):
                    if status in (126, 127):  # password dialog dismissed / not authorized
                        set_row(row, "skip", "Skipped — no password was entered")
                    else:
                        set_row(row, "fail", "Not removed")
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
                msg = f"Dry run: {plural(n, 'app')} would be uninstalled"
                if folders_done:
                    msg += f", {plural(folders_done, 'folder')} would be moved to the Trash"
            else:
                msg = f"Uninstalled {plural(n, 'app')}"
                if folders_done:
                    msg += f"; moved {plural(folders_done, 'folder')} to the Trash"
            self.work_title.set_text(msg)
            if moved:
                self.undo_toast = self.window.toast(msg, "Restore folders", lambda: self.restore(moved), timeout=10)
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
                self.window.toast(f"Put back {len(back)}, {len(failed)} could not be restored: {failed[0]['info']}")
            else:
                self.window.toast(f"Put back {plural(len(back), 'folder')} from the Trash")
            self.load()

        self.running = self.engine.restore(list(moved), on_event, on_done)
