"""Space Lens: what takes up the space in a folder, biggest first; open folders to dig deeper,
move what you don't need to the Trash, undo. It starts in your home folder; the Locations menu opens the
whole system disk (/) or any other disk instead.

The engine measures (`--json lens`, never with sudo: a folder you can't read shows as such), says why
something is view only (`reason`), moves (`--json trash --home-only`: your home folder, or a writable
drive mounted for you, into its own Trash) and puts things back (`--json restore`); this page only shows
the list, keeps the choice and links a view-only row to the page that cleans that kind of thing.
"""
import os

from gi.repository import Adw, Gio, GLib, Gtk, Pango

from .a11y import named
from .engine import IN_FLATPAK, human
from .errorview import ErrorPage, Failure
from . import findbar
from .findbar import FindBar
from .i18n import _, ngettext
from .largefiles import short_path
from .preview import open_file, row_buttons, show_in_files
from .scanpage import size_widgets
from . import messages
from .rows import plain_row


def reason_text(reason):
    """Why a row is view only (the engine's `reason`), and the page that cleans that kind of thing, if any."""
    return {
        "excluded": (_("You never clean it, or a folder in it (Settings › Never clean)"), None),
        "home": (_("Your home folder is inside: open it to choose what to move"), None),
        "protected": (_("Your system or apps need it (settings, or a link to a system folder)"), None),
        "drive_top": (_("The drive itself: open it to choose what to move"), None),
        "drive_ro": (_("This drive is read-only or a network drive"), None),
        "drive": (_("The drive's Trash, or reached through a link to elsewhere"), None),
        "backup": (_("A Timeshift backup: delete old snapshots in Timeshift, never by hand"), None),
        "mount": (_("Another disk mounted here: open it to explore"), None),
        "user": (_("Another user's files: only they (or an administrator) can clean them"), None),
        "snap": (_("Snap packages and their data. Old revisions are cleaned in System Junk, apps removed in "
                   "Uninstaller"), "system"),
        "flatpak": (_("Flatpak apps and runtimes. Unused runtimes are removed in Maintenance, apps in Uninstaller"),
                    "maintenance"),
        "docker": (_("Docker images, containers and volumes: clean them in Developer Junk"), "dev"),
        "journal": (_("The systemd journal: old logs are cleaned in Logs"), "logs"),
        "logs": (_("System logs and crash reports: old ones are cleaned in Logs"), "logs"),
        "apt": (_("apt's package cache and lists: the cache is cleaned in System Junk"), "system"),
        "kernels": (_("Kernels and boot files: extra old kernels are removed in System Junk"), "system"),
        "packages": (_("Installed programs and system files: remove apps in Uninstaller"), "uninstall"),
        "temp": (_("Temporary files of the system: old ones are cleaned in System Junk"), "system"),
        "swap": (_("The swap file: extra memory on disk"), None),
    }.get(reason, (_("Part of the system: only an administrator can change it"), None))


def mount_of(path):
    """The folder the disk holding PATH is mounted on."""
    while path != "/" and not os.path.ismount(path):
        path = os.path.dirname(path)
    return path


def is_hidden(e):
    return os.path.basename(e["path"]).startswith(".")


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
        self.locks = {}  # path → the lock icon of a view-only row (its tooltip says why)
        self.links = {}  # path → the page id a view-only row's link opens
        self.shown = []  # the entries listed: all, or without hidden ones
        self.show_hidden = True  # names starting with a dot
        self.places = []  # "place" events: home, the system disk, other disks
        self.crumb_buttons = []  # path bar buttons, root first
        self.all_check = None
        self.syncing = False
        self.running = None  # Gio.Cancellable of the current engine run
        self.moving = False  # a Trash or undo run: never cancelled, nothing else starts meanwhile
        self.generation = 0  # a newer measurement makes an older one's results stale
        self.undo_toast = None
        self.shown_at = None  # the folder whose list is on screen (a stopped measurement goes back to it)
        self.excluding = None  # a Never clean run

        # path bar
        self.up_button = named(Gtk.Button(icon_name="go-up-symbolic", tooltip_text=_("Up one folder"),
                                          valign=Gtk.Align.CENTER))
        self.up_button.connect("clicked", lambda *_a: self.up())
        self.crumbs = Gtk.Box(spacing=2)
        crumbs_scroll = Gtk.ScrolledWindow(child=self.crumbs, hexpand=True, vscrollbar_policy=Gtk.PolicyType.NEVER,
                                           hscrollbar_policy=Gtk.PolicyType.AUTOMATIC)
        crumbs_scroll.set_propagate_natural_height(True)
        actions = Gio.SimpleActionGroup()
        place = Gio.SimpleAction.new("place", GLib.VariantType.new("s"))
        place.connect("activate", lambda _a, v: self.set_root(v.get_string()))
        actions.add_action(place)
        choose = Gio.SimpleAction.new("choose", None)
        choose.connect("activate", lambda *_a: self.choose_folder())
        actions.add_action(choose)
        self.insert_action_group("lens", actions)
        self.places_menu = Gio.Menu()
        self.places_button = named(Gtk.MenuButton(icon_name="drive-harddisk-symbolic", valign=Gtk.Align.CENTER,
                                                  menu_model=self.places_menu,
                                                  tooltip_text=_("Locations: your home folder, the whole system "
                                                                 "disk, other disks or any folder")))
        self.places_button.connect("notify::active", lambda b, _p: b.get_active() and self.load_places())
        self.hidden_button = named(Gtk.ToggleButton(icon_name="view-reveal-symbolic", valign=Gtk.Align.CENTER,
                                                    active=True, tooltip_text=_("Show hidden files (Ctrl+Shift+.)")))
        self.hidden_button.connect("toggled", lambda b: self.set_show_hidden(b.get_active()))
        top = Gtk.Box(spacing=6, margin_top=8, margin_bottom=8, margin_start=12, margin_end=12)
        top.append(self.up_button)
        top.append(crumbs_scroll)
        top.append(self.hidden_button)
        top.append(self.places_button)
        self.append(top)
        self.append(Gtk.Separator())

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True)
        self.append(self.stack)
        measuring = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18, halign=Gtk.Align.CENTER)
        measuring.append(Gtk.Spinner(spinning=True, width_request=32, height_request=32, halign=Gtk.Align.CENTER))
        self.stop_button = Gtk.Button(label=_("Stop"), halign=Gtk.Align.CENTER, css_classes=["pill"])
        self.stop_button.connect("clicked", lambda *_a: self.stop())
        measuring.append(self.stop_button)
        self.measuring = Adw.StatusPage(icon_name=icon, title=_("Measuring…"), child=measuring)
        self.stack.add_named(self.measuring, "measuring")
        again = Gtk.Button(label=_("Measure Again"), halign=Gtk.Align.CENTER, css_classes=["pill", "suggested-action"])
        again.connect("clicked", lambda *_a: self.load(self.folder, fresh=True))
        self.stopped = Adw.StatusPage(icon_name=icon, title=_("Measuring stopped"), child=again)
        self.stack.add_named(self.stopped, "stopped")
        self.empty = Adw.StatusPage(icon_name="folder-symbolic", title=_("This folder is empty"))
        self.stack.add_named(self.empty, "empty")
        self.failed = ErrorPage(window, lambda: self.load(self.folder, fresh=True), title=_("Couldn't measure this folder"))
        self.stack.add_named(self.failed, "failed")
        self.results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24,
                               margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        self.scroll = Gtk.ScrolledWindow(child=Adw.Clamp(maximum_size=900, child=self.results),
                                         vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)
        self.find_bar = FindBar(self.apply_filter, _("Search this folder"))
        results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        results.append(self.find_bar)
        results.append(self.scroll)
        self.stack.add_named(results, "results")
        findbar.never_clean_actions(self, self.never_clean_folder)

        self.bar = Gtk.ActionBar(revealed=False)
        self.summary = Gtk.Label(xalign=0)
        self.bar.pack_start(self.summary)
        self.trash_button = Gtk.Button(label=_("Move to Trash"), css_classes=["destructive-action"])
        self.trash_button.connect("clicked", lambda *_a: self.confirm_trash())
        self.bar.pack_end(self.trash_button)
        again = named(Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text=_("Measure again")))
        again.connect("clicked", lambda *_a: self.load(self.folder, fresh=True))
        self.bar.pack_end(again)
        self.bar.pack_end(self.find_bar.toggle())
        self.append(self.bar)

        keys = Gtk.ShortcutController()
        for accel in ("<Alt>Up", "<Alt>Left", "BackSpace"):
            keys.add_shortcut(Gtk.Shortcut(trigger=Gtk.ShortcutTrigger.parse_string(accel),
                                           action=Gtk.CallbackAction.new(lambda *_a: self.up() or True)))
        for accel in ("<Control><Shift>period", "<Control><Shift>greater", "<Control>h"):
            keys.add_shortcut(Gtk.Shortcut(trigger=Gtk.ShortcutTrigger.parse_string(accel), action=Gtk.CallbackAction.new(
                lambda *_a: self.hidden_button.set_active(not self.hidden_button.get_active()) or True)))
        self.add_controller(keys)

        self.fill_places_menu()
        self.load_places()
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
        """Show one folder with the whole trail in the path bar: from home for a folder in it, else from
        the folder the disk is mounted on (/ for the system disk), so Up goes all the way back."""
        if self.moving:
            return
        home = os.path.expanduser("~")
        if path == home or path.startswith(home + "/"):
            root = home
        elif path == self.root or path.startswith(self.root.rstrip("/") + "/"):
            root = self.root
        else:
            root = mount_of(path)
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
                self.cache.clear()
                self.open_folder(folder.get_path())

        dialog.select_folder(self.window, None, chosen)

    def load_places(self):
        """Ask the engine for the disks again (each time the Locations menu opens: one may have been plugged in)."""
        places = []

        def on_event(e):
            if e["event"] == "place":
                places.append(e)

        def on_done(ok, status):
            if places:
                self.places = places
                self.fill_places_menu()

        self.engine.places(on_event, on_done)

    def fill_places_menu(self):
        self.places_menu.remove_all()
        found = {p["kind"]: p for p in self.places if p["kind"] != "drive"}
        home = found.get("home", {"path": os.path.expanduser("~"), "avail": None})

        def item(label, path):
            entry = Gio.MenuItem.new(label, None)
            entry.set_action_and_target_value("lens.place", GLib.Variant.new_string(path))
            return entry

        spots = Gio.Menu()
        spots.append_item(item(_("Home folder"), home["path"]))
        if not IN_FLATPAK:  # the sandbox sees its own / only
            spots.append_item(item(_("System disk (/)"), "/"))
        self.places_menu.append_section(None, spots)
        disks = Gio.Menu()
        for p in self.places:
            if p["kind"] == "drive":
                disks.append_item(item(_("{disk} · {free} free of {size}").format(
                    disk=os.path.basename(p["path"]) or p["path"], free=human(p["avail"]), size=human(p["size"])),
                    p["path"]))
        if disks.get_n_items():
            self.places_menu.append_section(_("Disks"), disks)
        other = Gio.Menu()
        other.append(_("Choose a Folder…"), "lens.choose")
        self.places_menu.append_section(None, other)

    def place_label(self, path):
        """The first button of the path bar."""
        if path == os.path.expanduser("~"):
            return _("Home")
        if path == "/":
            return _("System disk")
        if path == self.info.get("drive") or any(p["path"] == path and p["kind"] == "drive" for p in self.places):
            return os.path.basename(path) or path
        return short_path(path)

    def up(self):
        if self.folder != self.root:
            self.load(os.path.dirname(self.folder))

    def update_crumbs(self):
        child = self.crumbs.get_first_child()
        while child:
            self.crumbs.remove(child)
            child = self.crumbs.get_first_child()
        self.crumb_buttons = []
        parts = [(self.place_label(self.root), self.root)]
        rel = os.path.relpath(self.folder, self.root)
        if rel != "." and not rel.startswith(".."):
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

    def find(self):
        """Ctrl+F: show only the files and folders here whose name has every word typed."""
        if self.stack.get_visible_child_name() == "results":
            self.find_bar.open()

    def stop(self):
        """End the measurement at once (the engine and the du it started); the folder shown before comes back."""
        if not self.running or self.moving:
            return
        self.running.cancel()
        self.running = None
        self.generation += 1  # its answer is dropped
        self.window.set_busy(False)
        self.window.toast(_("Measuring stopped"))
        if self.shown_at is not None:
            self.folder = self.shown_at
            self.update_crumbs()
            self.show_results()
        else:
            self.stopped.set_description(short_path(self.folder))
            self.stack.set_visible_child_name("stopped")

    def load(self, path, fresh=False):
        if self.moving:
            return
        if self.running:
            self.running.cancel()
            self.running = None
            self.window.set_busy(False)
        self.generation += 1
        gen = self.generation
        if path != self.folder:
            self.find_bar.set_search_mode(False)  # another folder: the words were for this one
        self.folder = path
        self.selected.clear()
        self.update_crumbs()
        if fresh:
            self.cache.pop(path, None)
        if path in self.cache:
            self.entries, self.info = self.cache[path]
            return self.show_results()
        entries, info = [], {}
        failure = Failure("cm --json lens", self.engine.env.get("HOME"))
        self.measuring.set_description(_("Adding up {folder}").format(folder=short_path(path)))
        self.stack.set_visible_child_name("measuring")
        self.bar.set_revealed(False)
        self.window.set_busy(True)

        def on_event(e):
            failure.see(e)
            if e["event"] == "entry":
                entries.append(e)
            elif e["event"] in ("done", "error"):
                info.update(e)

        def on_done(ok, status):
            if gen != self.generation:
                return  # replaced by a newer measurement
            self.running = None
            self.window.set_busy(False)
            if failure.failed and "bytes" not in info:  # no answer: an error, never "this folder is empty"
                self.entries, self.info = [], {}
                self.failed.show(failure)
                self.stack.set_visible_child_name("failed")
                self.bar.set_revealed(False)
                return
            if "message" in info:
                self.window.toast(messages.text(info))
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
    def set_show_hidden(self, show):
        """Ctrl+Shift+. or the eye button: list names starting with a dot, or leave them out (the folder's total
        stays; one row sums them up). What gets hidden is unticked."""
        if show == self.show_hidden:
            return
        self.show_hidden = show
        if self.hidden_button.get_active() != show:
            self.hidden_button.set_active(show)
        if not show:
            self.selected -= {e["path"] for e in self.entries if is_hidden(e)}
        if self.stack.get_visible_child_name() != "measuring":
            self.show_results()

    def show_results(self):
        child = self.results.get_first_child()
        while child:
            self.results.remove(child)
            child = self.results.get_first_child()
        self.checks.clear()
        self.rows.clear()
        self.locks.clear()
        self.links.clear()
        self.all_check = None
        self.shown_at = self.folder
        self.shown = [e for e in self.entries if self.show_hidden or not is_hidden(e)]
        hidden = [] if self.show_hidden else [e for e in self.entries if is_hidden(e)]
        if not self.entries:
            if self.info.get("denied"):
                self.empty.set_title(_("No permission to read this folder"))
                self.empty.set_description(_("{folder} · only an administrator can see inside").format(
                    folder=short_path(self.folder)))
            else:
                self.empty.set_title(_("This folder is empty"))
                self.empty.set_description(short_path(self.folder))
            self.stack.set_visible_child_name("empty")
            self.bar.set_revealed(False)
            return

        total = self.info.get("bytes") or sum(e["bytes"] for e in self.entries if e["kind"] != "mount")
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
        for text in self.header_notes(total):
            header.append(Gtk.Label(label=text, xalign=0, wrap=True, css_classes=["dim-label"]))
        self.results.append(header)

        group = Adw.PreferencesGroup()
        if sum(e["movable"] for e in self.shown) > 1:
            self.all_check = Gtk.CheckButton(label=_("All"), valign=Gtk.Align.CENTER, css_classes=["big-check"],
                                             tooltip_text=_("Select or deselect every item"))
            self.all_check.connect("toggled", self.on_all_toggled)
            group.set_header_suffix(self.all_check)
        # the bars compare with the biggest entry of this folder; another disk mounted here can be much bigger
        biggest = max([e["bytes"] for e in self.entries if e["kind"] != "mount"] or [e["bytes"] for e in self.entries])
        for e in self.shown:
            group.add(self.entry_row(e, biggest, total))
        if hidden:
            row = plain_row(Adw.ActionRow, title=ngettext("{n} hidden item", "{n} hidden items", len(hidden)),
                                subtitle=_("Names starting with a dot · Ctrl+Shift+. shows them"),
                                css_classes=["item-row"])
            row.add_prefix(Gtk.Image(icon_name="view-conceal-symbolic"))
            for widget in size_widgets(sum(e["bytes"] for e in hidden), biggest):
                row.add_suffix(widget)
            self.rows["hidden"] = row
            group.add(row)
        self.results.append(group)
        self.stack.set_visible_child_name("results")
        self.scroll.get_vadjustment().set_value(0)
        self.bar.set_revealed(True)
        self.apply_filter()

    def apply_filter(self):
        """Ctrl+F: only the rows whose name has every word typed (the hidden items' row only without words)."""
        words = self.find_bar.words()
        for path, row in self.rows.items():
            row.set_visible(not words if path == "hidden" else findbar.matches(words, os.path.basename(path)))
        self.update_summary()

    def listed(self):
        """The entries listed and not hidden by the search."""
        return [e for e in self.shown if e["path"] not in self.rows or self.rows[e["path"]].get_visible()]

    # ── Never clean: a folder here goes to Settings › Never clean; it is view only from then on ──
    def never_clean_folder(self, folder):
        if self.moving or self.excluding:
            return

        def again():
            self.cache.clear()  # the folders above it changed too: view only, or not any more
            if not self.running and not self.moving:
                self.load(self.folder, fresh=True)

        def ended():
            self.excluding = None

        self.excluding = findbar.never_clean(self, folder, again, again, ended)

    def header_notes(self, total):
        """The lines under the title: view only and why, how the folder adds up to the disk, what couldn't be read."""
        notes = []
        if self.info.get("excluded"):
            notes.append(_("View only: you never clean this folder (Settings › Never clean)."))
        elif not any(e["movable"] for e in self.entries):
            if self.info.get("drive") and not self.info.get("drive_trash"):
                notes.append(_("View only: this drive is read-only or a network drive."))
            elif self.info.get("drive_trash"):
                notes.append(_("View only: nothing here can be moved to the Trash (the drive itself, its Trash or "
                               "a backup)."))
            else:
                notes.append(_("View only: things outside your home folder and your drives can't be moved to the "
                               "Trash here. Each row's lock says why, and the arrow opens the page that cleans it."))
        used = self.info.get("disk_used")
        if used:
            notes.append(_("{used} in use on this disk; the list adds up to {listed}.").format(
                used=human(used), listed=human(total)))
            if used - total > used // 100:
                notes.append(_("{size} not counted: folders only an administrator can read, and files deleted "
                               "while a program still has them open.").format(size=human(used - total)))
        unread = self.info.get("unreadable", 0)
        if unread:
            notes.append(ngettext("{n} folder couldn't be read without administrator rights; the sizes leave it out.",
                                  "{n} folders couldn't be read without administrator rights; the sizes leave them "
                                  "out.", unread))
        return notes

    def page_title(self, pid):
        """The sidebar title of a page, or None when this app has no such page (the Flatpak hides some)."""
        from .window import PAGES  # the window imports this module
        return next((s[1] for s in PAGES if s and s[0] == pid), None)

    def entry_row(self, e, biggest, total):
        path = e["path"]
        share = percent(e["bytes"], total)
        if e.get("denied"):
            subtitle = _("No permission to read · only an administrator can see inside")
        elif e["kind"] == "mount":
            subtitle = _("Another disk · {used} in use").format(used=human(e["bytes"]))
        elif e["kind"] == "dir":
            subtitle = ngettext("{n} item · {percent}", "{n} items · {percent}", e["count"], percent=share)
        else:
            subtitle = share
        if e.get("unreadable") and not e.get("denied"):
            subtitle += " · " + ngettext("{n} folder inside couldn't be read", "{n} folders inside couldn't be read",
                                         e["unreadable"])
        row = plain_row(Adw.ActionRow, title=os.path.basename(path), subtitle=subtitle, subtitle_lines=1,
                            css_classes=["item-row"], tooltip_text=path)
        row.add_prefix(Gtk.Image(gicon=entry_icon(e)))
        if e["movable"]:
            check = Gtk.CheckButton(active=path in self.selected, valign=Gtk.Align.CENTER, css_classes=["big-check"])
            check.connect("toggled", self.on_toggled, path)
            self.checks[path] = check
            row.add_prefix(check)  # prefixes stack leftwards: the box comes first
        else:  # view only: a lock that says why, no box
            text, pid = reason_text(e.get("reason") or ("excluded" if e.get("excluded") else ""))
            lock = named(Gtk.Image(icon_name="changes-prevent-symbolic", css_classes=["dim-label"],
                                   tooltip_text=_("View only: {reason}").format(reason=text)))
            self.locks[path] = lock
            row.add_prefix(lock)
            title = self.page_title(pid) if pid else None
            if title:
                link = named(Gtk.Button(icon_name="go-jump-symbolic", valign=Gtk.Align.CENTER, css_classes=["flat"],
                                        tooltip_text=_("Clean it in {page}").format(page=title)))
                link.connect("clicked", lambda *_a, p=pid: self.window.go_to(p))
                self.links[path] = pid
                row.add_suffix(link)
        self.rows[path] = row
        if e.get("denied"):
            row.add_suffix(Gtk.Label(label=_("no permission"), width_chars=9, xalign=1,
                                     css_classes=["numeric", "dim-label"]))
        else:
            for widget in size_widgets(e["bytes"], biggest):
                row.add_suffix(widget)
        if e["kind"] == "file":
            row_buttons(row, self.window, path)  # Open, Show in Files; Enter opens it
        else:
            for icon, tip, action in (("document-open-symbolic", _("Open"), open_file),
                                      ("folder-open-symbolic", _("Show in Files"), show_in_files)):
                button = named(Gtk.Button(icon_name=icon, valign=Gtk.Align.CENTER, css_classes=["flat"],
                                          tooltip_text=tip))
                button.connect("clicked", lambda *_a, act=action: act(self.window, path))
                row.add_suffix(button)
        if e["kind"] == "dir" and e["movable"] and findbar.can_exclude(self.engine, path):
            row.add_suffix(findbar.never_clean_button(path))
        if e["kind"] in ("dir", "mount") and not e.get("denied"):  # a click opens the folder; the box ticks it
            row.add_suffix(Gtk.Image(icon_name="go-next-symbolic"))
            row.set_activatable(True)
            row.connect("activated", lambda *_a: self.load(path))
        elif e["movable"]:
            row.set_activatable_widget(self.checks[path])
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
        for e in self.listed():
            check = self.checks.get(e["path"])
            if check and check.get_sensitive():
                check.set_active(target)

    def chosen(self):
        """The ticked entries listed: one the search hides is never moved."""
        return [e for e in self.listed() if e["path"] in self.selected]

    def update_summary(self):
        chosen = self.chosen()
        self.summary.set_markup(ngettext("Selected <b>{size}</b> in {n} item", "Selected <b>{size}</b> in {n} items",
                                         len(chosen), size=human(sum(e["bytes"] for e in chosen))))
        self.trash_button.set_sensitive(bool(chosen) and not self.running)
        if self.all_check:
            movable = sum(e["movable"] for e in self.listed())
            self.syncing = True  # none / some (inconsistent) / all
            self.all_check.set_inconsistent(0 < len(chosen) < movable)
            self.all_check.set_active(movable > 0 and len(chosen) == movable)
            self.syncing = False

    # ── Trash and undo ──
    def confirm_trash(self):
        chosen = self.chosen()
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
                failed.append(e)
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
                                         len(failed), reason=messages.text(failed[0])) if len(failed) > 1
                                else messages.text(failed[0]))
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
                failed.append(e)
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
                    back=len(back), failed=len(failed), reason=messages.text(failed[0])))
            else:
                self.window.toast(ngettext("Put back {n} item from the Trash", "Put back {n} items from the Trash",
                                           len(back)))

        self.window.set_busy(True)
        self.moving = True
        self.running = self.engine.restore(list(moved), on_event, on_done)
