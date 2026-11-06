"""The welcome: three steps the first time the desktop app opens, and again from the main menu.

1. What CleanMate does and how it deletes safely. 2. What needs your password, what is never touched, and
the terminal app. 3. The main options — the Settings rows themselves (`SettingsPage` with `keys`), so they
save the same keys and turn the same timers on and off — and the way in: its button runs Smart Scan. Closing it the first time saves `welcome_shown=1`
through the engine; opened from the menu it changes nothing. It doesn't open by itself in the self-test,
for screenshots or as root (settings are per user, so it would come back every time).
The steps move in a `Gtk.Stack` (a `Adw.Carousel` hands each page only its natural width, so the steps
shrank to a narrow column in the middle of the dialog) with a dot per step as the indicator.
The Flatpak's welcome only promises what the Flatpak does: no Uninstaller, password, terminal app or
automatic cleaning; step 2 says what it reaches and links to its limits.
"""
from gi.repository import Adw, Gtk

from . import i18n
from .engine import IN_FLATPAK
from .i18n import _
from .settings import SettingsPage, flatpak_limits_row
from .rows import plain_row

OPTIONS = ("language", "schedule", "remind", "low_disk_pct")  # rows of the last step, keys of the settings file
FLATPAK_OPTIONS = ("language", "low_disk_pct")  # no systemd timers in the Flatpak: no schedule, no reminder


def is_new(config=None):
    """True until the welcome was closed once (`welcome_shown=1` in the settings file)."""
    return i18n.saved_setting("welcome_shown", config) != "1"


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
    def __init__(self, window, first_run=False, flatpak=None):
        super().__init__(title=_("Welcome to CleanMate"), content_width=560, content_height=680)
        self.window = window
        self.flatpak = IN_FLATPAK if flatpak is None else flatpak
        self.terminal_button = None
        self.first_run = first_run  # closing saves welcome_shown
        self.marked = False
        self.index = 0

        self.options = SettingsPage(window, keys=FLATPAK_OPTIONS if self.flatpak else OPTIONS,
                                    flatpak=self.flatpak, intro=intro(
            "emblem-system-symbolic", _("Your options"),
            _("Change them any time in Settings, in the main menu (Ctrl+,).")))
        self.options.before_restart = self.mark_shown  # a new language restarts the app: don't come back
        self.steps = [self.what_step(), self.flatpak_step() if self.flatpak else self.scope_step(), self.options]
        self.pager = Gtk.Stack(transition_type=Gtk.StackTransitionType.SLIDE_LEFT_RIGHT, transition_duration=250,
                               vexpand=True, hhomogeneous=True, vhomogeneous=True)
        for i, step in enumerate(self.steps):
            self.pager.add_named(step, str(i))
        self.pager.connect("notify::visible-child", self.on_page)
        self.dots = [Gtk.Box(css_classes=["welcome-dot"]) for _ in self.steps]
        dots_box = Gtk.Box(spacing=4, valign=Gtk.Align.CENTER)
        for dot in self.dots:
            dots_box.append(dot)

        self.skip = Gtk.Button(label=_("Skip"))
        self.skip.connect("clicked", lambda *_a: self.close())
        self.back = Gtk.Button(label=_("Back"))
        self.back.connect("clicked", lambda *_a: self.go(self.index - 1))
        self.next = Gtk.Button(label=_("Next"), css_classes=["suggested-action"])
        self.next.connect("clicked", lambda *_a: self.start() if self.index == len(self.steps) - 1
                          else self.go(self.index + 1))
        header = Adw.HeaderBar()
        header.pack_start(self.skip)
        bottom = Gtk.CenterBox(start_widget=self.back, center_widget=dots_box,
                               end_widget=self.next, margin_start=12, margin_end=12, margin_top=6, margin_bottom=12)
        view = Adw.ToolbarView(content=self.pager)
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
        if self.flatpak:
            smart = _("Junk in your home folder in one scan: caches, old app logs, developer and AI tool junk "
                      "and the Trash.")
            tool = ("edit-copy-symbolic", _("Large & Old Files and Duplicates"),
                    _("Find big, old and duplicate files and move the ones you pick to the Trash."))
        else:
            smart = _("System, developer and AI tool junk in one scan: caches, old logs, unused packages and what "
                      "removed apps left behind.")
            tool = ("application-x-addon-symbolic", _("Uninstaller"),
                    _("Remove apps and the folders they leave in your home."))
        page.add(points(_("What it does"), [
            ("starred-symbolic", _("Smart Scan"), smart),
            ("security-high-symbolic", _("Privacy"),
             _("Browser history and cookies, terminal history and recent files.")),
            tool,
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
             _("Cleans only user and developer junk and AI caches, so it never asks for your password. "
               "On a laptop it waits until it is plugged in.")),
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
        row = plain_row(Adw.ActionRow, title=_("All tools (terminal)"), subtitle=_("Open the terminal app (cm)"))
        row.add_prefix(Gtk.Image(icon_name="utilities-terminal-symbolic"))
        button = Gtk.Button(label=_("Open"), valign=Gtk.Align.CENTER)
        button.connect("clicked", lambda *_a: self.window.open_terminal())
        row.add_suffix(button)
        row.set_activatable_widget(button)
        self.terminal_button = button
        terminal.add(row)
        page.add(terminal)
        return page

    def flatpak_step(self):
        """Step 2 of the Flatpak: what it reaches, what it never touches, and a link to what it can't do."""
        page = Adw.PreferencesPage()
        page.add(intro("user-home-symbolic", _("What the Flatpak reaches"),
                       _("It runs as you, inside your home folder.")))
        page.add(points(None, [
            ("user-home-symbolic", _("Your home folder"),
             _("Caches, old app logs, developer and AI tool junk and the Trash. Your own files only when you "
               "pick them in Space Lens, Large & Old Files or Duplicates — and then they go to the Trash.")),
        ]))
        page.add(points(_("Never touched"), [
            ("channel-secure-symbolic", _("Logins and keys"),
             _(".ssh, .gnupg and saved logins, your settings and bookmarks.")),
        ]))
        limits = Adw.PreferencesGroup()
        self.limits_row = flatpak_limits_row(self.window)
        limits.add(self.limits_row)
        page.add(limits)
        return page

    # ── moving ──
    def go(self, index):
        index = max(0, min(index, len(self.steps) - 1))
        if index == self.index:
            return
        self.pager.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT if index > self.index
                                       else Gtk.StackTransitionType.SLIDE_RIGHT)
        self.pager.set_visible_child(self.steps[index])

    def on_page(self, *_a):
        self.index = self.steps.index(self.pager.get_visible_child())
        self.update()

    def update(self):
        last = self.index == len(self.steps) - 1
        self.back.set_visible(self.index > 0)
        self.skip.set_visible(not last)
        self.next.set_label(_("Run Smart Scan") if last else _("Next"))
        for i, dot in enumerate(self.dots):
            if i == self.index:
                dot.add_css_class("active")
            else:
                dot.remove_css_class("active")

    def start(self):
        """The last step's button: close and run the first Smart Scan."""
        self.close()
        self.window.start_smart_scan()

    def mark_shown(self):
        """The first time only: saved with the options, in order, so neither undoes the other."""
        if self.first_run and not self.marked:
            self.marked = True
            self.options.change("welcome_shown", "1")

    def on_closed(self):
        self.options.flush()
        self.mark_shown()
