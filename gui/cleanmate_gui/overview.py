"""System Overview: the system, each disk with a usage bar, free space over time, memory, what CleanMate
freed lately, space outside your folders, your largest folders and whether the system's protections are on.

The engine measures it all (`--json overview`), the same facts as the terminal app's System Overview;
this page only shows them. A disk over 90 % full gets the warning colour. The engine sends the quick facts
first and measures folders (du) last: the page shows as soon as the quick part is there, and the last two
groups fill in when the rest arrives. System protection is read only: when one is off the page shows the
command that turns it on, to copy and run in a terminal; the app never runs it. What CleanMate freed shows as
three numbers and a bar per day over the last 30 days; they count up and grow once per app session, unless
the system turns animations off.
"""
import datetime
import os
import sys
import time

from gi.repository import Adw, GLib, Gtk

from .a11y import named
from .engine import IN_FLATPAK, human
from .i18n import _, ngettext
from .largefiles import short_path
from .scanpage import size_widgets
from . import messages
from .rows import plain_row

FULL = 0.9  # a disk fuller than this is shown in the warning colour
HISTORY_POINTS = 30  # days in the free-space chart
WEEK_CHANGE = 100 << 20  # free space changing less than this a week counts as stable
ANIMATION_MS = 600  # the Freed numbers count up and the bars grow this long


_charts_ok = None  # None until the first chart asks; remembered for the whole session


def charts_ok():
    """True when PyGObject can hand a cairo.Context to a draw callback: the `python3-gi-cairo` package.
    Without it the charts are left out (a note shows instead) and the app keeps working."""
    global _charts_ok
    if _charts_ok is None:
        try:
            import gi
            gi.require_foreign("cairo")
            _charts_ok = True
        except Exception as error:  # not installed, or present without its cairo bridge
            _charts_ok = False
            print(f"cleanmate-gui: the Overview charts need python3-gi-cairo "
                  f"(install it with: sudo apt install python3-gi-cairo): {error}", file=sys.stderr, flush=True)
    return _charts_ok


def charts_note():
    """The line that stands where a chart would be when python3-gi-cairo is missing."""
    return Gtk.Label(label=_("Install python3-gi-cairo to see the charts."), wrap=True,
                     justify=Gtk.Justification.CENTER, margin_top=6, margin_bottom=6,
                     css_classes=["dim-label"])


def guarded_draw(draw):
    """A draw func that can't take the app down: an error is logged once and the chart draws nothing."""
    warned = []

    def guarded(area, cr, width, height):
        try:
            draw(area, cr, width, height)
        except Exception as error:
            if not warned:
                warned.append(1)
                print(f"cleanmate-gui: drawing the chart failed, the app goes on: {error}",
                      file=sys.stderr, flush=True)
    return guarded


def last_scan_text(epoch, today=None):
    """When either app last scanned or cleaned (the engine's "last_scan"; 0 = never), in calendar days."""
    if not epoch:
        return _("No scan yet — see in a minute what can be cleaned.")
    days = ((today or datetime.date.today()) - datetime.date.fromtimestamp(epoch)).days
    if days <= 0:
        return _("Last scan: today")
    if days == 1:
        return _("Last scan: yesterday")
    return ngettext("Last scan: {n} day ago", "Last scan: {n} days ago", days)


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


def history_trend(points):
    """The free-space history in words, like the terminal app: where it went and how fast."""
    first, last = points[0], points[-1]
    text = _("{start} free on {start_date} → {end} on {end_date}.").format(
        start=human(first["avail"]), start_date=day_text(first["time"]),
        end=human(last["avail"]), end_date=day_text(last["time"]))
    days = (last["time"] - first["time"]) // 86400
    if days <= 0:
        return text
    per_week = (last["avail"] - first["avail"]) * 7 // days
    if per_week < -WEEK_CHANGE:
        weeks = last["avail"] // -per_week
        trend = ngettext("Losing about {size} a week: at this rate the disk is full in about {n} week.",
                         "Losing about {size} a week: at this rate the disk is full in about {n} weeks.",
                         weeks, size=human(-per_week))
    elif per_week > WEEK_CHANGE:
        trend = _("Gaining about {size} a week.").format(size=human(per_week))
    else:
        trend = ngettext("Stable over the last {n} day.", "Stable over the last {n} days.", days)
    return text + " " + trend


def day_text(epoch):
    return GLib.DateTime.new_from_unix_local(epoch).format("%x")


class HistoryChart(Gtk.DrawingArea):
    """Free space on / per day as a line in the accent colour; hovering a day shows its date and value."""

    PAD = 8

    def __init__(self, points):
        super().__init__(content_height=120, hexpand=True, has_tooltip=True, css_classes=["accent"],
                         margin_top=12, margin_bottom=12, margin_start=12, margin_end=12)
        self.points = points[-HISTORY_POINTS:]
        self.hover = None
        self.set_draw_func(guarded_draw(self.draw))
        self.connect("query-tooltip", self.on_query_tooltip)
        motion = Gtk.EventControllerMotion()
        motion.connect("motion", lambda _c, x, _y: self.set_hover(self.index_at(x)))
        motion.connect("leave", lambda _c: self.set_hover(None))
        self.add_controller(motion)

    def set_hover(self, index):
        if index != self.hover:
            self.hover = index
            self.queue_draw()

    def index_at(self, x):
        span = self.get_width() - 2 * self.PAD
        n = len(self.points)
        if span <= 0 or n < 2:
            return None
        return min(max(round((x - self.PAD) / span * (n - 1)), 0), n - 1)

    def point_text(self, index):
        p = self.points[index]
        return _("{date}: {free} free").format(date=day_text(p["time"]), free=human(p["avail"]))

    def on_query_tooltip(self, _widget, x, _y, _keyboard, tooltip):
        index = self.index_at(x)
        if index is None:
            return False
        tooltip.set_text(self.point_text(index))
        return True

    def xy(self, width, height):
        values = [p["avail"] for p in self.points]
        low, high = min(values), max(values)
        margin = (high - low) * 0.1 or max(high * 0.05, 1)  # a flat line sits in the middle
        low, high = low - margin, high + margin
        n = len(values)
        return [(self.PAD + i * (width - 2 * self.PAD) / (n - 1),
                 self.PAD + (high - v) / (high - low) * (height - 2 * self.PAD)) for i, v in enumerate(values)]

    def draw(self, _area, cr, width, height):
        if len(self.points) < 2:
            return
        color = self.get_color()
        xy = self.xy(width, height)
        cr.move_to(xy[0][0], height - self.PAD)
        for x, y in xy:
            cr.line_to(x, y)
        cr.line_to(xy[-1][0], height - self.PAD)
        cr.close_path()
        cr.set_source_rgba(color.red, color.green, color.blue, 0.15)
        cr.fill()
        cr.move_to(*xy[0])
        for x, y in xy[1:]:
            cr.line_to(x, y)
        cr.set_source_rgba(color.red, color.green, color.blue, 1)
        cr.set_line_width(2)
        cr.stroke()
        for i in {len(xy) - 1, self.hover} - {None}:
            cr.arc(xy[i][0], xy[i][1], 4, 0, 6.2832)
            cr.fill()


def date_text(iso):
    """A "YYYY-MM-DD" day from the engine as the locale's date."""
    year, month, day = (int(part) for part in iso.split("-"))
    return GLib.DateTime.new_local(year, month, day, 12, 0, 0).format("%x")


class FreedByDayChart(Gtk.DrawingArea):
    """What CleanMate freed per day as bars in the accent colour; hovering a day shows its date and size."""

    PAD = 8

    def __init__(self, days):
        super().__init__(content_height=120, hexpand=True, has_tooltip=True, css_classes=["accent"],
                         margin_top=12, margin_bottom=12, margin_start=12, margin_end=12)
        self.days = days  # [{"date", "bytes", "cleanups"}], oldest first
        self.hover = None
        self.progress = 1.0  # share of each bar's height, while they grow
        self.set_draw_func(guarded_draw(self.draw))
        self.connect("query-tooltip", self.on_query_tooltip)
        motion = Gtk.EventControllerMotion()
        motion.connect("motion", lambda _c, x, _y: self.set_hover(self.index_at(x)))
        motion.connect("leave", lambda _c: self.set_hover(None))
        self.add_controller(motion)

    def set_progress(self, progress):
        self.progress = progress
        self.queue_draw()

    def set_hover(self, index):
        if index != self.hover:
            self.hover = index
            self.queue_draw()

    def index_at(self, x):
        span = self.get_width() - 2 * self.PAD
        n = len(self.days)
        if span <= 0 or not n:
            return None
        return min(max(int((x - self.PAD) / span * n), 0), n - 1)

    def day_text(self, index):
        d = self.days[index]
        if not d["cleanups"]:
            return _("{date}: no cleanup").format(date=date_text(d["date"]))
        return ngettext("{date}: {size} freed in {n} cleanup", "{date}: {size} freed in {n} cleanups",
                        d["cleanups"], date=date_text(d["date"]), size=human(d["bytes"]))

    def on_query_tooltip(self, _widget, x, _y, _keyboard, tooltip):
        index = self.index_at(x)
        if index is None:
            return False
        tooltip.set_text(self.day_text(index))
        return True

    def bars(self, width, height):
        """(x, y, w, h) of each day's bar, None for a day without a cleanup; a cleanup shows at least 2 px."""
        slot = (width - 2 * self.PAD) / len(self.days)
        high = max(d["bytes"] for d in self.days) or 1
        base = height - self.PAD
        bars = []
        for i, d in enumerate(self.days):
            if not d["cleanups"]:
                bars.append(None)
                continue
            h = max(d["bytes"] / high * (height - 2 * self.PAD), 2) * self.progress
            bars.append((self.PAD + (i + 0.15) * slot, base - h, slot * 0.7, h))
        return bars

    def draw(self, _area, cr, width, height):
        if not self.days or width <= 2 * self.PAD:
            return
        color = self.get_color()
        slot = (width - 2 * self.PAD) / len(self.days)
        if self.hover is not None:  # the hovered day, also one without a cleanup
            cr.set_source_rgba(color.red, color.green, color.blue, 0.08)
            cr.rectangle(self.PAD + self.hover * slot, self.PAD, slot, height - 2 * self.PAD)
            cr.fill()
        cr.set_source_rgba(color.red, color.green, color.blue, 0.3)
        cr.rectangle(self.PAD, height - self.PAD, width - 2 * self.PAD, 1)
        cr.fill()
        for i, bar in enumerate(self.bars(width, height)):
            if bar:
                cr.set_source_rgba(color.red, color.green, color.blue, 1 if i == self.hover else 0.75)
                cr.rectangle(*bar)
                cr.fill()


def animations_on(widget):
    return widget.get_settings().get_property("gtk-enable-animations")


class FreedPanel(Gtk.Box):
    """What CleanMate freed: three cards with a big number (last 30 days, in total, the last cleanup) and the
    bar chart of the last 30 days. The numbers are what left the disk; what the same cleanups moved to the
    Trash is still on it, and its line under the number says how much. With animate, the numbers count up
    and the bars grow once it shows."""

    def __init__(self, f, animate):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.numbers = {}  # "freed30", "lifetime", "last" → (Gtk.Label, bytes)
        self.chart = None  # FreedByDayChart, when a day in the last 30 had a cleanup
        self.timer = None
        self.map_handler = None
        cards = Gtk.Box(spacing=12, homogeneous=True)
        items = [("freed30", f["bytes"], f.get("trash_bytes", 0),
                  ngettext("Last 30 days · {n} cleanup", "Last 30 days · {n} cleanups", f["cleanups"])),
                 ("lifetime", f["lifetime"], f.get("lifetime_trash", 0),
                  ngettext("In total · {n} cleanup", "In total · {n} cleanups", f["runs"]))]
        if f["last_time"]:
            when = GLib.DateTime.new_from_unix_local(f["last_time"]).format("%x %H:%M")
            items.append(("last", f["last_bytes"], f.get("last_trash", 0),
                          _("Last cleanup · {date}").format(date=when)))
        self.trash_lines = {}  # key → the "… in the Trash" label of that card, when it has one
        for key, value, trash, caption in items:
            card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, css_classes=["card"])
            number = Gtk.Label(label=human(value), css_classes=["title-1", "numeric"], margin_top=18,
                               margin_start=12, margin_end=12)
            card.append(number)
            card.append(Gtk.Label(label=caption, wrap=True, justify=Gtk.Justification.CENTER,
                                  margin_bottom=6 if trash else 18, margin_start=12, margin_end=12,
                                  css_classes=["dim-label"]))
            if trash:
                line = Gtk.Label(label=_("{size} in the Trash").format(size=human(trash)), wrap=True,
                                 justify=Gtk.Justification.CENTER, margin_bottom=18, margin_start=12,
                                 margin_end=12, css_classes=["dim-label", "caption"])
                card.append(line)
                self.trash_lines[key] = line
            self.numbers[key] = (number, value)
            cards.append(card)
        self.append(cards)
        days = f.get("freed_by_day") or []
        if any(d["cleanups"] for d in days):
            if charts_ok():
                self.chart = FreedByDayChart(days)
                self.append(Gtk.Frame(child=self.chart, css_classes=["view"]))
            else:
                self.append(charts_note())
        self.animated = animate and animations_on(self)  # counts up once it shows
        self.animating = self.animated
        if self.animating:
            self.set_progress(0)
            self.map_handler = self.connect("map", lambda _w: self.begin())

    def begin(self):
        """Count up from now, once."""
        self.disconnect(self.map_handler)
        self.map_handler = None
        started = time.monotonic()

        def step():
            t = min((time.monotonic() - started) * 1000 / ANIMATION_MS, 1)
            self.set_progress(1 - (1 - t) ** 3)  # ease out
            if t < 1:
                return True
            self.timer = None
            self.animating = False
            return False

        self.timer = GLib.timeout_add(16, step)

    def stop(self):
        """Jump to the end (the page is rebuilt)."""
        if self.map_handler:
            self.disconnect(self.map_handler)
            self.map_handler = None
        if self.timer:
            GLib.source_remove(self.timer)
            self.timer = None
        self.animating = False
        self.set_progress(1)

    def set_progress(self, progress):
        for label, value in self.numbers.values():
            label.set_label(human(int(value * progress)))
        if self.chart:
            self.chart.set_progress(progress)


OUTSIDE_ICONS = {"reserved": "drive-harddisk-symbolic", "swapfile": "media-flash-symbolic",
                 "timeshift": "document-open-recent-symbolic"}


def outside_text(e):
    """Title and subtitle of a row in "Space outside your folders"."""
    kind, path = e["kind"], e["path"]
    if kind == "reserved":
        return _("Reserved for the system"), _(
            "ext4 keeps about 5 percent of {path} for root, so Ubuntu still runs when the disk is full").format(path=path)
    if kind == "swapfile":
        return _("Swap file"), _("{path} · extra memory on disk; shrinking it is possible but needs care").format(
            path=path)
    if kind == "timeshift":
        return ngettext("Timeshift: {n} snapshot", "Timeshift: {n} snapshots", e["count"]), _(
            "{path} · delete old ones in Timeshift, never by hand").format(path=path)
    return kind, e["note"]


PROTECTION_STATES = {  # state → icon, style
    "on": ("emblem-ok-symbolic", "success"),
    "off": ("dialog-warning-symbolic", "warning"),
    "unknown": ("dialog-question-symbolic", "dim-label"),
    "na": ("action-unavailable-symbolic", "dim-label"),
}


def protection_text(e):
    """Name, value and hint of a row in "System protection"."""
    names = {"firewall": _("Firewall"), "apparmor": _("AppArmor"), "updates": _("Automatic security updates"),
             "secureboot": _("Secure Boot")}
    values = {"on": _("On"), "off": _("Off"), "na": _("Not applicable")}
    value = values.get(e["state"], _("Unknown"))
    hints = {
        ("firewall", "ufw"): _("ufw is turned on."),
        ("firewall", "firewalld"): _("firewalld is turned on."),
        ("firewall", "disabled"): _("ufw is turned off. To turn it on, run in a terminal:"),
        ("firewall", "inactive"): _("ufw is set to start but isn't running. To start it, run in a terminal:"),
        ("firewall", "missing"): _("No firewall is installed. To install ufw and turn it on, run in a terminal:"),
        ("firewall", "unreadable"): _("Can't read /etc/ufw/ufw.conf."),
        ("apparmor", "loaded"): _("Apps with an AppArmor profile are confined."),
        ("apparmor", "service"): _("AppArmor's profiles aren't loaded. To load them, run in a terminal:"),
        ("apparmor", "kernel"): _("Turned off when the computer starts: remove apparmor=0 from the kernel options "
                                  "in /etc/default/grub, then run sudo update-grub."),
        ("apparmor", "unreadable"): _("Can't read AppArmor's state from the kernel."),
        ("updates", "on"): _("unattended-upgrades installs security updates every day."),
        ("updates", "missing"): _("unattended-upgrades isn't installed. To install it, run in a terminal:"),
        ("updates", "disabled"): _("Turned off in APT's settings. To turn it on, run in a terminal:"),
        ("updates", "timer"): _("The daily upgrade timer is off. To turn it on, run in a terminal:"),
        ("updates", "no-apt"): _("This system doesn't use APT."),
        ("updates", "unreadable"): _("Couldn't read APT's settings."),
        ("secureboot", "on"): _("Only signed boot loaders and kernels start."),
        ("secureboot", "firmware"): _("Turn it on in your computer's firmware (UEFI) settings."),
        ("secureboot", "legacy"): _("This computer starts without UEFI, so there is no Secure Boot."),
        ("secureboot", "unreadable"): _("Can't read the Secure Boot state."),
    }
    return names.get(e["id"], e["id"]), value, hints.get((e["id"], e["reason"]), "")


class OverviewPage(Gtk.Box):
    """Read-only facts in groups, with a Refresh button; a click on a large folder opens it in Space Lens."""

    def __init__(self, window, title, icon, description):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self.engine = window.engine
        self.title, self.description = title, description
        self.running = None  # Gio.Cancellable of the current engine run
        self.data = {}  # event name → event ("disk" → list)
        self.render_ms = None  # how long showing the quick part of the last result took
        self.first_ms = None  # from Refresh to the quick part on screen
        self.full_ms = None  # from Refresh to the folder sizes on screen
        self.first_before_folders = None  # the quick part showed before the folder sizes arrived
        self.chart = None  # HistoryChart, with two days or more
        self.freed = None  # FreedPanel, once a cleanup was recorded
        self.freed_shown = False  # the Freed numbers counted up once this session
        self.groups = {}  # "history", "outside", "top" → Adw.PreferencesGroup
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
    def reload(self):
        self.load()  # no-op while loading

    def load(self):
        if self.running:
            return
        data = {"disk": [], "outside": [], "protection": []}
        if not self.data:
            self.stack.set_visible_child_name("loading")
        self.refresh_button.set_sensitive(False)
        self.window.set_busy(True)
        started = time.monotonic()
        shown = []

        def show_first():
            t0 = time.monotonic()
            self.data = data  # still filling: "outside" and "top_dirs" come later
            self.show_results()
            shown.append(True)
            self.render_ms = (time.monotonic() - t0) * 1000
            self.first_ms = (time.monotonic() - started) * 1000
            self.first_before_folders = "top_dirs" not in data

        def on_event(e):
            if e["event"] in ("disk", "outside", "protection"):
                data[e["event"]].append(e)
            else:
                data[e["event"]] = e
            if e["event"] == "history" and "system" in data and not shown:
                show_first()
            elif e["event"] == "top_dirs" and shown:
                self.show_folders()

        def on_done(ok, status):
            self.running = None
            self.window.set_busy(False)
            self.refresh_button.set_sensitive(True)
            if "error" in data or "system" not in data:
                self.failed.set_description(messages.text(data.get("error", {})))
                self.stack.set_visible_child_name("failed")
                return
            if not shown:
                show_first()
            self.show_folders()
            self.full_ms = (time.monotonic() - started) * 1000

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
        self.groups.clear()
        self.chart = None
        if self.freed:
            self.freed.stop()
            self.freed = None
        d = self.data

        header = Gtk.Box(spacing=12)
        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, hexpand=True)
        text.append(Gtk.Label(label=self.title, xalign=0, wrap=True, css_classes=["title-1"]))
        text.append(Gtk.Label(label=self.description, xalign=0, wrap=True, css_classes=["dim-label"]))
        header.append(text)
        header.append(self.refresh_button)
        self.results.append(header)

        # the way in: System Overview only shows facts, Smart Scan finds what can go
        scan = Adw.PreferencesGroup()
        row = plain_row(Adw.ActionRow, title=_("Smart Scan"), css_classes=["item-row"],
                            subtitle=last_scan_text(d.get("last_scan", {}).get("time", 0)))
        row.add_prefix(Gtk.Image(icon_name="starred-symbolic", pixel_size=32))
        self.smart_button = named(Gtk.Button(label=_("Run Smart Scan"), valign=Gtk.Align.CENTER,
                                             css_classes=["suggested-action", "pill"],
                                             tooltip_text=_("Find the junk you can clean safely")),
                                  _("Run Smart Scan"))
        self.smart_button.connect("clicked", lambda _b: self.window.start_smart_scan())
        row.add_suffix(self.smart_button)
        row.set_activatable_widget(self.smart_button)
        self.rows["smart"] = row
        scan.add(row)
        self.results.append(scan)

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

        points = d.get("history", {}).get("points", [])[-HISTORY_POINTS:]
        history = Adw.PreferencesGroup(title=_("Free space over time"))
        if len(points) < 2:
            history.set_description(_("Free space on / is recorded once a day while you use CleanMate; "
                                      "the chart shows here after a few days."))
        else:
            history.set_description(history_trend(points))
            if charts_ok():
                self.chart = HistoryChart(points)
                history.add(Gtk.Frame(child=self.chart, css_classes=["view"]))
            else:
                history.add(charts_note())
        self.groups["history"] = history
        self.results.append(history)

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
            self.freed = FreedPanel(f, animate=not self.freed_shown)  # Refresh doesn't count up again
            self.freed_shown = True
            if not any(day["cleanups"] for day in f.get("freed_by_day") or []):
                freed.set_description(_("No cleanups in the last 30 days."))
            freed.add(self.freed)
        self.groups["freed"] = freed
        self.results.append(freed)

        # measured last: placeholders until "top_dirs" arrives (show_folders). The Flatpak sees neither the
        # space outside your folders (snapshots, swap) nor the system's protection: no group for them
        later = [("top", _("Largest folders in your home"))]
        if not IN_FLATPAK:
            later.insert(0, ("outside", _("Space outside your folders")))
        for key, title in later:
            group = Adw.PreferencesGroup(title=title, description=_("Measuring…"),
                                         header_suffix=Gtk.Spinner(spinning=True, valign=Gtk.Align.CENTER))
            self.groups[key] = group
            self.results.append(group)

        protection = Adw.PreferencesGroup(
            title=_("System protection"),
            description=_("Read only: CleanMate doesn't change these. To turn one on, run the command shown in a "
                          "terminal."))
        if not d.get("protection"):
            protection.set_description(_("Couldn't read the system's protection."))
        for e in d.get("protection", []):
            protection.add(self.protection_row(e))
        self.groups["protection"] = protection
        if not IN_FLATPAK:
            self.results.append(protection)
        self.stack.set_visible_child_name("results")

    def show_folders(self):
        """Fill the last two groups once the folder sizes are in (or the run ended without them)."""
        d = self.data
        if "top" not in self.groups or self.groups["top"].get_header_suffix() is None:
            return  # already filled
        outside = Adw.PreferencesGroup(
            title=_("Space outside your folders"),
            description=_("In use, but in none of your folders. Shown for information: each is a choice, "
                          "not junk."))
        items = d.get("outside", [])
        beyond = d.get("top_dirs", {}).get("outside_home")
        if not items and beyond is None:
            outside.set_description(_("No Timeshift snapshots, swap file or reserved space found."))
        biggest = max([e["bytes"] or 0 for e in items] + [beyond or 0], default=0)
        if beyond is not None:  # all of the system disk's use that isn't your home: /usr, /var, snap, Docker…
            row = plain_row(Adw.ActionRow, title=_("Outside your home folder"), css_classes=["item-row"],
                                subtitle=_("Apps, system files, logs, snaps and Docker on the system disk (/)"))
            row.add_prefix(Gtk.Image(icon_name="drive-harddisk-system-symbolic", pixel_size=24))
            for widget in size_widgets(beyond, biggest):
                row.add_suffix(widget)
            view = Gtk.Button(label=_("View in Space Lens"), valign=Gtk.Align.CENTER,
                              tooltip_text=_("See what takes the space, folder by folder"))
            view.connect("clicked", lambda _b: self.window.open_lens("/"))
            row.add_suffix(view)
            row.set_activatable_widget(view)
            self.rows["outside_home"] = row
            outside.add(row)
        for e in items:
            title, subtitle = outside_text(e)
            row = plain_row(Adw.ActionRow, title=title, subtitle=subtitle, css_classes=["item-row"])
            row.add_prefix(Gtk.Image(icon_name=OUTSIDE_ICONS.get(e["kind"], "drive-harddisk-symbolic"),
                                     pixel_size=24))
            if e["bytes"] is None:
                row.add_suffix(Gtk.Label(label="?", width_chars=9, xalign=1, css_classes=["numeric", "dim-label"],
                                         tooltip_text=_("Measuring its size needs administrator rights")))
            else:
                for widget in size_widgets(e["bytes"], biggest):
                    row.add_suffix(widget)
            self.rows["outside:" + e["kind"] + ":" + e["path"]] = row
            outside.add(row)

        top = Adw.PreferencesGroup(title=_("Largest folders in your home"))
        dirs = d.get("top_dirs", {}).get("dirs")
        if dirs is None:
            top.set_description(_("Couldn't measure your home folder."))
        elif not dirs:
            top.set_description(_("Your home folder is empty."))
        else:
            top.set_description(_("Click a folder to explore it in Space Lens."))
        biggest = max([e["bytes"] for e in dirs or []], default=0)
        for e in dirs or []:
            path = e["path"]
            row = plain_row(Adw.ActionRow, title=os.path.basename(path), subtitle=short_path(path),
                                subtitle_lines=1, css_classes=["item-row"], activatable=True,
                                tooltip_text=_("Open in Space Lens"))
            row.add_prefix(Gtk.Image(icon_name="folder-symbolic", pixel_size=24))
            for widget in size_widgets(e["bytes"], biggest):
                row.add_suffix(widget)
            row.add_suffix(Gtk.Image(icon_name="go-next-symbolic"))
            row.connect("activated", lambda _r, p=path: self.window.open_lens(p))
            self.rows["top:" + path] = row
            top.add(row)

        for key, group in (("outside", outside), ("top", top)):
            if key not in self.groups:
                continue  # the Flatpak has no "outside" group
            self.results.insert_child_after(group, self.groups[key])
            self.results.remove(self.groups[key])
            self.groups[key] = group

    def protection_row(self, e):
        name, value, hint = protection_text(e)
        command = e.get("command") or ""
        icon, style = PROTECTION_STATES.get(e["state"], PROTECTION_STATES["unknown"])
        subtitle = hint + ("\n" + command if command else "")
        row = plain_row(Adw.ActionRow, title=name, subtitle_selectable=True, css_classes=["item-row"])
        row.set_subtitle(subtitle)  # after use_markup=False: a command may hold "&&"
        row.add_prefix(Gtk.Image(icon_name=icon, pixel_size=24, css_classes=[style]))
        if command:
            copy = named(Gtk.Button(icon_name="edit-copy-symbolic", valign=Gtk.Align.CENTER, css_classes=["flat"],
                                    tooltip_text=_("Copy the command")))
            copy.update_property([Gtk.AccessibleProperty.LABEL], [_("Copy the command")])
            copy.connect("clicked", lambda _b, c=command: self.copy_command(c))
            row.add_suffix(copy)
        row.add_suffix(Gtk.Label(label=value, css_classes=[style] if e["state"] in ("on", "off") else ["dim-label"]))
        self.rows["protect:" + e["id"]] = row
        return row

    def copy_command(self, command):
        self.get_clipboard().set(command)
        self.window.toast(_("Command copied. Paste it in a terminal to run it."))

    def fact_row(self, key, label, value):
        row = plain_row(Adw.ActionRow, title=label, subtitle=value, subtitle_selectable=True,
                            css_classes=["property"])
        self.rows[key] = row
        return row

    def bar_row(self, key, title, subtitle, fraction, icon, tooltip=None):
        row = plain_row(Adw.ActionRow, title=title, subtitle=subtitle, css_classes=["item-row"],
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
