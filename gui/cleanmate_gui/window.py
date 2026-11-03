"""Main window: sidebar on the left, the selected page on the right."""
import os
import shutil
import subprocess

from gi.repository import Adw, Gio, GLib, Gtk

from .a11y import named
from . import bugreport, state
from .bugreport import REPO_URL, WEBSITE_URL
from .duplicates import DuplicatesPage
from .engine import FLATPAK_HIDDEN_PAGES, IN_FLATPAK, SMART_SCAN, Selection, human
from .i18n import _
from .largefiles import LargeFilesPage
from .maintenance import MaintenancePage
from .overview import OverviewPage
from .scanpage import ScanPage
from .settings import SettingsPage
from .spacelens import SpaceLensPage
from .startup import StartupPage
from .uninstaller import UninstallerPage
from .welcome import Welcome

TOOL_PAGES = {"lens": SpaceLensPage, "large": LargeFilesPage, "dupes": DuplicatesPage,
              "uninstall": UninstallerPage, "startup": StartupPage,
              "maintenance": MaintenancePage, "overview": OverviewPage}  # pages with their own engine commands


def disk_space(paths=None):
    """[(mount point, free bytes, total bytes)]: the filesystem holding / and, when it is another one, the one
    holding your home (in the Flatpak only your home's: / is the sandbox)."""
    home = os.path.expanduser("~")
    disks, seen = [], set()
    for path in paths or ([home] if IN_FLATPAK else ["/", home]):
        try:
            dev, st = os.stat(path).st_dev, os.statvfs(path)
        except OSError:
            continue
        if dev in seen:
            continue
        seen.add(dev)
        mount = path
        while mount != "/" and not os.path.ismount(mount):
            mount = os.path.dirname(mount)
        disks.append((mount, st.f_bavail * st.f_frsize, st.f_blocks * st.f_frsize))
    return disks


# (id, title, icon, categories, description) — same order as the terminal app's menu
PAGES = [
    ("smart", _("Smart Scan"), "starred-symbolic", SMART_SCAN,
     _("Scan everything in one go and clean what you don't need. Nothing is removed until you confirm.")),
    None,  # section: Cleanup
    ("system", _("System Junk"), "computer-symbolic", ["system"],
     _("Package cache, unused packages and kernels, leftover configs, old Snap revisions, temp files.")),
    ("logs", _("Logs"), "text-x-generic-symbolic", ["logs"],
     _("Systemd journal, oversized and rotated logs, crash reports, old app logs.")),
    ("user", _("User & App Junk"), "user-home-symbolic", ["user", "browser", "apps"],
     _("Trash, thumbnails, stale caches — and every browser and app cache on its own.")),
    ("ai", _("AI Tools"), "applications-science-symbolic", ["ai", "models"],
     _("Caches, logs and old chat sessions of Claude, Codex, Gemini/Antigravity, opencode, ZCode, Zed and more — "
       "and downloaded Ollama, Hugging Face and LM Studio models, each on its own.")),
    ("dev", _("Developer Junk"), "applications-engineering-symbolic", ["dev"],
     _("Stale node_modules and project build folders, npm, pip, Go, Cargo, Conda, Docker and Podman leftovers, "
       "Firebase CLI logs.")),
    ("privacy", _("Privacy"), "security-high-symbolic", ["privacy"],
     _("Browser history and cookies, terminal history, recent files, run dialog and emoji history.")),
    None,  # section: Tools
    ("lens", _("Space Lens"), "folder-symbolic", None,
     _("See what takes up the space, folder by folder, and move what you don't need to the Trash. "
       "You can undo it.")),
    ("large", _("Large & Old Files"), "drive-harddisk-symbolic", None,
     _("Find the biggest files, or the ones you haven't opened in months, and move what you don't need "
       "to the Trash. You can undo it.")),
    ("dupes", _("Duplicates"), "edit-copy-symbolic", None,
     _("Find identical files, keep one copy of each and move the others to the Trash. You can undo it.")),
    ("uninstall", _("Uninstaller"), "application-x-addon-symbolic", None,
     _("Remove apps from apt, Snap, Flatpak and AppImage, and the folders they leave in your home.")),
    ("startup", _("Startup Items"), "system-reboot-symbolic", None,
     _("Choose which apps and services start when you log in.")),
    ("maintenance", _("Maintenance"), "emblem-system-symbolic", None,
     _("Update everything, repair packages, TRIM, rebuild caches, and keep snap versions and system logs "
       "from piling up again.")),
    ("overview", _("System Overview"), "utilities-system-monitor-symbolic", None,
     _("Your system, disks, free space over time, memory, the space CleanMate freed, and your largest "
       "folders.")),
]
if IN_FLATPAK:  # what the Flatpak can't reach is left out (engine.IN_FLATPAK); the descriptions say what is left
    _FLATPAK_DESCRIPTIONS = {
        "system": _("Old installers, downloads and screenshots, and unfinished downloads. The package cache, "
                    "old kernels and snaps are out of the Flatpak's reach."),
        "logs": _("Old app logs. The systemd journal, /var/log and crash reports are out of the Flatpak's reach."),
    }
    PAGES = [(s[0], s[1], s[2], s[3], _FLATPAK_DESCRIPTIONS.get(s[0], s[4])) if s else s
             for s in PAGES if not (s and s[0] in FLATPAK_HIDDEN_PAGES)]
# Ctrl+1…9: the System Overview (where the app opens) first, then the sidebar from the top
SHORTCUT_PAGES = ["overview", "smart", "system", "logs", "user", "ai", "dev", "privacy", "lens"]
# the other tools: Ctrl+0, then Ctrl+Shift+1…4 (pages the Flatpak hides get none)
MORE_SHORTCUTS = [(pid, accel) for pid, accel in (
    ("large", "<Control>0"), ("dupes", "<Control><Shift>1"), ("uninstall", "<Control><Shift>2"),
    ("startup", "<Control><Shift>3"), ("maintenance", "<Control><Shift>4"))
    if not (IN_FLATPAK and pid in FLATPAK_HIDDEN_PAGES)]
ACCEL_LABELS = {"<Control>0": "Ctrl+0", "<Control><Shift>1": "Ctrl+Shift+1", "<Control><Shift>2": "Ctrl+Shift+2",
                "<Control><Shift>3": "Ctrl+Shift+3", "<Control><Shift>4": "Ctrl+Shift+4"}


class Window(Adw.ApplicationWindow):
    def __init__(self, app, engine):
        super().__init__(application=app, title="CleanMate", default_width=1060, default_height=720,
                         width_request=360, height_request=320)
        self.engine = engine
        self.selection = Selection()
        self.pages = {}
        self.overview_stale = False  # something freed space since System Overview last measured
        self._busy = 0

        # ── sidebar ──
        self.sidebar_list = Gtk.ListBox(css_classes=["navigation-sidebar"])
        self.sidebar_list.set_header_func(self._section_header)
        for spec in PAGES:
            if spec is None:
                continue
            pid, title, icon = spec[:3]
            box = Gtk.Box(spacing=12)
            box.append(Gtk.Image(icon_name=icon))
            box.append(Gtk.Label(label=title, xalign=0))
            row = Gtk.ListBoxRow(child=box)
            if pid in SHORTCUT_PAGES:
                row.set_tooltip_text(f"{title} (Ctrl+{SHORTCUT_PAGES.index(pid) + 1})")
            for other, accel in MORE_SHORTCUTS:
                if other == pid:
                    row.set_tooltip_text(f"{title} ({ACCEL_LABELS[accel]})")
            row.page_id = pid
            self.sidebar_list.append(row)
        if not IN_FLATPAK:  # the sandbox can't open a terminal on your desktop
            more = Gtk.Box(spacing=12)
            more.append(Gtk.Image(icon_name="utilities-terminal-symbolic"))
            more.append(Gtk.Label(label=_("All tools (terminal)"), xalign=0))
            more_row = Gtk.ListBoxRow(child=more, tooltip_text=_("Open the terminal app (cm)"))
            more_row.page_id = "terminal"
            self.sidebar_list.append(more_row)
        self.sidebar_list.connect("row-activated", self._on_row_activated)

        self.disk_bar = Gtk.LevelBar(min_value=0, max_value=1)
        self.disk_label = Gtk.Label(xalign=0, css_classes=["caption", "dim-label"])
        disk = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6,
                       margin_start=12, margin_end=12, margin_top=6, margin_bottom=12)
        disk.append(self.disk_bar)
        disk.append(self.disk_label)

        menu = Gio.Menu()
        main = Gio.Menu()
        main.append(_("Settings"), "win.settings")
        main.append(_("Keyboard Shortcuts"), "win.shortcuts")
        if not IN_FLATPAK:
            main.append(_("Open the terminal app"), "win.terminal")
        menu.append_section(None, main)
        help_ = Gio.Menu()
        help_.append(_("Getting Started…"), "win.welcome")
        help_.append(_("Report a Bug…"), "win.report-bug")
        help_.append(_("Suggest a Feature…"), "win.suggest")
        help_.append(_("Share CleanMate"), "win.share")
        help_.append(_("Source code"), "win.source")
        menu.append_section(None, help_)
        about = Gio.Menu()
        about.append("HomieLab", "win.homepage")
        about.append(_("About CleanMate"), "win.about")
        menu.append_section(None, about)
        side_header = Adw.HeaderBar()
        side_header.pack_end(named(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu,
                                                  tooltip_text=_("Main menu"))))
        side = Adw.ToolbarView(content=Gtk.ScrolledWindow(child=self.sidebar_list, vexpand=True))
        side.add_top_bar(side_header)
        side.add_bottom_bar(disk)
        sidebar_page = Adw.NavigationPage(title="CleanMate", child=side)

        # ── content ──
        self.content_stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE)
        self.spinner = Gtk.Spinner()
        content_header = Adw.HeaderBar()
        content_header.pack_end(self.spinner)
        content = Adw.ToolbarView(content=self.content_stack)
        content.add_top_bar(content_header)
        if engine.dry_run:
            banner = Adw.Banner(title=_("Dry run — nothing will be deleted"), revealed=True)
            content.add_top_bar(banner)
        self.content_page = Adw.NavigationPage(title=_("System Overview"), child=content)

        self.split = Adw.NavigationSplitView(sidebar=sidebar_page, content=self.content_page,
                                             min_sidebar_width=220, max_sidebar_width=280)
        self.toasts = Adw.ToastOverlay(child=self.split)
        self.set_content(self.toasts)

        bp = Adw.Breakpoint.new(Adw.BreakpointCondition.parse("max-width: 640sp"))
        bp.add_setter(self.split, "collapsed", True)
        self.add_breakpoint(bp)

        for name, cb in (("terminal", self.open_terminal), ("about", self.show_about),
                         ("settings", lambda *_: self.show_settings()),
                         ("welcome", lambda *_: self.show_welcome()),
                         ("source", lambda *_: self._open_url(REPO_URL)),
                         ("report-bug", lambda *_: bugreport.report_bug(self)),
                         ("suggest", lambda *_: bugreport.suggest_feature(self)),
                         ("share", lambda *_: bugreport.share(self)),
                         ("homepage", lambda *_: self._open_url("https://homielab.com"))):
            action = Gio.SimpleAction(name=name)
            action.connect("activate", cb)
            self.add_action(action)
        app.set_accels_for_action("win.settings", ["<Control>comma"])
        go = Gio.SimpleAction(name="page", parameter_type=GLib.VariantType.new("s"))
        go.connect("activate", lambda _a, p: self.go_to(p.get_string()))
        self.add_action(go)
        for n, pid in enumerate(SHORTCUT_PAGES, 1):
            app.set_accels_for_action(f"win.page::{pid}", [f"<Control>{n}"])
        for pid, accel in MORE_SHORTCUTS:
            app.set_accels_for_action(f"win.page::{pid}", [accel])
        for name, cb, accels in (("reload", lambda *_: self.reload_page(), ["<Control>r", "F5"]),
                                 ("find", lambda *_: self.find_on_page(), ["<Control>f"]),
                                 ("shortcuts", lambda *_: self.show_shortcuts(),
                                  ["<Control>question", "<Control>slash"])):
            action = Gio.SimpleAction(name=name)
            action.connect("activate", cb)
            self.add_action(action)
            app.set_accels_for_action(f"win.{name}", accels)
        self.settings_page = None
        self.welcome = None

        self.refresh_disk()
        self.show_page("overview")  # opens at once: the engine answers in the background
        self.select_sidebar("overview")

    # ── navigation ──
    def _section_header(self, row, before):
        titles = {"system": _("Cleanup"), "lens": _("Tools"), "terminal": _("More")}
        title = titles.get(getattr(row, "page_id", ""))
        if title:
            label = Gtk.Label(label=title, xalign=0, margin_start=12, margin_top=12, margin_bottom=6,
                              css_classes=["heading", "dim-label"])
            row.set_header(label)
        else:
            row.set_header(None)

    def _on_row_activated(self, _list, row):
        if row.page_id == "terminal":
            self.open_terminal()
            return
        self.show_page(row.page_id)
        self.split.set_show_content(True)

    def show_page(self, pid):
        spec = next(s for s in PAGES if s and s[0] == pid)
        if pid not in self.pages:
            if pid in TOOL_PAGES:
                page = TOOL_PAGES[pid](self, spec[1], spec[2], spec[4])
            else:
                page = ScanPage(self, spec[1], spec[3], spec[2], spec[4])
                page.groups_changed()
            self.pages[pid] = page
            self.content_stack.add_named(page, pid)
        self.content_stack.set_visible_child_name(pid)
        self.content_page.set_title(spec[1])
        if pid == "overview" and self.overview_stale:
            self.overview_stale = False
            self.pages[pid].reload()

    def go_to(self, pid):
        """Ctrl+1…9: open a page and select it in the sidebar."""
        if self.get_visible_dialog():
            return
        self.show_page(pid)
        self.select_sidebar(pid)
        self.split.set_show_content(True)

    def reload_page(self):
        """Ctrl+R: scan, search or list again on the open page; nothing while it is busy or a dialog is open."""
        page = self.content_stack.get_visible_child()
        if page and not self.get_visible_dialog() and hasattr(page, "reload"):
            page.reload()

    def find_on_page(self):
        """Ctrl+F: search the open page's results (the cleanup pages)."""
        page = self.content_stack.get_visible_child()
        if page and not self.get_visible_dialog() and hasattr(page, "find"):
            page.find()

    def show_shortcuts(self):
        section = Gtk.ShortcutsSection(section_name="shortcuts", title=_("Keyboard Shortcuts"))
        groups = [
            (_("Pages"), [(f"<Control>{n}", next(s[1] for s in PAGES if s and s[0] == pid))
                          for n, pid in enumerate(SHORTCUT_PAGES, 1)]
             + [(accel, next(s[1] for s in PAGES if s and s[0] == pid)) for pid, accel in MORE_SHORTCUTS]),
            (_("General"), [("<Control>r F5", _("Scan, search or list again")),
                            ("<Control>f", _("Search results")),
                            ("<Control>comma", _("Settings")),
                            ("<Control>question", _("Keyboard Shortcuts")),
                            ("<Control>q", _("Quit"))]),
            (_("Space Lens"), [("<Alt>Up BackSpace", _("Up one folder")),
                               ("<Control><Shift>period <Control>h", _("Show or hide hidden files"))]),
        ]
        for title, rows in groups:
            group = Gtk.ShortcutsGroup(title=title)
            for accel, text in rows:
                group.add_shortcut(Gtk.ShortcutsShortcut(accelerator=accel, title=text))
            section.add_group(group)
        win = Gtk.ShortcutsWindow(transient_for=self, modal=True)
        win.add_section(section)
        win.present()
        self.shortcuts_window = win
        return win

    def groups_changed(self):
        """Settings › Scan groups changed: the cleanup pages show whether their group is off."""
        for page in self.pages.values():
            if hasattr(page, "groups_changed"):
                page.groups_changed()

    # ── what the window remembers ──
    def restore_state(self):
        """Open on the page and at the size of the last run."""
        saved = state.load()
        if "width" in saved:
            self.set_default_size(saved["width"], saved["height"])
        if saved.get("maximized"):
            self.maximize()
        pid = saved.get("page")
        if pid and pid != "overview" and any(s and s[0] == pid for s in PAGES):
            self.show_page(pid)
            self.select_sidebar(pid)
        self.connect("close-request", lambda *_: self.save_state() or False)

    def save_state(self):
        width, height = self.get_default_size()
        state.save(self.content_stack.get_visible_child_name() or "overview", width, height, self.is_maximized())

    def notify_cleaned(self, text, dry_run=False):
        """A notification with what a clean freed, when you're not looking at the window (never in a dry run)."""
        if dry_run or self.is_active():
            return
        note = Gio.Notification.new(_("Cleanup complete"))
        note.set_body(text)
        self.get_application().send_notification("cleaned", note)

    def select_sidebar(self, pid):
        row = self.sidebar_list.get_first_child()
        while row and getattr(row, "page_id", None) != pid:
            row = row.get_next_sibling()
        if row:
            self.sidebar_list.select_row(row)

    def open_lens(self, path):
        """Space Lens at one folder (System Overview's largest folders, and / for the space outside your home)."""
        self.show_page("lens")
        self.select_sidebar("lens")
        self.split.set_show_content(True)
        self.pages["lens"].open_folder(path)

    # ── helpers used by pages ──
    def toast(self, text, button=None, on_button=None, timeout=4):
        """Show a toast; with button and on_button it offers an action (e.g. Undo). Returns the toast."""
        toast = Adw.Toast(title=GLib.markup_escape_text(text), timeout=timeout)
        if button and on_button:
            toast.set_button_label(button)
            toast.connect("button-clicked", lambda *_: on_button())
        self.toasts.add_toast(toast)
        return toast

    def set_busy(self, busy):
        self._busy += 1 if busy else -1
        self.spinner.set_spinning(self._busy > 0)

    def refresh_disk(self):
        """Free space in the sidebar: the system disk, and your home's disk too when it is a separate one
        (a /home partition). Called after anything that frees space: System Overview measures again too."""
        disks = disk_space()
        if disks:
            _mount, free, total = disks[0]
            self.disk_bar.set_value(1 - free / total if total else 0)
        if len(disks) == 1:
            self.disk_label.set_text(_("{free} free of {total}").format(free=human(disks[0][1]),
                                                                        total=human(disks[0][2])))
        else:
            self.disk_label.set_text("\n".join(_("{disk}: {free} free of {total}").format(
                disk=mount, free=human(free), total=human(total)) for mount, free, total in disks))
        overview = self.pages.get("overview")
        if overview is not None:
            if self.content_stack.get_visible_child() is overview:
                overview.reload()
            else:
                self.overview_stale = True  # measured again when it is opened

    def open_terminal(self, *_):
        for term in ("x-terminal-emulator", "gnome-terminal", "ptyxis", "kgx"):
            if shutil.which(term):
                argv = [term, "--", "bash", self.engine.path] if term in ("gnome-terminal", "ptyxis", "kgx") \
                    else [term, "-e", f"bash {self.engine.path}"]
                if self.engine.dry_run:
                    argv[-1:] = [argv[-1] + " --dry-run"] if term == "x-terminal-emulator" else [argv[-1], "--dry-run"]
                subprocess.Popen(argv, start_new_session=True)
                return
        self.toast(_("No terminal app found — run cm in a terminal."))

    def _open_url(self, url):
        Gtk.UriLauncher.new(url).launch(self, None, None)

    def show_settings(self):
        """The terminal app's settings in a dialog; read again each time it opens."""
        page = SettingsPage(self)
        dialog = Adw.PreferencesDialog(title=_("Settings"), search_enabled=False)
        dialog.add(page)
        dialog.connect("closed", lambda *_: page.flush())
        self.settings_page = page
        dialog.present(self)
        return dialog

    def show_welcome(self, first_run=False):
        """The three welcome steps; FIRST_RUN (the app's first start) saves that they were seen on close."""
        dialog = Welcome(self, first_run=first_run)
        self.welcome = dialog
        dialog.present(self)
        return dialog

    def show_about(self, *_):
        about = Adw.AboutDialog(
            application_name="CleanMate", application_icon="com.homielab.CleanMate",
            version=self.engine.version(), developer_name="HomieLab", developers=["HomieLab https://homielab.com"],
            copyright="© 2026 HomieLab", license_type=Gtk.License.MIT_X11, website=WEBSITE_URL,
            issue_url=bugreport.issue_url(bugreport.BUG_TEMPLATE),
            translator_credits=_("translator-credits"),
            comments=_("A friendly system cleaner for Ubuntu, inspired by CleanMyMac. "
                       "Not affiliated with MacPaw."))
        about.add_link(_("Source code"), REPO_URL)
        about.present(self)
