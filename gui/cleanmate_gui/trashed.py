"""Moved to the Trash: what CleanMate moved to the Trash, also in earlier sessions, and putting it back.

The engine keeps the record (`--json restore --list`) and puts items back (`--json restore`); this page
only lists them, filters them and passes the keys on. Items that have left the Trash since (emptied, or
deleted in Files) stay listed for a while, greyed out, so you know why they can't come back.
"""
import os
import time

from gi.repository import Adw, Gtk, Pango

from .a11y import named
from . import preview
from .engine import human
from .errorview import ErrorPage, Failure
from .i18n import _, item_text, ngettext
from .largefiles import short_path
from .scanpage import size_widgets
from . import messages

LIMIT = 500  # as many as the engine's record keeps of what is still in the Trash
GONE_DAYS = 30  # how long an item that left the Trash stays listed
SMART_SCAN = "Smart Scan"
# where an item was moved from: the engine's English name (the part before " › ") → shown name, in this order
SOURCES = {
    SMART_SCAN: _("Smart Scan"),
    "Large & Old Files": _("Large & Old Files"),
    "Duplicates": _("Duplicates"),
    "Similar Photos": _("Similar Photos"),
    "Space Lens": _("Space Lens"),
    "Uninstaller": _("Uninstaller"),
    "Startup Items": _("Startup Items"),
    "Command Line": _("Command Line"),
}


def source_group(source):
    """'Smart Scan › Old downloads' → 'Smart Scan': the source filter's value."""
    return (source or "CleanMate").split(" › ")[0]


def source_text(source):
    """The source in the app's language, with the Smart Scan item's name."""
    group, _sep, item = (source or "CleanMate").partition(" › ")
    name = SOURCES.get(group, group)
    return f"{name} › {item_text(item)}" if item else name


def item_date(text):
    """'2026-11-02T14:15:00+07:00' → '2 Nov 2026, 14:15' (local time, as the engine wrote it)."""
    try:
        return time.strftime("%-d %b %Y, %H:%M", time.strptime(text[:19], "%Y-%m-%dT%H:%M:%S"))
    except (TypeError, ValueError):
        return text or ""


class TrashedPage(Gtk.Box):
    """Search and a source filter on top, the items newest first below; Put Back one, the ticked ones or all."""

    def __init__(self, window, title, icon, description):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self.engine = window.engine
        self.items = []  # the engine's items, newest first
        self.rows = {}  # key → Adw.ActionRow
        self.checks = {}  # key → Gtk.CheckButton (only items still in the Trash)
        self.selected = set()  # keys
        self.sources = []  # source filter values: None (all), then the groups listed
        self.all_check = None
        self.syncing = False
        self.running = None  # Gio.Cancellable of the current engine run
        self.generation = 0  # a newer listing makes an older one's results stale
        self.loaded = False
        self.restore_dialog = None

        self.search_entry = Gtk.SearchEntry(placeholder_text=_("Search by name or folder"), hexpand=True)
        self.search_entry.connect("search-changed", lambda *_a: self.apply_filter())
        self.source_drop = Gtk.DropDown.new_from_strings([_("All sources")])
        self.source_drop.set_tooltip_text(_("Show only what was moved from here"))
        self.source_drop.connect("notify::selected", lambda *_a: self.apply_filter())
        filters = Gtk.Box(spacing=12, margin_top=12, margin_bottom=12, margin_start=12, margin_end=12)
        filters.append(self.search_entry)
        filters.append(self.source_drop)
        self.filters = filters
        self.append(filters)
        self.append(Gtk.Separator())

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True)
        self.append(self.stack)
        spinner = Gtk.Spinner(spinning=True, width_request=32, height_request=32, halign=Gtk.Align.CENTER)
        self.stack.add_named(Adw.StatusPage(icon_name=icon, title=title, description=description, child=spinner),
                             "loading")
        self.empty = Adw.StatusPage(
            icon_name=icon, title=_("Nothing to put back"),
            description=_("Files and folders CleanMate moves to the Trash are listed here, so you can put them "
                          "back where they were — also after you close the app."))
        self.stack.add_named(self.empty, "empty")
        self.failed = ErrorPage(window, lambda: self.load(), title=_("Can't read what was moved to the Trash"))
        self.stack.add_named(self.failed, "failed")
        self.results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24,
                               margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        self.stack.add_named(Gtk.ScrolledWindow(child=Adw.Clamp(maximum_size=900, child=self.results),
                                                vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER), "results")

        self.bar = Gtk.ActionBar(revealed=False)
        self.summary = Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.END)
        self.bar.pack_start(self.summary)
        self.restore_button = Gtk.Button(label=_("Put Back"), css_classes=["suggested-action"],
                                         tooltip_text=_("Put the ticked items back where they were"))
        self.restore_button.connect("clicked", lambda *_a: self.put_back([k for k in self.chosen()]))
        self.bar.pack_end(self.restore_button)
        self.all_button = Gtk.Button(label=_("Put Back All…"),
                                     tooltip_text=_("Put back every item listed that is still in the Trash"))
        self.all_button.connect("clicked", lambda *_a: self.confirm_put_back_all())
        self.bar.pack_end(self.all_button)
        again = named(Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text=_("List again")))
        again.connect("clicked", lambda *_a: self.reload())
        self.bar.pack_end(again)
        self.append(self.bar)

        # read again each time the page is shown: a clean or Files may have changed the Trash meanwhile
        self.connect("map", lambda *_a: self.reload())

    # ── listing ──
    def reload(self):
        """Ctrl+R (and showing the page): list again, unless a run is going."""
        if not self.running:
            self.load()

    def find(self):
        """Ctrl+F: the search box."""
        self.search_entry.grab_focus()

    def load(self):
        if self.running:
            return
        self.generation += 1
        gen = self.generation
        answer = {}
        failure = Failure("cm --json restore --list", self.engine.env.get("HOME"))
        if not self.loaded:
            self.stack.set_visible_child_name("loading")
        self.window.set_busy(True)

        def on_event(e):
            failure.see(e)
            if "items" in e:
                answer.update(e)

        def on_done(ok, status):
            self.running = None
            self.window.set_busy(False)
            if gen != self.generation:
                return
            if "items" not in answer:  # no answer: say why, never "nothing to put back"
                self.items, self.loaded = [], False
                if not failure.failed:
                    failure.status = status
                self.failed.show(failure)
                self.stack.set_visible_child_name("failed")
                self.bar.set_revealed(False)
                return
            self.loaded = True
            self.items = [i for i in answer["items"] if i.get("trashed")]
            self.show_results()

        self.running = self.engine.run(["restore", "--list", "--limit", str(LIMIT), "--gone", str(GONE_DAYS)],
                                       on_event, on_done)

    def show_results(self):
        child = self.results.get_first_child()
        while child:
            self.results.remove(child)
            child = self.results.get_first_child()
        self.rows.clear()
        self.checks.clear()
        self.all_check = None
        keys = {i["trashed"] for i in self.items if i.get("inTrash")}
        self.selected &= keys
        if not self.items:
            self.stack.set_visible_child_name("empty")
            self.bar.set_revealed(False)
            return
        self.update_sources()

        self.title = Gtk.Label(xalign=0, wrap=True, css_classes=["title-1"])
        self.subtitle = Gtk.Label(xalign=0, wrap=True, css_classes=["dim-label"])
        header = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        header.append(self.title)
        header.append(self.subtitle)
        self.results.append(header)

        self.group = Adw.PreferencesGroup()
        if len(keys) > 1:
            self.all_check = Gtk.CheckButton(label=_("All"), valign=Gtk.Align.CENTER, css_classes=["big-check"],
                                             tooltip_text=_("Select or deselect every item listed"))
            self.all_check.connect("toggled", self.on_all_toggled)
            self.group.set_header_suffix(self.all_check)
        biggest = max([i["size"] or 0 for i in self.items] + [1])
        for i in self.items:
            row = self.item_row(i, biggest)
            self.rows[i["trashed"]] = row
            self.group.add(row)
        self.results.append(self.group)
        self.no_match = Adw.StatusPage(icon_name="edit-find-symbolic", title=_("No results"),
                                       description=_("Try other words or another source."),
                                       css_classes=["compact"], visible=False)
        self.results.append(self.no_match)
        self.stack.set_visible_child_name("results")
        self.bar.set_revealed(True)
        self.apply_filter()

    def update_sources(self):
        """The source filter lists the sources present, keeping the one chosen."""
        chosen = self.sources[self.source_drop.get_selected()] if self.sources else None
        present = {source_group(i.get("source")) for i in self.items}
        groups = [g for g in SOURCES if g in present] + sorted(present - set(SOURCES))
        self.sources = [None, *groups]
        self.source_drop.set_model(Gtk.StringList.new([_("All sources"), *(SOURCES.get(g, g) for g in groups)]))
        self.source_drop.set_selected(self.sources.index(chosen) if chosen in self.sources else 0)

    def item_row(self, i, biggest):
        key, path, in_trash = i["trashed"], i["path"], bool(i.get("inTrash"))
        folder, name = os.path.split(path.rstrip("/"))
        facts = [short_path(folder) or "/", source_text(i.get("source")), item_date(i.get("date"))]
        if not in_trash:
            facts.insert(0, _("No longer in the Trash"))
        row = Adw.ActionRow(title=name or path, subtitle=" · ".join(facts), use_markup=False, subtitle_lines=1,
                            css_classes=["item-row"], tooltip_text=path)
        icon = "folder-symbolic" if i.get("kind") == "folder" else "text-x-generic-symbolic"
        if not in_trash:  # can't come back: greyed out, no box and no buttons
            row.add_prefix(Gtk.Image(icon_name="action-unavailable-symbolic", valign=Gtk.Align.CENTER))
            row.add_css_class("dim-label")
            row.set_tooltip_text(path + "\n" + _("Emptied or deleted from the Trash: it can't be put back"))
            row.gone = True
            return row
        row.gone = False
        check = Gtk.CheckButton(active=key in self.selected, valign=Gtk.Align.CENTER, css_classes=["big-check"])
        check.connect("toggled", self.on_toggled, key)
        self.checks[key] = check
        row.add_prefix(Gtk.Image(icon_name=icon, valign=Gtk.Align.CENTER))
        row.add_prefix(check)  # prefixes stack leftwards: the box comes first
        row.set_activatable_widget(check)
        for widget in size_widgets(i["size"] or 0, biggest):
            row.add_suffix(widget)
        back = named(Gtk.Button(icon_name="edit-undo-symbolic", valign=Gtk.Align.CENTER, css_classes=["flat"],
                                tooltip_text=_("Put Back")))
        back.connect("clicked", lambda *_a: self.put_back([key]))
        row.add_suffix(back)
        if i.get("location"):
            show = named(Gtk.Button(icon_name="folder-open-symbolic", valign=Gtk.Align.CENTER, css_classes=["flat"],
                                    tooltip_text=_("Show in Files")))
            show.connect("clicked", lambda *_a: preview.show_in_files(self.window, i["location"]))
            row.add_suffix(show)
        return row

    # ── search and source filter ──
    def shown(self):
        """The items the search and the source filter let through, newest first."""
        words = self.search_entry.get_text().casefold().split()
        source = self.sources[self.source_drop.get_selected()] if self.sources else None
        out = []
        for i in self.items:
            if source and source_group(i.get("source")) != source:
                continue
            hay = " ".join((i["path"], short_path(i["path"]), i.get("source") or "",
                            source_text(i.get("source")))).casefold()
            if all(w in hay for w in words):
                out.append(i)
        return out

    def apply_filter(self):
        if not self.rows:
            return
        shown = self.shown()
        keys = {i["trashed"] for i in shown}
        for key, row in self.rows.items():
            row.set_visible(key in keys)
        self.group.set_visible(bool(shown))
        self.no_match.set_visible(not shown)
        live = [i for i in shown if i.get("inTrash")]
        size = human(sum(i["size"] or 0 for i in live))
        self.title.set_label(ngettext("{n} item in the Trash · {size}", "{n} items in the Trash · {size}",
                                      len(live), size=size))
        gone = len(shown) - len(live)
        sub = _("Newest first. Put an item back and it returns to the folder it came from.")
        if gone:
            sub += " " + ngettext("{n} more has left the Trash since and can't be put back.",
                                  "{n} more have left the Trash since and can't be put back.", gone)
        self.subtitle.set_label(sub)
        self.update_summary()

    # ── selection ──
    def chosen(self):
        """The ticked items that are listed: an item the filter hides is never put back."""
        return [i["trashed"] for i in self.shown() if i.get("inTrash") and i["trashed"] in self.selected]

    def on_toggled(self, check, key):
        if check.get_active():
            self.selected.add(key)
        else:
            self.selected.discard(key)
        self.update_summary()

    def on_all_toggled(self, button):
        if self.syncing:
            return
        target = button.get_active()
        shown = {i["trashed"] for i in self.shown()}
        for key, check in self.checks.items():
            if key in shown:
                check.set_active(target)

    def update_summary(self):
        chosen = self.chosen()
        sizes = {i["trashed"]: i["size"] or 0 for i in self.items}
        live = [i for i in self.shown() if i.get("inTrash")]
        self.summary.set_markup(ngettext("Selected <b>{size}</b> in {n} item", "Selected <b>{size}</b> in {n} items",
                                         len(chosen), size=human(sum(sizes[k] for k in chosen))))
        self.restore_button.set_sensitive(bool(chosen) and not self.running)
        self.all_button.set_sensitive(bool(live) and not self.running)
        if self.all_check:
            self.syncing = True  # none / some (inconsistent) / all of the listed ones
            self.all_check.set_inconsistent(0 < len(chosen) < len(live))
            self.all_check.set_active(bool(live) and len(chosen) == len(live))
            self.all_check.set_sensitive(bool(live))
            self.syncing = False

    # ── putting back ──
    def confirm_put_back_all(self):
        keys = [i["trashed"] for i in self.shown() if i.get("inTrash")]
        if not keys or self.running:
            return None
        size = human(sum(i["size"] or 0 for i in self.shown() if i.get("inTrash")))
        dialog = Adw.AlertDialog(
            heading=ngettext("Put back {n} item?", "Put back all {n} items?", len(keys)),
            body=_("{size}. Each goes back to the folder it came from. An item whose place is taken by another "
                   "file stays in the Trash.").format(size=size))
        dialog.add_response("cancel", _("Cancel"))
        dialog.add_response("restore", _("Put Back"))
        dialog.set_response_appearance("restore", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("restore")
        dialog.set_close_response("cancel")
        dialog.connect("response", lambda d, r: r == "restore" and self.put_back(keys))
        dialog.present(self.window)
        self.restore_dialog = dialog
        return dialog

    def put_back(self, keys):
        if self.running or not keys:
            return
        back, gone, failed = set(), set(), []
        gen = self.generation

        def on_event(e):
            if e.get("event") == "error":
                failed.append(messages.text(e))
            if e.get("event") != "task":
                return
            if e["state"] == "ok":
                back.add(e.get("trash"))
            elif e.get("code") == "not_in_trash":
                gone.add(e.get("trash"))
            else:
                failed.append(messages.text(e))

        def on_done(ok, status):
            self.running = None
            self.window.set_busy(False)
            if self.engine.dry_run:
                self.window.toast(ngettext("Dry run: {n} item would be put back",
                                           "Dry run: {n} items would be put back", len(back)))
                self.update_summary()
                return
            if gen == self.generation:  # the same list is shown: drop what is back, grey out what left
                for i in self.items:
                    if i["trashed"] in gone:
                        i.update(inTrash=False, size=None, location=None)
                self.items = [i for i in self.items if i["trashed"] not in back]
                self.selected -= back | gone
                self.show_results()
            parts = []
            if back:
                parts.append(ngettext("Put back {n} item", "Put back {n} items", len(back)))
            if gone:
                parts.append(ngettext("{n} is no longer in the Trash", "{n} are no longer in the Trash", len(gone)))
            if failed:
                parts.append(ngettext("{n} could not be put back: {reason}", "{n} could not be put back: {reason}",
                                      len(failed), reason=failed[0]))
            self.window.toast(" — ".join(parts) or _("Nothing was put back"), timeout=6 if failed or gone else 4)
            if back:
                self.window.refresh_disk()

        self.window.set_busy(True)
        self.restore_button.set_sensitive(False)
        self.all_button.set_sensitive(False)
        self.running = self.engine.restore(list(keys), on_event, on_done)
