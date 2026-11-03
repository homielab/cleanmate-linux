"""Space Lens: what takes up the space in a folder, biggest first; open folders to dig deeper,
move what you don't need to the Trash, undo.

The engine measures (`--json lens`), moves (`--json trash --home-only`: your home folder, or a
writable drive mounted for you, into its own Trash) and puts things back (`--json restore`); this page
only shows the list and keeps the choice.
"""
import os

from gi.repository import Adw, Gio, GLib, Gtk, Pango

from .a11y import named
from .engine import human
from .i18n import _, ngettext
from .largefiles import short_path
from .scanpage import size_widgets


def entry_icon(e):
    if e["kind"] == "dir":
        return Gio.ThemedIcon.new("folder-symbolic")
    content_type = Gio.content_type_guess(os.path.basename(e["path"]), None)[0]
    return Gio.content_type_get_symbolic_icon(content_type)


def percent(n, total):
    if n <= 0 or total <= 0:
        return "0%"
    share = n * 100 / total
    return "<1%" if share < 1 else f"{min(round(share), 100)}%"


class SpaceLensPage(Gtk.Box):
    """Path bar on top; the folder's entries below, biggest first, with checkboxes."""

    def __init__(self, window, title, icon, description):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self.engine = window.engine
        self.root = os.path.expanduser("~")  # where the path bar starts
        self.folder = self.root  # the folder shown
        self.entries = []  # "entry" events of the folder shown, biggest first
        self.info = {}  # its "done" event
        self.cache = {}  # folder → (entries, info): going back is instant
        self.selected = set()  # paths, in the folder shown
        self.checks = {}  # path → Gtk.CheckButton
        self.rows = {}  # path → Adw.ActionRow
        self.crumb_buttons = []  # path bar buttons, root first
        self.all_check = None
        self.syncing = False
        self.running = None  # Gio.Cancellable of the current engine run
        self.moving = False  # a Trash or undo run: never cancelled, nothing else starts meanwhile
        self.generation = 0  # a newer measurement makes an older one's results stale
        self.undo_toast = None

        # path bar
        self.up_button = named(Gtk.Button(icon_name="go-up-symbolic", tooltip_text=_("Up one folder"),
                                          valign=Gtk.Align.CENTER))
        self.up_button.connect("clicked", lambda *_a: self.up())
        self.crumbs = Gtk.Box(spacing=2)
        crumbs_scroll = Gtk.ScrolledWindow(child=self.crumbs, hexpand=True, vscrollbar_policy=Gtk.PolicyType.NEVER,
                                           hscrollbar_policy=Gtk.PolicyType.AUTOMATIC)
        crumbs_scroll.set_propagate_natural_height(True)
        folder_button = named(Gtk.Button(icon_name="folder-open-symbolic", valign=Gtk.Align.CENTER,
                                         tooltip_text=_("Explore another folder (also a drive)")))
        folder_button.connect("clicked", lambda *_a: self.choose_folder())
        top = Gtk.Box(spacing=6, margin_top=8, margin_bottom=8, margin_start=12, margin_end=12)
        top.append(self.up_button)
        top.append(crumbs_scroll)
        top.append(folder_button)
        self.append(top)
        self.append(Gtk.Separator())

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True)
        self.append(self.stack)
        spinner = Gtk.Spinner(spinning=True, width_request=32, height_request=32, halign=Gtk.Align.CENTER)
        self.measuring = Adw.StatusPage(icon_name=icon, title=_("Measuring…"), child=spinner)
        self.stack.add_named(self.measuring, "measuring")
        self.empty = Adw.StatusPage(icon_name="folder-symbolic", title=_("This folder is empty"))
        self.stack.add_named(self.empty, "empty")
        self.results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24,
                               margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        self.scroll = Gtk.ScrolledWindow(child=Adw.Clamp(maximum_size=900, child=self.results),
                                         vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)
        self.stack.add_named(self.scroll, "results")

        self.bar = Gtk.ActionBar(revealed=False)
        self.summary = Gtk.Label(xalign=0)
        self.bar.pack_start(self.summary)
        self.trash_button = Gtk.Button(label=_("Move to Trash"), css_classes=["destructive-action"])
        self.trash_button.connect("clicked", lambda *_a: self.confirm_trash())
        self.bar.pack_end(self.trash_button)
        again = named(Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text=_("Measure again")))
        again.connect("clicked", lambda *_a: self.load(self.folder, fresh=True))
        self.bar.pack_end(again)
        self.append(self.bar)

        keys = Gtk.ShortcutController()
        for accel in ("<Alt>Up", "<Alt>Left", "BackSpace"):
            keys.add_shortcut(Gtk.Shortcut(trigger=Gtk.ShortcutTrigger.parse_string(accel),
                                           action=Gtk.CallbackAction.new(lambda *_a: self.up() or True)))
        self.add_controller(keys)

        self.load(self.folder)

    # ── where we are ──
    def set_root(self, path):
        """Explore another folder from scratch (the folder button, or the self-test)."""
        if self.moving:
            return
        self.root = path
        self.cache.clear()
        self.load(path)

    def open_folder(self, path):
        """Show one folder; inside home the path bar still starts at home, so Up goes back there."""
        if self.moving:
            return
        home = os.path.expanduser("~")
        root = home if path == home or path.startswith(home + "/") else path
        if root != self.root:
            self.root = root
            self.cache.clear()
        self.load(path)

    def choose_folder(self):
        dialog = Gtk.FileDialog(title=_("Folder to explore"), initial_folder=Gio.File.new_for_path(self.folder))

        def chosen(d, result):
            try:
                folder = d.select_folder_finish(result)
            except GLib.Error:
                return  # cancelled
            if folder and folder.get_path():
                self.set_root(folder.get_path())

        dialog.select_folder(self.window, None, chosen)

    def up(self):
        if self.folder != self.root:
            self.load(os.path.dirname(self.folder))

    def update_crumbs(self):
        child = self.crumbs.get_first_child()
        while child:
            self.crumbs.remove(child)
            child = self.crumbs.get_first_child()
        self.crumb_buttons = []
        home = os.path.expanduser("~")
        if self.root == home:
            first = _("Home")
        elif self.root == self.info.get("drive"):
            first = os.path.basename(self.root)
        else:
            first = short_path(self.root)
        parts = [(first, self.root)]
        rel = os.path.relpath(self.folder, self.root)
        if rel != ".":
            path = self.root
            for name in rel.split(os.sep):
                path = os.path.join(path, name)
                parts.append((name, path))
        for i, (label, path) in enumerate(parts):
            if i:
                self.crumbs.append(Gtk.Label(label="›", css_classes=["dim-label"]))
            last = i == len(parts) - 1
            text = Gtk.Label(label=label, ellipsize=Pango.EllipsizeMode.MIDDLE, max_width_chars=24,
                             css_classes=["heading"] if last else [])
            button = Gtk.Button(child=text, css_classes=["flat"], tooltip_text=path)
            button.connect("clicked", lambda _b, p=path: self.load(p))
            self.crumbs.append(button)
            self.crumb_buttons.append(button)
        self.up_button.set_sensitive(self.folder != self.root)

    # ── measuring ──
    def reload(self):
        """Ctrl+R: measure the open folder again, unless a measurement or a Trash run is going."""
        if not self.running and not self.moving:
            self.load(self.folder, fresh=True)

    def load(self, path, fresh=False):
        if self.moving:
            return
        if self.running:
            self.running.cancel()
            self.running = None
            self.window.set_busy(False)
        self.generation += 1
        gen = self.generation
        self.folder = path
        self.selected.clear()
        self.update_crumbs()
        if fresh:
            self.cache.pop(path, None)
        if path in self.cache:
            self.entries, self.info = self.cache[path]
            return self.show_results()
        entries, info = [], {}
        self.measuring.set_description(_("Adding up {folder}").format(folder=short_path(path)))
        self.stack.set_visible_child_name("measuring")
        self.bar.set_revealed(False)
        self.window.set_busy(True)

        def on_event(e):
            if e["event"] == "entry":
                entries.append(e)
            elif e["event"] in ("done", "error"):
                info.update(e)

        def on_done(ok, status):
            if gen != self.generation:
                return  # replaced by a newer measurement
            self.running = None
            self.window.set_busy(False)
            if "message" in info:
                self.window.toast(info["message"])
            elif ok:
                self.cache[path] = (entries, info)
            self.entries, self.info = entries, info
            drive = info.get("drive")
            if drive and self.root.startswith(drive + "/"):
                self.root = drive  # on a drive the path bar starts at the drive
            self.update_crumbs()
            self.show_results()

        self.running = self.engine.lens(path, on_event, on_done)

    # ── results ──
    def show_results(self):
        child = self.results.get_first_child()
        while child:
            self.results.remove(child)
            child = self.results.get_first_child()
        self.checks.clear()
        self.rows.clear()
        self.all_check = None
        if not self.entries:
            self.empty.set_description(short_path(self.folder))
            self.stack.set_visible_child_name("empty")
            self.bar.set_revealed(False)
            return

        total = self.info.get("bytes") or sum(e["bytes"] for e in self.entries)
        name = os.path.basename(self.folder.rstrip("/")) or self.folder
        title = Gtk.Label(label=_("{folder} · {size}").format(folder=name, size=human(total)), xalign=0, wrap=True,
                          css_classes=["title-1"])
        found = self.info.get("found", len(self.entries))
        sub = ngettext("{n} item, biggest first", "{n} items, biggest first", found)
        if found > len(self.entries):
            sub += " — " + _("the {n} biggest of {found}").format(n=len(self.entries), found=found)
        header = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        header.append(title)
        header.append(Gtk.Label(label=sub, xalign=0, wrap=True, css_classes=["dim-label"]))
        if self.info.get("excluded"):
            header.append(Gtk.Label(label=_("View only: you never clean this folder (Settings › Never clean)."),
                                    xalign=0, wrap=True, css_classes=["dim-label"]))
        elif not any(e["movable"] for e in self.entries):
            if self.info.get("drive") and not self.info.get("drive_trash"):
                text = _("View only: this drive is read-only or a network drive.")
            elif self.info.get("drive_trash"):
                text = _("View only: nothing here can be moved to the Trash (the drive itself, its Trash or a backup).")
            else:
                text = _("View only: things outside your home folder and your drives can't be moved to the Trash here.")
            header.append(Gtk.Label(label=text, xalign=0, wrap=True, css_classes=["dim-label"]))
        self.results.append(header)

        group = Adw.PreferencesGroup()
        if sum(e["movable"] for e in self.entries) > 1:
            self.all_check = Gtk.CheckButton(label=_("All"), valign=Gtk.Align.CENTER, css_classes=["big-check"],
                                             tooltip_text=_("Select or deselect every item"))
            self.all_check.connect("toggled", self.on_all_toggled)
            group.set_header_suffix(self.all_check)
        biggest = self.entries[0]["bytes"]
        for e in self.entries:
            group.add(self.entry_row(e, biggest, total))
        self.results.append(group)
        self.stack.set_visible_child_name("results")
        self.scroll.get_vadjustment().set_value(0)
        self.bar.set_revealed(True)
        self.update_summary()

    def entry_row(self, e, biggest, total):
        path = e["path"]
        share = percent(e["bytes"], total)
        if e["kind"] == "dir":
            subtitle = ngettext("{n} item · {percent}", "{n} items · {percent}", e["count"], percent=share)
        else:
            subtitle = share
        row = Adw.ActionRow(title=os.path.basename(path), subtitle=subtitle, use_markup=False, subtitle_lines=1,
                            css_classes=["item-row"], tooltip_text=path)
        check = Gtk.CheckButton(active=path in self.selected, valign=Gtk.Align.CENTER, css_classes=["big-check"],
                                sensitive=e["movable"])
        if e.get("excluded"):
            check.set_tooltip_text(_("Can't be moved to the Trash: you never clean it, or a folder in it "
                                     "(Settings › Never clean)"))
        elif not e["movable"]:
            check.set_tooltip_text(_("Can't be moved to the Trash here: it's outside your home folder and your "
                                     "writable drives, or your system or a backup needs it"))
        check.connect("toggled", self.on_toggled, path)
        self.checks[path] = check
        self.rows[path] = row
        row.add_prefix(Gtk.Image(gicon=entry_icon(e)))
        row.add_prefix(check)  # prefixes stack leftwards: the box comes first
        for widget in size_widgets(e["bytes"], biggest):
            row.add_suffix(widget)
        show = named(Gtk.Button(icon_name="folder-open-symbolic", valign=Gtk.Align.CENTER, css_classes=["flat"],
                                tooltip_text=_("Show in Files")))
        show.connect("clicked", lambda *_a: Gtk.FileLauncher.new(Gio.File.new_for_path(path))
                     .open_containing_folder(self.window, None, None))
        row.add_suffix(show)
        if e["kind"] == "dir":  # a click opens the folder; the box ticks it
            row.add_suffix(Gtk.Image(icon_name="go-next-symbolic"))
            row.set_activatable(True)
            row.connect("activated", lambda *_a: self.load(path))
        elif e["movable"]:
            row.set_activatable_widget(check)
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
            if check.get_sensitive():
                check.set_active(target)

    def update_summary(self):
        chosen = [e for e in self.entries if e["path"] in self.selected]
        self.summary.set_markup(ngettext("Selected <b>{size}</b> in {n} item", "Selected <b>{size}</b> in {n} items",
                                         len(chosen), size=human(sum(e["bytes"] for e in chosen))))
        self.trash_button.set_sensitive(bool(chosen) and not self.running)
        if self.all_check:
            movable = sum(e["movable"] for e in self.entries)
            self.syncing = True  # none / some (inconsistent) / all
            self.all_check.set_inconsistent(0 < len(chosen) < movable)
            self.all_check.set_active(len(chosen) == movable)
            self.syncing = False

    # ── Trash and undo ──
    def confirm_trash(self):
        chosen = [e for e in self.entries if e["path"] in self.selected]
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
            heading=ngettext("Move {n} item to the Trash?", "Move {n} items to the Trash?", len(chosen)),
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

    def after_move(self):
        """Every folder above what moved changed size: measure the one shown again."""
        self.running, self.moving = None, False
        self.window.set_busy(False)
        self.cache.clear()
        self.load(self.folder)
        self.window.refresh_disk()

    def trash(self, paths):
        if self.running or not paths:
            return
        moved = []  # names in the Trash, for undo
        failed, freed, n = [], 0, 0

        def on_event(e):
            nonlocal freed, n
            if e["event"] == "error":
                failed.append({"info": e["message"]})
            if e["event"] != "task":
                return
            if e["state"] == "ok":
                freed += e["freed"]
                n += 1
                if e["trash"] and not self.engine.dry_run:
                    moved.append(e["trash"])
            else:
                failed.append(e)

        def on_done(ok, status):
            if self.engine.dry_run:
                self.running, self.moving = None, False
                self.window.set_busy(False)
                self.update_summary()
                self.window.toast(ngettext("Dry run: {n} item ({size}) would be moved to the Trash",
                                           "Dry run: {n} items ({size}) would be moved to the Trash", n,
                                           size=human(freed)))
                return
            self.after_move()
            msg = ngettext("Moved {n} item ({size}) to the Trash", "Moved {n} items ({size}) to the Trash", n,
                           size=human(freed)) if n else _("Nothing was moved")
            if failed:
                msg += " — " + (ngettext("{n} could not be moved: {reason}", "{n} could not be moved: {reason}",
                                         len(failed), reason=failed[0]["info"]) if len(failed) > 1
                                else failed[0]["info"])
            if moved:
                self.undo_toast = self.window.toast(msg, _("Undo"), lambda: self.undo(moved), timeout=10)
            else:
                self.window.toast(msg, timeout=6)

        self.window.set_busy(True)
        self.trash_button.set_sensitive(False)
        self.moving = True
        self.running = self.engine.trash(paths, on_event, on_done, home_only=True, source="Space Lens")

    def undo(self, moved):
        if self.moving or not moved:
            return
        if self.running:  # a measurement: the undo matters more
            self.running.cancel()
            self.running = None
            self.window.set_busy(False)
            self.generation += 1
        self.undo_toast = None
        back, failed = [], []

        def on_event(e):
            if e["event"] == "error":
                failed.append({"info": e["message"]})
            if e["event"] != "task":
                return
            if e["state"] == "ok":
                back.append(e["id"])
            else:
                failed.append(e)

        def on_done(ok, status):
            self.after_move()
            if failed:
                self.window.toast(_("Put back {back}, {failed} could not be restored: {reason}").format(
                    back=len(back), failed=len(failed), reason=failed[0]["info"]))
            else:
                self.window.toast(ngettext("Put back {n} item from the Trash", "Put back {n} items from the Trash",
                                           len(back)))

        self.window.set_busy(True)
        self.moving = True
        self.running = self.engine.restore(list(moved), on_event, on_done)
