"""Duplicates: groups of identical files; keep one copy, move the others to the Trash, undo.

The engine finds the groups (`--json dupes`: same size, then same content), moves files
(`--json trash`) and puts them back (`--json restore`); this page only shows the groups and
keeps the choice. Nothing is ticked after a search; *Select automatically* ticks every copy except
the oldest of each group (the original; newer ones are usually downloaded or copied again), like
the terminal app.
"""
import os
import time

from gi.repository import Adw, Gio, GLib, Gtk, Pango

from .engine import human
from .i18n import _, ngettext
from .largefiles import short_path
from .scanpage import size_widgets

MIN_SIZES = [("100 KB", 100 << 10), ("1 MB", 1 << 20), ("10 MB", 10 << 20), ("100 MB", 100 << 20)]


def group_key(g):
    return f"{g['bytes']}:{g['hash']}"


def oldest_copy(g):
    """Path of the copy to keep: the oldest (smallest mtime; files come newest first, so a tie keeps the last)."""
    return min(reversed(g["files"]), key=lambda f: f["mtime"])["path"]


def auto_selection(groups):
    """Every copy except the oldest of each group."""
    return {f["path"] for g in groups for f in g["files"] if f["path"] != oldest_copy(g)}


def file_icon(path):
    content_type = Gio.content_type_guess(os.path.basename(path), None)[0]
    return Gio.content_type_get_symbolic_icon(content_type)


class DuplicatesPage(Gtk.Box):
    """Filters on top; one expandable row per group of identical files below, biggest first."""

    def __init__(self, window, title, icon, description):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self.engine = window.engine
        self.folder = os.path.expanduser("~")
        self.groups = []  # "group" events of the last search, biggest first; files newest first
        self.found = 0  # how many groups exist (only the biggest are listed)
        self.selected = set()  # paths
        self.checks = {}  # path → Gtk.CheckButton
        self.group_rows = {}  # group key → (Adw.ExpanderRow, warning icon)
        self.searched = False
        self.running = None  # Gio.Cancellable of the current engine run
        self.moving = False  # a Trash or undo run: never cancelled, nothing else starts meanwhile
        self.generation = 0  # a newer search makes an older one's results stale
        self.undo_toast = None

        # filters
        self.size_drop = Gtk.DropDown.new_from_strings([label for label, _n in MIN_SIZES])
        self.size_drop.set_selected(1)
        self.size_drop.set_tooltip_text(_("Smallest file size to compare"))
        self.size_drop.connect("notify::selected", lambda *_a: self.searched and self.search())
        self.folder_label = Gtk.Label(label=short_path(self.folder), ellipsize=Pango.EllipsizeMode.MIDDLE,
                                      max_width_chars=24)
        folder_box = Gtk.Box(spacing=6)
        folder_box.append(Gtk.Image(icon_name="folder-symbolic"))
        folder_box.append(self.folder_label)
        folder_button = Gtk.Button(child=folder_box, tooltip_text=_("Folder to search (also a drive)"))
        folder_button.connect("clicked", lambda *_a: self.choose_folder())
        filters = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, column_spacing=18, row_spacing=6,
                              max_children_per_line=2, margin_top=12, margin_bottom=12,
                              margin_start=12, margin_end=12)
        for label, widget in ((_("At least"), self.size_drop), (_("In"), folder_button)):
            box = Gtk.Box(spacing=8, halign=Gtk.Align.START)
            box.append(Gtk.Label(label=label, css_classes=["dim-label"]))
            box.append(widget)
            filters.append(box)
        self.append(filters)
        self.append(Gtk.Separator())

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True)
        self.append(self.stack)
        button = Gtk.Button(label=_("Search"), halign=Gtk.Align.CENTER, css_classes=["pill", "suggested-action"])
        button.connect("clicked", lambda *_a: self.search())
        self.stack.add_named(Adw.StatusPage(icon_name=icon, title=title, description=description, child=button),
                             "start")
        spinner = Gtk.Spinner(spinning=True, width_request=32, height_request=32, halign=Gtk.Align.CENTER)
        self.searching = Adw.StatusPage(icon_name="system-search-symbolic", title=_("Searching…"), child=spinner)
        self.stack.add_named(self.searching, "searching")
        self.empty = Adw.StatusPage(icon_name="emblem-ok-symbolic", title=_("No duplicates found"),
                                    description=_("Try a smaller size or another folder."))
        self.stack.add_named(self.empty, "empty")
        self.results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24,
                               margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        self.stack.add_named(Gtk.ScrolledWindow(child=Adw.Clamp(maximum_size=900, child=self.results),
                                                vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER), "results")

        self.bar = Gtk.ActionBar(revealed=False)
        self.summary = Gtk.Label(xalign=0)
        self.bar.pack_start(self.summary)
        self.trash_button = Gtk.Button(label=_("Move to Trash"), css_classes=["destructive-action"])
        self.trash_button.connect("clicked", lambda *_a: self.confirm_trash())
        self.bar.pack_end(self.trash_button)
        again = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text=_("Search again"))
        again.connect("clicked", lambda *_a: self.search())
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
        groups, info = [], {}
        min_bytes = MIN_SIZES[self.size_drop.get_selected()][1]
        self.searching.set_description(_("Listing files…"))
        self.stack.set_visible_child_name("searching")
        self.bar.set_revealed(False)
        self.window.set_busy(True)

        def on_event(e):
            if gen != self.generation:
                return
            if e["event"] == "group":
                groups.append(e)
            elif e["event"] == "progress" and e["total"]:
                text = (_("Comparing {done} of {total} files of the same size…") if e["stage"] == "compare"
                        else _("Checking {done} of {total} likely duplicates…"))
                self.searching.set_description(text.format(done=e["done"], total=e["total"]))
            elif e["event"] in ("done", "error"):
                info.update(e)

        def on_done(ok, status):
            if gen != self.generation:
                return  # replaced by a newer search
            self.running = None
            self.window.set_busy(False)
            if "message" in info:
                self.window.toast(info["message"])
            self.groups = groups
            self.found = info.get("found", len(groups))
            self.selected = set()
            self.show_results()

        self.running = self.engine.dupes(min_bytes, self.folder, on_event, on_done)

    # ── results ──
    def shown_groups(self):
        return [g for g in self.groups if len(g["files"]) > 1]

    def select_automatically(self, show=True):
        """Tick every copy except the oldest of each group."""
        self.selected = auto_selection(self.shown_groups())
        if show:
            for path, check in self.checks.items():
                check.set_active(path in self.selected)

    def show_results(self):
        child = self.results.get_first_child()
        while child:
            self.results.remove(child)
            child = self.results.get_first_child()
        self.checks.clear()
        self.group_rows.clear()
        groups = self.shown_groups()
        if not groups:
            self.stack.set_visible_child_name("empty")
            self.bar.set_revealed(False)
            return

        wasted = sum(g["bytes"] * (len(g["files"]) - 1) for g in groups)
        title = Gtk.Label(label=ngettext("{n} group of duplicates", "{n} groups of duplicates", len(groups)),
                          xalign=0, wrap=True, css_classes=["title-1"])
        sub = _("{size} can be freed by keeping one copy of each, in {folder}").format(
            size=human(wasted), folder=short_path(self.folder))
        if self.found > len(self.groups):
            sub += " — " + _("the {n} biggest of {found}").format(n=len(self.groups), found=self.found)
        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, hexpand=True)
        text.append(title)
        text.append(Gtk.Label(label=sub, xalign=0, wrap=True, css_classes=["dim-label"]))
        auto = Gtk.Button(label=_("Select automatically"), valign=Gtk.Align.CENTER,
                          tooltip_text=_("Tick every copy except the oldest one of each group"))
        auto.connect("clicked", lambda *_a: self.select_automatically())
        header = Gtk.Box(spacing=12)
        header.append(text)
        header.append(auto)
        self.results.append(header)

        group = Adw.PreferencesGroup()
        biggest = max(g["bytes"] * (len(g["files"]) - 1) for g in groups)
        expand = len(groups) <= 20
        for g in groups:
            group.add(self.group_row(g, biggest, expand))
        self.results.append(group)
        self.stack.set_visible_child_name("results")
        self.bar.set_revealed(True)
        self.update_summary()

    def group_row(self, g, biggest, expand):
        oldest = oldest_copy(g)
        row = Adw.ExpanderRow(title=os.path.basename(oldest), use_markup=False, expanded=expand,
                              css_classes=["item-row"])
        warning = Gtk.Image(icon_name="dialog-warning-symbolic", css_classes=["warning"], visible=False,
                            tooltip_text=_("Every copy is selected: none would be kept"))
        # an ExpanderRow stacks suffixes rightwards
        row.add_suffix(warning)
        for widget in size_widgets(g["bytes"] * (len(g["files"]) - 1), biggest):
            row.add_suffix(widget)
        row.add_prefix(Gtk.Image(gicon=file_icon(oldest)))
        self.group_rows[group_key(g)] = (row, warning)
        for f in g["files"]:
            row.add_row(self.file_row(g, f, f["path"] == oldest))
        self.update_group(g)
        return row

    def file_row(self, g, f, oldest):
        path = f["path"]
        date = time.strftime("%-d %b %Y %H:%M", time.localtime(f["mtime"]))
        subtitle = (_("Oldest · modified {date}") if oldest else _("Modified {date}")).format(date=date)
        row = Adw.ActionRow(title=short_path(os.path.dirname(path)), subtitle=subtitle, use_markup=False,
                            title_lines=1, css_classes=["item-row"], tooltip_text=path)
        check = Gtk.CheckButton(active=path in self.selected, valign=Gtk.Align.CENTER, css_classes=["big-check"],
                                tooltip_text=_("Move this copy to the Trash"))
        check.connect("toggled", self.on_toggled, g, path)
        self.checks[path] = check
        row.add_prefix(Gtk.Image(icon_name="folder-symbolic"))
        row.add_prefix(check)  # prefixes stack leftwards: the box comes first
        row.set_activatable_widget(check)
        show = Gtk.Button(icon_name="folder-open-symbolic", valign=Gtk.Align.CENTER, css_classes=["flat"],
                          tooltip_text=_("Show in Files"))
        show.connect("clicked", lambda *_a: Gtk.FileLauncher.new(Gio.File.new_for_path(path))
                     .open_containing_folder(self.window, None, None))
        row.add_suffix(show)
        return row

    def all_ticked(self, g):
        return all(f["path"] in self.selected for f in g["files"])

    def update_group(self, g):
        row, warning = self.group_rows[group_key(g)]
        n = len(g["files"])
        ticked = sum(f["path"] in self.selected for f in g["files"])
        if ticked == n:
            row.set_subtitle(_("Every copy is selected: none would be kept"))
        else:
            row.set_subtitle(ngettext("{n} copy of {size}, {k} selected", "{n} copies of {size}, {k} selected", n,
                                      size=human(g["bytes"]), k=ticked))
        warning.set_visible(ticked == n)

    def on_toggled(self, check, g, path):
        if check.get_active():
            self.selected.add(path)
        else:
            self.selected.discard(path)
        self.update_group(g)
        self.update_summary()

    def chosen(self):
        return [(g, f) for g in self.shown_groups() for f in g["files"] if f["path"] in self.selected]

    def update_summary(self):
        chosen = self.chosen()
        self.summary.set_markup(ngettext("Selected <b>{size}</b> in {n} file", "Selected <b>{size}</b> in {n} files",
                                         len(chosen), size=human(sum(g["bytes"] for g, _f in chosen))))
        self.trash_button.set_sensitive(bool(chosen) and not self.running)

    # ── Trash and undo ──
    def confirm_trash(self):
        chosen = self.chosen()
        if not chosen:
            return
        lines = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        whole = [g for g in self.shown_groups() if self.all_ticked(g)]
        if whole:
            lines.append(Gtk.Label(
                label=ngettext("Every copy of {n} file is selected: none of its copies would be kept.",
                               "Every copy of {n} files is selected: none of their copies would be kept.",
                               len(whole)),
                xalign=0, wrap=True, css_classes=["warning"], margin_bottom=6))
        for g, f in chosen[:12]:
            row = Gtk.Box(spacing=12)
            row.append(Gtk.Label(label=short_path(f["path"]), xalign=0, hexpand=True,
                                 ellipsize=Pango.EllipsizeMode.START))
            row.append(Gtk.Label(label=human(g["bytes"]), css_classes=["numeric", "dim-label"]))
            lines.append(row)
        if len(chosen) > 12:
            lines.append(Gtk.Label(label=_("… and {n} more").format(n=len(chosen) - 12), xalign=0, css_classes=["dim-label"]))
        dialog = Adw.AlertDialog(
            heading=ngettext("Move {n} file to the Trash?", "Move {n} files to the Trash?", len(chosen)),
            body=_("{size}. You can undo this right away, or restore the files from the Trash later.").format(
                size=human(sum(g["bytes"] for g, _f in chosen))),
            extra_child=lines)
        dialog.add_response("cancel", _("Cancel"))
        dialog.add_response("trash", _("Move to Trash"))
        dialog.set_response_appearance("trash", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.set_close_response("cancel")
        dialog.connect("response", lambda d, r: r == "trash" and self.trash([f["path"] for g, f in chosen]))
        dialog.present(self.window)

    def trash(self, paths):
        if self.running or not paths:
            return
        owner = {f["path"]: (g, f) for g in self.groups for f in g["files"]}
        moved = {}  # name in the Trash → (group, file), for undo
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
                    if e["trash"] and e["id"] in owner:
                        moved[e["trash"]] = owner[e["id"]]
            else:
                failed.append(e)

        def on_done(ok, status):
            self.running, self.moving = None, False
            self.window.set_busy(False)
            if gen == self.generation:  # a group down to one file is hidden; undo brings it back
                for g in self.groups:
                    g["files"] = [f for f in g["files"] if f["path"] not in gone]
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
            if gen == self.generation:  # the same search is still shown: put the copies back in their groups
                for g, f in back:
                    if f["path"] not in (x["path"] for x in g["files"]):
                        g["files"] = sorted(g["files"] + [f], key=lambda x: -x["mtime"])
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
