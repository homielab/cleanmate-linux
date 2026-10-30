"""System Overview: the system, each disk with a usage bar, memory, and what CleanMate freed lately.

The engine measures it all (`--json overview`), the same facts as the terminal app's System Overview;
this page only shows them. A disk over 90 % full gets the warning colour.
"""
import time

from gi.repository import Adw, GLib, Gtk

from .engine import human
from .i18n import _, ngettext

FULL = 0.9  # a disk fuller than this is shown in the warning colour


def usage_bar(fraction, width=160):
    """A used/total bar; the warning colour over FULL."""
    bar = Gtk.LevelBar(min_value=0, max_value=1, value=min(max(fraction, 0), 1), width_request=width,
                       valign=Gtk.Align.CENTER)
    for name in ("low", "high", "full"):
        bar.remove_offset_value(name)
    if fraction > FULL:
        bar.add_css_class("almost-full")
    return bar


def uptime_text(seconds):
    days, rest = divmod(int(seconds), 86400)
    hours, rest = divmod(rest, 3600)
    minutes = rest // 60
    if days:
        return ngettext("{n} day", "{n} days", days) + ", " + ngettext("{n} hour", "{n} hours", hours)
    if hours:
        return ngettext("{n} hour", "{n} hours", hours) + ", " + ngettext("{n} minute", "{n} minutes", minutes)
    return ngettext("{n} minute", "{n} minutes", minutes)


class OverviewPage(Gtk.Box):
    """Read-only facts in four groups, with a Refresh button."""

    def __init__(self, window, title, icon, description):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self.engine = window.engine
        self.title, self.description = title, description
        self.running = None  # Gio.Cancellable of the current engine run
        self.data = {}  # event name → event ("disk" → list)
        self.render_ms = None  # how long showing the last result took
        self.rows = {}  # key → Adw.ActionRow (disk rows: "disk:" + mount)
        self.bars = {}  # same keys → Gtk.LevelBar

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True)
        self.append(self.stack)
        spinner = Gtk.Spinner(spinning=True, width_request=32, height_request=32, halign=Gtk.Align.CENTER)
        self.stack.add_named(Adw.StatusPage(icon_name=icon, title=title, description=description, child=spinner),
                             "loading")
        self.failed = Adw.StatusPage(icon_name="dialog-warning-symbolic", title=_("Can't measure this system"))
        self.stack.add_named(self.failed, "failed")
        self.results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24,
                               margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        self.stack.add_named(Gtk.ScrolledWindow(child=Adw.Clamp(maximum_size=900, child=self.results),
                                                vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER), "results")
        self.refresh_button = Gtk.Button(label=_("Refresh"), valign=Gtk.Align.CENTER)
        self.refresh_button.connect("clicked", lambda *_a: self.load())
        self.load()

    @property
    def busy(self):
        return self.running is not None

    # ── loading ──
    def load(self):
        if self.running:
            return
        data = {"disk": []}
        if not self.data:
            self.stack.set_visible_child_name("loading")
        self.refresh_button.set_sensitive(False)
        self.window.set_busy(True)

        def on_event(e):
            if e["event"] == "disk":
                data["disk"].append(e)
            else:
                data[e["event"]] = e

        def on_done(ok, status):
            self.running = None
            self.window.set_busy(False)
            self.refresh_button.set_sensitive(True)
            if "error" in data or "system" not in data:
                self.failed.set_description(data.get("error", {}).get("message", ""))
                self.stack.set_visible_child_name("failed")
                return
            t0 = time.monotonic()
            self.data = data
            self.show_results()
            self.render_ms = (time.monotonic() - t0) * 1000

        self.running = self.engine.overview(on_event, on_done)

    # ── results ──
    def show_results(self):
        child = self.results.get_first_child()
        while child:
            self.results.remove(child)
            child = self.results.get_first_child()
        if self.refresh_button.get_parent():
            self.refresh_button.get_parent().remove(self.refresh_button)
        self.rows.clear()
        self.bars.clear()
        d = self.data

        header = Gtk.Box(spacing=12)
        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, hexpand=True)
        text.append(Gtk.Label(label=self.title, xalign=0, wrap=True, css_classes=["title-1"]))
        text.append(Gtk.Label(label=self.description, xalign=0, wrap=True, css_classes=["dim-label"]))
        header.append(text)
        header.append(self.refresh_button)
        self.results.append(header)

        s = d["system"]
        system = Adw.PreferencesGroup(title=_("System"))
        packages = [ngettext("{n} apt package", "{n} apt packages", s["apt"] or 0)]
        if s["snap"] is not None:
            packages.append(ngettext("{n} snap", "{n} snaps", s["snap"]))
        if s["flatpak"] is not None:
            packages.append(ngettext("{n} flatpak", "{n} flatpaks", s["flatpak"]))
        for key, label, value in (
                ("os", _("Operating system"), s["os"] or _("unknown")),
                ("kernel", _("Kernel"), s["kernel"]),
                ("uptime", _("Uptime"), uptime_text(s["uptime"])),
                ("cpu", _("Processor"), ngettext("{cpu} ({n} thread)", "{cpu} ({n} threads)", s["threads"],
                                                 cpu=s["cpu"] or _("unknown"))),
                ("packages", _("Packages"), ", ".join(packages))):
            system.add(self.fact_row(key, label, value))
        self.results.append(system)

        storage = Adw.PreferencesGroup(title=_("Storage"))
        if not d["disk"]:
            storage.set_description(_("No disks found."))
        for disk in d["disk"]:
            used = disk["used"] / disk["size"] if disk["size"] else 0
            text = _("Almost full · {used} of {size} used · {free} free · {fstype}") if used > FULL \
                else _("{used} of {size} used · {free} free · {fstype}")
            subtitle = text.format(used=human(disk["used"]), size=human(disk["size"]), free=human(disk["avail"]),
                                   fstype=disk["fstype"])
            storage.add(self.bar_row("disk:" + disk["mount"], disk["mount"], subtitle, used,
                                     "drive-harddisk-symbolic", disk["device"]))
        self.results.append(storage)

        m = d.get("memory")
        if m:
            memory = Adw.PreferencesGroup(title=_("Memory"))
            ram = m["ram_used"] / m["ram_total"] if m["ram_total"] else 0
            memory.add(self.bar_row("ram", _("RAM"), _("{used} of {size} in use · {free} available").format(
                used=human(m["ram_used"]), size=human(m["ram_total"]), free=human(m["ram_avail"])), ram,
                "computer-symbolic"))
            if m["swap_total"]:
                memory.add(self.bar_row("swap", _("Swap"), _("{used} of {size} in use").format(
                    used=human(m["swap_used"]), size=human(m["swap_total"])), m["swap_used"] / m["swap_total"],
                    "media-flash-symbolic"))
            else:
                memory.add(self.fact_row("swap", _("Swap"), _("none")))
            self.results.append(memory)

        f = d.get("freed")
        freed = Adw.PreferencesGroup(title=_("Freed by CleanMate"))
        if not f:
            freed.set_description(_("Shows here after your first cleanup."))
        else:
            freed.add(self.fact_row("freed30", _("Last 30 days"), ngettext(
                "{size} in {n} cleanup", "{size} in {n} cleanups", f["cleanups"], size=human(f["bytes"]))))
            freed.add(self.fact_row("lifetime", _("In total"), ngettext(
                "{size} in {n} cleanup", "{size} in {n} cleanups", f["runs"], size=human(f["lifetime"]))))
            if f["last_time"]:
                when = GLib.DateTime.new_from_unix_local(f["last_time"]).format("%x")
                freed.add(self.fact_row("last", _("Last cleanup"), _("{size} on {date}").format(
                    size=human(f["last_bytes"]), date=when)))
        self.results.append(freed)
        self.stack.set_visible_child_name("results")

    def fact_row(self, key, label, value):
        row = Adw.ActionRow(title=label, subtitle=value, use_markup=False, subtitle_selectable=True,
                            css_classes=["property"])
        self.rows[key] = row
        return row

    def bar_row(self, key, title, subtitle, fraction, icon, tooltip=None):
        row = Adw.ActionRow(title=title, subtitle=subtitle, use_markup=False, css_classes=["item-row"],
                            tooltip_text=tooltip)
        row.add_prefix(Gtk.Image(icon_name=icon, pixel_size=24))
        bar = usage_bar(fraction)
        pct = Gtk.Label(label=f"{fraction * 100:.0f}%", width_chars=5, xalign=1,
                        css_classes=["numeric"] + (["size-medium"] if fraction > FULL else ["dim-label"]))
        row.add_suffix(bar)
        row.add_suffix(pct)
        self.rows[key] = row
        self.bars[key] = bar
        return row
