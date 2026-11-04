"""Duplicates: groups of identical files, or of similar photos; keep one, move the others to the Trash, undo.

Identical files: the engine finds the groups (`--json dupes`: same size, then same content). Similar photos:
`similar.py` reads the photos here, on a background thread, with GdkPixbuf. Either way the engine moves files
(`--json trash`) and puts them back (`--json restore`); this page only shows the groups and keeps the choice.
Nothing is ticked after a search; *Select automatically* ticks every copy except the oldest of each group (the
original; newer ones are usually downloaded or copied again), like the terminal app, and every photo except
the suggested one (most pixels, then biggest file).
"""
import collections
import os
import threading
import time

from gi.repository import Adw, Gio, GLib, Gtk, Pango

from .a11y import named
from . import preview, similar
from .engine import human
from .errorview import ErrorPage, Failure
from . import findbar
from .findbar import FindBar
from .i18n import _, ngettext
from .largefiles import short_path, skipped_notes
from .scanpage import size_widgets
from . import messages
from .rows import plain_row

MIN_SIZES = [("100 KB", 100 << 10), ("1 MB", 1 << 20), ("10 MB", 10 << 20), ("100 MB", 100 << 20)]
FILES, PHOTOS = "files", "photos"  # the two modes: identical files, similar photos
THUMB = 48  # px, the photo next to each similar photo
WIDE = 760  # sp: a narrower page hides the photo preview
ROWS_AT_ONCE = 50  # file rows added per frame, so a group of 2,000 photos never freezes the window


def dupes_notes(info):
    """What the duplicate search left out (the engine's `done` counts and reasons), one line each."""
    why = info.get("reasons") or {}
    notes = skipped_notes({"hidden": info.get("hidden")})
    if why.get("hidden_folders"):
        notes.append(ngettext("{n} file skipped: it is hidden, or in a hidden folder",
                              "{n} files skipped: they are hidden, or in hidden folders", why["hidden_folders"]))
    if why.get("node_modules"):
        notes.append(ngettext("{n} file skipped: it is in a node_modules folder",
                              "{n} files skipped: they are in node_modules folders", why["node_modules"]))
    if why.get("never_clean"):
        notes.append(ngettext("{n} file skipped: it is in a folder you never clean",
                              "{n} files skipped: they are in folders you never clean", why["never_clean"]))
    if why.get("unreadable"):
        notes.append(ngettext("{n} file skipped: it can't be read",
                              "{n} files skipped: they can't be read", why["unreadable"]))
    return notes + skipped_notes({"other_drives": info.get("other_drives")})


def group_key(g):
    return g.get("key") or f"{g['bytes']}:{g['hash']}"


def file_bytes(g, f):
    """A file's size: in a group of identical files they all have the group's size."""
    return f.get("bytes", g.get("bytes", 0))


def keeper(g):
    """The file a group suggests keeping: the oldest copy, or the best photo."""
    return similar.keeper(g) if "key" in g else oldest_copy(g)


def freeable(g):
    keep = keeper(g)
    return sum(file_bytes(g, f) for f in g["files"] if f["path"] != keep)


def pictures_folder():
    """Your Pictures folder (xdg-user-dirs), or home when there is none."""
    path = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_PICTURES)
    home = os.path.expanduser("~")
    return path if path and path != home and os.path.isdir(path) else home


def oldest_copy(g):
    """Path of the copy to keep: the oldest (smallest mtime; files come newest first, so a tie keeps the last)."""
    return min(reversed(g["files"]), key=lambda f: f["mtime"])["path"]


def auto_selection(groups):
    """Every copy except the oldest of each group (in a group of similar photos: except the suggested one)."""
    return {f["path"] for g in groups for f in g["files"] if f["path"] != keeper(g)}


def file_icon(path):
    content_type = Gio.content_type_guess(os.path.basename(path), None)[0]
    return Gio.content_type_get_symbolic_icon(content_type)


class DuplicatesPage(Gtk.Box):
    """Mode and filters on top; one expandable row per group of identical files or similar photos below,
    most to free first."""

    def __init__(self, window, title, icon, description):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self.engine = window.engine
        self.mode = FILES
        self.folder = os.path.expanduser("~")
        self.folders = {FILES: self.folder, PHOTOS: pictures_folder()}  # each mode keeps its own folder
        self.intro = (icon, title, description)
        self.groups = []  # "group" events of the last search, biggest first; files newest first
        self.found = 0  # how many groups exist (only the biggest are listed)
        self.info = {}  # the search's `done` event: what it left out
        self.selected = set()  # paths
        self.checks = {}  # path → Gtk.CheckButton
        self.pending_rows = collections.deque()  # (group, its row, file, kept?) still to add
        self.bulk = False  # ticking many boxes at once: count once at the end
        self.group_rows = {}  # group key → (Adw.ExpanderRow, warning icon)
        self.searched = False
        self.running = None  # Gio.Cancellable of the current engine run
        self.moving = False  # a Trash or undo run: never cancelled, nothing else starts meanwhile
        self.generation = 0  # a newer search makes an older one's results stale
        self.undo_toast = None
        self.excluding = None  # a Never clean run

        # mode, filters
        self.mode_buttons = {}
        modes = Gtk.Box(css_classes=["linked"])
        for mode, label in ((FILES, _("Identical Files")), (PHOTOS, _("Similar Photos"))):
            button = Gtk.ToggleButton(label=label, active=mode == FILES,
                                      group=self.mode_buttons.get(FILES))
            button.connect("toggled", lambda b, m=mode: b.get_active() and self.set_mode(m))
            self.mode_buttons[mode] = button
            modes.append(button)
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
                              max_children_per_line=3, margin_top=12, margin_bottom=12,
                              margin_start=12, margin_end=12)
        filters.append(modes)
        for label, widget in ((_("At least"), self.size_drop), (_("In"), folder_button)):
            box = Gtk.Box(spacing=8, halign=Gtk.Align.START)
            box.append(Gtk.Label(label=label, css_classes=["dim-label"]))
            box.append(widget)
            filters.append(box)
            if widget is self.size_drop:
                self.size_filter = box.get_parent()  # the FlowBoxChild, hidden for photos
        self.append(filters)
        self.append(Gtk.Separator())

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True)
        self.append(self.stack)
        button = Gtk.Button(label=_("Search"), halign=Gtk.Align.CENTER, css_classes=["pill", "suggested-action"])
        button.connect("clicked", lambda *_a: self.search())
        self.start = Adw.StatusPage(icon_name=icon, title=title, description=description, child=button)
        self.stack.add_named(self.start, "start")
        spinner = Gtk.Spinner(spinning=True, width_request=32, height_request=32, halign=Gtk.Align.CENTER)
        self.stop_button = Gtk.Button(label=_("Stop"), halign=Gtk.Align.CENTER, css_classes=["pill"])
        self.stop_button.connect("clicked", lambda *_a: self.stop())
        searching = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24)
        searching.append(spinner)
        searching.append(self.stop_button)
        self.searching = Adw.StatusPage(icon_name="system-search-symbolic", title=_("Searching…"), child=searching)
        self.stack.add_named(self.searching, "searching")
        self.empty = Adw.StatusPage(icon_name="emblem-ok-symbolic", title=_("No duplicates found"),
                                    description=_("Try a smaller size or another folder."))
        self.stack.add_named(self.empty, "empty")
        self.failed = ErrorPage(window, lambda: self.search(), title=_("The search failed"))
        self.stack.add_named(self.failed, "failed")
        self.results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24,
                               margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        self.scroller = Gtk.ScrolledWindow(child=Adw.Clamp(maximum_size=900, child=self.results),
                                           vexpand=True, hexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)
        # Similar Photos: the photo you point at, big, beside the list (when the page is wide enough)
        self.preview = preview.PreviewPane(window)
        self.preview_slot = Gtk.Box(visible=False)  # shown in the photos mode
        self.preview_slot.append(Gtk.Separator(orientation=Gtk.Orientation.VERTICAL))
        self.preview_slot.append(self.preview)
        side = Gtk.Box()
        side.append(self.scroller)
        side.append(self.preview_slot)
        wide = Adw.BreakpointBin(child=side, width_request=300, height_request=200)
        narrow = Adw.Breakpoint.new(Adw.BreakpointCondition.parse(f"max-width: {WIDE}sp"))
        narrow.add_setter(self.preview, "visible", False)
        wide.add_breakpoint(narrow)
        self.find_bar = FindBar(self.apply_filter)
        results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        results.append(self.find_bar)
        results.append(wide)
        self.stack.add_named(results, "results")
        findbar.never_clean_actions(self, self.never_clean_folder)

        self.bar = Gtk.ActionBar(revealed=False)
        self.summary = Gtk.Label(xalign=0)
        self.bar.pack_start(self.summary)
        self.trash_button = Gtk.Button(label=_("Move to Trash"), css_classes=["destructive-action"])
        self.trash_button.connect("clicked", lambda *_a: self.confirm_trash())
        self.bar.pack_end(self.trash_button)
        again = named(Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text=_("Search again")))
        again.connect("clicked", lambda *_a: self.search())
        self.bar.pack_end(again)
        self.bar.pack_end(self.find_bar.toggle())
        self.append(self.bar)

    # ── mode ──
    def set_mode(self, mode):
        """Identical files or similar photos: each has its own folder and results; a search going is stopped."""
        if mode == self.mode:
            return
        if self.moving:  # a Trash or undo run finishes on the mode it started in
            self.mode_buttons[self.mode].set_active(True)
            return
        self.stop(show=False)
        self.folders[self.mode] = self.folder
        self.mode = mode
        self.mode_buttons[mode].set_active(True)
        self.preview_slot.set_visible(mode == PHOTOS)
        self.preview.clear()
        self.set_folder(self.folders[mode])
        self.size_filter.set_visible(mode == FILES)
        icon, title, description = self.intro
        if mode == PHOTOS:
            icon, title = "image-x-generic-symbolic", _("Similar Photos")
            description = _("Find photos that look alike — resized or re-saved copies, edits, shots taken one after "
                            "another — keep the best of each and move the others to the Trash. You can undo it. "
                            "Your photos are read on this computer only.")
        self.start.set_icon_name(icon)
        self.start.set_title(title)
        self.start.set_description(description)
        self.empty.set_title(_("No similar photos found") if mode == PHOTOS else _("No duplicates found"))
        self.empty.set_description(_("Try another folder.") if mode == PHOTOS
                                   else _("Try a smaller size or another folder."))
        self.groups, self.found, self.selected, self.searched = [], 0, set(), False
        self.info = {}
        self.stack.set_visible_child_name("start")
        self.bar.set_revealed(False)

    def stop(self, show=True):
        """Stop the search going, at once: its results never show."""
        if not self.running or self.moving:
            return
        self.generation += 1
        self.running.cancel()
        self.running = None
        self.window.set_busy(False)
        if show:
            self.stack.set_visible_child_name("results" if self.shown_groups() else "start")
            self.bar.set_revealed(bool(self.shown_groups()))

    def find(self):
        """Ctrl+F: show only the groups with a file whose name or folder has every word typed."""
        if self.stack.get_visible_child_name() == "results":
            self.find_bar.open()

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

    def reload(self):
        """Ctrl+R: search again, unless a search or a Trash run is going."""
        if not self.running and not self.moving:
            self.search()

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
        if self.mode == PHOTOS:
            return self.search_photos(gen)

        failure = Failure("cm --json dupes", self.engine.env.get("HOME"))

        def on_event(e):
            if gen != self.generation:
                return
            failure.see(e)
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
            if failure.failed and "found" not in info:  # no answer: an error, never "no duplicates found"
                self.groups, self.found = [], 0
                self.selected = set()
                self.failed.show(failure)
                self.stack.set_visible_child_name("failed")
                return
            if "message" in info:
                self.window.toast(messages.text(info))
            self.groups = groups
            self.found = info.get("found", len(groups))
            self.info = info
            self.selected = set()
            self.show_results()

        self.running = self.engine.dupes(min_bytes, self.folder, on_event, on_done)

    def search_photos(self, gen):
        """Never clean folders from the engine's settings, then list, read and group the photos on a thread."""
        exclusions = []
        folder = self.folder

        def on_setting(e):
            if e.get("event") == "setting" and e.get("key") == "exclusions":
                exclusions[:] = e.get("value") or []

        def got_settings(ok, status):
            if gen != self.generation:
                return
            cancellable = self.running = Gio.Cancellable()
            threading.Thread(target=work, args=(cancellable,), daemon=True).start()

        def work(cancellable):
            last = [0.0]

            def progress(done, total):
                now = time.monotonic()
                if done == total or now - last[0] > 0.1:
                    last[0] = now
                    GLib.idle_add(show_progress, done, total)

            groups, failure = None, None
            try:
                photos = similar.find_photos(folder, exclusions, cancellable.is_cancelled)
                GLib.idle_add(show_progress, 0, len(photos))
                read = similar.hash_photos(photos, cancellable.is_cancelled, progress)
                groups = similar.group_photos(read, cancellable.is_cancelled)
            except Exception as e:  # a bug, never "no similar photos found": the error page says what went wrong
                failure = Failure("similar photos", self.engine.env.get("HOME"))
                failure.crashed(e)
            finally:  # the page never stays on "Searching…"
                GLib.idle_add(finished, cancellable, groups, failure)

        def show_progress(done, total):
            if gen == self.generation and total:
                self.searching.set_description(ngettext("Reading {done} of {n} photo…", "Reading {done} of {n} photos…",
                                                        total, done=done))
            return False

        def finished(cancellable, found, failure):
            if gen != self.generation or cancellable.is_cancelled():
                return False  # stopped, or replaced by a newer search
            self.running = None
            self.window.set_busy(False)
            if failure:
                self.groups, self.found = [], 0
                self.selected = set()
                self.failed.show(failure)
                self.stack.set_visible_child_name("failed")
                return False
            found = found or []
            self.groups = found[:similar.GROUPS_LIMIT]
            self.found = len(found)
            self.info = {}
            self.selected = set()
            self.show_results()
            return False

        self.running = self.engine.settings(on_setting, got_settings)

    # ── results ──
    def shown_groups(self):
        return [g for g in self.groups if len(g["files"]) > 1]

    def select_automatically(self, show=True):
        """Tick every copy except the oldest of each group."""
        self.selected = auto_selection(self.shown_groups())
        if show:
            self.bulk = True
            try:
                for path, check in self.checks.items():
                    check.set_active(path in self.selected)
            finally:
                self.bulk = False
            for g in self.shown_groups():
                if group_key(g) in self.group_rows:
                    self.update_group(g)
            self.update_summary()

    def show_results(self):
        child = self.results.get_first_child()
        while child:
            self.results.remove(child)
            child = self.results.get_first_child()
        self.checks.clear()
        self.group_rows.clear()
        self.pending_rows = collections.deque()
        groups = self.shown_groups()
        notes = dupes_notes(self.info)
        if not groups:
            hint = (_("Try another folder.") if self.mode == PHOTOS else _("Try a smaller size or another folder."))
            self.empty.set_description(GLib.markup_escape_text("\n".join([hint, *notes])))
            self.stack.set_visible_child_name("empty")
            self.bar.set_revealed(False)
            return

        wasted = sum(freeable(g) for g in groups)
        photos = self.mode == PHOTOS
        title = Gtk.Label(label=ngettext("{n} group of similar photos", "{n} groups of similar photos", len(groups))
                          if photos else ngettext("{n} group of duplicates", "{n} groups of duplicates", len(groups)),
                          xalign=0, wrap=True, css_classes=["title-1"])
        sub = (_("{size} can be freed by keeping the suggested photo of each, in {folder}") if photos
               else _("{size} can be freed by keeping one copy of each, in {folder}")).format(
            size=human(wasted), folder=short_path(self.folder))
        if self.found > len(self.groups):
            sub += " — " + _("the {n} biggest of {found}").format(n=len(self.groups), found=self.found)
        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, hexpand=True)
        text.append(title)
        text.append(Gtk.Label(label=sub, xalign=0, wrap=True, css_classes=["dim-label"]))
        for note in notes:
            text.append(Gtk.Label(label=note, xalign=0, wrap=True, css_classes=["dim-label", "caption"]))
        auto = Gtk.Button(label=_("Select automatically"), valign=Gtk.Align.CENTER,
                          tooltip_text=_("Tick every photo except the suggested one of each group") if photos
                          else _("Tick every copy except the oldest one of each group"))
        auto.connect("clicked", lambda *_a: self.select_automatically())
        header = Gtk.Box(spacing=12)
        header.append(text)
        header.append(auto)
        self.results.append(header)

        group = Adw.PreferencesGroup()
        biggest = max(freeable(g) for g in groups)
        expand = len(groups) <= 20
        for g in groups:
            group.add(self.group_row(g, biggest, expand))
        self.results.append(group)
        self.add_rows(self.pending_rows)
        if photos and self.preview.path not in {f["path"] for g in groups for f in g["files"]}:
            g = groups[0]
            keep = keeper(g)
            self.preview.show(keep, self.photo_facts(next(f for f in g["files"] if f["path"] == keep)), True)
        self.stack.set_visible_child_name("results")
        self.bar.set_revealed(True)
        self.apply_filter()

    def group_matches(self, words, g):
        return not words or any(findbar.matches(words, os.path.basename(f["path"]),
                                                short_path(os.path.dirname(f["path"]))) for f in g["files"])

    def apply_filter(self):
        words = self.find_bar.words()
        for g in self.shown_groups():
            rows = self.group_rows.get(group_key(g))
            if rows:
                rows[0].set_visible(self.group_matches(words, g))
        self.update_summary()

    def listed_groups(self):
        """The groups shown and not hidden by the search."""
        return [g for g in self.shown_groups() if group_key(g) not in self.group_rows
                or self.group_rows[group_key(g)][0].get_visible()]

    def group_row(self, g, biggest, expand):
        keep = keeper(g)
        row = plain_row(Adw.ExpanderRow, title=os.path.basename(keep), expanded=expand,
                              css_classes=["item-row"])
        everything = (_("Every photo is selected: none would be kept") if self.mode == PHOTOS
                      else _("Every copy is selected: none would be kept"))
        warning = Gtk.Image(icon_name="dialog-warning-symbolic", css_classes=["warning"], visible=False,
                            tooltip_text=everything)
        # an ExpanderRow stacks suffixes rightwards
        row.add_suffix(warning)
        for widget in size_widgets(freeable(g), biggest):
            row.add_suffix(widget)
        kept = next(f for f in g["files"] if f["path"] == keep)
        row.add_prefix(self.thumbnail(keep, file_bytes(g, kept), kept["mtime"]))
        self.group_rows[group_key(g)] = (row, warning)
        self.pending_rows.extend((g, row, f, f["path"] == keep) for f in g["files"])
        self.update_group(g)
        return row

    def add_rows(self, pending):
        """Add the next file rows; the rest on the next frames (pending is dropped by a new result)."""
        if pending is not self.pending_rows:
            return False
        for _n in range(min(ROWS_AT_ONCE, len(pending))):
            g, row, f, keep = pending.popleft()
            row.add_row(self.file_row(g, f, keep))
        if not pending:
            return False
        # one batch a frame, so each is laid out before the next is built; the timer as well, for a page that isn't
        # shown or a display that draws only now and then
        done = [False]

        def next_batch(*_a):
            if not done[0]:
                done[0] = True
                self.add_rows(pending)
            return False

        if self.results.get_mapped():
            self.results.add_tick_callback(next_batch)
        GLib.timeout_add(250, next_batch)
        return False

    def thumbnail(self, path, size_bytes, mtime):
        """A small picture of the photo, image or video (read on a thread the first time it shows), else its icon."""
        gen = self.generation
        alive = lambda: gen == self.generation  # noqa: E731
        if self.mode == PHOTOS:
            return preview.THUMBNAILS.image(path, "image", stamp=(size_bytes, mtime), size=THUMB,
                                            icon_name="image-x-generic-symbolic", alive=alive)
        return preview.THUMBNAILS.image(path, preview.media_kind(path), stamp=(size_bytes, mtime),
                                        gicon=file_icon(path), alive=alive)

    @staticmethod
    def photo_facts(f):
        return _("{width} × {height} · {size} · {folder}").format(
            width=f["width"], height=f["height"], size=human(f["bytes"]), folder=short_path(os.path.dirname(f["path"])))

    def point_at(self, row, f, keep):
        """The photo of a row shows in the preview while the pointer rests on it, or when the row has the focus."""
        motion = Gtk.EventControllerMotion()
        motion.connect("enter", lambda *_a: self.preview.show_later(f["path"], self.photo_facts(f), keep))
        row.add_controller(motion)
        focus = Gtk.EventControllerFocus()
        focus.connect("enter", lambda *_a: self.preview.show(f["path"], self.photo_facts(f), keep))
        row.add_controller(focus)

    def file_row(self, g, f, keep):
        path = f["path"]
        date = time.strftime("%-d %b %Y %H:%M", time.localtime(f["mtime"]))
        if self.mode == PHOTOS:
            title = os.path.basename(path)
            subtitle = self.photo_facts(f)
            tip = _("Move this photo to the Trash")
        else:
            title = short_path(os.path.dirname(path))
            subtitle = (_("Oldest · modified {date}") if keep else _("Modified {date}")).format(date=date)
            tip = _("Move this copy to the Trash")
        # one line each (the path is in the tooltip): wrapped labels made laying out 2,000 rows take seconds
        row = plain_row(Adw.ActionRow, title=title, subtitle=subtitle,
                            title_lines=1, subtitle_lines=1, css_classes=["item-row"], tooltip_text=path)
        check = Gtk.CheckButton(active=path in self.selected, valign=Gtk.Align.CENTER, css_classes=["big-check"],
                                tooltip_text=tip)
        check.connect("toggled", self.on_toggled, g, path)
        self.checks[path] = check
        if self.mode == PHOTOS:
            row.add_prefix(self.thumbnail(path, f["bytes"], f["mtime"]))
            if keep:  # the suggested photo, marked so it can't be missed
                row.add_suffix(Gtk.Label(label=_("Suggested"), valign=Gtk.Align.CENTER, css_classes=["keep-badge"],
                                         tooltip_text=_("Suggested to keep: the most pixels, then the biggest file")))
            self.point_at(row, f, keep)
        else:
            row.add_prefix(Gtk.Image(icon_name="folder-symbolic"))
        row.add_prefix(check)  # prefixes stack leftwards: the box comes first
        row.set_activatable_widget(check)
        preview.row_buttons(row, self.window, path)
        if findbar.can_exclude(self.engine, os.path.dirname(path)):
            row.add_suffix(findbar.never_clean_button(os.path.dirname(path), _("Never Clean Its Folder")))
        return row

    def all_ticked(self, g):
        return all(f["path"] in self.selected for f in g["files"])

    def update_group(self, g):
        row, warning = self.group_rows[group_key(g)]
        n = len(g["files"])
        ticked = sum(f["path"] in self.selected for f in g["files"])
        if ticked == n:
            row.set_subtitle(_("Every photo is selected: none would be kept") if self.mode == PHOTOS
                             else _("Every copy is selected: none would be kept"))
        elif self.mode == PHOTOS:
            row.set_subtitle(ngettext("{n} photo, {k} selected", "{n} photos, {k} selected", n, k=ticked))
        else:
            row.set_subtitle(ngettext("{n} copy of {size}, {k} selected", "{n} copies of {size}, {k} selected", n,
                                      size=human(g["bytes"]), k=ticked))
        warning.set_visible(ticked == n)

    def on_toggled(self, check, g, path):
        if check.get_active():
            self.selected.add(path)
        else:
            self.selected.discard(path)
        if self.bulk:
            return
        self.update_group(g)
        self.update_summary()

    def chosen(self):
        """The ticked files of the groups listed: a group the search hides is never moved."""
        return [(g, f) for g in self.listed_groups() for f in g["files"] if f["path"] in self.selected]

    # ── Never clean: a copy's folder goes to Settings › Never clean; searches skip it from then on ──
    def never_clean_folder(self, folder):
        if self.moving or self.excluding:
            return

        def saved():
            for g in self.groups:
                g["files"] = [f for f in g["files"] if not findbar.inside(f["path"], folder)]
            self.selected = {p for p in self.selected if not findbar.inside(p, folder)}
            self.show_results()

        def undone():
            if self.searched and not self.running and not self.moving:
                self.search()

        def ended():
            self.excluding = None

        self.excluding = findbar.never_clean(self, folder, saved, undone, ended)

    def update_summary(self):
        chosen = self.chosen()
        self.summary.set_markup(ngettext("Selected <b>{size}</b> in {n} file", "Selected <b>{size}</b> in {n} files",
                                         len(chosen), size=human(sum(file_bytes(g, f) for g, f in chosen))))
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
                label=ngettext("Every photo of {n} group is selected: none of its photos would be kept.",
                               "Every photo of {n} groups is selected: none of their photos would be kept.",
                               len(whole)) if self.mode == PHOTOS else
                ngettext("Every copy of {n} file is selected: none of its copies would be kept.",
                         "Every copy of {n} files is selected: none of their copies would be kept.",
                         len(whole)),
                xalign=0, wrap=True, css_classes=["warning"], margin_bottom=6))
        for g, f in chosen[:12]:
            row = Gtk.Box(spacing=12)
            row.append(Gtk.Label(label=short_path(f["path"]), xalign=0, hexpand=True,
                                 ellipsize=Pango.EllipsizeMode.START))
            row.append(Gtk.Label(label=human(file_bytes(g, f)), css_classes=["numeric", "dim-label"]))
            lines.append(row)
        if len(chosen) > 12:
            lines.append(Gtk.Label(label=_("… and {n} more").format(n=len(chosen) - 12), xalign=0, css_classes=["dim-label"]))
        dialog = Adw.AlertDialog(
            heading=ngettext("Move {n} file to the Trash?", "Move {n} files to the Trash?", len(chosen)),
            body=_("{size}. You can undo this right away, or restore the files from the Trash later.").format(
                size=human(sum(file_bytes(g, f) for g, f in chosen))),
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
                failed.append(e)
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
                                         len(failed), reason=messages.text(failed[0])) if len(failed) > 1
                                else messages.text(failed[0]))
            if moved:
                self.undo_toast = self.window.toast(msg, _("Undo"), lambda: self.undo(moved), timeout=10)
            else:
                self.window.toast(msg, timeout=6)
            self.window.refresh_disk()

        self.window.set_busy(True)
        self.trash_button.set_sensitive(False)
        self.moving = True
        self.running = self.engine.trash(paths, on_event, on_done,
                                         source="Similar Photos" if self.mode == PHOTOS else "Duplicates")

    def undo(self, moved):
        if self.running or not moved:
            return
        self.undo_toast = None
        back, failed = [], []
        gen = self.generation

        def on_event(e):
            if e["event"] == "error":
                failed.append(e)
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
                        g["files"] = sorted(g["files"] + [f], reverse=True, key=similar.keep_key if "key" in g
                                            else lambda x: x["mtime"])
                self.show_results()
            if failed:
                self.window.toast(_("Put back {back}, {failed} could not be restored: {reason}").format(
                    back=len(back), failed=len(failed), reason=messages.text(failed[0])))
            else:
                self.window.toast(ngettext("Put back {n} file from the Trash", "Put back {n} files from the Trash",
                                           len(back)))
            self.window.refresh_disk()

        self.window.set_busy(True)
        self.moving = True
        self.running = self.engine.restore(list(moved), on_event, on_done)
