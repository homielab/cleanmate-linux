"""The engine's results in the app's language.

Every `error` event, and every `task` event that says how something went, carries a stable
`code` and its `args` next to the English `message` / `info` (cleanmate.sh `json_code`). This
module turns the code into translated text; an event without a code keeps its English text.
The background notifications (low disk, scan reminder, automatic cleaning) come here too:
the engine runs `python3 -m cleanmate_gui.messages notify CODE [KEY VALUE]…` and sends what
it prints, and the app sends the one `--json check` hands it. So this module imports no GTK, only i18n.

tests/messages_test.py checks that every code the engine sends has a text here, translated.
"""
import sys

from .i18n import _, item_text, ngettext


def human(n):
    """Bytes → '1.8 GB', identical to the engine's formatting."""
    n = int(n or 0)
    if n < 1024:
        return f"{n} B"
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    d, i = 1, 0
    while n // d >= 1024 and i < 5:
        d, i = d * 1024, i + 1
    t = (n * 10 + d // 2) // d
    if t >= 10240 and i < 5:
        d, i = d * 1024, i + 1
        t = (n * 10 + d // 2) // d
    return f"{t // 10}.{t % 10} {units[i]}"


def maint_missing():
    """Maintenance task → why it can't run here (the engine's MAINT_WHY)."""
    return {
        "update": _("apt isn't available on this system."),
        "repair": _("apt isn't available on this system."),
        "flatpak_unused": _("Flatpak is not installed."),
        "fstrim": _("fstrim is not installed."),
        "fonts": _("fontconfig (fc-cache) is not installed."),
        "locate": _("locate/plocate is not installed."),
        "snap_versions": _("Snap is not installed."),
        "journal_limit": _("This system doesn't use the systemd journal."),
    }


def _values():
    """Setting values the engine names in a message (schedule, reminder, language)."""
    return {"off": _("Off"), "daily": _("Daily"), "weekly": _("Weekly"), "monthly": _("Monthly"),
            "system": _("System"), "en": "English", "vi": "Tiếng Việt"}


def texts():
    """Code → text with {fields} from the event's args. `size` is `bytes` as '1.8 GB'."""
    return {
        # errors: the command was refused
        "usage": _("CleanMate couldn't do this: the cleaning engine didn't understand the request."),
        "per_user": _("This works for your own account: run CleanMate as yourself, not as root."),
        "refused_as_root": _("CleanMate doesn't do this as root: run it as yourself."),
        "unknown_item": _("Unknown cleanup item: {id}"),
        "flatpak_unavailable": _("Not available in the Flatpak: this manages the system's apps and services. "
                                 "Use the .deb version."),
        "not_folder": _("Not a folder: {path}"),
        "unknown_startup": _("Unknown startup item: {id}"),
        "bad_value": _("This value isn't allowed for {key}."),
        "no_gsettings": _("gsettings is not available."),
        "out_of_range": _("{key} must be a number from {min} to {max}."),
        "not_removable": _("Not an app CleanMate can remove: {app}"),
        "remove_as_user": _("This app is removed as you, not as root: {app}"),
        "apt_refused": _("apt can't remove this cleanly: {detail}"),
        "apt_takes_core": _("Not removed: apt would also take {packages}, which Ubuntu needs to run."),
        "apt_required": _("Not removed: {packages} is marked as required by Ubuntu. Use apt yourself if you're sure."),
        "not_resettable": _("Not an app CleanMate can reset: {app}"),
        "close_first": _("Close {program} first: resetting an app while it runs can lose what is open in it."),
        "not_data_folder": _("Not a data folder of this app: {path}"),
        "nothing_to_reset": _("Nothing to reset: this app keeps no data in your home."),
        "maint_missing": _("A tool this task needs is missing."),  # replaced by maint_missing()[id]
        "maint_as_user": _("This task runs as you, not as root."),
        "engine_failed": _("The cleaning engine couldn't start."),
        # Smart Scan › clean
        "excluded": _("In Settings › Never clean"),
        "already_clean": _("Already clean"),
        "app_running": _("Skipped: the app is running — close it and try again"),
        "needs_root": _("Skipped: needs administrator rights"),
        "clean_failed": _("Couldn't clean it"),
        "cleared": _("Cleared"),
        "would_clear": _("Would be cleared"),
        "freed": _("{size} freed"),
        "would_free": _("{size} would be freed"),
        # files: Trash, put back, uninstall
        "not_absolute": _("Not a full path"),
        "not_movable": _("Only items inside your home folder or on a writable drive can be moved to the Trash here"),
        "not_found": _("Not found"),
        "trashed": _("Moved to the Trash"),
        "would_trash": _("Would be moved to the Trash"),
        "trash_failed": _("Couldn't move it to the Trash"),
        "needs_gio": _("Moving to the Trash outside your home folder needs gio (package libglib2.0-bin)"),
        "not_in_trash": _("Not in the Trash any more"),
        "restored": _("Put back"),
        "would_restore": _("Would be put back"),
        "name_taken": _("A file with this name is already there"),
        "program_running": _("Skipped: {program} is running — close it and try again"),
        "uninstalled": _("Removed"),
        "would_uninstall": _("Would be removed"),
        "uninstall_failed": _("Couldn't remove it"),
        # startup items
        "system_turn_off": _("It comes with the system: turn it off instead"),
        "turned_on": _("Turned on"),
        "turned_off": _("Turned off"),
        "would_turn_on": _("Would be turned on"),
        "would_turn_off": _("Would be turned off"),
        "write_failed": _("Couldn't change {path}"),
        "not_a_unit": _("Not a service or timer"),
        "system_unit": _("It comes with the system: only shown here"),
        "not_removable_unit": _("Only units in {path}, or whose program is gone, can be removed"),
        "systemctl_failed": _("systemctl couldn't change it"),
        # settings
        "added": _("Added to Never clean"),
        "already_listed": _("Already in Never clean"),
        "would_add": _("Would be added to Never clean"),
        "removed": _("Removed from Never clean"),
        "would_remove": _("Would be removed from Never clean"),
        "not_listed": _("Not in Never clean: {path}"),
        "not_full_path": _("Not a full path: {path}"),
        "control_chars": _("The folder's name has control characters"),
        "too_broad": _("Your home folder or a folder above it is too broad to exclude"),
        "outside_home": _("Only folders inside your home folder can be excluded"),
        "symlink": _("Folders reached through a symbolic link can't be excluded"),
        "save_failed": _("Couldn't save {path}"),
        "remove_failed": _("Couldn't remove {path}"),
        "set": _("Set to {value}"),
        "would_set": _("Would be set to {value}"),
        "forgotten": _("Forgotten"),
        "would_forget": _("Would be forgotten"),
        "gsettings_failed": _("gsettings couldn't change it"),
        "no_systemd": _("systemd is not available."),
        "timer_failed": _("Couldn't turn on the systemd timer."),
        "schedule_off": _("Automatic cleaning turned off."),
        "schedule_on": _("Automatic cleaning: {value}."),
        "schedule_not_installed": _("Automatic cleaning: {value}. Install the launcher so moving CleanMate "
                                    "won't break this."),
        # maintenance steps
        "skipped": _("Skipped"),
        "done": _("Done"),
        "would_run": _("Would run"),
        "step_failed": _("Failed"),
        "ram_freed": _("Available RAM {before} → {after}"),
        "trimmed": None,  # plural: see text()
        "snap_retain": _("Older versions go at the next snap refresh — or clean them now in System Junk"),
    }


# the background notifications: (title, body) — see notification()
NOTIFICATIONS = ("low_disk", "remind", "remind_first", "auto_clean", "auto_failed")


def _fields(args):
    fields = dict(args or {})
    for key in ("bytes", "before", "after", "freed"):
        if key in fields:
            try:
                fields["size" if key == "bytes" else key] = human(fields[key])
            except (TypeError, ValueError):
                pass
    if "value" in fields:
        fields["value"] = _values().get(fields["value"], fields["value"])
    return fields


def known(code):
    return code in texts() or code in NOTIFICATIONS


def text(event, fallback=""):
    """The translated text of an event's `code`; its English message/info when it has none."""
    english = event.get("info") or event.get("message") or fallback
    code = event.get("code")
    if not code:
        return english
    fields = _fields(event.get("args"))
    if code == "maint_missing":
        return maint_missing().get(fields.get("id"), texts()[code])
    if code == "trimmed":
        try:
            n = int(fields.get("n", 0))
        except ValueError:
            return english
        return ngettext("{n} file system trimmed", "{n} file systems trimmed", n)
    template = texts().get(code)
    if not template:
        return english
    try:
        return template.format(**fields)
    except (KeyError, IndexError, ValueError):
        return english


def detail(event):
    """What a tool printed when it failed (English, from the tool itself), for a tooltip or a log; "" if none."""
    return (event.get("args") or {}).get("detail", "")


def notification(code, args):
    """(title, body) of a background notification in the app's language."""
    f = _fields(args)
    if code == "low_disk":
        return (_("Disk almost full"),
                _("Only {size} ({pct}%) free on /. Open CleanMate to free up space.").format(**f))
    if code == "remind":
        n = int(f.get("days", 0))
        return (_("Time for a Smart Scan"),
                ngettext("Your last scan was {n} day ago. Open CleanMate to see what can be cleaned.",
                         "Your last scan was {n} days ago. Open CleanMate to see what can be cleaned.", n))
    if code == "remind_first":
        return _("Time for a Smart Scan"), _("Open CleanMate to see what can be cleaned.")
    if code == "auto_clean":
        freed = int(args.get("freed", 0) or 0)
        title = _("Freed {size}").format(size=human(freed)) if freed else "CleanMate"
        body = _("Caches and junk were cleaned automatically.") if freed else ""
        left = []
        for key in sorted(k for k in args if k.startswith("item")):
            size, _sep, label = args[key].partition(" ")
            left.append(_("{name} {size}").format(name=item_text(label), size=human(size)))
        if left:
            body = (body + " " if body else "") + _("Worth a look: {items}. Open CleanMate to review.").format(
                items=", ".join(left))
        return title, body
    if code == "auto_failed":
        items = [item_text(args[k]) for k in sorted(k for k in args if k.startswith("item"))]
        if args.get("reason") == "task_failed" and items:
            body = _("Couldn't clean {items}. It runs again at the next scheduled time; open CleanMate to see "
                     "why.").format(items=", ".join(items))
        else:
            n = int(args.get("tries", 3) or 3)
            body = ngettext("It was stopped {n} time before it finished, for example by sleep or logging out. It "
                            "runs again at the next scheduled time, or clean now in CleanMate.",
                            "It was stopped {n} times before it finished, for example by sleep or logging out. It "
                            "runs again at the next scheduled time, or clean now in CleanMate.", n)
        return _("Couldn't finish automatic cleaning"), body
    raise KeyError(code)


def main(argv):
    """`notify CODE [KEY VALUE]…` → the title, a newline and the body."""
    if len(argv) < 2 or argv[0] != "notify" or len(argv) % 2:
        print("usage: python3 -m cleanmate_gui.messages notify CODE [KEY VALUE]…", file=sys.stderr)
        return 2
    args = dict(zip(argv[2::2], argv[3::2]))
    try:
        title, body = notification(argv[1], args)
    except (KeyError, ValueError):
        return 1
    sys.stdout.write(f"{title}\n{body}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
