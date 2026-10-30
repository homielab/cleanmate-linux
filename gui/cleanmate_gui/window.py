"""Main window: sidebar on the left, the selected page on the right."""
import os
import shutil
import subprocess

from gi.repository import Adw, Gio, GLib, Gtk

from .duplicates import DuplicatesPage
from .engine import SMART_SCAN, Selection, human
from .i18n import _
from .largefiles import LargeFilesPage
from .maintenance import MaintenancePage
from .overview import OverviewPage
from .scanpage import ScanPage
from .settings import SettingsPage
from .spacelens import SpaceLensPage
from .startup import StartupPage
from .uninstaller import UninstallerPage

TOOL_PAGES = {"lens": SpaceLensPage, "large": LargeFilesPage, "dupes": DuplicatesPage,
              "uninstall": UninstallerPage, "startup": StartupPage,
              "maintenance": MaintenancePage, "overview": OverviewPage}  # pages with their own engine commands

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
     _("Terminal history, recent files, run dialog and emoji history.")),
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
     _("Remove apps from apt, Snap and Flatpak, and the folders they leave in your home.")),
    ("startup", _("Startup Items"), "system-reboot-symbolic", None,
     _("Choose which apps and services start when you log in.")),
    ("maintenance", _("Maintenance"), "emblem-system-symbolic", None,
     _("Update everything, repair packages, TRIM, rebuild caches, and keep snap versions and system logs "
       "from piling up again.")),
    ("overview", _("System Overview"), "utilities-system-monitor-symbolic", None,
     _("Your system, disks, free space over time, memory, the space CleanMate freed, and your largest "
       "folders.")),
]
# Ctrl+1…9: the System Overview (where the app opens) first, then the sidebar from the top
SHORTCUT_PAGES = ["overview", "smart", "system", "logs", "user", "ai", "dev", "privacy", "lens"]
REPO_URL = "https://github.com/homielab/cleanmate-linux"


class Window(Adw.ApplicationWindow):
    def __init__(self, app, engine):
        super().__init__(application=app, title="CleanMate", default_width=1060, default_height=720,
                         width_request=360, height_request=320)
        self.engine = engine
        self.selection = Selection()
        self.pages = {}
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
            row.page_id = pid
            self.sidebar_list.append(row)
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
        menu.append(_("Settings"), "win.settings")
        menu.append(_("Keyboard Shortcuts"), "win.shortcuts")
        menu.append(_("Open the terminal app"), "win.terminal")
        menu.append(_("Source code"), "win.source")
        menu.append(_("Report a problem"), "win.issues")
        menu.append("HomieLab", "win.homepage")
        menu.append(_("About CleanMate"), "win.about")
        side_header = Adw.HeaderBar()
        side_header.pack_end(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu,
                                            tooltip_text=_("Main menu")))
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
                         ("source", lambda *_: self._open_url(REPO_URL)),
                         ("issues", lambda *_: self._open_url(REPO_URL + "/issues")),
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
        for name, cb, accels in (("reload", lambda *_: self.reload_page(), ["<Control>r", "F5"]),
                                 ("shortcuts", lambda *_: self.show_shortcuts(),
                                  ["<Control>question", "<Control>slash"])):
            action = Gio.SimpleAction(name=name)
            action.connect("activate", cb)
            self.add_action(action)
            app.set_accels_for_action(f"win.{name}", accels)
        self.settings_page = None

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
            self.pages[pid] = page
            self.content_stack.add_named(page, pid)
        self.content_stack.set_visible_child_name(pid)
        self.content_page.set_title(spec[1])

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

    def show_shortcuts(self):
        section = Gtk.ShortcutsSection(section_name="shortcuts", title=_("Keyboard Shortcuts"))
        groups = [
            (_("Pages"), [(f"<Control>{n}", next(s[1] for s in PAGES if s and s[0] == pid))
                          for n, pid in enumerate(SHORTCUT_PAGES, 1)]),
            (_("General"), [("<Control>r F5", _("Scan, search or list again")),
                            ("<Control>comma", _("Settings")),
                            ("<Control>question", _("Keyboard Shortcuts")),
                            ("<Control>q", _("Quit"))]),
            (_("Space Lens"), [("<Alt>Up BackSpace", _("Up one folder"))]),
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

    def select_sidebar(self, pid):
        row = self.sidebar_list.get_first_child()
        while row and getattr(row, "page_id", None) != pid:
            row = row.get_next_sibling()
        if row:
            self.sidebar_list.select_row(row)

    def open_lens(self, path):
        """Space Lens at one folder (System Overview's largest folders)."""
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
        st = os.statvfs("/")
        total, free = st.f_blocks * st.f_frsize, st.f_bavail * st.f_frsize
        used = 1 - free / total if total else 0
        self.disk_bar.set_value(used)
        self.disk_label.set_text(_("{free} free of {total}").format(free=human(free), total=human(total)))

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

    def show_about(self, *_):
        about = Adw.AboutDialog(
            application_name="CleanMate", application_icon="com.homielab.CleanMate",
            version=self.engine.version(), developer_name="HomieLab", developers=["HomieLab https://homielab.com"],
            copyright="© 2026 HomieLab", license_type=Gtk.License.MIT_X11, website=REPO_URL,
            issue_url=REPO_URL + "/issues",
            translator_credits=_("translator-credits"),
            comments=_("A friendly system cleaner for Ubuntu, inspired by CleanMyMac. "
                       "Not affiliated with MacPaw."))
        about.present(self)
