"""One scan page: start → scanning → results (checkboxes, sizes) → cleaning."""
from gi.repository import Adw, GLib, Gtk, Pango

from .engine import CATEGORY_TITLES, human
from .i18n import _, item_text, ngettext


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

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True)
        self.append(self.stack)

        # 1. start
        button = Gtk.Button(label=_("Scan"), halign=Gtk.Align.CENTER)
        button.add_css_class("pill")
        button.add_css_class("suggested-action")
        button.connect("clicked", lambda *_: self.scan())
        start = Adw.StatusPage(icon_name=icon, title=title, description=description, child=button)
        self.stack.add_named(start, "start")

        # 2. scanning
        self.progress = Gtk.ProgressBar(show_text=False, width_request=320, halign=Gtk.Align.CENTER)
        self.progress_label = Gtk.Label(css_classes=["dim-label"], ellipsize=Pango.EllipsizeMode.END)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, halign=Gtk.Align.CENTER)
        box.append(self.progress)
        box.append(self.progress_label)
        scanning = Adw.StatusPage(icon_name="system-search-symbolic", title=_("Scanning…"), child=box)
        self.stack.add_named(scanning, "scanning")

        # 3. results (filled in by show_results)
        self.results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24,
                               margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        clamp = Adw.Clamp(maximum_size=820, child=self.results)
        self.stack.add_named(Gtk.ScrolledWindow(child=clamp, vexpand=True,
                                                hscrollbar_policy=Gtk.PolicyType.NEVER), "results")

        # 4. cleaning
        self.clean_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE, css_classes=["boxed-list"])
        self.clean_progress = Gtk.ProgressBar()
        self.clean_title = Gtk.Label(css_classes=["title-2"], xalign=0)
        cbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18,
                       margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        cbox.append(self.clean_title)
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
        rescan = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text=_("Scan again"))
        rescan.connect("clicked", lambda *_: self.scan())
        self.bar.pack_end(rescan)
        self.append(self.bar)

    # ── scanning ──
    def reload(self):
        """Ctrl+R: scan again, unless a scan or a clean is running."""
        if not self.running and self.stack.get_visible_child_name() != "cleaning":
            self.scan()

    def scan(self):
        if self.running:
            return
        self.items.clear()
        self.progress.set_fraction(0)
        self.progress_label.set_text(_("Starting…"))
        self.stack.set_visible_child_name("scanning")
        self.bar.set_revealed(False)
        self.window.set_busy(True)

        def on_event(e):
            if e["event"] == "progress":
                self.progress.set_fraction(e["done"] / max(e["total"], 1))
                self.progress_label.set_text(_("Checking {name}…").format(name=e["current"]) if e["current"] else "")
            elif e["event"] == "item":
                self.items[e["id"]] = e
            elif e["event"] == "done":
                self.scan_info = e

        def on_done(ok, status):
            self.running = None
            self.window.set_busy(False)
            if not ok and not self.items:
                self.window.toast(_("The scan failed — try the terminal app (cm) for details."))
                self.stack.set_visible_child_name("start")
                return
            self.show_results()
            if self.scan_again:
                self.scan_again = False
                self.scan()

        self.running = self.engine.scan(self.categories, on_event, on_done)

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
        # an item whose program is running is skipped by the engine: never tick it
        self.selected = {i: e["selected"] and not e.get("locked") for i, e in self.items.items()
                         if e["status"] == "found"}

        found = [e for e in self.items.values() if e["status"] == "found"]
        total = sum(e["bytes"] for e in found)
        if self.privacy:
            head = ngettext("{n} history list with entries", "{n} history lists with entries", len(found)) \
                if found else _("Nothing to clear")
            sub = _("Pick what to clear — nothing happens until you confirm.")
        elif found:
            info = getattr(self, "scan_info", {})
            head = ngettext("{size} of junk found in {n} item", "{size} of junk found in {n} items", len(found),
                            size=human(total))
            sub = ngettext("{n} location scanned in {secs}s", "{n} locations scanned in {secs}s",
                           info.get("locations", 0), secs=f"{info.get('ms', 0) / 1000:.1f}")
        else:
            head, sub = _("Your system is clean"), _("Nothing worth removing was found.")
        title = Gtk.Label(label=head, xalign=0, wrap=True, css_classes=["title-1"])
        subtitle = Gtk.Label(label=sub, xalign=0, css_classes=["dim-label"])
        header = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        header.append(title)
        header.append(subtitle)
        self.results.append(header)

        biggest = max([e["bytes"] for e in found] or [1])
        for cat in self.categories:
            items = [e for e in self.items.values() if e["category"] == cat]
            if not items:
                continue
            junk = sorted((e for e in items if e["status"] == "found"), key=lambda e: -e["bytes"])
            clean = [e for e in items if e["status"] != "found"]
            group = Adw.PreferencesGroup(title=CATEGORY_TITLES.get(cat, cat))
            if junk and not self.privacy:
                group.set_description(human(sum(e["bytes"] for e in junk)))
            free = [e["id"] for e in junk if not e.get("locked")]  # the group box skips locked rows
            if len(free) > 1:
                toggle = Gtk.CheckButton(label=_("All"), valign=Gtk.Align.CENTER, css_classes=["big-check"],
                                         tooltip_text=_("Select or deselect the whole group"))
                toggle.connect("toggled", self.on_group_toggle, free)
                group.set_header_suffix(toggle)
                self.group_buttons.append((toggle, free))
            for e in junk:
                group.add(self.item_row(e, biggest))
            if clean:
                more = Adw.ExpanderRow(title=ngettext("{n} more item is clean", "{n} more items are clean", len(clean)),
                                       use_markup=False)
                more.add_prefix(Gtk.Image(icon_name="emblem-ok-symbolic", css_classes=["success"]))
                for e in clean:
                    row = Adw.ActionRow(title=item_text(e["label"]), subtitle=item_text(e["note"]) or _("clean"),
                                         use_markup=False)
                    row.add_css_class("dim-label")
                    more.add_row(row)
                group.add(more)
            self.results.append(group)

        self.stack.set_visible_child_name("results")
        self.bar.set_revealed(bool(found))
        self.update_summary()

    def item_row(self, e, biggest):
        locked = e.get("locked") or ""  # the program that has to be closed first
        subtitle = item_text(e["note"])
        if locked:
            subtitle = _("Close {program} and scan again").format(program=locked)
        elif e["root"]:
            subtitle = f"{subtitle} · {_('Needs your password')}" if subtitle else _("Needs your password")
        expander = bool(e.get("entries")) and not locked and not self.privacy
        row_type = Adw.ExpanderRow if expander else Adw.ActionRow
        row = row_type(title=item_text(e["label"]), subtitle=subtitle, use_markup=False, subtitle_lines=1,
                       tooltip_text=item_text(e["description"]), css_classes=["item-row"])
        check = Gtk.CheckButton(active=self.selected.get(e["id"], False), valign=Gtk.Align.CENTER,
                                css_classes=["big-check"], sensitive=not locked)
        check.connect("toggled", self.on_toggled, e["id"])
        self.checks[e["id"]] = check
        row.add_prefix(check)
        suffixes = []
        if locked:
            suffixes.append(Gtk.Image(icon_name="changes-prevent-symbolic", css_classes=["warning"],
                                      tooltip_text=_("{program} is running — close it, then scan again").format(program=locked)))
        elif not expander:
            row.set_activatable_widget(check)
        if e["root"] and not locked:
            suffixes.append(Gtk.Image(icon_name="system-lock-screen-symbolic", tooltip_text=_("Needs your password")))
        if not self.privacy:
            bar, size = size_widgets(e["bytes"], biggest)
            self.size_labels[e["id"]] = size
            suffixes += [bar, size]
        info = Gtk.Button(icon_name="go-next-symbolic", valign=Gtk.Align.CENTER,
                          css_classes=["flat"], tooltip_text=_("Show what's inside"))
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
        placeholder = Adw.ActionRow(title=_("Loading…"), css_classes=["dim-label"])
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
                row.add_row(Adw.ActionRow(title=_("Nothing to choose one by one — Clean removes it all"),
                                          css_classes=["dim-label"]))
                return
            on = self.selected.get(item_id, False)
            picked = {x["id"] for x in found if x["selected"]} or {x["id"] for x in found}
            self.entry_selected[item_id] = picked if on else set()
            self.entry_checks[item_id] = {}
            for x in found:
                row.add_row(self.entry_row(item_id, x))
            self.sync_item(item_id)
            self.update_summary()

        self.engine.details(item_id, on_event, on_done)

    def entry_row(self, item_id, x):
        row = Adw.ActionRow(title=x["label"], subtitle=entry_note(x.get("note")), use_markup=False, title_lines=1,
                            css_classes=["item-row"], tooltip_text=x["id"])
        check = Gtk.CheckButton(active=x["id"] in self.entry_selected[item_id], valign=Gtk.Align.CENTER,
                                css_classes=["big-check"])
        check.connect("toggled", self.on_entry_toggled, item_id, x["id"])
        self.entry_checks[item_id][x["id"]] = check
        row.add_prefix(check)
        row.set_activatable_widget(check)
        row.add_suffix(Gtk.Label(label=human(x["bytes"]), width_chars=9, xalign=1,
                                 css_classes=["numeric", "dim-label"]))
        return row

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
                lines.extend(ev["lines"])

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
        lines = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        for i in ids[:12]:
            e = self.items[i]
            row = Gtk.Box(spacing=12)
            row.append(Gtk.Label(label=item_text(e["label"]), xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.END))
            if e["root"]:
                row.append(Gtk.Image(icon_name="system-lock-screen-symbolic"))
            if not self.privacy:
                row.append(Gtk.Label(label=human(self.chosen_bytes(i)), css_classes=["numeric", "dim-label"]))
            lines.append(row)
        if len(ids) > 12:
            lines.append(Gtk.Label(label=_("… and {n} more").format(n=len(ids) - 12), xalign=0, css_classes=["dim-label"]))

        if self.privacy:
            heading = ngettext("Clear {n} history list?", "Clear {n} history lists?", len(ids))
            body = _("This can't be undone.")
        else:
            heading = ngettext("Clean {n} item?", "Clean {n} items?", len(ids))
            body = _("About {size} will be removed.").format(size=human(total)) + " " + self.undo_note(ids)
        if needs_root:
            body += " " + _("Items with a lock need your password.")
        dialog = Adw.AlertDialog(heading=heading, body=body, extra_child=lines)
        dialog.add_response("cancel", _("Cancel"))
        dialog.add_response("clean", _("Clear") if self.privacy else _("Clean"))
        dialog.set_response_appearance("clean", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("clean")
        dialog.set_close_response("cancel")
        dialog.connect("response", lambda d, r: r == "clean" and self.clean(ids))
        dialog.present(self.window)

    def undo_note(self, ids):
        """What the confirmation says about undoing: only items that go to the Trash come back."""
        if any(self.items[i].get("trash") for i in ids):
            return _("Items moved to the Trash can be undone for 10 seconds; the rest is deleted for good.")
        return _("This can't be undone.")

    def clean(self, ids):
        user_ids = [i for i in ids if not self.items[i]["root"]]
        root_ids = [i for i in ids if self.items[i]["root"]]
        self.task_rows = {}
        self.freed = 0
        self.trashed = {}
        self.avail = [None, None]  # free space before the first and after the last run
        self.done_count = 0
        self.total_count = len(ids)
        child = self.clean_list.get_first_child()
        while child:
            self.clean_list.remove(child)
            child = self.clean_list.get_first_child()
        for i in user_ids + root_ids:
            row = Adw.ActionRow(title=item_text(self.items[i]["label"]), subtitle=_("waiting"), use_markup=False)
            spinner = Gtk.Image(icon_name="content-loading-symbolic", css_classes=["dim-label"])
            row.add_prefix(spinner)
            row.icon = spinner
            self.clean_list.append(row)
            self.task_rows[i] = row
        self.clean_title.set_text(_("Cleaning…"))
        self.clean_progress.set_fraction(0)
        self.stack.set_visible_child_name("cleaning")
        self.bar.set_revealed(False)
        self.window.set_busy(True)

        def on_event(e):
            if e["event"] == "done" and "avail_before" in e:
                if self.avail[0] is None:
                    self.avail[0] = e["avail_before"]
                self.avail[1] = e["avail_after"]
                for item_id, keys in (e.get("trash") or {}).items():
                    self.trashed.setdefault(item_id, []).extend(keys)
            if e["event"] != "task" or e["id"] not in self.task_rows:
                return
            row = self.task_rows[e["id"]]
            if e["state"] == "run":
                row.set_subtitle(_("working…"))
                return
            icon = {"ok": "emblem-ok-symbolic", "skip": "dialog-warning-symbolic"}.get(e["state"], "dialog-error-symbolic")
            row.icon.set_from_icon_name(icon)
            row.icon.set_css_classes([{"ok": "success", "skip": "warning"}.get(e["state"], "error")])
            row.set_subtitle(e["info"] or {"ok": _("done"), "skip": _("skipped")}.get(e["state"], _("failed")))
            self.freed += e["freed"]
            self.done_count += 1
            self.clean_progress.set_fraction(self.done_count / max(self.total_count, 1))

        def run_root():
            if not root_ids:
                return finish()
            for i in root_ids:
                self.task_rows[i].set_subtitle(_("waiting for your password…"))
            self.engine.clean(root_ids, on_event, root_done, as_root=True)

        def root_done(ok, status):
            if status in (126, 127):  # password dialog dismissed / not authorized
                for i in root_ids:
                    row = self.task_rows[i]
                    if row.get_subtitle() in (_("waiting"), _("waiting for your password…")):
                        row.icon.set_from_icon_name("dialog-warning-symbolic")
                        row.icon.set_css_classes(["warning"])
                        row.set_subtitle(_("Skipped — no password was entered"))
            finish()

        def finish():
            self.window.set_busy(False)
            if self.engine.dry_run:
                msg = _("Dry run: {size} would be freed").format(size=human(self.freed))
            elif self.privacy:
                msg = _("History cleared")
            else:
                msg = _("Freed {size}").format(size=human(self.freed))
                if None not in self.avail:
                    msg += " · " + _("Free space: {before} → {after}").format(
                        before=human(self.avail[0]), after=human(self.avail[1]))
            self.clean_title.set_text(msg)
            keys = [k for item_keys in self.trashed.values() for k in item_keys]
            if keys and not self.engine.dry_run:
                text = ngettext("Freed {size} · {n} item moved to the Trash",
                                "Freed {size} · {n} items moved to the Trash", len(keys), size=human(self.freed))
                self.undo_toast = self.window.toast(text, _("Undo"), lambda: self.undo(keys), timeout=10)
            else:
                self.window.toast(msg)
            self.window.refresh_disk()
            GLib.timeout_add(1200, lambda: (self.scan(), False)[1])

        # items with only some entries ticked (or a BY_ENTRY item) run one by one with those entries, the rest together
        some = {i: sorted(self.entry_selected[i]) for i in user_ids if self.by_entries(i)}
        whole = [i for i in user_ids if i not in some]
        runs = ([(whole, None)] if whole else []) + [([i], entries) for i, entries in some.items()]

        def run_user():
            if not runs:
                return run_root()
            run_ids, entries = runs.pop(0)
            self.engine.clean(run_ids, on_event, lambda ok, st: run_user(), entries=entries)

        run_user()

    # ── undo: put back what the last clean moved to the Trash ──
    def undo(self, keys):
        if self.restoring or not keys:
            return
        self.undo_toast = None
        back, failed = [], []

        def on_event(e):
            if e["event"] == "error":
                failed.append({"info": e["message"]})
            elif e["event"] == "task":
                (back if e["state"] == "ok" else failed).append(e)

        def on_done(ok, status):
            self.restoring = None
            self.window.set_busy(False)
            if failed:
                self.window.toast(_("Put back {back}, {failed} could not be restored: {reason}").format(
                    back=len(back), failed=len(failed), reason=failed[0]["info"]))
            else:
                self.window.toast(ngettext("Put back {n} item from the Trash", "Put back {n} items from the Trash",
                                           len(back)))
            self.window.refresh_disk()
            if self.running:  # a scan is on its way: it may have missed what came back
                self.scan_again = True
            elif self.stack.get_visible_child_name() != "cleaning":  # a clean scans again when it ends
                self.scan()

        self.window.set_busy(True)
        self.restoring = self.engine.restore(keys, on_event, on_done)
