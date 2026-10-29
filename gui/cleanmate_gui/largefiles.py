"""Large & Old Files: find big or long-unused files, move them to the Trash, undo.

The engine finds the files (`--json large`), moves them (`--json trash`) and puts
them back (`--json restore`); this page only shows them and keeps the choice.
"""
import os
import time

from gi.repository import Adw, Gio, GLib, Gtk, Pango

from .engine import human
from .i18n import _, ngettext
from .scanpage import size_widgets

MIN_SIZES = [("50 MB", 50 << 20), ("100 MB", 100 << 20), ("500 MB", 500 << 20), ("1 GB", 1 << 30),
             ("5 GB", 5 << 30)]
AGES = [(_("Any age"), 0), (_("30 days"), 30), (_("90 days"), 90), (_("6 months"), 182), (_("1 year"), 365)]
KIND_ICONS = {
    "video": "video-x-generic-symbolic",
    "audio": "audio-x-generic-symbolic",
    "image": "image-x-generic-symbolic",
    "archive": "package-x-generic-symbolic",
    "package": "system-software-install-symbolic",
    "disk": "drive-harddisk-symbolic",
    "document": "x-office-document-symbolic",
}


def short_path(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path == home or path.startswith(home + "/") else path


class LargeFilesPage(Gtk.Box):
    """Filters on top; the matching files below, biggest first, with checkboxes."""

    def __init__(self, window, title, icon, description):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self.engine = window.engine
        self.folder = os.path.expanduser("~")
        self.files = []  # "file" events of the last search, biggest first
        self.found = 0  # how many matched (only the biggest are listed)
        self.selected = set()  # paths
        self.checks = {}  # path → Gtk.CheckButton
        self.all_check = None
        self.syncing = False
        self.searched = False
        self.running = None  # Gio.Cancellable of the current engine run
        self.moving = False  # a Trash or undo run: never cancelled, nothing else starts meanwhile
        self.generation = 0  # a newer search makes an older one's results stale
        self.undo_toast = None

        # filters
        self.size_drop = Gtk.DropDown.new_from_strings([label for label, _ in MIN_SIZES])
        self.size_drop.set_selected(1)
        self.size_drop.set_tooltip_text(_("Smallest file size to list"))
        self.age_drop = Gtk.DropDown.new_from_strings([label for label, _ in AGES])
        self.age_drop.set_tooltip_text(_("Only files not changed or opened for this long"))
        for drop in (self.size_drop, self.age_drop):
            drop.connect("notify::selected", lambda *_: self.searched and self.search())
        self.folder_label = Gtk.Label(label=short_path(self.folder), ellipsize=Pango.EllipsizeMode.MIDDLE,
                                      max_width_chars=24)
        folder_box = Gtk.Box(spacing=6)
        folder_box.append(Gtk.Image(icon_name="folder-symbolic"))
        folder_box.append(self.folder_label)
        folder_button = Gtk.Button(child=folder_box, tooltip_text=_("Folder to search (also a drive)"))
        folder_button.connect("clicked", lambda *_: self.choose_folder())
        filters = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, column_spacing=18, row_spacing=6,
                              max_children_per_line=3, margin_top=12, margin_bottom=12,
                              margin_start=12, margin_end=12)
        for label, widget in ((_("At least"), self.size_drop), (_("Unused for"), self.age_drop), (_("In"), folder_button)):
            box = Gtk.Box(spacing=8, halign=Gtk.Align.START)
            box.append(Gtk.Label(label=label, css_classes=["dim-label"]))
            box.append(widget)
            filters.append(box)
        self.append(filters)
        self.append(Gtk.Separator())

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True)
        self.append(self.stack)

        button = Gtk.Button(label=_("Search"), halign=Gtk.Align.CENTER, css_classes=["pill", "suggested-action"])
        button.connect("clicked", lambda *_: self.search())
        self.stack.add_named(Adw.StatusPage(icon_name=icon, title=title, description=description, child=button),
                             "start")
        spinner = Gtk.Spinner(spinning=True, width_request=32, height_request=32, halign=Gtk.Align.CENTER)
        self.searching = Adw.StatusPage(icon_name="system-search-symbolic", title=_("Searching…"), child=spinner)
        self.stack.add_named(self.searching, "searching")
        self.empty = Adw.StatusPage(icon_name="emblem-ok-symbolic", title=_("No files match"),
                                    description=_("Try a smaller size, any age, or another folder."))
        self.stack.add_named(self.empty, "empty")
        self.results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24,
                               margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        self.stack.add_named(Gtk.ScrolledWindow(child=Adw.Clamp(maximum_size=900, child=self.results),
                                                vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER), "results")

        self.bar = Gtk.ActionBar(revealed=False)
        self.summary = Gtk.Label(xalign=0)
        self.bar.pack_start(self.summary)
        self.trash_button = Gtk.Button(label=_("Move to Trash"), css_classes=["destructive-action"])
        self.trash_button.connect("clicked", lambda *_: self.confirm_trash())
        self.bar.pack_end(self.trash_button)
        again = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text=_("Search again"))
        again.connect("clicked", lambda *_: self.search())
        self.bar.pack_end(again)
        self.append(self.bar)

    # ── searching ──
    def choose_folder(self):
        dialog = Gtk.FileDialog(title=_("Folder to search"), initial_folder=Gio.File.new_for_path(self.folder))

        def chosen(d, result):
            try:
                folder = d.select_folder_finish(result)
            except GLib.Error:
                return  # cancelled
            if folder and folder.get_path():
                self.set_folder(folder.get_path())
                self.search()

        dialog.select_folder(self.window, None, chosen)

    def set_folder(self, path):
        self.folder = path
        self.folder_label.set_text(short_path(path))

    def search(self):
        if self.moving:
            return
        if self.running:
            self.running.cancel()
            self.running = None
            self.window.set_busy(False)
        self.searched = True
        self.generation += 1
        gen = self.generation
        files, info = [], {}
        min_bytes = MIN_SIZES[self.size_drop.get_selected()][1]
        days = AGES[self.age_drop.get_selected()][1]
        self.searching.set_description(_("Files of {size} or more in {folder}").format(size=human(min_bytes), folder=short_path(self.folder)))
        self.stack.set_visible_child_name("searching")
        self.bar.set_revealed(False)
        self.window.set_busy(True)

        def on_event(e):
            if e["event"] == "file":
                files.append(e)
            elif e["event"] in ("done", "error"):
                info.update(e)

        def on_done(ok, status):
            if gen != self.generation:
                return  # replaced by a newer search
            self.running = None
            self.window.set_busy(False)
            if "message" in info:
                self.window.toast(info["message"])
            self.files = files
            self.found = info.get("found", len(files))
            self.selected.clear()
            self.show_results()

        self.running = self.engine.large(min_bytes, days, self.folder, on_event, on_done)

    # ── results ──
    def show_results(self):
        child = self.results.get_first_child()
        while child:
            self.results.remove(child)
            child = self.results.get_first_child()
        self.checks.clear()
        self.all_check = None
        if not self.files:
            self.stack.set_visible_child_name("empty")
            self.bar.set_revealed(False)
            return

        total = sum(e["bytes"] for e in self.files)
        title = Gtk.Label(label=ngettext("{n} file · {size}", "{n} files · {size}", len(self.files), size=human(total)),
                          xalign=0, wrap=True,
                          css_classes=["title-1"])
        sub = _("Biggest first, in {folder}").format(folder=short_path(self.folder))
        if self.found > len(self.files):
            sub += " — " + _("the {n} biggest of {found}").format(n=len(self.files), found=self.found)
        header = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        header.append(title)
        header.append(Gtk.Label(label=sub, xalign=0, wrap=True, css_classes=["dim-label"]))
        self.results.append(header)

        group = Adw.PreferencesGroup()
        if len(self.files) > 1:
            self.all_check = Gtk.CheckButton(label=_("All"), valign=Gtk.Align.CENTER, css_classes=["big-check"],
                                             tooltip_text=_("Select or deselect every file"))
            self.all_check.connect("toggled", self.on_all_toggled)
            group.set_header_suffix(self.all_check)
        biggest = self.files[0]["bytes"]
        for e in self.files:
            group.add(self.file_row(e, biggest))
        self.results.append(group)
        self.stack.set_visible_child_name("results")
        self.bar.set_revealed(True)
        self.update_summary()

    def file_row(self, e, biggest):
        path = e["path"]
        folder, name = os.path.split(path)
        when = time.strftime("%-d %b %Y", time.localtime(e["mtime"]))
        row = Adw.ActionRow(title=name, subtitle=_("{folder} · modified {date}").format(folder=short_path(folder), date=when),
                            use_markup=False,
                            subtitle_lines=1, css_classes=["item-row"],
                            tooltip_text=path + "\n" + _("Last opened {date}").format(
                                date=time.strftime("%-d %b %Y", time.localtime(e["atime"]))))
        check = Gtk.CheckButton(active=path in self.selected, valign=Gtk.Align.CENTER, css_classes=["big-check"])
        check.connect("toggled", self.on_toggled, path)
        self.checks[path] = check
        row.add_prefix(Gtk.Image(icon_name=KIND_ICONS.get(e["kind"], "text-x-generic-symbolic")))
        row.add_prefix(check)  # prefixes stack leftwards: the box comes first
        row.set_activatable_widget(check)
        for widget in size_widgets(e["bytes"], biggest):
            row.add_suffix(widget)
        show = Gtk.Button(icon_name="folder-open-symbolic", valign=Gtk.Align.CENTER, css_classes=["flat"],
                          tooltip_text=_("Show in Files"))
        show.connect("clicked", lambda *_: Gtk.FileLauncher.new(Gio.File.new_for_path(path))
                     .open_containing_folder(self.window, None, None))
        row.add_suffix(show)
        return row

    def on_toggled(self, check, path):
        if check.get_active():
            self.selected.add(path)
        else:
            self.selected.discard(path)
        self.update_summary()

    def on_all_toggled(self, button):
        if self.syncing:
            return
        target = button.get_active()  # read once: each row change re-syncs the box
        for check in self.checks.values():
            check.set_active(target)

    def update_summary(self):
        chosen = [e for e in self.files if e["path"] in self.selected]
        self.summary.set_markup(ngettext("Selected <b>{size}</b> in {n} file", "Selected <b>{size}</b> in {n} files",
                                         len(chosen), size=human(sum(e["bytes"] for e in chosen))))
        self.trash_button.set_sensitive(bool(chosen) and not self.running)
        if self.all_check:
            self.syncing = True  # none / some (inconsistent) / all
            self.all_check.set_inconsistent(0 < len(chosen) < len(self.files))
            self.all_check.set_active(len(chosen) == len(self.files))
            self.syncing = False

    # ── Trash and undo ──
    def confirm_trash(self):
        chosen = [e for e in self.files if e["path"] in self.selected]
        if not chosen:
            return
        lines = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        for e in chosen[:12]:
            row = Gtk.Box(spacing=12)
            row.append(Gtk.Label(label=os.path.basename(e["path"]), xalign=0, hexpand=True,
                                 ellipsize=Pango.EllipsizeMode.MIDDLE))
            row.append(Gtk.Label(label=human(e["bytes"]), css_classes=["numeric", "dim-label"]))
            lines.append(row)
        if len(chosen) > 12:
            lines.append(Gtk.Label(label=_("… and {n} more").format(n=len(chosen) - 12), xalign=0, css_classes=["dim-label"]))
        dialog = Adw.AlertDialog(
            heading=ngettext("Move {n} file to the Trash?", "Move {n} files to the Trash?", len(chosen)),
            body=_("{size}. You can undo this right away, or restore the files from the Trash later.").format(
                size=human(sum(e["bytes"] for e in chosen))),
            extra_child=lines)
        dialog.add_response("cancel", _("Cancel"))
        dialog.add_response("trash", _("Move to Trash"))
        dialog.set_response_appearance("trash", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.set_close_response("cancel")
        dialog.connect("response", lambda d, r: r == "trash" and self.trash([e["path"] for e in chosen]))
        dialog.present(self.window)

    def trash(self, paths):
        if self.running or not paths:
            return
        by_path = {e["path"]: e for e in self.files}
        moved = {}  # name in the Trash → the file's event, for undo
        gone, failed, freed, n = set(), [], 0, 0
        gen = self.generation

        def on_event(e):
            nonlocal freed, n
            if e["event"] == "error":
                failed.append({"info": e["message"]})
            if e["event"] != "task":
                return
            if e["state"] == "ok":
                freed += e["freed"]
                n += 1
                if not self.engine.dry_run:
                    gone.add(e["id"])
                    if e["trash"] and e["id"] in by_path:
                        moved[e["trash"]] = by_path[e["id"]]
            else:
                failed.append(e)

        def on_done(ok, status):
            self.running, self.moving = None, False
            self.window.set_busy(False)
            if gen == self.generation:
                self.files = [e for e in self.files if e["path"] not in gone]
                self.selected -= gone
                self.show_results()
            if self.engine.dry_run:
                self.window.toast(ngettext("Dry run: {n} file ({size}) would be moved to the Trash",
                                           "Dry run: {n} files ({size}) would be moved to the Trash", n,
                                           size=human(freed)))
                return
            msg = ngettext("Moved {n} file ({size}) to the Trash", "Moved {n} files ({size}) to the Trash", n,
                           size=human(freed)) if n else _("Nothing was moved")
            if failed:
                msg += " — " + (ngettext("{n} could not be moved: {reason}", "{n} could not be moved: {reason}",
                                         len(failed), reason=failed[0]["info"]) if len(failed) > 1
                                else failed[0]["info"])
            if moved:
                self.undo_toast = self.window.toast(msg, _("Undo"), lambda: self.undo(moved), timeout=10)
            else:
                self.window.toast(msg, timeout=6)
            self.window.refresh_disk()

        self.window.set_busy(True)
        self.trash_button.set_sensitive(False)
        self.moving = True
        self.running = self.engine.trash(paths, on_event, on_done)

    def undo(self, moved):
        if self.running or not moved:
            return
        self.undo_toast = None
        back, failed = [], []
        gen = self.generation

        def on_event(e):
            if e["event"] == "error":
                failed.append({"info": e["message"]})
            if e["event"] != "task":
                return
            if e["state"] == "ok" and e["trash"] in moved:
                back.append(moved[e["trash"]])
            elif e["state"] != "ok":
                failed.append(e)

        def on_done(ok, status):
            self.running, self.moving = None, False
            self.window.set_busy(False)
            if gen == self.generation:  # the same search is still shown: put the rows back too
                known = {e["path"] for e in self.files}
                self.files = sorted(self.files + [e for e in back if e["path"] not in known],
                                    key=lambda e: -e["bytes"])
                self.show_results()
            if failed:
                self.window.toast(_("Put back {back}, {failed} could not be restored: {reason}").format(
                    back=len(back), failed=len(failed), reason=failed[0]["info"]))
            else:
                self.window.toast(ngettext("Put back {n} file from the Trash", "Put back {n} files from the Trash",
                                           len(back)))
            self.window.refresh_disk()

        self.window.set_busy(True)
        self.moving = True
        self.running = self.engine.restore(list(moved), on_event, on_done)
