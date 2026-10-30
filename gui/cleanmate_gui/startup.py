"""Startup Items: apps and services that start when you log in; turn them on or off, remove yours.

The engine lists them (`--json startup`), changes them (`--json startup-set ID enable|disable|remove`)
and puts a removed file back (`--json restore`); this page only shows them. Entries and services
that come with the system are shown, but only the engine decides what can change.
"""
from gi.repository import Adw, Gio, GLib, Gtk

from .i18n import _, ngettext


def unit_icon(u):
    if u["kind"] == "autostart":
        try:
            info = Gio.DesktopAppInfo.new_from_filename(u["path"])
        except TypeError:
            info = None
        icon = info.get_icon() if info else None
        if icon:
            return Gtk.Image(gicon=icon, pixel_size=32)
        return Gtk.Image(icon_name="application-x-executable-symbolic", pixel_size=32)
    return Gtk.Image(icon_name="alarm-symbolic" if u["id"].endswith(".timer") else "system-run-symbolic",
                     pixel_size=32)


class StartupPage(Gtk.Box):
    """Login apps and systemd user services, each with an on/off switch."""

    def __init__(self, window, title, icon, description):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self.engine = window.engine
        self.units = []  # "unit" events, apps first
        self.info = {}  # the "done" event
        self.switches = {}  # unit id → Gtk.Switch
        self.rows = {}  # unit id → Adw.ActionRow
        self.syncing = False  # a switch moved by the page, not by you
        self.running = None  # Gio.Cancellable of the current engine run
        self.changing = False  # a change or undo runs: never cancelled, one at a time
        self.generation = 0
        self.undo_toast = None

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True)
        self.append(self.stack)
        spinner = Gtk.Spinner(spinning=True, width_request=32, height_request=32, halign=Gtk.Align.CENTER)
        self.stack.add_named(Adw.StatusPage(icon_name=icon, title=title, description=description, child=spinner),
                             "loading")
        self.failed = Adw.StatusPage(icon_name="dialog-warning-symbolic", title=_("Can't read your startup items"))
        self.stack.add_named(self.failed, "failed")
        self.results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24,
                               margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        self.stack.add_named(Gtk.ScrolledWindow(child=Adw.Clamp(maximum_size=900, child=self.results),
                                                vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER), "results")
        self.show_system = Adw.SwitchRow(title=_("Show system services"),
                                         subtitle=_("Parts of Ubuntu that start for every user"))
        self.show_system.connect("notify::active", lambda *_a: self.show_results())
        self.load()

    # ── loading ──
    def load(self):
        if self.running:
            self.running.cancel()
            self.running = None
            self.window.set_busy(False)
        self.generation += 1
        gen = self.generation
        units, info = [], {}
        if not self.units:
            self.stack.set_visible_child_name("loading")
        self.window.set_busy(True)

        def on_event(e):
            if e["event"] == "unit":
                units.append(e)
            elif e["event"] in ("done", "error"):
                info.update(e)

        def on_done(ok, status):
            if gen != self.generation:
                return
            self.running = None
            self.window.set_busy(False)
            if "message" in info:
                self.failed.set_description(info["message"])
                self.stack.set_visible_child_name("failed")
                return
            self.units, self.info = units, info
            self.show_results()

        self.running = self.engine.startup(on_event, on_done)

    # ── results ──
    def visible_units(self):
        return [u for u in self.units if self.show_system.get_active() or not u["hidden"]]

    def show_results(self):
        child = self.results.get_first_child()
        while child:
            self.results.remove(child)
            child = self.results.get_first_child()
        if self.show_system.get_parent():
            self.show_system.get_parent().remove(self.show_system)
        self.switches.clear()
        self.rows.clear()
        units = self.visible_units()

        self.count = Gtk.Label(xalign=0, wrap=True, css_classes=["title-1"])
        header = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        header.append(self.count)
        header.append(Gtk.Label(label=_("Fewer apps at login means a faster start. Turning one off doesn't "
                                        "uninstall it."), xalign=0, wrap=True, css_classes=["dim-label"]))
        self.results.append(header)

        for kind, title, empty in (
                ("autostart", _("Apps"), _("No app starts when you log in.")),
                ("systemd-user", _("Services and timers"), _("No service or timer of yours starts when you log in."))):
            group = Adw.PreferencesGroup(title=title)
            mine = [u for u in units if u["kind"] == kind]
            if kind == "systemd-user" and not self.info.get("systemd", True):
                group.set_description(_("systemd user services aren't available here."))
            elif not mine:
                group.set_description(empty)
            for u in mine:
                group.add(self.unit_row(u))
            self.results.append(group)
        options = Adw.PreferencesGroup()
        options.add(self.show_system)
        hidden = sum(u["hidden"] for u in self.units)
        self.show_system.set_subtitle(ngettext("{n} part of Ubuntu that starts for every user",
                                               "{n} parts of Ubuntu that start for every user", hidden))
        self.results.append(options)
        self.update_count()
        self.stack.set_visible_child_name("results")

    def unit_row(self, u):
        subtitle = u["description"] if u["description"] and u["description"] != u["name"] else u["command"]
        row = Adw.ActionRow(title=u["name"], subtitle=subtitle, use_markup=False, subtitle_lines=1,
                            css_classes=["item-row"], tooltip_text=u["path"] or u["id"].split(":", 1)[1])
        row.add_prefix(unit_icon(u))
        if u["system"]:
            row.add_suffix(Gtk.Label(label=_("System"), valign=Gtk.Align.CENTER, css_classes=["caption", "dim-label"]))
        if u["removable"]:
            remove = Gtk.Button(icon_name="user-trash-symbolic", valign=Gtk.Align.CENTER, css_classes=["flat"],
                                tooltip_text=_("Remove (to the Trash)"))
            remove.connect("clicked", lambda *_a: self.confirm_remove(u))
            row.add_suffix(remove)
        switch = Gtk.Switch(active=u["enabled"], valign=Gtk.Align.CENTER, sensitive=u["toggle"])
        if not u["toggle"]:
            switch.set_tooltip_text(_("Comes with the system: only shown here"))
        else:
            row.set_activatable_widget(switch)
        switch.connect("notify::active", self.on_switched, u)
        row.add_suffix(switch)
        self.switches[u["id"]] = switch
        self.rows[u["id"]] = row
        return row

    def update_count(self):
        units = self.visible_units()
        on = sum(u["enabled"] for u in units)
        self.count.set_label(ngettext("{on} of {n} starts when you log in", "{on} of {n} start when you log in",
                                      len(units), on=on))

    def set_switch(self, unit_id, active):
        switch = self.switches.get(unit_id)
        if switch:
            self.syncing = True
            switch.set_active(active)
            self.syncing = False

    # ── changes ──
    def on_switched(self, switch, _pspec, u):
        if self.syncing:
            return
        on = switch.get_active()
        if self.changing:  # one change at a time
            return self.set_switch(u["id"], not on)
        self.change(u, "enable" if on else "disable")

    def change(self, u, action, then=None):
        """Run startup-set; then(task event) on success."""
        result = {}

        def on_event(e):
            if e["event"] in ("task", "error"):
                result.update(e)

        def on_done(ok, status):
            self.running, self.changing = None, False
            self.window.set_busy(False)
            self.results.set_sensitive(True)
            if result.get("state") != "ok":
                self.set_switch(u["id"], u["enabled"])  # back to what it is
                self.window.toast(result.get("info") or result.get("message") or _("Could not change it"))
                return
            if self.engine.dry_run:
                self.set_switch(u["id"], u["enabled"])
                self.window.toast(_("Dry run: {name} would be changed").format(name=u["name"]))
                return
            if action in ("enable", "disable"):
                u["enabled"] = action == "enable"
                self.update_count()
                self.window.toast((_("{name} will start when you log in") if u["enabled"]
                                   else _("{name} won't start when you log in")).format(name=u["name"]))
            if then:
                then(result)

        if self.changing:
            return self.set_switch(u["id"], u["enabled"])
        self.stop_reload()
        self.changing = True
        self.window.set_busy(True)
        self.results.set_sensitive(False)
        self.running = self.engine.startup_set(u["id"], action, on_event, on_done)

    def confirm_remove(self, u):
        dialog = Adw.AlertDialog(
            heading=_("Remove {name}?").format(name=u["name"]),
            body=_("It won't start when you log in any more, and its startup file goes to the Trash. "
                   "The app itself stays installed. You can undo this right away."))
        dialog.add_response("cancel", _("Cancel"))
        dialog.add_response("remove", _("Remove"))
        dialog.set_response_appearance("remove", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.set_close_response("cancel")
        dialog.connect("response", lambda d, r: r == "remove" and self.remove(u))
        dialog.present(self.window)

    def stop_reload(self):
        if self.running:  # only ever a reload when nothing is changing
            self.running.cancel()
            self.running = None
            self.window.set_busy(False)
            self.generation += 1

    def remove(self, u):
        def removed(task):
            self.load()
            if task.get("trash"):
                self.undo_toast = self.window.toast(_("Removed {name}").format(name=u["name"]), _("Undo"),
                                                    lambda: self.undo(u, task["trash"]), timeout=10)
            else:
                self.window.toast(_("Removed {name}").format(name=u["name"]))

        self.change(u, "remove", removed)

    def undo(self, u, name):
        """Put the file back; a service that was on is turned on again."""
        if self.changing:
            return
        self.undo_toast = None
        result = {}

        def on_event(e):
            if e["event"] in ("task", "error"):
                result.update(e)

        def on_done(ok, status):
            self.running, self.changing = None, False
            self.window.set_busy(False)
            if result.get("state") != "ok":
                self.window.toast(_("Could not restore {name}: {reason}").format(
                    name=u["name"], reason=result.get("info") or result.get("message", "")))
                return self.load()
            if u["kind"] == "systemd-user" and u["enabled"]:
                return self.change(u, "enable", lambda _t: (self.load(), self.window.toast(
                    _("{name} is back").format(name=u["name"]))))
            self.load()
            self.window.toast(_("{name} is back").format(name=u["name"]))

        if self.changing:
            return
        self.stop_reload()
        self.changing = True
        self.window.set_busy(True)
        self.running = self.engine.restore([name], on_event, on_done)
