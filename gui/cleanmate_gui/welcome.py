"""The welcome: three steps the first time the desktop app opens, and again from the main menu.

1. What CleanMate does and how it deletes safely. 2. What needs your password, what is never touched, and
the terminal app. 3. The main options — the Settings rows themselves (`SettingsPage` with `keys`), so they
save the same keys and turn the same timers on and off. Closing it the first time saves `welcome_shown=1`
through the engine; opened from the menu it changes nothing. It doesn't open by itself in the self-test,
for screenshots or as root (settings are per user, so it would come back every time).
"""
from gi.repository import Adw, Gtk

from . import i18n
from .i18n import _
from .settings import SettingsPage

OPTIONS = ("language", "schedule", "remind", "low_disk_pct")  # rows of the last step, keys of the settings file


def is_new(config=None):
    """True until the welcome was closed once (`welcome_shown=1` in the settings file)."""
    return i18n.saved_setting("welcome_shown", config) != "1"


def animations():
    return Gtk.Settings.get_default().get_property("gtk-enable-animations")


def intro(icon, title, text):
    """The top of a step: a big icon, a title and a sentence."""
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin_bottom=6)
    box.append(Gtk.Image(icon_name=icon, pixel_size=64))
    box.append(Gtk.Label(label=title, wrap=True, justify=Gtk.Justification.CENTER, css_classes=["title-2"]))
    box.append(Gtk.Label(label=text, wrap=True, justify=Gtk.Justification.CENTER, css_classes=["dim-label"]))
    group = Adw.PreferencesGroup()
    group.add(box)
    return group


def points(title, rows, description=None):
    """A group of rows, each an icon, a title and a sentence."""
    group = Adw.PreferencesGroup(title=title, description=description)
    for icon, head, text in rows:
        row = Adw.ActionRow(use_markup=False)  # before the text: "&" isn't markup
        row.set_title(head)
        row.set_subtitle(text)
        row.add_prefix(Gtk.Image(icon_name=icon))
        group.add(row)
    return group


class Welcome(Adw.Dialog):
    def __init__(self, window, first_run=False):
        super().__init__(title=_("Welcome to CleanMate"), content_width=560, content_height=680)
        self.window = window
        self.first_run = first_run  # closing saves welcome_shown
        self.marked = False
        self.index = 0

        self.options = SettingsPage(window, keys=OPTIONS, intro=intro(
            "emblem-system-symbolic", _("Your options"),
            _("Change them any time in Settings, in the main menu (Ctrl+,).")))
        self.options.before_restart = self.mark_shown  # a new language restarts the app: don't come back
        self.steps = [self.what_step(), self.scope_step(), self.options]
        self.carousel = Adw.Carousel(vexpand=True)
        for step in self.steps:
            self.carousel.append(step)
        self.carousel.connect("page-changed", self.on_page)

        self.skip = Gtk.Button(label=_("Skip"))
        self.skip.connect("clicked", lambda *_a: self.close())
        self.back = Gtk.Button(label=_("Back"))
        self.back.connect("clicked", lambda *_a: self.go(self.index - 1))
        self.next = Gtk.Button(label=_("Next"), css_classes=["suggested-action"])
        self.next.connect("clicked", lambda *_a: self.close() if self.index == len(self.steps) - 1
                          else self.go(self.index + 1))
        header = Adw.HeaderBar()
        header.pack_start(self.skip)
        bottom = Gtk.CenterBox(start_widget=self.back, center_widget=Adw.CarouselIndicatorDots(carousel=self.carousel),
                               end_widget=self.next, margin_start=12, margin_end=12, margin_top=6, margin_bottom=12)
        view = Adw.ToolbarView(content=self.carousel)
        view.add_top_bar(header)
        view.add_bottom_bar(bottom)
        self.set_child(Adw.ToastOverlay(child=view))  # the options' toasts
        self.set_default_widget(self.next)
        self.set_focus(self.next)
        self.connect("closed", lambda *_a: self.on_closed())
        self.update()

    # ── steps ──
    def what_step(self):
        page = Adw.PreferencesPage()
        page.add(intro("com.homielab.CleanMate", _("Welcome to CleanMate"),
                       _("Free up disk space and keep Ubuntu tidy — safely.")))
        page.add(points(_("What it does"), [
            ("starred-symbolic", _("Smart Scan"),
             _("System, developer and AI tool junk in one scan: caches, old logs, unused packages and what "
               "removed apps left behind.")),
            ("security-high-symbolic", _("Privacy"),
             _("Browser history and cookies, terminal history and recent files.")),
            ("application-x-addon-symbolic", _("Uninstaller"),
             _("Remove apps and the folders they leave in your home.")),
            ("folder-symbolic", _("Space Lens"), _("See what takes up the space, folder by folder.")),
        ]))
        page.add(points(_("How it stays safe"), [
            ("view-reveal-symbolic", _("You see everything first"),
             _("Each clean lists the items and their sizes, and nothing is removed until you confirm.")),
            ("user-trash-symbolic", _("Your files go to the Trash"),
             _("Caches and logs that apps make again are deleted. Your own files go to the Trash, and Undo puts "
               "them back.")),
            ("emblem-ok-symbolic", _("Open source, no data collected"),
             _("Nothing about you is sent anywhere. The only connection is a daily check for a new version, which "
               "you can turn off; installed from a package, there is none.")),
        ]))
        return page

    def scope_step(self):
        page = Adw.PreferencesPage()
        page.add(intro("dialog-password-symbolic", _("What needs your password"),
                       _("Most cleaning runs as you, without a password.")))
        page.add(points(None, [
            ("system-lock-screen-symbolic", _("Items with a lock"),
             _("The APT cache, system logs, old kernels and old Snap versions belong to the system. Cleaning them "
               "asks for your password in Ubuntu's own dialog; so do removing apt and Snap apps and Maintenance "
               "tasks.")),
            ("emblem-synchronizing-symbolic", _("Automatic cleaning"),
             _("Cleans only user and developer junk, so it never asks for your password.")),
            ("application-x-addon-symbolic", _("Snap, Flatpak and AppImage"),
             _("Apps from apt, Snap, Flatpak and AppImage are all found, with their caches and leftovers.")),
        ]))
        page.add(points(_("Never touched"), [
            ("channel-secure-symbolic", _("Logins and keys"),
             _(".ssh, .gnupg and saved logins, your settings and bookmarks.")),
            ("folder-documents-symbolic", _("Your documents"),
             _("Nothing of yours is removed unless you tick it in Space Lens, Large & Old Files or Duplicates — "
               "and then it goes to the Trash.")),
            ("computer-symbolic", _("The kernel you run"),
             _("Old kernels can go, but never the one you run or the one before it.")),
        ]))
        terminal = Adw.PreferencesGroup(
            title=_("The terminal app"),
            description=_("Run cm in a terminal for every tool, also over SSH. sudo cm cleans the system items "
                          "in one go."))
        row = Adw.ActionRow(title=_("All tools (terminal)"), subtitle=_("Open the terminal app (cm)"))
        row.add_prefix(Gtk.Image(icon_name="utilities-terminal-symbolic"))
        button = Gtk.Button(label=_("Open"), valign=Gtk.Align.CENTER)
        button.connect("clicked", lambda *_a: self.window.open_terminal())
        row.add_suffix(button)
        row.set_activatable_widget(button)
        self.terminal_button = button
        terminal.add(row)
        page.add(terminal)
        return page

    # ── moving ──
    def go(self, index):
        index = max(0, min(index, len(self.steps) - 1))
        self.carousel.scroll_to(self.steps[index], animations())

    def on_page(self, _carousel, index):
        self.index = index
        self.update()

    def update(self):
        last = self.index == len(self.steps) - 1
        self.back.set_visible(self.index > 0)
        self.skip.set_visible(not last)
        self.next.set_label(_("Start") if last else _("Next"))

    def mark_shown(self):
        """The first time only: saved with the options, in order, so neither undoes the other."""
        if self.first_run and not self.marked:
            self.marked = True
            self.options.change("welcome_shown", "1")

    def on_closed(self):
        self.options.flush()
        self.mark_shown()
