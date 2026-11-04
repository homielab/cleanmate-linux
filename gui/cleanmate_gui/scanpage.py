"""One scan page: start → scanning → results (checkboxes, sizes) → cleaning."""
import time
from urllib.parse import unquote

from gi.repository import Adw, Gio, GLib, GObject, Gtk, Pango

from .a11y import named
from .engine import (CAT_GROUP, CATEGORY_TITLES, FLATPAK_LIMITS_URL, IN_FLATPAK, PACKAGE_HINT, PACKAGE_NEEDED,
                     SMART_SCAN, human)
from .errorview import ErrorPage, Failure, last_line, pkexec_reason
from .i18n import _, detail_text, item_text, ngettext, note_text, why_running
from .preview import open_file
from .settings import short_path
from . import messages
from .rows import plain_row


# Items whose clean-all removes something else than the parts listed (`docker volume prune` keeps named
# volumes, `docker image prune -a` also takes dangling images): once listed, Clean removes just the ticked parts.
BY_ENTRY = {"docker_volumes", "docker_images"}


def entry_note(note):
    """The subtitle of a part, from the engine's note."""
    return {"anonymous": _("Anonymous volume"), "data": _("Named volume — may hold data")}.get(note, "")


def size_class(n):
    if n >= 1 << 30:
        return "size-large"
    if n >= 100 << 20:
        return "size-medium"
    return "size-small" if n > 0 else "dim-label"


def size_widgets(n, biggest):
    """The size column every list shares: a bar relative to the biggest row, then the size."""
    bar = Gtk.LevelBar(min_value=0, max_value=1, value=max(n / max(biggest, 1), 0.02),
                       width_request=90, valign=Gtk.Align.CENTER)
    bar.remove_offset_value("low")
    bar.remove_offset_value("high")
    bar.remove_offset_value("full")
    size = Gtk.Label(label=human(n), width_chars=9, xalign=1, css_classes=["numeric", size_class(n)])
    return bar, size


class ScanPage(Gtk.Box):
    """Scan some categories, review the results, clean the selection."""

    def __init__(self, window, title, categories, icon, description):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self.engine = window.engine
        self.title = title
        self.categories = categories
        self.privacy = categories == ["privacy"]
        self.smart = categories == SMART_SCAN  # the engine leaves out the groups turned off in Settings
        self.groups = [] if self.smart else sorted({CAT_GROUP.get(c, c) for c in categories})
        self.items = {}  # id → item event (from the last scan)
        self.selected = {}  # id → bool
        self.checks = {}  # id → Gtk.CheckButton
        self.group_buttons = []  # (tri-state check, ids)
        self.entries = {}  # item id → its "entry" events (Docker images, volumes, build-cache records), once loaded
        self.entry_selected = {}  # item id → set of ticked entry ids
        self.entry_checks = {}  # item id → {entry id → Gtk.CheckButton}
        self.size_labels = {}  # item id → its size label ("selected / total" when only some entries are ticked)
        self.syncing = False
        self.entry_syncing = False  # checkboxes moved by the page while syncing an item and its entries
        self.running = None  # Gio.Cancellable of the current engine run
        self.trashed = {}  # item id → Trash keys of the last clean (what Undo puts back)
        self.undo_toast = None  # the toast offering Undo after a clean that moved items to the Trash
        self.restoring = None  # Gio.Cancellable of the Undo run
        self.scan_again = False  # Undo finished during a scan: scan once more to show what came back
        self.scan_info = {}  # the scan's "done" event
        self.stopping = False  # Stop was pressed: the engine is ending the scan early
        self.stopped = False  # the results are those of a stopped scan
        self.clean_summary = None  # what the last clean did; its card stays until the user scans again
        self.excluding = None  # Gio.Cancellable of a Never clean change
        self.summary_undo = None  # the Undo button of the clean summary card
        self.summary_empty = None  # its Empty Trash… button
        self.item_rows = {}  # item id → its row
        self.entry_rows = {}  # item id → {entry id → row}
        self.group_rows = []  # (group, junk ids, "more items are clean" row or None, [(clean row, item)])
        self.gone = set()  # items whose every entry went to Never clean: hidden until the next scan

        if IN_FLATPAK and {"system", "logs"} & set(categories):
            banner = Adw.Banner(title=_("System files are out of the Flatpak's reach: the package cache, system "
                                        "logs and old kernels need the .deb version."),
                                button_label=_("Learn More"), revealed=True)
            banner.connect("button-clicked",
                           lambda *_: Gtk.UriLauncher.new(FLATPAK_LIMITS_URL).launch(window, None, None))
            self.append(banner)

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True)
        self.append(self.stack)

        # 1. start
        button = Gtk.Button(label=_("Scan"), halign=Gtk.Align.CENTER)
        button.add_css_class("pill")
        button.add_css_class("suggested-action")
        button.connect("clicked", lambda *_: self.scan())
        start = Adw.StatusPage(icon_name=icon, title=title, description=description, child=button)
        self.stack.add_named(start, "start")

        # 1b. the page's group is turned off in Settings › Scan groups
        turn_on = Gtk.Button(label=_("Turn On"), halign=Gtk.Align.CENTER, css_classes=["pill", "suggested-action"])
        turn_on.connect("clicked", lambda *_: self.turn_on())
        self.stack.add_named(Adw.StatusPage(icon_name=icon, title=title, child=turn_on,
                                            description=_("This group is turned off in Settings, so Smart Scan "
                                                          "leaves it out.")), "off")

        # 2. scanning
        self.progress = Gtk.ProgressBar(show_text=False, width_request=320, halign=Gtk.Align.CENTER)
        self.progress_label = Gtk.Label(css_classes=["dim-label"], ellipsize=Pango.EllipsizeMode.END)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, halign=Gtk.Align.CENTER)
        box.append(self.progress)
        box.append(self.progress_label)
        self.stop_button = Gtk.Button(label=_("Stop"), halign=Gtk.Align.CENTER, css_classes=["pill"],
                                      tooltip_text=_("Stop and show what was checked so far"))
        self.stop_button.connect("clicked", lambda *_: self.stop())
        box.append(self.stop_button)
        scanning = Adw.StatusPage(icon_name="system-search-symbolic", title=_("Scanning…"), child=box)
        self.stack.add_named(scanning, "scanning")

        # 2b. the engine failed before it answered: an error, never "your system is clean"
        self.failed = ErrorPage(window, lambda: self.scan(), title=_("The scan failed"))
        self.stack.add_named(self.failed, "failed")

        # 3. results (filled in by show_results)
        self.results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24,
                               margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        clamp = Adw.Clamp(maximum_size=820, child=self.results)
        self.search_entry = Gtk.SearchEntry(placeholder_text=_("Search results"), hexpand=True)
        self.search_entry.connect("search-changed", lambda *_: self.apply_filter())
        self.search_bar = Gtk.SearchBar(child=Adw.Clamp(maximum_size=820, child=self.search_entry))
        self.search_bar.connect_entry(self.search_entry)
        self.search_bar.connect("notify::search-mode-enabled",
                                lambda b, _p: b.get_search_mode() or self.search_entry.set_text(""))
        results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        results.append(self.search_bar)
        results.append(Gtk.ScrolledWindow(child=clamp, vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER))
        self.stack.add_named(results, "results")

        # 4. cleaning
        self.clean_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE, css_classes=["boxed-list"])
        self.clean_progress = Gtk.ProgressBar()
        self.clean_title = Gtk.Label(css_classes=["title-2"], xalign=0)
        cbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18,
                       margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        cbox.append(self.clean_title)
        self.clean_disks = Gtk.Label(xalign=0, wrap=True, visible=False, css_classes=["dim-label"])
        cbox.append(self.clean_disks)
        cbox.append(self.clean_progress)
        cbox.append(self.clean_list)
        self.stack.add_named(Gtk.ScrolledWindow(child=Adw.Clamp(maximum_size=820, child=cbox),
                                                vexpand=True), "cleaning")

        # bottom bar: selection summary + Clean
        self.bar = Gtk.ActionBar(revealed=False)
        self.summary = Gtk.Label(xalign=0)
        self.bar.pack_start(self.summary)
        self.clean_button = Gtk.Button(label=_("Clear") if self.privacy else _("Clean"))
        self.clean_button.add_css_class("suggested-action")
        self.clean_button.connect("clicked", lambda *_: self.confirm_clean())
        self.bar.pack_end(self.clean_button)
        rescan = named(Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text=_("Scan again")))
        rescan.connect("clicked", lambda *_: self.scan())
        self.bar.pack_end(rescan)
        self.search_toggle = named(Gtk.ToggleButton(icon_name="system-search-symbolic",
                                                    tooltip_text=_("Search results (Ctrl+F)")))
        self.search_toggle.bind_property("active", self.search_bar, "search-mode-enabled",
                                         GObject.BindingFlags.BIDIRECTIONAL)
        self.bar.pack_end(self.search_toggle)
        self.append(self.bar)

        actions = Gio.SimpleActionGroup()  # the menus of the result rows
        never = Gio.SimpleAction(name="never-clean", parameter_type=GLib.VariantType.new("s"))
        never.connect("activate", lambda _a, p: self.never_clean(*p.get_string().split("\t", 1)))
        actions.add_action(never)
        self.insert_action_group("scan", actions)

    # ── Settings › Scan groups ──
    def group_off(self):
        return bool(self.groups) and not any(self.engine.group_on(g) for g in self.groups)

    def groups_changed(self):
        """A group was turned on or off: show the page's start or its "turned off" screen."""
        page = self.stack.get_visible_child_name()
        if self.group_off() and page == "start":
            self.stack.set_visible_child_name("off")
        elif not self.group_off() and page == "off":
            self.stack.set_visible_child_name("start")

    def turn_on(self):
        pending = [g for g in self.groups if not self.engine.group_on(g)]
        result = {}

        def on_event(e):
            if e["event"] in ("task", "error"):
                result.update(e)

        def on_done(ok, status):
            if result.get("state") != "ok":
                self.window.toast(_("Could not change it: {reason}").format(
                    reason=messages.text(result)))
            elif pending:
                return next_group()
            self.window.groups_changed()

        def next_group():
            self.engine.settings_set("group_" + pending.pop(0), "1", on_event, on_done)

        if pending:
            next_group()

    # ── scanning ──
    def reload(self):
        """Ctrl+R: scan again, unless a scan or a clean is running."""
        if not self.running and self.stack.get_visible_child_name() not in ("cleaning", "off"):
            self.scan()

    def find(self):
        """Ctrl+F: search the results."""
        if self.stack.get_visible_child_name() == "results":
            self.search_bar.set_search_mode(True)
            self.search_entry.grab_focus()

    def scan(self, keep_summary=False):
        """Scan again; KEEP_SUMMARY keeps the card of the last clean (the scan right after a clean or an Undo)."""
        if self.running:
            return
        if self.group_off():
            self.stack.set_visible_child_name("off")
            return
        if not keep_summary:
            self.clean_summary = None
        self.items.clear()
        self.scan_info = {}
        self.stopping = False
        self.stop_button.set_sensitive(True)
        self.progress.set_fraction(0)
        self.progress_label.set_text(_("Starting…"))
        self.stack.set_visible_child_name("scanning")
        self.bar.set_revealed(False)
        self.window.set_busy(True)
        failure = Failure("cm --json scan", self.engine.env.get("HOME"))

        def on_event(e):
            failure.see(e)
            if e["event"] == "progress" and not self.stopping:
                self.progress.set_fraction(e["done"] / max(e["total"], 1))
                self.progress_label.set_text(_("Checking {name}…").format(name=e["current"]) if e["current"] else "")
            elif e["event"] == "item":
                self.items[e["id"]] = e
            elif e["event"] == "done":
                self.scan_info = e

        def on_done(ok, status):
            self.running = None
            self.window.set_busy(False)
            self.stopped = self.stopping or bool(self.scan_info.get("stopped"))
            self.stopping = False
            if self.stopped and not any(e["status"] == "found" for e in self.items.values()) \
                    and not self.clean_summary:
                self.window.toast(_("Scan stopped"))
                self.stack.set_visible_child_name("start")
                return
            if failure.failed and not self.scan_info and not self.stopped:  # it never said it was done
                self.items.clear()
                self.failed.show(failure)
                self.stack.set_visible_child_name("failed")
                return
            self.show_results()
            if self.scan_again:
                self.scan_again = False
                self.scan(keep_summary=True)

        self.running = self.engine.scan(None if self.smart else self.categories, on_event, on_done)

    def stop(self):
        """End the scan early: the engine lists the items it got to. One that doesn't end soon is killed."""
        run = self.running
        if not run or self.stopping:
            return
        self.stopping = True
        self.stop_button.set_sensitive(False)
        self.progress_label.set_text(_("Stopping…"))
        run.stop()
        GLib.timeout_add_seconds(5, lambda: (run is self.running and run.cancel(), False)[1])

    # ── results ──
    def show_results(self):
        child = self.results.get_first_child()
        while child:
            self.results.remove(child)
            child = self.results.get_first_child()
        self.checks.clear()
        self.group_buttons.clear()
        self.entries.clear()
        self.entry_selected.clear()
        self.entry_checks.clear()
        self.size_labels.clear()
        self.item_rows.clear()
        self.entry_rows.clear()
        self.group_rows.clear()
        self.gone.clear()
        # an item whose program is running is skipped by the engine, one that needs root can't be cleaned by
        # this copy: never tick them
        self.selected = {i: e["selected"] and not self.held(e) for i, e in self.items.items()
                         if e["status"] == "found"}

        found = [e for e in self.items.values() if e["status"] == "found"]
        # cut off at the scan's time limit: not checked to the end, so never counted as clean
        unfinished = [e for e in self.items.values() if e["status"] == "timeout"]
        total = sum(e["bytes"] for e in found)
        info = self.scan_info
        scanned = ngettext("{n} location scanned in {secs}s", "{n} locations scanned in {secs}s",
                           info.get("locations", 0), secs=f"{info.get('durationMs', info.get('ms', 0)) / 1000:.1f}")
        if self.privacy:
            head = ngettext("{n} history list with entries", "{n} history lists with entries", len(found)) \
                if found else _("Nothing to clear")
            lines = [_("Pick what to clear — nothing happens until you confirm."), scanned]
        elif found:
            head = ngettext("{size} of junk found in {n} item", "{size} of junk found in {n} items", len(found),
                            size=human(total))
            lines = [scanned]
        elif self.stopped:
            head, lines = _("Scan stopped"), [_("Nothing worth removing was found in what was checked."), scanned]
        elif unfinished:
            head, lines = _("The scan didn't finish"), [_("Nothing worth removing was found in what was checked."),
                                                         scanned]
        else:
            head, lines = _("Your system is clean"), [_("Nothing worth removing was found."), scanned]
        header = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        header.append(Gtk.Label(label=head, xalign=0, wrap=True, css_classes=["title-1"]))
        for line in lines:
            header.append(Gtk.Label(label=line, xalign=0, wrap=True, css_classes=["dim-label"]))
        if self.stopped:
            header.append(Gtk.Label(label=_("The scan was stopped: items it hadn't checked yet are not listed."),
                                    xalign=0, wrap=True, css_classes=["warning"]))
        if unfinished:
            header.append(Gtk.Label(label=ngettext(
                "{n} item took too long to check: it may still hold junk. Scan again to check it.",
                "{n} items took too long to check: they may still hold junk. Scan again to check them.",
                len(unfinished)), xalign=0, wrap=True, css_classes=["warning"]))
        self.scan_header = header
        self.results.append(header)
        if self.clean_summary:
            self.results.append(self.summary_card())
        if unfinished:
            self.results.append(self.unfinished_group(unfinished))

        biggest = max([e["bytes"] for e in found] or [1])
        for cat in self.categories:
            items = [e for e in self.items.values() if e["category"] == cat]
            if not items:
                continue
            junk = sorted((e for e in items if e["status"] == "found"), key=lambda e: -e["bytes"])
            clean = [e for e in items if e["status"] not in ("found", "timeout")]
            if not junk and not clean:
                continue  # its only items are in "Not finished"
            group = Adw.PreferencesGroup(title=CATEGORY_TITLES.get(cat, cat))
            if junk and not self.privacy:
                group.set_description(human(sum(e["bytes"] for e in junk)))
            free = [e["id"] for e in junk if not self.held(e)]  # the group box skips locked rows
            if len(free) > 1:
                toggle = Gtk.CheckButton(label=_("All"), valign=Gtk.Align.CENTER, css_classes=["big-check"],
                                         tooltip_text=_("Select or deselect the whole group"))
                toggle.connect("toggled", self.on_group_toggle, free)
                group.set_header_suffix(toggle)
                self.group_buttons.append((toggle, free))
            for e in junk:
                row = self.item_row(e, biggest)
                self.item_rows[e["id"]] = row
                group.add(row)
            more, clean_rows = None, []
            if clean:
                more = plain_row(Adw.ExpanderRow, title=ngettext("{n} more item is clean", "{n} more items are clean", len(clean)))
                more.add_prefix(Gtk.Image(icon_name="emblem-ok-symbolic", css_classes=["success"]))
                for e in clean:
                    row = plain_row(Adw.ActionRow, title=item_text(e["label"]), subtitle=note_text(e["note"]) or _("clean"))
                    row.add_css_class("dim-label")
                    more.add_row(row)
                    clean_rows.append((row, e))
                group.add(more)
            self.group_rows.append((group, [e["id"] for e in junk], more, clean_rows))
            self.results.append(group)
        self.no_match = Adw.StatusPage(icon_name="system-search-symbolic", title=_("No results"),
                                       description=_("Nothing found matches your search."), visible=False)
        self.results.append(self.no_match)

        self.stack.set_visible_child_name("results")
        self.bar.set_revealed(bool(found))
        self.update_summary()
        self.apply_filter()

    def unfinished_group(self, items):
        """The items the scan cut off at its time limit: a warning each and Scan Again, never "clean"."""
        group = Adw.PreferencesGroup(title=_("Not finished"), description=_(
            "These checks took too long and were stopped, so what they hold isn't listed or counted."))
        again = Gtk.Button(label=_("Scan Again"), valign=Gtk.Align.CENTER)
        again.connect("clicked", lambda *_a: self.scan(keep_summary=True))
        group.set_header_suffix(again)
        self.unfinished_button = again
        rows = []
        for e in sorted(items, key=lambda e: item_text(e["label"])):
            secs = e.get("durationMs", 0) / 1000
            row = plain_row(Adw.ActionRow, title=item_text(e["label"]), subtitle=_(
                "Stopped after {secs}s — not checked to the end").format(secs=f"{secs:.0f}") if secs >= 1
                else _("Not checked: the scan ran out of time"))
            row.add_prefix(Gtk.Image(icon_name="dialog-warning-symbolic", css_classes=["warning"]))
            group.add(row)
            rows.append((row, e))
        self.group_rows.append((group, [], None, rows))
        return group

    # ── search: Ctrl+F filters items and their listed parts by name or path ──
    @staticmethod
    def matches(words, *texts):
        hay = " ".join(t for t in texts if t).casefold()
        return all(w in hay for w in words)

    def item_matches(self, words, e):
        return self.matches(words, item_text(e["label"]), e["label"], item_text(e["description"]), e["id"],
                            note_text(e.get("note") or ""))

    def entry_matches(self, words, x):
        return self.matches(words, detail_text(x["label"]), x["label"], x.get("path") or "", unquote(x["id"]))

    def apply_filter(self):
        words = self.search_entry.get_text().casefold().split()
        shown_any = False
        for group, junk, more, clean_rows in self.group_rows:
            shown = 0
            for i in junk:
                row, e = self.item_rows[i], self.items[i]
                own = not words or self.item_matches(words, e)
                parts = self.entry_rows.get(i, {})
                hits = {x["id"] for x in self.entries.get(i, []) if x["id"] in parts
                        and (own or self.entry_matches(words, x))}
                for entry_id, part in parts.items():
                    part.set_visible(entry_id in hits)
                visible = (own or bool(hits)) and i not in self.gone
                row.set_visible(visible)
                if visible and hits and not own:
                    row.set_expanded(True)  # show the parts that matched
                shown += visible
            n = 0
            for row, e in clean_rows:
                on = not words or self.item_matches(words, e)
                row.set_visible(on)
                n += on
            if more:
                more.set_visible(n > 0)
            shown += n
            group.set_visible(shown > 0)
            shown_any = shown_any or shown > 0
        if hasattr(self, "no_match"):
            self.no_match.set_visible(bool(words) and not shown_any)

    def held(self, e):
        """The item can't be ticked: its program is running, or it needs root and this copy of the engine
        can't ask for the password (not installed from a package)."""
        return bool(e.get("locked")) or (e["root"] and not self.engine.can_ask_password())

    def item_row(self, e, biggest):
        locked = e.get("locked") or ""  # the program that has to be closed first
        subtitle = note_text(e["note"])
        held = self.held(e)
        if locked:
            subtitle = _("Close {program} and scan again").format(program=locked)
        elif held:
            subtitle = PACKAGE_NEEDED
        elif e["root"]:
            subtitle = f"{subtitle} · {_('Needs your password')}" if subtitle else _("Needs your password")
        expander = bool(e.get("entries")) and not held and not self.privacy
        row_type = Adw.ExpanderRow if expander else Adw.ActionRow
        row = row_type(title=item_text(e["label"]), subtitle=subtitle, use_markup=False, subtitle_lines=1,
                       tooltip_text=item_text(e["description"]), css_classes=["item-row"])
        check = Gtk.CheckButton(active=self.selected.get(e["id"], False), valign=Gtk.Align.CENTER,
                                css_classes=["big-check"], sensitive=not held)
        check.connect("toggled", self.on_toggled, e["id"])
        self.checks[e["id"]] = check
        row.add_prefix(check)
        suffixes = []
        if locked:
            suffixes.append(Gtk.Image(icon_name="changes-prevent-symbolic", css_classes=["warning"],
                                      tooltip_text=_("{program} is running — close it, then scan again").format(program=locked)))
        elif held:
            suffixes.append(Gtk.Image(icon_name="changes-prevent-symbolic", css_classes=["warning"],
                                      tooltip_text=PACKAGE_HINT))
        elif not expander:
            row.set_activatable_widget(check)
        if e["root"] and not held:
            suffixes.append(Gtk.Image(icon_name="system-lock-screen-symbolic", tooltip_text=_("Needs your password")))
        if not self.privacy:
            bar, size = size_widgets(e["bytes"], biggest)
            self.size_labels[e["id"]] = size
            suffixes += [bar, size]
        if e.get("why"):
            why = named(Gtk.MenuButton(icon_name="help-about-symbolic", valign=Gtk.Align.CENTER,
                                       css_classes=["flat"], tooltip_text=_("Why is this safe?")))
            why.set_create_popup_func(lambda b: b.get_popover() or b.set_popover(self.why_popover(e)))
            suffixes.append(why)
        info = named(Gtk.Button(icon_name="go-next-symbolic", valign=Gtk.Align.CENTER,
                                css_classes=["flat"], tooltip_text=_("Show what's inside")))
        info.connect("clicked", lambda *_: self.show_details(e))
        suffixes.append(info)
        if expander:  # an ExpanderRow stacks its suffixes the other way round
            suffixes.reverse()
            row.connect("notify::expanded", lambda r, _p: r.get_expanded() and self.load_entries(e["id"], r))
        for widget in suffixes:
            row.add_suffix(widget)
        return row

    # ── entries: single parts of an item (Docker images, volumes, build-cache records) ──
    def load_entries(self, item_id, row):
        if item_id in self.entries or getattr(row, "loading", None):
            return
        placeholder = plain_row(Adw.ActionRow, title=_("Loading…"), css_classes=["dim-label"])
        row.loading = placeholder
        row.add_row(placeholder)
        found = []

        def on_event(ev):
            if ev["event"] == "entry" and ev["item"] == item_id:
                found.append(ev)

        def on_done(ok, status):
            row.remove(placeholder)
            row.loading = None
            if item_id not in self.items or self.checks.get(item_id) is None:
                return  # scanned again meanwhile
            self.entries[item_id] = found
            if not found:
                row.add_row(plain_row(Adw.ActionRow, title=_("Nothing to choose one by one — Clean removes it all"),
                                          css_classes=["dim-label"]))
                return
            on = self.selected.get(item_id, False)
            picked = {x["id"] for x in found if x["selected"]} or {x["id"] for x in found}
            self.entry_selected[item_id] = picked if on else set()
            self.entry_checks[item_id] = {}
            self.entry_rows[item_id] = {}
            for x in found:
                part = self.entry_row(item_id, x)
                self.entry_rows[item_id][x["id"]] = part
                row.add_row(part)
            self.sync_item(item_id)
            self.update_summary()
            self.apply_filter()

        self.engine.details(item_id, on_event, on_done)

    def entry_row(self, item_id, x):
        row = plain_row(Adw.ActionRow, title=detail_text(x["label"]), subtitle=entry_note(x.get("note")), title_lines=1,
                            css_classes=["item-row"], tooltip_text=x["id"])
        check = Gtk.CheckButton(active=x["id"] in self.entry_selected[item_id], valign=Gtk.Align.CENTER,
                                css_classes=["big-check"])
        check.connect("toggled", self.on_entry_toggled, item_id, x["id"])
        self.entry_checks[item_id][x["id"]] = check
        row.add_prefix(check)
        row.set_activatable_widget(check)
        row.add_suffix(Gtk.Label(label=human(x["bytes"]), width_chars=9, xalign=1,
                                 css_classes=["numeric", "dim-label"]))
        if x.get("path") and not self.items[item_id]["root"]:  # a folder Settings › Never clean can take
            menu = Gio.Menu()
            never = Gio.MenuItem.new(_("Never Clean This"), None)
            never.set_action_and_target_value("scan.never-clean", GLib.Variant.new_string(f"{item_id}\t{x['id']}"))
            menu.append_item(never)
            row.add_suffix(named(Gtk.MenuButton(icon_name="view-more-symbolic", menu_model=menu,
                                                valign=Gtk.Align.CENTER, css_classes=["flat"],
                                                tooltip_text=_("More"))))
        return row

    # ── Never clean: a listed folder goes to Settings › Never clean; scans skip it from then on ──
    def never_clean(self, item_id, entry_id):
        x = next((x for x in self.entries.get(item_id, []) if x["id"] == entry_id), None)
        if not x or not x.get("path") or self.excluding:
            return
        path, result = x["path"], {}

        def on_event(e):
            if e["event"] in ("task", "error"):
                result.update(e)

        def on_done(ok, status):
            self.excluding = None
            self.window.set_busy(False)
            if result.get("state") != "ok":
                reason = messages.text(result)
                self.window.toast(_("Could not change it: {reason}").format(reason=reason))
            elif self.engine.dry_run:
                self.window.toast(_("Dry run: nothing was saved"))
            else:
                self.drop_entry(item_id, entry_id)
                self.window.toast(_("{folder} is never cleaned now").format(folder=short_path(path)), _("Undo"),
                                  lambda: self.allow_clean(path), timeout=10)

        self.window.set_busy(True)
        self.excluding = self.engine.settings_set("exclusions", ["add", path], on_event, on_done)

    def allow_clean(self, path):
        """Undo of Never clean: the folder can be cleaned again; scan again to list it."""
        def on_done(ok, status):
            self.window.set_busy(False)
            if ok:
                self.window.toast(_("{folder} can be cleaned again").format(folder=short_path(path)))
                if self.stack.get_visible_child_name() == "results":
                    self.scan(keep_summary=True)

        self.window.set_busy(True)
        self.engine.settings_set("exclusions", ["remove", path], lambda e: None, on_done)

    # ── Why is this safe?: what the item is, where, what cleaning does, when it is skipped ──
    def why_popover(self, e):
        why, locked = e["why"], e.get("locked") or ""
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, width_request=360,
                      margin_top=6, margin_bottom=6, margin_start=6, margin_end=6)

        def text(label, *classes):
            box.append(Gtk.Label(label=label, wrap=True, xalign=0, max_width_chars=48, use_markup=False,
                                 css_classes=list(classes)))

        def section(title, lines):
            box.append(Gtk.Label(label=title, xalign=0, margin_top=8, css_classes=["heading"]))
            for line in lines:
                text(f"• {line}")

        text(item_text(e["label"]), "title-4")
        section(_("What it is"), [])
        text(item_text(e["description"]))
        section(_("Where it is"), [])
        for path in why["where"][:4]:
            label = Gtk.Label(label=path, xalign=0, selectable=True, ellipsize=Pango.EllipsizeMode.MIDDLE,
                              max_width_chars=48, css_classes=["monospace", "caption"], tooltip_text=path)
            box.append(label)
        if len(why["where"]) > 4:
            more = len(why["where"]) - 4
            text(ngettext("and {n} more", "and {n} more", more), "dim-label", "caption")
        for note in why["where_note"]:
            text(item_text(note))
        section(_("After cleaning"), [item_text(line) for line in why["after"]])
        skipped = ([why_running(why["running"])] if why["running"] else []) + [item_text(line) for line in why["skipped"]]
        section(_("Skipped when"), skipped or [_("No rule of its own; Settings › Never clean still applies")])
        if locked:
            text(_("Now: {program} is running — close it, then scan again").format(program=locked), "warning")
        elif e["root"] and not self.engine.can_ask_password():
            text(PACKAGE_HINT, "warning")
        folders = why["folders"]
        if folders:
            buttons = Gtk.Box(spacing=6, halign=Gtk.Align.END, margin_top=10)
            show = Gtk.Button(label=_("Open Folder"), tooltip_text=short_path(folders[0]))
            show.connect("clicked", lambda *_a: open_file(self.window, folders[0]))
            buttons.append(show)
            if not e["root"]:
                never = Gtk.Button(label=_("Never Clean"), tooltip_text="\n".join(short_path(f) for f in folders))
                never.connect("clicked", lambda b: (b.get_ancestor(Gtk.Popover).popdown(),
                                                    self.never_clean_item(e["id"], list(folders))))
                buttons.append(never)
            box.append(buttons)
        return Gtk.Popover(child=box)

    def never_clean_item(self, item_id, folders):
        """The item's folders go to Settings › Never clean, one after the other; the item is hidden (the
        next scan leaves it out). Undo takes them out of the list again."""
        if self.excluding:
            return
        todo, added, result = list(folders), [], {}

        def on_event(ev):
            if ev["event"] in ("task", "error"):
                result.update(ev)

        def on_done(ok, status):  # the answer about todo[0]
            if result.get("state") != "ok":
                finish(messages.text(result))
                return
            added.append(todo.pop(0))
            next_folder()

        def next_folder():
            result.clear()
            if not todo:
                finish(None)
                return
            self.excluding = self.engine.settings_set("exclusions", ["add", todo[0]], on_event, on_done)

        def finish(reason):
            self.excluding = None
            self.window.set_busy(False)
            if reason is not None:
                self.window.toast(_("Could not change it: {reason}").format(reason=reason))
                if not added:
                    return
            if self.engine.dry_run:
                self.window.toast(_("Dry run: nothing was saved"))
                return
            self.gone.add(item_id)
            self.selected[item_id] = False
            self.item_rows[item_id].set_visible(False)
            self.update_summary()
            label = item_text(self.items[item_id]["label"])
            self.window.toast(_("{item} is never cleaned now").format(item=label), _("Undo"),
                              lambda: self.allow_clean_all(added), timeout=10)

        self.window.set_busy(True)
        next_folder()

    def allow_clean_all(self, paths):
        """Undo of Never clean on an item: its folders can be cleaned again; scan again to list it."""
        left = list(paths)

        def on_done(ok, status):
            if left and ok:
                self.engine.settings_set("exclusions", ["remove", left.pop(0)], lambda e: None, on_done)
                return
            self.window.set_busy(False)
            if ok:
                self.window.toast(_("It can be cleaned again"))
                if self.stack.get_visible_child_name() == "results":
                    self.scan(keep_summary=True)

        self.window.set_busy(True)
        on_done(True, None)

    def drop_entry(self, item_id, entry_id):
        """Take a part out of the results (it went to Never clean); an item left without parts is hidden."""
        part = self.entry_rows.get(item_id, {}).pop(entry_id, None)
        if part is None:
            return
        self.item_rows[item_id].remove(part)
        self.entry_checks[item_id].pop(entry_id, None)
        self.entry_selected[item_id].discard(entry_id)
        x = next(x for x in self.entries[item_id] if x["id"] == entry_id)
        self.entries[item_id].remove(x)
        self.items[item_id]["bytes"] = max(0, self.items[item_id]["bytes"] - x["bytes"])
        if self.entries[item_id]:
            self.sync_item(item_id)
        else:
            self.gone.add(item_id)
            self.selected[item_id] = False
            self.item_rows[item_id].set_visible(False)
        self.update_summary()

    def on_entry_toggled(self, check, item_id, entry_id):
        if self.entry_syncing:
            return
        chosen = self.entry_selected[item_id]
        if check.get_active():
            chosen.add(entry_id)
        else:
            chosen.discard(entry_id)
        self.sync_item(item_id)
        self.update_summary()

    def sync_item(self, item_id):
        """The item's box follows its entries: none / some (inconsistent) / all; its size shows selected / total."""
        chosen, every = self.entry_selected[item_id], self.entries[item_id]
        self.selected[item_id] = bool(chosen)
        self.entry_syncing = True
        box = self.checks[item_id]
        box.set_active(bool(chosen))
        box.set_inconsistent(0 < len(chosen) < len(every))
        self.entry_syncing = False
        size = self.size_labels.get(item_id)
        if size:
            total = self.items[item_id]["bytes"]
            size.set_text(f"{human(self.chosen_bytes(item_id))} / {human(total)}" if self.partial(item_id)
                          else human(self.chosen_bytes(item_id) if chosen else total))

    def partial(self, item_id):
        """Only some entries of the item are ticked: clean just those."""
        chosen = self.entry_selected.get(item_id)
        return bool(chosen) and len(chosen) < len(self.entries.get(item_id, []))

    def by_entries(self, item_id):
        """Clean the ticked entries one by one instead of the whole item."""
        return self.partial(item_id) or (item_id in BY_ENTRY and bool(self.entry_selected.get(item_id)))

    def chosen_bytes(self, item_id):
        if self.by_entries(item_id):
            return sum(x["bytes"] for x in self.entries[item_id] if x["id"] in self.entry_selected[item_id])
        return self.items[item_id]["bytes"]

    def on_toggled(self, check, item_id):
        if self.entry_syncing:
            return
        self.selected[item_id] = check.get_active()
        self.window.selection.remember(item_id, check.get_active())
        if self.entries.get(item_id):  # its entries follow the item
            self.entry_selected[item_id] = {x["id"] for x in self.entries[item_id]} if check.get_active() else set()
            self.entry_syncing = True
            for box in self.entry_checks[item_id].values():
                box.set_active(check.get_active())
            self.entry_syncing = False
            self.sync_item(item_id)
        self.update_summary()

    def on_group_toggle(self, button, ids):
        if self.syncing:
            return
        target = button.get_active()  # read once: each row change re-syncs the box
        for i in ids:
            self.checks[i].set_active(target)

    def update_summary(self):
        ids = [i for i, on in self.selected.items() if on]
        if self.privacy:
            self.summary.set_text(ngettext("{n} selected", "{n} selected", len(ids)))
        else:
            self.summary.set_markup(ngettext("Selected <b>{size}</b> in {n} item", "Selected <b>{size}</b> in {n} items",
                                             len(ids), size=human(sum(self.chosen_bytes(i) for i in ids))))
        self.clean_button.set_sensitive(bool(ids))
        self.syncing = True  # the group boxes follow the rows: none / some (inconsistent) / all
        for button, group_ids in self.group_buttons:
            n = sum(1 for i in group_ids if self.selected.get(i))
            button.set_inconsistent(0 < n < len(group_ids))
            button.set_active(n == len(group_ids))
        self.syncing = False

    # ── details ──
    def show_details(self, e):
        text = Gtk.TextView(editable=False, cursor_visible=False, monospace=True,
                            top_margin=12, bottom_margin=12, left_margin=12, right_margin=12)
        text.get_buffer().set_text(_("Collecting details…"))
        desc = Gtk.Label(label=item_text(e["description"]), wrap=True, xalign=0,
                         margin_start=12, margin_end=12, margin_top=6, css_classes=["dim-label"])
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.append(desc)
        box.append(Gtk.ScrolledWindow(child=text, vexpand=True))
        toolbar = Adw.ToolbarView(content=box)
        toolbar.add_top_bar(Adw.HeaderBar())
        dialog = Adw.Dialog(title=item_text(e["label"]), child=toolbar, content_width=640, content_height=440)
        dialog.present(self.window)

        lines = []

        def on_event(ev):
            if ev["event"] == "details":
                lines.extend(detail_text(line) for line in ev["lines"])

        def on_done(ok, status):
            text.get_buffer().set_text("\n".join(lines) if lines else _("Nothing more to show."))

        self.engine.details(e["id"], on_event, on_done)

    # ── cleaning ──
    def confirm_clean(self):
        ids = [i for i, on in self.selected.items() if on]
        if not ids:
            return
        total = sum(self.chosen_bytes(i) for i in ids)
        needs_root = any(self.items[i]["root"] for i in ids)
        kind_text = {"trash": _("To the Trash"), "delete": _("Deleted permanently")}
        lines = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.confirm_rows = []  # (item id, kind): what the dialog says happens to each
        for i in ids:
            e, kind = self.items[i], self.clean_kind(i)
            row = Gtk.Box(spacing=12)
            row.append(Gtk.Label(label=item_text(e["label"]), xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.END,
                                 tooltip_text=item_text(e["label"])))
            if e["root"]:
                row.append(Gtk.Image(icon_name="system-lock-screen-symbolic", tooltip_text=_("Needs your password")))
            row.append(Gtk.Label(label=kind_text[kind], css_classes=["caption", "dim-label" if kind == "trash" else "warning"]))
            if not self.privacy:
                row.append(Gtk.Label(label=human(self.chosen_bytes(i)), width_chars=9, xalign=1,
                                     css_classes=["numeric", "dim-label"]))
            lines.append(row)
            self.confirm_rows.append((i, kind))
        rows = Gtk.ScrolledWindow(child=lines, hscrollbar_policy=Gtk.PolicyType.NEVER, propagate_natural_height=True,
                                  max_content_height=300)
        extra = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        extra.append(rows)
        if not self.privacy:  # the totals of each kind
            trash = [i for i, k in self.confirm_rows if k == "trash"]
            gone = [i for i, k in self.confirm_rows if k == "delete"]
            if trash:
                extra.append(Gtk.Label(xalign=0, wrap=True, label=ngettext(
                    "To the Trash: {size} in {n} item", "To the Trash: {size} in {n} items", len(trash),
                    size=human(sum(self.chosen_bytes(i) for i in trash)))))
            if gone:
                extra.append(Gtk.Label(xalign=0, wrap=True, label=ngettext(
                    "Deleted permanently: {size} in {n} item", "Deleted permanently: {size} in {n} items", len(gone),
                    size=human(sum(self.chosen_bytes(i) for i in gone)))))

        if self.privacy:
            heading = ngettext("Clear {n} history list?", "Clear {n} history lists?", len(ids))
            body = _("This can't be undone.")
        else:
            heading = ngettext("Clean {n} item?", "Clean {n} items?", len(ids))
            body = _("About {size} will be removed.").format(size=human(total)) + " " + self.undo_note(ids)
        if needs_root:
            body += " " + _("Items with a lock need your password.")
        dialog = Adw.AlertDialog(heading=heading, body=body, extra_child=extra)
        dialog.add_response("cancel", _("Cancel"))
        dialog.add_response("clean", _("Clear") if self.privacy else _("Clean"))
        dialog.set_response_appearance("clean", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("clean")
        dialog.set_close_response("cancel")
        dialog.connect("response", lambda d, r: r == "clean" and self.clean(ids))
        dialog.present(self.window)
        self.confirm_dialog = dialog

    def clean_kind(self, item_id):
        """Where a clean puts the item: "trash" (Undo can bring it back) or "delete" (gone for good)."""
        return "trash" if self.items[item_id].get("trash") and not self.privacy else "delete"

    def undo_note(self, ids):
        """What the confirmation says about undoing: only items that go to the Trash come back."""
        if any(self.items[i].get("trash") for i in ids):
            return _("Items moved to the Trash can be undone for 10 seconds; the rest is deleted for good.")
        return _("This can't be undone.")

    def clean(self, ids):
        user_ids = [i for i in ids if not self.items[i]["root"]]
        root_ids = [i for i in ids if self.items[i]["root"]]
        self.task_rows = {}
        self.freed = 0  # what the items took, freed or moved to the Trash
        self.to_trash = 0  # the part of it now in the Trash: still on the disk until the Trash is emptied
        self.trashed = {}
        self.disks = {}  # mount point → [free before the first run, free after the last run]
        self.done_count = 0
        self.total_count = len(ids)
        self.task_states = {}  # item id → ok / skip / fail
        child = self.clean_list.get_first_child()
        while child:
            self.clean_list.remove(child)
            child = self.clean_list.get_first_child()
        for i in user_ids + root_ids:
            row = plain_row(Adw.ActionRow, title=item_text(self.items[i]["label"]), subtitle=_("waiting"))
            spinner = Gtk.Image(icon_name="content-loading-symbolic", css_classes=["dim-label"])
            row.add_prefix(spinner)
            row.icon = spinner
            self.clean_list.append(row)
            self.task_rows[i] = row
        self.clean_title.set_text(_("Cleaning…"))
        self.clean_disks.set_visible(False)
        self.clean_progress.set_fraction(0)
        self.stack.set_visible_child_name("cleaning")
        self.bar.set_revealed(False)
        self.window.set_busy(True)

        def settle(item_id, state, text, freed=0, detail=""):
            """An item is done: its row says how (what a tool printed when it failed in the tooltip), and it
            counts in the summary."""
            row = self.task_rows[item_id]
            row.set_tooltip_text(detail or None)
            icon = {"ok": "emblem-ok-symbolic", "skip": "dialog-warning-symbolic"}.get(state, "dialog-error-symbolic")
            row.icon.set_from_icon_name(icon)
            row.icon.set_css_classes([{"ok": "success", "skip": "warning"}.get(state, "error")])
            row.set_subtitle(text or {"ok": _("done"), "skip": _("skipped")}.get(state, _("failed")))
            self.freed += freed
            self.done_count += 1
            self.task_states[item_id] = state
            self.clean_progress.set_fraction(self.done_count / max(self.total_count, 1))

        def on_event(e):
            if e["event"] == "done" and "avail_before" in e:
                for disk in e.get("disks") or [{"mount": "/", "before": e["avail_before"], "after": e["avail_after"]}]:
                    self.disks.setdefault(disk["mount"], [disk["before"], None])[1] = disk["after"]
                self.to_trash += e.get("to_trash", 0)
                for item_id, keys in (e.get("trash") or {}).items():
                    self.trashed.setdefault(item_id, []).extend(keys)
            if e["event"] != "task" or e["id"] not in self.task_rows:
                return
            if e["state"] == "run":
                self.task_rows[e["id"]].set_subtitle(_("working…"))
                return
            settle(e["id"], e["state"], messages.text(e), e["freed"], messages.detail(e))

        def run(run_ids, then, as_root=False, entries=None):
            """One engine run; items it never reported on (it crashed, or pkexec didn't run it) are settled
            from how it ended, so no row stays "waiting"."""
            failure = Failure("cm --json clean", self.engine.env.get("HOME"))

            def events(e):
                failure.see(e)
                on_event(e)

            def ended(ok, status):
                reason = pkexec_reason(status, failure.stderr) if as_root else None
                for i in run_ids:
                    if i in self.task_states:
                        continue
                    if reason:
                        settle(i, "skip", reason)
                    else:
                        settle(i, "fail", last_line(failure.stderr, status, self.engine.env.get("HOME"))
                               if failure.failed else _("The engine didn't say what happened"))
                then()

            self.engine.clean(run_ids, events, ended, as_root=as_root, entries=entries)

        def run_root():
            if not root_ids:
                return finish()
            for i in root_ids:
                self.task_rows[i].set_subtitle(_("waiting for your password…"))
            run(root_ids, finish, as_root=True)

        def finish():
            self.window.set_busy(False)
            freed = max(self.freed - self.to_trash, 0)  # off the disk now; the rest is in the Trash
            if self.engine.dry_run:
                msg = _("Dry run: {size} would be freed").format(size=human(freed))
                if self.to_trash:
                    msg += " · " + _("{size} would go to the Trash").format(size=human(self.to_trash))
            elif self.privacy:
                msg = _("History cleared")
            else:
                msg = _("Freed {size}").format(size=human(freed))
                if self.to_trash:
                    msg += " · " + _("{size} in the Trash (empty the Trash to get it back)").format(
                        size=human(self.to_trash))
            disks = [] if self.privacy or self.engine.dry_run else self.disk_lines()
            self.clean_title.set_text(msg)
            self.clean_disks.set_text("\n".join(disks))
            self.clean_disks.set_visible(bool(disks))
            keys = [k for item_keys in self.trashed.values() for k in item_keys]
            ok = [i for i, state in self.task_states.items() if state == "ok"]
            trash = [i for i in ok if i in self.trashed or (self.engine.dry_run and self.clean_kind(i) == "trash")]
            states = list(self.task_states.values())
            self.clean_summary = {
                "title": msg, "cleaned": len(ok), "trash": len(trash), "deleted": len(ok) - len(trash),
                "skipped": states.count("skip") + len(ids) - len(states),
                "failed": sum(1 for state in states if state not in ("ok", "skip")),
                "to_trash": self.to_trash, "disks": disks, "emptied": None,
                "keys": [] if self.engine.dry_run else keys, "undo_until": time.monotonic() + 10, "restored": None,
            }
            if keys and not self.engine.dry_run:
                self.undo_toast = self.window.toast(msg, _("Undo"), lambda: self.undo(keys), timeout=10)
            else:
                self.window.toast(msg)
            if self.freed or self.privacy:
                self.window.notify_cleaned(msg, self.engine.dry_run)
            self.window.refresh_disk()
            GLib.timeout_add(1200, lambda: (self.scan(keep_summary=True), False)[1])

        # items with only some entries ticked (or a BY_ENTRY item) run one by one with those entries, the rest together
        some = {i: sorted(self.entry_selected[i]) for i in user_ids if self.by_entries(i)}
        whole = [i for i in user_ids if i not in some]
        runs = ([(whole, None)] if whole else []) + [([i], entries) for i, entries in some.items()]

        def run_user():
            if not runs:
                return run_root()
            run_ids, entries = runs.pop(0)
            run(run_ids, run_user, entries=entries)

        run_user()

    def disk_lines(self):
        """Free space before → after the clean, on each filesystem it was measured on (/ and a separate /home)."""
        disks = [(mount, before, after) for mount, (before, after) in self.disks.items() if after is not None]
        if len(disks) == 1:
            return [_("Free space: {before} → {after}").format(before=human(disks[0][1]), after=human(disks[0][2]))]
        return [_("Free space on {disk}: {before} → {after}").format(disk=mount, before=human(before),
                                                                     after=human(after))
                for mount, before, after in sorted(disks, key=lambda d: (d[0] != "/", d[0]))]

    def summary_card(self):
        """What the last clean did; stays on top of the results until the user scans again."""
        s = self.clean_summary
        parts = [ngettext("{n} item cleaned", "{n} items cleaned", s["cleaned"])]
        if s["trash"]:
            parts.append(ngettext("{n} moved to the Trash", "{n} moved to the Trash", s["trash"]))
        if s["deleted"]:
            parts.append(ngettext("{n} deleted permanently", "{n} deleted permanently", s["deleted"]))
        if s["skipped"]:
            parts.append(ngettext("{n} skipped", "{n} skipped", s["skipped"]))
        if s["failed"]:
            parts.append(ngettext("{n} failed", "{n} failed", s["failed"]))
        if s["restored"] is not None:
            parts.append(ngettext("Put back {n} item from the Trash", "Put back {n} items from the Trash",
                                  s["restored"]))
        if s["emptied"] is not None:
            parts.append(_("Trash emptied: {size} freed").format(size=human(s["emptied"])))
        subtitle = "\n".join([" · ".join(parts), *s["disks"]])
        row = plain_row(Adw.ActionRow, title=s["title"], subtitle=subtitle, subtitle_lines=0,
                            css_classes=["clean-summary"])
        row.add_prefix(Gtk.Image(icon_name="emblem-ok-symbolic", css_classes=["success"], valign=Gtk.Align.CENTER))
        self.summary_undo = None
        self.summary_empty = None
        self.summary_trashed = None
        left = s["undo_until"] - time.monotonic()
        if s["keys"] and s["restored"] is None and left > 0:  # Undo, as long as the toast offered it
            undo = Gtk.Button(label=_("Undo"), valign=Gtk.Align.CENTER)
            undo.connect("clicked", lambda *_: self.undo(s["keys"]))
            row.add_suffix(undo)
            self.summary_undo = undo
            GLib.timeout_add(int(left * 1000), lambda: (undo.set_visible(False), False)[1])
        if s["trash"] and not self.engine.dry_run:
            trash = Gtk.Button(label=_("Open Trash"), valign=Gtk.Align.CENTER)
            trash.connect("clicked", lambda *_: Gtk.UriLauncher.new("trash:///").launch(self.window, None, None))
            row.add_suffix(trash)
            moved = Gtk.Button(label=_("View Moved Items"), valign=Gtk.Align.CENTER,
                               tooltip_text=_("Everything CleanMate moved to the Trash, to put back what you need"))
            moved.connect("clicked", lambda *_: self.window.show_trashed())
            row.add_suffix(moved)
            self.summary_trashed = moved
            if s["to_trash"] and s["restored"] is None and s["emptied"] is None:
                empty = Gtk.Button(label=_("Empty Trash…"), valign=Gtk.Align.CENTER,
                                   tooltip_text=_("Delete what is in the Trash for good, to get the space back"))
                empty.connect("clicked", lambda *_: self.confirm_empty_trash())
                row.add_suffix(empty)
                self.summary_empty = empty
        card = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE, css_classes=["boxed-list"])
        card.append(row)
        self.summary_row = row
        return card

    # ── Empty Trash: the space of what a clean moved to the Trash comes back only when the Trash is emptied ──
    def confirm_empty_trash(self):
        moved = (self.clean_summary or {}).get("to_trash", 0)
        body = _("Everything in the Trash is deleted for good: the {size} this cleanup moved there and any files "
                 "you deleted yourself. This can't be undone.").format(size=human(moved))
        dialog = Adw.AlertDialog(heading=_("Empty the Trash?"), body=body)
        dialog.add_response("cancel", _("Cancel"))
        dialog.add_response("empty", _("Empty Trash"))
        dialog.set_response_appearance("empty", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.set_close_response("cancel")
        dialog.connect("response", lambda d, r: r == "empty" and self.empty_trash())
        dialog.present(self.window)
        self.empty_dialog = dialog
        return dialog

    def empty_trash(self):
        if self.restoring or self.running:
            return
        result = {}
        failure = Failure("cm --json clean trash", self.engine.env.get("HOME"))

        def on_event(e):
            failure.see(e)
            if e["event"] == "task" and e["id"] == "trash" and e["state"] != "run":
                result.update(e)

        def on_done(ok, status):
            self.restoring = None
            self.window.set_busy(False)
            if result.get("state") == "ok":
                if self.undo_toast:
                    self.undo_toast.dismiss()
                    self.undo_toast = None
                if self.clean_summary:
                    self.clean_summary["emptied"] = result.get("freed", 0)
                    self.clean_summary["keys"] = []  # gone for good: nothing to put back
                self.window.toast(_("Trash emptied: {size} freed").format(size=human(result.get("freed", 0))))
            else:
                reason = messages.text(result) or (failure.reason() if failure.failed else "")
                self.window.toast(_("Could not empty the Trash: {reason}").format(reason=reason), timeout=8)
            self.window.refresh_disk()
            if self.stack.get_visible_child_name() == "results":
                self.scan(keep_summary=True)

        if self.summary_empty:
            self.summary_empty.set_sensitive(False)
        self.window.set_busy(True)
        self.restoring = self.engine.clean(["trash"], on_event, on_done)

    # ── undo: put back what the last clean moved to the Trash ──
    def undo(self, keys):
        if self.restoring or not keys:
            return
        if self.undo_toast:
            self.undo_toast.dismiss()
        self.undo_toast = None
        if self.summary_undo:
            self.summary_undo.set_visible(False)
        back, failed = [], []

        def on_event(e):
            if e["event"] == "error":
                failed.append(e)
            elif e["event"] == "task":
                (back if e["state"] == "ok" else failed).append(e)

        def on_done(ok, status):
            self.restoring = None
            self.window.set_busy(False)
            if failed:
                self.window.toast(_("Put back {back}, {failed} could not be restored: {reason}").format(
                    back=len(back), failed=len(failed), reason=messages.text(failed[0])))
            else:
                self.window.toast(ngettext("Put back {n} item from the Trash", "Put back {n} items from the Trash",
                                           len(back)))
            if self.clean_summary and self.clean_summary["keys"] == keys:
                self.clean_summary["restored"] = len(back)
            self.window.refresh_disk()
            if self.running:  # a scan is on its way: it may have missed what came back
                self.scan_again = True
            elif self.stack.get_visible_child_name() != "cleaning":  # a clean scans again when it ends
                self.scan(keep_summary=True)

        self.window.set_busy(True)
        self.restoring = self.engine.restore(keys, on_event, on_done)
