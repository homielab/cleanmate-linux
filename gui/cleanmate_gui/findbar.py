"""What every list page shares: the Ctrl+F search bar, and Never clean for a folder from a file's row.

FindBar filters what a page lists by words (all of them, in any order, any case). A page hides the rows that
don't match, and a ticked row it hides is never moved. Never clean saves a folder in Settings › Never clean
through the engine (`settings-set exclusions add`), which only takes a folder inside your home folder; a toast
offers Undo.
"""
import os

from gi.repository import Adw, Gio, GLib, GObject, Gtk

from .a11y import named
from .i18n import _
from . import messages


def matches(words, *texts):
    """True when every word is in one of TEXTS (words already casefolded)."""
    hay = " ".join(t for t in texts if t).casefold()
    return all(w in hay for w in words)


class FindBar(Gtk.SearchBar):
    """A search entry that slides in under the page's header; CHANGED() runs on each edit. Closing it
    (Escape) clears the words, so everything shows again."""

    def __init__(self, changed, placeholder=None, width=900):
        self.entry = Gtk.SearchEntry(placeholder_text=placeholder or _("Search results"), hexpand=True)
        super().__init__(child=Adw.Clamp(maximum_size=width, child=self.entry))
        self.connect_entry(self.entry)
        self.entry.connect("search-changed", lambda *_a: changed())
        self.connect("notify::search-mode-enabled", lambda b, _p: b.get_search_mode() or self.entry.set_text(""))

    def open(self):
        self.set_search_mode(True)
        self.entry.grab_focus()

    def toggle(self):
        """A search button for the page's bottom bar, on while the bar is open."""
        button = named(Gtk.ToggleButton(icon_name="system-search-symbolic", tooltip_text=_("Search results (Ctrl+F)")))
        button.bind_property("active", self, "search-mode-enabled", GObject.BindingFlags.BIDIRECTIONAL)
        return button

    def words(self):
        return self.entry.get_text().casefold().split()


def short_path(path):
    home = GLib.get_home_dir()
    return "~" + path[len(home):] if path.startswith(home + "/") else path


def can_exclude(engine, folder):
    """A folder Settings › Never clean takes: inside the home folder ENGINE runs with, not that folder itself."""
    home = os.path.realpath(engine.env.get("HOME") or GLib.get_home_dir())
    return bool(folder) and os.path.realpath(folder).startswith(home + "/")


def never_clean_actions(widget, callback):
    """`rows.never-clean` on WIDGET (a page): CALLBACK(folder) when a row's menu item is chosen."""
    actions = Gio.SimpleActionGroup()
    action = Gio.SimpleAction(name="never-clean", parameter_type=GLib.VariantType.new("s"))
    action.connect("activate", lambda _a, p: callback(p.get_string()))
    actions.add_action(action)
    widget.insert_action_group("rows", actions)


def never_clean_button(folder, label=None):
    """The More button at the end of a row, with Never Clean (FOLDER) in its menu."""
    menu = Gio.Menu()
    item = Gio.MenuItem.new(label or _("Never Clean This Folder"), None)
    item.set_action_and_target_value("rows.never-clean", GLib.Variant.new_string(folder))
    menu.append_item(item)
    return named(Gtk.MenuButton(icon_name="view-more-symbolic", menu_model=menu, valign=Gtk.Align.CENTER,
                                css_classes=["flat"], tooltip_text=_("More")))


def never_clean(page, folder, saved, undone=None, ended=None):
    """Save FOLDER in Settings › Never clean through PAGE's engine; SAVED() then takes what is in it off the
    page. Undo takes it out of the list again and calls UNDONE(). ENDED() runs once the engine answered, saved
    or not."""
    window, engine, result = page.window, page.engine, {}

    def on_event(e):
        if e["event"] in ("task", "error"):
            result.update(e)

    def on_done(ok, status):
        window.set_busy(False)
        if ended:
            ended()
        if result.get("state") != "ok":
            window.toast(_("Could not change it: {reason}").format(reason=messages.text(result)))
        elif engine.dry_run:
            window.toast(_("Dry run: nothing was saved"))
        else:
            saved()
            window.toast(_("{folder} is never cleaned now").format(folder=short_path(folder)), _("Undo"),
                         lambda: allow_clean(page, folder, undone), timeout=10)

    window.set_busy(True)
    return engine.settings_set("exclusions", ["add", folder], on_event, on_done)


def allow_clean(page, folder, undone=None):
    """Undo of Never clean: FOLDER can be cleaned again."""
    window = page.window

    def on_done(ok, status):
        window.set_busy(False)
        if ok:
            window.toast(_("{folder} can be cleaned again").format(folder=short_path(folder)))
            if undone:
                undone()

    window.set_busy(True)
    return page.engine.settings_set("exclusions", ["remove", folder], lambda e: None, on_done)


def inside(path, folder):
    return path == folder or path.startswith(folder.rstrip("/") + "/")
